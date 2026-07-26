// api/config.js  →  GET /api/config
// Serves the PUBLIC front-end auth config, read from environment variables at RUNTIME.
// Only non-secret values are returned (the OAuth client ID is public by design).

const { parseList } = require('./_auth');

module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  const clientId = process.env.GOOGLE_CLIENT_ID || process.env.VITE_GOOGLE_CLIENT_ID || '';
  const allowedDomain = (process.env.ALLOWED_DOMAIN || process.env.VITE_ALLOWED_DOMAIN || '').toLowerCase();
  const restricted = parseList(process.env.ALLOWED_EMAILS).length > 0;
  // Admins see every TL (oversight). Employees, not secrets — safe to expose.
  const admins = parseList(process.env.ADMIN_EMAILS);
  return res.status(200).json({
    enabled: !!clientId,   // gate is ON whenever a client ID is configured
    clientId,
    allowedDomain,
    restricted,
    admins,
  });
};
