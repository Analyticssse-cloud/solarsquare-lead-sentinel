# SolarSquare Lead Sentinel — Vercel Deploy

Same structure as `solarsquare-lrm`: plain HTML front-end + Vercel serverless functions, **no build step**. Same Google service account.

The tool reads **two tabs** from the Google Sheet and merges them on `lrm_email` in the browser:

| Tab | What it is | Who fills it |
|-----|------------|--------------|
| `Audit_Queue` | **Today's** queue — header + today's rows, replaced on each run | `apps-script/AuditQueueDaily.gs` — this is what the app reads |
| `Audit_Queue_Log` | **Append-only history** — every day's export, forever (`exported_at` + all v4 columns) | same job, appended; never overwritten |
| `LRM_TL_MAP`  | LRM → TL / ZSM / ADOS mapping (dynamic) | maintained for the QA / LRM dashboards — **read only, never written to** |

The daily job is `apps-script/AuditQueueDaily.gs` — same pattern as the IVR master sheet:
log in to Metabase, run the saved card (`audit_queue_daily_v4.sql`), append to
`Audit_Queue_Log`, and refresh `Audit_Queue`. It is idempotent — a second run on the same
`audit_date` exits without writing (use `deleteToday()` to force a re-export) — and it trims
the log past `KEEP_DAYS` (120). Set the Metabase credentials as Script Properties and add a
daily 6–7 AM IST trigger; setup notes are in the file header.

The API also guards this: if it is ever pointed at the append-only log, it keeps only the
**newest `audit_date`** present, so history can never stack into one day's queue.

Both live on the spreadsheet at `SHEET_ID`. A **separate** spreadsheet (`RCA_SHEET_ID`) holds
the app's own write-side log:

| Tab | What it holds | Written by |
|---|---|---|
| `RCA_Log` | Every completed RCA, appended | the app, via `/api/rca` — tab created automatically |

`Audit_Queue` header row must match the SQL column names: `audit_date, lrm_id, lrm_name, lrm_email, lead_id, customer_name, cluster, lead_stage, lead_status, category, leak_code, priority_key, lrm_category_rank, created_at, meeting_confirmed_at, meeting_schedule_date, meeting_done_date, follow_up_at, qualified_at, status_changed_at, attempt_today, last_activity_at, last_activity_type, days_silent, hours_silent, crm_touch_at, calls_30d, connects_30d, loop_turns, mcch_events, dev_events, days_overdue`.

### Two open column names

v4 runs, but two filters are scaffolded off because this schema dump doesn't pin their
column names — see the lines marked `(A)` and `(D)` in the query, and run
`probe_columns.sql` to resolve them:

- **(A) Manual-only call filter.** Without it `calls_30d` counts Progressive / IVR /
  Inbound traffic too, so an LRM looks more diligent than they were.
- **(D) Agent scoping.** Dials are matched on the customer's phone number, so a bot or
  another agent calling that number counts as the assigned LRM having called. This is the
  bigger of the two — it can make a completely untouched lead look worked, which is
  exactly the failure this tool exists to catch.

Both only ever make the tool *under*-report leaks, never over-report. Dial counts are
already scoped to `>= lrm_assigned_at`, so a previous owner's calls can't leak in.

### If the queue comes back empty

Open `/api/debug` — it runs the app's own pull and returns a plain-English verdict. The
app shows the same diagnosis inline on the empty-queue screen.

The failure seen on 31 Jul is worth knowing: **Metabase card 4447 was emitting a blank
`lrm_email` on every row.** With no LRM address nothing joins to the mapping sheet, no TL
owns any lead, and every screen goes empty — while sign-in and role resolution work
perfectly, which makes it look like a permissions problem. It isn't.

Two things to keep in step:

1. **The card must run the current query.** Card 4447 was still on an old version (36 rows,
   three categories, no `lrm_email`). Update it to `audit_queue_daily_v5.sql`.
2. **`QUEUE_TAB` must exist.** `Audit_Queue` was missing from the spreadsheet, so the sheet
   fallback couldn't cover for the thin card. Create the tab — the Apps Script job does it
   for you — or point `QUEUE_TAB` at the right name.

The API now also resolves a missing `lrm_email` by matching `lrm_name` against the mapping
sheet, so a thin card degrades instead of going blank. That is a safety net, not a fix:
`/api/debug` reports how many rows relied on it, and any spelling difference still drops
the lead.

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
| `MAP_TAB`         | *(optional)* mapping tab name — defaults to `LRM_TL_MAP` (currently set to `EmployeeMaster`) |
| `GOOGLE_CLIENT_ID`| OAuth client ID — **the moment this is set, sign-in is enforced** |
| `ADMIN_EMAILS`    | comma-separated admins (see the Settings tab) |
| `BLOB_READ_WRITE_TOKEN` | *(optional)* Vercel Blob token — enables server-side call-recording storage |
| `OPENAI_API_KEY`  | *(not used — transcription is shelved for now)* |
| `SHEET_ID`         | the org's shared mapping spreadsheet (`EmployeeMaster`) — **read only** |
| `QUEUE_SHEET_ID`   | *(optional)* spreadsheet holding `Audit_Queue` / `Audit_Queue_Log`. Defaults to `SHEET_ID`; set it so the daily job never writes into the shared mapping file |
| `RCA_SHEET_ID`    | spreadsheet the app writes the RCA log into — **must not** be the mapping sheet |
| `RCA_TAB`         | *(optional)* RCA log tab name — defaults to `RCA_Log` |

4. **Deploy.**

### Call recordings

Without `BLOB_READ_WRITE_TOKEN` recordings still work, but they live in the auditor's
own browser (IndexedDB) and no one else can hear them. To share them across the team:
Vercel dashboard → **Storage → Create → Blob**, connect it to this project, redeploy.
The token is injected automatically and `/api/recording` starts persisting uploads.

### Transcription — shelved

Removed for now. Two approaches were built and both were unsatisfying in practice:
on-device Whisper (Transformers.js) was free and private but CPU-bound and slow (~1–2 min
per 10 min of audio, since most machines expose no usable WebGPU adapter), and the hosted
OpenAI route bills per minute and sends customer audio to a third party.

When this comes back, the likely answer is a self-hosted **faster-whisper** endpoint on a
machine SolarSquare already owns, fronted by an `/api/transcribe` route — no per-minute
cost, audio stays in-house, and the GPU makes it fast enough to be useful. Recording upload
is unaffected and still works.

### Roles

The queue is work **TLs** do. Everyone above them sees what the teams did with it:

| Role | Tabs |
|---|---|
| Team Lead | Audit queue · My adherence |
| RCA auditor (`RCA_AUDITOR_EMAILS` / Settings) | RCA audit · Team progress |
| ZSM / ADOS | Team progress |
| Admin | RCA audit · Team progress · Settings |

No role is ever locked out by an empty queue — a day with nothing flagged shows an empty
state, not an error.

### Sign-in
Sign-in only turns on once `GOOGLE_CLIENT_ID` is set. Add the deployed URL
(`https://<app>.vercel.app`) to the OAuth client's **Authorised JavaScript origins**,
or Google rejects the login with an `origin` error.

## 3. Verify

- `https://<app>.vercel.app/api/queue` → `{ "auditDate": "...", "queue": [...], "hierarchy": [...] }`
- `https://<app>.vercel.app` → the tool loads. If `/api/queue` is empty or errors, the UI
  automatically falls back to the bundled demo data in `public/demo/` so it still renders.

---

## Which spreadsheet holds what

Three distinct roles — keep them separate:

| Spreadsheet | Env var | Tabs | App's access |
|---|---|---|---|
| The org's shared mapping sheet | `SHEET_ID` | `EmployeeMaster` | **read only, always** |
| Lead Sentinel data | `QUEUE_SHEET_ID` | `Audit_Queue`, `Audit_Queue_Log`, `Run_Log` | read (Apps Script writes it) |
| Lead Sentinel RCA log | `RCA_SHEET_ID` | `RCA_Log` | read + append |

The last two can be the **same new spreadsheet** — simplest setup:

1. Create one Google Sheet, e.g. *Lead Sentinel — Data*. Leave it empty.
2. Share it with the service account (`GOOGLE_SA_EMAIL`) as **Editor**.
3. Set both `QUEUE_SHEET_ID` and `RCA_SHEET_ID` to its id (the string in the URL between
   `/d/` and `/edit`), and redeploy.
4. Bind `apps-script/AuditQueueDaily.gs` to that same spreadsheet. It creates `Audit_Queue`
   and `Audit_Queue_Log` on its first run — **nothing to create by hand.**

`QUEUE_SHEET_ID` falls back to `SHEET_ID` when unset, which is why `Audit_Queue` was being
looked for inside the mapping sheet and reported `Unable to parse range`. Setting it is
what keeps the daily job out of a file other teams depend on.

## Wiring the daily export

Point the same Apps Script that feeds the QA/LRM sheets at a new `Audit_Queue` tab:
run `audit_queue_daily_v5.sql` in Metabase → CSV → clear-and-replace into `Audit_Queue`
(or let `apps-script/AuditQueueDaily.gs` do it on a daily trigger).
The app reads whatever is in that tab on each request (300s edge cache).

> **v5 is current.** v4 parsed but produced an unusable queue — 18,798 rows, 69% of them
> already closed, median breach 304 days old, and both terminal categories never firing.
> v5 adds the two gates it was missing: the lead must be **open** (not won/booked) and the
> breach must be **recent** (14 days, tunable in the `cfg` CTE at the top). It also routes
> not-interested / not-qualified off the real stage strings, stops flagging completed
> meetings as missed, and tests terminal branches before meeting branches.
> v2–v4 are kept for reference and are superseded.

> **v4 is current.** It expresses the lead-journey flowchart directly: each of the five
> branches (MLS/MD, CNC, call-later loop, LI, NQ) maps to a leak code L0–L4, and a lead is
> only flagged when it has ALSO gone **silent** since its last real activity (stage change,
> Manual Ozonetel dial, follow-up, CRM edit). New in v4: Manual-only call filtering,
> `loop_turns` counted from the audit history so the never-closing call-later loop is
> visible, and resolved `customer_name`.
> `audit_queue_daily_v2.sql` / `_v3.sql` are kept for reference and are superseded.

### The RCA log (write side)

Completed RCAs are appended by `/api/rca` to an **`RCA_Log`** tab on a spreadsheet created
**for this app** — not the LRM→TL mapping sheet. That mapping file was shared for reading
only and the app never writes to it; if `RCA_SHEET_ID` is unset, writes are refused with a
clear message rather than falling back to it.

This log is what makes cross-team numbers possible: “Done” in Team progress, month-to-date
adherence, and the RCA-audit tab all read it.

Setup, once:

1. Create a new Google Sheet — e.g. *Lead Sentinel — RCA Log*. Leave it empty.
2. Share it with the service account (`GOOGLE_SA_EMAIL`) as **Editor**.
3. Set `RCA_SHEET_ID` in Vercel to its id (the long string in the sheet URL between
   `/d/` and `/edit`), and redeploy.

The `RCA_Log` tab and its header row are created on the first submission. Submissions queue
in the browser (`localStorage` outbox) and retry every 20s, so an auditor on a flaky
connection never loses a logged RCA.

## Structure

```
public/
  index.html          Front-end (vanilla JS; fetches /api/queue)
  preview.html        Redirects to index.html?sample=1 — layout preview with fake data,
                      banner-marked, never reachable without the explicit flag
  styles.css          Design-system tokens + components
  demo/               (removed — no demo account, no silent fallback)
api/
  _sheets.js     Google Sheets helper (not a route)
  _metabase.js   Metabase REST helper (not a route)
  _auth.js       Google token verification (not a route)
  queue.js       GET  /api/queue
  debug.js       GET  /api/debug         (why is the queue empty? — reads the same pull)
  rca.js         GET/POST /api/rca      (the shared RCA log — read + append)
  recording.js   POST /api/recording    (Vercel Blob storage, optional)
  config.js      GET  /api/config
package.json
vercel.json
```
