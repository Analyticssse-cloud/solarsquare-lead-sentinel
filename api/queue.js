// api/queue.js  ->  GET /api/queue
//
// Two feeds, joined on lrm_email:
//   1. Metabase Q4447   — the daily audit queue (audit_queue_daily_v4.sql), pulled
//                          live over the Metabase REST API. The query does the
//                          categorising and per-category ranking. It emits NO TL columns
//                          and applies NO cap — the 4-per-category / 20-per-TL cap is
//                          applied in the front-end, pooled across each TL's LRMs.
//                          Falls back to a Sheets "Audit_Queue" tab if MB is unset.
//   2. "LRM_TL_MAP"     — the LRM -> TL / ZSM / ADOS mapping sheet: the source of truth
//                          for every level above the LRM. Joined on lrm_email.
//
// Returns { queue, hierarchy, auditDate, source }.

const { readSheet, readQueueSheet, toObjects } = require('./_sheets');
const { fetchCardJson } = require('./_metabase');
const { requireUser, deny, parseList } = require('./_auth');
const access = require('./access');
const mapping = require('./mapping');

// warm-cache the whole pull so repeat loads are instant and never re-hit Metabase
let CACHE = null, CACHE_AT = 0;
const CACHE_TTL = 5 * 60 * 1000;

const QUEUE_TAB = process.env.QUEUE_TAB || 'Audit_Queue';
const MAP_TAB   = process.env.MAP_TAB   || 'LRM_TL_MAP';

const norm = e => String(e || '').trim().toLowerCase().replace('@homes.solarsquare.in', '@solarsquare.in');

// Loose name key for the email fallback: case/punctuation/extra-space insensitive.
const nameKey = n => String(n || '').toLowerCase().replace(/[^a-z]+/g, ' ').trim();

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
    // ?fresh=1 skips the warm cache — the app sends it right after an admin saves a
    // mapping or access change, so the effect is visible immediately instead of in 5 min.
    const fresh = /(?:\?|&)fresh=1(?:&|$)/.test(req.url || '');
    const full = await getData(fresh);                  // cached full pull
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
  if (!user) return { ...full, role: 'none', user: null, meEmail: null };
  const email = String(user.email || '').toLowerCase();
  const admins = parseList(process.env.ADMIN_EMAILS);
  const H = full.hierarchy || [];
  const ov = (full.overrides || {})[email] || null;

  let role = 'none', meEmail = null;
  // Explicit overrides win over the org chart — that is the point of them. 'none' blocks
  // an account the chart would otherwise admit.
  if (ov && ov.role === 'none') role = 'blocked';
  else if (admins.indexOf(email) >= 0 || (ov && ov.role === 'admin')) role = 'admin';
  else if (ov && ov.role === 'auditor') role = 'auditor';
  else if (ov && ov.role === 'zsm') role = 'zsm';
  else if (ov && ov.role === 'ados') role = 'ados';
  else if (ov && ov.role === 'tl') { role = 'tl'; meEmail = email; }
  else if (H.some(h => h.tl_email === email)) { role = 'tl'; meEmail = email; }
  else if (H.some(h => h.zsm_email === email)) role = 'zsm';
  else if (H.some(h => h.ados_email === email)) role = 'ados';

  // which TL emails is this user allowed to see?
  let tlSet = null; // null = all
  if (role === 'tl')  tlSet = new Set([email]);
  if (role === 'zsm') tlSet = new Set(H.filter(h => h.zsm_email === email).map(h => h.tl_email));
  if (role === 'ados') tlSet = new Set(H.filter(h => h.ados_email === email).map(h => h.tl_email));
  if (role === 'none' || role === 'blocked') tlSet = new Set();
  // an overridden zsm/ados/auditor with no reporting lines of their own sees everything,
  // otherwise the grant would be meaningless
  if (ov && ['zsm', 'ados', 'auditor'].indexOf(ov.role) >= 0 && tlSet && !tlSet.size) tlSet = null;
  if (role === 'auditor') tlSet = tlSet || null;

  const lrmAllowed = new Set(
    tlSet ? H.filter(h => tlSet.has(h.tl_email)).map(h => h.lrm_email) : H.map(h => h.lrm_email)
  );
  const inScope = tlSet
    ? full.queue.filter(r => lrmAllowed.has(r.lrm_email))
    : full.queue;
  const hierScope = tlSet
    ? H.filter(h => tlSet.has(h.tl_email))
    : H;

  return {
    auditDate: full.auditDate,
    source: full.source,
    resolvedByName: full.resolvedByName || 0,
    excludedUnmapped: full.excludedUnmapped || 0,
    // Admins get the list of LRMs the mapping doesn't know, so they can give them a TL
    // from inside Settings instead of waiting on an EmployeeMaster edit.
    unmappedLrms: role === 'admin' ? (full.unmappedLrms || []) : [],
    mappingOverrides: role === 'admin' ? (full.mappingOverrides || {}) : {},
    auditors: Object.keys(full.overrides || {}).filter(e => (full.overrides[e].role === 'auditor')),
    overrideRole: ov ? ov.role : '',
    user, role, meEmail,
    queue: inScope,
    hierarchy: hierScope,
  };
}

// Fetch + build the FULL dataset once, cached in warm memory for 5 min.
async function getData(fresh) {
  if (!fresh && CACHE && Date.now() - CACHE_AT < CACHE_TTL) return CACHE;

  // ---- audit rows: Metabase Q4447 first, Sheets tab as fallback ----
  let queueRaw = [];
  let source = 'metabase';
  try {
    queueRaw = await fetchCardJson();
  } catch (e) {
    console.warn('Metabase pull failed, falling back to sheet:', e.message);
    source = 'sheet';
    queueRaw = toObjects(await readQueueSheet(QUEUE_TAB).catch(() => []));
  }

  const num = v => Number(String(v == null ? '' : v).replace(/,/g, '')) || 0;

    const queue = queueRaw.map(r => ({
      audit_date:            r.audit_date || '',
      lrm_id:                r.lrm_id || '',
      lrm_name:              r.lrm_name || '',
      lrm_email:             norm(r.lrm_email),
      lrm_name:              r.lrm_name || '',
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
      // v4 — activity-driven detection
      last_activity_at:      r.last_activity_at || null,
      last_activity_type:    r.last_activity_type || '',
      days_silent:           num(r.days_silent),
      hours_silent:          num(r.hours_silent),
      calls_30d:             num(r.calls_30d),
      connects_30d:          num(r.connects_30d),
      leak_code:             r.leak_code || '',
      crm_touch_at:          r.crm_touch_at || null,
      loop_turns:            num(r.loop_turns),
      mcch_events:           num(r.mcch_events),
      dev_events:            num(r.dev_events),
      lead_status:           r.lead_status || '',
      days_overdue:          num(r.days_overdue),
      priority_key:          num(r.priority_key),
      category_rank:         num(r.lrm_category_rank || r.category_rank),
    })).filter(r => r.lead_id && r.category);

    // ---- today only ----
    // The Apps Script job appends every day to Audit_Queue_Log and refreshes the
    // Audit_Queue tab, but if the app is ever pointed at the append-only log it must
    // not stack weeks of history into one queue. Keep the newest audit_date present.
    const dates = [...new Set(queue.map(r => String(r.audit_date || '').slice(0, 10)).filter(Boolean))].sort();
    const latest = dates[dates.length - 1];
    const todayOnly = latest ? queue.filter(r => String(r.audit_date || '').slice(0, 10) === latest) : queue;

    // ---- hierarchy: the mapping sheet ----
    const mRaw = await readSheet(MAP_TAB).catch(() => []);
    const hierarchyBase = toObjects(mRaw).map(r => ({
      lrm_email:  norm(pick(r, ['Email IDs', 'Email ID', 'LRM Email', 'lrm_email'])),
      lrm_name:   pick(r, ['LRM Name', 'Name', 'lrm_name']),
      sseid:      pick(r, ['SSEID', 'SSE ID', 'sseid']),
      cluster:    pick(r, ['Cluster', 'City', 'cluster']),
      tl_email:   norm(pick(r, ['LRM TL Email ID', 'LRM TL', 'TL Email', 'tl_email'])),
      tl_name:    pick(r, ['Reporting Team Lead', 'TL Name', 'tl_name']),
      zsm_email:  norm(pick(r, ['LRM DZSM Email ID', 'DZSM', 'ZSM Email', 'zsm_email'])),
      zsm_name:   pick(r, ['ZSM Name', 'zsm_name']),
      ados_email: norm(pick(r, ['ADOS Email', 'ADOS', 'ados_email'])),
      ados_name:  pick(r, ['ADOS Name', 'ados_name']),
      hr_status:  pick(r, ['HR Status', 'Status', 'hr_status']) || 'Active',
    })).filter(h => h.lrm_email && h.hr_status.toLowerCase() !== 'inactive');

    // ---- reporting-line overrides (Mapping_Overrides tab, edited in Settings) ----
    // EmployeeMaster stays read-only; this patches it. An LRM present only in the
    // override tab is added outright, which is how an admin maps someone HR hasn't
    // filed yet.
    const mappingOverrides = await mapping.readMappingOverrides().catch(() => ({}));
    const hierarchy = mapping.applyOverrides(hierarchyBase, mappingOverrides);

    // ---- name fallback (before scoping, so a nameable row still finds its TL) ----
    // The card can emit a blank lrm_email when an LRM's users record has no address.
    // If the name matches the mapping sheet, use that; otherwise the row is dropped
    // below with the rest of the unmapped.
    const byName = {};
    hierarchy.forEach(x => { const k = nameKey(x.lrm_name); if (k && !byName[k]) byName[k] = x.lrm_email; });
    let resolvedByName = 0;
    todayOnly.forEach(r => {
      if (r.lrm_email) return;
      const hit = byName[nameKey(r.lrm_name)];
      if (hit) { r.lrm_email = hit; r.lrm_email_source = 'name'; resolvedByName++; }
    });

    // ---- scope to the mapped org ----
    // An LRM who isn't in the mapping sheet has no TL, so nobody can review their leads.
    // Carrying those rows anyway only produces confusion, so they are dropped here and
    // reported as a count. This is by design, not a failure: the mapping sheet defines
    // who this tool covers.
    const mapped = new Set(hierarchy.map(x => x.lrm_email));
    const inOrg = todayOnly.filter(r => r.lrm_email && mapped.has(r.lrm_email));
    const excludedUnmapped = todayOnly.length - inOrg.length;
    const excludedLrms = [...new Set(todayOnly
      .filter(r => !r.lrm_email || !mapped.has(r.lrm_email))
      .map(r => r.lrm_email || ('(no email) ' + (r.lrm_name || '?'))))];

    // Same set, but with the name and the number of leads stranded behind it — that is
    // what makes the Settings list actionable rather than a wall of addresses.
    const stranded = {};
    todayOnly.forEach(r => {
      if (r.lrm_email && mapped.has(r.lrm_email)) return;
      const k = r.lrm_email || ('name:' + (r.lrm_name || '?'));
      const e = stranded[k] || (stranded[k] = { lrm_email: r.lrm_email || '', lrm_name: r.lrm_name || '', cluster: r.cluster || '', leads: 0 });
      e.leads++;
      if (!e.cluster && r.cluster) e.cluster = r.cluster;
    });
    const unmappedLrms = Object.values(stranded).sort((a, b) => b.leads - a.leads).slice(0, 400);

    // ---- payload guard ----
    // keep the top N candidates per (LRM, category) so every TL has enough to fill its
    // 4-per-category picks and backfill; the real cap is applied in the front-end
    const PER = Number(process.env.PER_LRM_CATEGORY || 12);
    const seen = {};
    const trimmed = inOrg
      .slice()
      .sort((a, b) => (b.priority_key - a.priority_key) || (b.days_overdue - a.days_overdue))
      .filter(r => {
        const k = r.lrm_email + '|' + r.category;
        seen[k] = (seen[k] || 0) + 1;
        return seen[k] <= PER;
      });

    const auditDate = (trimmed[0] && trimmed[0].audit_date) || new Date().toISOString().slice(0, 10);
    // access overrides are tiny and change rarely; read them with the same cache
    const overrides = await access.readOverrides().catch(() => ({}));
    CACHE = { auditDate, source, queue: trimmed, hierarchy, overrides, mappingOverrides,
              resolvedByName, excludedUnmapped, excludedLrms, unmappedLrms };
    CACHE_AT = Date.now();
    return CACHE;
}

// raise the serverless limit above Metabase's cold round-trip (needs Vercel Pro;
// harmless on Hobby, which caps at 10s regardless). Set AFTER the handler assignment
// so it isn't clobbered by `module.exports = handler`.
module.exports.config = { maxDuration: 60 };
// /api/debug reuses the exact same pull, so a diagnosis can never disagree with the app.
module.exports.getData = getData;
