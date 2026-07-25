# SolarSquare Lead Sentinel — Vercel Deploy

Same structure as `solarsquare-lrm`: plain HTML front-end + Vercel serverless functions, **no build step**. Same Google service account.

The tool reads **two tabs** from the Google Sheet and merges them on `rep_email` in the browser:

| Tab | What it is | Who fills it |
|-----|------------|--------------|
| `Audit_Queue` | Daily output of `audit_queue_daily.sql` (one row per sampled lead) | Apps Script / Metabase export, once a day |
| `LRM_TL_MAP`  | LRM → TL / ZSM / ADOS mapping (dynamic) | already maintained for the QA / LRM dashboards |

`Audit_Queue` header row must match the SQL column names: `audit_date, rep_id, rep_name, rep_email, lead_id, customer_name, cluster, lead_stage, category, created_at, meeting_confirmed_at, meeting_schedule_date, meeting_done_date, follow_up_at, qualified_at, status_changed_at, attempt_today, days_overdue`.

---

## 1. Push to GitHub

```bash
git init
git add .
git commit -m "lead sentinel"
git remote add origin https://github.com/Analyticssse-cloud/solarsquare-lead-sentinel.git
git push -u origin main
```

## 2. Deploy on Vercel

1. **vercel.com → Add New → Project → Import** the repo.
2. Framework preset: **Other**. Build command: *(blank)*. Output directory: `public`.
3. **Environment Variables** (same values as `solarsquare-lrm` / `solarsquare-qa`):

| Variable          | Value |
|-------------------|-------|
| `SHEET_ID`        | the mapping/export spreadsheet id |
| `GOOGLE_SA_EMAIL` | service-account email |
| `GOOGLE_SA_KEY`   | full private key (keep the `\n` sequences, in quotes) |
| `QUEUE_TAB`       | *(optional)* audit-export tab name — defaults to `Audit_Queue` |
| `MAP_TAB`         | *(optional)* mapping tab name — defaults to `LRM_TL_MAP` |

4. **Deploy.**

## 3. Verify

- `https://<app>.vercel.app/api/queue` → `{ "auditDate": "...", "queue": [...], "hierarchy": [...] }`
- `https://<app>.vercel.app` → the tool loads. If `/api/queue` is empty or errors, the UI
  automatically falls back to the bundled demo data in `public/demo/` so it still renders.

---

## Wiring the daily export

Point the same Apps Script that feeds the QA/LRM sheets at a new `Audit_Queue` tab:
run `audit_queue_daily.sql` in Metabase → CSV → clear-and-replace into `Audit_Queue`.
The app reads whatever is in that tab on each request (300s edge cache).

## Structure

```
public/
  index.html     Front-end (vanilla JS; fetches /api/queue, demo fallback)
  styles.css     Organic design-system tokens + components
  demo/          Sample feeds used when the API is empty
api/
  _sheets.js     Google Sheets helper (not a route)
  queue.js       GET /api/queue
package.json
vercel.json
```
