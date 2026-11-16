BEGIN;

DO $migration$
BEGIN
  IF to_regclass('public.sales') IS NULL
    OR to_regclass('public.stores') IS NULL
    OR to_regprocedure('public.get_my_store_id()') IS NULL
    OR to_regprocedure('public.has_store_permission(text)') IS NULL
    OR to_regprocedure('public.complete_pos_sale_internal(jsonb, uuid, numeric, text, numeric, uuid)') IS NULL
    OR to_regprocedure('public.complete_pos_sale(jsonb, uuid, numeric, text, numeric, uuid)') IS NULL THEN
    RAISE EXCEPTION 'POS sale idempotency requires the current tenant-scoped POS schema';
  END IF;
END;
$migration$;

CREATE TABLE public.pos_sale_idempotency (
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  idempotency_key uuid NOT NULL,
  request_payload jsonb NOT NULL,
  sale_id uuid REFERENCES public.sales(id) ON DELETE RESTRICT,
  response_payload jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_id, idempotency_key),
  CONSTRAINT pos_sale_idempotency_completion_check
    CHECK ((sale_id IS NULL) = (response_payload IS NULL))
);

ALTER TABLE public.pos_sale_idempotency ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pos_sale_idempotency FROM PUBLIC, anon, authenticated;
CREATE POLICY pos_sale_idempotency_store_isolation
  ON public.pos_sale_idempotency
  FOR ALL TO authenticated
  USING (store_id = (SELECT public.get_my_store_id()))
  WITH CHECK (store_id = (SELECT public.get_my_store_id()));

CREATE FUNCTION public.complete_pos_sale(
  p_cart jsonb,
  p_customer_id uuid,
  p_discount numeric,
  p_payment_method text,
  p_paid_amount numeric,
  p_idempotency_key uuid,
  p_offer_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $function$
DECLARE
  v_store_id uuid;
  v_request jsonb;
  v_sale_id uuid;
  v_response jsonb;
  v_existing public.pos_sale_idempotency%ROWTYPE;
  v_updated_rows integer;
BEGIN
  IF public.has_store_permission('pos.create') IS DISTINCT FROM true
    OR public.has_store_permission('sales.create') IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'POS sales permission is required'
      USING ERRCODE = '42501';
  END IF;

  v_store_id := public.get_my_store_id();
  IF v_store_id IS NULL THEN
    RAISE EXCEPTION 'An approved store account is required'
      USING ERRCODE = '42501';
  END IF;

  IF p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'A sale idempotency key is required'
      USING ERRCODE = '22023';
  END IF;

  v_request := pg_catalog.jsonb_build_object(
    'cart', p_cart,
    'customer_id', p_customer_id,
    'discount', p_discount,
    'payment_method', p_payment_method,
    'paid_amount', p_paid_amount,
    'offer_id', p_offer_id
  );

  INSERT INTO public.pos_sale_idempotency (store_id, idempotency_key, request_payload)
  VALUES (v_store_id, p_idempotency_key, v_request)
  ON CONFLICT (store_id, idempotency_key) DO NOTHING;

  IF NOT FOUND THEN
    SELECT *
    INTO v_existing
    FROM public.pos_sale_idempotency
    WHERE store_id = v_store_id
      AND idempotency_key = p_idempotency_key;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Sale idempotency record could not be loaded';
    END IF;
    IF v_existing.request_payload IS DISTINCT FROM v_request THEN
      RAISE EXCEPTION 'Sale idempotency key was already used for a different request'
        USING ERRCODE = '22023';
    END IF;
    IF v_existing.sale_id IS NULL OR v_existing.response_payload IS NULL THEN
      RAISE EXCEPTION 'Sale idempotency record is incomplete'
        USING ERRCODE = '55000';
    END IF;

    RETURN v_existing.response_payload;
  END IF;

  v_response := public.complete_pos_sale(
    p_cart,
    p_customer_id,
    p_discount,
    p_payment_method,
    p_paid_amount,
    p_offer_id
  );
  v_sale_id := NULLIF(v_response ->> 'id', '')::uuid;

  IF v_sale_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.sales
    WHERE id = v_sale_id
      AND store_id = v_store_id
  ) THEN
    RAISE EXCEPTION 'POS sale did not return a sale in the current store';
  END IF;

  UPDATE public.pos_sale_idempotency
  SET sale_id = v_sale_id,
      response_payload = v_response
  WHERE store_id = v_store_id
    AND idempotency_key = p_idempotency_key
    AND sale_id IS NULL
    AND response_payload IS NULL;

  GET DIAGNOSTICS v_updated_rows = ROW_COUNT;
  IF v_updated_rows <> 1 THEN
    RAISE EXCEPTION 'Sale idempotency record could not be completed';
  END IF;

  RETURN v_response;
END;
$function$;

REVOKE ALL ON FUNCTION public.complete_pos_sale(jsonb, uuid, numeric, text, numeric, uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_pos_sale(jsonb, uuid, numeric, text, numeric, uuid, uuid)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
