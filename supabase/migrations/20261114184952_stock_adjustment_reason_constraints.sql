BEGIN;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.stock_adjustments'::regclass
      AND conname='stock_adjustments_reason_check'
  ) THEN
    ALTER TABLE public.stock_adjustments
      ADD CONSTRAINT stock_adjustments_reason_check
      CHECK (reason IS NOT NULL AND reason IN (
        'physical_stock_correction','damaged_products','expired_products',
        'lost_missing_products','found_extra_stock','opening_stock_correction',
        'internal_stock_correction','other'
      )) NOT VALID;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.stock_adjustments'::regclass
      AND conname='stock_adjustments_other_reason_details_check'
  ) THEN
    ALTER TABLE public.stock_adjustments
      ADD CONSTRAINT stock_adjustments_other_reason_details_check
      CHECK (reason<>'other' OR NULLIF(btrim(reason_details),'') IS NOT NULL) NOT VALID;
  END IF;
END;
$$;
COMMIT;
