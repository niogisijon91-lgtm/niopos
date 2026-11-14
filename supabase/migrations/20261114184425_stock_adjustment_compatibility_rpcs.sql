BEGIN;

CREATE OR REPLACE FUNCTION public.adjust_inventory_stock(
  p_product_id uuid,
  p_direction text,
  p_quantity numeric,
  p_reason text,
  p_note text DEFAULT NULL,
  p_purchase_price numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE
  v_reason text;
  v_result jsonb;
BEGIN
  v_reason := CASE p_reason
    WHEN 'Opening Stock' THEN 'opening_stock_correction'
    WHEN 'New Stock Received' THEN 'physical_stock_correction'
    WHEN 'Purchase Return' THEN 'physical_stock_correction'
    WHEN 'Manual Adjustment' THEN 'physical_stock_correction'
    WHEN 'Damaged Product' THEN 'damaged_products'
    WHEN 'Expired Product' THEN 'expired_products'
    WHEN 'Lost / Missing' THEN 'lost_missing_products'
    WHEN 'Internal Use' THEN 'internal_stock_correction'
    WHEN 'Other' THEN CASE WHEN NULLIF(btrim(p_note), '') IS NOT NULL
      THEN 'other' ELSE 'physical_stock_correction' END
    ELSE p_reason
  END;
  v_result := public.perform_stock_adjustment(
    p_product_id,
    CASE p_direction WHEN 'in' THEN 'increase' WHEN 'out' THEN 'decrease' ELSE p_direction END,
    p_quantity, v_reason,
    CASE WHEN p_reason = 'Other' THEN p_note ELSE NULL END,
    p_note, NULL, gen_random_uuid(), NULL, p_purchase_price
  );
  RETURN v_result || jsonb_build_object(
    'direction', p_direction, 'purchase_price', p_purchase_price
  );
END;
$$;
REVOKE ALL ON FUNCTION public.adjust_inventory_stock(uuid, text, numeric, text, text, numeric)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.adjust_inventory_stock(uuid, text, numeric, text, text, numeric)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.apply_stock_reconciliation_adjustment(
  p_reconciliation_id uuid,
  p_expected_current_stock numeric,
  p_adjusted_by text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE
  v_reconciliation public.stock_reconciliations%ROWTYPE;
  v_reason text;
BEGIN
  SELECT sr.* INTO v_reconciliation
  FROM public.stock_reconciliations AS sr
  WHERE sr.id = p_reconciliation_id AND sr.store_id = public.get_my_store_id();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reconciliation not found';
  END IF;

  v_reason := CASE v_reconciliation.reason
    WHEN 'Damaged Product' THEN 'damaged_products'
    WHEN 'Expired Product' THEN 'expired_products'
    WHEN 'Lost Product' THEN 'lost_missing_products'
    WHEN 'Theft' THEN 'lost_missing_products'
    WHEN 'Other' THEN 'other'
    WHEN 'damagedProduct' THEN 'damaged_products'
    WHEN 'expiredProduct' THEN 'expired_products'
    WHEN 'lostProduct' THEN 'lost_missing_products'
    WHEN 'other' THEN CASE WHEN NULLIF(btrim(v_reconciliation.reason_details), '') IS NOT NULL
      THEN 'other' ELSE 'physical_stock_correction' END
    WHEN 'damaged_products' THEN 'damaged_products'
    WHEN 'expired_products' THEN 'expired_products'
    WHEN 'lost_missing_products' THEN 'lost_missing_products'
    WHEN 'found_extra_stock' THEN 'found_extra_stock'
    WHEN 'opening_stock_correction' THEN 'opening_stock_correction'
    WHEN 'internal_stock_correction' THEN 'internal_stock_correction'
    WHEN 'physical_stock_correction' THEN 'physical_stock_correction'
    ELSE 'physical_stock_correction'
  END;

  RETURN public.perform_stock_adjustment(
    v_reconciliation.product_id, 'set_actual', v_reconciliation.physical_quantity,
    v_reason, v_reconciliation.reason_details, NULL, p_expected_current_stock,
    p_reconciliation_id, p_reconciliation_id, NULL
  );
END;
$$;
REVOKE ALL ON FUNCTION public.apply_stock_reconciliation_adjustment(uuid, numeric, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.apply_stock_reconciliation_adjustment(uuid, numeric, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
