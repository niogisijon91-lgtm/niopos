BEGIN;
CREATE OR REPLACE FUNCTION public.record_unlogged_stock_change()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET row_security=off AS $$
DECLARE
 d numeric:=COALESCE(NEW.stock,0)-COALESCE(OLD.stock,0);
 c numeric:=COALESCE(NEW.cost_price,0); a uuid; k uuid:=gen_random_uuid(); actor text;
BEGIN
 IF d=0 THEN RETURN NULL; END IF;
 IF EXISTS(SELECT 1 FROM public.stock_movements m WHERE m.product_id=NEW.id
   AND m.store_id=NEW.store_id AND (
    (m.previous_stock=COALESCE(OLD.stock,0) AND m.new_stock=COALESCE(NEW.stock,0))
    OR (m.previous_stock IS NULL AND m.new_stock IS NULL AND m.quantity=abs(d)
     AND ((d>0 AND m.type IN ('in','opening','adjustment'))
       OR (d<0 AND m.type IN ('out','adjustment'))))
   )
   AND m.xmin::text::numeric=mod(pg_catalog.pg_current_xact_id()::text::numeric,4294967296)) THEN
  RETURN NULL;
 END IF;
 SELECT COALESCE(NULLIF(btrim(full_name),''),email,auth.uid()::text,'system')
 INTO actor FROM public.profiles WHERE id=auth.uid();
 INSERT INTO public.stock_adjustments(product_id,previous_quantity,new_quantity,difference,
  reason,adjusted_by,adjusted_at,store_id,adjustment_type,quantity,unit,product_name,
  sku,barcode,adjusted_by_user_id,idempotency_key,value_impact)
 VALUES(NEW.id,COALESCE(OLD.stock,0),COALESCE(NEW.stock,0),d,'internal_stock_correction',
  COALESCE(actor,'system'),clock_timestamp(),NEW.store_id,CASE WHEN d>0 THEN 'increase' ELSE 'decrease' END,
  abs(d),NEW.unit,NEW.name,NEW.sku,NEW.barcode,auth.uid(),k,d*c) RETURNING id INTO a;
 INSERT INTO public.stock_movements(product_id,type,quantity,reference,previous_stock,new_stock,
  reason,purchase_price,performed_by,store_id,idempotency_key,stock_adjustment_id)
 VALUES(NEW.id,CASE WHEN d>0 THEN 'in' ELSE 'out' END,abs(d),'Stock Adjustment',
  COALESCE(OLD.stock,0),COALESCE(NEW.stock,0),'internal_stock_correction',c,auth.uid(),
  NEW.store_id,k,a);
 RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.record_unlogged_stock_change() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS products_record_unlogged_stock_change ON public.products;
CREATE CONSTRAINT TRIGGER products_record_unlogged_stock_change
 AFTER UPDATE OF stock ON public.products DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION public.record_unlogged_stock_change();

CREATE OR REPLACE FUNCTION public.record_product_opening_stock()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET row_security=off AS $$
DECLARE a uuid; k uuid:=gen_random_uuid(); actor text;
BEGIN
 IF COALESCE(NEW.stock,0)<=0 THEN RETURN NEW; END IF;
 SELECT COALESCE(NULLIF(btrim(full_name),''),email,auth.uid()::text,'system')
 INTO actor FROM public.profiles WHERE id=auth.uid();
 INSERT INTO public.stock_adjustments(product_id,previous_quantity,new_quantity,difference,
  reason,adjusted_by,adjusted_at,store_id,adjustment_type,quantity,unit,product_name,
  sku,barcode,adjusted_by_user_id,idempotency_key,value_impact)
 VALUES(NEW.id,0,NEW.stock,NEW.stock,'opening_stock_correction',COALESCE(actor,'system'),
  clock_timestamp(),NEW.store_id,'increase',NEW.stock,NEW.unit,NEW.name,NEW.sku,NEW.barcode,
  auth.uid(),k,NEW.stock*COALESCE(NEW.cost_price,0)) RETURNING id INTO a;
 INSERT INTO public.stock_movements(product_id,type,quantity,reference,note,previous_stock,
  new_stock,reason,purchase_price,performed_by,store_id,idempotency_key,stock_adjustment_id)
 VALUES(NEW.id,'opening',NEW.stock,'Opening Stock','Initial product stock',0,NEW.stock,
  'opening_stock_correction',COALESCE(NEW.cost_price,0),auth.uid(),NEW.store_id,k,a);
 RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.record_product_opening_stock() FROM PUBLIC,anon,authenticated,service_role;
NOTIFY pgrst,'reload schema';
COMMIT;
