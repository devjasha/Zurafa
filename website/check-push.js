// Self-check (node check-push.js):  signs a provider token with a throwaway P-256 key and sends to the real APNs sandbox,
// which must reject the key (403 InvalidProviderToken) — proving JWT format and the HTTP/2 path.
const crypto = require('node:crypto');
const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
process.env.APNS_KEY = privateKey.export({ type: 'pkcs8', format: 'pem' });
process.env.APNS_KEY_ID = 'ABC123DEFG'; process.env.APNS_TEAM_ID = 'K8T3LW283A';
const handler = require("./api/push.js");
const [h, c, s] = handler.providerToken().split('.');
console.assert(JSON.parse(Buffer.from(h, 'base64url')).alg === 'ES256');
console.log('signature verifies:', crypto.verify('sha256', Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(s, 'base64url')));
const res = { code: 0, status(c) { this.code = c; return this; }, send(b) { console.log('relay answered', this.code, b); }, json(b) { console.log('relay answered', this.code, b); } };
handler({ method: 'POST', body: { token: 'ab'.repeat(32), sandbox: true, title: 't', pane: 't1' } }, res);
handler({ method: 'POST', body: { token: 'nope' } }, res);
