// api/rca.js  ->  GET /api/rca      read the RCA log (last N days)
//                 POST /api/rca     append one completed RCA
//
// This is the shared write store the app was missing. Until it existed, completed RCAs
// lived in each auditor's browser, so no manager could see what another team had done.
//
// Storage is an RCA_Log tab on a spreadsheet created FOR THIS APP (env RCA_SHEET_ID) —
// deliberately NOT the LRM→TL mapping sheet the org shared for reading, which stays
// read-only. The tab is created on first write. One row per RCA submission; re-submitting
// the same lead appends a second row and readers keep the LATEST per (audit_date, lead_id).
//
// ENV: RCA_SHEET_ID (the log spreadsheet, shared with the service account as Editor),
//      GOOGLE_SA_EMAIL, GOOGLE_SA_KEY, RCA_TAB (optional, default 'RCA_Log')

const { readSheet, toObjects, ensureTab, appendRows, readWriteSheet, WRITE_SHEET_ID } = require('./_sheets');
const { requireUser, deny } = require('./_auth');

const RCA_TAB = process.env.RCA_TAB || 'RCA_Log';

const HEADER = [
  'logged_at', 'audit_date', 'lead_id', 'customer_name', 'category',
  'lrm_email', 'lrm_name', 'tl_email', 'tl_name',
  'auditor_email', 'auditor_name',
  'reason', 'severity', 'action', 'note', 'why_path', 'assignee',
  'what', 'why', 'owner', 'fault', 'action_status',
  // The call recording the TL attached while doing the RCA. Without these two the
  // audio was written to blob storage and then orphaned — nothing in the log pointed
  // at it, so a Quality auditor opening the RCA had no way to hear the call.
  'recording_url', 'recording_name',
];

const clean = v => String(v === undefined || v === null ? '' : v).replace(/[\r\n\t]+/g, ' ').slice(0, 900);

function readBody(req) {
  if (req.body && typeof req.body === 'object') return Promise.resolve(req.body);
  return new Promise(resolve => {
    let s = '';
    req.on('data', c => { s += c; if (s.length > 512 * 1024) req.destroy(); });
    req.on('end', () => { try { resolve(JSON.parse(s || '{}')); } catch (e) { resolve({}); } });
    req.on('error', () => resolve({}));
  });
}

module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization,Content-Type');
  if (req.method === 'OPTIONS') return res.status(200).end();

  // Same gate as /api/queue: enforced the moment an OAuth client ID is configured.
  let who = { email: '', name: '' };
  if (process.env.GOOGLE_CLIENT_ID) {
    const r = await requireUser(req);
    if (!r.ok) return deny(res, r);
    who = r.user;
  }

  if (!WRITE_SHEET_ID) {
    return res.status(501).json({
      error: 'no_write_sheet',
      message: 'No log spreadsheet configured. Create a spreadsheet for Lead Review, share it with '
             + (process.env.GOOGLE_SA_EMAIL || 'the service account') + ' as an Editor, and set RCA_SHEET_ID '
             + 'to its id. The shared LRM\u2192TL mapping sheet is deliberately never written to.',
    });
  }

  try {
    if (req.method === 'GET') {
      const days = Math.min(120, Math.max(1, parseInt((req.query && req.query.days) || '45', 10) || 45));
      const cut = new Date(Date.now() - days * 86400000).toISOString().slice(0, 10);
      const all = toObjects(await readWriteSheet(RCA_TAB).catch(() => []));
      // keep only the newest submission per lead per audit date
      const latest = new Map();
      all.forEach(r => {
        const d = String(r.audit_date || '').slice(0, 10);
        if (d && d < cut) return;
        const k = d + '|' + r.lead_id;
        const prev = latest.get(k);
        if (!prev || String(r.logged_at || '') >= String(prev.logged_at || '')) latest.set(k, r);
      });
      res.setHeader('Cache-Control', 'no-store');
      return res.status(200).json({ rows: Array.from(latest.values()), tab: RCA_TAB });
    }

    if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed' });

    const b = await readBody(req);
    const items = Array.isArray(b.items) ? b.items : [b];
    const valid = items.filter(i => i && i.lead_id && i.reason);
    if (!valid.length) return res.status(400).json({ error: 'lead_id_and_reason_required' });

    await ensureTab(RCA_TAB, HEADER);

    const now = new Date().toISOString();
    const rows = valid.map(i => [
      now, clean(i.audit_date), clean(i.lead_id), clean(i.customer_name), clean(i.category),
      clean(i.lrm_email), clean(i.lrm_name), clean(i.tl_email), clean(i.tl_name),
      clean(who.email || i.auditor_email), clean(who.name || i.auditor_name),
      clean(i.reason), clean(i.severity), clean(i.action), clean(i.note),
      clean(i.why_path), clean(i.assignee),
      clean(i.what), clean(i.why), clean(i.owner), clean(i.fault), clean(i.action_status || 'open'),
    ]);
    const n = await appendRows(RCA_TAB, rows);
    return res.status(200).json({ ok: true, logged: n });
  } catch (err) {
    const msg = String((err && err.message) || err);
    if (msg === 'no_write_sheet') {
      return res.status(501).json({ error: 'no_write_sheet', message: 'RCA_SHEET_ID is not set.' });
    }
    // the most common misconfiguration by far: the service account only has view access
    const scope = /insufficient|scope|permission|forbidden/i.test(msg);
    return res.status(500).json({
      error: scope ? 'sheet_not_writable' : 'server_error',
      message: scope
        ? 'The service account cannot write to the log spreadsheet. Share it with ' +
          (process.env.GOOGLE_SA_EMAIL || 'the service account') + ' as an Editor, then retry.'
        : msg,
    });
  }
};

module.exports.config = { maxDuration: 30 };
