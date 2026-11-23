ALTER TABLE public.supplier_payments
  ADD COLUMN IF NOT EXISTS purchase_id uuid
    REFERENCES public.purchases(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS reference_number text,
  ADD COLUMN IF NOT EXISTS applied_to_previous_due boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS idempotency_key uuid;

CREATE INDEX IF NOT EXISTS supplier_payments_purchase_idx
  ON public.supplier_payments (purchase_id, payment_date DESC)
  WHERE purchase_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS supplier_payments_store_idempotency_uidx
  ON public.supplier_payments (store_id, idempotency_key)
  WHERE store_id IS NOT NULL AND idempotency_key IS NOT NULL;

CREATE OR REPLACE FUNCTION public.collect_supplier_due_payment(
  p_supplier_id uuid,
  p_purchase_id uuid,
  p_amount numeric,
  p_payment_method text,
  p_payment_date date,
  p_reference_number text,
  p_note text,
  p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE
  v_user_id uuid := (SELECT auth.uid());
  v_store_id uuid;
  v_supplier public.suppliers%ROWTYPE;
  v_purchase public.purchases%ROWTYPE;
  v_payment public.supplier_payments%ROWTYPE;
  v_remaining_due numeric;
  v_unallocated_paid numeric;
BEGIN
  v_store_id := (SELECT public.get_my_store_id());
  IF v_user_id IS NULL OR v_store_id IS NULL
    OR NOT (SELECT public.has_store_permission('purchases')) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'supplier_payment_permission_denied';
  END IF;

  IF p_supplier_id IS NULL
    OR p_amount IS NULL
    OR p_amount <= 0
    OR p_amount <> round(p_amount, 2)
    OR p_payment_method IS NULL
    OR p_payment_method NOT IN ('cash', 'card', 'mobile', 'bank')
    OR p_payment_date IS NULL
    OR p_idempotency_key IS NULL
    OR length(COALESCE(p_reference_number, '')) > 120
    OR length(COALESCE(p_note, '')) > 1000 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'supplier_payment_invalid_request';
  END IF;

  IF p_purchase_id IS NOT NULL THEN
    SELECT purchase.*
    INTO v_purchase
    FROM public.purchases AS purchase
    WHERE purchase.id = p_purchase_id
      AND purchase.store_id = v_store_id
      AND purchase.supplier_id = p_supplier_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'supplier_payment_invoice_not_found';
    END IF;
  ELSE
    SELECT supplier.*
    INTO v_supplier
    FROM public.suppliers AS supplier
    WHERE supplier.id = p_supplier_id
      AND supplier.store_id = v_store_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'supplier_payment_supplier_not_found';
    END IF;
  END IF;

  SELECT payment.*
  INTO v_payment
  FROM public.supplier_payments AS payment
  WHERE payment.store_id = v_store_id
    AND payment.idempotency_key = p_idempotency_key;

  IF FOUND THEN
    IF v_payment.supplier_id IS DISTINCT FROM p_supplier_id
      OR v_payment.purchase_id IS DISTINCT FROM p_purchase_id
      OR v_payment.amount IS DISTINCT FROM p_amount
      OR v_payment.payment_method IS DISTINCT FROM p_payment_method
      OR v_payment.payment_date::date IS DISTINCT FROM p_payment_date
      OR v_payment.applied_to_previous_due IS DISTINCT FROM (p_purchase_id IS NULL)
      OR v_payment.reference_number IS DISTINCT FROM NULLIF(btrim(p_reference_number), '')
      OR v_payment.note IS DISTINCT FROM NULLIF(btrim(p_note), '') THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'supplier_payment_duplicate_request';
    END IF;
  ELSE
    IF p_purchase_id IS NOT NULL THEN
      IF v_purchase.status = 'cancelled' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'supplier_payment_invoice_cancelled';
      END IF;
      v_remaining_due := GREATEST(COALESCE(v_purchase.due_amount, 0), 0);
    ELSE
      SELECT COALESCE(SUM(payment.amount), 0)
      INTO v_unallocated_paid
      FROM public.supplier_payments AS payment
      WHERE payment.store_id = v_store_id
        AND payment.supplier_id = p_supplier_id
        AND payment.applied_to_previous_due;

      v_remaining_due := GREATEST(
        COALESCE(v_supplier.previous_due, 0) - v_unallocated_paid,
        0
      );
    END IF;

    IF p_amount > v_remaining_due THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'supplier_payment_exceeds_remaining_due';
    END IF;

    INSERT INTO public.supplier_payments (
      supplier_id, purchase_id, amount, payment_date, payment_method,
      reference_number, applied_to_previous_due, note, store_id, idempotency_key
    ) VALUES (
      p_supplier_id, p_purchase_id, p_amount, p_payment_date::timestamptz,
      p_payment_method, NULLIF(btrim(p_reference_number), ''), p_purchase_id IS NULL,
      NULLIF(btrim(p_note), ''), v_store_id, p_idempotency_key
    )
    ON CONFLICT (store_id, idempotency_key)
      WHERE store_id IS NOT NULL AND idempotency_key IS NOT NULL
      DO NOTHING
    RETURNING * INTO v_payment;

    IF NOT FOUND THEN
      SELECT payment.*
      INTO v_payment
      FROM public.supplier_payments AS payment
      WHERE payment.store_id = v_store_id
        AND payment.idempotency_key = p_idempotency_key;

      IF NOT FOUND
        OR v_payment.supplier_id IS DISTINCT FROM p_supplier_id
        OR v_payment.purchase_id IS DISTINCT FROM p_purchase_id
        OR v_payment.amount IS DISTINCT FROM p_amount
        OR v_payment.payment_method IS DISTINCT FROM p_payment_method
        OR v_payment.payment_date::date IS DISTINCT FROM p_payment_date
        OR v_payment.applied_to_previous_due IS DISTINCT FROM (p_purchase_id IS NULL)
        OR v_payment.reference_number IS DISTINCT FROM NULLIF(btrim(p_reference_number), '')
        OR v_payment.note IS DISTINCT FROM NULLIF(btrim(p_note), '') THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'supplier_payment_duplicate_request';
      END IF;
    ELSE
      IF p_purchase_id IS NOT NULL THEN
        UPDATE public.purchases
        SET paid_amount = LEAST(
              COALESCE(total, 0),
              COALESCE(paid_amount, 0) + p_amount
            ),
            due_amount = GREATEST(COALESCE(due_amount, 0) - p_amount, 0),
            payment_status = CASE
              WHEN GREATEST(COALESCE(due_amount, 0) - p_amount, 0) = 0 THEN 'paid'
              ELSE 'partial'
            END
        WHERE id = p_purchase_id
          AND store_id = v_store_id;
      END IF;

      UPDATE public.suppliers
      SET total_paid = COALESCE(total_paid, 0) + p_amount,
          total_due = GREATEST(COALESCE(total_due, 0) - p_amount, 0)
      WHERE id = p_supplier_id
        AND store_id = v_store_id;
    END IF;
  END IF;

  IF p_purchase_id IS NOT NULL THEN
    SELECT GREATEST(COALESCE(purchase.due_amount, 0), 0)
    INTO v_remaining_due
    FROM public.purchases AS purchase
    WHERE purchase.id = p_purchase_id
      AND purchase.store_id = v_store_id;
  ELSE
    SELECT GREATEST(
      COALESCE(supplier.previous_due, 0) - COALESCE(SUM(payment.amount), 0),
      0
    )
    INTO v_remaining_due
    FROM public.suppliers AS supplier
    LEFT JOIN public.supplier_payments AS payment
      ON payment.supplier_id = supplier.id
     AND payment.store_id = v_store_id
     AND payment.applied_to_previous_due
    WHERE supplier.id = p_supplier_id
      AND supplier.store_id = v_store_id
    GROUP BY supplier.previous_due;
  END IF;

  RETURN jsonb_build_object(
    'id', v_payment.id,
    'purchase_id', p_purchase_id,
    'amount', v_payment.amount,
    'remaining_due', COALESCE(v_remaining_due, 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.collect_supplier_due_payment(
  uuid, uuid, numeric, text, date, text, text, uuid
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.collect_supplier_due_payment(
  uuid, uuid, numeric, text, date, text, text, uuid
) TO authenticated;

NOTIFY pgrst, 'reload schema';