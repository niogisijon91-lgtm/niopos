CREATE SEQUENCE IF NOT EXISTS public.sale_return_invoice_number_seq AS bigint;

DO $$
DECLARE
  v_next_number numeric;
BEGIN
  SELECT COALESCE(MAX(invoice_number::numeric), 0) + 1
  INTO v_next_number
  FROM public.sale_returns
  WHERE invoice_number ~ '^[0-9]+$';

  IF v_next_number > 9223372036854775807 THEN
    RAISE EXCEPTION 'Existing numeric sales return invoice numbers exceed the supported range';
  END IF;

  PERFORM setval(
    'public.sale_return_invoice_number_seq',
    v_next_number::bigint,
    false
  );
END;
$$;

REVOKE ALL ON SEQUENCE public.sale_return_invoice_number_seq FROM PUBLIC, anon, authenticated;

DO $$
DECLARE
  v_definition text;
  v_old_expression text := $pattern$v_invoice_number\s*:=\s*'RET-'\s*\|\|\s*upper\(substr\(replace\(gen_random_uuid\(\)::text,\s*'-',\s*''\),\s*1,\s*8\)\);$pattern$;
  v_new_expression_pattern text := $pattern$v_invoice_number\s*:=\s*nextval\('public\.sale_return_invoice_number_seq'\)::text;$pattern$;
  v_new_expression text := $replacement$v_invoice_number := nextval('public.sale_return_invoice_number_seq')::text;$replacement$;
BEGIN
  v_definition := pg_get_functiondef(
    'public.complete_sale_return(uuid,jsonb,text,uuid)'::regprocedure
  );

  IF v_definition ~ v_old_expression THEN
    EXECUTE regexp_replace(v_definition, v_old_expression, v_new_expression);
  ELSIF v_definition !~ v_new_expression_pattern THEN
    RAISE EXCEPTION 'Expected return invoice number expression was not found';
  END IF;
END;
$$;
