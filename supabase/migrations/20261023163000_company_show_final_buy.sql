-- Per-company switch for the "Final buy" note on bike details, read from the same view as the other company terms.

ALTER TABLE public.companies
  ADD COLUMN show_final_buy boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.companies.show_final_buy IS
  'Shows the "Final buy" note on bike details (default true). Set false to hide it: presenting buying the bike as an option can conflict with the no-acquisition terms the operational lease relies on (BNR/IFN test, benefit-in-kind, consumer credit).';

CREATE OR REPLACE VIEW "public"."bikes_with_my_pricing" WITH ("security_invoker"='on') AS
 SELECT "b"."id",
    "b"."name",
    "b"."created_at",
    "b"."updated_at",
    "b"."brand",
    "b"."description",
    "b"."image_url",
    "b"."full_price",
    "b"."employee_price",
    "b"."weight_kg",
    "b"."charge_time_hours",
    "b"."range_max_km",
    "b"."power_wh",
    "b"."engine",
    "b"."supported_features",
    "b"."frame_material",
    "b"."frame_size",
    "b"."wheel_size",
    "b"."wheel_bandwidth",
    "b"."lock_type",
    "b"."sku",
    "d"."name" AS "dealer_name",
    "d"."address" AS "dealer_address",
    "d"."lat" AS "dealer_lat",
    "d"."lon" AS "dealer_lon",
    "d"."phone" AS "dealer_phone",
    "b"."available_for_test",
    "b"."in_stock",
    "b"."type",
    "b"."images",
    "c"."monthly_benefit_subsidy",
    "c"."contract_months",
    "c"."contract_months" AS "employee_contract_month",
    "c"."currency",
    "prices"."employee_price" AS "employee_full_price",
    "prices"."monthly_employee_price" AS "employee_monthly_price",
    "public"."specifications"("b".*) AS "specifications",
    "c"."insurance_provider",
    "c"."helmet_provider",
    "c"."show_final_buy"
   FROM (((("public"."bikes" "b"
     JOIN "public"."dealers" "d" ON (("d"."id" = "b"."dealer_id")))
     LEFT JOIN "public"."profiles" "me" ON (("me"."user_id" = "auth"."uid"())))
     LEFT JOIN "public"."companies" "c" ON (("c"."id" = "me"."company_id")))
     LEFT JOIN LATERAL "public"."calc_employee_prices"("b"."full_price", "c"."monthly_benefit_subsidy", "c"."contract_months") "prices"("employee_price", "monthly_employee_price") ON (true));
