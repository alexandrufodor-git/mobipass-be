drop view if exists "public"."profile_invites_with_details";

create or replace view "public"."profile_invites_with_details" as  SELECT pi.id AS invite_id,
    pi.email,
    pi.status AS invite_status,
    pi.created_at AS invited_at,
    pi.company_id,
    c.name AS company_name,
    c.monthly_benefit_subsidy,
    c.contract_months,
    p.user_id,
    p.status AS profile_status,
    p.created_at AS registered_at,
    COALESCE(p.first_name, pi.first_name) AS first_name,
    COALESCE(p.last_name, pi.last_name) AS last_name,
    COALESCE(p.description, pi.description) AS description,
    COALESCE(p.department, pi.department) AS department,
    COALESCE(p.hire_date, pi.hire_date) AS hire_date,
    bb.id AS bike_benefit_id,
    bb.step AS current_step,
    bb.benefit_status,
    bb.contract_status,
    COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) AS last_modified_at,
    bb.bike_id,
    b.name AS bike_name,
    b.brand AS bike_brand,
    b.type AS bike_type,
    b.full_price AS bike_full_price,
        CASE
            WHEN (b.full_price IS NOT NULL) THEN GREATEST((0)::numeric, (b.full_price - (c.monthly_benefit_subsidy * (c.contract_months)::numeric)))
            ELSE NULL::numeric
        END AS bike_employee_price,
    c.monthly_benefit_subsidy AS monthly_benefit_price,
    bb.committed_at,
    bb.delivered_at,
    bb.benefit_terminated_at,
    bb.benefit_insurance_claim_at,
    bb.contract_requested_at,
    bb.contract_viewed_at,
    bb.contract_employee_signed_at,
    bb.contract_employer_signed_at,
    bb.contract_approved_at,
    bb.contract_terminated_at,
    bb.live_test_location_coords,
    bb.live_test_location_name,
    bb.live_test_whatsapp_sent_at,
    bb.live_test_checked_in_at,
    bo.id AS order_id,
    bo.helmet AS ordered_helmet,
    bo.insurance AS ordered_insurance
   FROM (((((public.profile_invites pi
     LEFT JOIN public.companies c ON ((pi.company_id = c.id)))
     LEFT JOIN public.profiles p ON ((pi.email = p.email)))
     LEFT JOIN public.bike_benefits bb ON ((p.user_id = bb.user_id)))
     LEFT JOIN public.bikes b ON ((bb.bike_id = b.id)))
     LEFT JOIN public.bike_orders bo ON ((bb.id = bo.bike_benefit_id)))
  ORDER BY COALESCE(bb.updated_at, bo.updated_at, p.created_at, pi.created_at) DESC;


drop trigger if exists "objects_delete_delete_prefix" on "storage"."objects";

drop trigger if exists "objects_insert_create_prefix" on "storage"."objects";

drop trigger if exists "objects_update_create_prefix" on "storage"."objects";

-- Hosted Storage has storage.prefixes + hierarchy triggers; older/local init may not.
-- DROP TRIGGER ... ON t still requires t to exist in Postgres (IF EXISTS applies to trigger only).
DO $remote_schema_storage_prefixes$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM information_schema.tables
     WHERE table_schema = 'storage'
       AND table_name = 'prefixes'
  ) THEN
    DROP TRIGGER IF EXISTS "prefixes_create_hierarchy" ON "storage"."prefixes";
    DROP TRIGGER IF EXISTS "prefixes_delete_hierarchy" ON "storage"."prefixes";
  END IF;
END
$remote_schema_storage_prefixes$;

-- Supabase Cloud internal triggers — function does not exist in local CLI environment.
-- CREATE TRIGGER protect_buckets_delete BEFORE DELETE ON storage.buckets FOR EACH STATEMENT EXECUTE FUNCTION storage.protect_delete();
-- CREATE TRIGGER protect_objects_delete BEFORE DELETE ON storage.objects FOR EACH STATEMENT EXECUTE FUNCTION storage.protect_delete();


