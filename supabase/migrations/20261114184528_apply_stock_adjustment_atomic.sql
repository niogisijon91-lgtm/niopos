BEGIN;
CREATE OR REPLACE FUNCTION public.apply_stock_adjustment_atomic(uuid,text,numeric,text,text,text,numeric,uuid,uuid,numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET row_security=off AS $$
DECLARE
 u uuid:=auth.uid(); s uuid; k uuid:=COALESCE($8,gen_random_uuid());
 p public.products%ROWTYPE; old public.stock_adjustments%ROWTYPE;
 prev numeric; nxt numeric; delta numeric; old_cost numeric; cost numeric; aid uuid;
 why text:=NULLIF(btrim($4),''); detail text:=NULLIF(btrim($5),''); typ text;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
 s:=public.get_my_store_id();
 IF s IS NULL THEN RAISE EXCEPTION 'Store required' USING ERRCODE='42501'; END IF;
 SELECT * INTO p FROM public.products WHERE id=$1 AND store_id=s AND NOT COALESCE(is_deleted,false) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Product not found in current store'; END IF;
 SELECT * INTO old FROM public.stock_adjustments WHERE store_id=s AND idempotency_key=k;
 IF FOUND THEN RETURN jsonb_build_object('adjustment_id',old.id,'idempotent_replay',true); END IF;
 IF why IS NULL OR why NOT IN ('physical_stock_correction','damaged_products','expired_products',
  'lost_missing_products','found_extra_stock','opening_stock_correction','internal_stock_correction','other')
  OR (why='other' AND detail IS NULL) THEN RAISE EXCEPTION 'Invalid adjustment reason'; END IF;
 prev:=COALESCE(p.stock,0);
 IF $7 IS NOT NULL AND prev<>$7 THEN RAISE EXCEPTION 'Stock changed; reload and retry'; END IF;
 IF COALESCE(p.unit,'') !~* '^(kg|g|gram|grams|liter|litre|l|ml|meter|metre|m|cm|mm)$'
  AND $3<>trunc($3) THEN RAISE EXCEPTION 'Whole quantity required'; END IF;
 nxt:=CASE $2 WHEN 'increase' THEN prev+$3 WHEN 'decrease' THEN prev-$3 ELSE $3 END;
 delta:=nxt-prev;
 IF nxt<0 OR delta=0 THEN RAISE EXCEPTION 'Invalid resulting stock'; END IF;
 IF (delta>0 AND NOT public.has_store_permission('actions.adjust_stock_increase')
  AND NOT (why='opening_stock_correction' AND public.has_store_permission('products.create')))
  OR (delta<0 AND NOT public.has_store_permission('actions.adjust_stock_decrease')) THEN
  RAISE EXCEPTION 'Adjustment direction not permitted' USING ERRCODE='42501'; END IF;
 old_cost:=COALESCE(p.cost_price,0); cost:=CASE WHEN delta>0 AND $10 IS NOT NULL THEN $10 ELSE old_cost END;
 typ:=CASE WHEN $2='set_actual' THEN 'set_actual' WHEN delta>0 THEN 'increase' ELSE 'decrease' END;
 UPDATE public.products SET stock=nxt,cost_price=cost,updated_at=clock_timestamp() WHERE id=$1 AND store_id=s;
 SELECT COALESCE(cost_price,0) INTO cost FROM public.products WHERE id=$1 AND store_id=s;
 aid:=public.record_stock_adjustment_atomic($1,$9,u,k,why,detail,$6,typ,prev,nxt,p.unit,p.name,p.sku,p.barcode,s,old_cost,cost);
 RETURN jsonb_build_object('adjustment_id',aid);
END;
$$;
REVOKE ALL ON FUNCTION public.apply_stock_adjustment_atomic(uuid,text,numeric,text,text,text,numeric,uuid,uuid,numeric) FROM PUBLIC,anon,authenticated;
COMMIT;
