// api/queue.js  ->  GET /api/queue
//
// Two feeds, joined on rep_email:
//   1. Metabase Q4447   — the daily audit queue (audit_queue_daily.sql), pulled
//                          live over the Metabase REST API. One row per sampled lead.
//                          Falls back to a Sheets "Audit_Queue" tab if MB is unset.
//   2. "LRM_TL_MAP"     — the dynamic LRM -> TL / ZSM / ADOS mapping sheet.
//
// Returns { queue, hierarchy, auditDate, source }. The front-end does the merge
// + priority ranking + per-TL top-4 sampling.

const { readSheet, toObjects } = require('./_sheets');
const { fetchCardJson } = require('./_metabase');
const { requireUser, deny, parseList } = require('./_auth');

// warm-cache the whole pull so repeat loads are instant and never re-hit Metabase
let CACHE = null, CACHE_AT = 0;
const CACHE_TTL = 5 * 60 * 1000;

const QUEUE_TAB = process.env.QUEUE_TAB || 'Audit_Queue';
const MAP_TAB   = process.env.MAP_TAB   || 'LRM_TL_MAP';

const norm = e => String(e || '').trim().toLowerCase().replace('@homes.solarsquare.in', '@solarsquare.in');

// pull the first present header from a row object
function pick(o, keys) {
  for (const k of keys) if (o[k] !== undefined && o[k] !== '') return o[k];
  return '';
}

module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization,Content-Type');
  if (req.method === 'OPTIONS') return res.status(200).end();

  // ---- access gate: enforced only once an OAuth client ID is configured ----
  // (lets the app keep working on demo before Google Sign-In is set up; the moment
  //  GOOGLE_CLIENT_ID is set in Vercel, every call must carry a valid @domain token)
  const gateOn = !!(process.env.GOOGLE_CLIENT_ID || process.env.VITE_GOOGLE_CLIENT_ID);
  let user = null;
  if (gateOn) {
    const auth = await requireUser(req);
    if (!auth.ok) return deny(res, auth);
    user = auth.user;
  }

  try {
    const full = await getData();                       // cached full pull
    const scoped = scopeForUser(full, user);            // role-based slice
    res.setHeader('Cache-Control', 'private, max-age=0, must-revalidate');
    return res.status(200).json(scoped);
  } catch (err) {
    console.error('queue API error:', err);
    return res.status(500).json({ error: String(err.message || err) });
  }
};

// Determine a user's role from the hierarchy and return only the data they may see.
function scopeForUser(full, user) {
  if (!user) return { ...full, role: 'demo', user: null, meEmail: null };
  const email = String(user.email || '').toLowerCase();
  const admins = parseList(process.env.ADMIN_EMAILS);
  const H = full.hierarchy || [];
  let role = 'none', meEmail = null;
  if (admins.indexOf(email) >= 0) role = 'admin';
  else if (H.some(h => h.tl_email === email)) { role = 'tl'; meEmail = email; }
  else if (H.some(h => h.zsm_email === email)) role = 'zsm';
  else if (H.some(h => h.ados_email === email)) role = 'ados';

  // which TL emails is this user allowed to see?
  let tlSet = null; // null = all
  if (role === 'tl')  tlSet = new Set([email]);
  if (role === 'zsm') tlSet = new Set(H.filter(h => h.zsm_email === email).map(h => h.tl_email));
  if (role === 'ados') tlSet = new Set(H.filter(h => h.ados_email === email).map(h => h.tl_email));
  if (role === 'none') tlSet = new Set(); // no team → empty (access-limited)

  const repAllowed = new Set(
    tlSet ? H.filter(h => tlSet.has(h.tl_email)).map(h => h.rep_email) : H.map(h => h.rep_email)
  );
  const inScope = tlSet
    ? full.queue.filter(r => repAllowed.has(r.rep_email))
    : full.queue;
  const hierScope = tlSet
    ? H.filter(h => tlSet.has(h.tl_email))
    : H;

  return {
    auditDate: full.auditDate,
    source: full.source,
    user, role, meEmail,
    queue: inScope,
    hierarchy: hierScope,
  };
}

// Fetch + build the FULL dataset once, cached in warm memory for 5 min.
async function getData() {
  if (CACHE && Date.now() - CACHE_AT < CACHE_TTL) return CACHE;

  // ---- audit rows: Metabase Q4447 first, Sheets tab as fallback ----
  let queueRaw = [];
  let source = 'metabase';
  try {
    queueRaw = await fetchCardJson();
  } catch (e) {
    console.warn('Metabase pull failed, falling back to sheet:', e.message);
    source = 'sheet';
    queueRaw = toObjects(await readSheet(QUEUE_TAB).catch(() => []));
  }

  const num = v => Number(String(v == null ? '' : v).replace(/,/g, '')) || 0;

    const queue = queueRaw.map(r => ({
      audit_date:            r.audit_date || '',
      rep_id:                r.rep_id || '',
      rep_name:              r.rep_name || '',
      rep_email:             norm(r.rep_email),
      lead_id:               r.lead_id || '',
      lead_object_id:        r.lead_object_id || '',
      customer_name:         r.customer_name || '',
      cluster:               r.cluster || '',
      lead_stage:            r.lead_stage || '',
      category:              r.category || '',
      created_at:            r.created_at || null,
      meeting_confirmed_at:  r.meeting_confirmed_at || null,
      meeting_schedule_date: r.meeting_schedule_date || null,
      meeting_done_date:     r.meeting_done_date || null,
      follow_up_at:          r.follow_up_at || null,
      qualified_at:          r.qualified_at || null,
      status_changed_at:     r.status_changed_at || null,
      order_closed_at:       r.order_closed_at || null,
      attempt_today:         r.attempt_today === true || String(r.attempt_today).toLowerCase() === 'true',
      days_overdue:          num(r.days_overdue),
      category_rank:         num(r.category_rank),
    })).filter(r => r.lead_id && r.category);

    // ---- trim: keep only the top N most-overdue per (rep, category) ----
    // the app samples 4/category/TL, so 12 gives ample headroom while capping payload
    const PER = Number(process.env.PER_REP_CATEGORY || 12);
    const seen = {};
    const trimmed = queue
      .slice()
      .sort((a, b) => b.days_overdue - a.days_overdue)
      .filter(r => {
        const k = r.rep_email + '|' + r.category;
        seen[k] = (seen[k] || 0) + 1;
        return seen[k] <= PER;
      });

    // ---- hierarchy: LRM_TL_MAP sheet ----
    const mRaw = await readSheet(MAP_TAB).catch(() => []);
    const hierarchy = toObjects(mRaw).map(r => ({
      rep_email:  norm(pick(r, ['Email IDs', 'Email ID', 'LRM Email', 'rep_email'])),
      rep_name:   pick(r, ['LRM Name', 'Name', 'rep_name']),
      sseid:      pick(r, ['SSEID', 'SSE ID', 'sseid']),
      cluster:    pick(r, ['Cluster', 'City', 'cluster']),
      tl_email:   norm(pick(r, ['LRM TL Email ID', 'LRM TL', 'TL Email', 'tl_email'])),
      tl_name:    pick(r, ['Reporting Team Lead', 'TL Name', 'tl_name']),
      zsm_email:  norm(pick(r, ['LRM DZSM Email ID', 'DZSM', 'ZSM Email', 'zsm_email'])),
      zsm_name:   pick(r, ['ZSM Name', 'zsm_name']),
      ados_email: norm(pick(r, ['ADOS Email', 'ADOS', 'ados_email'])),
      ados_name:  pick(r, ['ADOS Name', 'ados_name']),
      hr_status:  pick(r, ['HR Status', 'Status', 'hr_status']) || 'Active',
    })).filter(h => h.rep_email && h.hr_status.toLowerCase() !== 'inactive');

    const auditDate = (trimmed[0] && trimmed[0].audit_date) || new Date().toISOString().slice(0, 10);
    CACHE = { auditDate, source, queue: trimmed, hierarchy };
    CACHE_AT = Date.now();
    return CACHE;
}

// raise the serverless limit above Metabase's cold round-trip (needs Vercel Pro;
// harmless on Hobby, which caps at 10s regardless). Set AFTER the handler assignment
// so it isn't clobbered by `module.exports = handler`.
module.exports.config = { maxDuration: 30 };
