// api/_auth.js — shared sign-in enforcement for the Vercel functions.
// Files prefixed with "_" are NOT deployed as endpoints; they're imported by the others.
//
// The browser sends the signed-in user's Google ID token as "Authorization: Bearer <token>".
// requireUser() verifies it with Google, then applies two env-var gates:
//   ALLOWED_DOMAIN  — only accept accounts on this Workspace domain (e.g. solarsquare.in).
//   ALLOWED_EMAILS  — optional allowlist (comma/space/newline separated). Blank = whole domain.
// This is the REAL gate; the login screen is only UX.

function parseList(v) {
  return String(v || '').split(/[,\s]+/).map(s => s.trim().toLowerCase()).filter(Boolean);
}

function bearer(req) {
  const h = (req && req.headers) || {};
  const raw = h.authorization || h.Authorization || '';
  const m = /^Bearer\s+(.+)$/i.exec(String(raw).trim());
  return m ? m[1] : '';
}

async function requireUser(req) {
  const token = bearer(req);
  if (!token) return { ok: false, status: 401, reason: 'not-signed-in' };

  let p;
  try {
    const r = await fetch('https://oauth2.googleapis.com/tokeninfo?id_token=' + encodeURIComponent(token));
    if (!r.ok) return { ok: false, status: 401, reason: 'invalid-token' };
    p = await r.json();
  } catch (e) {
    return { ok: false, status: 401, reason: 'verify-failed' };
  }

  const aud = process.env.GOOGLE_CLIENT_ID || process.env.VITE_GOOGLE_CLIENT_ID;
  if (aud && p.aud && p.aud !== aud) return { ok: false, status: 401, reason: 'wrong-audience' };
  if (p.email_verified === false || p.email_verified === 'false') return { ok: false, status: 401, reason: 'email-unverified' };

  const email = String(p.email || '').toLowerCase();
  if (!email) return { ok: false, status: 401, reason: 'no-email' };

  const domain = (process.env.ALLOWED_DOMAIN || '').toLowerCase();
  if (domain && p.hd !== domain && !email.endsWith('@' + domain)) {
    return { ok: false, status: 403, reason: 'wrong-domain' };
  }

  const allow = parseList(process.env.ALLOWED_EMAILS);
  if (allow.length && allow.indexOf(email) < 0) {
    return { ok: false, status: 403, reason: 'not-authorized' };
  }

  return { ok: true, status: 200, user: { email, name: p.name || '', picture: p.picture || '' } };
}

function deny(res, r) {
  return res.status(r.status || 401).json({ error: r.reason || 'unauthorized', authError: true });
}

module.exports = { requireUser, deny, parseList };
