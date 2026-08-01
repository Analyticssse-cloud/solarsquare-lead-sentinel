// api/access.js  ->  GET  /api/access    read the access overrides
//                    POST /api/access    upsert or clear one person's access
//
// Access has two layers, deliberately:
//
//   1. EmployeeMaster (read-only)  — the org chart. Who reports to whom. Not ours to edit.
//   2. Access_Overrides (this)     — exceptions the tool owns: grant someone the RCA
//                                    auditor role, make someone an admin, give a manager
//                                    ZSM-level visibility, or block an account outright.
//
// Overrides live in an `Access_Overrides` tab on the RCA spreadsheet (RCA_SHEET_ID), so a
// change by one admin is seen by every admin. Before this existed the auditor list was in
// each admin's own browser, which meant it wasn't really a setting at all.
//
// Only ADMIN_EMAILS may write. Everyone signed-in may read (the app needs it to know its
// own role), and it contains no secrets — just email/role pairs.
//
// Roles: 'admin' | 'auditor' | 'tl' | 'zsm' | 'ados' | 'none'
//   'none' blocks an account that the org chart would otherwise let in.
//   Clearing an override (role '') deletes the row and returns the person to org-chart rules.

const { readWriteSheet, ensureTab, appendRows, WRITE_SHEET_ID } = require('./_sheets');
const { requireUser, deny, parseList } = require('./_auth');
const { google } = require('googleapis');

const TAB = process.env.ACCESS_TAB || 'Access_Overrides';
const HEADER = ['email', 'role', 'scope', 'note', 'updated_by', 'updated_at'];
const ROLES = ['admin', 'auditor', 'tl', 'zsm', 'ados', 'none'];

const norm = e => String(e || '').trim().toLowerCase().replace('@homes.solarsquare.in', '@solarsquare.in');
const clean = v => String(v == null ? '' : v).replace(/[\r\n\t]+/g, ' ').slice(0, 300);

function readBody(req) {
  if (req.body && typeof req.body === 'object') return Promise.resolve(req.body);
  return new Promise(resolve => {
    let s = '';
    req.on('data', c => { s += c; if (s.length > 64 * 1024) req.destroy(); });
    req.on('end', () => { try { resolve(JSON.parse(s || '{}')); } catch (e) { resolve({}); } });
    req.on('error', () => resolve({}));
  });
}

// Read every override as {email: {role, scope, note, updated_by, updated_at}}.
// Later rows win, so an upsert can simply append and the newest value takes effect —
// but we also rewrite the tab on write so it never grows unbounded.
async function readOverrides() {
  const rows = await readWriteSheet(TAB).catch(() => []);
  if (!rows.length) return {};
  const hdr = rows[0].map(h => String(h).trim());
  const out = {};
  rows.slice(1).forEach(r => {
    const o = {};
    hdr.forEach((h, i) => { o[h] = r[i] !== undefined ? r[i] : ''; });
    const em = norm(o.email);
    if (em) out[em] = { role: String(o.role || '').toLowerCase(), scope: o.scope || '',
                        note: o.note || '', updated_by: o.updated_by || '', updated_at: o.updated_at || '' };
  });
  return out;
}

async function writeAll(map) {
  const auth = (function () {
    let k = process.env.GOOGLE_SA_KEY || '';
    if (k.includes('\\n')) k = k.replace(/\\n/g, '\n');
    k = k.replace(/^["']|["']$/g, '');
    return new google.auth.JWT({ email: process.env.GOOGLE_SA_EMAIL, key: k,
      scopes: ['https://www.googleapis.com/auth/spreadsheets'] });
  })();
  const sheets = google.sheets({ version: 'v4', auth });
  const body = Object.keys(map).sort().map(em => {
    const o = map[em];
    return [em, o.role, o.scope || '', o.note || '', o.updated_by || '', o.updated_at || ''];
  });
  // clear then write: the tab is small (tens of rows) and this keeps it canonical
  await sheets.spreadsheets.values.clear({ spreadsheetId: WRITE_SHEET_ID, range: TAB + '!A2:Z10000' });
  if (body.length) {
    await sheets.spreadsheets.values.update({
      spreadsheetId: WRITE_SHEET_ID, range: TAB + '!A2',
      valueInputOption: 'RAW', requestBody: { values: body },
    });
  }
  return body.length;
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
    return res.status(501).json({
      error: 'no_write_sheet',
      message: 'RCA_SHEET_ID is not set, so access changes cannot be saved. Set it to the app\'s own spreadsheet and redeploy.',
    });
  }

  try {
    if (req.method === 'GET') {
      return res.status(200).json({ overrides: await readOverrides(), tab: TAB });
    }
    if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed' });

    // writes are admin-only, and the admin list itself lives in env (not editable here,
    // so nobody can lock the real owners out through the UI)
    const admins = parseList(process.env.ADMIN_EMAILS);
    if (process.env.GOOGLE_CLIENT_ID && admins.length && admins.indexOf(norm(who.email)) < 0) {
      return res.status(403).json({ error: 'admin_only', message: 'Only an admin can change access.' });
    }

    const b = await readBody(req);
    const email = norm(b.email);
    const role = String(b.role || '').toLowerCase();
    if (!email || email.indexOf('@') < 0) return res.status(400).json({ error: 'email_required' });
    if (role && ROLES.indexOf(role) < 0) return res.status(400).json({ error: 'bad_role', allowed: ROLES });

    await ensureTab(TAB, HEADER);
    const map = await readOverrides();

    if (!role) delete map[email];                       // clear -> back to org-chart rules
    else map[email] = { role, scope: clean(b.scope), note: clean(b.note),
                        updated_by: norm(who.email), updated_at: new Date().toISOString() };

    const n = await writeAll(map);
    return res.status(200).json({ ok: true, count: n, overrides: map });
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

module.exports.readOverrides = readOverrides;
module.exports.config = { maxDuration: 30 };
