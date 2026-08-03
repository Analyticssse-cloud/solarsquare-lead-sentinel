const { google } = require('googleapis');

// THREE spreadsheet roles, deliberately separate:
//   SHEET_ID        the org's shared mapping sheet (EmployeeMaster). READ ONLY, always.
//   QUEUE_SHEET_ID  where the daily audit queue lands. Defaults to SHEET_ID for backwards
//                   compatibility, but should be the app's own file so the Apps Script job
//                   never has to write into a sheet other teams depend on.
//   RCA_SHEET_ID    where the app writes completed RCAs. Never falls back to anything.
const SHEET_ID       = process.env.SHEET_ID;
const QUEUE_SHEET_ID = process.env.QUEUE_SHEET_ID || process.env.SHEET_ID;
const WRITE_SHEET_ID = process.env.RCA_SHEET_ID || '';

function getAuth(readonly) {
  let privateKey = process.env.GOOGLE_SA_KEY || '';
  if (privateKey.includes('\\n')) privateKey = privateKey.replace(/\\n/g, '\n');
  privateKey = privateKey.replace(/^["']|["']$/g, '');
  return new google.auth.JWT({
    email:  process.env.GOOGLE_SA_EMAIL,
    key:    privateKey,
    // The RCA log needs write access. Reads still ask for the narrower scope.
    scopes: [readonly
      ? 'https://www.googleapis.com/auth/spreadsheets.readonly'
      : 'https://www.googleapis.com/auth/spreadsheets'],
  });
}

async function readSheet(range) {
  const auth   = getAuth(true);
  const sheets = google.sheets({ version: 'v4', auth });
  const res    = await sheets.spreadsheets.values.get({ spreadsheetId: SHEET_ID, range });
  return res.data.values || [];
}

// Read the queue tab, wherever it lives. Falls back to the mapping spreadsheet when
// QUEUE_SHEET_ID is unset, so an existing deploy keeps working unchanged.
async function readQueueSheet(range) {
  const auth   = getAuth(true);
  const sheets = google.sheets({ version: 'v4', auth });
  const res    = await sheets.spreadsheets.values.get({ spreadsheetId: QUEUE_SHEET_ID, range });
  return res.data.values || [];
}

// Create the tab if it doesn't exist yet, and keep its header row in step with the code.
// This second part matters: the header used to be written ONCE, at creation. Columns were
// added to the code's header afterwards, so appended rows carried more fields than the
// stored header row named — and every read came back shifted (a root cause reading as the
// TL's name). Rows are always appended in the code's header order, so the fix is to make
// row 1 say so. Idempotent.
async function ensureTab(title, header) {
  if (!WRITE_SHEET_ID) throw new Error('no_write_sheet');
  const auth   = getAuth(false);
  const sheets = google.sheets({ version: 'v4', auth });
  const meta   = await sheets.spreadsheets.get({ spreadsheetId: WRITE_SHEET_ID, fields: 'sheets.properties.title' });
  const exists = (meta.data.sheets || []).some(s => s.properties && s.properties.title === title);
  if (!exists) {
    await sheets.spreadsheets.batchUpdate({
      spreadsheetId: WRITE_SHEET_ID,
      requestBody: { requests: [{ addSheet: { properties: { title } } }] },
    });
  }
  const first = await sheets.spreadsheets.values.get({
    spreadsheetId: WRITE_SHEET_ID, range: title + '!A1:BZ1',
  }).catch(() => ({ data: {} }));
  const have = (first.data && first.data.values && first.data.values[0]) || [];
  const same = have.length === header.length
            && have.every((h, i) => String(h).trim() === header[i]);
  if (!same) {
    await sheets.spreadsheets.values.update({
      spreadsheetId: WRITE_SHEET_ID, range: title + '!A1',
      valueInputOption: 'RAW', requestBody: { values: [header] },
    });
  }
  return true;
}

// Append rows (arrays of cells) to a tab in the WRITE spreadsheet.
async function appendRows(title, rows) {
  if (!WRITE_SHEET_ID) throw new Error('no_write_sheet');
  const auth   = getAuth(false);
  const sheets = google.sheets({ version: 'v4', auth });
  await sheets.spreadsheets.values.append({
    spreadsheetId: WRITE_SHEET_ID,
    range: title + '!A1',
    valueInputOption: 'RAW',
    insertDataOption: 'INSERT_ROWS',
    requestBody: { values: rows },
  });
  return rows.length;
}

// Read back from the WRITE spreadsheet (the RCA log lives there, not in the mapping sheet).
async function readWriteSheet(range) {
  if (!WRITE_SHEET_ID) return [];
  const auth   = getAuth(true);
  const sheets = google.sheets({ version: 'v4', auth });
  const res    = await sheets.spreadsheets.values.get({ spreadsheetId: WRITE_SHEET_ID, range });
  return res.data.values || [];
}

// Turn a sheet [headerRow, ...dataRows] into array of {header: cell} objects.
function toObjects(rows) {
  if (!rows || !rows.length) return [];
  const hdr = rows[0].map(h => String(h).trim());
  return rows.slice(1).filter(r => r && r.length).map(r => {
    const o = {};
    hdr.forEach((h, i) => { o[h] = r[i] !== undefined ? r[i] : ''; });
    return o;
  });
}

module.exports = { readSheet, readQueueSheet, toObjects, ensureTab, appendRows, readWriteSheet,
                   WRITE_SHEET_ID, QUEUE_SHEET_ID, SHEET_ID };
