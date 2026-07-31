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

-- 6 · Sanity: how many leads actually get flagged, and in which category?
--     Run AFTER v4 parses. Zero rows in a category means its rule never matches —
--     which is a finding, not a pass.
-- (paste v4, replace its final SELECT with:)
--   SELECT category, leak_code, COUNT(*) AS n,
--          ROUND(AVG(quiet_days), 1) AS avg_days_silent
--   FROM queue GROUP BY 1, 2 ORDER BY 1, 2;
