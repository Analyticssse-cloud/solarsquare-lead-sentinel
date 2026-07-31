-- audit_queue_daily_v3.sql — ACTIVITY-DRIVEN leak detection
-- Supersedes audit_queue_daily_v2.sql. Same 5 category keys (the app depends on them),
-- but a leak is now defined by SILENCE SINCE THE LAST REAL ACTIVITY, not by stage alone.
-- ---------------------------------------------------------------------------
-- WHY v3
--   v2 asked "what stage is this lead in?". The whiteboard journey says the leak is
--   never the stage — it is a stage that stopped moving. So every row now carries:
--       last_activity_at    — the newest of ALL activity signals on the lead
--       last_activity_type  — which signal it was
--       days_silent         — days since that signal (IST)
--       calls_30d / connects_30d — dial pressure behind the stage
--   and every category requires silence to fire. A meeting date that passed yesterday
--   but was called about this morning is NOT a leak; the same lead untouched for 6 days is.
--
-- ACTIVITY SIGNALS UNIONED (newest wins)
--   stage_change  lead_stage_status_audit_history."createdAt"     (typed)
--   call          ozonetel_call_logs."createdAt"                  (varchar, guarded)
--   meeting_done  lead.first_meeting_done_date                    (typed)
--   followup_set  lead.follow_up_datetime                         (typed)
--   crm_touch     lead."updatedAt"                                (typed, weakest)
--
-- LEAK CODES (map to the whiteboard journey)
--   L1 ms_no_followup   MS/MCCH date passed, no activity since   -> mcch_past
--   L2 cnc_one_attempt  follow-up due, <2 dials, silent           -> followup_missed
--   L3 loop_no_close    call-later loop turning, no meeting       -> followup_missed
--   L4 closed_no_reason NI / NQ set with no discovery or contact  -> not_interested / not_qualified
--   L0 (none)           future meeting, watch only                -> mcch_future
--
-- CAP: none here. 4/category, 20/TL pooled across the TL's LRMs is applied in the app.
-- ---------------------------------------------------------------------------
WITH ist AS (SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date AS today),

base AS (
  SELECT l.*
  FROM lead l
  WHERE COALESCE(l."isDelete",0) = 0
    AND COALESCE(l."customer_isDelete",0) = 0
    AND l."updatedAt" >= now() - interval '45 days'
),

phones AS (
  SELECT lead_id,
         RIGHT(REGEXP_REPLACE(COALESCE(customer_phone_number,''), '\D', '', 'g'), 10) AS ph10
  FROM base
  WHERE LENGTH(RIGHT(REGEXP_REPLACE(COALESCE(customer_phone_number,''), '\D', '', 'g'), 10)) = 10
),

-- dial pressure + last dial. Bounded to the pre-filtered lead set and 45 days (replica-safe).
calls AS (
  SELECT p.lead_id,
         MAX(CASE WHEN c."createdAt" ~ '^\d{4}-\d{2}-\d{2}'
                  THEN c."createdAt"::timestamptz END)                      AS last_call_at,
         COUNT(*)                                                            AS calls_30d,
         COUNT(*) FILTER (
           WHERE COALESCE(NULLIF(REGEXP_REPLACE(COALESCE(c."response_CallDuration",''),'\D','','g'),''),'0')::int >= 15
         )                                                                   AS connects_30d
  FROM phones p
  JOIN ozonetel_call_logs c
    ON RIGHT(REGEXP_REPLACE(COALESCE(c.call_to,''), '\D', '', 'g'), 10) = p.ph10
  WHERE c."createdAt" >= TO_CHAR(now() - interval '45 days', 'YYYY-MM-DD')
  GROUP BY p.lead_id
),

-- latest typed milestone row per lead
typed AS (
  SELECT DISTINCT ON (a.lead_id)
         a.lead_id,
         a."createdAt"                  AS last_stage_at,
         a.meeting_confirmed_datetime,
         a.meeting_schedule_date,
         a.meeting_done_date
  FROM lead_stage_status_audit_history a
  WHERE a.lead_id IN (SELECT lead_id FROM base)
  ORDER BY a.lead_id, a."createdAt" DESC, a."_id" DESC
),

geo AS (
  SELECT TRIM(g.pin_code::text) AS pin10, MAX(g.cluster) AS cluster, MAX(g.city) AS city
  FROM city_state_cluster g
  WHERE g.pincode_status = 'active' AND COALESCE(g."isDelete",0) = 0
  GROUP BY TRIM(g.pin_code::text)
),

enriched AS (
  SELECT
    b.lead_id,
    NULL::text                                               AS customer_name,   -- confirm col
    COALESCE(gg.cluster, gg.city)                            AS cluster,
    b.assigned_lrm                                           AS lrm_id,
    TRIM(CONCAT_WS(' ', urm."firstName", urm."lastName"))    AS lrm_name,
    LOWER(TRIM(REPLACE(urm.emails,'@homes.solarsquare.in','@solarsquare.in'))) AS lrm_email,
    b.stage                                                  AS lead_stage,
    b."createdAt"                                            AS created_at,
    (b."createdAt" AT TIME ZONE 'Asia/Kolkata')::date        AS created_ist,
    t.meeting_confirmed_datetime                             AS meeting_confirmed_at,
    t.meeting_schedule_date                                  AS meeting_schedule_date,
    t.meeting_done_date                                      AS meeting_done_date,
    b.follow_up_datetime                                     AS follow_up_at,
    CASE WHEN b.qualified_datetime ~ '^\d{4}-\d{2}-\d{2}T'
         THEN b.qualified_datetime::timestamptz END          AS qualified_at,
    b.order_closure_datetime                                 AS status_changed_at,
    (COALESCE(b.lrm_queue_entry_attempts_today,0) > 0)       AS attempt_today,
    -- activity inputs
    t.last_stage_at,
    cl.last_call_at,
    COALESCE(cl.calls_30d, 0)                                AS calls_30d,
    COALESCE(cl.connects_30d, 0)                             AS connects_30d,
    b.first_meeting_done_date                                AS meeting_done_touch,
    b."updatedAt"                                            AS crm_touch_at,
    (t.meeting_schedule_date AT TIME ZONE 'Asia/Kolkata')::date AS msd_ist,
    (t.meeting_done_date     AT TIME ZONE 'Asia/Kolkata')::date AS mdd_ist,
    (b.follow_up_datetime    AT TIME ZONE 'Asia/Kolkata')::date AS fu_ist,
    i.today
  FROM base b
  CROSS JOIN ist i
  LEFT JOIN typed  t  ON t.lead_id  = b.lead_id
  LEFT JOIN calls  cl ON cl.lead_id = b.lead_id
  LEFT JOIN geo    gg ON gg.pin10 = TRIM(COALESCE(
                          NULLIF(TRIM(b.site_address_pin_code),''),
                          NULLIF(TRIM(b.meeting_address_pin_code),'')))
  LEFT JOIN users urm ON urm."_id" = b.assigned_lrm
),

-- GREATEST ignores NULLs in Postgres, so this is the newest signal of any kind.
activity AS (
  SELECT e.*,
    GREATEST(e.last_stage_at, e.last_call_at, e.meeting_done_touch,
             e.follow_up_at,  e.crm_touch_at)                       AS last_activity_at
  FROM enriched e
),

acted AS (
  SELECT a.*,
    CASE
      WHEN last_activity_at IS NULL                       THEN 'none'
      WHEN last_activity_at = last_call_at                THEN 'call'
      WHEN last_activity_at = last_stage_at               THEN 'stage_change'
      WHEN last_activity_at = meeting_done_touch          THEN 'meeting_done'
      WHEN last_activity_at = follow_up_at                THEN 'followup_set'
      ELSE 'crm_touch'
    END                                                             AS last_activity_type,
    (today - (last_activity_at AT TIME ZONE 'Asia/Kolkata')::date)  AS days_silent,
    ROUND(EXTRACT(EPOCH FROM (now() - last_activity_at)) / 3600.0)::int AS hours_silent
  FROM activity a
),

-- A category only fires when the lead has ALSO gone quiet. Silence is the leak.
categorised AS (
  SELECT c.*,
    CASE
      -- L1: meeting date passed, never moved to done, and nothing has happened since it passed
      WHEN msd_ist IS NOT NULL AND msd_ist < today
           AND (mdd_ist IS NULL OR mdd_ist < msd_ist)
           AND COALESCE((last_activity_at AT TIME ZONE 'Asia/Kolkata')::date, created_ist) <= msd_ist
                                                                    THEN 'mcch_past'
      -- watch-only: meeting still ahead
      WHEN msd_ist IS NOT NULL AND msd_ist > today AND mdd_ist IS NULL
                                                                    THEN 'mcch_future'
      -- L4: closed without contact evidence
      WHEN lead_stage = 'NI'                                        THEN 'not_interested'
      WHEN lead_stage = 'NQ'                                        THEN 'not_qualified'
      -- L2 / L3: follow-up due and no activity since it fell due
      WHEN fu_ist IS NOT NULL AND fu_ist <= today
           AND attempt_today = false
           AND COALESCE((last_call_at AT TIME ZONE 'Asia/Kolkata')::date, DATE '1900-01-01') < fu_ist
                                                                    THEN 'followup_missed'
    END AS category
  FROM acted c
),

flagged AS (
  SELECT c.*,
    CASE
      WHEN category = 'mcch_past'                                    THEN 'L1'
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

-- ranking: silence first inside every category, then the category's own clock
keyed AS (
  SELECT f.*,
    CASE category
      WHEN 'mcch_past'       THEN (today - msd_ist) * 10 + LEAST(COALESCE(days_silent,0), 60)
      WHEN 'mcch_future'     THEN (msd_ist - today) * 10
      WHEN 'not_interested'  THEN LEAST(COALESCE(days_silent,0), 60) * 10 + (today - created_ist)
      WHEN 'not_qualified'   THEN LEAST(COALESCE(days_silent,0), 60) * 10 + (today - created_ist)
      WHEN 'followup_missed' THEN (today - fu_ist) * 10 + LEAST(COALESCE(days_silent,0), 60)
    END AS rank_key,
    CASE category
      WHEN 'mcch_past'       THEN (today - msd_ist)
      WHEN 'followup_missed' THEN (today - fu_ist)
      WHEN 'mcch_future'     THEN 0
      ELSE COALESCE(days_silent, today - created_ist)
    END AS overdue_days
  FROM flagged f
),

per_cat AS (
  SELECT k.*,
    ROW_NUMBER() OVER (
      PARTITION BY lrm_id, category
      ORDER BY rank_key DESC NULLS LAST, days_silent DESC NULLS LAST, created_at DESC
    ) AS lrm_category_rank
  FROM keyed k
),

queue AS (SELECT * FROM per_cat WHERE lrm_category_rank <= 20)

SELECT
  today                    AS audit_date,
  lrm_id, lrm_name, lrm_email,
  lead_id, customer_name, cluster, lead_stage,
  category, leak_code,
  rank_key                 AS priority_key,
  lrm_category_rank,
  created_at, meeting_confirmed_at, meeting_schedule_date, meeting_done_date,
  follow_up_at, qualified_at, status_changed_at, attempt_today,
  last_activity_at, last_activity_type, days_silent, hours_silent,
  calls_30d, connects_30d,
  overdue_days             AS days_overdue
FROM queue
ORDER BY lrm_email NULLS LAST, category, lrm_category_rank;
