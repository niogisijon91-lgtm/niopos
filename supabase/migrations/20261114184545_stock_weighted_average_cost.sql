BEGIN;
CREATE OR REPLACE FUNCTION public.capture_weighted_average_cost()
RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE
 old_stock numeric:=COALESCE(OLD.stock,0);
 new_stock numeric:=COALESCE(NEW.stock,0);
 incoming_cost numeric:=NEW.cost_price;
BEGIN
 IF new_stock>old_stock AND old_stock>0 AND incoming_cost IS NOT NULL
  AND incoming_cost IS DISTINCT FROM OLD.cost_price THEN
  NEW.cost_price:=((old_stock*COALESCE(OLD.cost_price,0))
   +((new_stock-old_stock)*incoming_cost))/new_stock;
 END IF;
 RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.capture_weighted_average_cost() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS products_weighted_average_cost ON public.products;
CREATE TRIGGER products_weighted_average_cost
 BEFORE UPDATE OF stock,cost_price ON public.products
 FOR EACH ROW EXECUTE FUNCTION public.capture_weighted_average_cost();
COMMIT;
