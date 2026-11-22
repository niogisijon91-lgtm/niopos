BEGIN;

DO $migration$
BEGIN
  IF to_regclass('public.settings') IS NULL
    OR to_regprocedure('public.get_my_store_id()') IS NULL
    OR to_regprocedure('public.has_store_permission(text)') IS NULL
    OR NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_policy
      WHERE polrelid = 'public.settings'::regclass
        AND polname = 'rbac_action_select'
        AND polcmd = 'r'
        AND NOT polpermissive
    ) THEN
    RAISE EXCEPTION 'Expected store-scoped restrictive settings read policy is missing';
  END IF;
END;
$migration$;

DROP POLICY rbac_action_select ON public.settings;

CREATE POLICY rbac_action_select
  ON public.settings AS RESTRICTIVE FOR SELECT TO authenticated
  USING (
    store_id = (SELECT public.get_my_store_id())
    AND (
      (SELECT public.has_store_permission('settings.view'))
      OR (SELECT public.has_store_permission('pos.view'))
    )
  );

DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_policy
    WHERE polrelid = 'public.settings'::regclass
      AND polname = 'rbac_action_select'
      AND polcmd = 'r'
      AND NOT polpermissive
      AND pg_catalog.pg_get_expr(polqual, polrelid) LIKE '%pos.view%'
      AND pg_catalog.pg_get_expr(polqual, polrelid) LIKE '%get_my_store_id%'
  ) THEN
    RAISE EXCEPTION 'Settings read policy verification failed';
  END IF;
END;
$migration$;

COMMIT;

NOTIFY pgrst, 'reload schema';
