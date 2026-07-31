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
| `OPENAI_API_KEY`  | *(optional)* hosted transcription — **not needed**, the default engine is on-device |
| `TRANSCRIBE_URL`  | *(optional)* self-hosted Whisper endpoint, used instead of OpenAI |
| `TRANSCRIBE_MODEL`| *(optional)* defaults to `gpt-4o-transcribe`; `whisper-1` also works |

4. **Deploy.**

### Call recordings

Without `BLOB_READ_WRITE_TOKEN` recordings still work, but they live in the auditor's
own browser (IndexedDB) and no one else can hear them. To share them across the team:
Vercel dashboard → **Storage → Create → Blob**, connect it to this project, redeploy.
The token is injected automatically and `/api/recording` starts persisting uploads.

### Transcription

**The default engine costs nothing and needs no setup.** Whisper (MIT weights) runs
on-device in the auditor's browser via WebGPU/WASM — no API key, no server, and the call
audio never leaves the machine. Pick the engine, model and language under any recording:

- **Tiny** — fastest, rough. Fine for checking whether a call happened at all.
- **Base** (default) — the sensible balance.
- **Small** — slowest, clearly best on Hindi / code-switched calls.

The model downloads once (~40 MB tiny, ~80 MB base, ~250 MB small) and is then cached by
the browser, so only the first transcription waits. WebGPU is used when the browser exposes
it and is several times faster; otherwise it falls back to WASM. Expect roughly
0.5–2× real time on WebGPU, slower on WASM — the tab must stay open.

Needs a Chromium browser (Chrome/Edge) for module workers + WebGPU. Transcripts are cached
with the recording, so re-opening a lead never re-runs the model.

#### Optional: a server backend instead

`/api/transcribe` exists so the backend can be swapped without touching the UI — choose
“Server” in the engine dropdown. Two ways to fill it:

- `TRANSCRIBE_URL` — any OpenAI-compatible `/audio/transcriptions` endpoint
  (faster-whisper-server, whisper.cpp server, your own GPU box). **No per-minute cost**,
  and audio stays inside your infrastructure. No OpenAI key needed.
- `OPENAI_API_KEY` — the hosted API, ~$0.006/min. Convenient, but it bills per call and
  sends customer audio to a third party. `TRANSCRIBE_MODEL` defaults to
  `gpt-4o-transcribe`; set `whisper-1` for segment timestamps.

Both server paths need **Vercel Pro** for the 300s function timeout — on Hobby long calls
are cut at 10s. The on-device engine has no such limit, which is another reason it's the
default.

Compliance note: on-device and self-hosted keep recordings in-house. Only the hosted
OpenAI path sends customer audio out — get that cleared before enabling it.

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
  index.html          Front-end (vanilla JS; fetches /api/queue, demo fallback)
  styles.css          Design-system tokens + components
  whisper-worker.js   On-device Whisper (Transformers.js) — the default, free engine
  demo/               Sample feeds used when the API is empty
api/
  _sheets.js     Google Sheets helper (not a route)
  _metabase.js   Metabase REST helper (not a route)
  _auth.js       Google token verification (not a route)
  queue.js       GET  /api/queue
  recording.js   POST /api/recording    (Vercel Blob storage, optional)
  transcribe.js  POST /api/transcribe   (OpenAI or self-hosted, optional)
  config.js      GET  /api/config
package.json
vercel.json
```
