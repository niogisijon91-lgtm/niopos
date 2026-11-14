BEGIN;

CREATE OR REPLACE FUNCTION public.record_stock_reconciliations(p_items jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE
  v_store_id uuid;
  v_user_id uuid := auth.uid();
  v_ids uuid[];
  v_expected_count integer;
  v_locked_count integer;
  v_item jsonb;
  v_product public.products%ROWTYPE;
  v_physical numeric;
  v_difference numeric;
  v_reason text;
  v_details text;
  v_actor text;
  v_inserted integer := 0;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication is required' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_store_permission('stock_reconciliation.create') THEN
    RAISE EXCEPTION 'Stock reconciliation permission is required' USING ERRCODE = '42501';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Stock counts must be supplied as an array';
  END IF;
  IF jsonb_array_length(p_items) < 1 OR jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'Provide between 1 and 500 stock counts';
  END IF;

  v_store_id := public.get_my_store_id();
  IF v_store_id IS NULL THEN
    RAISE EXCEPTION 'Store is required' USING ERRCODE = '42501';
  END IF;
  SELECT COALESCE(NULLIF(btrim(p.full_name), ''), p.email)
  INTO v_actor FROM public.profiles AS p WHERE p.id = v_user_id;
  v_actor := COALESCE(v_actor, v_user_id::text);

  SELECT array_agg((item.value ->> 'product_id')::uuid ORDER BY (item.value ->> 'product_id')::uuid),
         count(*)::integer
  INTO v_ids, v_expected_count
  FROM jsonb_array_elements(p_items) AS item(value);
  IF array_length(v_ids, 1) <> (SELECT count(DISTINCT id) FROM unnest(v_ids) AS ids(id)) THEN
    RAISE EXCEPTION 'A product can only be verified once per request';
  END IF;

  PERFORM p.id
  FROM public.products AS p
  WHERE p.id = ANY(v_ids) AND p.store_id = v_store_id
  ORDER BY p.id
  FOR UPDATE;
  GET DIAGNOSTICS v_locked_count = ROW_COUNT;
  IF v_locked_count <> v_expected_count THEN
    RAISE EXCEPTION 'One or more products do not belong to this store';
  END IF;

  FOR v_item IN
    SELECT item.value FROM jsonb_array_elements(p_items) AS item(value)
    ORDER BY (item.value ->> 'product_id')::uuid
  LOOP
    SELECT p.* INTO v_product
    FROM public.products AS p
    WHERE p.id = (v_item ->> 'product_id')::uuid AND p.store_id = v_store_id;

    v_physical := (v_item ->> 'physical_quantity')::numeric;
    IF v_physical IS NULL OR v_physical < 0 THEN
      RAISE EXCEPTION 'Physical quantity must be zero or greater';
    END IF;
    IF COALESCE(v_product.unit, '') !~*
      '^(kg|g|gram|grams|liter|litre|l|ml|meter|metre|m|cm|mm)$'
      AND v_physical <> trunc(v_physical) THEN
      RAISE EXCEPTION 'This product unit only accepts whole quantities';
    END IF;

    v_difference := v_physical - COALESCE(v_product.stock, 0);
    v_reason := NULLIF(btrim(v_item ->> 'reason'), '');
    v_details := NULLIF(btrim(v_item ->> 'reason_details'), '');
    IF length(COALESCE(v_details, '')) > 500 THEN
      RAISE EXCEPTION 'Custom reason is too long';
    END IF;
    IF v_difference <> 0 AND v_reason IS NULL THEN
      RAISE EXCEPTION 'A reason is required when the physical count differs';
    END IF;
    IF v_reason IS NOT NULL AND v_reason NOT IN (
      'physical_stock_correction', 'damaged_products', 'expired_products',
      'lost_missing_products', 'found_extra_stock', 'opening_stock_correction',
      'internal_stock_correction', 'other'
    ) THEN
      RAISE EXCEPTION 'Select a valid stock reconciliation reason';
    END IF;
    IF v_reason = 'other' AND v_details IS NULL THEN
      RAISE EXCEPTION 'A custom reason is required when Other is selected';
    END IF;

    INSERT INTO public.stock_reconciliations (
      product_id, system_quantity, physical_quantity, difference, status,
      reason, reason_details, checked_by, checked_by_user_id, checked_at, store_id
    ) VALUES (
      v_product.id, COALESCE(v_product.stock, 0), v_physical, v_difference,
      CASE WHEN v_difference = 0 THEN 'CHECKED' ELSE 'DIFFERENCE_FOUND' END,
      v_reason, v_details, v_actor, v_user_id, clock_timestamp(), v_store_id
    );
    v_inserted := v_inserted + 1;
  END LOOP;

  RETURN v_inserted;
END;
$$;
REVOKE ALL ON FUNCTION public.record_stock_reconciliations(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_stock_reconciliations(jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
