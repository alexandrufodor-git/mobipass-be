-- Add bike snapshot columns to bike_orders.
--
-- bike_orders becomes the canonical, frozen record of what bike the employee
-- committed to at contract creation time. send-contract UPSERTs this row using
-- the existing UNIQUE (bike_benefit_id) constraint (unique_benefit_order).
--
-- All columns are nullable: existing rows (e2e seed) keep their NULL snapshot;
-- new rows populated by send-contract carry the frozen values.

ALTER TABLE public.bike_orders
  ADD COLUMN IF NOT EXISTS bike_id         uuid REFERENCES public.bikes(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS bike_sku        text,
  ADD COLUMN IF NOT EXISTS bike_name       text,
  ADD COLUMN IF NOT EXISTS bike_brand      text,
  ADD COLUMN IF NOT EXISTS bike_full_price numeric(10,2),
  ADD COLUMN IF NOT EXISTS frozen_at       timestamptz;

COMMENT ON COLUMN public.bike_orders.bike_id         IS 'Snapshot of bikes.id at contract creation. SET NULL on bike delete so the order audit row survives.';
COMMENT ON COLUMN public.bike_orders.bike_sku        IS 'Frozen bike SKU at contract creation.';
COMMENT ON COLUMN public.bike_orders.bike_name       IS 'Frozen bike name at contract creation.';
COMMENT ON COLUMN public.bike_orders.bike_brand      IS 'Frozen bike brand at contract creation.';
COMMENT ON COLUMN public.bike_orders.bike_full_price IS 'Frozen full price at contract creation. Decoupled from later bikes.full_price changes.';
COMMENT ON COLUMN public.bike_orders.frozen_at       IS 'When the snapshot was last refreshed by send-contract.';
