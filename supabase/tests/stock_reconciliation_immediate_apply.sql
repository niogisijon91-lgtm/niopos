-- Run only against an isolated Supabase database after all migrations.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(30);

CREATE TEMP TABLE stock_reconciliation_test_fixture (
  owner_id uuid NOT NULL,
  store_id uuid,
  product_a uuid NOT NULL,
  product_b uuid NOT NULL,
  product_c uuid NOT NULL
);

INSERT INTO stock_reconciliation_test_fixture
VALUES (gen_random_uuid(), NULL, gen_random_uuid(), gen_random_uuid(), gen_random_uuid());

INSERT INTO auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
)
SELECT owner_id,
  '00000000-0000-0000-0000-000000000000',
  'authenticated',
  'authenticated',
  owner_id::text || '@stock-reconciliation.test',
  '',
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"full_name":"Stock Reconciliation Test","store_name":"Stock Reconciliation Test"}'::jsonb,
  now(),
  now()
FROM stock_reconciliation_test_fixture;

UPDATE public.profiles
SET role = 'store_owner', status = 'approved'
WHERE id = (SELECT owner_id FROM stock_reconciliation_test_fixture);

UPDATE stock_reconciliation_test_fixture AS fixture
SET store_id = (SELECT profile.store_id
                FROM public.profiles AS profile
                WHERE profile.id = fixture.owner_id);

INSERT INTO public.products (id, store_id, name, unit, cost_price, selling_price, stock, status)
SELECT product_a, store_id, 'Reconciliation Test A', 'pcs', 1, 2, 3, 'active'
FROM stock_reconciliation_test_fixture
UNION ALL
SELECT product_b, store_id, 'Reconciliation Test B', 'pcs', 1, 2, 5, 'active'
FROM stock_reconciliation_test_fixture
UNION ALL
SELECT product_c, store_id, 'Reconciliation Test C', 'pcs', 1, 2, NULL, 'active'
FROM stock_reconciliation_test_fixture;

GRANT SELECT, UPDATE ON TABLE stock_reconciliation_test_fixture TO authenticated;
SET LOCAL ROLE authenticated;

SELECT set_config(
  'request.jwt.claim.sub',
  (SELECT owner_id::text FROM stock_reconciliation_test_fixture),
  true
);
SELECT set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (SELECT owner_id::text FROM stock_reconciliation_test_fixture),
    'role', 'authenticated'
  )::text,
  true
);

SELECT is(
  (SELECT stock FROM public.products
   WHERE id = (SELECT product_b FROM stock_reconciliation_test_fixture)),
  5::numeric,
  'a product without a reconciliation keeps its existing stock'
);
SELECT is(
  (SELECT count(*)::integer FROM public.stock_reconciliations
   WHERE product_id = (SELECT product_b FROM stock_reconciliation_test_fixture)),
  0,
  'a product without a reconciliation has no history row'
);

SELECT is(
  public.record_stock_reconciliations(
    jsonb_build_array(jsonb_build_object(
      'product_id', (SELECT product_a FROM stock_reconciliation_test_fixture),
      'physical_quantity', 7,
      'reason', 'physical_stock_correction'
    ))
  ),
  1,
  'a physical count is recorded'
);
SELECT is(
  (SELECT stock FROM public.products
   WHERE id = (SELECT product_a FROM stock_reconciliation_test_fixture)),
  7::numeric,
  'reconciliation immediately sets inventory to the physical count'
);
SELECT is(
  (SELECT status FROM public.stock_reconciliations
   WHERE product_id = (SELECT product_a FROM stock_reconciliation_test_fixture)
   ORDER BY checked_at DESC LIMIT 1),
  'DIFFERENCE_FOUND',
  'the discrepancy remains visible in reconciliation history'
);
SELECT ok(
  (SELECT adjustment_applied FROM public.stock_reconciliations
   WHERE product_id = (SELECT product_a FROM stock_reconciliation_test_fixture)
   ORDER BY checked_at DESC LIMIT 1),
  'the reconciliation is marked applied in the same operation'
);
SELECT is(
  (SELECT stock_quantity FROM public.get_dashboard_inventory_totals()),
  12::numeric,
  'dashboard inventory totals reflect the updated product stock'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.stock_adjustments
   WHERE reconciliation_id IN (
     SELECT id FROM public.stock_reconciliations
     WHERE product_id = (SELECT product_a FROM stock_reconciliation_test_fixture)
   )),
  1,
  'one stock adjustment audit row is created for the discrepancy'
);
SELECT is(
  (SELECT count(*)::integer
   FROM public.stock_movements AS movement
   JOIN public.stock_adjustments AS adjustment
     ON adjustment.id = movement.stock_adjustment_id
   WHERE adjustment.reconciliation_id IN (
     SELECT id FROM public.stock_reconciliations
     WHERE product_id = (SELECT product_a FROM stock_reconciliation_test_fixture)
   )),
  1,
  'one stock movement is created with the adjustment'
);
SET LOCAL ROLE authenticated;

SELECT is(
  public.record_stock_reconciliations(
    jsonb_build_array(jsonb_build_object(
      'product_id', (SELECT product_a FROM stock_reconciliation_test_fixture),
      'physical_quantity', 7
    ))
  ),
  1,
  'an unchanged physical count can be recorded without an adjustment'
);
SELECT is(
  (SELECT stock FROM public.products
   WHERE id = (SELECT product_a FROM stock_reconciliation_test_fixture)),
  7::numeric,
  'recording an unchanged count does not alter inventory'
);
SELECT is(
  (SELECT status FROM public.stock_reconciliations
   WHERE product_id = (SELECT product_a FROM stock_reconciliation_test_fixture)
   ORDER BY checked_at DESC LIMIT 1),
  'CHECKED',
  'an unchanged physical count is marked checked'
);
SELECT is(
  (SELECT count(*)::integer FROM public.stock_adjustments
   WHERE product_id = (SELECT product_a FROM stock_reconciliation_test_fixture)),
  1,
  'repeating an unchanged physical count does not duplicate its stock adjustment'
);

SELECT is(
  public.record_stock_reconciliations(
    jsonb_build_array(
      jsonb_build_object(
        'product_id', (SELECT product_a FROM stock_reconciliation_test_fixture),
        'physical_quantity', 0,
        'reason', 'lost_missing_products'
      ),
      jsonb_build_object(
        'product_id', (SELECT product_b FROM stock_reconciliation_test_fixture),
        'physical_quantity', 2,
        'reason', 'physical_stock_correction'
      )
    )
  ),
  2,
  'bulk reconciliation applies all physical counts'
);
SELECT is(
  (SELECT stock FROM public.products
   WHERE id = (SELECT product_a FROM stock_reconciliation_test_fixture)),
  0::numeric,
  'a zero physical count is applied to inventory'
);
SELECT is(
  (SELECT stock FROM public.products
   WHERE id = (SELECT product_b FROM stock_reconciliation_test_fixture)),
  2::numeric,
  'bulk reconciliation applies the second product count'
);
SELECT is(
  (SELECT stock_quantity FROM public.get_dashboard_inventory_totals()),
  2::numeric,
  'dashboard totals update after bulk reconciliation'
);
SELECT is(
  (SELECT stock_value FROM public.get_dashboard_inventory_totals()),
  2::numeric,
  'dashboard stock value updates after bulk reconciliation'
);

SELECT is(
  (SELECT stock FROM public.products
   WHERE id = (SELECT product_c FROM stock_reconciliation_test_fixture)),
  NULL::numeric,
  'an uncounted product keeps a null software stock until it is reconciled'
);
SELECT is(
  public.record_stock_reconciliations(
    jsonb_build_array(jsonb_build_object(
      'product_id', (SELECT product_c FROM stock_reconciliation_test_fixture),
      'physical_quantity', 0
    ))
  ),
  1,
  'a zero physical count is recorded when software stock is null'
);
SELECT is(
  (SELECT stock FROM public.products
   WHERE id = (SELECT product_c FROM stock_reconciliation_test_fixture)),
  0::numeric,
  'a zero physical count normalizes null software stock to zero'
);
SELECT is(
  (SELECT status FROM public.stock_reconciliations
   WHERE product_id = (SELECT product_c FROM stock_reconciliation_test_fixture)
   ORDER BY checked_at DESC LIMIT 1),
  'CHECKED',
  'zero physical stock against null software stock is checked without a difference'
);
SELECT is(
  (SELECT count(*)::integer FROM public.stock_adjustments
   WHERE product_id = (SELECT product_c FROM stock_reconciliation_test_fixture)),
  0,
  'normalizing null software stock to zero does not create a zero-quantity adjustment'
);

SELECT is(
  public.record_stock_reconciliations(
    jsonb_build_array(
      jsonb_build_object(
        'product_id', (SELECT product_a FROM stock_reconciliation_test_fixture),
        'physical_quantity', NULL
      ),
      jsonb_build_object(
        'product_id', (SELECT product_b FROM stock_reconciliation_test_fixture),
        'physical_quantity', ''
      )
    )
  ),
  0,
  'null and empty physical counts are skipped'
);
SELECT is(
  (SELECT stock FROM public.products
   WHERE id = (SELECT product_a FROM stock_reconciliation_test_fixture)),
  0::numeric,
  'a null physical count leaves existing zero stock unchanged'
);
SELECT is(
  (SELECT stock FROM public.products
   WHERE id = (SELECT product_b FROM stock_reconciliation_test_fixture)),
  2::numeric,
  'an empty physical count leaves existing stock unchanged'
);
SELECT is(
  (SELECT count(*)::integer FROM public.stock_reconciliations
   WHERE product_id IN (
     SELECT product_a FROM stock_reconciliation_test_fixture
     UNION ALL
     SELECT product_b FROM stock_reconciliation_test_fixture
   )),
  4,
  'skipped physical counts do not add reconciliation history'
);
SELECT is(
  (SELECT count(*)::integer
   FROM public.stock_movements AS movement
   JOIN public.stock_adjustments AS adjustment
     ON adjustment.id = movement.stock_adjustment_id
   WHERE adjustment.reconciliation_id IN (
     SELECT id FROM public.stock_reconciliations
     WHERE product_id IN (
       SELECT product_a FROM stock_reconciliation_test_fixture
       UNION ALL
       SELECT product_b FROM stock_reconciliation_test_fixture
     )
   )),
  3,
  'skipped physical counts do not duplicate stock movements'
);

RESET ROLE;
SELECT is(
  (SELECT count(*)::integer FROM public.stock_adjustments
   WHERE reconciliation_id IN (
     SELECT id FROM public.stock_reconciliations
     WHERE product_id IN (
       SELECT product_a FROM stock_reconciliation_test_fixture
       UNION ALL
       SELECT product_b FROM stock_reconciliation_test_fixture
     )
   )),
  3,
  'increases and decreases each create one adjustment record'
);
SELECT is(
  (SELECT count(*)::integer
   FROM public.stock_movements AS movement
   JOIN public.stock_adjustments AS adjustment
     ON adjustment.id = movement.stock_adjustment_id
   WHERE adjustment.reconciliation_id IN (
     SELECT id FROM public.stock_reconciliations
     WHERE product_id IN (
       SELECT product_a FROM stock_reconciliation_test_fixture
       UNION ALL
       SELECT product_b FROM stock_reconciliation_test_fixture
     )
   )),
  3,
  'every applied reconciliation has one corresponding stock movement'
);

SELECT * FROM finish();
ROLLBACK;
