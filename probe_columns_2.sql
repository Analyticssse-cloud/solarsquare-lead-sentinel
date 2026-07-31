-- probe_columns_2.sql — the last two unknowns. Run both blocks, paste results back.

-- (1) Which column holds the customer's name?  (`customer_name` does not exist on lead)
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema='public' AND table_name='lead'
  AND (column_name ILIKE '%name%' OR column_name ILIKE '%cust%')
ORDER BY column_name;


-- (2) What are the real `stage` strings?  (we assumed 'NI' / 'NQ')
-- Run this second, separately — it scans, so it is bounded to 30 days.
SELECT stage, COUNT(*) AS leads
FROM lead
WHERE COALESCE("isDelete",0)=0
  AND "updatedAt" >= now() - interval '30 days'
GROUP BY stage
ORDER BY leads DESC;
