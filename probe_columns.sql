-- probe_columns.sql — the two column names v4 still cannot resolve, plus value checks.
-- Everything else in v4 is now pinned against the 31 Jul 2026 dictionary.
-- Run block by block; the information_schema lookups are instant.
-- ===========================================================================

-- 1 · ozonetel_call_logs: which column carries Manual / Progressive / IVR / Inbound?
--     Feeds the line marked (A) in v4. Candidates are `type` or `response_Type`.
SELECT ordinal_position, column_name, data_type
FROM information_schema.columns
WHERE table_name = 'ozonetel_call_logs'
  AND (column_name ILIKE '%type%' OR column_name ILIKE '%mode%'
    OR column_name ILIKE '%direction%' OR column_name ILIKE '%campaign%'
    OR column_name ILIKE '%dial%')
ORDER BY ordinal_position;

-- 2 · ozonetel_call_logs: which column identifies the AGENT who dialled?
--     Feeds the line marked (D). Without it, a bot or another agent's dial to the same
--     number counts as the assigned LRM having called — the biggest remaining hole.
SELECT ordinal_position, column_name, data_type
FROM information_schema.columns
WHERE table_name = 'ozonetel_call_logs'
  AND (column_name ILIKE '%agent%' OR column_name ILIKE '%user%'
    OR column_name ILIKE '%lrm%'   OR column_name ILIKE '%caller%'
    OR column_name ILIKE '%email%')
ORDER BY ordinal_position;

-- 3 · Confirm the call-type values, once block 1 names the column. Substitute below
--     (keep the double quotes if the name is camelCase). Looking for a value list
--     containing Manual / Progressive / IVR / Inbound.
-- SELECT COALESCE("response_Type", '(null)') AS val, COUNT(*) AS n
-- FROM ozonetel_call_logs
-- WHERE "createdAt" >= TO_CHAR(now() - interval '7 days', 'YYYY-MM-DD')
-- GROUP BY 1 ORDER BY n DESC LIMIT 20;

-- 4 · Do v4's loop keywords match real strings? It counts a "turn" when stage or status
--     contains 'call later', 'follow', 'could not connect' or 'cnc'. Also verifies the
--     two exact constants v4 compares: 'Meeting Confirmed - Customer Home', 'DEV Scheduled'.
SELECT COALESCE(stage, '(null)') AS stage, COUNT(*) AS n
FROM lead_stage_status_audit_history
WHERE "createdAt" >= now() - interval '30 days'
GROUP BY 1 ORDER BY n DESC LIMIT 40;

SELECT COALESCE(status, '(null)') AS status, COUNT(*) AS n
FROM lead_stage_status_audit_history
WHERE "createdAt" >= now() - interval '30 days'
GROUP BY 1 ORDER BY n DESC LIMIT 40;

-- 5 · Do NI / NQ really appear as lead.stage = 'NI' / 'NQ', or only as status text?
--     v4 accepts either, but if neither matches, both terminal categories never fire
--     and two whole branches of the flowchart go unaudited.
SELECT COALESCE(stage, '(null)') AS stage, COUNT(*) AS n
FROM lead
WHERE "updatedAt" >= now() - interval '30 days'
GROUP BY 1 ORDER BY n DESC LIMIT 40;

SELECT COALESCE(status, '(null)') AS status, COUNT(*) AS n
FROM lead
WHERE "updatedAt" >= now() - interval '30 days'
GROUP BY 1 ORDER BY n DESC LIMIT 40;

-- 7 · WHY ARE ALL DIAL COUNTS ZERO? 18,798 rows came back with every call count at 0,
--     which means the Ozonetel join matches nothing. Run these in order — the first that
--     returns 0 is the broken hop.

--   7a · does ANY lead phone match ANY call_to? (no date bound, no filters)
SELECT COUNT(*) AS matching_pairs
FROM (SELECT RIGHT(REGEXP_REPLACE(COALESCE(customer_phone_number,''),'\D','','g'),10) AS ph10
      FROM lead WHERE "updatedAt" >= now() - interval '7 days' LIMIT 2000) p
JOIN ozonetel_call_logs c
  ON RIGHT(REGEXP_REPLACE(COALESCE(c.call_to,''),'\D','','g'),10) = p.ph10
WHERE c."createdAt" >= TO_CHAR(now() - interval '7 days','YYYY-MM-DD');

--   7b · what does call_to actually look like? Is it even the customer's number?
SELECT call_to, "createdAt"
FROM ozonetel_call_logs
WHERE "createdAt" >= TO_CHAR(now() - interval '2 days','YYYY-MM-DD')
LIMIT 10;

--   7c · is lrm_assigned_at parseable? If it is not ISO the bound goes NULL (harmless),
--        but if it parses to a moment after the calls, every dial gets excluded.
SELECT LEFT(lrm_assigned_at, 10) AS fmt, COUNT(*) AS n
FROM lead
WHERE lrm_assigned_at IS NOT NULL AND btrim(lrm_assigned_at) <> ''
  AND "updatedAt" >= now() - interval '30 days'
GROUP BY 1 ORDER BY n DESC LIMIT 10;

-- 8 · Sanity check on v5: how many leads survive the new funnel + recency gates,
--     and in which category? Paste v5 and replace its final SELECT with this.
--   SELECT category, leak_code, COUNT(*) AS n,
--          ROUND(AVG(quiet_days),1) AS avg_silent, ROUND(AVG(overdue_days),1) AS avg_overdue
--   FROM queue GROUP BY 1,2 ORDER BY 1,2;
--     Expect: all five categories present, avg_overdue in single/low-double digits,
--     and a total in the hundreds — not 18,798.
