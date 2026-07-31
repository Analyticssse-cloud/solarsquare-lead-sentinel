// api/transcribe.js  ->  POST /api/transcribe?lead=<lead_id>&name=<filename>[&lang=hi]
//
// Transcribes a call recording with OpenAI. Two ways to send the audio:
//
//   1. raw audio body   (Content-Type: audio/*)  — the browser streams the file it holds
//   2. JSON body        {"url": "<blob url>"}    — the server fetches an already-uploaded file
//
// Returns { text, language, duration, model }.
//
// ENV
//   OPENAI_API_KEY          required unless TRANSCRIBE_URL is set
//   TRANSCRIBE_URL          optional — any OpenAI-compatible /audio/transcriptions endpoint
//                           (faster-whisper-server, whisper.cpp server, your own box).
//                           Set it and transcription costs nothing and stays in-house.
//   TRANSCRIBE_MODEL        optional — default 'gpt-4o-transcribe'
//                           ('whisper-1' also works and returns segment timestamps)
//
// NOTE: the app's DEFAULT engine is not this route at all — it is on-device Whisper
// running in the browser (see public/whisper-worker.js), which is free and needs no server.
// This route exists so a hosted or self-hosted backend can be swapped in without UI changes.
//
// NOTES
//   · OpenAI caps uploads at 25 MB. Longer calls must be compressed (mono 16 kHz mp3
//     fits ~3 hours) or split — we reject with a clear message rather than truncating.
//   · Hindi / code-switched calls: gpt-4o-transcribe is materially better than whisper-1.
//     Leave `lang` unset for auto-detect; pass ?lang=hi to pin it.

const MAX_BYTES = 25 * 1024 * 1024;
const DEFAULT_MODEL = 'gpt-4o-transcribe';

// a short domain prompt measurably reduces mangled solar/sales vocabulary
const HINT = 'SolarSquare rooftop solar sales call. Terms: kilowatt, kW, subsidy, PM Surya Ghar, '
  + 'net metering, inverter, panel, EMI, site visit, DEV, LRM, meeting, follow-up, quotation, '
  + 'discom, sanction load, terrace, shadow-free area.';

const safe = s => String(s || '').replace(/[^a-zA-Z0-9._-]/g, '_').slice(0, 120);

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let n = 0;
    req.on('data', c => {
      n += c.length;
      if (n > MAX_BYTES + 1024) { reject(new Error('too_large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization,Content-Type');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed' });

  const key = process.env.OPENAI_API_KEY;
  // TRANSCRIBE_URL points at any OpenAI-compatible /audio/transcriptions endpoint —
  // faster-whisper-server, whisper.cpp server, vLLM, or a box you run yourself.
  // Set it and no OpenAI key is needed; the front-end and UI are unchanged.
  const url = process.env.TRANSCRIBE_URL || 'https://api.openai.com/v1/audio/transcriptions';
  const selfHosted = !!process.env.TRANSCRIBE_URL;
  if (!key && !selfHosted) {
    return res.status(501).json({
      error: 'no_backend',
      message: 'No server transcription backend configured. Use the on-device engine (free, no setup), '
             + 'or set OPENAI_API_KEY, or point TRANSCRIBE_URL at a self-hosted Whisper server.',
    });
  }

  const model = process.env.TRANSCRIBE_MODEL || DEFAULT_MODEL;
  const lang = String((req.query && req.query.lang) || '').trim();
  let name = safe((req.query && req.query.name) || 'recording.mp3');

  try {
    const ctype = String(req.headers['content-type'] || '').split(';')[0];
    let buf, mime;

    if (ctype === 'application/json') {
      const raw = await readBody(req);
      let j = {};
      try { j = JSON.parse(raw.toString('utf8') || '{}'); } catch (e) { /* fall through */ }
      if (!j.url) return res.status(400).json({ error: 'url_required' });
      const g = await fetch(j.url);
      if (!g.ok) return res.status(502).json({ error: 'fetch_failed', status: g.status });
      buf = Buffer.from(await g.arrayBuffer());
      mime = g.headers.get('content-type') || 'application/octet-stream';
      if (j.name) name = safe(j.name);
    } else {
      buf = await readBody(req);
      mime = ctype || 'application/octet-stream';
    }

    if (!buf || !buf.length) return res.status(400).json({ error: 'empty_body' });
    if (!selfHosted && buf.length > MAX_BYTES) {
      return res.status(413).json({
        error: 'too_large',
        message: 'Recording is ' + (buf.length / 1048576).toFixed(1) + ' MB. OpenAI accepts up to 25 MB — '
               + 'export the call as mono 16 kHz mp3, or split it, and try again.',
      });
    }
    // make sure the filename carries an extension OpenAI recognises
    if (!/\.[a-z0-9]{2,5}$/i.test(name)) {
      const ext = (mime.split('/')[1] || 'mp3').replace(/[^a-z0-9]/gi, '') || 'mp3';
      name = name + '.' + ext;
    }

    const fd = new FormData();
    fd.append('file', new Blob([buf], { type: mime }), name);
    fd.append('model', model);
    fd.append('prompt', HINT);
    if (lang) fd.append('language', lang);
    // whisper-1 is the only model that returns segments; ask for them when it's in use
    fd.append('response_format', model === 'whisper-1' ? 'verbose_json' : 'json');

    const r = await fetch(url, {
      method: 'POST',
      headers: key ? { authorization: 'Bearer ' + key } : {},
      body: fd,
    });

    const j = await r.json().catch(() => ({}));
    if (!r.ok) {
      return res.status(r.status).json({
        error: 'backend_error',
        message: (j && j.error && (j.error.message || j.error)) || ((selfHosted ? 'Whisper server' : 'OpenAI') + ' returned ' + r.status),
      });
    }

    return res.status(200).json({
      text: j.text || '',
      language: j.language || lang || '',
      duration: j.duration || null,
      segments: Array.isArray(j.segments)
        ? j.segments.map(s => ({ start: s.start, end: s.end, text: s.text }))
        : null,
      model,
      backend: selfHosted ? 'self-hosted' : 'openai',
    });
  } catch (err) {
    if (String(err.message) === 'too_large') {
      return res.status(413).json({ error: 'too_large', message: 'Recording exceeds the 25 MB transcription limit.' });
    }
    return res.status(500).json({ error: 'server_error', message: String(err.message || err) });
  }
};

module.exports.config = { api: { bodyParser: false }, maxDuration: 300 };
