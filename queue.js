const { google } = require('googleapis');

const SHEET_ID = process.env.SHEET_ID;

function getAuth() {
  let privateKey = process.env.GOOGLE_SA_KEY || '';
  if (privateKey.includes('\\n')) privateKey = privateKey.replace(/\\n/g, '\n');
  privateKey = privateKey.replace(/^["']|["']$/g, '');
  return new google.auth.JWT({
    email:  process.env.GOOGLE_SA_EMAIL,
    key:    privateKey,
    scopes: ['https://www.googleapis.com/auth/spreadsheets.readonly'],
  });
}

async function readSheet(range) {
  const auth   = getAuth();
  const sheets = google.sheets({ version: 'v4', auth });
  const res    = await sheets.spreadsheets.values.get({ spreadsheetId: SHEET_ID, range });
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

module.exports = { readSheet, toObjects };
