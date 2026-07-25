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
    // ---- audit rows: Metabase Q4447 first, Sheets tab as fallback ----
    let queueRaw = [];
    let source = 'metabase';
    try {
      queueRaw = await fetchCardJson();               // already array of objects
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
      ados_email: norm(pick(r, ['ADOS', 'ADOS Email', 'ados_email'])),
      hr_status:  pick(r, ['HR Status', 'Status', 'hr_status']) || 'Active',
    })).filter(h => h.rep_email && h.hr_status.toLowerCase() !== 'inactive');

    const auditDate = (queue[0] && queue[0].audit_date) || new Date().toISOString().slice(0, 10);
    res.setHeader('Cache-Control', 's-maxage=300, stale-while-revalidate=600');
    return res.status(200).json({ auditDate, source, queue, hierarchy });
  } catch (err) {
    console.error('queue API error:', err);
    return res.status(500).json({ error: String(err.message || err) });
  }
};
