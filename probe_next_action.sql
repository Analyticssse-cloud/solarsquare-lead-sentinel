-- probe_next_action.sql — run BEFORE deploying v7.
-- v7 now gates every follow-up rule on lrm_queue_entry_next_action_at, with
-- reschedule_date as a fallback. Both column names were inferred from a CRM
-- activity screenshot, not from information_schema. Confirm them here first —
-- a wrong name throws column-not-found and empties every screen in the app.
-- ===========================================================================

-- 1. Do the columns exist, and what type are they?
--    Expect: lrm_queue_entry_next_action_at, reschedule_date, reschedule_time,
--            reschedule_date_time_milisecond  (note the misspelling in the source)
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'lead'
  AND (column_name ILIKE '%next_action%'
       OR column_name ILIKE '%reschedule%'
       OR column_name ILIKE '%follow_up%')
ORDER BY column_name;


-- 2. What format does each actually hold? v7 guards with:
--      next_action_at   ~ '^\d{4}-\d{2}-\d{2}T'      (ISO)
--      reschedule_date  ~ '^\d{1,2}-\d{1,2}-\d{4}$'  (DD-MM-YYYY)
--    If the real format differs, the guard yields NULL and the rule silently
--    never fires — the failure mode is an empty category, not an error.
SELECT LEFT(lrm_queue_entry_next_action_at, 10) AS next_action_fmt, COUNT(*) AS n
FROM lead
WHERE COALESCE("isDelete", 0) = 0
  AND lrm_queue_entry_next_action_at IS NOT NULL
  AND btrim(lrm_queue_entry_next_action_at) <> ''
GROUP BY 1 ORDER BY n DESC LIMIT 10;

SELECT LEFT(reschedule_date, 10) AS reschedule_fmt, COUNT(*) AS n
FROM lead
WHERE COALESCE("isDelete", 0) = 0
  AND reschedule_date IS NOT NULL
  AND btrim(reschedule_date) <> ''
GROUP BY 1 ORDER BY n DESC LIMIT 10;


-- 3. Fill rate on the 3-month population v7 actually audits.
--    If next_action_at is thinly filled, the reschedule_date fallback is carrying
--    the rules and its format matters more than the primary column's.
SELECT
  COUNT(*)                                                              AS leads_3m,
  COUNT(*) FILTER (WHERE COALESCE(lrm_queue_entry_next_action_at,'') <> '') AS has_next_action,
  COUNT(*) FILTER (WHERE COALESCE(reschedule_date,'') <> '')            AS has_reschedule,
  COUNT(*) FILTER (WHERE follow_up_datetime IS NOT NULL)                AS has_follow_up_dt,
  COUNT(*) FILTER (WHERE COALESCE(lrm_queue_entry_next_action_at,'') = ''
                     AND COALESCE(reschedule_date,'') = ''
                     AND follow_up_datetime IS NULL)                     AS has_none
FROM lead
WHERE COALESCE("isDelete", 0) = 0
  AND "createdAt" >= now() - interval '3 months';


-- 4. Do the three sources agree? Rows where next_action_at and follow_up_datetime
--    disagree by more than a day are the leads v7 will now treat differently from v6.
SELECT
  lead_id, stage,
  lrm_queue_entry_next_action_at,
  reschedule_date, reschedule_time,
  follow_up_datetime
FROM lead
WHERE COALESCE("isDelete", 0) = 0
  AND "createdAt" >= now() - interval '3 months'
  AND lrm_queue_entry_next_action_at ~ '^\d{4}-\d{2}-\d{2}T'
  AND follow_up_datetime IS NOT NULL
  AND ABS(EXTRACT(EPOCH FROM (
        lrm_queue_entry_next_action_at::timestamptz - follow_up_datetime)) / 86400.0) > 1
LIMIT 25;


-- 5. Speed Order — the status question. v7 removed 'Speed Order' from the base
--    STAGE exclusion, but base still drops status IN ('Closed - Won','Booked').
--    If every Speed Order lead carries one of those, the rule is dead code and
--    the status filter needs a carve-out.
SELECT COALESCE(status, '(null)') AS status, COUNT(*) AS n
FROM lead
WHERE COALESCE("isDelete", 0) = 0
  AND stage = 'Speed Order'
GROUP BY 1 ORDER BY n DESC;


-- 6. Stage-string spot check. v7 compares 16 blocked stages case-folded and
--    trimmed; anything spelled differently in the data slips through.
--    Compare this list against the blocklist in the query.
SELECT COALESCE(stage, '(null)') AS stage, COUNT(*) AS n
FROM lead
WHERE COALESCE("isDelete", 0) = 0
  AND "createdAt" >= now() - interval '3 months'
GROUP BY 1 ORDER BY n DESC;
