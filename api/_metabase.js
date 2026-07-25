// api/_metabase.js
//
// Pulls a saved question's results as JSON. No API key on this instance, so we
// authenticate with a service account (username + password) -> session token,
// cached in module memory across warm invocations.
//
//   POST /api/session            { username, password }      -> { id: <token> }
//   POST /api/card/:id/query/json  (X-Metabase-Session)      -> [ {col: val}, ... ]
//
// Env:
//   METABASE_URL   e.g. https://metabase-lighthouse.solarsquare.in
//   METABASE_USER  service-account email
//   METABASE_PASS  service-account password
//   METABASE_CARD  saved-question id (default 4447)

const BASE = (process.env.METABASE_URL || '').replace(/\/+$/, '');
const CARD = process.env.METABASE_CARD || '4447';

let sessionToken = null;
let sessionAt = 0;
const SESSION_TTL = 12 * 60 * 60 * 1000; // 12h; Metabase default is 14 days

async function login() {
  const r = await fetch(`${BASE}/api/session`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      username: process.env.METABASE_USER,
      password: process.env.METABASE_PASS,
    }),
  });
  if (!r.ok) throw new Error(`Metabase login failed (${r.status})`);
  const j = await r.json();
  sessionToken = j.id;
  sessionAt = Date.now();
  return sessionToken;
}

async function token() {
  if (sessionToken && Date.now() - sessionAt < SESSION_TTL) return sessionToken;
  return login();
}

// snake_case any Metabase column key: "Audit Date" / "audit_date" -> audit_date
const keyify = k => String(k).trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '');

async function fetchCardJson(cardId = CARD) {
  if (!BASE || !process.env.METABASE_USER) throw new Error('Metabase env not configured');

  const call = async tok => fetch(`${BASE}/api/card/${cardId}/query/json`, {
    method: 'POST',
    headers: { 'X-Metabase-Session': tok, 'Content-Type': 'application/json' },
    body: '{}',
  });

  let r = await call(await token());
  if (r.status === 401 || r.status === 403) {       // stale session -> re-login once
    sessionToken = null;
    r = await call(await login());
  }
  if (!r.ok) throw new Error(`Metabase query failed (${r.status})`);

  const rows = await r.json();
  return rows.map(row => {
    const o = {};
    for (const k in row) o[keyify(k)] = row[k];
    return o;
  });
}

module.exports = { fetchCardJson };
