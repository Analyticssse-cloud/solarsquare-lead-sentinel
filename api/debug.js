// api/debug.js  ->  GET /api/debug
// Answers one question: if the app shows nothing, WHERE did the rows go?
//
// Three places a lead can vanish, and this reports each separately:
//   1. the source      — Metabase card / Audit_Queue tab returned no rows at all
//   2. the shape       — rows came back but lack lead_id or category, so they're dropped
//   3. the join        — rows exist, but their lrm_email matches nothing in LRM_TL_MAP,
//                        so no TL owns them and every scoped view is empty
//
// No secret values are leaked — presence flags, counts, and sample emails only.

const { readSheet, readQueueSheet, QUEUE_SHEET_ID, SHEET_ID } = require('./_sheets');
const queue = require('./queue');

const MAP_TAB   = process.env.MAP_TAB   || 'LRM_TL_MAP';
const QUEUE_TAB = process.env.QUEUE_TAB || 'Audit_Queue';

const norm = e => String(e || '').trim().toLowerCase().replace('@homes.solarsquare.in', '@solarsquare.in');

module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Cache-Control', 'no-store');

  const out = {
    env: {
      SHEET_ID:          !!process.env.SHEET_ID,
      QUEUE_SHEET_ID:    !!process.env.QUEUE_SHEET_ID,
      queue_sheet_is_mapping_sheet: !process.env.QUEUE_SHEET_ID,
      RCA_SHEET_ID:      !!process.env.RCA_SHEET_ID,
      GOOGLE_SA_EMAIL:   process.env.GOOGLE_SA_EMAIL || null,   // email is safe to show
      GOOGLE_SA_KEY:     !!process.env.GOOGLE_SA_KEY,
      METABASE_URL:      process.env.METABASE_URL || null,
      METABASE_USER:     !!process.env.METABASE_USER,
      METABASE_PASS:     !!process.env.METABASE_PASS,
      METABASE_CARD:     process.env.METABASE_CARD || '4447 (default)',
      GOOGLE_CLIENT_ID:  !!process.env.GOOGLE_CLIENT_ID,
      ADMIN_EMAILS:      (process.env.ADMIN_EMAILS || '').split(',').filter(Boolean).length,
    },
    tabs: { MAP_TAB, QUEUE_TAB },
    reads: {},
  };

  for (const tab of [MAP_TAB, QUEUE_TAB]) {
    try {
      const rows = tab === QUEUE_TAB ? await readQueueSheet(tab) : await readSheet(tab);
      out.reads[tab] = {
        ok: true,
        spreadsheet: tab === QUEUE_TAB ? (process.env.QUEUE_SHEET_ID ? 'QUEUE_SHEET_ID' : 'SHEET_ID (fallback)') : 'SHEET_ID',
        rowCount: rows.length,
        header: rows[0] || null,
        firstDataRow: rows[1] || null,
      };
    } catch (e) {
      out.reads[tab] = {
        ok: false,
        spreadsheet: tab === QUEUE_TAB ? (process.env.QUEUE_SHEET_ID ? 'QUEUE_SHEET_ID' : 'SHEET_ID (fallback)') : 'SHEET_ID',
        error: String(e.message || e),
        hint: /parse range/i.test(String(e.message || e))
          ? 'The tab does not exist in that spreadsheet. Create it, or set QUEUE_SHEET_ID to the spreadsheet that has it.'
          : undefined,
      };
    }
  }

  // Metabase reachability (login only, no query)
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

  // ---- the actual diagnosis: run the app's own pull and inspect the join ----
  try {
    const full = await queue.getData();
    const q = full.queue || [], H = full.hierarchy || [];

    const qEmails = new Set(q.map(r => norm(r.lrm_email)).filter(Boolean));
    const hEmails = new Set(H.map(h => norm(h.lrm_email)).filter(Boolean));
    const matched = [...qEmails].filter(e => hEmails.has(e));
    const orphanQ = [...qEmails].filter(e => !hEmails.has(e));
    const blankLrm = q.filter(r => !norm(r.lrm_email)).length;
    const byNameRows = q.filter(r => r.lrm_email_source === 'name').length;
    const qNames = [...new Set(q.map(r => String(r.lrm_name || '').trim()).filter(Boolean))];

    const byCat = {};
    q.forEach(r => { byCat[r.category] = (byCat[r.category] || 0) + 1; });

    const tlEmails = new Set(H.map(h => norm(h.tl_email)).filter(Boolean));

    out.pull = {
      source: full.source,
      auditDate: full.auditDate,
      queueRows: q.length,
      hierarchyRows: H.length,
      byCategory: byCat,
      distinctLrmInQueue: qEmails.size,
      distinctLrmInMap: hEmails.size,
      lrmMatchedBoth: matched.length,
      queueRowsWithBlankLrmEmail: blankLrm,
      queueRowsResolvedByName: byNameRows,
      distinctLrmNamesInQueue: qNames.length,
      sampleQueueLrmNames: qNames.slice(0, 8),
      distinctTlInMap: tlEmails.size,
      sampleQueueLrmEmails: [...qEmails].slice(0, 8),
      sampleMapLrmEmails: [...hEmails].slice(0, 8),
      sampleTlEmails: [...tlEmails].slice(0, 8),
      sampleUnmatchedQueueLrmEmails: orphanQ.slice(0, 12),
    };

    // Plain-language verdict, in the order the pipeline can fail.
    let verdict;
    if (!q.length) {
      verdict = out.reads[QUEUE_TAB] && out.reads[QUEUE_TAB].rowCount > 1
        ? 'ROWS EXIST IN THE SHEET BUT NONE SURVIVED PARSING — every row is missing lead_id or category. Check that the Audit_Queue header row matches the v5 column names exactly.'
        : 'NO ROWS AT SOURCE — the Metabase card and the ' + QUEUE_TAB + ' tab both came back empty. Run audit_queue_daily_v5.sql and paste the export in, or check METABASE_CARD.';
    } else if (!H.length) {
      verdict = 'QUEUE HAS ROWS BUT THE MAPPING IS EMPTY — ' + MAP_TAB + ' read no usable rows, so no LRM has a TL and every scoped view is empty. Check the tab name and its header row.';
    } else if (blankLrm && !byNameRows) {
      verdict = 'THE CARD IS NOT EMITTING lrm_email — all ' + blankLrm + ' queue rows have a blank LRM address, and their lrm_name does not match the mapping sheet either, so nothing can be assigned to a TL. Metabase card ' + (process.env.METABASE_CARD || '4447') + ' is running an OLD query: update it to audit_queue_daily_v5.sql, whose users join emits lrm_email. Compare sampleQueueLrmNames with the mapping sheet\'s LRM Name column.';
    } else if (byNameRows) {
      verdict = 'WORKING, BUT ON THE FALLBACK — ' + byNameRows + ' rows had no lrm_email and were matched to a TL by NAME instead. That is fragile (any spelling difference drops the lead). Fix it properly by updating Metabase card ' + (process.env.METABASE_CARD || '4447') + ' to audit_queue_daily_v5.sql.';
    } else if (!matched.length) {
      verdict = 'JOIN FAILURE — ' + q.length + ' queue rows and ' + H.length + ' mapping rows, but NOT ONE lrm_email matches. Compare sampleQueueLrmEmails with sampleMapLrmEmails: usually the query emits a different address form than the mapping sheet.';
    } else {
      verdict = 'HEALTHY — ' + q.length + ' rows across ' + matched.length + ' LRMs, all joined to a TL. If a specific person still sees nothing, their signed-in address is not in the TL / ZSM / ADOS columns; compare it against sampleTlEmails.';
    }
    out.verdict = verdict;
  } catch (e) {
    out.pull = { ok: false, error: String((e && e.message) || e) };
    out.verdict = 'THE PULL ITSELF FAILED — see pull.error. The app would show an API error rather than an empty queue.';
  }

  res.status(200).json(out);
};

module.exports.config = { maxDuration: 60 };
