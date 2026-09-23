-- Run this in Supabase SQL Editor — returns a table of PASS/FAIL results

DO $$
DECLARE
  v_user_id uuid;
  v_id      uuid;
  v_bs      text;
  v_cs      text;
  v_wa      timestamptz;
  v_ca      timestamptz;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS trigger_test_results (
    step_num int, test_name text, expected text, actual text, result text
  );
  DELETE FROM trigger_test_results;

  SELECT user_id INTO v_user_id FROM public.profiles LIMIT 1;

  -- 1. INSERT → inactive
  INSERT INTO public.bike_benefits (user_id) VALUES (v_user_id)
  RETURNING id, benefit_status::text INTO v_id, v_bs;
  INSERT INTO trigger_test_results VALUES (1, 'INSERT (step NULL)', 'inactive', v_bs,
    CASE WHEN v_bs = 'inactive' THEN 'PASS' ELSE 'FAIL' END);

  -- 2. choose_bike → searching
  UPDATE public.bike_benefits SET step = 'choose_bike' WHERE id = v_id
  RETURNING benefit_status::text INTO v_bs;
  INSERT INTO trigger_test_results VALUES (2, 'step = choose_bike', 'searching', v_bs,
    CASE WHEN v_bs = 'searching' THEN 'PASS' ELSE 'FAIL' END);

  -- 3. book_live_test → searching (always, waiting for WhatsApp)
  UPDATE public.bike_benefits SET step = 'book_live_test' WHERE id = v_id
  RETURNING benefit_status::text INTO v_bs;
  INSERT INTO trigger_test_results VALUES (3, 'step = book_live_test', 'searching', v_bs,
    CASE WHEN v_bs = 'searching' THEN 'PASS' ELSE 'FAIL' END);

  -- 4. set whatsapp_sent_at (still on book_live_test) → still searching
  UPDATE public.bike_benefits SET live_test_sent_at = now() WHERE id = v_id
  RETURNING benefit_status::text INTO v_bs;
  INSERT INTO trigger_test_results VALUES (4, 'whatsapp sent (on book_live_test)', 'searching', v_bs,
    CASE WHEN v_bs = 'searching' THEN 'PASS' ELSE 'FAIL' END);

  -- 5. step = commit_to_bike → testing (whatsapp was set on prev step)
  UPDATE public.bike_benefits SET step = 'commit_to_bike' WHERE id = v_id
  RETURNING benefit_status::text INTO v_bs;
  INSERT INTO trigger_test_results VALUES (5, 'step = commit_to_bike', 'testing', v_bs,
    CASE WHEN v_bs = 'testing' THEN 'PASS' ELSE 'FAIL' END);

  -- 6. set committed_at (still on commit_to_bike) → still testing
  UPDATE public.bike_benefits SET committed_at = now() WHERE id = v_id
  RETURNING benefit_status::text INTO v_bs;
  INSERT INTO trigger_test_results VALUES (6, 'committed_at set (on commit_to_bike)', 'testing', v_bs,
    CASE WHEN v_bs = 'testing' THEN 'PASS' ELSE 'FAIL' END);

  -- 7. step = sign_contract → active (committed_at was set on prev step)
  UPDATE public.bike_benefits SET step = 'sign_contract' WHERE id = v_id
  RETURNING benefit_status::text INTO v_bs;
  INSERT INTO trigger_test_results VALUES (7, 'step = sign_contract', 'active', v_bs,
    CASE WHEN v_bs = 'active' THEN 'PASS' ELSE 'FAIL' END);

  -- 8. set contract_requested_at → contract_status = pending, benefit stays active
  UPDATE public.bike_benefits SET contract_requested_at = now() WHERE id = v_id
  RETURNING benefit_status::text, contract_status::text INTO v_bs, v_cs;
  INSERT INTO trigger_test_results VALUES (8, 'contract_requested_at set', 'active / pending', v_bs || ' / ' || COALESCE(v_cs,'NULL'),
    CASE WHEN v_bs = 'active' AND v_cs = 'pending' THEN 'PASS' ELSE 'FAIL' END);

  -- 9. step = pickup_delivery → benefit stays active
  UPDATE public.bike_benefits SET step = 'pickup_delivery' WHERE id = v_id
  RETURNING benefit_status::text INTO v_bs;
  INSERT INTO trigger_test_results VALUES (9, 'step = pickup_delivery', 'active', v_bs,
    CASE WHEN v_bs = 'active' THEN 'PASS' ELSE 'FAIL' END);

  -- ══════ RESET to choose_bike ══════
  UPDATE public.bike_benefits SET step = 'choose_bike' WHERE id = v_id
  RETURNING benefit_status::text, contract_status::text,
            live_test_sent_at, committed_at
  INTO v_bs, v_cs, v_wa, v_ca;
  INSERT INTO trigger_test_results VALUES (10, 'RESET → choose_bike',
    'searching / cs=NULL / wa=NULL / ca=NULL',
    v_bs||' / cs='||COALESCE(v_cs,'NULL')||' / wa='||COALESCE(v_wa::text,'NULL')||' / ca='||COALESCE(v_ca::text,'NULL'),
    CASE WHEN v_bs='searching' AND v_cs IS NULL AND v_wa IS NULL AND v_ca IS NULL
         THEN 'PASS' ELSE 'FAIL' END);

  -- ══════ SECOND PASS ══════

  UPDATE public.bike_benefits SET step = 'book_live_test' WHERE id = v_id
  RETURNING benefit_status::text INTO v_bs;
  INSERT INTO trigger_test_results VALUES (11, '[2nd] book_live_test', 'searching', v_bs,
    CASE WHEN v_bs = 'searching' THEN 'PASS' ELSE 'FAIL' END);

  UPDATE public.bike_benefits SET live_test_sent_at = now() WHERE id = v_id
  RETURNING benefit_status::text INTO v_bs;
  INSERT INTO trigger_test_results VALUES (12, '[2nd] whatsapp sent', 'searching', v_bs,
    CASE WHEN v_bs = 'searching' THEN 'PASS' ELSE 'FAIL' END);

  UPDATE public.bike_benefits SET step = 'commit_to_bike' WHERE id = v_id
  RETURNING benefit_status::text INTO v_bs;
  INSERT INTO trigger_test_results VALUES (13, '[2nd] step = commit_to_bike', 'testing', v_bs,
    CASE WHEN v_bs = 'testing' THEN 'PASS' ELSE 'FAIL' END);

  UPDATE public.bike_benefits SET committed_at = now() WHERE id = v_id
  RETURNING benefit_status::text INTO v_bs;
  INSERT INTO trigger_test_results VALUES (14, '[2nd] committed_at set', 'testing', v_bs,
    CASE WHEN v_bs = 'testing' THEN 'PASS' ELSE 'FAIL' END);

  UPDATE public.bike_benefits SET step = 'sign_contract' WHERE id = v_id
  RETURNING benefit_status::text INTO v_bs;
  INSERT INTO trigger_test_results VALUES (15, '[2nd] step = sign_contract', 'active', v_bs,
    CASE WHEN v_bs = 'active' THEN 'PASS' ELSE 'FAIL' END);

  UPDATE public.bike_benefits SET contract_requested_at = now() WHERE id = v_id
  RETURNING benefit_status::text, contract_status::text INTO v_bs, v_cs;
  INSERT INTO trigger_test_results VALUES (16, '[2nd] contract_requested_at', 'active / pending', v_bs || ' / ' || COALESCE(v_cs,'NULL'),
    CASE WHEN v_bs = 'active' AND v_cs = 'pending' THEN 'PASS' ELSE 'FAIL' END);

  DELETE FROM public.bike_benefits WHERE id = v_id;
END;
$$;

SELECT step_num, test_name, expected, actual, result FROM trigger_test_results ORDER BY step_num;
