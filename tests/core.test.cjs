const { test } = require('node:test');
const assert = require('node:assert/strict');
const core = require('../ios/Sever/Resources/sever-core.js');
const uuid = '11111111-2222-4333-8444-555555555555';
const link = `vless://${uuid}@example.invalid:443?security=reality&pbk=public-key&type=grpc&serviceName=test&sni=example.invalid#Test`;
const config = () => ({
  remarks: 'Образец', env: { 'xray.tun.fd': '0' }, log: { access: '/tmp/secret' },
  outbounds: [{ protocol: 'vless', tag: 'proxy', settings: { vnext: [{ address: 'example.invalid', port: 443, users: [{ id: uuid }] }] } }, { protocol: 'freedom', tag: 'direct' }, { protocol: 'blackhole', tag: 'block' }],
  burstObservatory: { subjectSelector: ['proxy'], pingConfig: { interval: '1m', sampling: 1, timeout: '3s' } },
  routing: { balancers: [{ tag: 'auto', selector: ['proxy'], fallbackTag: 'direct', strategy: { type: 'leastLoad' } }], rules: [{ domain: ['domain:example.org'], outboundTag: 'direct', webhook: { url: 'https://bad.invalid/secret' } }, { network: 'tcp,udp', balancerTag: 'auto' }] }
});
test('imports a full configuration without losing original routing or mutating input', () => {
  const raw = JSON.stringify(config()); const profile = core.importText(raw)[0];
  assert.equal(profile.nodes, 1); assert.deepEqual(JSON.parse(profile.configuration), config());
});
test('preserves REALITY and gRPC share-link settings', () => {
  const p = core.importText(link)[0]; const out = JSON.parse(p.configuration).outbounds[0];
  assert.equal(out.streamSettings.grpcSettings.serviceName, 'test');
  assert.equal(out.settings.vnext[0].users[0].id, uuid);
});
test('imports UTF-8 and URL-safe Base64 subscriptions', () => {
  const encoded = Buffer.from(link.replace('#Test', '#%D0%A1%D0%B5%D0%B2%D0%B5%D1%80')).toString('base64url');
  assert.equal(core.importText(encoded)[0].name, 'Север');
});
test('strict mode eliminates direct routes, replaces fallbacks, strips executable environment and webhooks', () => {
  const raw = JSON.stringify(config()); const strict = JSON.parse(core.strictXray(raw));
  assert.equal(strict.env, undefined); assert.equal(strict.log.loglevel, 'none');
  assert.equal(strict.outbounds.find(o => o.tag === 'direct').protocol, 'blackhole');
  assert.equal(strict.routing.rules.some(r => r.outboundTag === 'direct' || r.webhook), false);
  assert.equal(strict.routing.balancers[0].fallbackTag, 'sever-block');
  assert.equal(strict.routing.balancers[0].strategy.type, 'leastLoad');
  assert.ok(strict.burstObservatory); assert.equal(JSON.parse(raw).routing.balancers[0].fallbackTag, 'direct');
});
test('single-node import gets automatic health monitoring and a blocking fallback', () => {
  const p = core.importText(link)[0]; const cfg = JSON.parse(core.strictXray(p.configuration));
  assert.ok(cfg.observatory); assert.equal(cfg.routing.balancers[0].strategy.type, 'leastPing');
  assert.equal(cfg.routing.rules[0].inboundTag[0], 'sever-dns-query');
});
test('rejects insecure TLS, missing REALITY key, duplicate tags and unsupported geodata', () => {
  assert.throws(() => core.importText(link.replace('security=reality&pbk=public-key', 'security=tls&allowInsecure=1')));
  assert.throws(() => core.importText(link.replace('&pbk=public-key', '')));
  const cfg = config(); cfg.outbounds[1].tag = 'proxy'; assert.throws(() => core.importText(JSON.stringify(cfg)));
  const geo = config(); geo.routing.rules[0].domain = ['geosite:private']; assert.throws(() => core.importText(JSON.stringify(geo)));
});
const ovpn = (host = '203.0.113.5') => `client\ndev tun\nproto tcp\nremote ${host} 443\n<ca>\nCERTIFICATE TEST FIXTURE\n</ca>\n`;
const csv = (rows) => '*vpn_servers\r\n#HostName,IP,Score,CountryLong,CountryShort,OpenVPN_ConfigData_Base64\r\n' + rows.join('\r\n') + '\r\n*\r\n';
const row = (ip, country = 'Japan', score = 100, conf = ovpn(ip)) => `test,${ip},${score},"${country}",JP,${Buffer.from(conf).toString('base64')}`;
test('VPN Gate CSV handles quotes, sorts, deduplicates and adds certificate validation', () => {
  const profiles = core.vpnGate(csv([row('203.0.113.5', 'Test, Country', 1), row('203.0.113.6', 'Japan', 2), row('203.0.113.6')]));
  assert.equal(profiles.length, 2); assert.equal(profiles[0].host, '203.0.113.6');
  assert.match(profiles[0].configuration, /remote-cert-tls server/); assert.equal(profiles[1].name, 'Test, Country');
});
test('VPN Gate rejects private addresses, mismatched config endpoints, scripts, UDP and malformed rows', () => {
  const input = csv([row('127.0.0.1'), row('10.1.1.1'), row('203.0.113.2', 'A', 1, ovpn('203.0.113.3')), row('203.0.113.4', 'A', 1, ovpn('203.0.113.4') + 'up /tmp/script\n'), row('203.0.113.8', 'A', 1, ovpn('203.0.113.8').replace('proto tcp', 'proto udp')), row('203.0.113.9')]);
  const profiles = core.vpnGate(input); assert.equal(profiles.length, 1); assert.equal(profiles[0].host, '203.0.113.9');
});
test('OpenVPN accepts interactive authentication without mistaking the next line for a password file', () => {
  const profile = core.importText(ovpn() + 'auth-user-pass\nverb 0\n')[0];
  assert.equal(profile.engine, 'openvpn');
  assert.throws(() => core.importText(ovpn() + 'auth-user-pass password.txt\n'));
});
test('VPN Gate rejects hidden secondary remote endpoints and local proxy directives', () => {
  assert.throws(() => core.vpnGate(csv([row('203.0.113.5', 'Test', 1, ovpn() + 'remote 127.0.0.1 8080\n')])));
  assert.throws(() => core.vpnGate(csv([row('203.0.113.5', 'Test', 1, ovpn() + 'socks-proxy 127.0.0.1 1080\n')])));
});
test('remote configuration does not contaminate the AI report', () => {
  const secret = 'never-send-this-secret';
  const safe = core.safeDiagnostic({ tunnel: 'connected', engine: 'xray', config: secret, url: secret, password: secret, checks: [{target: 'cloudflare', ok: false, error: secret, host: secret, milliseconds: 12.6}] });
  assert.equal(JSON.stringify(safe).includes(secret), false); assert.equal(safe.checks[0].milliseconds, 13);
});
test('bad and oversized inputs produce generic errors without echoing credentials', () => {
  assert.throws(() => core.importText('a'.repeat(4194305)));
  assert.throws(() => core.importText('not a configuration'));
  const result = JSON.parse(globalThis.severCall('importText', JSON.stringify('vless://SECRET@host:99999')));
  assert.equal(result.ok, false); assert.equal(result.error.includes('SECRET'), false);
});
