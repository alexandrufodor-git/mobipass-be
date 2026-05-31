-- REGES employee bridge: registration trigger backfills employee_pii.user_id
--
-- Adds an additive step 4.5 to handle_user_registration: when the email
-- being registered matches a profile_invites row that has an associated
-- employee_pii row (staged from REGES with user_id IS NULL), set its
-- user_id to the new auth user. CSV-only invites have no profile_invite_id
-- on employee_pii so the UPDATE matches zero rows.
--
-- The rest of the trigger logic is unchanged; only step 4.5 is new.

CREATE OR REPLACE FUNCTION public.handle_user_registration() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  AS $$
DECLARE
  v_company_id  uuid;
  v_first_name  text;
  v_last_name   text;
  v_description text;
  v_department  text;
  v_hire_date   bigint;
  v_invite_id   uuid;
BEGIN
  IF NEW.email_confirmed_at IS NOT NULL THEN

    -- 1. Resolve company_id and employee fields from profile_invites
    SELECT
      pi.id,
      pi.company_id,
      pi.first_name,
      pi.last_name,
      pi.description,
      pi.department,
      pi.hire_date
    INTO
      v_invite_id,
      v_company_id,
      v_first_name,
      v_last_name,
      v_description,
      v_department,
      v_hire_date
    FROM public.profile_invites pi
    WHERE LOWER(pi.email) = LOWER(NEW.email)
    LIMIT 1;

    IF v_company_id IS NULL THEN
      RAISE EXCEPTION 'No active invite found for email %', NEW.email;
    END IF;

    -- 2. Create or update profile (must exist before user_roles FK insert)
    INSERT INTO public.profiles (
      user_id, email, status, company_id,
      first_name, last_name, description, department, hire_date
    )
    VALUES (
      NEW.id, NEW.email, 'active'::public.user_profile_status, v_company_id,
      v_first_name, v_last_name, v_description, v_department, v_hire_date
    )
    ON CONFLICT (user_id) DO UPDATE SET
      email       = EXCLUDED.email,
      status      = 'active'::public.user_profile_status,
      company_id  = EXCLUDED.company_id,
      first_name  = EXCLUDED.first_name,
      last_name   = EXCLUDED.last_name,
      description = EXCLUDED.description,
      department  = EXCLUDED.department,
      hire_date   = EXCLUDED.hire_date;

    -- 3. Assign 'employee' role
    INSERT INTO public.user_roles (user_id, role)
    VALUES (NEW.id, 'employee'::public.user_role)
    ON CONFLICT (user_id, role) DO NOTHING;

    -- 4. Update profile_invites status
    UPDATE public.profile_invites
    SET status = 'active'::public.user_profile_status
    WHERE LOWER(email) = LOWER(NEW.email);

    -- 4.5. Link any pending REGES PII to this user
    UPDATE public.employee_pii
       SET user_id    = NEW.id,
           updated_at = now()
     WHERE profile_invite_id = v_invite_id
       AND user_id IS NULL;

    -- 5. Create bike benefit
    INSERT INTO public.bike_benefits (user_id)
    VALUES (NEW.id)
    ON CONFLICT DO NOTHING;

    -- 6. Insert notification — Realtime postgres_changes delivers it to HR dashboard
    INSERT INTO public.company_notifications (company_id, event, event_type, payload)
    VALUES (
      v_company_id,
      'user_update',
      'created',
      jsonb_build_object(
        'user_id',       NEW.id,
        'employee_name', v_first_name || ' ' || v_last_name
      )
    );

  END IF;

  RETURN NEW;
END;
$$;
