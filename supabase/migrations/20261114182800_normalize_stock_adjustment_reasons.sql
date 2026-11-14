-- Deployed to Supabase as migration 20261114182800.
BEGIN;

UPDATE public.stock_adjustments AS sa
SET reason = CASE sm.reason
  WHEN 'Opening Stock' THEN 'opening_stock_correction'
  WHEN 'Damaged Product' THEN 'damaged_products'
  WHEN 'Expired Product' THEN 'expired_products'
  WHEN 'Lost / Missing' THEN 'lost_missing_products'
  WHEN 'Other' THEN 'other'
  WHEN 'Manual Adjustment' THEN 'physical_stock_correction'
  ELSE 'physical_stock_correction'
END
FROM public.stock_movements AS sm
WHERE sa.store_id = sm.store_id
  AND sa.idempotency_key = sm.id
  AND (sm.reference = 'Manual Stock Adjustment'
    OR (sm.type = 'opening' AND sm.reference = 'Opening Stock'));

COMMIT;
