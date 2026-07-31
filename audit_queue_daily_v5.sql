-- audit_queue_daily_v5.sql — the lead-journey flowchart, with the funnel filters v4 lacked
-- Written after auditing 18,798 rows of real v4-variant output (31 Jul 2026).
-- ===========================================================================
-- WHAT THE v4 OUTPUT GOT WRONG, measured from that export:
--
--   1. 69% OF THE QUEUE WAS ALREADY CLOSED. Closed-Cold 8,311, Closed-Lost 2,515,
--      Closed-Won 2,217. A won customer cannot have a missed follow-up. A lead closed
--      eight months ago is not today's leak.
--   2. IT AUDITED HISTORY, NOT TODAY. Median days_overdue 304; 8,786 rows over a year
--      overdue; 7,825 follow-up dates from 2020-2024. A daily review queue must look at
--      RECENT breaches — a 2022 follow-up is a data-hygiene problem, not a coaching one.
--   3. NOT-INTERESTED AND NOT-QUALIFIED NEVER FIRED. Zero rows in either category, while
--      5,748 leads sat in the queue under the wrong one. The real stage strings are
--      'Lead - Not Interested' / 'Lead - Not Qualified' (and 'Meeting - ...' variants) —
--      not 'NI'/'NQ', and their status reads 'Closed - Lost', not 'not interested'.
--      Two whole branches of the flowchart went unaudited.
--   4. COMPLETED MEETINGS WERE FLAGGED AS MISSED. 2,252 rows sat at stage
--      'Meeting Done - Hot/Moderate/Customer Not Reachable' yet were categorised
--      mcch_past, because meeting_done_date was null or older than the schedule date.
--      If the stage says the meeting happened, it happened.
--   5. EVERY ROW HAD ZERO DIALS. 18,798 rows, not one call counted. The Ozonetel join is
--      returning nothing — so L2 ("never re-dialled") is currently unfalsifiable and
--      every follow-up miss grades L2 by default. See the note on the calls CTE.
--   6. Ordering bug: mcch_past was tested before the terminal branches, so a
--      not-interested lead with an old meeting date was reported as a missed meeting.
--
-- THE FIX IN ONE LINE: the queue is for OPEN leads with RECENT breaches. Everything else
-- is history, and history belongs in a report, not in a review queue.
--
-- CATEGORIES (flowchart branch -> leak code -> category)
--   MLS -> MD                     healthy, never flagged
--   MLS -> M/S -> nothing         L1  meeting date passed, stage never moved -> mcch_past
--   MLS -> future date            L0  watch only                             -> mcch_future
--   CNC -> no re-attempt          L2  marked could-not-connect, never re-dialled
--   Call later -> loop, no close  L3  loop turning, no meeting                -> followup_missed
--   LI  -> closed soft            L4  not interested, nothing recorded        -> not_interested
--   NQ  -> closed hard            L4  not qualified, no connect               -> not_qualified
-- ===========================================================================
WITH cfg AS (
  SELECT
    14  AS breach_window_days,   -- how recent a breach must be to enter the queue
    2   AS close_quiet_days,     -- silence required before auditing an NI/NQ close
    3   AS loop_quiet_days,      -- silence required before auditing a turning loop
    3   AS loop_turns_min        -- turns of the call-later loop that count as churn
),
ist AS (SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date AS today),

-- ---------------------------------------------------------------------------
-- POPULATION. Open working funnel only.
-- Won / booked / order-stage leads are commercial successes; auditing them for a missed
-- follow-up is noise. Long-dead records are excluded by the breach-recency gate below,
-- not here, so a lead that JUST went cold is still reviewable.
-- ---------------------------------------------------------------------------
base AS (
  SELECT l.*
  FROM lead l
  WHERE COALESCE(l."isDelete", 0) = 0
    AND COALESCE(l."customer_isDelete", 0) = 0
    AND l."updatedAt" >= now() - interval '45 days'
    AND COALESCE(l.status, '') NOT IN ('Closed - Won', 'Booked')
    AND COALESCE(l.stage, '')  NOT IN ('Order Confirmed', 'Booking Processing', 'Speed Order')
),

phones AS (
  SELECT lead_id,
         RIGHT(REGEXP_REPLACE(COALESCE(customer_phone_number, ''), '\D', '', 'g'), 10) AS ph10,
         CASE WHEN lrm_assigned_at ~ '^\d{4}-\d{2}-\d{2}T'
              THEN lrm_assigned_at::timestamptz END AS assigned_at
  FROM base
  WHERE LENGTH(RIGHT(REGEXP_REPLACE(COALESCE(customer_phone_number, ''), '\D', '', 'g'), 10)) = 10
),

-- ⚠ THIS CTE RETURNED ZERO FOR ALL 18,798 ROWS IN THE LAST EXPORT. Until that is fixed,
--   calls_30d is not evidence of anything and L2 vs L3 is not a real distinction.
--   Debug in this order, one at a time:
--     a) does the phone join match at all?   -> probe_columns.sql block 7
--     b) is call_to the right column, and does it carry +91?
--     c) is the assigned_at bound throwing everything away (lrm_assigned_at unparseable)?
--   The assigned_at bound is the most likely culprit: it is a text column and if the
--   format is not ISO the CASE yields NULL, which we allow through — but if it parses to
--   a date AFTER the calls, every call is excluded.
calls AS (
  SELECT p.lead_id,
         MAX(c."createdAt"::timestamptz)                                          AS last_call_at,
         COUNT(*)                                                                  AS calls_30d,
         COUNT(*) FILTER (
           WHERE COALESCE(NULLIF(REGEXP_REPLACE(COALESCE(c."response_CallDuration", ''), '\D', '', 'g'), ''), '0')::int >= 15
         )                                                                         AS connects_30d
  FROM phones p
  JOIN ozonetel_call_logs c
    ON RIGHT(REGEXP_REPLACE(COALESCE(c.call_to, ''), '\D', '', 'g'), 10) = p.ph10
  WHERE c."createdAt" >= TO_CHAR(now() - interval '30 days', 'YYYY-MM-DD')
    AND c."createdAt" ~ '^\d{4}-\d{2}-\d{2}'
    AND (p.assigned_at IS NULL OR c."createdAt"::timestamptz >= p.assigned_at)
    AND TRUE -- (A) Manual-only:  AND COALESCE(c."<type_column>", '') ILIKE 'manual%'
    AND TRUE -- (D) Agent scope:  AND LOWER(TRIM(REPLACE(c."<agent_column>",'@homes.solarsquare.in','@solarsquare.in'))) = lrm email
  GROUP BY p.lead_id
),

-- MAX per lead, not the newest row: the audit table is event-sparse, and reading only the
-- latest row NULLs out milestone dates whenever the last event was a close.
typed AS (
  SELECT a.lead_id,
         MAX(a."createdAt")                AS last_stage_at,
         MAX(a.meeting_confirmed_datetime) AS meeting_confirmed_datetime,
         MAX(a.meeting_schedule_date)      AS meeting_schedule_date,
         MAX(a.meeting_done_date)          AS meeting_done_date
  FROM lead_stage_status_audit_history a
  WHERE a.lead_id IN (SELECT lead_id FROM base)
  GROUP BY a.lead_id
),

loops AS (
  SELECT a.lead_id,
         COUNT(*) FILTER (
           WHERE COALESCE(a.stage, '') ILIKE ANY (ARRAY[
             '%call later%', '%followup%', '%follow up%', '%call not connected%',
             '%future followup%', '%postponed%'])
         )                                                                              AS loop_turns,
         COUNT(*) FILTER (WHERE COALESCE(a.stage, '') = 'Meeting Confirmed - Customer Home') AS mcch_events,
         COUNT(*) FILTER (WHERE COALESCE(a.stage, '') = 'DEV Scheduled')                     AS dev_events
  FROM lead_stage_status_audit_history a
  WHERE a.lead_id IN (SELECT lead_id FROM base)
  GROUP BY a.lead_id
),

geo AS (
  SELECT TRIM(g.pin_code::text) AS pin10, MAX(g.cluster) AS cluster, MAX(g.city) AS city
  FROM city_state_cluster g
  WHERE g.pincode_status = 'active' AND COALESCE(g."isDelete", 0) = 0
  GROUP BY TRIM(g.pin_code::text)
),

enriched AS (
  SELECT
    b.lead_id,
    NULLIF(TRIM(CONCAT_WS(' ', b.customer_first_name, b.customer_middle_name, b.customer_last_name)), '')
                                                             AS customer_name,
    COALESCE(gg.cluster, gg.city, NULLIF(TRIM(b.site_address_city), ''),
             NULLIF(TRIM(b.meeting_address_city), ''))        AS cluster,
    b.assigned_lrm                                           AS lrm_id,
    TRIM(CONCAT_WS(' ', urm."firstName", urm."lastName"))    AS lrm_name,
    LOWER(TRIM(REPLACE(urm.emails, '@homes.solarsquare.in', '@solarsquare.in'))) AS lrm_email,
    b.stage                                                  AS lead_stage,
    b.status                                                 AS lead_status,
    b."createdAt"                                            AS created_at,
    (b."createdAt" AT TIME ZONE 'Asia/Kolkata')::date        AS created_ist,
    t.meeting_confirmed_datetime                             AS meeting_confirmed_at,
    t.meeting_schedule_date                                  AS meeting_schedule_date,
    t.meeting_done_date                                      AS meeting_done_date,
    b.follow_up_datetime                                     AS follow_up_at,
    CASE WHEN b.qualified_datetime ~ '^\d{4}-\d{2}-\d{2}T'
         THEN b.qualified_datetime::timestamptz END          AS qualified_at,
    b.order_closure_datetime                                 AS status_changed_at,
    (COALESCE(b.lrm_queue_entry_attempts_today, 0) > 0)      AS attempt_today,
    t.last_stage_at,
    cl.last_call_at,
    COALESCE(cl.calls_30d, 0)                                AS calls_30d,
    COALESCE(cl.connects_30d, 0)                             AS connects_30d,
    COALESCE(lp.loop_turns, 0)                               AS loop_turns,
    COALESCE(lp.mcch_events, 0)                              AS mcch_events,
    COALESCE(lp.dev_events, 0)                               AS dev_events,
    b.first_meeting_done_date                                AS meeting_done_touch,
    b."updatedAt"                                            AS crm_updated_at,   -- reported, never gates
    (t.meeting_schedule_date AT TIME ZONE 'Asia/Kolkata')::date AS msd_ist,
    (t.meeting_done_date     AT TIME ZONE 'Asia/Kolkata')::date AS mdd_ist,
    (b.follow_up_datetime    AT TIME ZONE 'Asia/Kolkata')::date AS fu_ist,
    (t.last_stage_at         AT TIME ZONE 'Asia/Kolkata')::date AS stage_ist,
    i.today, c.breach_window_days, c.close_quiet_days, c.loop_quiet_days, c.loop_turns_min
  FROM base b
  CROSS JOIN ist i
  CROSS JOIN cfg c
  LEFT JOIN typed t  ON t.lead_id  = b.lead_id
  LEFT JOIN loops lp ON lp.lead_id = b.lead_id
  LEFT JOIN calls cl ON cl.lead_id = b.lead_id
  LEFT JOIN geo   gg ON gg.pin10 = TRIM(COALESCE(
                          NULLIF(TRIM(b.site_address_pin_code), ''),
                          NULLIF(TRIM(b.meeting_address_pin_code), '')))
  LEFT JOIN users urm ON urm."_id" = b.assigned_lrm
),

-- Silence, from LRM-attributable signals only. lead."updatedAt" is excluded on purpose:
-- it bumps on any automated write, which would reset the clock and un-flag real leaks.
activity AS (
  SELECT e.*,
         GREATEST(e.last_stage_at, e.last_call_at, e.meeting_done_touch, e.follow_up_at)
           AS last_activity_at
  FROM enriched e
),

acted AS (
  SELECT a.*,
    CASE
      WHEN last_activity_at IS NULL              THEN 'none'
      WHEN last_activity_at = last_call_at       THEN 'call'
      WHEN last_activity_at = meeting_done_touch THEN 'meeting_done'
      WHEN last_activity_at = follow_up_at       THEN 'followup_set'
      ELSE 'stage_change'
    END                                                                   AS last_activity_type,
    -- a lead with no attributable signal at all is silent since creation
    COALESCE((today - (last_activity_at AT TIME ZONE 'Asia/Kolkata')::date),
             today - created_ist)                                          AS quiet_days,
    ROUND(EXTRACT(EPOCH FROM (now() - COALESCE(last_activity_at, created_at))) / 3600.0)::int
                                                                           AS hours_silent,
    -- The meeting happened if the STAGE says so, or if a done date lands on/after the
    -- schedule (§5). Stage is the stronger signal — 2,252 completed meetings were
    -- previously flagged as missed because only the date rule was applied.
    (COALESCE(lead_stage, '') ILIKE 'meeting done%'
     OR (mdd_ist IS NOT NULL AND msd_ist IS NOT NULL AND mdd_ist >= msd_ist)) AS meeting_really_done,
    (COALESCE(lead_stage, '') ILIKE '%not interested%')                      AS is_ni,
    (COALESCE(lead_stage, '') ILIKE '%not qualified%'
     OR COALESCE(lead_stage, '') ILIKE '%lost in qualification%')            AS is_nq
  FROM activity a
),

-- ---------------------------------------------------------------------------
-- CATEGORISE. Terminal branches FIRST: a closed lead's leak is the close itself,
-- not whatever meeting or follow-up was left dangling behind it.
-- Every branch is gated on BOTH recency (the breach is new) and silence (nobody is
-- working it) — the two things that make a row worth a human's morning.
-- ---------------------------------------------------------------------------
categorised AS (
  SELECT c.*,
    CASE
      -- L4 · closed soft. Recent close, gone quiet since.
      WHEN is_ni
           AND COALESCE(stage_ist, created_ist) >= today - breach_window_days
           AND quiet_days >= close_quiet_days                       THEN 'not_interested'
      -- L4 · closed hard.
      WHEN is_nq
           AND COALESCE(stage_ist, created_ist) >= today - breach_window_days
           AND quiet_days >= close_quiet_days                       THEN 'not_qualified'
      -- L1 · meeting date passed, meeting never happened, nothing since it passed.
      WHEN msd_ist IS NOT NULL
           AND msd_ist < today
           AND msd_ist >= today - breach_window_days
           AND NOT meeting_really_done
           AND COALESCE((last_activity_at AT TIME ZONE 'Asia/Kolkata')::date, created_ist) <= msd_ist
                                                                    THEN 'mcch_past'
      -- L0 · meeting still ahead. Watch only, no silence requirement.
      WHEN msd_ist IS NOT NULL AND msd_ist > today
           AND NOT meeting_really_done                              THEN 'mcch_future'
      -- L2 / L3 · follow-up fell due recently and nothing has been dialled since.
      WHEN fu_ist IS NOT NULL
           AND fu_ist <= today
           AND fu_ist >= today - breach_window_days
           AND attempt_today = false
           AND COALESCE((last_call_at AT TIME ZONE 'Asia/Kolkata')::date, DATE '1900-01-01') < fu_ist
                                                                    THEN 'followup_missed'
      -- L3 · no follow-up date at all, but the loop keeps turning with no meeting.
      WHEN loop_turns >= loop_turns_min
           AND mcch_events = 0
           AND quiet_days >= loop_quiet_days
           AND quiet_days <= breach_window_days * 3                 THEN 'followup_missed'
    END AS category
  FROM acted c
),

flagged AS (
  SELECT c.*,
    CASE
      WHEN category = 'mcch_past'                                   THEN 'L1'
      WHEN category = 'followup_missed' AND calls_30d < 2            THEN 'L2'
      WHEN category = 'followup_missed'                              THEN 'L3'
      WHEN category IN ('not_interested','not_qualified')
           AND connects_30d = 0                                      THEN 'L4'
      WHEN category IN ('not_interested','not_qualified')            THEN 'L4b'
      ELSE 'L0'
    END AS leak_code
  FROM categorised c
  WHERE category IS NOT NULL
),

keyed AS (
  SELECT f.*,
    CASE category
      WHEN 'mcch_past'       THEN (today - msd_ist) * 10 + LEAST(quiet_days, 60)
      WHEN 'mcch_future'     THEN (msd_ist - today) * 10
      WHEN 'followup_missed' THEN COALESCE((today - fu_ist), 0) * 10
                                  + LEAST(quiet_days, 60)
                                  + LEAST(loop_turns, 8) * 5
      ELSE LEAST(quiet_days, 60) * 10
    END AS rank_key,
    CASE category
      WHEN 'mcch_past'       THEN (today - msd_ist)
      WHEN 'followup_missed' THEN COALESCE((today - fu_ist), quiet_days)
      WHEN 'mcch_future'     THEN 0
      ELSE quiet_days
    END AS overdue_days
  FROM flagged f
),

per_cat AS (
  SELECT k.*,
    ROW_NUMBER() OVER (
      PARTITION BY lrm_id, category
      ORDER BY rank_key DESC NULLS LAST, quiet_days DESC NULLS LAST, created_at DESC
    ) AS lrm_category_rank
  FROM keyed k
),

queue AS (SELECT * FROM per_cat WHERE lrm_category_rank <= 20)

SELECT
  today                    AS audit_date,
  lrm_id, lrm_name, lrm_email,
  lead_id, customer_name, cluster, lead_stage, lead_status,
  category, leak_code,
  rank_key                 AS priority_key,
  lrm_category_rank,
  created_at, meeting_confirmed_at, meeting_schedule_date, meeting_done_date,
  follow_up_at, qualified_at, status_changed_at, attempt_today,
  last_activity_at, last_activity_type,
  quiet_days               AS days_silent,
  hours_silent, crm_updated_at,
  calls_30d, connects_30d, loop_turns, mcch_events, dev_events,
  overdue_days             AS days_overdue
FROM queue
ORDER BY lrm_email NULLS LAST, category, lrm_category_rank;
