-- audit_queue_daily_v4.sql — the lead-journey flowchart, expressed as SQL
-- Verified against the 31 Jul 2026 information_schema dictionary.
-- ===========================================================================
-- COLUMN-NAME CORRECTIONS APPLIED (earlier drafts referenced columns that don't exist,
-- which Postgres resolves at plan time — the query never reached execution):
--   lead.customer_name          -> CONCAT_WS of customer_first_name/_middle_name/_last_name
--   lead.lead_status            -> lead.status
--   audit_history.lead_status   -> audit_history.status
--   lead.city                   -> site_address_city / meeting_address_city
--   lead."customer_isDelete"    -> quoted (camelCase)
--
-- WHAT THIS QUERY IS
--   One row per lead that is LEAKING, with the evidence needed to run a root-cause
--   review on it. Categories map 1:1 to the whiteboard journey:
--
--   MLS -> MD                     healthy, not flagged
--   MLS -> M/R -> M/S -> nothing  L1  meeting date passed, stage never moved  -> mcch_past
--   MLS -> future date            L0  watch only                              -> mcch_future
--   CNC -> no re-attempt          L2  marked could-not-connect, never re-dialled
--                                                                             -> followup_missed
--   Call later -> loop, no close  L3  loop turning, no meeting                -> followup_missed
--   LI  -> no reason / no date    L4  soft close, nothing recorded            -> not_interested
--   NQ  -> no discovery/contact   L4  hard close, no connected call           -> not_qualified
--
-- SILENCE IS THE GATE, EVERYWHERE
--   A breach condition that was worked today is not a leak, it is work in progress.
--   Every category — L4 included — requires the lead to have gone quiet.
--
--   Silence is measured ONLY from LRM-attributable signals: a manual dial, a stage
--   change, a follow-up being set, a meeting marked done. lead."updatedAt" is
--   deliberately NOT one of them: it bumps on any automated/system write, which would
--   reset days_silent to zero and quietly un-flag real leaks. It is still reported as
--   crm_touch_at so a reviewer can see it, but it never gates anything.
--
-- CALL ATTRIBUTION
--   Dials are counted only from lrm_assigned_at onward (§5's definition of "called"),
--   so calls made by a previous owner or before assignment cannot make an untouched
--   lead look worked. The window is 30 days and the columns say _30d — they agree.
--
--   ⚠ STILL OPEN: dials are matched on customer phone number, not on the calling agent.
--   An IVR / bot / other-agent dial to the same number still counts. Two filters fix
--   it and both need a column name this schema dump doesn't pin — see the lines marked
--   (A) call type and (D) agent identity, and probe_columns.sql. Until they are on,
--   calls_30d reads optimistically: some genuine L2 misses will be graded L3.
--
-- CAP: none here. The app applies 4/category and 20/TL pooled across the TL's LRMs.
-- ===========================================================================
WITH ist AS (SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date AS today),

-- Bound the population first; every heavy join runs against this set only.
base AS (
  SELECT l.*
  FROM lead l
  WHERE COALESCE(l."isDelete", 0) = 0
    AND COALESCE(l."customer_isDelete", 0) = 0
    AND l."updatedAt" >= now() - interval '45 days'
),

phones AS (
  SELECT lead_id,
         RIGHT(REGEXP_REPLACE(COALESCE(customer_phone_number, ''), '\D', '', 'g'), 10) AS ph10,
         -- text column; regex-guarded per §2. Dials before this moment are not this
         -- LRM's work and must not count toward "did they call?".
         CASE WHEN lrm_assigned_at ~ '^\d{4}-\d{2}-\d{2}T'
              THEN lrm_assigned_at::timestamptz END AS assigned_at
  FROM base
  WHERE LENGTH(RIGHT(REGEXP_REPLACE(COALESCE(customer_phone_number, ''), '\D', '', 'g'), 10)) = 10
),

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
  -- ISO-8601 text compares lexicographically = chronologically, so this bounds the
  -- scan without a cast. The cast below is guarded and only runs on matched rows.
  WHERE c."createdAt" >= TO_CHAR(now() - interval '30 days', 'YYYY-MM-DD')
    AND c."createdAt" ~ '^\d{4}-\d{2}-\d{2}'
    -- §5: only dials on or after assignment count as this LRM having called.
    AND (p.assigned_at IS NULL OR c."createdAt"::timestamptz >= p.assigned_at)
    AND TRUE -- (A) Manual-only:  AND COALESCE(c."<type_column>", '') ILIKE 'manual%'
    AND TRUE -- (D) Agent scope:  AND LOWER(TRIM(REPLACE(c."<agent_column>",'@homes.solarsquare.in','@solarsquare.in'))) = <lrm email>
  GROUP BY p.lead_id
),

-- Milestone timestamps: take the MAX per lead, not the newest row's values.
-- The audit table is event-sparse — if the latest event is an NI/NQ transition it may
-- carry no meeting_schedule_date, and reading only that row would NULL out msd_ist and
-- silently skip a genuinely overdue meeting.
typed AS (
  SELECT a.lead_id,
         MAX(a."createdAt")                  AS last_stage_at,
         MAX(a.meeting_confirmed_datetime)   AS meeting_confirmed_datetime,
         MAX(a.meeting_schedule_date)        AS meeting_schedule_date,
         MAX(a.meeting_done_date)            AS meeting_done_date
  FROM lead_stage_status_audit_history a
  WHERE a.lead_id IN (SELECT lead_id FROM base)
  GROUP BY a.lead_id
),

-- THE LOOP. How many times has this lead been round the follow-up / call-later circuit,
-- and did it ever reach a confirmed meeting? A lead on its fourth turn with no meeting
-- is a soft close wearing a working lead's clothes.
loops AS (
  SELECT a.lead_id,
         COUNT(*) FILTER (
           WHERE COALESCE(a.status, '') ILIKE ANY (ARRAY['%call later%', '%could not connect%', '%cnc%', '%follow%'])
              OR COALESCE(a.stage, '')  ILIKE ANY (ARRAY['%call later%', '%follow%'])
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
    b."updatedAt"                                            AS crm_touch_at,   -- reported, never gates
    (t.meeting_schedule_date AT TIME ZONE 'Asia/Kolkata')::date  AS msd_ist,
    (t.meeting_done_date     AT TIME ZONE 'Asia/Kolkata')::date  AS mdd_ist,
    (b.follow_up_datetime    AT TIME ZONE 'Asia/Kolkata')::date  AS fu_ist,
    i.today
  FROM base b
  CROSS JOIN ist i
  LEFT JOIN typed t  ON t.lead_id  = b.lead_id
  LEFT JOIN loops lp ON lp.lead_id = b.lead_id
  LEFT JOIN calls cl ON cl.lead_id = b.lead_id
  LEFT JOIN geo   gg ON gg.pin10 = TRIM(COALESCE(
                          NULLIF(TRIM(b.site_address_pin_code), ''),
                          NULLIF(TRIM(b.meeting_address_pin_code), '')))
  LEFT JOIN users urm ON urm."_id" = b.assigned_lrm
),

-- GREATEST ignores NULLs in Postgres. crm_touch_at is excluded on purpose (see header).
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
      WHEN last_activity_at = last_stage_at      THEN 'stage_change'
      WHEN last_activity_at = meeting_done_touch THEN 'meeting_done'
      WHEN last_activity_at = follow_up_at       THEN 'followup_set'
      ELSE 'stage_change'
    END                                                                  AS last_activity_type,
    (today - (last_activity_at AT TIME ZONE 'Asia/Kolkata')::date)        AS days_silent,
    ROUND(EXTRACT(EPOCH FROM (now() - last_activity_at)) / 3600.0)::int   AS hours_silent,
    -- §5: done only counts when it lands on or after the scheduled date
    (mdd_ist IS NOT NULL AND msd_ist IS NOT NULL AND mdd_ist >= msd_ist)  AS meeting_really_done
  FROM activity a
),

-- A lead with no LRM-attributable signal at all is treated as silent since creation,
-- so "never touched" can never slip past a silence gate.
silence AS (
  SELECT c.*,
         COALESCE(days_silent, today - created_ist) AS quiet_days
  FROM acted c
),

categorised AS (
  SELECT s.*,
    CASE
      -- L1 · meeting date passed, never moved to done, nothing since it passed
      WHEN msd_ist IS NOT NULL AND msd_ist < today
           AND NOT meeting_really_done
           AND COALESCE((last_activity_at AT TIME ZONE 'Asia/Kolkata')::date, created_ist) <= msd_ist
                                                                        THEN 'mcch_past'
      -- L0 · meeting still ahead: watch only, no silence requirement
      WHEN msd_ist IS NOT NULL AND msd_ist > today AND NOT meeting_really_done
                                                                        THEN 'mcch_future'
      -- L4 · terminal branches. Silence gated, like everything else: a close worked
      --      today is a decision being made, not a leak.
      WHEN (lead_stage = 'NI' OR COALESCE(lead_status, '') ILIKE '%not interested%')
           AND quiet_days >= 2                                          THEN 'not_interested'
      WHEN (lead_stage = 'NQ' OR COALESCE(lead_status, '') ILIKE '%not qualified%')
           AND quiet_days >= 2                                          THEN 'not_qualified'
      -- L2 / L3 · follow-up fell due and nothing has been dialled since
      WHEN fu_ist IS NOT NULL AND fu_ist <= today
           AND attempt_today = false
           AND COALESCE((last_call_at AT TIME ZONE 'Asia/Kolkata')::date, DATE '1900-01-01') < fu_ist
                                                                        THEN 'followup_missed'
      -- L3 alone · no follow-up date at all, but the loop has turned with no meeting
      WHEN loop_turns >= 3 AND mcch_events = 0 AND quiet_days >= 3       THEN 'followup_missed'
    END AS category
  FROM silence s
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

-- Ranking: how long the breach has stood, then how long the lead has been silent.
-- Loop count adds weight — a lead on its fifth turn is the expensive one.
keyed AS (
  SELECT f.*,
    CASE category
      WHEN 'mcch_past'       THEN (today - msd_ist) * 10 + LEAST(quiet_days, 60)
      WHEN 'mcch_future'     THEN (msd_ist - today) * 10
      WHEN 'followup_missed' THEN COALESCE((today - fu_ist), 0) * 10
                                  + LEAST(quiet_days, 60)
                                  + LEAST(loop_turns, 8) * 5
      ELSE LEAST(quiet_days, 60) * 10 + (today - created_ist)
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
  hours_silent,
  crm_touch_at,
  calls_30d, connects_30d, loop_turns, mcch_events, dev_events,
  overdue_days             AS days_overdue
FROM queue
ORDER BY lrm_email NULLS LAST, category, lrm_category_rank;
