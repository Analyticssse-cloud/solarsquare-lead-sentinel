// api/_blob-token.js
//
// Finds the Vercel Blob read/write token however Vercel decided to name it.
//
// When a Blob store is connected to a project Vercel injects BLOB_READ_WRITE_TOKEN
// — but only for a store attached with the default env prefix. Attach a second store,
// or set a custom prefix, and the variable arrives as <PREFIX>_READ_WRITE_TOKEN
// (e.g. LEAD_REVIEW_RECORDINGS_READ_WRITE_TOKEN). The debug probe then reports
// "token missing" while the store is in fact perfectly connected.
//
// Every real blob token is a `vercel_blob_rw_...` string, so we match on the VALUE
// as well as the name and never depend on the exact key.

function findBlobToken() {
  const env = process.env || {};
  if (env.BLOB_READ_WRITE_TOKEN) {
    return { token: env.BLOB_READ_WRITE_TOKEN, key: 'BLOB_READ_WRITE_TOKEN' };
  }
  const keys = Object.keys(env);
  // 1. any *_READ_WRITE_TOKEN holding a blob token
  for (const k of keys) {
    if (/_READ_WRITE_TOKEN$/.test(k) && /^vercel_blob_rw_/.test(String(env[k] || ''))) {
      return { token: env[k], key: k };
    }
  }
  // 2. last resort — any variable at all whose value is a blob token
  for (const k of keys) {
    if (/^vercel_blob_rw_/.test(String(env[k] || ''))) return { token: env[k], key: k };
  }
  return { token: null, key: null };
}

// Names of every *_READ_WRITE_TOKEN-ish variable present, for diagnostics.
function blobTokenCandidates() {
  return Object.keys(process.env || {}).filter(k => /READ_WRITE_TOKEN|BLOB/i.test(k));
}

module.exports = { findBlobToken, blobTokenCandidates };
