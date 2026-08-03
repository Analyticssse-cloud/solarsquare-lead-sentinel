-- audit_queue_daily_v7_6.sql — v6 plus the stage blocklist and a 6-month lead window
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
--        (the DEV / design arms listed here were REMOVED in v7.5 — see the header)
--        (the Speed Order arm listed here was REMOVED in v7.6 — see the header)
--        Assigned                                            still Assigned days later
--        Meeting Scheduled (BD)                              LRM owns it, stage unmoved
--        Future Followup Required                            follow-up date came due
--      (v7.6: 'Speed Order' is back in the exclusion, this time as a hard blocklist entry.)
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
--   followup_missed  L2  due follow-up, never re-dialled
--                    L3  loop turning, no meeting
--   not_interested   L4  closed soft, recently, gone quiet
--   not_qualified    L4  closed hard, recently, gone quiet
-- ===========================================================================
-- ===========================================================================
-- v7.5 (2 Aug 2026) — POST-MCCH STAGES OUT
--   Design Created, DEV Confirmation, DEV Scheduled, DEV Postponed and DEV Done were
--   reaching the queue through two v7 stage rules. They sit AFTER the meeting, so they
--   are outside what a conversion-desk auditor reviews — blocklisted, and both rules
--   removed so no other branch can pick them up. 'Duplicate Opportunity' blocked too.
--   Leak code L5 retired: nothing feeds it any more.
-- ===========================================================================
-- v7.4 (2 Aug 2026) — CLOSE-DATE FIX
--   A lead closed "Lead - Not Qualified" on 30 May 2026 was appearing in the 2 Aug queue.
--   Cause: the NI/NQ recency gate dated the close from the newest row of
--   lead_stage_status_audit_history regardless of what that row was. Non-stage touches
--   live in that table too, so a later tag edit or re-save made a May close look like a
--   July one and it cleared close_from. Fixed by dating the close from the newest event
--   whose stage is itself terminal (new `terminal_at` CTE).
-- ===========================================================================
-- v7.6 (3 Aug 2026) — MEETING CONFIRMATION AND SPEED ORDER OUT
--   'Meeting Confirmation' is the state between booking and the meeting itself: the
--   meeting is set, the date has not arrived, and there is nothing for a conversion-desk
--   auditor to coach yet. Blocked.
--   'Speed Order' is an order-side stage, not a conversion-desk one. v7 had audited it
--   when its scheduled date lapsed; that arm is REMOVED and the stage blocklisted, so no
--   branch can pick it up. TWENTY-NINE stages now blocked in total.
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
    'New Lead',
    -- ★ v7.5: POST-MCCH. The meeting has already happened and the deal has moved into
    --   design / DEV. v7 deliberately queued these when no 'Meeting Done' event existed,
    --   on the theory that design work without a completed meeting is a data leak — but
    --   in practice the MD event is simply not always written, so the rule fired on
    --   healthy, advancing deals and put post-meeting work in front of an auditor whose
    --   remit stops at the meeting. Blocked outright; the whole ladder goes together,
    --   because blocking DEV Scheduled while auditing DEV Postponed makes no sense.
    'Design Created',
    'DEV Confirmation',
    'DEV Scheduled',
    'DEV Postponed',
    'DEV Done',
    -- ★ v7.5: a duplicate record is not anybody's leak. (v7 dropped this string as
    --   fiction on a 30-day census; it does occur — it is in the live stage list.)
    'Duplicate Opportunity',
    -- ★ v7.6: booked but not yet held — nothing to audit until the meeting date passes.
    'Meeting Confirmation',
    -- ★ v7.6: order-side stage, owned outside the conversion desk. The v7 "scheduled date
    --   lapsed" arm that used to audit it has been removed from `categorised`.
    'Speed Order'
  ]) AS x
),
ist AS (
  SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date                          AS today,
         DATE_TRUNC('month', (now() AT TIME ZONE 'Asia/Kolkata')::date)::date AS month_start,
         -- ★ v7.3: the window NI / NQ closes are actually drawn from.
         --
         --   v7.1 used month_start directly and the two terminal categories went to ZERO
         --   rows for the first two days of every month: a close must be `close_quiet_days`
         --   (2) days silent before it is auditable, but on the 1st nothing in the month can
         --   be more than a few hours old. The month gate and the quiet gate cancelled out.
         --
         --   So while the month is under 7 days old the window reaches back into the previous
         --   month, which is what an MTD review does anyway — you are still closing out last
         --   month's queue during the changeover. From the 7th it is the calendar month alone.
         CASE
           WHEN (now() AT TIME ZONE 'Asia/Kolkata')::date
                - DATE_TRUNC('month', (now() AT TIME ZONE 'Asia/Kolkata')::date)::date < 7
           THEN (DATE_TRUNC('month', (now() AT TIME ZONE 'Asia/Kolkata')::date)
                 - interval '1 month')::date
           ELSE DATE_TRUNC('month', (now() AT TIME ZONE 'Asia/Kolkata')::date)::date
         END                                                                  AS close_from
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
    -- 'Speed Order' is handled by excluded_stages as of v7.6 (blocked outright).
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

-- ---------------------------------------------------------------------------
-- ★ NEW IN v7.4 — WHEN DID IT ACTUALLY CLOSE?
-- v7.3 dated an NI/NQ close with `stage_ist` = the newest row in
-- lead_stage_status_audit_history, whatever that row was. That table also carries
-- non-stage touches (tag edits, "miscellaneous changes", re-saves), so ANY later touch
-- on a long-dead lead reset its apparent close date and walked it back into the queue:
-- a lead marked "Lead - Not Qualified" on 30 May, tag-edited weeks later, dated itself
-- to the tag edit and passed a close_from of 1 Jul.
--
-- The right question is "when did this lead last become NI / NQ", so this CTE takes the
-- newest event whose STAGE is itself terminal. Nothing else can move the date.
-- ---------------------------------------------------------------------------
terminal_at AS (
  SELECT a.lead_id,
         MAX(a."createdAt") FILTER (WHERE COALESCE(a.stage,'') ILIKE '%not interested%') AS ni_at,
         MAX(a."createdAt") FILTER (WHERE COALESCE(a.stage,'') ILIKE '%not qualified%')  AS nq_at
  FROM lead_stage_status_audit_history a
  WHERE a.lead_id IN (SELECT lead_id FROM base)
  GROUP BY a.lead_id
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
    -- ★ v7.4: the close date proper — the newest genuinely-terminal stage event.
    (tm.ni_at AT TIME ZONE 'Asia/Kolkata')::date                                     AS ni_ist,
    (tm.nq_at AT TIME ZONE 'Asia/Kolkata')::date                                     AS nq_ist,
    i.today, i.month_start, i.close_from, c.breach_window_days, c.close_quiet_days, c.loop_quiet_days, c.loop_turns_min
  FROM base b
  LEFT JOIN terminal_at tm ON tm.lead_id = b.lead_id
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
      -- ★ v7.4 NOTE: for NI/NQ the gate reads ni_ist / nq_ist, NOT stage_ist.
      -- ★ v7.3: scoped to close_from (see the `ist` CTE) — the calendar month, widened to
      --   take in the previous month while the current one is under a week old. The quiet
      --   gate still holds a close back for 2 days so the LRM is finished with it first.
      WHEN is_ni THEN
        -- ★ v7.4: ni_ist first. stage_ist only stands in when the history has no NI event
        --   at all (data gap), and created_ist behind that.
        CASE WHEN COALESCE(ni_ist, stage_ist, created_ist) >= close_from
                  AND quiet_days >= close_quiet_days
             THEN 'not_interested' END          -- else NULL: closed before the window
      -- ★ v7.3: same close_from window as not_interested. Covers both NQ strings in the
      --   data — 'Lead - Not Qualified' and 'Meeting - Not Qualified' — via the ILIKE on
      --   '%not qualified%' that sets is_nq.
      WHEN is_nq THEN
        -- ★ v7.4: nq_ist first, same reasoning as the NI arm above.
        CASE WHEN COALESCE(nq_ist, stage_ist, created_ist) >= close_from
                  AND quiet_days >= close_quiet_days
             THEN 'not_qualified' END          -- else NULL: closed before the window

      -- ---- ★ v7 STAGE-DRIVEN RULES: these run BEFORE the date-driven branches ----
      -- mcch_future fires on a future meeting date alone and never looks at the stage, so
      -- placing these below it made them unreachable for exactly the leads they target —
      -- "Meeting Scheduled (BD)" carries a future date by definition. Current stage decides
      -- first; a leftover date only gets a say once no stage rule claims the lead.
      -- Each one is a stage that is legitimate on its own but becomes a leak under a stated
      -- condition. All land in followup_missed: the LRM owes this lead an action and hasn't
      -- taken it. Every arm carries a silence gate so a healthy pipeline does not flood in.

      -- ★ v7.5: the two DEV / design arms that lived here are GONE. Those stages are now
      --   in excluded_stages — post-MCCH work is out of this tool's remit, so it must not
      --   be reachable by any rule.

      -- ★ v7.6: the Speed Order arm that lived here is GONE — the stage is blocklisted.

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
      -- ★ v7.5: L5 (DEV/design started, no meeting done) retired with the rules that fed
      --   it — those stages are blocked now, so nothing can carry this code.
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
