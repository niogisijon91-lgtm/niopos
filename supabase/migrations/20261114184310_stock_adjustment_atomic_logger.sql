BEGIN;
CREATE OR REPLACE FUNCTION public.record_stock_adjustment_atomic(
 uuid,uuid,uuid,uuid,text,text,text,text,numeric,numeric,text,text,text,text,uuid,numeric,numeric
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET row_security=off AS $$
DECLARE
 aid uuid; actor text; delta numeric:=$10-$9;
BEGIN
 SELECT COALESCE(NULLIF(btrim(full_name),''),email,$3::text) INTO actor
 FROM public.profiles WHERE id=$3;
 INSERT INTO public.stock_adjustments(
  product_id,reconciliation_id,adjusted_by_user_id,idempotency_key,reason,reason_details,notes,
  previous_quantity,new_quantity,difference,quantity,adjustment_type,unit,product_name,sku,
  barcode,store_id,adjusted_by,adjusted_at,value_impact
 ) VALUES(
  $1,$2,$3,$4,$5,$6,NULLIF(btrim($7),''),$9,$10,delta,abs(delta),$8,$11,$12,$13,$14,
  $15,COALESCE(actor,$3::text),clock_timestamp(),($10*$17)-($9*$16)
 ) RETURNING id INTO aid;
 INSERT INTO public.stock_movements(
  product_id,type,quantity,reference,note,previous_stock,new_stock,reason,purchase_price,
  performed_by,store_id,idempotency_key,stock_adjustment_id
 ) VALUES(
  $1,CASE WHEN delta>0 THEN 'in' ELSE 'out' END,abs(delta),'Stock Adjustment',
  COALESCE(NULLIF(btrim($7),''),$6),$9,$10,$5,$17,$3,$15,$4,aid
 );
 IF $2 IS NOT NULL THEN
  UPDATE public.stock_reconciliations SET adjustment_applied=true,
   adjustment_applied_at=clock_timestamp(),adjustment_applied_by=COALESCE(actor,$3::text)
   WHERE id=$2 AND store_id=$15 AND NOT adjustment_applied;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reconciliation state changed'; END IF;
 END IF;
 RETURN aid;
END;
$$;
REVOKE ALL ON FUNCTION public.record_stock_adjustment_atomic(uuid,uuid,uuid,uuid,text,text,text,text,numeric,numeric,text,text,text,text,uuid,numeric,numeric) FROM PUBLIC,anon,authenticated;
COMMIT;
