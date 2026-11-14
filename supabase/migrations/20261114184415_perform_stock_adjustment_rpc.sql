BEGIN;
CREATE OR REPLACE FUNCTION public.perform_stock_adjustment(
 p_product_id uuid,p_adjustment_type text,p_quantity numeric,p_reason text,
 p_reason_details text DEFAULT NULL,p_notes text DEFAULT NULL,
 p_expected_current_stock numeric DEFAULT NULL,p_idempotency_key uuid DEFAULT NULL,
 p_reconciliation_id uuid DEFAULT NULL,p_unit_cost numeric DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET row_security=off AS $$
DECLARE
 u uuid:=auth.uid(); s uuid; r public.stock_reconciliations%ROWTYPE;
 why text; detail text;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE='42501'; END IF;
 IF p_adjustment_type IS NULL OR p_adjustment_type NOT IN ('increase','decrease','set_actual')
  OR p_quantity IS NULL OR p_quantity<0 OR (p_adjustment_type<>'set_actual' AND p_quantity=0) THEN
  RAISE EXCEPTION 'Invalid adjustment'; END IF;
 IF p_adjustment_type='increase' AND NOT public.has_store_permission('actions.adjust_stock_increase')
  AND NOT (p_reason='opening_stock_correction' AND public.has_store_permission('products.create')) THEN
  RAISE EXCEPTION 'Stock increase permission required' USING ERRCODE='42501'; END IF;
 IF p_adjustment_type='decrease' AND NOT public.has_store_permission('actions.adjust_stock_decrease') THEN
  RAISE EXCEPTION 'Stock decrease permission required' USING ERRCODE='42501'; END IF;
 IF p_adjustment_type='set_actual' AND NOT public.has_store_permission('stock_reconciliation.edit') THEN
  RAISE EXCEPTION 'Stock reconciliation permission required' USING ERRCODE='42501'; END IF;
 IF p_unit_cost IS NOT NULL AND (p_adjustment_type<>'increase' OR p_unit_cost<0
  OR NOT public.has_store_permission('products.edit')
  OR NOT public.has_store_permission('actions.view_purchase_price')) THEN
  RAISE EXCEPTION 'Purchase-cost permission required' USING ERRCODE='42501'; END IF;
 s:=public.get_my_store_id();
 IF s IS NULL THEN RAISE EXCEPTION 'Store required' USING ERRCODE='42501'; END IF;
 why:=NULLIF(btrim(p_reason),''); detail:=NULLIF(btrim(p_reason_details),'');
 IF p_reconciliation_id IS NOT NULL THEN
  SELECT * INTO r FROM public.stock_reconciliations
   WHERE id=p_reconciliation_id AND store_id=s FOR UPDATE;
  IF NOT FOUND OR r.product_id<>p_product_id OR r.adjustment_applied
   OR r.status<>'DIFFERENCE_FOUND' OR p_adjustment_type<>'set_actual'
   OR p_quantity<>r.physical_quantity THEN RAISE EXCEPTION 'Reconciliation unavailable'; END IF;
  why:=CASE r.reason WHEN 'Damaged Product' THEN 'damaged_products'
   WHEN 'Expired Product' THEN 'expired_products' WHEN 'Lost Product' THEN 'lost_missing_products'
   WHEN 'Theft' THEN 'lost_missing_products' WHEN 'Other' THEN 'other'
   WHEN 'damagedProduct' THEN 'damaged_products' WHEN 'expiredProduct' THEN 'expired_products'
   WHEN 'lostProduct' THEN 'lost_missing_products' WHEN 'other' THEN 'other'
   ELSE COALESCE(r.reason,'physical_stock_correction') END;
  detail:=r.reason_details;
 END IF;
 RETURN public.apply_stock_adjustment_atomic(p_product_id,p_adjustment_type,p_quantity,
  why,detail,p_notes,p_expected_current_stock,p_idempotency_key,p_reconciliation_id,p_unit_cost);
END;
$$;
REVOKE ALL ON FUNCTION public.perform_stock_adjustment(uuid,text,numeric,text,text,text,numeric,uuid,uuid,numeric) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.perform_stock_adjustment(uuid,text,numeric,text,text,text,numeric,uuid,uuid,numeric) TO authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
