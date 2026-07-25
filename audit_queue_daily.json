-- audit_queue_daily.sql
-- Run daily in Metabase; write the result to the "Audit_Queue" tab of the mapping sheet.
-- One row per eligible lead, last 30 days, IST. rep_email is the key the app joins
-- LRM_TL_MAP (LRM -> TL / ZSM / ADOS) on, in the browser.
-- Confirm the 4 marked columns against your schema before scheduling.
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
         a.meeting_done_date, a.qualified_datetime
  FROM lead_stage_status_audit_history a
  WHERE a.lead_id IN (SELECT lead_id FROM base)
  ORDER BY a.lead_id, a."createdAt" DESC, a."_id" DESC
),

calls_today AS (
  SELECT DISTINCT RIGHT(regexp_replace(c.call_to,'\D','','g'),10) AS phone10
  FROM ozonetel_call_logs c, ist
  WHERE c.call_type = 'Manual'                                   -- confirm col/value
    AND c."createdAt" ~ '^\d{4}-\d{2}-\d{2}T'
    AND ((c."createdAt")::timestamptz AT TIME ZONE 'Asia/Kolkata')::date = ist.today
),

geo AS (
  SELECT TRIM(g.pin_code::text) AS pin10, MAX(g.cluster) AS cluster, MAX(g.city) AS city
  FROM city_state_cluster g
  WHERE g.pincode_status = 'active' AND COALESCE(g."isDelete",0)=0
  GROUP BY TRIM(g.pin_code::text)
),

enriched AS (
  SELECT
    b.lead_id,
    b.customer_name                                          AS customer_name,   -- confirm
    COALESCE(gg.cluster, gg.city)                            AS cluster,
    b.assigned_lrm                                           AS rep_id,
    urm.name                                                 AS rep_name,
    LOWER(TRIM(REPLACE(urm.emails,'@homes.solarsquare.in','@solarsquare.in'))) AS rep_email,
    b.lead_stage                                             AS lead_stage,       -- holds 'NI'/'NQ'
    b."createdAt"                                            AS created_at,
    t.meeting_confirmed_datetime                            AS meeting_confirmed_at,
    t.meeting_schedule_date                                 AS meeting_schedule_date,
    t.meeting_done_date                                     AS meeting_done_date,
    b.follow_up_datetime                                    AS follow_up_at,
    t.qualified_datetime                                    AS qualified_at,
    b.order_closure_datetime                                AS status_changed_at,
    (ct.phone10 IS NOT NULL)                                AS attempt_today,
    (t.meeting_schedule_date AT TIME ZONE 'Asia/Kolkata')::date AS msd_ist,
    (t.meeting_done_date     AT TIME ZONE 'Asia/Kolkata')::date AS mdd_ist,
    (b.follow_up_datetime    AT TIME ZONE 'Asia/Kolkata')::date AS fu_ist,
    i.today
  FROM base b
  CROSS JOIN ist i
  LEFT JOIN typed t   ON t.lead_id = b.lead_id
  LEFT JOIN geo   gg  ON gg.pin10 = TRIM(b.pincode::text)                          -- confirm lead pincode col
  LEFT JOIN calls_today ct ON ct.phone10 = RIGHT(regexp_replace(b.customer_phone_number,'\D','','g'),10)
  LEFT JOIN users urm ON urm."_id" = b.assigned_lrm                                -- confirm assigned_lrm = users._id
),

categorised AS (
  SELECT e.*,
    CASE
      WHEN msd_ist IS NOT NULL AND msd_ist <  today
           AND (mdd_ist IS NULL OR mdd_ist < msd_ist)              THEN 'mcch_past'
      WHEN msd_ist IS NOT NULL AND msd_ist >  today
           AND mdd_ist IS NULL                                     THEN 'mcch_future'
      WHEN lead_stage = 'NI'                                       THEN 'not_interested'
      WHEN lead_stage = 'NQ'                                       THEN 'not_qualified'
      WHEN fu_ist IS NOT NULL AND fu_ist <= today
           AND attempt_today = false                               THEN 'followup_missed'
    END AS category
  FROM enriched e
)

SELECT
  today                         AS audit_date,
  rep_id, rep_name, rep_email,
  lead_id, customer_name, cluster, lead_stage,
  category,
  created_at, meeting_confirmed_at, meeting_schedule_date, meeting_done_date,
  follow_up_at, qualified_at, status_changed_at, attempt_today,
  CASE category
    WHEN 'mcch_past'       THEN (today - msd_ist)
    WHEN 'followup_missed' THEN (today - fu_ist)
    WHEN 'not_interested'  THEN (today - (status_changed_at AT TIME ZONE 'Asia/Kolkata')::date)
    WHEN 'not_qualified'   THEN (today - (status_changed_at AT TIME ZONE 'Asia/Kolkata')::date)
    ELSE 0
  END AS days_overdue,
  ROW_NUMBER() OVER (
    PARTITION BY category
    ORDER BY (CASE category WHEN 'mcch_past' THEN (today-msd_ist)
                            WHEN 'followup_missed' THEN (today-fu_ist) ELSE 0 END) DESC NULLS LAST
  ) AS category_rank
FROM categorised
WHERE category IS NOT NULL
ORDER BY category, category_rank;
