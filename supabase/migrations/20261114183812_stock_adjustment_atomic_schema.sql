BEGIN;

DO $$
BEGIN
  IF to_regclass('public.products') IS NULL
    OR to_regclass('public.stock_movements') IS NULL
    OR to_regclass('public.stock_adjustments') IS NULL
    OR to_regclass('public.stock_reconciliations') IS NULL
    OR to_regprocedure('public.has_store_permission(text)') IS NULL THEN
    RAISE EXCEPTION 'Stock reconciliation requires inventory and RBAC migrations';
  END IF;
END;
$$;

INSERT INTO public.rbac_permission_catalog (permission_key, module_key, action_key, sort_order)
VALUES ('actions.view_stock_value', 'actions', 'view_stock_value', 215)
ON CONFLICT (permission_key) DO NOTHING;

UPDATE public.roles
SET permissions = COALESCE(permissions, '{}'::jsonb) || '{"actions.view_stock_value":true}'::jsonb
WHERE role_key IN ('store_owner', 'admin', 'accountant');

CREATE OR REPLACE FUNCTION public.get_dashboard_inventory_totals()
RETURNS TABLE (stock_quantity numeric, stock_value numeric)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT
    COALESCE(sum(COALESCE(p.stock, 0)), 0)::numeric,
    CASE WHEN public.has_store_permission('actions.view_stock_value')
      THEN COALESCE(
        sum(COALESCE(p.stock, 0) * COALESCE(p.cost_price, 0))
          FILTER (WHERE p.status = 'active' AND NOT COALESCE(p.is_deleted, false)),
        0
      )::numeric
      ELSE NULL::numeric
    END
  FROM public.products AS p
  WHERE p.store_id = public.get_my_store_id();
$$;
REVOKE ALL ON FUNCTION public.get_dashboard_inventory_totals() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_dashboard_inventory_totals() TO authenticated;

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

ALTER TABLE public.stock_movements
  ADD COLUMN IF NOT EXISTS idempotency_key uuid,
  ADD COLUMN IF NOT EXISTS stock_adjustment_id uuid
    REFERENCES public.stock_adjustments(id) ON DELETE RESTRICT;

ALTER TABLE public.stock_reconciliations
  ADD COLUMN IF NOT EXISTS checked_by_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

UPDATE public.stock_movements AS sm
SET idempotency_key = COALESCE(sm.idempotency_key, sm.id),
    stock_adjustment_id = COALESCE(
      sm.stock_adjustment_id,
      (SELECT sa.id FROM public.stock_adjustments AS sa
       WHERE sa.store_id = sm.store_id AND sa.idempotency_key = sm.id LIMIT 1)
    )
WHERE sm.store_id IS NOT NULL
  AND (sm.reference = 'Manual Stock Adjustment'
    OR (sm.type = 'opening' AND sm.reference = 'Opening Stock'));

CREATE UNIQUE INDEX IF NOT EXISTS stock_movements_store_idempotency_key
  ON public.stock_movements (store_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS stock_adjustments_store_adjusted_at_idx
  ON public.stock_adjustments (store_id, adjusted_at DESC);
CREATE INDEX IF NOT EXISTS stock_adjustments_store_product_idx
  ON public.stock_adjustments (store_id, product_id, adjusted_at DESC);
CREATE INDEX IF NOT EXISTS stock_adjustments_store_actor_idx
  ON public.stock_adjustments (store_id, adjusted_by_user_id, adjusted_at DESC);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.stock_adjustments'::regclass
      AND conname = 'stock_adjustments_adjustment_type_check'
  ) THEN
    ALTER TABLE public.stock_adjustments
      ADD CONSTRAINT stock_adjustments_adjustment_type_check
      CHECK (adjustment_type IN ('increase', 'decrease', 'set_actual')) NOT VALID;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.stock_adjustments'::regclass
      AND conname = 'stock_adjustments_quantity_positive_check'
  ) THEN
    ALTER TABLE public.stock_adjustments
      ADD CONSTRAINT stock_adjustments_quantity_positive_check
      CHECK (quantity > 0) NOT VALID;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.stock_adjustments'::regclass
      AND conname = 'stock_adjustments_store_required_check'
  ) THEN
    ALTER TABLE public.stock_adjustments
      ADD CONSTRAINT stock_adjustments_store_required_check
      CHECK (store_id IS NOT NULL) NOT VALID;
  END IF;
END;
$$;

ALTER TABLE public.stock_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_adjustments FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.stock_adjustments FROM PUBLIC, anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.stock_reconciliations FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.prevent_product_delete_with_stock_history()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.stock_movements AS sm
    WHERE sm.product_id = OLD.id AND sm.store_id = OLD.store_id
  ) OR EXISTS (
    SELECT 1 FROM public.stock_adjustments AS sa
    WHERE sa.product_id = OLD.id AND sa.store_id = OLD.store_id
  ) OR EXISTS (
    SELECT 1 FROM public.stock_reconciliations AS sr
    WHERE sr.product_id = OLD.id AND sr.store_id = OLD.store_id
  ) THEN
    RAISE EXCEPTION 'Products with stock history must be archived, not deleted'
      USING ERRCODE = '23503';
  END IF;
  RETURN OLD;
END;
$$;
REVOKE ALL ON FUNCTION public.prevent_product_delete_with_stock_history()
  FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS products_prevent_stock_history_delete ON public.products;
CREATE TRIGGER products_prevent_stock_history_delete
  BEFORE DELETE ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.prevent_product_delete_with_stock_history();

NOTIFY pgrst, 'reload schema';
COMMIT;
