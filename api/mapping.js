// api/mapping.js  ->  GET  /api/mapping   read the reporting-line overrides
//                     POST /api/mapping   upsert / clear one or many LRM mappings
//
// EmployeeMaster is the org's shared sheet and is READ ONLY from this app — other teams
// depend on it and it is not ours to edit. But the queue is only useful for LRMs the
// mapping knows, and ~169 LRMs currently have no TL, so their leads are dropped before
// anyone can review them.
//
// This route owns a `Mapping_Overrides` tab on the app's own spreadsheet (RCA_SHEET_ID).
// Each row patches one LRM's reporting line on top of EmployeeMaster:
//
//     lrm_email  →  tl_email / tl_name / zsm_email / ados_email / cluster / hr_status
//
// Blank fields inherit from EmployeeMaster; filled fields win. An LRM who is not in
// EmployeeMaster at all can be added here outright — that is how an admin rescues the
// unmapped LRMs without waiting on an HR sheet update.
//
// Only ADMIN_EMAILS may write. Signed-in users may read (queue.js needs it to build the
// hierarchy, and it holds no secrets).

const { readWriteSheet, ensureTab, WRITE_SHEET_ID } = require('./_sheets');
const { requireUser, deny, parseList } = require('./_auth');
const { google } = require('googleapis');

const TAB = process.env.MAPPING_TAB || 'Mapping_Overrides';
const FIELDS = ['lrm_name', 'tl_email', 'tl_name', 'zsm_email', 'zsm_name',
                'ados_email', 'ados_name', 'cluster', 'hr_status'];
const HEADER = ['lrm_email'].concat(FIELDS, ['updated_by', 'updated_at']);
const EMAIL_FIELDS = ['tl_email', 'zsm_email', 'ados_email'];

const norm  = e => String(e || '').trim().toLowerCase().replace('@homes.solarsquare.in', '@solarsquare.in');
const clean = v => String(v == null ? '' : v).replace(/[\r\n\t]+/g, ' ').trim().slice(0, 200);

function readBody(req) {
  if (req.body && typeof req.body === 'object') return Promise.resolve(req.body);
  return new Promise(resolve => {
    let s = '';
    req.on('data', c => { s += c; if (s.length > 512 * 1024) req.destroy(); });
    req.on('end', () => { try { resolve(JSON.parse(s || '{}')); } catch (e) { resolve({}); } });
    req.on('error', () => resolve({}));
  });
}

/** {lrm_email: {tl_email, tl_name, …}} — later rows win, blanks are simply absent. */
async function readMappingOverrides() {
  const rows = await readWriteSheet(TAB).catch(() => []);
  if (!rows.length) return {};
  const hdr = rows[0].map(h => String(h).trim());
  const out = {};
  rows.slice(1).forEach(r => {
    const o = {};
    hdr.forEach((h, i) => { o[h] = r[i] !== undefined ? String(r[i]) : ''; });
    const em = norm(o.lrm_email);
    if (!em) return;
    const rec = out[em] || (out[em] = {});
    FIELDS.forEach(f => {
      const v = EMAIL_FIELDS.indexOf(f) >= 0 ? norm(o[f]) : clean(o[f]);
      if (v) rec[f] = v;
    });
    rec.updated_by = o.updated_by || '';
    rec.updated_at = o.updated_at || '';
  });
  return out;
}

async function writeAll(map) {
  let k = process.env.GOOGLE_SA_KEY || '';
  if (k.includes('\\n')) k = k.replace(/\\n/g, '\n');
  k = k.replace(/^["']|["']$/g, '');
  const auth = new google.auth.JWT({ email: process.env.GOOGLE_SA_EMAIL, key: k,
    scopes: ['https://www.googleapis.com/auth/spreadsheets'] });
  const sheets = google.sheets({ version: 'v4', auth });
  const body = Object.keys(map).sort().map(em => {
    const o = map[em];
    return [em].concat(FIELDS.map(f => o[f] || ''), [o.updated_by || '', o.updated_at || '']);
  });
  await sheets.spreadsheets.values.clear({ spreadsheetId: WRITE_SHEET_ID, range: TAB + '!A2:Z20000' });
  if (body.length) {
    await sheets.spreadsheets.values.update({
      spreadsheetId: WRITE_SHEET_ID, range: TAB + '!A2',
      valueInputOption: 'RAW', requestBody: { values: body },
    });
  }
  return body.length;
}

/** Apply overrides on top of the EmployeeMaster hierarchy. Pure — used by queue.js too. */
function applyOverrides(hierarchy, overrides) {
  const by = {};
  hierarchy.forEach(h => { by[h.lrm_email] = Object.assign({}, h); });
  Object.keys(overrides || {}).forEach(em => {
    const o = overrides[em];
    const base = by[em] || { lrm_email: em, lrm_name: '', cluster: '', tl_email: '', tl_name: '',
                             zsm_email: '', zsm_name: '', ados_email: '', ados_name: '',
                             hr_status: 'Active', added_in_app: true };
    FIELDS.forEach(f => { if (o[f]) base[f] = o[f]; });
    base.overridden = true;
    by[em] = base;
  });
  return Object.values(by).filter(h => h.lrm_email && String(h.hr_status || 'Active').toLowerCase() !== 'inactive');
}

module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization,Content-Type');
  res.setHeader('Cache-Control', 'no-store');
  if (req.method === 'OPTIONS') return res.status(200).end();

  let who = { email: '', name: '' };
  if (process.env.GOOGLE_CLIENT_ID) {
    const r = await requireUser(req);
    if (!r.ok) return deny(res, r);
    who = r.user;
  }

  if (!WRITE_SHEET_ID) {
    return res.status(501).json({ error: 'no_write_sheet',
      message: 'RCA_SHEET_ID is not set, so mapping changes cannot be saved.' });
  }

  try {
    if (req.method === 'GET') {
      return res.status(200).json({ mapping: await readMappingOverrides(), tab: TAB });
    }
    if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed' });

    const admins = parseList(process.env.ADMIN_EMAILS);
    if (process.env.GOOGLE_CLIENT_ID && admins.length && admins.indexOf(norm(who.email)) < 0) {
      return res.status(403).json({ error: 'admin_only', message: 'Only an admin can change reporting lines.' });
    }

    const b = await readBody(req);
    const items = Array.isArray(b.items) ? b.items : [b];
    if (!items.length) return res.status(400).json({ error: 'nothing_to_save' });

    await ensureTab(TAB, HEADER);
    const map = await readMappingOverrides();
    const at = new Date().toISOString(), by = norm(who.email);
    let touched = 0;

    for (const it of items) {
      const em = norm(it.lrm_email);
      if (!em || em.indexOf('@') < 0) continue;
      if (it.clear) { delete map[em]; touched++; continue; }
      const rec = map[em] || {};
      FIELDS.forEach(f => {
        if (!(f in it)) return;                                  // absent = leave as-is
        const v = EMAIL_FIELDS.indexOf(f) >= 0 ? norm(it[f]) : clean(it[f]);
        if (v) rec[f] = v; else delete rec[f];                   // '' = clear, inherit again
      });
      if (!Object.keys(rec).filter(k => FIELDS.indexOf(k) >= 0).length) delete map[em];
      else { rec.updated_by = by; rec.updated_at = at; map[em] = rec; }
      touched++;
    }
    if (!touched) return res.status(400).json({ error: 'no_valid_rows' });

    const n = await writeAll(map);
    return res.status(200).json({ ok: true, saved: touched, count: n, mapping: map });
  } catch (err) {
    const msg = String((err && err.message) || err);
    const scope = /insufficient|scope|permission|forbidden/i.test(msg);
    return res.status(500).json({
      error: scope ? 'sheet_not_writable' : 'server_error',
      message: scope
        ? 'The service account cannot write to the log spreadsheet. Share it with ' +
          (process.env.GOOGLE_SA_EMAIL || 'the service account') + ' as an Editor.'
        : msg,
    });
  }
};

module.exports.readMappingOverrides = readMappingOverrides;
module.exports.applyOverrides = applyOverrides;
module.exports.config = { maxDuration: 30 };
