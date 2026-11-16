BEGIN;

REVOKE ALL ON FUNCTION public.complete_pos_sale(jsonb, uuid, numeric, text, numeric)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_pos_sale(jsonb, uuid, numeric, text, numeric, uuid)
  FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
