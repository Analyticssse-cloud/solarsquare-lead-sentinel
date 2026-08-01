-- audit_queue_daily_v7.sql — v6 plus the stage blocklist and a 6-month lead window
-- Written after a stage-by-stage review of the queue, 1 Aug 2026.
-- ===========================================================================
-- WHAT CHANGED FROM v6
--
--   1. TWELVE STAGES ARE NOW BLOCKED OUTRIGHT (see excluded_stages below). A lead sitting
--      at any of them leaves the queue no matter what its dates say. Three groups:
--        · completed meetings   Meeting Done - Hot / Moderate / Customer Not Reachable
--        · dead or parked       Lost In Qualification, Inactive Lead, On-Hold, Language Issue
--        · not-yet-workable     Qualification In Progress / Remaining,
--                               Followup Rescheduled / On Call / At Home
--      The blocklist is tested against the lead's CURRENT stage (v6's newest-audit-row
--      stage), not lead.stage, so a stale CRM value cannot smuggle a lead back in.
--
--   2. LEADS OLDER THAN 6 MONTHS ARE OUT. v6 bounded only on "updatedAt", so a lead created
--      in 2022 that got one automated touch last week was still eligible. The queue is for
--      leads an LRM is realistically still working; a four-year-old record is a data-hygiene
--      job, not a coaching one.
--
--   3. TWENTY-SIX STAGES BLOCKED IN TOTAL (v7.1, after the 1 Aug stage census). On top of
--      the twelve above: Lost to Competitor, Expert Call Required, Lead - Cold, New Lead,
--      and the ten post-booking stages (Advance Received, Booking Pending/Rejected by
--      Cx & ZSM, Pending Verification, Verification Rejected, Pending RM Call, RM Rejected,
--      HOTO Initiated) — Ops/RM/ZSM territory, never LRM coaching.
--      'Meeting Confirmation' and 'Duplicate Opportunity' were dropped: zero rows.
--
--   4. STAGE-DRIVEN RULES. Stages that are fine on their own but become a leak under a
--      stated condition. All land in followup_missed, each behind a silence gate so a
--      healthy pipeline does not flood the queue:
--        DEV Confirmation / DEV Scheduled / Design Created   no meeting ever completed  -> L5
--        DEV Postponed / DEV Done                            gone quiet
--        Speed Order                                         scheduled date lapsed
--        Assigned                                            still Assigned days later
--        Meeting Scheduled (BD)                              LRM owns it, stage unmoved
--        Future Followup Required                            follow-up date came due
--      'Speed Order' therefore no longer sits in the base stage exclusion.
--
--   5. 'Lost In Qualification' REMOVED FROM THE not_qualified TEST. v6 counted it as an NQ
--      close; it is now blocked entirely, and leaving it in is_nq would have contradicted
--      the blocklist.
--
-- CARRIED OVER FROM v6
--   · Current stage read from the newest lead_stage_status_audit_history row per lead.
--   · Terminal stages (NI / NQ) are a hard gate: a stale close DROPS the lead rather than
--     falling through into a meeting or follow-up category.
--   · meeting_really_done gates the two meeting branches only — never the follow-up ones,
--     which would delete every post-meeting follow-up miss.
--
-- CATEGORIES
--   mcch_past        L1  meeting date passed, meeting never happened, nothing since
--   mcch_future      L0  meeting still ahead — watch only
--                    L5  DEV or design started with no completed meeting
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
    -- (the 6-month lead-age window is a literal in `base` below: base does not cross-join
    --  cfg, so a knob here would look configurable while doing nothing)
),

-- ★ NEW IN v7 — stages that never belong in a review queue, whatever the dates say.
-- Tested against the lead's CURRENT stage further down, so a stale lead.stage cannot
-- smuggle one back in. Exact strings, trimmed and case-folded at the comparison.
excluded_stages AS (
  SELECT LOWER(x) AS stage_lc FROM unnest(ARRAY[
    -- the meeting happened: not a leak
    'Meeting Done - Hot',
    'Meeting Done - Moderate',
    'Meeting Done - Customer Not Reachable',
    -- dead or deliberately parked
    'Lost In Qualification',
    'Inactive Lead',
    'On-Hold',
    'Language Issue',
    -- not yet workable by the LRM
    'Qualification In Progress',
    'Qualification Remaining',
    -- follow-up already re-planned: the loop is turning, not broken
    'Followup Rescheduled',
    'Followup On Call',
    'Followup At Home',
    'Lead - Cold',
    -- closed, or not an LRM task at all
    'Lost to Competitor',
    'Expert Call Required',
    -- ★ v7.1: post-booking. Confirmed against the live stage census (1 Aug 2026) — these
    --   exist in the data and were reaching the queue, because `base` only screened
    --   lead.stage for 'Order Confirmed' / 'Booking Processing'. Ownership here is Ops /
    --   RM / ZSM, not the LRM, so none of it is coachable in this tool.
    'Advance Received',
    'Booking Pending by Cx',
    'Booking Pending by ZSM',
    'Booking Rejected by Cx',
    'Booking Rejected by ZSM',
    'Pending Verification',
    'Verification Rejected',
    'Pending RM Call',
    'RM Rejected',
    'HOTO Initiated',
    -- ★ v7.1: not yet an LRM's lead — no owner has been handed the work.
    'New Lead'
    -- Dropped from the v7 list: 'Meeting Confirmation' and 'Duplicate Opportunity' do not
    -- occur in the data (0 rows in the 30-day census) — they were guessed strings.
  ]) AS x
),
ist AS (
  SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date                          AS today,
         -- ★ v7.1: first of the current month, IST. The not_interested category is scoped
         --   to the calendar month rather than a rolling window, so the month's NI closes
         --   are all reviewable and the list resets on the 1st.
         DATE_TRUNC('month', (now() AT TIME ZONE 'Asia/Kolkata')::date)::date AS month_start
),

-- ---------------------------------------------------------------------------
-- POPULATION. Open working funnel only.
-- ---------------------------------------------------------------------------
base AS (
  SELECT l.*
  FROM lead l
  WHERE COALESCE(l."isDelete", 0) = 0
    AND COALESCE(l."customer_isDelete", 0) = 0
    -- ★ v7: the lead itself must be recent. Without this the queue reached back to 2022 —
    --    any ancient record with one automated touch last week qualified on "updatedAt" alone.
    AND l."createdAt" >= now() - interval '6 months'
    AND l."updatedAt" >= now() - interval '45 days'
    AND COALESCE(l.status, '') NOT IN ('Closed - Won', 'Booked')
    -- 'Speed Order' is NOT excluded here any more: v7 audits it when its scheduled date
    -- has lapsed (see the stage-driven arms in `categorised`).
    AND COALESCE(l.stage, '')  NOT IN ('Order Confirmed', 'Booking Processing')
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
         -- ★ v7.1: ILIKE, not equality. The census turned up 'Meeting Confirmed - Over
         --   WhatsApp' alongside '- Customer Home'; both are a confirmed meeting.
         COUNT(*) FILTER (WHERE COALESCE(a.stage, '') ILIKE 'meeting confirmed%')            AS mcch_events,
         COUNT(*) FILTER (WHERE COALESCE(a.stage, '') = 'DEV Scheduled')                     AS dev_events,
         -- ★ v7: did a meeting EVER complete? Several stage rules turn on its absence.
         COUNT(*) FILTER (WHERE COALESCE(a.stage, '') ILIKE 'meeting done%')                  AS md_events
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
    -- ★ v7.1: the LRM's real next action. lrm_queue_entry_next_action_at is the typed
    --   field the queue writes (2026-08-07T04:00:00Z == 09:30 IST on 07-08-2026, matching
    --   reschedule_date + reschedule_time). follow_up_datetime alone was missing these.
    --   reschedule_date is DD-MM-YYYY text, hence the branch guard on that one only.
    --   ★ v7.2: next_action_at is a real timestamptz — the v7.1 regex guard on it raised
    --   "operator does not exist: timestamp with time zone ~ unknown". Used directly now.
    COALESCE(
      b.lrm_queue_entry_next_action_at,
      CASE WHEN b.reschedule_date::text ~ '^\d{1,2}-\d{1,2}-\d{4}$'
           THEN TO_TIMESTAMP(b.reschedule_date::text, 'DD-MM-YYYY') AT TIME ZONE 'Asia/Kolkata' END,
      b.follow_up_datetime
    )                                                        AS follow_up_at,
    b.follow_up_datetime                                     AS follow_up_datetime_raw,
    CASE WHEN b.qualified_datetime::text ~ '^\d{4}-\d{2}-\d{2}'
         THEN b.qualified_datetime::text::timestamptz END    AS qualified_at,
    b.order_closure_datetime                                 AS status_changed_at,
    (COALESCE(b.lrm_queue_entry_attempts_today, 0) > 0)      AS attempt_today,
    t.last_stage_at,
    cl.last_call_at,
    COALESCE(cl.calls_30d, 0)                                AS calls_30d,
    COALESCE(cl.connects_30d, 0)                             AS connects_30d,
    COALESCE(lp.loop_turns, 0)                               AS loop_turns,
    COALESCE(lp.mcch_events, 0)                              AS mcch_events,
    COALESCE(lp.dev_events, 0)                               AS dev_events,
    COALESCE(lp.md_events, 0)                                AS md_events,
    b.first_meeting_done_date                                AS meeting_done_touch,
    (b.first_meeting_done_date IS NOT NULL)                  AS first_meeting_done_date_present,
    b."updatedAt"                                            AS crm_updated_at,   -- reported, never gates
    (t.meeting_schedule_date AT TIME ZONE 'Asia/Kolkata')::date AS msd_ist,
    (t.meeting_done_date     AT TIME ZONE 'Asia/Kolkata')::date AS mdd_ist,
    (COALESCE(
       b.lrm_queue_entry_next_action_at,
       CASE WHEN b.reschedule_date::text ~ '^\d{1,2}-\d{1,2}-\d{4}$'
            THEN TO_TIMESTAMP(b.reschedule_date::text, 'DD-MM-YYYY') AT TIME ZONE 'Asia/Kolkata' END,
       b.follow_up_datetime
     ) AT TIME ZONE 'Asia/Kolkata')::date                    AS fu_ist,
    -- stage recency now reads the LATEST stage event, not the MAX of all of them
    (COALESCE(lt.latest_stage_at, t.last_stage_at) AT TIME ZONE 'Asia/Kolkata')::date AS stage_ist,
    i.today, i.month_start, c.breach_window_days, c.close_quiet_days, c.loop_quiet_days, c.loop_turns_min
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
    -- 'Lost In Qualification' is deliberately NOT here: v7 blocks that stage outright,
    -- and counting it as an NQ close would contradict the blocklist.
    (COALESCE(current_stage, '') ILIKE '%not qualified%')                    AS is_nq,
    LOWER(TRIM(COALESCE(current_stage, '')))                                 AS stage_lc,
    -- ★ v7: the pipeline moved on but no meeting was ever completed
    (COALESCE(md_events, 0) = 0
     AND COALESCE(first_meeting_done_date_present, false) = false)           AS no_md_ever
  FROM activity a
),

-- ★ NEW IN v7 — THE STAGE BLOCKLIST, applied to the lead's CURRENT stage.
-- This runs BEFORE any categorising, so a blocked stage cannot reach a single branch.
-- It sits here rather than in `base` on purpose: `base` only knows lead.stage, which v6
-- proved can be stale — the whole point of reading the newest audit row is that the
-- effective stage is the one an auditor will see on screen.
allowed AS (
  SELECT a.*
  FROM acted a
  WHERE LOWER(TRIM(COALESCE(a.current_stage, ''))) NOT IN (SELECT stage_lc FROM excluded_stages)
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
      -- ★ v7.1: Not Interested is scoped to the CURRENT CALENDAR MONTH, not a rolling window.
      --   Every lead marked NI since the 1st is reviewable; the quiet gate still applies so a
      --   close made in the last few hours is not audited before the LRM has finished with it.
      WHEN is_ni THEN
        CASE WHEN COALESCE(stage_ist, created_ist) >= month_start
                  AND quiet_days >= close_quiet_days
             THEN 'not_interested' END          -- else NULL: closed in an earlier month
      -- ★ v7.1: same calendar-month scope as not_interested. Covers both NQ strings in the
      --   data — 'Lead - Not Qualified' and 'Meeting - Not Qualified' — via the ILIKE on
      --   '%not qualified%' that sets is_nq.
      WHEN is_nq THEN
        CASE WHEN COALESCE(stage_ist, created_ist) >= month_start
                  AND quiet_days >= close_quiet_days
             THEN 'not_qualified' END          -- else NULL: closed in an earlier month

      -- ---- ★ v7 STAGE-DRIVEN RULES: these run BEFORE the date-driven branches ----
      -- mcch_future fires on a future meeting date alone and never looks at the stage, so
      -- placing these below it made them unreachable for exactly the leads they target —
      -- "Meeting Scheduled (BD)" carries a future date by definition. Current stage decides
      -- first; a leftover date only gets a say once no stage rule claims the lead.
      -- Each one is a stage that is legitimate on its own but becomes a leak under a stated
      -- condition. All land in followup_missed: the LRM owes this lead an action and hasn't
      -- taken it. Every arm carries a silence gate so a healthy pipeline does not flood in.

      -- Pipeline advanced past the meeting without a meeting ever completing.
      -- ('dev confirmation' was a guessed string and does not occur; the real ladder is
      --  DEV Scheduled → DEV Postponed → DEV Done.)
      WHEN stage_lc IN ('dev scheduled', 'design created')
           AND no_md_ever
           AND quiet_days >= loop_quiet_days                        THEN 'followup_missed'

      -- DEV postponed or done: the ball is with the LRM to re-book or close.
      WHEN stage_lc IN ('dev postponed', 'dev done')
           AND quiet_days >= loop_quiet_days
           AND quiet_days <= breach_window_days * 3                 THEN 'followup_missed'

      -- Speed Order behaves like Assigned: the stage has not moved and nobody is working it.
      WHEN stage_lc = 'speed order'
           AND created_ist < today
           AND quiet_days >= loop_quiet_days                        THEN 'followup_missed'

      -- Assigned, and still sitting at Assigned days later — never picked up.
      WHEN stage_lc = 'assigned'
           AND created_ist < today
           AND quiet_days >= loop_quiet_days                        THEN 'followup_missed'

      -- BD booked the meeting, an LRM owns it, and the stage has not moved since.
      WHEN stage_lc = 'meeting scheduled (bd)'
           AND lrm_id IS NOT NULL
           AND created_ist < today
           AND quiet_days >= loop_quiet_days                        THEN 'followup_missed'

      -- Future follow-up that has come due.
      WHEN stage_lc = 'future followup required'
           AND fu_ist IS NOT NULL AND fu_ist <= today               THEN 'followup_missed'


      -- ---- open funnel ----
      WHEN msd_ist IS NOT NULL
           AND msd_ist < today
           AND msd_ist >= today - breach_window_days
           AND NOT meeting_really_done
           AND COALESCE((last_activity_at AT TIME ZONE 'Asia/Kolkata')::date, created_ist) <= msd_ist
                                                                    THEN 'mcch_past'
      WHEN msd_ist IS NOT NULL AND msd_ist > today
           AND NOT meeting_really_done                              THEN 'mcch_future'

      -- ---- generic follow-up rules ----
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
  FROM allowed c
),

flagged AS (
  SELECT c.*,
    CASE
      WHEN category = 'mcch_past'                                    THEN 'L1'
      -- ★ v7: DEV/design work started but no meeting was ever completed
      WHEN category = 'followup_missed' AND no_md_ever
           AND stage_lc IN ('dev confirmation','dev scheduled','design created')
                                                                      THEN 'L5'
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
  follow_up_at, follow_up_datetime_raw, qualified_at, status_changed_at, attempt_today,
  last_activity_at, last_activity_type,
  quiet_days               AS days_silent,
  hours_silent, crm_updated_at,
  calls_30d, connects_30d, loop_turns, mcch_events, dev_events,
  overdue_days             AS days_overdue
FROM queue
ORDER BY lrm_email NULLS LAST, category, lrm_category_rank;
