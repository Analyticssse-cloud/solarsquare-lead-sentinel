-- audit_queue_daily_v2.sql  — built from the Queue Logic Worksheet
-- Column names verified against information_schema (probe run 27 Jul 2026).
-- ---------------------------------------------------------------------------
-- WORKSHEET → SQL MAP
--   Eligibility  : lead not deleted, touched in last 30d, stage maps to one of 5 categories.
--   Categories   : A mcch_past | B mcch_future | C not_interested
--                  D not_qualified | E followup_missed        (all equal severity)
--   Rank in cat  : A  most overdue first          (today - meeting_schedule_date) DESC
--                  B  FARTHEST future first        (meeting_schedule_date - today) DESC  ← D+2 reschedule risk
--                  C  oldest by lead created date  (today - created)              DESC
--                  D  oldest by lead created date  (today - created)              DESC
--                  E  most overdue first           (today - follow_up_datetime)   DESC
--   Cap          : top 4 per category  →  20 leads  PER TL, pooled across every LRM
--                  reporting to that TL. Applied in the app, not here: TL identity comes
--                  from the LRM→TL→ZSM→ADOS mapping sheet, which is the source of truth.
--                  This query emits each LRM's ranked candidates + priority_key.
--   Backfill     : if a category has < 4, top up to 20 from the most-overdue leftovers
--   Ties / order : lead freshness (created date) decides
--
-- RESOLVED FROM THE PROBE
--   lead.stage                          — the stage column (NOT lead_stage)
--   lead.lrm_queue_entry_attempts_today — replaces the whole Ozonetel call-log join
--   lead.site_address_pin_code          — pincode (meeting_address_pin_code as fallback)
--   users.firstName / lastName          — no `name` column
--   qualified_datetime                  — lives on lead (text), not on the audit table
--
-- ⚠ TWO VALUES STILL TO CONFIRM — see probe_columns_2.sql
--   1. the customer-name column (no `customer_name` exists on lead)  → emitted NULL for now
--   2. the exact `stage` strings for NI / NQ / meeting-confirmed      → 'NI'/'NQ' assumed below
-- ---------------------------------------------------------------------------
WITH ist AS (SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date AS today),

base AS (
  SELECT l.*
  FROM lead l
  WHERE COALESCE(l."isDelete",0) = 0
    AND COALESCE(l."customer_isDelete",0) = 0
    AND l."updatedAt" >= now() - interval '30 days'
),

typed AS (
  SELECT DISTINCT ON (a.lead_id)
         a.lead_id, a.meeting_confirmed_datetime, a.meeting_schedule_date,
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
    NULL::text                                               AS customer_name,   -- ⚠ confirm col (probe 2)
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
         THEN b.qualified_datetime::timestamptz
    END                                                      AS qualified_at,
    b.order_closure_datetime                                 AS status_changed_at,
    (COALESCE(b.lrm_queue_entry_attempts_today,0) > 0)       AS attempt_today,
    (t.meeting_schedule_date AT TIME ZONE 'Asia/Kolkata')::date AS msd_ist,
    (t.meeting_done_date     AT TIME ZONE 'Asia/Kolkata')::date AS mdd_ist,
    (b.follow_up_datetime    AT TIME ZONE 'Asia/Kolkata')::date AS fu_ist,
    i.today
  FROM base b
  CROSS JOIN ist i
  LEFT JOIN typed t  ON t.lead_id = b.lead_id
  LEFT JOIN geo   gg ON gg.pin10 = TRIM(COALESCE(
                          NULLIF(TRIM(b.site_address_pin_code),''),
                          NULLIF(TRIM(b.meeting_address_pin_code),'')))
  LEFT JOIN users urm ON urm."_id" = b.assigned_lrm
),

categorised AS (
  SELECT e.*,
    CASE
      WHEN msd_ist IS NOT NULL AND msd_ist <  today
           AND (mdd_ist IS NULL OR mdd_ist < msd_ist)              THEN 'mcch_past'
      WHEN msd_ist IS NOT NULL AND msd_ist >  today
           AND mdd_ist IS NULL                                     THEN 'mcch_future'
      WHEN lead_stage = 'NI'                                       THEN 'not_interested'   -- ⚠ confirm value
      WHEN lead_stage = 'NQ'                                       THEN 'not_qualified'    -- ⚠ confirm value
      WHEN fu_ist IS NOT NULL AND fu_ist <= today
           AND attempt_today = false                               THEN 'followup_missed'
    END AS category
  FROM enriched e
),

-- worksheet ranking keys: all "bigger = higher priority", so one DESC sorts every category
keyed AS (
  SELECT c.*,
    CASE category
      WHEN 'mcch_past'       THEN (today - msd_ist)          -- most overdue first
      WHEN 'mcch_future'     THEN (msd_ist - today)          -- FARTHEST future first
      WHEN 'not_interested'  THEN (today - created_ist)      -- oldest created first
      WHEN 'not_qualified'   THEN (today - created_ist)      -- oldest created first
      WHEN 'followup_missed' THEN (today - fu_ist)           -- most overdue first
    END AS rank_key,
    -- comparable overdue metric for cross-category backfill ordering
    CASE category
      WHEN 'mcch_past'       THEN (today - msd_ist)
      WHEN 'followup_missed' THEN (today - fu_ist)
      WHEN 'not_interested'  THEN (today - created_ist)
      WHEN 'not_qualified'   THEN (today - created_ist)
      ELSE 0                                                  -- future meetings aren't "overdue"
    END AS overdue_days
  FROM categorised c
  WHERE category IS NOT NULL
),

-- rank inside each (LRM, category); ties broken by freshness
per_cat AS (
  SELECT k.*,
    ROW_NUMBER() OVER (
      PARTITION BY lrm_id, category
      ORDER BY rank_key DESC NULLS LAST, created_at DESC
    ) AS lrm_category_rank
  FROM keyed k
),

-- Payload bound ONLY — not the business cap.
-- The real cap is 4 per category / 20 total PER TL, pooled across every LRM reporting to
-- that TL, and it is applied by the app, which owns the LRM -> TL -> ZSM -> ADOS mapping.
-- priority_key travels with each row so the app can rank a category across a TL's LRMs.
queue AS (
  SELECT * FROM per_cat WHERE lrm_category_rank <= 20
)

SELECT
  today                    AS audit_date,
  lrm_id, lrm_name, lrm_email,
  lead_id, customer_name, cluster, lead_stage,
  category,
  rank_key                 AS priority_key,      -- bigger = higher priority in its category
  lrm_category_rank,
  created_at, meeting_confirmed_at, meeting_schedule_date, meeting_done_date,
  follow_up_at, qualified_at, status_changed_at, attempt_today,
  overdue_days             AS days_overdue
FROM queue
ORDER BY lrm_email NULLS LAST, category, lrm_category_rank;
