# SolarSquare Lead Sentinel — Vercel Deploy

Same structure as `solarsquare-lrm`: plain HTML front-end + Vercel serverless functions, **no build step**. Same Google service account.

The tool reads **two tabs** from the Google Sheet and merges them on `lrm_email` in the browser:

| Tab | What it is | Who fills it |
|-----|------------|--------------|
| `Audit_Queue` | Daily output of `audit_queue_daily_v3.sql` (one row per sampled lead) | Apps Script / Metabase export, once a day |
| `LRM_TL_MAP`  | LRM → TL / ZSM / ADOS mapping (dynamic) | already maintained for the QA / LRM dashboards |

`Audit_Queue` header row must match the SQL column names: `audit_date, lrm_id, lrm_name, lrm_email, lead_id, customer_name, cluster, lead_stage, category, leak_code, priority_key, lrm_category_rank, created_at, meeting_confirmed_at, meeting_schedule_date, meeting_done_date, follow_up_at, qualified_at, status_changed_at, attempt_today, last_activity_at, last_activity_type, days_silent, hours_silent, calls_30d, connects_30d, days_overdue`.

---

## 1. Push to GitHub

First time only:

```bash
cd lead-sentinel-vercel
git init
git add .
git commit -m "lead sentinel"
git branch -M main
git remote add origin https://github.com/Analyticssse-cloud/solarsquare-lead-sentinel.git
git push -u origin main
```

Every time after that — this is all a normal update needs, Vercel redeploys on push:

```bash
cd lead-sentinel-vercel
git add .
git commit -m "activity-driven detection + recording upload"
git push
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
| `GOOGLE_CLIENT_ID`| OAuth client ID — **the moment this is set, sign-in is enforced** |
| `ADMIN_EMAILS`    | comma-separated admins (see the Settings tab) |
| `BLOB_READ_WRITE_TOKEN` | *(optional)* Vercel Blob token — enables server-side call-recording storage |

4. **Deploy.**

### Call recordings

Without `BLOB_READ_WRITE_TOKEN` recordings still work, but they live in the auditor's
own browser (IndexedDB) and no one else can hear them. To share them across the team:
Vercel dashboard → **Storage → Create → Blob**, connect it to this project, redeploy.
The token is injected automatically and `/api/recording` starts persisting uploads.

### Sign-in

Sign-in only turns on once `GOOGLE_CLIENT_ID` is set. Add the deployed URL
(`https://<app>.vercel.app`) to the OAuth client's **Authorised JavaScript origins**,
or Google rejects the login with an `origin` error.

## 3. Verify

- `https://<app>.vercel.app/api/queue` → `{ "auditDate": "...", "queue": [...], "hierarchy": [...] }`
- `https://<app>.vercel.app` → the tool loads. If `/api/queue` is empty or errors, the UI
  automatically falls back to the bundled demo data in `public/demo/` so it still renders.

---

## Wiring the daily export

Point the same Apps Script that feeds the QA/LRM sheets at a new `Audit_Queue` tab:
run `audit_queue_daily_v3.sql` in Metabase → CSV → clear-and-replace into `Audit_Queue`.
The app reads whatever is in that tab on each request (300s edge cache).

> v3 is the activity-driven query: a lead is only flagged when it has gone **silent**
> since its last real activity (stage change, Ozonetel dial, follow-up, CRM edit).
> `audit_queue_daily_v2.sql` is kept for reference but is superseded.

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
