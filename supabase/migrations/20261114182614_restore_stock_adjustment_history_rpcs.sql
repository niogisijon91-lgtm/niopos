BEGIN;

INSERT INTO public.rbac_permission_catalog (permission_key, module_key, action_key, sort_order)
VALUES ('actions.view_stock_value', 'actions', 'view_stock_value', 215)
ON CONFLICT (permission_key) DO NOTHING;

UPDATE public.roles
SET permissions = COALESCE(permissions, '{}'::jsonb) || '{"actions.view_stock_value":true}'::jsonb
WHERE role_key IN ('admin', 'accountant');

ALTER TABLE public.stock_adjustments
  ADD COLUMN IF NOT EXISTS adjustment_type text,
  ADD COLUMN IF NOT EXISTS quantity numeric,
  ADD COLUMN IF NOT EXISTS unit text,
  ADD COLUMN IF NOT EXISTS product_name text,
  ADD COLUMN IF NOT EXISTS sku text,
  ADD COLUMN IF NOT EXISTS barcode text,
  ADD COLUMN IF NOT EXISTS notes text,
  ADD COLUMN IF NOT EXISTS adjusted_by_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS idempotency_key uuid,
  ADD COLUMN IF NOT EXISTS value_impact numeric;

UPDATE public.stock_adjustments AS sa
SET quantity = COALESCE(sa.quantity, abs(sa.difference)),
    adjustment_type = COALESCE(sa.adjustment_type,
      CASE WHEN sa.reconciliation_id IS NOT NULL THEN 'set_actual'
           WHEN sa.difference > 0 THEN 'increase' ELSE 'decrease' END),
    product_name = COALESCE(sa.product_name, p.name),
    sku = COALESCE(sa.sku, p.sku),
    barcode = COALESCE(sa.barcode, p.barcode),
    unit = COALESCE(sa.unit, p.unit)
FROM public.products AS p
WHERE p.id = sa.product_id
  AND (sa.quantity IS NULL OR sa.adjustment_type IS NULL OR sa.product_name IS NULL
       OR sa.sku IS NULL OR sa.barcode IS NULL OR sa.unit IS NULL);

INSERT INTO public.stock_adjustments (
  product_id, previous_quantity, new_quantity, difference, reason,
  adjusted_by, adjusted_at, store_id, adjustment_type, quantity, unit,
  product_name, sku, barcode, notes, adjusted_by_user_id, idempotency_key,
  value_impact
)
SELECT sm.product_id, sm.previous_stock, sm.new_stock,
       sm.new_stock - sm.previous_stock, 'physical_stock_correction',
       COALESCE(p.full_name, sm.performed_by::text, 'system'), sm.created_at,
       sm.store_id,
       CASE WHEN sm.new_stock > sm.previous_stock THEN 'increase' ELSE 'decrease' END,
       abs(sm.new_stock - sm.previous_stock), product.unit, product.name,
       product.sku, product.barcode, sm.note, sm.performed_by, sm.id,
       (sm.new_stock - sm.previous_stock)
         * COALESCE(sm.purchase_price, product.cost_price, 0)
FROM public.stock_movements AS sm
JOIN public.products AS product
  ON product.id = sm.product_id AND product.store_id = sm.store_id
LEFT JOIN public.profiles AS p ON p.id = sm.performed_by
WHERE sm.previous_stock IS NOT NULL AND sm.new_stock IS NOT NULL
  AND sm.store_id IS NOT NULL AND sm.new_stock <> sm.previous_stock
  AND (sm.reference = 'Manual Stock Adjustment'
    OR (sm.type = 'opening' AND sm.reference = 'Opening Stock'))
  AND NOT EXISTS (
    SELECT 1 FROM public.stock_adjustments existing
    WHERE existing.store_id = sm.store_id AND existing.idempotency_key = sm.id
  )
ON CONFLICT DO NOTHING;

CREATE UNIQUE INDEX IF NOT EXISTS stock_adjustments_store_idempotency_key
  ON public.stock_adjustments (store_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS stock_adjustments_store_adjusted_at_idx
  ON public.stock_adjustments (store_id, adjusted_at DESC);
CREATE INDEX IF NOT EXISTS stock_adjustments_store_product_idx
  ON public.stock_adjustments (store_id, product_id, adjusted_at DESC);
CREATE INDEX IF NOT EXISTS stock_adjustments_store_actor_idx
  ON public.stock_adjustments (store_id, adjusted_by_user_id, adjusted_at DESC);

CREATE OR REPLACE FUNCTION public.get_stock_adjustment_history(
  p_from timestamptz DEFAULT NULL,
  p_to timestamptz DEFAULT NULL,
  p_adjustment_type text DEFAULT NULL,
  p_employee_id uuid DEFAULT NULL,
  p_reason text DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_offset integer DEFAULT 0,
  p_limit integer DEFAULT 25
)
RETURNS TABLE (
  id uuid, adjusted_at timestamptz, product_id uuid, product_name text, sku text,
  barcode text, previous_quantity numeric, adjustment_type text, quantity numeric,
  new_quantity numeric, difference numeric, unit text, reason text,
  reason_details text, notes text, adjusted_by_user_id uuid, adjusted_by text,
  value_impact numeric, total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
BEGIN
  IF NOT (public.has_store_permission('stock_reconciliation.view')
          OR public.has_store_permission('inventory.view')) THEN
    RAISE EXCEPTION 'Stock adjustment history permission is required'
      USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_offset IS NULL OR p_limit < 1 OR p_limit > 500 OR p_offset < 0 THEN
    RAISE EXCEPTION 'Invalid history pagination';
  END IF;

  RETURN QUERY
  SELECT sa.id, sa.adjusted_at, sa.product_id, sa.product_name, sa.sku,
         sa.barcode, sa.previous_quantity, sa.adjustment_type, sa.quantity,
         sa.new_quantity, sa.difference, sa.unit, sa.reason, sa.reason_details,
         sa.notes, sa.adjusted_by_user_id, sa.adjusted_by,
         CASE WHEN public.has_store_permission('actions.view_stock_value')
           THEN sa.value_impact ELSE NULL END,
         count(*) OVER ()
  FROM public.stock_adjustments AS sa
  WHERE sa.store_id = public.get_my_store_id()
    AND (p_from IS NULL OR sa.adjusted_at >= p_from)
    AND (p_to IS NULL OR sa.adjusted_at < p_to)
    AND (p_adjustment_type IS NULL OR sa.adjustment_type = p_adjustment_type)
    AND (p_employee_id IS NULL OR sa.adjusted_by_user_id = p_employee_id)
    AND (p_reason IS NULL OR sa.reason = p_reason)
    AND (p_search IS NULL OR p_search = ''
      OR sa.product_name ILIKE '%' || p_search || '%'
      OR sa.sku ILIKE '%' || p_search || '%'
      OR sa.barcode ILIKE '%' || p_search || '%')
  ORDER BY sa.adjusted_at DESC, sa.id DESC
  OFFSET p_offset LIMIT p_limit;
END;
$$;
REVOKE ALL ON FUNCTION public.get_stock_adjustment_history(
  timestamptz, timestamptz, text, uuid, text, text, integer, integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_stock_adjustment_history(
  timestamptz, timestamptz, text, uuid, text, text, integer, integer
) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_stock_adjustment_export(
  p_from timestamptz DEFAULT NULL,
  p_to timestamptz DEFAULT NULL,
  p_adjustment_type text DEFAULT NULL,
  p_employee_id uuid DEFAULT NULL,
  p_reason text DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_offset integer DEFAULT 0,
  p_limit integer DEFAULT 500
)
RETURNS TABLE (
  id uuid, adjusted_at timestamptz, product_id uuid, product_name text, sku text,
  barcode text, previous_quantity numeric, adjustment_type text, quantity numeric,
  new_quantity numeric, difference numeric, unit text, reason text,
  reason_details text, notes text, adjusted_by_user_id uuid, adjusted_by text,
  value_impact numeric, total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
BEGIN
  IF NOT public.has_store_permission('stock_reconciliation.export') THEN
    RAISE EXCEPTION 'Stock adjustment export permission is required'
      USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT * FROM public.get_stock_adjustment_history(
    p_from, p_to, p_adjustment_type, p_employee_id, p_reason, p_search, p_offset, p_limit
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_stock_adjustment_export(
  timestamptz, timestamptz, text, uuid, text, text, integer, integer
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_stock_adjustment_export(
  timestamptz, timestamptz, text, uuid, text, text, integer, integer
) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_stock_adjustment_report(
  p_from timestamptz DEFAULT NULL,
  p_to timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE
  v_rows jsonb;
  v_value_allowed boolean;
BEGIN
  IF NOT (public.has_store_permission('stock_reconciliation.view')
          OR public.has_store_permission('inventory.view')) THEN
    RAISE EXCEPTION 'Stock adjustment report permission is required'
      USING ERRCODE = '42501';
  END IF;
  v_value_allowed := public.has_store_permission('actions.view_stock_value');

  WITH filtered AS (
    SELECT sa.* FROM public.stock_adjustments AS sa
    WHERE sa.store_id = public.get_my_store_id()
      AND (p_from IS NULL OR sa.adjusted_at >= p_from)
      AND (p_to IS NULL OR sa.adjusted_at < p_to)
  )
  SELECT jsonb_build_object(
    'total_adjustments', count(*),
    'total_increased', COALESCE(sum(abs(difference)) FILTER (WHERE difference > 0), 0),
    'total_decreased', COALESCE(sum(abs(difference)) FILTER (WHERE difference < 0), 0),
    'total_value_impact', CASE WHEN v_value_allowed THEN COALESCE(sum(value_impact), 0) ELSE NULL END,
    'by_product', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'product_id', g.product_id, 'product_name', g.product_name, 'sku', g.sku,
        'count', g.adjustment_count, 'increased', g.increased, 'decreased', g.decreased
      ) ORDER BY g.adjustment_count DESC, g.product_name)
      FROM (
        SELECT product_id, max(product_name) product_name, max(sku) sku, count(*) adjustment_count,
          COALESCE(sum(abs(difference)) FILTER (WHERE difference > 0), 0) increased,
          COALESCE(sum(abs(difference)) FILTER (WHERE difference < 0), 0) decreased
        FROM filtered GROUP BY product_id
      ) g
    ), '[]'::jsonb),
    'by_employee', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'user_id', g.adjusted_by_user_id, 'name', g.adjusted_by, 'count', g.adjustment_count,
        'increased', g.increased, 'decreased', g.decreased
      ) ORDER BY g.adjustment_count DESC, g.adjusted_by)
      FROM (
        SELECT adjusted_by_user_id, max(adjusted_by) adjusted_by, count(*) adjustment_count,
          COALESCE(sum(abs(difference)) FILTER (WHERE difference > 0), 0) increased,
          COALESCE(sum(abs(difference)) FILTER (WHERE difference < 0), 0) decreased
        FROM filtered GROUP BY adjusted_by_user_id
      ) g
    ), '[]'::jsonb),
    'by_reason', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'reason', g.reason, 'count', g.adjustment_count,
        'increased', g.increased, 'decreased', g.decreased
      ) ORDER BY g.adjustment_count DESC, g.reason)
      FROM (
        SELECT reason, count(*) adjustment_count,
          COALESCE(sum(abs(difference)) FILTER (WHERE difference > 0), 0) increased,
          COALESCE(sum(abs(difference)) FILTER (WHERE difference < 0), 0) decreased
        FROM filtered GROUP BY reason
      ) g
    ), '[]'::jsonb)
  ) INTO v_rows FROM filtered;
  RETURN v_rows;
END;
$$;
REVOKE ALL ON FUNCTION public.get_stock_adjustment_report(timestamptz, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_stock_adjustment_report(timestamptz, timestamptz)
  TO authenticated;

COMMIT;
