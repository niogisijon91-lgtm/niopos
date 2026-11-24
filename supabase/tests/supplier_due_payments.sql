-- Run only against an isolated Supabase database after all migrations.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(15);

CREATE TEMP TABLE supplier_due_payment_test_fixtures (
  owner_id uuid NOT NULL,
  store_id uuid,
  supplier_id uuid NOT NULL,
  purchase_id uuid NOT NULL,
  invoice_payment_key uuid NOT NULL,
  previous_due_payment_key uuid NOT NULL,
  overpayment_key uuid NOT NULL
);

INSERT INTO supplier_due_payment_test_fixtures
VALUES (
  gen_random_uuid(), NULL, gen_random_uuid(), gen_random_uuid(),
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid()
);

INSERT INTO auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
SELECT owner_id, '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated',
  owner_id::text || '@supplier-due.test', '',
  now(), '{"provider":"email","providers":["email"]}'::jsonb,
  '{"full_name":"Supplier Due Test","store_name":"Supplier Due Test"}'::jsonb,
  now(), now()
FROM supplier_due_payment_test_fixtures;

UPDATE public.profiles
SET role = 'store_owner', status = 'approved'
WHERE id = (SELECT owner_id FROM supplier_due_payment_test_fixtures);

UPDATE supplier_due_payment_test_fixtures AS fixture
SET store_id = (
  SELECT profile.store_id
  FROM public.profiles AS profile
  WHERE profile.id = fixture.owner_id
);

INSERT INTO public.suppliers (
  id, store_id, name, previous_due, total_paid, total_due
)
SELECT supplier_id, store_id, 'Supplier Due Test', 20, 30, 90
FROM supplier_due_payment_test_fixtures;

INSERT INTO public.purchases (
  id, store_id, po_number, supplier_id, subtotal, tax, discount, total,
  paid_amount, due_amount, payment_method, status, payment_status, purchase_date
)
SELECT purchase_id, store_id, 'SUPPLIER-DUE-' || left(purchase_id::text, 8),
  supplier_id, 100, 0, 0, 100, 30, 70, 'due', 'received', 'due', now()
FROM supplier_due_payment_test_fixtures;

GRANT SELECT ON supplier_due_payment_test_fixtures TO authenticated;

SET LOCAL ROLE authenticated;
SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT owner_id::text FROM supplier_due_payment_test_fixtures),
  true
);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (SELECT owner_id::text FROM supplier_due_payment_test_fixtures),
    'role', 'authenticated'
  )::text,
  true
);

SELECT is(
  (public.collect_supplier_due_payment(
    fixture.supplier_id, fixture.purchase_id, 25, 'cash', DATE '2026-11-24',
    'INV-REF', 'Partial invoice payment', fixture.invoice_payment_key
  ) ->> 'remaining_due')::numeric,
  45::numeric,
  'partial invoice payment returns the outstanding amount'
)
FROM supplier_due_payment_test_fixtures AS fixture;

SELECT is(
  (SELECT purchase.paid_amount
   FROM public.purchases AS purchase
   WHERE purchase.id = fixture.purchase_id),
  55::numeric,
  'partial payment increases the purchase paid amount'
)
FROM supplier_due_payment_test_fixtures AS fixture;

SELECT is(
  (SELECT purchase.due_amount
   FROM public.purchases AS purchase
   WHERE purchase.id = fixture.purchase_id),
  45::numeric,
  'partial payment decreases the purchase due amount'
)
FROM supplier_due_payment_test_fixtures AS fixture;

SELECT is(
  (SELECT supplier.total_paid
   FROM public.suppliers AS supplier
   WHERE supplier.id = fixture.supplier_id),
  55::numeric,
  'partial payment updates supplier total paid'
)
FROM supplier_due_payment_test_fixtures AS fixture;

SELECT is(
  (SELECT supplier.total_due
   FROM public.suppliers AS supplier
   WHERE supplier.id = fixture.supplier_id),
  65::numeric,
  'partial payment updates supplier total due'
)
FROM supplier_due_payment_test_fixtures AS fixture;

SELECT is(
  (SELECT count(*)::integer
   FROM public.supplier_payments AS payment
   WHERE payment.store_id = fixture.store_id
     AND payment.idempotency_key = fixture.invoice_payment_key),
  1,
  'invoice payment is stored once'
)
FROM supplier_due_payment_test_fixtures AS fixture;

SELECT is(
  (public.collect_supplier_due_payment(
    fixture.supplier_id, fixture.purchase_id, 25, 'cash', DATE '2026-11-24',
    'INV-REF', 'Partial invoice payment', fixture.invoice_payment_key
  ) ->> 'remaining_due')::numeric,
  45::numeric,
  'retrying the same request returns the current remaining due'
)
FROM supplier_due_payment_test_fixtures AS fixture;

SELECT is(
  (SELECT count(*)::integer
   FROM public.supplier_payments AS payment
   WHERE payment.store_id = fixture.store_id
     AND payment.idempotency_key = fixture.invoice_payment_key),
  1,
  'retrying does not duplicate the payment'
)
FROM supplier_due_payment_test_fixtures AS fixture;

SELECT is(
  (public.collect_supplier_due_payment(
    fixture.supplier_id, NULL, 5, 'bank', DATE '2026-11-24',
    NULL, 'Previous balance payment', fixture.previous_due_payment_key
  ) ->> 'remaining_due')::numeric,
  15::numeric,
  'previous due payment returns the remaining previous balance'
)
FROM supplier_due_payment_test_fixtures AS fixture;

SELECT is(
  (SELECT payment.applied_to_previous_due
   FROM public.supplier_payments AS payment
   WHERE payment.store_id = fixture.store_id
     AND payment.idempotency_key = fixture.previous_due_payment_key),
  true,
  'previous balance payment is identified in payment history'
)
FROM supplier_due_payment_test_fixtures AS fixture;

SELECT is(
  (SELECT supplier.total_due
   FROM public.suppliers AS supplier
   WHERE supplier.id = fixture.supplier_id),
  60::numeric,
  'previous due payment decreases supplier total due'
)
FROM supplier_due_payment_test_fixtures AS fixture;

SELECT is(
  (SELECT supplier.total_due
   FROM public.suppliers AS supplier
   WHERE supplier.id = fixture.supplier_id),
  (
    SELECT COALESCE((
        SELECT SUM(purchase.due_amount)
        FROM public.purchases AS purchase
        WHERE purchase.supplier_id = supplier.id
          AND purchase.store_id = fixture.store_id
          AND purchase.status <> 'cancelled'
      ), 0)
      + GREATEST(
          COALESCE(supplier.previous_due, 0) - COALESCE((
            SELECT SUM(payment.amount)
            FROM public.supplier_payments AS payment
            WHERE payment.supplier_id = supplier.id
              AND payment.store_id = fixture.store_id
              AND payment.applied_to_previous_due
          ), 0),
          0
        )
    FROM public.suppliers AS supplier
    WHERE supplier.id = fixture.supplier_id
  ),
  'cached supplier due matches remaining invoices and previous due'
)
FROM supplier_due_payment_test_fixtures AS fixture;

SELECT throws_ok(
  format(
    'SELECT public.collect_supplier_due_payment(%L::uuid, NULL, 16, %L, %L::date, NULL, NULL, %L::uuid)',
    fixture.supplier_id, 'cash', '2026-11-24', fixture.overpayment_key
  ),
  '22023',
  'supplier_payment_exceeds_remaining_due',
  'payment above the remaining previous due is rejected'
)
FROM supplier_due_payment_test_fixtures AS fixture;

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.collect_supplier_due_payment(uuid,uuid,numeric,text,date,text,text,uuid)',
    'EXECUTE'
  ),
  'authenticated users can call the guarded payment RPC'
);

SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.collect_supplier_due_payment(uuid,uuid,numeric,text,date,text,text,uuid)',
    'EXECUTE'
  ),
  'anonymous users cannot call the payment RPC'
);

SELECT * FROM finish();
ROLLBACK;
