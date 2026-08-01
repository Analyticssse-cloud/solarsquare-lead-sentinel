-- audit_queue_daily_v6.sql — v5 plus the lead's TRUE current stage as a hard gate
-- Written after two live misfiles reported 1 Aug 2026.
-- ===========================================================================
-- WHAT v5 GOT WRONG, from the two reported leads:
--
--   RMH40177  shown as "MCCH ahead", actual current stage: Not Interested.
--   LUP161698 shown as "MCCH past",  actual current stage: meeting done / Not Qualified.
--
-- ONE root cause for both. v5 tested the terminal branches FIRST (correct) but gated them
-- on recency: the close had to have happened within breach_window_days. When the close was
-- OLDER than that window the terminal branch simply did not fire, and the lead fell through
-- to whatever meeting or follow-up date was still dangling behind it. A lead that went
-- Not Interested in July was therefore reported in August as a missed meeting.
--
-- A stale close means "too old to coach". It must DROP the lead from the queue. It must
-- never re-file it under a category that contradicts the stage the CRM is showing — the
-- auditor opens the lead, sees "Not Interested" on screen, and stops trusting the tool.
--
-- THE TWO FIXES
--   1. CURRENT STAGE IS READ PROPERLY. v5 used lead.stage alone. v6 takes the newest row
--      of lead_stage_status_audit_history per lead (DISTINCT ON ... ORDER BY "createdAt"
--      DESC) and uses that as the effective stage, falling back to lead.stage only when the
--      audit table has nothing. Both are emitted so a mismatch is visible, not hidden.
--   2. TERMINAL STAGES ARE A HARD GATE, NOT AN ORDERED BRANCH. If the lead is currently
--      Not Interested or Not Qualified, that arm of the CASE matches unconditionally and the
--      meeting and follow-up branches become unreachable. Recency now decides whether the
--      lead is AUDITABLE, not which category it lands in. A stale close drops the lead.
--      Note `meeting_really_done` stays a per-branch condition on the two meeting branches
--      only (as in v5) — it is partly date-derived and permanent, so promoting it to a
--      top-level arm would delete every post-meeting follow-up miss.
--
-- CATEGORIES (unchanged from v5)
--   mcch_past        L1  meeting date passed, meeting never happened, nothing since
--   mcch_future      L0  meeting still ahead — watch only
--   followup_missed  L2  due follow-up, never re-dialled
--                    L3  loop turning, no meeting
--   not_interested   L4  closed soft, recently, gone quiet
--   not_qualified    L4  closed hard, recently, gone quiet
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

-- ---------------------------------------------------------------------------
-- ★ NEW IN v6 — THE LEAD'S LATEST STAGE.
-- The newest audit row per lead, by event time. This is the stage the CRM is actually
-- showing an auditor when they open the record. lead.stage is kept as a fallback and
-- emitted alongside, so a divergence between the two shows up in the output instead of
-- silently picking one.
-- ---------------------------------------------------------------------------
latest AS (
  SELECT DISTINCT ON (a.lead_id)
         a.lead_id,
         a.stage                AS latest_stage,
         a."createdAt"          AS latest_stage_at
  FROM lead_stage_status_audit_history a
  WHERE a.lead_id IN (SELECT lead_id FROM base)
  ORDER BY a.lead_id, a."createdAt" DESC NULLS LAST, a."_id" DESC
),

phones AS (
  SELECT lead_id,
         RIGHT(REGEXP_REPLACE(COALESCE(customer_phone_number, ''), '\D', '', 'g'), 10) AS ph10,
         CASE WHEN lrm_assigned_at ~ '^\d{4}-\d{2}-\d{2}T'
              THEN lrm_assigned_at::timestamptz END AS assigned_at
  FROM base
  WHERE LENGTH(RIGHT(REGEXP_REPLACE(COALESCE(customer_phone_number, ''), '\D', '', 'g'), 10)) = 10
),

calls AS (
  SELECT p.lead_id,
         MAX(c."createdAt"::timestamptz)                                            AS last_call_at,
         COUNT(*)                                                                    AS calls_30d,
         COUNT(*) FILTER (
           WHERE COALESCE(NULLIF(REGEXP_REPLACE(COALESCE(c."response_CallDuration", ''), '\D', '', 'g'), ''), '0')::int >= 15
         )                                                                           AS connects_30d
  FROM phones p
  JOIN ozonetel_call_logs c
    ON RIGHT(REGEXP_REPLACE(COALESCE(c.call_to, ''), '\D', '', 'g'), 10) = p.ph10
  WHERE c."createdAt" >= TO_CHAR(now() - interval '30 days', 'YYYY-MM-DD')
    AND c."createdAt" ~ '^\d{4}-\d{2}-\d{2}'
    AND (p.assigned_at IS NULL OR c."createdAt"::timestamptz >= p.assigned_at)
  GROUP BY p.lead_id
),

-- MAX per lead, not the newest row: the audit table is event-sparse, and reading only the
-- latest row NULLs out milestone dates whenever the last event was a close. (The LATEST
-- stage is a different question and is answered by the `latest` CTE above.)
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

    -- ★ the effective stage: newest audit event, lead.stage only as a fallback.
    --   Status stays on `lead` — the audit table carries `stage` and
    --   `status_stage_updated_by`, but no plain `status` column.
    COALESCE(NULLIF(TRIM(lt.latest_stage), ''),  b.stage)    AS current_stage,
    b.status                                                 AS current_status,
    lt.latest_stage_at                                       AS current_stage_at,
    b.stage                                                  AS lead_table_stage,
    b.status                                                 AS lead_table_status,
    (NULLIF(TRIM(lt.latest_stage), '') IS NOT NULL
     AND TRIM(lt.latest_stage) IS DISTINCT FROM TRIM(COALESCE(b.stage, ''))) AS stage_mismatch,

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
    -- stage recency now reads the LATEST stage event, not the MAX of all of them
    (COALESCE(lt.latest_stage_at, t.last_stage_at) AT TIME ZONE 'Asia/Kolkata')::date AS stage_ist,
    i.today, c.breach_window_days, c.close_quiet_days, c.loop_quiet_days, c.loop_turns_min
  FROM base b
  CROSS JOIN ist i
  CROSS JOIN cfg c
  LEFT JOIN latest lt ON lt.lead_id = b.lead_id
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
    COALESCE((today - (last_activity_at AT TIME ZONE 'Asia/Kolkata')::date),
             today - created_ist)                                          AS quiet_days,
    ROUND(EXTRACT(EPOCH FROM (now() - COALESCE(last_activity_at, created_at))) / 3600.0)::int
                                                                           AS hours_silent,
    -- ★ every stage test below now reads current_stage, not lead.stage
    (COALESCE(current_stage, '') ILIKE 'meeting done%'
     OR (mdd_ist IS NOT NULL AND msd_ist IS NOT NULL AND mdd_ist >= msd_ist)) AS meeting_really_done,
    (COALESCE(current_stage, '') ILIKE '%not interested%')                   AS is_ni,
    (COALESCE(current_stage, '') ILIKE '%not qualified%'
     OR COALESCE(current_stage, '') ILIKE '%lost in qualification%')         AS is_nq
  FROM activity a
),

-- ★ THE HARD GATE, and it lives in the CASE below rather than in a flag column.
--   Terminal stages are tested FIRST and their arms match unconditionally: if a lead is
--   currently Not Interested or Not Qualified, that WHEN fires, and the inner CASE decides
--   only whether it is recent enough to audit. A stale close therefore yields NULL and the
--   lead DROPS — it can never fall through to a meeting or follow-up branch. That
--   fall-through is exactly what put a July "Not Interested" into August's MCCH-ahead list.
--
--   `meeting_really_done` is deliberately NOT a top-level arm. It is partly date-derived
--   (meeting_done_date >= meeting_schedule_date) and therefore TRUE forever once a meeting
--   has ever completed. Gating the whole CASE on it would silently delete every post-meeting
--   follow-up miss — the stall point where solar deals most often die. It gates the two
--   meeting branches only, as in v5.
categorised AS (
  SELECT c.*,
    CASE
      -- ---- terminal stages: unconditional match, so these leads can take no other category ----
      WHEN is_ni THEN
        CASE WHEN COALESCE(stage_ist, created_ist) >= today - breach_window_days
                  AND quiet_days >= close_quiet_days
             THEN 'not_interested' END          -- else NULL: closed too long ago to coach
      WHEN is_nq THEN
        CASE WHEN COALESCE(stage_ist, created_ist) >= today - breach_window_days
                  AND quiet_days >= close_quiet_days
             THEN 'not_qualified' END

      -- ---- open funnel ----
      WHEN msd_ist IS NOT NULL
           AND msd_ist < today
           AND msd_ist >= today - breach_window_days
           AND NOT meeting_really_done
           AND COALESCE((last_activity_at AT TIME ZONE 'Asia/Kolkata')::date, created_ist) <= msd_ist
                                                                    THEN 'mcch_past'
      WHEN msd_ist IS NOT NULL AND msd_ist > today
           AND NOT meeting_really_done                              THEN 'mcch_future'
      -- follow-up misses are NOT gated on meeting_really_done: a lead that met in March and
      -- has a 10-day-overdue follow-up today is a live leak, not a closed success.
      WHEN fu_ist IS NOT NULL
           AND fu_ist <= today
           AND fu_ist >= today - breach_window_days
           AND attempt_today = false
           AND COALESCE((last_call_at AT TIME ZONE 'Asia/Kolkata')::date, DATE '1900-01-01') < fu_ist
                                                                    THEN 'followup_missed'
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
      WHEN category = 'mcch_past'                                    THEN 'L1'
      WHEN category = 'followup_missed' AND calls_30d < 2             THEN 'L2'
      WHEN category = 'followup_missed'                               THEN 'L3'
      WHEN category IN ('not_interested','not_qualified')
           AND connects_30d = 0                                       THEN 'L4'
      WHEN category IN ('not_interested','not_qualified')             THEN 'L4b'
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
  lead_id, customer_name, cluster,
  current_stage            AS lead_stage,      -- ★ the stage the CRM is showing today
  current_status           AS lead_status,
  current_stage_at         AS stage_changed_at_audit,
  lead_table_stage, lead_table_status, stage_mismatch,
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
