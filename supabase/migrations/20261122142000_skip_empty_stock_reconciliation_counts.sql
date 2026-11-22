BEGIN;

DO $migration$
BEGIN
  IF to_regclass('public.products') IS NULL
    OR to_regclass('public.stock_reconciliations') IS NULL
    OR to_regprocedure('public.perform_stock_adjustment(uuid, text, numeric, text, text, text, numeric, uuid, uuid, numeric)') IS NULL
    OR to_regprocedure('public.has_store_permission(text)') IS NULL
    OR to_regprocedure('public.get_my_store_id()') IS NULL THEN
    RAISE EXCEPTION 'Stock reconciliation requires the current atomic inventory schema';
  END IF;
END;
$migration$;

CREATE OR REPLACE FUNCTION public.record_stock_reconciliations(p_items jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $function$
DECLARE
  v_store_id uuid;
  v_user_id uuid := auth.uid();
  v_all_ids uuid[];
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
  v_reconciliation_id uuid;
  v_inserted integer := 0;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication is required' USING ERRCODE = '42501';
  END IF;
  IF NOT public.has_store_permission('stock_reconciliation.create') THEN
    RAISE EXCEPTION 'Stock reconciliation permission is required' USING ERRCODE = '42501';
  END IF;
  IF p_items IS NULL OR pg_catalog.jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Stock counts must be supplied as an array';
  END IF;
  IF pg_catalog.jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'Provide no more than 500 stock counts';
  END IF;
  IF pg_catalog.jsonb_array_length(p_items) = 0 THEN
    RETURN 0;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements(p_items) AS item(value)
    WHERE pg_catalog.jsonb_typeof(item.value) IS DISTINCT FROM 'object'
      OR NULLIF(pg_catalog.btrim(item.value ->> 'product_id'), '') IS NULL
  ) THEN
    RAISE EXCEPTION 'Every stock count must include a product ID';
  END IF;

  SELECT pg_catalog.array_agg((item.value ->> 'product_id')::uuid
           ORDER BY (item.value ->> 'product_id')::uuid)
  INTO v_all_ids
  FROM pg_catalog.jsonb_array_elements(p_items) AS item(value);
  IF pg_catalog.array_length(v_all_ids, 1) <> (
    SELECT pg_catalog.count(DISTINCT id)
    FROM pg_catalog.unnest(v_all_ids) AS ids(id)
  ) THEN
    RAISE EXCEPTION 'A product can only be verified once per request';
  END IF;

  SELECT pg_catalog.array_agg((item.value ->> 'product_id')::uuid
           ORDER BY (item.value ->> 'product_id')::uuid),
         pg_catalog.count(*)::integer
  INTO v_ids, v_expected_count
  FROM pg_catalog.jsonb_array_elements(p_items) AS item(value)
  WHERE NULLIF(pg_catalog.btrim(item.value ->> 'physical_quantity'), '') IS NOT NULL;

  IF COALESCE(v_expected_count, 0) = 0 THEN
    RETURN 0;
  END IF;

  v_store_id := public.get_my_store_id();
  IF v_store_id IS NULL THEN
    RAISE EXCEPTION 'Store is required' USING ERRCODE = '42501';
  END IF;
  SELECT COALESCE(NULLIF(pg_catalog.btrim(profile.full_name), ''), profile.email)
  INTO v_actor
  FROM public.profiles AS profile
  WHERE profile.id = v_user_id;
  v_actor := COALESCE(v_actor, v_user_id::text);

  PERFORM product.id
  FROM public.products AS product
  WHERE product.id = ANY(v_ids)
    AND product.store_id = v_store_id
  ORDER BY product.id
  FOR UPDATE;
  GET DIAGNOSTICS v_locked_count = ROW_COUNT;
  IF v_locked_count <> v_expected_count THEN
    RAISE EXCEPTION 'One or more products do not belong to this store';
  END IF;

  FOR v_item IN
    SELECT item.value
    FROM pg_catalog.jsonb_array_elements(p_items) AS item(value)
    WHERE NULLIF(pg_catalog.btrim(item.value ->> 'physical_quantity'), '') IS NOT NULL
    ORDER BY (item.value ->> 'product_id')::uuid
  LOOP
    SELECT product.*
    INTO v_product
    FROM public.products AS product
    WHERE product.id = (v_item ->> 'product_id')::uuid
      AND product.store_id = v_store_id;

    v_physical := NULLIF(pg_catalog.btrim(v_item ->> 'physical_quantity'), '')::numeric;
    IF v_physical < 0 THEN
      RAISE EXCEPTION 'Physical quantity must be zero or greater';
    END IF;
    IF COALESCE(v_product.unit, '') !~*
      '^(kg|g|gram|grams|liter|litre|l|ml|meter|metre|m|cm|mm)$'
      AND v_physical <> pg_catalog.trunc(v_physical) THEN
      RAISE EXCEPTION 'This product unit only accepts whole quantities';
    END IF;

    v_difference := v_physical - COALESCE(v_product.stock, 0);
    v_reason := NULLIF(pg_catalog.btrim(v_item ->> 'reason'), '');
    v_details := NULLIF(pg_catalog.btrim(v_item ->> 'reason_details'), '');
    IF pg_catalog.length(COALESCE(v_details, '')) > 500 THEN
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

    IF v_difference <> 0 THEN
      IF NOT public.has_store_permission('stock_reconciliation.edit') THEN
        RAISE EXCEPTION 'Stock reconciliation edit permission is required'
          USING ERRCODE = '42501';
      END IF;
      IF v_difference > 0
        AND NOT public.has_store_permission('actions.adjust_stock_increase') THEN
        RAISE EXCEPTION 'Stock increase permission is required' USING ERRCODE = '42501';
      END IF;
      IF v_difference < 0
        AND NOT public.has_store_permission('actions.adjust_stock_decrease') THEN
        RAISE EXCEPTION 'Stock decrease permission is required' USING ERRCODE = '42501';
      END IF;
    END IF;

    INSERT INTO public.stock_reconciliations (
      product_id, system_quantity, physical_quantity, difference, status,
      reason, reason_details, checked_by, checked_by_user_id, checked_at, store_id
    ) VALUES (
      v_product.id, COALESCE(v_product.stock, 0), v_physical, v_difference,
      CASE WHEN v_difference = 0 THEN 'CHECKED' ELSE 'DIFFERENCE_FOUND' END,
      v_reason, v_details, v_actor, v_user_id, pg_catalog.clock_timestamp(), v_store_id
    )
    RETURNING id INTO v_reconciliation_id;

    IF v_difference <> 0 THEN
      PERFORM public.perform_stock_adjustment(
        v_product.id,
        'set_actual',
        v_physical,
        v_reason,
        v_details,
        NULL,
        COALESCE(v_product.stock, 0),
        v_reconciliation_id,
        v_reconciliation_id,
        NULL
      );
    END IF;

    v_inserted := v_inserted + 1;
  END LOOP;

  RETURN v_inserted;
END;
$function$;

REVOKE ALL ON FUNCTION public.record_stock_reconciliations(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_stock_reconciliations(jsonb) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
