// api/debug.js  ->  GET /api/debug
// Reports why the mapping / queue reads return nothing. No secret values leaked —
// only presence flags, counts, and error messages.

const { readSheet } = require('./_sheets');

const MAP_TAB   = process.env.MAP_TAB   || 'LRM_TL_MAP';
const QUEUE_TAB = process.env.QUEUE_TAB || 'Audit_Queue';

module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');

  const out = {
    env: {
      SHEET_ID:          !!process.env.SHEET_ID,
      GOOGLE_SA_EMAIL:   process.env.GOOGLE_SA_EMAIL || null,
      GOOGLE_SA_KEY:     !!process.env.GOOGLE_SA_KEY,
      METABASE_URL:      process.env.METABASE_URL || null,
      METABASE_USER:     !!process.env.METABASE_USER,
      METABASE_PASS:     !!process.env.METABASE_PASS,
      METABASE_CARD:     process.env.METABASE_CARD || '4447 (default)',
    },
    tabs: { MAP_TAB, QUEUE_TAB },
    reads: {},
  };

  for (const tab of [MAP_TAB, QUEUE_TAB]) {
    try {
      const rows = await readSheet(tab);
      out.reads[tab] = {
        ok: true,
        rowCount: rows.length,
        header: rows[0] || null,
        firstDataRow: rows[1] || null,
      };
    } catch (e) {
      out.reads[tab] = { ok: false, error: String(e.message || e) };
    }
  }

  try {
    const base = (process.env.METABASE_URL || '').replace(/\/+$/, '');
    if (base && process.env.METABASE_USER) {
      const r = await fetch(`${base}/api/session`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: process.env.METABASE_USER, password: process.env.METABASE_PASS }),
      });
      out.metabase = { loginStatus: r.status, ok: r.ok };
    } else {
      out.metabase = { skipped: 'METABASE_URL / METABASE_USER not set' };
    }
  } catch (e) {
    out.metabase = { ok: false, error: String(e.message || e) };
  }

  res.status(200).json(out);
};
