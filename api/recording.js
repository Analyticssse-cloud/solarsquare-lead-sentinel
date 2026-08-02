// api/recording.js  ->  POST /api/recording?lead=<lead_id>&name=<filename>
//
// Accepts a raw audio body of ANY audio type and stores it in Vercel Blob.
// No npm dependency: talks to the Blob REST API with plain fetch.
//
//   Set BLOB_READ_WRITE_TOKEN in Vercel  -> uploads persist and return a public URL.
//   Token missing                        -> 501, and the front-end keeps the recording
//                                           locally in IndexedDB so playback still works.
//
// GET /api/recording?lead=<id> returns { files: [...] } listed from the blob store.

const { findBlobToken } = require('./_blob-token');

const MAX_BYTES = 60 * 1024 * 1024; // 60 MB — well past a 60-min mono call

const OK_EXT = ['mp3','wav','m4a','aac','ogg','oga','opus','flac','wma','amr','3gp','webm','mp4','caf','aiff','aif'];

const safe = s => String(s || '').replace(/[^a-zA-Z0-9._-]/g, '_').slice(0, 120);

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let n = 0;
    req.on('data', c => {
      n += c.length;
      if (n > MAX_BYTES) { reject(new Error('Recording is larger than 60 MB')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization,Content-Type');
  if (req.method === 'OPTIONS') return res.status(200).end();

  const token = findBlobToken().token;
  const lead = safe((req.query && req.query.lead) || '');
  if (!lead) return res.status(400).json({ error: 'lead is required' });

  // ---- GET: listing is never an error -------------------------------------
  // A lead with no recording and a deployment with no blob store used to return the
  // same 501, so the audit card could not tell "nothing attached" from "storage down"
  // — and it fires this lookup for every RCA on screen. GET now always answers 200
  // with a files array; `configured` carries the storage state for diagnostics.
  if (req.method === 'GET') {
    if (!token) return res.status(200).json({ files: [], configured: false });
    try {
      const r = await fetch('https://blob.vercel-storage.com?prefix=' + encodeURIComponent('recordings/' + lead + '/'), {
        headers: { authorization: 'Bearer ' + token, 'x-api-version': '7' },
      });
      if (!r.ok) {
        return res.status(200).json({ files: [], configured: true, storeError: r.status });
      }
      const j = await r.json();
      const files = (j.blobs || []).map(b => ({
        url: b.url, name: String(b.pathname || '').split('/').pop(), size: b.size, at: b.uploadedAt,
      }));
      return res.status(200).json({ files, configured: true });
    } catch (err) {
      return res.status(200).json({ files: [], configured: true, storeError: String(err.message || err) });
    }
  }

  if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed' });

  // ---- POST: an upload genuinely cannot proceed without a store ------------
  if (!token) {
    return res.status(501).json({
      error: 'no_blob_store',
      env: process.env.VERCEL_ENV || 'unknown',
      message: 'Recording storage is not configured for this deployment (' +
               (process.env.VERCEL_ENV || 'unknown') + '). Connect a Vercel Blob store to the ' +
               'project, tick its *_READ_WRITE_TOKEN for this environment, and REDEPLOY — ' +
               'environment variables are only picked up at build time. Until then recordings ' +
               'stay on this device only.',
    });
  }

  try {
    const name = safe((req.query && req.query.name) || 'recording');
    const ext = (name.split('.').pop() || '').toLowerCase();
    const ctype = String(req.headers['content-type'] || 'application/octet-stream').split(';')[0];
    // accept anything the browser calls audio, plus known audio containers that
    // some OSes hand over as octet-stream
    if (!/^audio\//.test(ctype) && !/^video\/(mp4|webm|3gpp)$/.test(ctype) && OK_EXT.indexOf(ext) < 0) {
      return res.status(415).json({ error: 'unsupported_type', ctype, ext });
    }

    const body = await readBody(req);
    if (!body.length) return res.status(400).json({ error: 'empty_body' });

    const path = 'recordings/' + lead + '/' + Date.now() + '-' + name;
    const put = await fetch('https://blob.vercel-storage.com/' + path, {
      method: 'PUT',
      headers: {
        authorization: 'Bearer ' + token,
        'x-api-version': '7',
        'x-content-type': ctype,
        'x-add-random-suffix': '0',
        'content-type': ctype,
      },
      body,
    });
    if (!put.ok) {
      const t = await put.text().catch(() => '');
      return res.status(502).json({ error: 'blob_put_failed', status: put.status, detail: t.slice(0, 300) });
    }
    const j = await put.json();
    return res.status(200).json({ url: j.url, name, size: body.length, contentType: ctype });
  } catch (err) {
    return res.status(500).json({ error: String(err.message || err) });
  }
};

module.exports.config = { api: { bodyParser: false }, maxDuration: 60 };
