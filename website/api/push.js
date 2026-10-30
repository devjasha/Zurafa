// Relays agent notifications from Zurafa on a Mac to the Zurafa iOS app through Apple Push (APNs).
// The Mac app posts {token, sandbox, title, subtitle, body, pane, thread, category}; this holds the key.
// Vercel env: APNS_KEY (contents of the .p8 file), APNS_KEY_ID, APNS_TEAM_ID, optional APNS_TOPIC.
// shortcut: no auth or rate limit; anyone holding a phone's token could push to it. Add a per-Mac secret if abused.
const http2 = require('node:http2');
const crypto = require('node:crypto');

let cached = { token: null, at: 0 };

/** APNs provider token: ES256 JWT, valid an hour, which Apple asks to refresh at most every 20 minutes. */
function providerToken(now = Math.floor(Date.now() / 1000)) {
  if (cached.token && now - cached.at < 50 * 60) return cached.token;
  const part = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const signed = `${part({ alg: 'ES256', kid: process.env.APNS_KEY_ID })}.${part({ iss: process.env.APNS_TEAM_ID, iat: now })}`;
  const key = process.env.APNS_KEY.replace(/\\n/g, '\n');
  const sig = crypto.sign('sha256', Buffer.from(signed), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  cached = { token: `${signed}.${sig}`, at: now };
  return cached.token;
}

function deliver(host, device, payload) {
  return new Promise((resolve, reject) => {
    const client = http2.connect(`https://${host}`);
    client.on('error', reject);
    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${device}`,
      authorization: `bearer ${providerToken()}`,
      'apns-topic': process.env.APNS_TOPIC || 'dev.zurafa.mobile',
      'apns-push-type': 'alert',
      'apns-priority': '10',
    });
    let status = 0;
    let body = '';
    req.setEncoding('utf8');
    req.on('response', (headers) => { status = headers[':status']; });
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => { client.close(); resolve({ status, body }); });
    req.on('error', reject);
    req.end(JSON.stringify(payload));
  });
}

const text = (v, max) => (typeof v === 'string' && v ? v.slice(0, max) : undefined);

module.exports = async (req, res) => {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });
  const b = req.body || {};
  if (typeof b.token !== 'string' || !/^[0-9a-f]{32,200}$/i.test(b.token)) return res.status(400).json({ error: 'invalid token' });
  const payload = {
    aps: {
      alert: { title: text(b.title, 200), subtitle: text(b.subtitle, 200), body: text(b.body, 1000) },
      sound: 'default',
      category: b.category === 'permission' ? 'permission' : undefined,
      'thread-id': text(b.thread, 100),
    },
    pane: text(b.pane, 100),
  };
  try {
    const r = await deliver(b.sandbox ? 'api.sandbox.push.apple.com' : 'api.push.apple.com', b.token, payload);
    // 410 tells the Mac to forget a token whose app was removed.
    res.status(r.status || 502).send(r.body || '');
  } catch (e) {
    res.status(502).json({ error: String((e && e.message) || e) });
  }
};

module.exports.providerToken = providerToken;
