-- Run only against an isolated Supabase database after all migrations.
-- This transaction verifies same-key replay and rollback-safe effects. It does
-- not prove two-session concurrency or retry after a committed network timeout.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(52);

CREATE TEMP TABLE pos_sale_test_fixtures (
  owner_a uuid NOT NULL,
  owner_b uuid NOT NULL,
  store_a uuid,
  store_b uuid,
  product_a uuid NOT NULL,
  product_b uuid NOT NULL,
  customer_a uuid NOT NULL,
  customer_b uuid NOT NULL
);

INSERT INTO pos_sale_test_fixtures
VALUES (
  gen_random_uuid(), gen_random_uuid(), NULL, NULL,
  gen_random_uuid(), gen_random_uuid(),
  gen_random_uuid(), gen_random_uuid()
);

INSERT INTO auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
SELECT owner_a, '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated',
  owner_a::text || '@pos-idempotency.test', '',
  now(), '{"provider":"email","providers":["email"]}'::jsonb,
  '{"full_name":"POS Idempotency A","store_name":"POS Idempotency A"}'::jsonb,
  now(), now()
FROM pos_sale_test_fixtures
UNION ALL
SELECT owner_b, '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated',
  owner_b::text || '@pos-idempotency.test', '',
  now(), '{"provider":"email","providers":["email"]}'::jsonb,
  '{"full_name":"POS Idempotency B","store_name":"POS Idempotency B"}'::jsonb,
  now(), now()
FROM pos_sale_test_fixtures;

UPDATE public.profiles
SET role = 'store_owner', status = 'approved'
WHERE id IN (
  SELECT owner_a FROM pos_sale_test_fixtures
  UNION ALL
  SELECT owner_b FROM pos_sale_test_fixtures
);

UPDATE pos_sale_test_fixtures AS fixture
SET store_a = (SELECT store_id FROM public.profiles WHERE id = fixture.owner_a),
    store_b = (SELECT store_id FROM public.profiles WHERE id = fixture.owner_b);

INSERT INTO public.products (id, store_id, name, cost_price, selling_price, stock, status)
SELECT product_a, store_a, 'POS Idempotency Product A', 1, 2, 100, 'active'
FROM pos_sale_test_fixtures
UNION ALL
SELECT product_b, store_b, 'POS Idempotency Product B', 1, 2, 100, 'active'
FROM pos_sale_test_fixtures;

INSERT INTO public.customers (id, store_id, name)
SELECT customer_a, store_a, 'POS Idempotency Customer A'
FROM pos_sale_test_fixtures
UNION ALL
SELECT customer_b, store_b, 'POS Idempotency Customer B'
FROM pos_sale_test_fixtures;

CREATE TEMP TABLE pos_sale_test_attempts (
  label text PRIMARY KEY,
  payment_method text NOT NULL,
  paid_amount numeric NOT NULL,
  idempotency_key uuid NOT NULL DEFAULT gen_random_uuid(),
  response jsonb,
  replay_response jsonb
);

INSERT INTO pos_sale_test_attempts (label, payment_method, paid_amount)
VALUES
  ('cash', 'cash', 0),
  ('card', 'card', 0),
  ('mobile', 'mobile', 0),
  ('transfer', 'bank', 0),
  ('due', 'due', 1);

GRANT SELECT, INSERT, UPDATE ON TABLE
  pos_sale_test_fixtures, pos_sale_test_attempts TO authenticated;

SET LOCAL ROLE authenticated;

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT owner_a::text FROM pos_sale_test_fixtures),
  true
);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (SELECT owner_a::text FROM pos_sale_test_fixtures),
    'role', 'authenticated'
  )::text,
  true
);

UPDATE pos_sale_test_attempts AS attempt
SET response = public.complete_pos_sale(
  pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'product_id', fixture.product_a,
    'quantity', 1,
    'discount_type', 'fixed',
    'discount_value', 0
  )),
  fixture.customer_a,
  0,
  attempt.payment_method,
  attempt.paid_amount,
  attempt.idempotency_key,
  NULL
)
FROM pos_sale_test_fixtures AS fixture;

UPDATE pos_sale_test_attempts AS attempt
SET replay_response = public.complete_pos_sale(
  pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'product_id', fixture.product_a,
    'quantity', 1,
    'discount_type', 'fixed',
    'discount_value', 0
  )),
  fixture.customer_a,
  0,
  attempt.payment_method,
  attempt.paid_amount,
  attempt.idempotency_key,
  NULL
)
FROM pos_sale_test_fixtures AS fixture;

SET CONSTRAINTS products_record_unlogged_stock_change IMMEDIATE;

SELECT is(
  (SELECT array_agg(attribute.attname ORDER BY key_column.ordinality)
   FROM pg_catalog.pg_constraint AS constraint_row
   CROSS JOIN LATERAL unnest(constraint_row.conkey)
     WITH ORDINALITY AS key_column(attnum, ordinality)
   JOIN pg_catalog.pg_attribute AS attribute
     ON attribute.attrelid = constraint_row.conrelid
    AND attribute.attnum = key_column.attnum
   WHERE constraint_row.conrelid = 'public.pos_sale_idempotency'::regclass
     AND constraint_row.contype = 'p'),
  ARRAY['store_id', 'idempotency_key']::name[],
  'store and idempotency key form the database primary key'
);
SELECT ok(
  (SELECT relrowsecurity FROM pg_catalog.pg_class
   WHERE oid = 'public.pos_sale_idempotency'::regclass),
  'idempotency table has row-level security enabled'
);
SELECT ok(
  NOT has_table_privilege('authenticated', 'public.pos_sale_idempotency', 'SELECT'),
  'authenticated clients cannot directly read idempotency rows'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_catalog.pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'pos_sale_idempotency'
      AND policyname = 'pos_sale_idempotency_store_isolation'
      AND qual LIKE '%get_my_store_id%'
      AND with_check LIKE '%get_my_store_id%'
  ),
  'idempotency policy scopes reads and writes to the current store'
);
SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.complete_pos_sale(jsonb,uuid,numeric,text,numeric,uuid,uuid)',
    'EXECUTE'
  ),
  'authenticated clients can execute the keyed sale RPC'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.complete_pos_sale(jsonb,uuid,numeric,text,numeric,uuid)',
    'EXECUTE'
  ),
  'the six-argument legacy sale RPC is not executable by authenticated clients'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.complete_pos_sale(jsonb,uuid,numeric,text,numeric)',
    'EXECUTE'
  ),
  'the five-argument legacy sale RPC is not executable by authenticated clients'
);
SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.complete_pos_sale_internal(jsonb,uuid,numeric,text,numeric,uuid)',
    'EXECUTE'
  ),
  'the internal unkeyed sale RPC is not executable by authenticated clients'
);

SELECT is(
  (SELECT response = replay_response
   FROM pos_sale_test_attempts WHERE label = 'cash'),
  true,
  'cash retry returns the saved response'
);
SELECT is(
  (SELECT response = replay_response
   FROM pos_sale_test_attempts WHERE label = 'card'),
  true,
  'card retry returns the saved response'
);
SELECT is(
  (SELECT response = replay_response
   FROM pos_sale_test_attempts WHERE label = 'mobile'),
  true,
  'mobile retry returns the saved response'
);
SELECT is(
  (SELECT response = replay_response
   FROM pos_sale_test_attempts WHERE label = 'transfer'),
  true,
  'transfer retry returns the saved response'
);
SELECT is(
  (SELECT response = replay_response
   FROM pos_sale_test_attempts WHERE label = 'due'),
  true,
  'due retry returns the saved response'
);

SELECT is(
  (SELECT response ->> 'payment_method'
   FROM pos_sale_test_attempts WHERE label = 'cash'),
  'cash',
  'cash payment method is preserved'
);
SELECT is(
  (SELECT response ->> 'payment_method'
   FROM pos_sale_test_attempts WHERE label = 'card'),
  'card',
  'card payment method is preserved'
);
SELECT is(
  (SELECT response ->> 'payment_method'
   FROM pos_sale_test_attempts WHERE label = 'mobile'),
  'mobile',
  'mobile payment method is preserved'
);
SELECT is(
  (SELECT response ->> 'payment_method'
   FROM pos_sale_test_attempts WHERE label = 'transfer'),
  'bank',
  'transfer payment method is stored as bank'
);
SELECT is(
  (SELECT response ->> 'payment_method'
   FROM pos_sale_test_attempts WHERE label = 'due'),
  'due',
  'due payment method is preserved'
);

SELECT is(
  (SELECT count(*)::integer
   FROM public.sales AS sale
   JOIN pos_sale_test_attempts AS attempt
     ON sale.id = (attempt.response ->> 'id')::uuid
   WHERE sale.payment_status = CASE
     WHEN attempt.label = 'due' THEN 'due' ELSE 'paid' END),
  5,
  'paid and due statuses are stored for all five methods'
);
SELECT ok(
  (SELECT due_amount > 0
   FROM public.sales AS sale
   JOIN pos_sale_test_attempts AS attempt
     ON sale.id = (attempt.response ->> 'id')::uuid
   WHERE attempt.label = 'due'),
  'partial due payment leaves a positive due balance'
);

SELECT is(
  (SELECT count(*)::integer
   FROM public.sales AS sale
   JOIN pos_sale_test_attempts AS attempt
     ON sale.id = (attempt.response ->> 'id')::uuid),
  5,
  'five new UUIDs produce five sales despite retries'
);
SELECT is(
  (SELECT count(*)::integer
   FROM public.sale_items AS item
   JOIN pos_sale_test_attempts AS attempt
     ON item.sale_id = (attempt.response ->> 'id')::uuid),
  5,
  'five new sales produce five sale items'
);
SELECT is(
  (SELECT count(*)::integer
   FROM public.stock_movements AS movement
   JOIN public.sales AS sale ON movement.reference = sale.invoice_number
   JOIN pos_sale_test_attempts AS attempt
     ON sale.id = (attempt.response ->> 'id')::uuid
   WHERE movement.type = 'out'),
  5,
  'retries create no additional invoice-linked stock movements'
);
SELECT is(
  (SELECT stock FROM public.products
   WHERE id = (SELECT product_a FROM pos_sale_test_fixtures)),
  95::numeric,
  'five new transactions deduct inventory once each'
);
SELECT is(
  (SELECT count(*)::integer
   FROM public.customer_payments AS payment
   WHERE payment.sale_id IN (
     SELECT (response ->> 'id')::uuid FROM pos_sale_test_attempts
   )),
  0,
  'same-key retries do not create duplicate customer payment records'
);

SELECT throws_ok(
  format(
    'SELECT public.complete_pos_sale(%L::jsonb, %L::uuid, 0, %L, 0, %L::uuid, NULL)',
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'product_id', (SELECT product_a FROM pos_sale_test_fixtures),
      'quantity', 2,
      'discount_type', 'fixed',
      'discount_value', 0
    ))::text,
    (SELECT customer_a::text FROM pos_sale_test_fixtures),
    'cash',
    (SELECT idempotency_key::text
     FROM pos_sale_test_attempts WHERE label = 'cash')
  ),
  '22023',
  'Sale idempotency key was already used for a different request',
  'a reused key with a changed request is rejected'
);
SELECT is(
  (SELECT count(*)::integer
   FROM public.sales AS sale
   JOIN pos_sale_test_attempts AS attempt
     ON sale.id = (attempt.response ->> 'id')::uuid),
  5,
  'changed-payload retry adds no sale'
);
SELECT is(
  (SELECT stock FROM public.products
   WHERE id = (SELECT product_a FROM pos_sale_test_fixtures)),
  95::numeric,
  'changed-payload retry does not deduct stock'
);

INSERT INTO pos_sale_test_attempts (label, payment_method, paid_amount)
VALUES ('identical_new_sale', 'card', 0);
UPDATE pos_sale_test_attempts AS attempt
SET response = public.complete_pos_sale(
  pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'product_id', fixture.product_a,
    'quantity', 1,
    'discount_type', 'fixed',
    'discount_value', 0
  )),
  fixture.customer_a,
  0,
  attempt.payment_method,
  attempt.paid_amount,
  attempt.idempotency_key,
  NULL
)
FROM pos_sale_test_fixtures AS fixture
WHERE attempt.label = 'identical_new_sale';
SELECT is(
  (SELECT count(*)::integer
   FROM public.sales AS sale
   JOIN pos_sale_test_attempts AS attempt
     ON sale.id = (attempt.response ->> 'id')::uuid),
  6,
  'an identical new sale with a new UUID is recorded separately'
);
SELECT is(
  (SELECT stock FROM public.products
   WHERE id = (SELECT product_a FROM pos_sale_test_fixtures)),
  94::numeric,
  'the distinct identical sale deducts inventory once'
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT owner_b::text FROM pos_sale_test_fixtures),
  true
);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (SELECT owner_b::text FROM pos_sale_test_fixtures),
    'role', 'authenticated'
  )::text,
  true
);
INSERT INTO pos_sale_test_attempts (label, payment_method, paid_amount)
VALUES ('same_key_other_store', 'cash', 0);
UPDATE pos_sale_test_attempts AS attempt
SET response = public.complete_pos_sale(
  pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'product_id', fixture.product_b,
    'quantity', 1,
    'discount_type', 'fixed',
    'discount_value', 0
  )),
  fixture.customer_b,
  0,
  attempt.payment_method,
  attempt.paid_amount,
  (SELECT idempotency_key
   FROM pos_sale_test_attempts WHERE label = 'cash'),
  NULL
)
FROM pos_sale_test_fixtures AS fixture
WHERE attempt.label = 'same_key_other_store';
SET CONSTRAINTS products_record_unlogged_stock_change IMMEDIATE;

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer
   FROM public.pos_sale_idempotency AS idempotency
   WHERE idempotency.idempotency_key = (
     SELECT idempotency_key FROM pos_sale_test_attempts WHERE label = 'cash'
   )),
  2,
  'the same UUID is independently recorded once per store'
);
SET LOCAL ROLE authenticated;

SELECT is(
  public.get_my_store_id(),
  (SELECT store_b FROM pos_sale_test_fixtures),
  'the second user resolves only to the second store'
);
SELECT isnt(
  (SELECT response ->> 'id'
   FROM pos_sale_test_attempts WHERE label = 'cash'),
  (SELECT response ->> 'id'
   FROM pos_sale_test_attempts WHERE label = 'same_key_other_store'),
  'the same key in another store returns a different sale'
);
SELECT is(
  (SELECT count(*)::integer FROM public.sales
   WHERE customer_id = (SELECT customer_b FROM pos_sale_test_fixtures)),
  1,
  'sales history under store B cannot see store A sales'
);
SELECT is(
  (SELECT count(*)::integer FROM public.products
   WHERE id = (SELECT product_a FROM pos_sale_test_fixtures)),
  0,
  'store B cannot read store A products'
);
SELECT is(
  (SELECT stock FROM public.products
   WHERE id = (SELECT product_b FROM pos_sale_test_fixtures)),
  99::numeric,
  'the other store inventory is deducted once'
);

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT owner_a::text FROM pos_sale_test_fixtures),
  true
);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (SELECT owner_a::text FROM pos_sale_test_fixtures),
    'role', 'authenticated'
  )::text,
  true
);
SELECT is(
  (SELECT count(*)::integer FROM public.sales),
  6,
  'sales history under store A contains only its six sales'
);
SELECT is(
  (SELECT count(*)::integer
   FROM public.stock_movements AS movement
   JOIN public.sales AS sale ON movement.reference = sale.invoice_number
   WHERE movement.type = 'out'
     AND sale.customer_id = (SELECT customer_a FROM pos_sale_test_fixtures)),
  6,
  'store A has one invoice-linked stock movement per sale'
);

SET CONSTRAINTS sales_persist_item_profit IMMEDIATE;

SELECT is(
  (SELECT count(*)::integer FROM public.sales
   WHERE customer_id = (SELECT customer_a FROM pos_sale_test_fixtures)),
  6,
  'sales history contains one parent row for each of the six UUIDs'
);

INSERT INTO pos_sale_test_attempts (label, payment_method, paid_amount)
VALUES ('atomic_failure', 'cash', 0);
SELECT throws_ok(
  format(
    'SELECT public.complete_pos_sale(%L::jsonb, %L::uuid, 0, %L, 0, %L::uuid, NULL)',
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'product_id', (SELECT product_a FROM pos_sale_test_fixtures),
      'quantity', 100,
      'discount_type', 'fixed',
      'discount_value', 0
    ))::text,
    (SELECT customer_a::text FROM pos_sale_test_fixtures),
    'cash',
    (SELECT idempotency_key::text
     FROM pos_sale_test_attempts WHERE label = 'atomic_failure')
  ),
  'P0001',
  'Insufficient stock',
  'a sale that fails after reserving a key is rolled back'
);
RESET ROLE;
SELECT is(
  (SELECT count(*)::integer
   FROM public.pos_sale_idempotency AS idempotency
   WHERE idempotency.idempotency_key = (
     SELECT idempotency_key
     FROM pos_sale_test_attempts WHERE label = 'atomic_failure'
   )),
  0,
  'a failed sale does not retain an incomplete idempotency reservation'
);
SET LOCAL ROLE authenticated;
SELECT is(
  (SELECT count(*)::integer FROM public.sales
   WHERE customer_id = (SELECT customer_a FROM pos_sale_test_fixtures)),
  6,
  'a failed sale does not create a sales row'
);
SELECT is(
  (SELECT stock FROM public.products
   WHERE id = (SELECT product_a FROM pos_sale_test_fixtures)),
  94::numeric,
  'a failed sale does not deduct inventory'
);

SELECT is(
  (SELECT sum(sale.paid) FROM public.sales AS sale
   WHERE sale.customer_id = (SELECT customer_a FROM pos_sale_test_fixtures)),
  (SELECT sum((response ->> 'paid')::numeric)
   FROM pos_sale_test_attempts
   WHERE label IN ('cash', 'card', 'mobile', 'transfer', 'due', 'identical_new_sale')),
  'payment report totals match the stored sale payments'
);
SELECT is(
  (SELECT count(DISTINCT sale.payment_method)::integer
   FROM public.sales AS sale
   WHERE sale.customer_id = (SELECT customer_a FROM pos_sale_test_fixtures)),
  5,
  'payment reporting includes cash, card, mobile, bank transfer, and due'
);
SELECT is(
  (SELECT sum(sale.total) FROM public.sales AS sale
   WHERE sale.customer_id = (SELECT customer_a FROM pos_sale_test_fixtures)
     AND sale.sale_date >= date_trunc('day', now())
     AND sale.sale_date < date_trunc('day', now()) + interval '1 day'),
  (SELECT sum((response ->> 'total')::numeric)
   FROM pos_sale_test_attempts
   WHERE label IN ('cash', 'card', 'mobile', 'transfer', 'due', 'identical_new_sale')),
  'daily sales totals include each committed test sale once'
);
SELECT is(
  (SELECT sum(movement.quantity) FROM public.stock_movements AS movement
   JOIN public.sales AS sale ON movement.reference = sale.invoice_number
   WHERE movement.type = 'out'),
  (SELECT sum(item.quantity) FROM public.sale_items AS item
   JOIN public.sales AS sale ON sale.id = item.sale_id),
  'stock movement quantities reconcile with the unique sale items'
);
SELECT is(
  (SELECT sum(sale.total)
   FROM public.sales AS sale
   WHERE sale.customer_id = (SELECT customer_a FROM pos_sale_test_fixtures)),
  (SELECT sum((response ->> 'total')::numeric)
   FROM pos_sale_test_attempts
   WHERE label IN ('cash', 'card', 'mobile', 'transfer', 'due', 'identical_new_sale')),
  'dashboard sales total matches the unique customer sales'
);
SELECT is(
  (SELECT count(*)::integer
   FROM public.sales AS sale
   JOIN public.sale_items AS item ON item.sale_id = sale.id
   WHERE sale.customer_id = (SELECT customer_a FROM pos_sale_test_fixtures)),
  6,
  'sales and customer purchase history contain six distinct sale items'
);
SELECT is(
  (SELECT total_buy FROM public.customers
   WHERE id = (SELECT customer_a FROM pos_sale_test_fixtures)),
  (SELECT sum(sale.total)
   FROM public.sales AS sale
   WHERE sale.customer_id = (SELECT customer_a FROM pos_sale_test_fixtures)),
  'customer purchase totals reconcile to the six unique sales'
);
SELECT is(
  (SELECT total_due FROM public.customers
   WHERE id = (SELECT customer_a FROM pos_sale_test_fixtures)),
  (SELECT sum(sale.due_amount)
   FROM public.sales AS sale
   WHERE sale.customer_id = (SELECT customer_a FROM pos_sale_test_fixtures)),
  'customer due balance reconciles to the sale due amounts'
);
SELECT is(
  public.get_sales_profit_summary(
    NULL, NULL, NULL,
    (SELECT customer_a FROM pos_sale_test_fixtures),
    'completed', NULL, NULL,
    ARRAY[(SELECT product_a FROM pos_sale_test_fixtures)],
    ARRAY[]::uuid[], ARRAY[]::uuid[], ARRAY[]::text[]
  ),
  (SELECT COALESCE(sum(item.profit), 0)
   FROM public.sale_items AS item
   JOIN public.sales AS sale ON sale.id = item.sale_id
   WHERE sale.customer_id = (SELECT customer_a FROM pos_sale_test_fixtures)),
  'profit report totals match the unique sale items'
);

SELECT * FROM finish();
ROLLBACK;
