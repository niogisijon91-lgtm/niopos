-- Deployed to Supabase as migration 20261114182400.
BEGIN;

DO $$
BEGIN
  IF to_regclass('public.profiles') IS NULL
    OR to_regclass('public.stores') IS NULL
    OR to_regclass('public.store_memberships') IS NULL
    OR to_regclass('public.store_invitations') IS NULL
    OR to_regclass('public.employees') IS NULL
    OR to_regclass('public.roles') IS NULL
    OR to_regprocedure('public.is_store_owner()') IS NULL THEN
    RAISE EXCEPTION 'Expected employee, role, membership, and tenant objects are missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'roles' AND column_name = 'store_id'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'employees' AND column_name = 'store_id'
  ) THEN
    RAISE EXCEPTION 'Store-scoped roles and employees are required';
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.rbac_permission_catalog (
  permission_key text PRIMARY KEY,
  module_key text NOT NULL,
  action_key text NOT NULL,
  sort_order integer NOT NULL,
  UNIQUE (module_key, action_key)
);

INSERT INTO public.rbac_permission_catalog (permission_key, module_key, action_key, sort_order)
SELECT module_key || '.' || action_key, module_key, action_key,
       (module_order * 10) + action_order
FROM (VALUES
  ('dashboard', 1), ('pos', 2), ('products', 3), ('brands', 4),
  ('categories', 5), ('units', 6), ('sales', 7), ('sale_returns', 8),
  ('inventory', 9), ('stock_reconciliation', 10), ('barcode', 11),
  ('customers', 12), ('discount_offers', 13), ('suppliers', 14),
  ('employees', 15), ('purchases', 16), ('purchase_returns', 17),
  ('expenses', 18), ('reports', 19), ('settings', 20)
) AS modules(module_key, module_order)
CROSS JOIN (VALUES
  ('view', 1), ('create', 2), ('edit', 3), ('delete', 4), ('export', 5), ('print', 6)
) AS actions(action_key, action_order)
ON CONFLICT (permission_key) DO NOTHING;

INSERT INTO public.rbac_permission_catalog (permission_key, module_key, action_key, sort_order)
VALUES
  ('actions.apply_discount', 'actions', 'apply_discount', 201),
  ('actions.change_selling_price', 'actions', 'change_selling_price', 202),
  ('actions.view_purchase_price', 'actions', 'view_purchase_price', 203),
  ('actions.view_profit', 'actions', 'view_profit', 204),
  ('actions.view_financial_reports', 'actions', 'view_financial_reports', 205),
  ('actions.view_customer_due', 'actions', 'view_customer_due', 206),
  ('actions.process_sale_return', 'actions', 'process_sale_return', 207),
  ('actions.process_purchase_return', 'actions', 'process_purchase_return', 208),
  ('actions.adjust_stock_increase', 'actions', 'adjust_stock_increase', 209),
  ('actions.adjust_stock_decrease', 'actions', 'adjust_stock_decrease', 210),
  ('actions.manage_employees', 'actions', 'manage_employees', 211),
  ('actions.manage_roles', 'actions', 'manage_roles', 212),
  ('actions.manage_permissions', 'actions', 'manage_permissions', 213),
  ('actions.manage_store_settings', 'actions', 'manage_store_settings', 214)
ON CONFLICT (permission_key) DO NOTHING;

ALTER TABLE public.roles
  ADD COLUMN IF NOT EXISTS role_key text,
  ADD COLUMN IF NOT EXISTS is_system boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS is_protected boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL;

ALTER TABLE public.roles
  ALTER COLUMN permissions SET DEFAULT '{}'::jsonb;

CREATE UNIQUE INDEX IF NOT EXISTS roles_id_store_id_key
  ON public.roles (id, store_id);
CREATE UNIQUE INDEX IF NOT EXISTS roles_store_name_key
  ON public.roles (store_id, lower(name));
CREATE UNIQUE INDEX IF NOT EXISTS roles_store_role_key_key
  ON public.roles (store_id, role_key)
  WHERE role_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS roles_store_id_idx ON public.roles (store_id);

ALTER TABLE public.store_memberships
  ADD COLUMN IF NOT EXISTS role_id uuid;

DO $$
BEGIN
  IF EXISTS (
    SELECT user_id
    FROM public.store_memberships
    GROUP BY user_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Employees assigned to multiple stores must be resolved before enforcing one-store accounts';
  END IF;
END;
$$;
CREATE UNIQUE INDEX IF NOT EXISTS store_memberships_user_id_key
  ON public.store_memberships (user_id);

ALTER TABLE public.store_invitations
  ADD COLUMN IF NOT EXISTS role_id uuid,
  ADD COLUMN IF NOT EXISTS full_name text,
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS address text,
  ADD COLUMN IF NOT EXISTS employee_code text,
  ADD COLUMN IF NOT EXISTS joining_date date;

ALTER TABLE public.store_memberships
  DROP CONSTRAINT IF EXISTS store_memberships_role_id_store_id_fkey;
ALTER TABLE public.store_memberships
  ADD CONSTRAINT store_memberships_role_id_store_id_fkey
  FOREIGN KEY (role_id, store_id) REFERENCES public.roles (id, store_id)
  ON DELETE RESTRICT;
ALTER TABLE public.store_invitations
  DROP CONSTRAINT IF EXISTS store_invitations_role_id_store_id_fkey;
ALTER TABLE public.store_invitations
  ADD CONSTRAINT store_invitations_role_id_store_id_fkey
  FOREIGN KEY (role_id, store_id) REFERENCES public.roles (id, store_id)
  ON DELETE RESTRICT;

ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS address text,
  ADD COLUMN IF NOT EXISTS profile_image text,
  ADD COLUMN IF NOT EXISTS employee_code text,
  ADD COLUMN IF NOT EXISTS joining_date date;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.employees
    WHERE email IS NOT NULL
    GROUP BY store_id, lower(email)
    HAVING count(*) > 1
  ) OR EXISTS (
    SELECT 1 FROM public.employees
    WHERE employee_code IS NOT NULL
    GROUP BY store_id, lower(employee_code)
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Duplicate employee emails or employee IDs must be resolved before enabling uniqueness';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.roles
    WHERE store_id IS NOT NULL
    GROUP BY store_id, lower(name)
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Duplicate store role names must be resolved before enabling role uniqueness';
  END IF;
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS employees_store_user_id_key
  ON public.employees (store_id, user_id)
  WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS employees_store_email_key
  ON public.employees (store_id, lower(email))
  WHERE email IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS employees_store_code_key
  ON public.employees (store_id, lower(employee_code))
  WHERE employee_code IS NOT NULL;
CREATE INDEX IF NOT EXISTS employees_store_name_idx
  ON public.employees (store_id, lower(name));

CREATE TABLE IF NOT EXISTS public.employee_permissions (
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  permission_key text NOT NULL REFERENCES public.rbac_permission_catalog(permission_key) ON DELETE CASCADE,
  is_granted boolean NOT NULL,
  updated_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store_id, user_id, permission_key),
  FOREIGN KEY (store_id, user_id)
    REFERENCES public.store_memberships(store_id, user_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS employee_permissions_user_idx
  ON public.employee_permissions (user_id, store_id);

CREATE TABLE IF NOT EXISTS public.employee_activity_logs (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  store_id uuid NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
  user_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  action text NOT NULL,
  module text NOT NULL,
  previous_value jsonb,
  new_value jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS employee_activity_store_time_idx
  ON public.employee_activity_logs (store_id, created_at DESC);
CREATE INDEX IF NOT EXISTS employee_activity_user_time_idx
  ON public.employee_activity_logs (store_id, user_id, created_at DESC);

ALTER TABLE public.rbac_permission_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rbac_permission_catalog FORCE ROW LEVEL SECURITY;
ALTER TABLE public.employee_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_permissions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.employee_activity_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_activity_logs FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.rbac_permission_catalog, public.employee_permissions,
  public.employee_activity_logs FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.build_store_role_permissions(permission_keys text[])
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT COALESCE(jsonb_object_agg(c.permission_key, true), '{}'::jsonb)
  FROM public.rbac_permission_catalog AS c
  WHERE c.permission_key = ANY (COALESCE(permission_keys, ARRAY[]::text[]));
$$;
REVOKE ALL ON FUNCTION public.build_store_role_permissions(text[]) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.seed_store_default_roles(target_store_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE
  v_all text[];
BEGIN
  IF target_store_id IS NULL THEN
    RAISE EXCEPTION 'A store is required to seed roles';
  END IF;
  SELECT array_agg(permission_key) INTO v_all
  FROM public.rbac_permission_catalog
  WHERE permission_key NOT IN (
    'actions.manage_store_settings',
    'actions.manage_employees',
    'actions.manage_roles',
    'actions.manage_permissions'
  )
    AND permission_key NOT LIKE 'employees.%'
    AND permission_key NOT LIKE 'settings.%';

  INSERT INTO public.roles (store_id, name, description, role_key, permissions, is_system, is_protected)
  SELECT target_store_id, role_def.name, role_def.description, role_def.role_key,
         public.build_store_role_permissions(role_def.permissions), role_def.is_system,
         role_def.is_protected
  FROM (VALUES
    ('Store Owner', 'Full access to this store; not assignable to employees.', 'store_owner',
      (SELECT array_agg(permission_key) FROM public.rbac_permission_catalog), true, true),
    ('Admin', 'Store administration without protected ownership controls.', 'admin', v_all, true, false),
    ('Manager', 'Manage daily sales, inventory, customers, purchasing, and permitted reports.', 'manager',
      ARRAY['dashboard.view','pos.view','pos.create','pos.print','sales.view','sales.create','sales.edit','sales.print','sale_returns.view','sale_returns.create','sale_returns.edit','sale_returns.print','customers.view','customers.create','customers.edit','inventory.view','inventory.create','inventory.edit','stock_reconciliation.view','stock_reconciliation.create','stock_reconciliation.edit','products.view','products.create','products.edit','purchases.view','purchases.create','purchases.edit','suppliers.view','suppliers.create','suppliers.edit','reports.view','reports.export','actions.process_sale_return','actions.process_purchase_return','actions.adjust_stock_increase','actions.adjust_stock_decrease']::text[], true, false),
    ('Cashier', 'Process sales, manage customers, and print receipts.', 'cashier',
      ARRAY['pos.view','pos.create','pos.print','sales.view','sales.create','sales.print','customers.view','customers.create','actions.apply_discount']::text[], true, false),
    ('Inventory Staff', 'Manage products, barcode, and stock tasks as assigned.', 'inventory_staff',
      ARRAY['products.view','products.create','products.edit','brands.view','categories.view','units.view','barcode.view','barcode.create','barcode.print','inventory.view','inventory.edit','stock_reconciliation.view','stock_reconciliation.create','stock_reconciliation.edit','actions.adjust_stock_increase','actions.adjust_stock_decrease']::text[], true, false),
    ('Accountant', 'Manage expenses, purchases, and permitted financial reports.', 'accountant',
      ARRAY['dashboard.view','sales.view','sales.export','sales.print','purchases.view','purchases.export','purchase_returns.view','expenses.view','expenses.create','expenses.edit','expenses.export','reports.view','reports.export','actions.view_purchase_price','actions.view_profit','actions.view_financial_reports','actions.view_customer_due']::text[], true, false),
    ('Custom Role', 'A custom permission template.', 'custom',
      ARRAY[]::text[], false, false)
  ) AS role_def(name, description, role_key, permissions, is_system, is_protected)
  ON CONFLICT (store_id, role_key) WHERE role_key IS NOT NULL DO NOTHING;
END;
$$;
REVOKE ALL ON FUNCTION public.seed_store_default_roles(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.seed_store_roles_after_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
BEGIN
  PERFORM public.seed_store_default_roles(NEW.id);
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.seed_store_roles_after_insert() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS seed_store_default_roles_trigger ON public.stores;
CREATE TRIGGER seed_store_default_roles_trigger
  AFTER INSERT ON public.stores
  FOR EACH ROW EXECUTE FUNCTION public.seed_store_roles_after_insert();

DO $$
DECLARE
  v_store_id uuid;
BEGIN
  FOR v_store_id IN SELECT id FROM public.stores LOOP
    PERFORM public.seed_store_default_roles(v_store_id);
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.has_store_permission(requested_permission text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE
  v_store_id uuid;
  v_role_permissions jsonb;
  v_legacy_permissions text[];
  v_permission text;
  v_override boolean;
  v_allowed boolean;
BEGIN
  IF requested_permission IS NULL OR requested_permission = '' THEN
    RETURN false;
  END IF;
  IF public.is_store_owner() THEN
    RETURN true;
  END IF;

  v_store_id := public.get_my_store_id();
  IF v_store_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.store_memberships AS sm
    JOIN public.profiles AS p ON p.id = sm.user_id
    WHERE sm.store_id = v_store_id AND sm.user_id = auth.uid()
      AND sm.role = 'cashier' AND sm.status = 'approved'
      AND p.role = 'cashier' AND p.status = 'approved'
  ) THEN
    RETURN false;
  END IF;

  SELECT r.permissions, sm.permissions
  INTO v_role_permissions, v_legacy_permissions
  FROM public.store_memberships AS sm
  LEFT JOIN public.roles AS r
    ON r.id = sm.role_id AND r.store_id = sm.store_id
  WHERE sm.store_id = v_store_id AND sm.user_id = auth.uid();

  IF position('.' IN requested_permission) = 0
    AND requested_permission NOT LIKE 'actions.%' THEN
    IF COALESCE(v_role_permissions, '{}'::jsonb) ? requested_permission THEN
      RETURN true;
    END IF;
    IF EXISTS (
      SELECT 1 FROM jsonb_each_text(COALESCE(v_role_permissions, '{}'::jsonb)) AS p(key, value)
      WHERE p.key LIKE requested_permission || '.%' AND p.value = 'true'
    ) THEN
      RETURN true;
    END IF;
    IF requested_permission = ANY (COALESCE(v_legacy_permissions, ARRAY[]::text[])) THEN
      RETURN true;
    END IF;
    RETURN requested_permission = ANY (ARRAY['pos','customers','sales']::text[])
      AND (SELECT role_id FROM public.store_memberships
           WHERE store_id = v_store_id AND user_id = auth.uid()) IS NULL;
  END IF;

  SELECT ep.is_granted INTO v_override
  FROM public.employee_permissions AS ep
  WHERE ep.store_id = v_store_id AND ep.user_id = auth.uid()
    AND ep.permission_key = requested_permission;
  IF FOUND THEN
    RETURN v_override;
  END IF;

  v_allowed := COALESCE((v_role_permissions ->> requested_permission)::boolean, false);
  IF NOT v_allowed AND requested_permission = ANY (COALESCE(v_legacy_permissions, ARRAY[]::text[])) THEN
    v_allowed := true;
  END IF;
  IF NOT v_allowed
    AND requested_permission = ANY (ARRAY['pos.view','pos.create','sales.view','sales.create','customers.view','customers.create']::text[])
    AND (SELECT role_id FROM public.store_memberships
         WHERE store_id = v_store_id AND user_id = auth.uid()) IS NULL THEN
    v_allowed := true;
  END IF;
  RETURN v_allowed;
END;
$$;
REVOKE ALL ON FUNCTION public.has_store_permission(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_store_permission(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_my_permissions()
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
  WITH role_permissions AS (
    SELECT rp.key AS permission_key
    FROM public.store_memberships AS sm
    JOIN public.roles AS r ON r.id = sm.role_id AND r.store_id = sm.store_id
    CROSS JOIN LATERAL jsonb_each_text(COALESCE(r.permissions, '{}'::jsonb)) AS rp(key, value)
    WHERE sm.store_id = public.get_my_store_id() AND sm.user_id = auth.uid()
      AND sm.status = 'approved' AND rp.value = 'true'
  ),
  legacy_permissions AS (
    SELECT unnest(sm.permissions) AS permission_key
    FROM public.store_memberships AS sm
    WHERE sm.store_id = public.get_my_store_id() AND sm.user_id = auth.uid()
      AND sm.role_id IS NULL AND sm.status = 'approved'
    UNION
    SELECT unnest(ARRAY['pos','sales','customers']::text[])
    FROM public.store_memberships AS sm
    WHERE sm.store_id = public.get_my_store_id() AND sm.user_id = auth.uid()
      AND sm.role_id IS NULL AND sm.status = 'approved'
  ),
  granted_permissions AS (
    SELECT permission_key FROM role_permissions
    UNION
    SELECT permission_key FROM legacy_permissions
    UNION
    SELECT permission_key FROM public.employee_permissions
    WHERE store_id = public.get_my_store_id() AND user_id = auth.uid() AND is_granted
  ),
  effective_permissions AS (
    SELECT DISTINCT granted.permission_key
    FROM granted_permissions AS granted
    WHERE NOT EXISTS (
      SELECT 1 FROM public.employee_permissions AS denied
      WHERE denied.store_id = public.get_my_store_id()
        AND denied.user_id = auth.uid()
        AND denied.permission_key = granted.permission_key
        AND NOT denied.is_granted
    )
  )
  SELECT CASE
    WHEN public.is_store_owner() THEN ARRAY['*']::text[]
    WHEN public.get_my_store_id() IS NULL THEN ARRAY[]::text[]
    ELSE ARRAY(
      SELECT permission_key FROM effective_permissions
      UNION
      SELECT c.module_key FROM public.rbac_permission_catalog AS c
      JOIN effective_permissions AS effective USING (permission_key)
      WHERE c.module_key <> 'actions' AND c.action_key = 'view'
    )
  END;
$$;
REVOKE ALL ON FUNCTION public.get_my_permissions() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_permissions() TO authenticated;

CREATE OR REPLACE FUNCTION public.get_my_store_role_name()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
  SELECT CASE
    WHEN public.is_super_admin() THEN 'Super Admin'
    WHEN public.is_store_owner() THEN 'Store Owner'
    ELSE (
      SELECT r.name
      FROM public.store_memberships AS sm
      JOIN public.roles AS r ON r.id = sm.role_id AND r.store_id = sm.store_id
      JOIN public.profiles AS p ON p.id = sm.user_id
      WHERE sm.store_id = public.get_my_store_id()
        AND sm.user_id = auth.uid()
        AND sm.status = 'approved'
        AND p.role = sm.role
        AND p.status = 'approved'
      LIMIT 1
    )
  END;
$$;
REVOKE ALL ON FUNCTION public.get_my_store_role_name() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_store_role_name() TO authenticated;

CREATE OR REPLACE FUNCTION public.write_employee_activity(
  target_store_id uuid,
  target_user_id uuid,
  target_action text,
  target_module text,
  target_previous jsonb DEFAULT NULL,
  target_new jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
  INSERT INTO public.employee_activity_logs
    (store_id, user_id, action, module, previous_value, new_value)
  VALUES (target_store_id, target_user_id, target_action, target_module, target_previous, target_new);
$$;
REVOKE ALL ON FUNCTION public.write_employee_activity(uuid, uuid, text, text, jsonb, jsonb)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_store_roles()
RETURNS TABLE (id uuid, name text, description text, role_key text, permissions jsonb,
               is_system boolean, is_protected boolean, assigned_employee_count bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE v_store_id uuid;
BEGIN
  IF NOT public.is_store_owner() THEN
    RAISE EXCEPTION 'Only the Store Owner can manage roles' USING ERRCODE = '42501';
  END IF;
  v_store_id := public.get_my_store_id();
  RETURN QUERY
  SELECT r.id, r.name, r.description, r.role_key, r.permissions,
         r.is_system, r.is_protected, count(sm.user_id)
  FROM public.roles AS r
  LEFT JOIN public.store_memberships AS sm ON sm.role_id = r.id
  WHERE r.store_id = v_store_id
  GROUP BY r.id
  ORDER BY r.is_protected DESC, r.name;
END;
$$;
REVOKE ALL ON FUNCTION public.get_store_roles() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_store_roles() TO authenticated;

CREATE OR REPLACE FUNCTION public.manage_store_role(
  operation text,
  target_role_id uuid DEFAULT NULL,
  target_name text DEFAULT NULL,
  target_description text DEFAULT NULL,
  target_permissions jsonb DEFAULT NULL,
  source_role_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE
  v_store_id uuid;
  v_role public.roles%ROWTYPE;
  v_source public.roles%ROWTYPE;
  v_permissions jsonb;
  v_new_id uuid;
BEGIN
  IF NOT public.is_store_owner() THEN
    RAISE EXCEPTION 'Only the Store Owner can manage roles' USING ERRCODE = '42501';
  END IF;
  v_store_id := public.get_my_store_id();

  IF operation = 'delete' THEN
    SELECT * INTO v_role FROM public.roles WHERE id = target_role_id AND store_id = v_store_id FOR UPDATE;
    IF NOT FOUND OR v_role.is_system OR v_role.is_protected THEN
      RAISE EXCEPTION 'This role cannot be deleted' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM public.store_memberships
      WHERE store_id = v_store_id AND role_id = target_role_id) THEN
      RAISE EXCEPTION 'Reassign employees before deleting this role';
    END IF;
    IF EXISTS (SELECT 1 FROM public.store_invitations
      WHERE store_id = v_store_id AND role_id = target_role_id
        AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at > now()) THEN
      RAISE EXCEPTION 'Revoke pending invitations before deleting this role';
    END IF;
    DELETE FROM public.roles WHERE id = target_role_id AND store_id = v_store_id;
    PERFORM public.write_employee_activity(v_store_id, auth.uid(), 'role_deleted', 'employees',
      to_jsonb(v_role), NULL);
    RETURN target_role_id;
  ELSIF operation = 'duplicate' THEN
    SELECT * INTO v_source FROM public.roles
    WHERE id = source_role_id AND store_id = v_store_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Source role was not found'; END IF;
    v_permissions := COALESCE(v_source.permissions, '{}'::jsonb);
    IF target_permissions IS NOT NULL THEN v_permissions := target_permissions; END IF;
  ELSIF operation = 'create' THEN
    v_permissions := COALESCE(target_permissions, '{}'::jsonb);
  ELSIF operation = 'update' THEN
    SELECT * INTO v_role FROM public.roles WHERE id = target_role_id AND store_id = v_store_id FOR UPDATE;
    IF NOT FOUND OR v_role.is_protected THEN
      RAISE EXCEPTION 'This role cannot be modified' USING ERRCODE = '42501';
    END IF;
    v_permissions := COALESCE(target_permissions, v_role.permissions, '{}'::jsonb);
  ELSE
    RAISE EXCEPTION 'Unsupported role operation';
  END IF;

  IF target_name IS NULL OR length(btrim(target_name)) NOT BETWEEN 1 AND 60 THEN
    RAISE EXCEPTION 'Role name must be between 1 and 60 characters';
  END IF;
  IF jsonb_typeof(v_permissions) <> 'object'
    OR EXISTS (
      SELECT 1 FROM jsonb_each(v_permissions) AS permission(key, value)
      WHERE NOT EXISTS (
        SELECT 1 FROM public.rbac_permission_catalog c WHERE c.permission_key = permission.key
      ) OR permission.value <> 'true'::jsonb
    ) THEN
    RAISE EXCEPTION 'Role permissions contain an unknown or invalid permission';
  END IF;

  IF operation = 'update' THEN
    UPDATE public.roles SET name = btrim(target_name), description = target_description,
      permissions = v_permissions
    WHERE id = target_role_id AND store_id = v_store_id
    RETURNING id INTO v_new_id;
    PERFORM public.write_employee_activity(v_store_id, auth.uid(), 'role_updated', 'employees',
      to_jsonb(v_role), jsonb_build_object('id', v_new_id, 'name', btrim(target_name),
      'description', target_description, 'permissions', v_permissions));
  ELSE
    INSERT INTO public.roles (store_id, name, description, role_key, permissions,
                              is_system, is_protected, created_by)
    VALUES (v_store_id, btrim(target_name), target_description, NULL, v_permissions,
            false, false, auth.uid())
    RETURNING id INTO v_new_id;
    PERFORM public.write_employee_activity(v_store_id, auth.uid(),
      CASE WHEN operation = 'duplicate' THEN 'role_duplicated' ELSE 'role_created' END,
      'employees', NULL, jsonb_build_object('id', v_new_id, 'name', btrim(target_name),
      'description', target_description, 'permissions', v_permissions));
  END IF;
  RETURN v_new_id;
END;
$$;
REVOKE ALL ON FUNCTION public.manage_store_role(text, uuid, text, text, jsonb, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_store_role(text, uuid, text, text, jsonb, uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.create_store_employee_invitation(
  target_email text,
  target_role_id uuid,
  target_full_name text,
  target_phone text DEFAULT NULL,
  target_address text DEFAULT NULL,
  target_employee_code text DEFAULT NULL,
  target_joining_date date DEFAULT CURRENT_DATE
)
RETURNS TABLE (invitation_id uuid, invitation_token uuid, invitation_expires_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE
  v_store_id uuid;
  v_role public.roles%ROWTYPE;
BEGIN
  IF NOT public.is_store_owner() THEN
    RAISE EXCEPTION 'Only the Store Owner can invite employees' USING ERRCODE = '42501';
  END IF;
  IF target_email IS NULL OR position('@' IN btrim(target_email)) < 2
    OR target_full_name IS NULL OR length(btrim(target_full_name)) = 0 THEN
    RAISE EXCEPTION 'A valid email and employee name are required';
  END IF;
  v_store_id := public.get_my_store_id();
  SELECT * INTO v_role FROM public.roles WHERE id = target_role_id AND store_id = v_store_id;
  IF NOT FOUND OR v_role.is_protected OR v_role.role_key = 'store_owner' THEN
    RAISE EXCEPTION 'Choose an assignable role in your store';
  END IF;
  IF EXISTS (SELECT 1 FROM public.profiles WHERE lower(email) = lower(btrim(target_email))) THEN
    RAISE EXCEPTION 'This email already has an account';
  END IF;
  IF EXISTS (SELECT 1 FROM public.store_invitations
    WHERE store_id = v_store_id AND lower(email) = lower(btrim(target_email))
      AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at > now()) THEN
    RAISE EXCEPTION 'An active invitation already exists for this email';
  END IF;
  RETURN QUERY
  INSERT INTO public.store_invitations
    (store_id, email, role, permissions, created_by, role_id, full_name, phone,
     address, employee_code, joining_date)
  VALUES
    (v_store_id, lower(btrim(target_email)), 'cashier', ARRAY['pos']::text[],
     auth.uid(), v_role.id, btrim(target_full_name), NULLIF(btrim(target_phone), ''),
     NULLIF(btrim(target_address), ''), NULLIF(btrim(target_employee_code), ''),
     COALESCE(target_joining_date, CURRENT_DATE))
  RETURNING id, token, expires_at;
END;
$$;
REVOKE ALL ON FUNCTION public.create_store_employee_invitation(text, uuid, text, text, text, text, date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_store_employee_invitation(text, uuid, text, text, text, text, date)
  TO authenticated;
REVOKE ALL ON FUNCTION public.create_store_invitation(text, text, text[]) FROM PUBLIC, anon, authenticated;

DROP FUNCTION IF EXISTS public.get_store_team_members();
CREATE OR REPLACE FUNCTION public.get_store_team_members()
RETURNS TABLE (
  user_id uuid, employee_id uuid, email text, full_name text, phone text, address text,
  profile_image text, employee_code text, joining_date date, role text, role_id uuid,
  role_name text, status text, permissions text[], created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
BEGIN
  IF NOT public.is_store_owner() THEN
    RAISE EXCEPTION 'Only the Store Owner can manage employees' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT p.id, e.id, p.email, p.full_name, p.phone, e.address, e.profile_image,
         e.employee_code, e.joining_date, sm.role, sm.role_id, r.name, sm.status,
         sm.permissions, sm.created_at
  FROM public.store_memberships AS sm
  JOIN public.profiles AS p ON p.id = sm.user_id
  LEFT JOIN public.roles AS r ON r.id = sm.role_id AND r.store_id = sm.store_id
  LEFT JOIN public.employees AS e ON e.user_id = sm.user_id AND e.store_id = sm.store_id
  WHERE sm.store_id = public.get_my_store_id()
  ORDER BY sm.created_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.get_store_team_members() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_store_team_members() TO authenticated;

CREATE OR REPLACE FUNCTION public.update_store_employee(
  target_user_id uuid,
  target_full_name text,
  target_phone text DEFAULT NULL,
  target_address text DEFAULT NULL,
  target_profile_image text DEFAULT NULL,
  target_employee_code text DEFAULT NULL,
  target_joining_date date DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE v_store_id uuid; v_previous jsonb; v_next jsonb;
BEGIN
  IF NOT public.is_store_owner() OR target_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Only the Store Owner may edit another employee' USING ERRCODE = '42501';
  END IF;
  IF target_full_name IS NULL OR length(btrim(target_full_name)) = 0 THEN
    RAISE EXCEPTION 'Employee name is required';
  END IF;
  v_store_id := public.get_my_store_id();
  SELECT to_jsonb(e) INTO v_previous
  FROM public.employees e
  JOIN public.store_memberships sm ON sm.store_id = e.store_id AND sm.user_id = e.user_id
  WHERE e.user_id = target_user_id AND e.store_id = v_store_id;
  IF v_previous IS NULL THEN RAISE EXCEPTION 'Employee was not found'; END IF;
  UPDATE public.profiles SET full_name = btrim(target_full_name),
    phone = NULLIF(btrim(target_phone), '')
  WHERE id = target_user_id AND EXISTS (
    SELECT 1 FROM public.store_memberships
    WHERE store_id = v_store_id AND user_id = target_user_id
  );
  UPDATE public.employees SET name = btrim(target_full_name),
    phone = NULLIF(btrim(target_phone), ''), address = NULLIF(btrim(target_address), ''),
    profile_image = NULLIF(btrim(target_profile_image), ''),
    employee_code = NULLIF(btrim(target_employee_code), ''),
    joining_date = target_joining_date
  WHERE user_id = target_user_id AND store_id = v_store_id;
  SELECT to_jsonb(e) INTO v_next FROM public.employees e
  WHERE e.user_id = target_user_id AND e.store_id = v_store_id;
  PERFORM public.write_employee_activity(v_store_id, auth.uid(), 'employee_updated',
    'employees', v_previous, v_next);
END;
$$;
REVOKE ALL ON FUNCTION public.update_store_employee(uuid, text, text, text, text, text, date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_store_employee(uuid, text, text, text, text, text, date)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.manage_store_member(
  target_user_id uuid,
  target_status text,
  target_role text DEFAULT NULL,
  target_permissions text[] DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE
  v_store_id uuid;
  v_old_role_id uuid;
  v_next_role_id uuid;
  v_previous_status text;
  v_new_status text;
  v_role public.roles%ROWTYPE;
BEGIN
  IF NOT public.is_store_owner() OR target_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Only the Store Owner may manage another employee' USING ERRCODE = '42501';
  END IF;
  IF target_status NOT IN ('approved', 'suspended', 'rejected') THEN
    RAISE EXCEPTION 'Unsupported employee status';
  END IF;
  v_store_id := public.get_my_store_id();
  SELECT sm.role_id, sm.status INTO v_old_role_id, v_previous_status
  FROM public.store_memberships sm
  WHERE sm.store_id = v_store_id AND sm.user_id = target_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Employee was not found'; END IF;
  v_next_role_id := v_old_role_id;
  IF target_role IS NOT NULL THEN
    SELECT * INTO v_role FROM public.roles
    WHERE store_id = v_store_id AND (role_key = target_role OR name = target_role);
    IF NOT FOUND OR v_role.is_protected OR v_role.role_key = 'store_owner' THEN
      RAISE EXCEPTION 'This role cannot be assigned' USING ERRCODE = '42501';
    END IF;
    v_next_role_id := v_role.id;
  END IF;
  IF target_permissions IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM unnest(target_permissions) AS requested(permission)
      WHERE NOT EXISTS (
        SELECT 1 FROM public.rbac_permission_catalog c
        WHERE c.permission_key = requested.permission
      )
    ) THEN RAISE EXCEPTION 'Unknown employee permission'; END IF;
    DELETE FROM public.employee_permissions
    WHERE store_id = v_store_id AND user_id = target_user_id;
    INSERT INTO public.employee_permissions
      (store_id, user_id, permission_key, is_granted, updated_by)
    SELECT v_store_id, target_user_id, permission_key, true, auth.uid()
    FROM unnest(target_permissions) AS permission_key;
  END IF;
  UPDATE public.store_memberships SET role_id = v_next_role_id,
    status = CASE WHEN target_status = 'approved' THEN 'approved' ELSE target_status END,
    role = 'cashier', permissions = ARRAY['pos']::text[], updated_at = now()
  WHERE store_id = v_store_id AND user_id = target_user_id;
  v_new_status := CASE WHEN target_status = 'approved' THEN 'approved' ELSE target_status END;
  UPDATE public.profiles SET role = 'cashier', status = v_new_status
  WHERE id = target_user_id AND role = 'cashier';
  UPDATE public.employees SET status = CASE WHEN v_new_status = 'approved' THEN 'active' ELSE 'inactive' END
  WHERE user_id = target_user_id AND store_id = v_store_id;
  PERFORM public.write_employee_activity(v_store_id, auth.uid(),
    CASE WHEN v_previous_status IS DISTINCT FROM v_new_status
      THEN 'employee_status_changed' ELSE 'employee_role_changed' END,
    'employees',
    jsonb_build_object('role_id', v_old_role_id, 'status', v_previous_status),
    jsonb_build_object('role_id', v_next_role_id, 'status', v_new_status));
END;
$$;
REVOKE ALL ON FUNCTION public.manage_store_member(uuid, text, text, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_store_member(uuid, text, text, text[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_store_employee_permission(
  target_user_id uuid,
  target_permission_key text,
  permission_state text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE v_store_id uuid; v_previous boolean;
BEGIN
  IF NOT public.is_store_owner() OR target_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Only the Store Owner may change another employee permissions' USING ERRCODE = '42501';
  END IF;
  IF permission_state NOT IN ('allow', 'deny', 'inherit')
    OR NOT EXISTS (SELECT 1 FROM public.rbac_permission_catalog
      WHERE permission_key = target_permission_key) THEN
    RAISE EXCEPTION 'Invalid permission override';
  END IF;
  v_store_id := public.get_my_store_id();
  IF NOT EXISTS (SELECT 1 FROM public.store_memberships
    WHERE store_id = v_store_id AND user_id = target_user_id) THEN
    RAISE EXCEPTION 'Employee was not found';
  END IF;
  SELECT is_granted INTO v_previous FROM public.employee_permissions
  WHERE store_id = v_store_id AND user_id = target_user_id
    AND permission_key = target_permission_key;
  DELETE FROM public.employee_permissions
  WHERE store_id = v_store_id AND user_id = target_user_id
    AND permission_key = target_permission_key;
  IF permission_state <> 'inherit' THEN
    INSERT INTO public.employee_permissions
      (store_id, user_id, permission_key, is_granted, updated_by)
    VALUES (v_store_id, target_user_id, target_permission_key,
      permission_state = 'allow', auth.uid());
  END IF;
  PERFORM public.write_employee_activity(v_store_id, auth.uid(), 'employee_permission_changed',
    'employees', jsonb_build_object('permission', target_permission_key,
      'granted', v_previous),
    jsonb_build_object('permission', target_permission_key,
      'state', permission_state));
END;
$$;
REVOKE ALL ON FUNCTION public.set_store_employee_permission(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_store_employee_permission(uuid, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.set_store_employee_permission_overrides(
  target_user_id uuid,
  target_overrides jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE
  v_store_id uuid;
  v_previous jsonb;
  v_next jsonb;
  v_override record;
BEGIN
  IF NOT public.is_store_owner() OR target_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Only the Store Owner may change another employee permissions' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(target_overrides) <> 'object' THEN
    RAISE EXCEPTION 'Permission overrides must be an object';
  END IF;
  v_store_id := public.get_my_store_id();
  IF NOT EXISTS (SELECT 1 FROM public.store_memberships
    WHERE store_id = v_store_id AND user_id = target_user_id) THEN
    RAISE EXCEPTION 'Employee was not found';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_each_text(target_overrides) AS item(permission_key, state)
    WHERE item.state NOT IN ('allow', 'deny', 'inherit')
      OR NOT EXISTS (
        SELECT 1 FROM public.rbac_permission_catalog c
        WHERE c.permission_key = item.permission_key
      )
  ) THEN
    RAISE EXCEPTION 'Permission overrides contain an unknown key or state';
  END IF;

  SELECT COALESCE(jsonb_object_agg(permission_key, is_granted), '{}'::jsonb)
  INTO v_previous
  FROM public.employee_permissions
  WHERE store_id = v_store_id AND user_id = target_user_id;

  FOR v_override IN
    SELECT permission_key, state
    FROM jsonb_each_text(target_overrides) AS item(permission_key, state)
  LOOP
    DELETE FROM public.employee_permissions
    WHERE store_id = v_store_id AND user_id = target_user_id
      AND permission_key = v_override.permission_key;
    IF v_override.state <> 'inherit' THEN
      INSERT INTO public.employee_permissions
        (store_id, user_id, permission_key, is_granted, updated_by)
      VALUES (v_store_id, target_user_id, v_override.permission_key,
        v_override.state = 'allow', auth.uid());
    END IF;
  END LOOP;

  SELECT COALESCE(jsonb_object_agg(permission_key, is_granted), '{}'::jsonb)
  INTO v_next
  FROM public.employee_permissions
  WHERE store_id = v_store_id AND user_id = target_user_id;
  PERFORM public.write_employee_activity(v_store_id, auth.uid(),
    'employee_permissions_changed', 'employees', v_previous, v_next);
END;
$$;
REVOKE ALL ON FUNCTION public.set_store_employee_permission_overrides(uuid, jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_store_employee_permission_overrides(uuid, jsonb)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.get_store_employee_permissions(target_user_id uuid)
RETURNS TABLE (permission_key text, is_granted boolean, is_overridden boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE v_store_id uuid;
BEGIN
  IF NOT public.is_store_owner() THEN
    RAISE EXCEPTION 'Only the Store Owner can view employee permissions' USING ERRCODE = '42501';
  END IF;
  v_store_id := public.get_my_store_id();
  IF NOT EXISTS (SELECT 1 FROM public.store_memberships
    WHERE store_id = v_store_id AND user_id = target_user_id) THEN
    RAISE EXCEPTION 'Employee was not found';
  END IF;
  RETURN QUERY
  SELECT c.permission_key,
    COALESCE(ep.is_granted, (r.permissions ->> c.permission_key)::boolean, false),
    ep.permission_key IS NOT NULL
  FROM public.rbac_permission_catalog c
  JOIN public.store_memberships sm ON sm.store_id = v_store_id AND sm.user_id = target_user_id
  LEFT JOIN public.roles r ON r.id = sm.role_id AND r.store_id = sm.store_id
  LEFT JOIN public.employee_permissions ep ON ep.store_id = sm.store_id
    AND ep.user_id = sm.user_id AND ep.permission_key = c.permission_key
  ORDER BY c.sort_order;
END;
$$;
REVOKE ALL ON FUNCTION public.get_store_employee_permissions(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_store_employee_permissions(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_store_employee_activity(target_user_id uuid DEFAULT NULL)
RETURNS TABLE (id bigint, user_id uuid, action text, module text, previous_value jsonb,
               new_value jsonb, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
BEGIN
  IF NOT public.is_store_owner() THEN
    RAISE EXCEPTION 'Only the Store Owner can view employee activity' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT l.id, l.user_id, l.action, l.module, l.previous_value, l.new_value, l.created_at
  FROM public.employee_activity_logs l
  WHERE l.store_id = public.get_my_store_id()
    AND (target_user_id IS NULL OR l.user_id = target_user_id)
  ORDER BY l.created_at DESC LIMIT 200;
END;
$$;
REVOKE ALL ON FUNCTION public.get_store_employee_activity(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_store_employee_activity(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.log_employee_session_activity(target_action text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
BEGIN
  IF target_action NOT IN ('login', 'logout') THEN
    RAISE EXCEPTION 'Unsupported session activity';
  END IF;
  IF public.get_my_store_id() IS NOT NULL THEN
    PERFORM public.write_employee_activity(public.get_my_store_id(), auth.uid(),
      target_action, 'authentication', NULL, NULL);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.log_employee_session_activity(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.log_employee_session_activity(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.handle_new_user_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE
  v_full_name text;
  v_profile_email text;
  v_profile_role text;
  v_profile_store_id uuid;
  v_store_id uuid;
  v_store_count integer;
  v_invitation public.store_invitations%ROWTYPE;
  v_invitation_token uuid;
BEGIN
  IF NEW.email IS NULL OR NULLIF(pg_catalog.btrim(NEW.email), '') IS NULL THEN
    RAISE EXCEPTION 'A valid email is required to create an account';
  END IF;
  v_full_name := COALESCE(
    NULLIF(pg_catalog.btrim(NEW.raw_user_meta_data ->> 'full_name'), ''),
    NULLIF(pg_catalog.btrim(NEW.raw_user_meta_data ->> 'name'), ''),
    NULLIF(pg_catalog.split_part(NEW.email, '@', 1), ''), 'New User'
  );

  IF NULLIF(pg_catalog.btrim(NEW.raw_user_meta_data ->> 'employee_invite_token'), '') IS NOT NULL THEN
    BEGIN
      v_invitation_token := (NEW.raw_user_meta_data ->> 'employee_invite_token')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'Employee invitation is invalid';
    END;
    UPDATE public.store_invitations AS invitation
    SET consumed_at = now()
    WHERE invitation.token = v_invitation_token
      AND pg_catalog.lower(invitation.email) = pg_catalog.lower(NEW.email)
      AND EXISTS (
        SELECT 1 FROM public.stores s
        JOIN public.profiles owner ON owner.id = s.owner_id
        WHERE s.id = invitation.store_id AND owner.store_id = s.id
          AND owner.role IN ('admin', 'store_owner') AND owner.status = 'approved'
      )
      AND invitation.consumed_at IS NULL AND invitation.revoked_at IS NULL
      AND invitation.expires_at > now()
    RETURNING invitation.* INTO v_invitation;
    IF NOT FOUND THEN RAISE EXCEPTION 'Employee invitation is invalid, expired, or already used'; END IF;

    INSERT INTO public.profiles (id, email, full_name, phone, role, status)
    VALUES (NEW.id, NEW.email, COALESCE(v_invitation.full_name, v_full_name),
      COALESCE(v_invitation.phone, NULLIF(pg_catalog.btrim(NEW.raw_user_meta_data ->> 'phone'), '')),
      'cashier', 'approved');
    INSERT INTO public.store_memberships (store_id, user_id, role, status, permissions, role_id)
    VALUES (v_invitation.store_id, NEW.id, 'cashier', 'approved',
      COALESCE(v_invitation.permissions, ARRAY['pos']::text[]), v_invitation.role_id);
    INSERT INTO public.employees
      (store_id, user_id, name, email, phone, address, employee_code, joining_date, status)
    VALUES (v_invitation.store_id, NEW.id, COALESCE(v_invitation.full_name, v_full_name),
      NEW.email, COALESCE(v_invitation.phone, NULLIF(pg_catalog.btrim(NEW.raw_user_meta_data ->> 'phone'), '')),
      v_invitation.address, v_invitation.employee_code,
      COALESCE(v_invitation.joining_date, CURRENT_DATE), 'active');
    IF v_invitation.role_id IS NOT NULL THEN
      PERFORM public.write_employee_activity(v_invitation.store_id, v_invitation.created_by,
        'employee_created', 'employees', NULL,
        jsonb_build_object('email', NEW.email, 'role_id', v_invitation.role_id));
    END IF;
    RETURN NEW;
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(NEW.id::text, 0));
  INSERT INTO public.profiles (id, email, full_name, phone, role, status)
  VALUES (NEW.id, NEW.email, v_full_name,
    NULLIF(pg_catalog.btrim(NEW.raw_user_meta_data ->> 'phone'), ''), 'admin', 'pending')
  ON CONFLICT (id) DO NOTHING;
  SELECT p.email, p.role, p.store_id
  INTO v_profile_email, v_profile_role, v_profile_store_id
  FROM public.profiles p WHERE p.id = NEW.id FOR UPDATE;
  IF NOT FOUND OR pg_catalog.lower(v_profile_email) <> pg_catalog.lower(NEW.email)
    OR v_profile_role NOT IN ('admin', 'store_owner') THEN
    RAISE EXCEPTION 'An incompatible profile exists for this Auth user';
  END IF;
  SELECT count(*), (pg_catalog.array_agg(s.id))[1]
  INTO v_store_count, v_store_id FROM public.stores s WHERE s.owner_id = NEW.id;
  IF v_store_count > 1 THEN
    RAISE EXCEPTION 'This account owns multiple stores; resolve ownership before signup can continue';
  ELSIF v_store_count = 0 THEN
    IF v_profile_store_id IS NOT NULL THEN RAISE EXCEPTION 'The profile references a store it does not own'; END IF;
    INSERT INTO public.stores (owner_id, store_name, store_phone, store_address)
    VALUES (NEW.id, COALESCE(NULLIF(pg_catalog.btrim(NEW.raw_user_meta_data ->> 'store_name'), ''),
      v_full_name || '''s Store'),
      NULLIF(pg_catalog.btrim(NEW.raw_user_meta_data ->> 'store_phone'), ''),
      NULLIF(pg_catalog.btrim(NEW.raw_user_meta_data ->> 'store_address'), ''))
    RETURNING id INTO v_store_id;
  ELSIF v_profile_store_id IS NOT NULL AND v_profile_store_id <> v_store_id THEN
    RAISE EXCEPTION 'The profile is linked to a different store than its owner record';
  END IF;
  UPDATE public.profiles SET store_id = v_store_id
  WHERE id = NEW.id AND store_id IS DISTINCT FROM v_store_id;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.handle_new_user_profile() FROM PUBLIC, anon, authenticated;

DROP FUNCTION IF EXISTS public.get_store_invitations();
CREATE FUNCTION public.get_store_invitations()
RETURNS TABLE (
  invitation_id uuid, email text, role text, permissions text[], created_at timestamptz,
  expires_at timestamptz, role_id uuid, role_name text, full_name text, phone text,
  address text, employee_code text, joining_date date
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
BEGIN
  IF NOT public.is_store_owner() THEN
    RAISE EXCEPTION 'Only the Store Owner can view invitations' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT i.id, i.email, i.role, i.permissions, i.created_at, i.expires_at, i.role_id,
         r.name, i.full_name, i.phone, i.address, i.employee_code, i.joining_date
  FROM public.store_invitations i
  LEFT JOIN public.roles r ON r.id = i.role_id AND r.store_id = i.store_id
  WHERE i.store_id = public.get_my_store_id() AND i.consumed_at IS NULL
    AND i.revoked_at IS NULL AND i.expires_at > now()
  ORDER BY i.created_at DESC;
END;
$$;
REVOKE ALL ON FUNCTION public.get_store_invitations() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_store_invitations() TO authenticated;

CREATE OR REPLACE FUNCTION public.revoke_store_invitation(target_invitation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
BEGIN
  IF NOT public.is_store_owner() THEN
    RAISE EXCEPTION 'Only the Store Owner can revoke employee invitations' USING ERRCODE = '42501';
  END IF;
  UPDATE public.store_invitations
  SET revoked_at = now()
  WHERE id = target_invitation_id
    AND store_id = public.get_my_store_id()
    AND consumed_at IS NULL AND revoked_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Active invitation was not found'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.revoke_store_invitation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.revoke_store_invitation(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.record_employee_activity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
DECLARE v_row jsonb; v_previous jsonb; v_next jsonb; v_store_id uuid; v_action text;
BEGIN
  IF TG_OP = 'DELETE' THEN v_row := to_jsonb(OLD); ELSE v_row := to_jsonb(NEW); END IF;
  v_store_id := (v_row ->> 'store_id')::uuid;
  IF TG_OP <> 'INSERT' THEN v_previous := to_jsonb(OLD); END IF;
  IF TG_OP <> 'DELETE' THEN v_next := to_jsonb(NEW); END IF;
  v_action := lower(TG_ARGV[0]) || '_' || lower(TG_OP);
  IF v_store_id IS NOT NULL THEN
    PERFORM public.write_employee_activity(v_store_id, auth.uid(), v_action, TG_ARGV[0],
      v_previous, v_next);
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.record_employee_activity() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS employee_activity_sales ON public.sales;
CREATE TRIGGER employee_activity_sales AFTER INSERT OR UPDATE OR DELETE ON public.sales
  FOR EACH ROW EXECUTE FUNCTION public.record_employee_activity('sales');
DROP TRIGGER IF EXISTS employee_activity_stock_adjustments ON public.stock_adjustments;
CREATE TRIGGER employee_activity_stock_adjustments AFTER INSERT OR UPDATE OR DELETE ON public.stock_adjustments
  FOR EACH ROW EXECUTE FUNCTION public.record_employee_activity('inventory');
DROP TRIGGER IF EXISTS employee_activity_stock_reconciliations ON public.stock_reconciliations;
CREATE TRIGGER employee_activity_stock_reconciliations AFTER INSERT OR UPDATE OR DELETE ON public.stock_reconciliations
  FOR EACH ROW EXECUTE FUNCTION public.record_employee_activity('stock_reconciliation');
DROP TRIGGER IF EXISTS employee_activity_settings ON public.settings;
CREATE TRIGGER employee_activity_settings AFTER INSERT OR UPDATE OR DELETE ON public.settings
  FOR EACH ROW EXECUTE FUNCTION public.record_employee_activity('settings');

CREATE OR REPLACE FUNCTION public.guard_employee_sensitive_actions()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_old jsonb;
  v_new jsonb := to_jsonb(NEW);
  v_old_stock numeric;
  v_new_stock numeric;
BEGIN
  IF TG_OP <> 'INSERT' THEN v_old := to_jsonb(OLD); END IF;
  IF TG_TABLE_NAME = 'products' AND TG_OP = 'INSERT'
    AND COALESCE((v_new ->> 'cost_price')::numeric, 0) > 0
    AND NOT public.has_store_permission('actions.view_purchase_price') THEN
    RAISE EXCEPTION 'Setting purchase prices is not permitted' USING ERRCODE = '42501';
  END IF;
  IF TG_TABLE_NAME = 'products' AND TG_OP = 'UPDATE' THEN
    IF v_old -> 'selling_price' IS DISTINCT FROM v_new -> 'selling_price'
      AND NOT public.has_store_permission('actions.change_selling_price') THEN
      RAISE EXCEPTION 'Changing a product selling price is not permitted' USING ERRCODE = '42501';
    END IF;
    IF v_old -> 'cost_price' IS DISTINCT FROM v_new -> 'cost_price'
      AND NOT public.has_store_permission('actions.view_purchase_price') THEN
      RAISE EXCEPTION 'Changing purchase prices is not permitted' USING ERRCODE = '42501';
    END IF;
    v_old_stock := NULLIF(v_old ->> 'stock', '')::numeric;
    v_new_stock := NULLIF(v_new ->> 'stock', '')::numeric;
    IF v_new_stock IS NULL THEN
      RAISE EXCEPTION 'Stock cannot be set to null' USING ERRCODE = '22004';
    END IF;
    v_old_stock := COALESCE(v_old_stock, 0);
    IF v_new_stock IS DISTINCT FROM v_old_stock THEN
      IF current_user = 'authenticated' THEN
        IF (v_new_stock > v_old_stock AND NOT public.has_store_permission('actions.adjust_stock_increase'))
          OR (v_new_stock < v_old_stock AND NOT public.has_store_permission('actions.adjust_stock_decrease')) THEN
          RAISE EXCEPTION 'This stock adjustment direction is not permitted' USING ERRCODE = '42501';
        END IF;
      ELSIF (v_new_stock > v_old_stock AND NOT (
          public.has_store_permission('actions.adjust_stock_increase')
          OR public.has_store_permission('purchases.create')
          OR public.has_store_permission('actions.process_sale_return')
        )) OR (v_new_stock < v_old_stock AND NOT (
          public.has_store_permission('actions.adjust_stock_decrease')
          OR public.has_store_permission('sales.create')
          OR public.has_store_permission('actions.process_purchase_return')
        )) THEN
        RAISE EXCEPTION 'This stock adjustment direction is not permitted' USING ERRCODE = '42501';
      END IF;
    END IF;
  ELSIF TG_TABLE_NAME = 'sales' THEN
    IF COALESCE((v_new ->> 'discount')::numeric, 0) > 0
      AND NOT public.has_store_permission('actions.apply_discount') THEN
      RAISE EXCEPTION 'Applying discounts is not permitted' USING ERRCODE = '42501';
    END IF;
  ELSIF TG_TABLE_NAME = 'sale_items' THEN
    IF COALESCE((v_new ->> 'discount_amount')::numeric, 0) > 0
      AND NOT public.has_store_permission('actions.apply_discount') THEN
      RAISE EXCEPTION 'Applying discounts is not permitted' USING ERRCODE = '42501';
    END IF;
  ELSIF TG_TABLE_NAME = 'sale_returns' THEN
    IF NOT public.has_store_permission('actions.process_sale_return') THEN
      RAISE EXCEPTION 'Processing sales returns is not permitted' USING ERRCODE = '42501';
    END IF;
  ELSIF TG_TABLE_NAME = 'purchase_returns' THEN
    IF NOT public.has_store_permission('actions.process_purchase_return') THEN
      RAISE EXCEPTION 'Processing purchase returns is not permitted' USING ERRCODE = '42501';
    END IF;
  ELSIF TG_TABLE_NAME = 'settings' THEN
    IF NOT public.has_store_permission('actions.manage_store_settings') THEN
      RAISE EXCEPTION 'Managing store settings is not permitted' USING ERRCODE = '42501';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_employee_sensitive_actions() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS guard_employee_product_price ON public.products;
CREATE TRIGGER guard_employee_product_price
  BEFORE INSERT OR UPDATE ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.guard_employee_sensitive_actions();
DROP TRIGGER IF EXISTS guard_employee_sale_discount ON public.sales;
CREATE TRIGGER guard_employee_sale_discount
  BEFORE INSERT OR UPDATE ON public.sales
  FOR EACH ROW EXECUTE FUNCTION public.guard_employee_sensitive_actions();
DROP TRIGGER IF EXISTS guard_employee_sale_item_discount ON public.sale_items;
CREATE TRIGGER guard_employee_sale_item_discount
  BEFORE INSERT OR UPDATE ON public.sale_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_employee_sensitive_actions();
DROP TRIGGER IF EXISTS guard_employee_sale_return ON public.sale_returns;
CREATE TRIGGER guard_employee_sale_return
  BEFORE INSERT OR UPDATE ON public.sale_returns
  FOR EACH ROW EXECUTE FUNCTION public.guard_employee_sensitive_actions();
DROP TRIGGER IF EXISTS guard_employee_purchase_return ON public.purchase_returns;
CREATE TRIGGER guard_employee_purchase_return
  BEFORE INSERT OR UPDATE ON public.purchase_returns
  FOR EACH ROW EXECUTE FUNCTION public.guard_employee_sensitive_actions();
DROP TRIGGER IF EXISTS guard_employee_settings ON public.settings;
CREATE TRIGGER guard_employee_settings
  BEFORE INSERT OR UPDATE OR DELETE ON public.settings
  FOR EACH ROW EXECUTE FUNCTION public.guard_employee_sensitive_actions();

DO $$
DECLARE
  v_definition text;
  v_updated text;
  v_signature regprocedure;
BEGIN
  v_signature := to_regprocedure(
    'public.adjust_inventory_stock(uuid,text,numeric,text,text,numeric)'
  );
  IF v_signature IS NULL THEN RAISE EXCEPTION 'Expected stock adjustment RPC is missing'; END IF;
  v_definition := pg_get_functiondef(v_signature);
  v_updated := regexp_replace(
    v_definition,
    'IF public\.has_store_permission\(''inventory''\) IS DISTINCT FROM true\s+AND NOT \(\s+p_direction = ''in''\s+AND p_reason = ''Opening Stock''\s+AND public\.has_store_permission\(''products''\) IS TRUE\s+\) THEN',
    'IF NOT ((p_direction = ''in'' AND public.has_store_permission(''actions.adjust_stock_increase'')) OR (p_direction = ''out'' AND public.has_store_permission(''actions.adjust_stock_decrease'')) OR (p_direction = ''in'' AND p_reason = ''Opening Stock'' AND public.has_store_permission(''products.create''))) THEN',
    'g'
  );
  IF v_updated = v_definition THEN
    RAISE EXCEPTION 'Could not safely update the stock-adjustment permission check';
  END IF;
  v_updated := replace(
    v_updated,
    'public.has_store_permission(''products'') IS DISTINCT FROM true',
    '(public.has_store_permission(''products.edit'') IS DISTINCT FROM true OR public.has_store_permission(''actions.view_purchase_price'') IS DISTINCT FROM true)'
  );
  EXECUTE v_updated;

  v_signature := to_regprocedure(
    'public.apply_stock_reconciliation_adjustment(uuid,numeric,text)'
  );
  IF v_signature IS NULL THEN RAISE EXCEPTION 'Expected stock reconciliation RPC is missing'; END IF;
  v_definition := pg_get_functiondef(v_signature);
  v_updated := replace(
    v_definition,
    'public.has_store_permission(''inventory'') IS DISTINCT FROM true',
    'public.has_store_permission(''stock_reconciliation.edit'') IS DISTINCT FROM true'
  );
  IF v_updated = v_definition THEN
    RAISE EXCEPTION 'Could not safely update the stock reconciliation permission check';
  END IF;
  v_definition := v_updated;
  v_updated := replace(
    v_definition,
    'v_difference := v_new_stock - v_current_stock;',
    'v_difference := v_new_stock - v_current_stock;' || E'\n' ||
    '   IF (v_difference > 0 AND NOT public.has_store_permission(''actions.adjust_stock_increase'')) OR (v_difference < 0 AND NOT public.has_store_permission(''actions.adjust_stock_decrease'')) THEN' || E'\n' ||
    '     RAISE EXCEPTION ''This stock adjustment direction is not permitted'' USING ERRCODE = ''42501'';' || E'\n' ||
    '   END IF;'
  );
  IF v_updated = v_definition THEN
    RAISE EXCEPTION 'Could not safely add a direction-specific reconciliation permission check';
  END IF;
  EXECUTE v_updated;

  FOR v_signature IN
    SELECT p.oid::regprocedure
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'complete_pos_sale'
  LOOP
    v_definition := pg_get_functiondef(v_signature);
    v_updated := replace(
      v_definition,
      'IF NOT (SELECT public.has_store_permission(''pos'')) THEN',
      'IF public.has_store_permission(''pos.create'') IS DISTINCT FROM true OR public.has_store_permission(''sales.create'') IS DISTINCT FROM true THEN'
    );
    IF v_updated = v_definition THEN
      RAISE EXCEPTION 'Could not safely update the POS permission check for %', v_signature;
    END IF;
    v_definition := v_updated;
    IF position('p_offer_id uuid' IN pg_get_function_arguments(v_signature)) > 0 THEN
      v_updated := replace(
        v_definition,
        'RETURN public.complete_pos_sale_internal(',
        'IF COALESCE(p_discount, 0) > 0 OR p_offer_id IS NOT NULL OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_cart) AS cart_item(value) WHERE COALESCE((cart_item.value ->> ''discount_value'')::numeric, 0) > 0 OR COALESCE((cart_item.value ->> ''discount_amount'')::numeric, 0) > 0) THEN' || E'\n' ||
        '    IF NOT public.has_store_permission(''actions.apply_discount'') THEN RAISE EXCEPTION ''Applying discounts is not permitted'' USING ERRCODE = ''42501''; END IF;' || E'\n' ||
        '  END IF;' || E'\n' ||
        '  RETURN public.complete_pos_sale_internal('
      );
    ELSE
      v_updated := replace(
        v_definition,
        'RETURN public.complete_pos_sale_internal(',
        'IF COALESCE(p_discount, 0) > 0 OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_cart) AS cart_item(value) WHERE COALESCE((cart_item.value ->> ''discount_value'')::numeric, 0) > 0 OR COALESCE((cart_item.value ->> ''discount_amount'')::numeric, 0) > 0) THEN' || E'\n' ||
        '    IF NOT public.has_store_permission(''actions.apply_discount'') THEN RAISE EXCEPTION ''Applying discounts is not permitted'' USING ERRCODE = ''42501''; END IF;' || E'\n' ||
        '  END IF;' || E'\n' ||
        '  RETURN public.complete_pos_sale_internal('
      );
    END IF;
    IF v_updated = v_definition THEN
      RAISE EXCEPTION 'Could not safely add POS discount validation for %', v_signature;
    END IF;
    EXECUTE v_updated;
  END LOOP;

  v_signature := to_regprocedure(
    'public.get_sales_profit_summary(timestamptz,timestamptz,text,uuid,text,numeric,numeric,uuid[],uuid[],uuid[],text[])'
  );
  IF v_signature IS NOT NULL THEN
    v_definition := pg_get_functiondef(v_signature);
    v_updated := replace(
      v_definition,
      'WHERE s.status = ''completed''',
      'WHERE public.has_store_permission(''actions.view_profit'') AND public.has_store_permission(''actions.view_financial_reports'') AND s.status = ''completed'''
    );
    IF v_updated = v_definition THEN
      RAISE EXCEPTION 'Could not safely protect the sales profit summary';
    END IF;
    EXECUTE v_updated;
  END IF;
END;
$$;

DO $$
DECLARE
  v_item record;
  v_read_permission text;
BEGIN
  FOR v_item IN SELECT * FROM (VALUES
    ('audit_logs','reports'), ('bank_accounts','reports'), ('bank_transactions','reports'),
    ('barcode_history','barcode'), ('brands','brands'), ('cash_transactions','reports'),
    ('categories','categories'), ('customer_discount_history','discount_offers'),
    ('customer_discount_offers','discount_offers'), ('customer_groups','customers'),
    ('customer_payments','customers'), ('customers','customers'),
    ('discount_offer_usage','discount_offers'), ('discount_offers','discount_offers'),
    ('employees','employees'), ('expense_categories','expenses'), ('expenses','expenses'),
    ('held_orders','pos'), ('product_variants','products'), ('products','products'),
    ('purchase_items','purchases'), ('purchase_return_items','purchase_returns'),
    ('purchase_returns','purchase_returns'), ('purchases','purchases'), ('sale_items','sales'),
    ('sale_return_items','sale_returns'), ('sale_returns','sale_returns'), ('sales','sales'),
    ('settings','settings'), ('stock_adjustments','stock_reconciliation'),
    ('stock_movements','inventory'), ('stock_reconciliations','stock_reconciliation'),
    ('supplier_payments','purchases'), ('suppliers','suppliers'), ('units','units')
  ) AS mapping(table_name, module_key)
  LOOP
    IF EXISTS (SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = v_item.table_name AND column_name = 'store_id') THEN
      v_read_permission := format('public.has_store_permission(%L)', v_item.module_key || '.view');
      IF v_item.table_name IN ('products', 'product_variants') THEN
        v_read_permission := '(public.has_store_permission(''products.view'') OR public.has_store_permission(''pos.view'') OR public.has_store_permission(''inventory.view'') OR public.has_store_permission(''purchases.view''))';
      ELSIF v_item.table_name IN ('brands', 'categories') THEN
        v_read_permission := '(public.has_store_permission(''products.view'') OR public.has_store_permission(''pos.view''))';
      ELSIF v_item.table_name = 'units' THEN
        v_read_permission := '(public.has_store_permission(''units.view'') OR public.has_store_permission(''inventory.view'') OR public.has_store_permission(''pos.view''))';
      ELSIF v_item.table_name IN ('sales', 'sale_items', 'sale_returns', 'sale_return_items') THEN
        v_read_permission := '(public.has_store_permission(''sales.view'') OR public.has_store_permission(''reports.view'') OR public.has_store_permission(''sale_returns.view''))';
      ELSIF v_item.table_name IN ('customers', 'customer_groups', 'customer_payments') THEN
        v_read_permission := '(public.has_store_permission(''customers.view'') OR public.has_store_permission(''pos.view'') OR public.has_store_permission(''reports.view''))';
      ELSIF v_item.table_name IN ('discount_offers', 'customer_discount_offers', 'discount_offer_usage', 'customer_discount_history') THEN
        v_read_permission := '(public.has_store_permission(''discount_offers.view'') OR public.has_store_permission(''pos.view''))';
      ELSIF v_item.table_name IN ('stock_adjustments', 'stock_reconciliations') THEN
        v_read_permission := '(public.has_store_permission(''stock_reconciliation.view'') OR public.has_store_permission(''inventory.view''))';
      ELSIF v_item.table_name = 'barcode_history' THEN
        v_read_permission := '(public.has_store_permission(''barcode.view'') OR public.has_store_permission(''inventory.view''))';
      END IF;
      EXECUTE format('DROP POLICY IF EXISTS rbac_action_select ON public.%I', v_item.table_name);
      EXECUTE format('DROP POLICY IF EXISTS rbac_action_insert ON public.%I', v_item.table_name);
      EXECUTE format('DROP POLICY IF EXISTS rbac_action_update ON public.%I', v_item.table_name);
      EXECUTE format('DROP POLICY IF EXISTS rbac_action_delete ON public.%I', v_item.table_name);
      EXECUTE format(
        'CREATE POLICY rbac_action_select ON public.%I AS RESTRICTIVE FOR SELECT TO authenticated USING (store_id = (SELECT public.get_my_store_id()) AND (%s))',
        v_item.table_name, v_read_permission);
      EXECUTE format(
        'CREATE POLICY rbac_action_insert ON public.%I AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (store_id = (SELECT public.get_my_store_id()) AND (SELECT public.has_store_permission(%L)))',
        v_item.table_name, v_item.module_key || '.create');
      EXECUTE format(
        'CREATE POLICY rbac_action_update ON public.%I AS RESTRICTIVE FOR UPDATE TO authenticated USING (store_id = (SELECT public.get_my_store_id()) AND (SELECT public.has_store_permission(%L))) WITH CHECK (store_id = (SELECT public.get_my_store_id()) AND (SELECT public.has_store_permission(%L)))',
        v_item.table_name, v_item.module_key || '.edit', v_item.module_key || '.edit');
      EXECUTE format(
        'CREATE POLICY rbac_action_delete ON public.%I AS RESTRICTIVE FOR DELETE TO authenticated USING (store_id = (SELECT public.get_my_store_id()) AND (SELECT public.has_store_permission(%L)))',
        v_item.table_name, v_item.module_key || '.delete');
    END IF;
  END LOOP;
END;
$$;

REVOKE ALL ON public.roles FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.store_memberships, public.store_invitations, public.employees
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.employee_permissions, public.employee_activity_logs,
  public.rbac_permission_catalog FROM PUBLIC, anon, authenticated;

COMMIT;
