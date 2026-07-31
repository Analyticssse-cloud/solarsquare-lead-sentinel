const { google } = require('googleapis');

const SHEET_ID = process.env.SHEET_ID;
// Writes go to their OWN spreadsheet. The sheet the org shared for LRM→TL mapping is
// read-only reference data — the app must never append to it. Set RCA_SHEET_ID to a
// spreadsheet created for Lead Sentinel; if it is unset, writes are refused outright
// rather than silently landing in the mapping file.
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

// Create the tab if it doesn't exist yet, and write the header row. Idempotent.
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
    spreadsheetId: WRITE_SHEET_ID, range: title + '!A1:Z1',
  }).catch(() => ({ data: {} }));
  const have = (first.data && first.data.values && first.data.values[0]) || [];
  if (!have.length) {
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

module.exports = { readSheet, toObjects, ensureTab, appendRows, readWriteSheet, WRITE_SHEET_ID };
