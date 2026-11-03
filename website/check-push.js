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
const start = handler.activityPayload({ event: 'start', attributes: { mac: 'Mac' }, alert: { title: 'Claude Code needs you' },
  state: { working: 1, blocked: 1, agents: Array(9).fill({ pane: 't1', name: 'Claude Code', glyph: 'claude', symbol: 'sparkle', color: 0xD97757, place: 'W · T', status: 'blocked', message: 'x'.repeat(500), permission: true }) } });
console.assert(start.aps['attributes-type'] === 'ZurafaAgentsAttributes' && start.aps.attributes.mac === 'Mac' && start.aps.alert.title, 'start payload');
console.assert(start.aps['content-state'].agents.length === 6 && start.aps['content-state'].agents[0].message.length === 120, 'agents capped');
const end = handler.activityPayload({ event: 'end', state: {}, dismissal: 1730000000 });
console.assert(end.aps['dismissal-date'] === 1730000000 && !end.aps.attributes && !end.aps.alert, 'end payload');
console.assert(handler.activityPayload({ event: 'nope' }) === null, 'event enum');
console.log('activity payloads checked');
handler({ method: 'POST', body: { kind: 'activity', token: 'ab'.repeat(32), sandbox: true, event: 'update', state: { agents: [], working: 0, blocked: 0 } } }, res);
handler({ method: 'POST', body: { kind: 'activity', token: 'ab'.repeat(32), event: 'bogus' } }, res);
