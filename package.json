// api/queue.js  ->  GET /api/queue
//
// Two feeds, joined in the browser on rep_email:
//   1. "Audit_Queue"  — the daily Metabase export (audit_queue_daily.sql output),
//                        one row per sampled lead. Headers must match the SQL columns.
//   2. "LRM_TL_MAP"   — the dynamic LRM -> TL / ZSM / ADOS mapping sheet.
//
// This endpoint reads both tabs and returns { queue, hierarchy, auditDate }.
// The front-end (public/index.html) does the merge + priority ranking.

const { readSheet, toObjects } = require('./_sheets');

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
  if (req.method === 'OPTIONS') return res.status(200).end();

  try {
    const [qRaw, mRaw] = await Promise.all([
      readSheet(QUEUE_TAB).catch(() => []),
      readSheet(MAP_TAB).catch(() => []),
    ]);

    // ---- queue rows: pass through as-is (headers already match SQL output) ----
    const queue = toObjects(qRaw).map(r => ({
      audit_date:            r.audit_date || '',
      rep_id:                r.rep_id || '',
      rep_name:              r.rep_name || '',
      rep_email:             norm(r.rep_email),
      lead_id:               r.lead_id || '',
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
      attempt_today:         String(r.attempt_today).toLowerCase() === 'true',
      days_overdue:          Number(r.days_overdue) || 0,
    })).filter(r => r.lead_id && r.category);

    // ---- hierarchy: normalise the LRM_TL_MAP columns into a stable shape ----
    const hierarchy = toObjects(mRaw).map(r => ({
      rep_email:  norm(pick(r, ['Email IDs', 'Email ID', 'LRM Email', 'rep_email'])),
      rep_name:   pick(r, ['LRM Name', 'Name', 'rep_name']),
      sseid:      pick(r, ['SSEID', 'SSE ID', 'sseid']),
      cluster:    pick(r, ['Cluster', 'City', 'cluster']),
      tl_email:   norm(pick(r, ['LRM TL Email ID', 'LRM TL', 'TL Email', 'tl_email'])),
      tl_name:    pick(r, ['Reporting Team Lead', 'TL Name', 'tl_name']),
      zsm_email:  norm(pick(r, ['LRM DZSM Email ID', 'DZSM', 'ZSM Email', 'zsm_email'])),
      ados_email: norm(pick(r, ['ADOS', 'ADOS Email', 'ados_email'])),
      hr_status:  pick(r, ['HR Status', 'Status', 'hr_status']) || 'Active',
    })).filter(h => h.rep_email && h.hr_status.toLowerCase() !== 'inactive');

    const auditDate = (queue[0] && queue[0].audit_date) || new Date().toISOString().slice(0, 10);
    res.setHeader('Cache-Control', 's-maxage=300, stale-while-revalidate=600');
    return res.status(200).json({ auditDate, queue, hierarchy });
  } catch (err) {
    console.error('queue API error:', err);
    return res.status(500).json({ error: String(err.message || err) });
  }
};
