// api/_auth.js — shared sign-in enforcement for the Vercel functions.
// Files prefixed with "_" are NOT deployed as endpoints; they're imported by the others.
//
// The browser sends the signed-in user's Google ID token as "Authorization: Bearer <token>".
// requireUser() verifies it with Google, then applies two env-var gates:
//   ALLOWED_DOMAIN  — accepted Workspace domain(s). Comma/space separated for more than one;
//                     defaults to "solarsquare.in homes.solarsquare.in" when unset.
//   ALLOWED_EMAILS  — optional allowlist (comma/space/newline separated). Blank = whole domain.
// This is the REAL gate; the login screen is only UX.

// Both SolarSquare Workspace domains are accepted by default; ALLOWED_DOMAIN overrides.
const DEFAULT_DOMAINS = ['solarsquare.in', 'homes.solarsquare.in'];

// Same identity rule the rest of the app uses: @homes.solarsquare.in is the same person
// as @solarsquare.in, so an allowlist entry on either address matches either login.
function normEmail(e) {
  return String(e || '').trim().toLowerCase().replace('@homes.solarsquare.in', '@solarsquare.in');
}

function allowedDomains() {
  const list = parseList(process.env.ALLOWED_DOMAIN).map(d => d.replace(/^@/, ''));
  return list.length ? list : DEFAULT_DOMAINS;
}

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

  const domains = allowedDomains();
  const hd = String(p.hd || '').toLowerCase();
  const onDomain = domains.some(d => hd === d || email.endsWith('@' + d));
  if (domains.length && !onDomain) {
    return { ok: false, status: 403, reason: 'wrong-domain' };
  }

  const allow = parseList(process.env.ALLOWED_EMAILS).map(normEmail);
  if (allow.length && allow.indexOf(normEmail(email)) < 0) {
    return { ok: false, status: 403, reason: 'not-authorized' };
  }

  // emailKey is the cross-domain identity used for mapping/allowlist lookups; email stays raw.
  return { ok: true, status: 200, user: { email, emailKey: normEmail(email), name: p.name || '', picture: p.picture || '' } };
}

function deny(res, r) {
  return res.status(r.status || 401).json({ error: r.reason || 'unauthorized', authError: true });
}

module.exports = { requireUser, deny, parseList, allowedDomains, normEmail, DEFAULT_DOMAINS };
