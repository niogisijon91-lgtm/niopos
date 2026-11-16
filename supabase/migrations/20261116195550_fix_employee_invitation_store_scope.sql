BEGIN;

DO $migration$
BEGIN
  IF to_regprocedure('public.handle_new_user_profile()') IS NULL
    OR NOT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'profiles'
        AND column_name = 'store_id'
    ) THEN
    RAISE EXCEPTION 'Employee invitation store scoping requires the current profile trigger schema';
  END IF;
END;
$migration$;

CREATE OR REPLACE FUNCTION public.handle_new_user_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $function$
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

    INSERT INTO public.profiles (id, email, full_name, phone, role, status, store_id)
    VALUES (NEW.id, NEW.email, COALESCE(v_invitation.full_name, v_full_name),
      COALESCE(v_invitation.phone, NULLIF(pg_catalog.btrim(NEW.raw_user_meta_data ->> 'phone'), '')),
      'cashier', 'approved', v_invitation.store_id);
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
$function$;

REVOKE ALL ON FUNCTION public.handle_new_user_profile() FROM PUBLIC, anon, authenticated;

COMMIT;
