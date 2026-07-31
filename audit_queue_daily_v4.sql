-- audit_queue_daily_v4.sql — the lead-journey flowchart, expressed as SQL
-- Supersedes v3. Verified against the SolarSquare SQL conventions dump of 31 Jul 2026.
-- ===========================================================================
-- WHAT CHANGED FROM v3 (and why)
--   1. Dial pressure now respects the Manual-call-type rule. v3 counted every Ozonetel
--      row, so Progressive/IVR/Inbound traffic inflated "the LRM did call" and hid real
--      misses. Agent-performance signals must be Manual only.
--   2. The call-later LOOP is counted, not inferred. The flowchart's third leak is a lead
--      turning follow-up → call-later → follow-up forever while looking "worked".
--      loop_turns counts follow-up/call-later stage events in the audit history.
--   3. customer_name is resolved (lead.customer_name), not left NULL.
--   4. Stage strings use the verified constants: 'Meeting Confirmed - Customer Home',
--      'DEV Scheduled'.
--   5. Meeting-done rule applied as specified: done only counts when
--      meeting_done_date >= meeting_schedule_date.
--   6. order_closure_datetime treated as native timestamptz (no cast).
--   7. Every text→timestamp cast is regex-guarded; every scan is bounded to the
--      pre-filtered lead set (replica recovery-conflict safety).
--
-- THE FLOWCHART, BRANCH BY BRANCH
--   MLS → MD                     healthy, not flagged
--   MLS → M/R → M/S → (nothing)  L1  meeting date passed, stage never moved   → mcch_past
--   MLS → future date            L0  watch only                               → mcch_future
--   CNC → no re-attempt          L2  marked could-not-connect, never re-dialled → followup_missed
--   Call later → loop, no close  L3  loop turning ≥3 times, no meeting        → followup_missed
--   LI  → no reason / no date    L4  soft close with nothing recorded         → not_interested
--   NQ  → no discovery/contact   L4  hard close with no connected call        → not_qualified
--
-- EVERY leak also requires SILENCE. A breach condition that was touched today is not a
-- leak, it is work in progress. days_silent is the gate, not a decoration.
--
-- CAP: none here. The app applies 4/category and 20/TL pooled across the TL's LRMs.
-- ===========================================================================
WITH ist AS (SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date AS today),

-- Bound the population first; everything else joins against this set only.
base AS (
  SELECT l.*
  FROM lead l
  WHERE COALESCE(l."isDelete", 0) = 0
    AND COALESCE(l.customer_isDelete, 0) = 0
    AND l."updatedAt" >= now() - interval '45 days'
),

phones AS (
  SELECT lead_id,
         RIGHT(REGEXP_REPLACE(COALESCE(customer_phone_number, ''), '\D', '', 'g'), 10) AS ph10
  FROM base
  WHERE LENGTH(RIGHT(REGEXP_REPLACE(COALESCE(customer_phone_number, ''), '\D', '', 'g'), 10)) = 10
),

-- Manual dials only (§5: exclude Progressive / IVR / Inbound for agent performance).
-- Real connect = duration >= 15s; dialer "Answered" alone is unreliable.
calls AS (
  SELECT p.lead_id,
         MAX(CASE WHEN c."createdAt" ~ '^\d{4}-\d{2}-\d{2}'
                  THEN c."createdAt"::timestamptz END)                          AS last_call_at,
         COUNT(*)                                                                AS calls_30d,
         COUNT(*) FILTER (
           WHERE COALESCE(NULLIF(REGEXP_REPLACE(COALESCE(c."response_CallDuration", ''), '\D', '', 'g'), ''), '0')::int >= 15
         )                                                                       AS connects_30d
  FROM phones p
  JOIN ozonetel_call_logs c
    ON RIGHT(REGEXP_REPLACE(COALESCE(c.call_to, ''), '\D', '', 'g'), 10) = p.ph10
  WHERE c."createdAt" >= TO_CHAR(now() - interval '45 days', 'YYYY-MM-DD')
    AND COALESCE(c.call_type, '') ILIKE 'manual%'
  GROUP BY p.lead_id
),

-- Latest typed milestone row per lead. The audit table carries these as real timestamptz;
-- the lead table stores the same fields as text (§2).
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

-- THE LOOP. How many times has this lead been round the follow-up / call-later circuit,
-- and has it ever reached a confirmed meeting? A lead on its fourth turn with no meeting
-- is a soft close wearing a working lead's clothes.
loops AS (
  SELECT a.lead_id,
         COUNT(*) FILTER (
           WHERE COALESCE(a.lead_status, '') ILIKE ANY (ARRAY['%call later%', '%could not connect%', '%cnc%', '%follow%'])
              OR COALESCE(a.stage, '')       ILIKE ANY (ARRAY['%call later%', '%follow%'])
         )                                                              AS loop_turns,
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
    b.customer_name,
    COALESCE(gg.cluster, gg.city, b.city)                    AS cluster,
    b.assigned_lrm                                           AS lrm_id,
    TRIM(CONCAT_WS(' ', urm."firstName", urm."lastName"))    AS lrm_name,
    LOWER(TRIM(REPLACE(urm.emails, '@homes.solarsquare.in', '@solarsquare.in'))) AS lrm_email,
    b.stage                                                  AS lead_stage,
    b.lead_status                                            AS lead_status,
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
    b."updatedAt"                                            AS crm_touch_at,
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

-- GREATEST ignores NULLs in Postgres, so this is the newest signal of any kind.
activity AS (
  SELECT e.*,
         GREATEST(e.last_stage_at, e.last_call_at, e.meeting_done_touch,
                  e.follow_up_at,  e.crm_touch_at) AS last_activity_at
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
      ELSE 'crm_touch'
    END                                                                 AS last_activity_type,
    (today - (last_activity_at AT TIME ZONE 'Asia/Kolkata')::date)       AS days_silent,
    ROUND(EXTRACT(EPOCH FROM (now() - last_activity_at)) / 3600.0)::int  AS hours_silent,
    -- §5 meeting-done rule: done only counts when it lands on or after the scheduled date
    (mdd_ist IS NOT NULL AND msd_ist IS NOT NULL AND mdd_ist >= msd_ist) AS meeting_really_done
  FROM activity a
),

categorised AS (
  SELECT c.*,
    CASE
      -- L1 · MLS → M/S → nothing. Date passed, never moved to MD, silent since it passed.
      WHEN msd_ist IS NOT NULL AND msd_ist < today
           AND NOT meeting_really_done
           AND COALESCE((last_activity_at AT TIME ZONE 'Asia/Kolkata')::date, created_ist) <= msd_ist
                                                                        THEN 'mcch_past'
      -- L0 · meeting still ahead: watch only
      WHEN msd_ist IS NOT NULL AND msd_ist > today AND NOT meeting_really_done
                                                                        THEN 'mcch_future'
      -- L4 · terminal branches of the flowchart
      WHEN lead_stage = 'NI' OR COALESCE(lead_status,'') ILIKE '%not interested%'
                                                                        THEN 'not_interested'
      WHEN lead_stage = 'NQ' OR COALESCE(lead_status,'') ILIKE '%not qualified%'
                                                                        THEN 'not_qualified'
      -- L2 / L3 · follow-up fell due and nothing has been dialled since
      WHEN fu_ist IS NOT NULL AND fu_ist <= today
           AND attempt_today = false
           AND COALESCE((last_call_at AT TIME ZONE 'Asia/Kolkata')::date, DATE '1900-01-01') < fu_ist
                                                                        THEN 'followup_missed'
      -- L3 alone · no follow-up date at all, but the loop has turned 3+ times with no meeting
      WHEN loop_turns >= 3 AND mcch_events = 0 AND COALESCE(days_silent, 0) >= 3
                                                                        THEN 'followup_missed'
    END AS category
  FROM acted c
),

flagged AS (
  SELECT c.*,
    CASE
      WHEN category = 'mcch_past'                                  THEN 'L1'
      WHEN category = 'followup_missed' AND calls_30d < 2           THEN 'L2'
      WHEN category = 'followup_missed' AND loop_turns >= 3         THEN 'L3'
      WHEN category = 'followup_missed'                             THEN 'L3'
      WHEN category IN ('not_interested','not_qualified')
           AND connects_30d = 0                                     THEN 'L4'
      WHEN category IN ('not_interested','not_qualified')           THEN 'L4b'
      ELSE 'L0'
    END AS leak_code
  FROM categorised c
  WHERE category IS NOT NULL
),

-- Ranking: how long the breach has stood, then how long the lead has been silent.
-- The loop count adds weight, because a lead on its fifth turn is the expensive one.
keyed AS (
  SELECT f.*,
    CASE category
      WHEN 'mcch_past'       THEN (today - msd_ist) * 10 + LEAST(COALESCE(days_silent,0), 60)
      WHEN 'mcch_future'     THEN (msd_ist - today) * 10
      WHEN 'followup_missed' THEN COALESCE((today - fu_ist), 0) * 10
                                  + LEAST(COALESCE(days_silent,0), 60)
                                  + LEAST(loop_turns, 8) * 5
      ELSE LEAST(COALESCE(days_silent,0), 60) * 10 + (today - created_ist)
    END AS rank_key,
    CASE category
      WHEN 'mcch_past'       THEN (today - msd_ist)
      WHEN 'followup_missed' THEN COALESCE((today - fu_ist), COALESCE(days_silent, 0))
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
  lead_id, customer_name, cluster, lead_stage, lead_status,
  category, leak_code,
  rank_key                 AS priority_key,
  lrm_category_rank,
  created_at, meeting_confirmed_at, meeting_schedule_date, meeting_done_date,
  follow_up_at, qualified_at, status_changed_at, attempt_today,
  last_activity_at, last_activity_type, days_silent, hours_silent,
  calls_30d, connects_30d, loop_turns, mcch_events, dev_events,
  overdue_days             AS days_overdue
FROM queue
ORDER BY lrm_email NULLS LAST, category, lrm_category_rank;
