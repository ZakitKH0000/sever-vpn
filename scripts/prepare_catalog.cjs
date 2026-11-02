// Capture a fresh, public VPN Gate bootstrap list before building the application.
// Generated profiles are never committed and contain no personal subscriptions.
const fs = require('node:fs');
const path = require('node:path');
const core = require('../ios/Sever/Resources/sever-core.js');

const sources = [
  'https://www.vpngate.net/api/iphone/',
  'https://download.vpngate.jp/api/iphone/'
];

async function prepare() {
  for (const source of sources) {
    try {
      const response = await fetch(source, { signal: AbortSignal.timeout(20000), headers: { 'User-Agent': 'Sever-build/0.1.1' } });
      if (!response.ok) throw new Error('HTTP ' + response.status);
      let bytes = 0;
      const chunks = [];
      for await (const chunk of response.body) {
        bytes += chunk.length;
        if (bytes > 4 * 1024 * 1024) throw new Error('Catalog exceeds size limit');
        chunks.push(Buffer.from(chunk));
      }
      const profiles = core.vpnGate(Buffer.concat(chunks).toString('utf8'));
      if (!profiles.length) throw new Error('No compatible profiles');
      const output = path.resolve(__dirname, '../ios/Sever/Resources/bootstrap-catalog.json');
      fs.writeFileSync(output, JSON.stringify({ fetchedAt: Date.now() / 1000, profiles }));
      console.log('Prepared public bootstrap catalog: ' + profiles.length + ' profiles from ' + new URL(source).hostname);
      return;
    } catch (error) {
      console.error('Bootstrap source ' + new URL(source).hostname + ': ' + error.name + ' ' + (error.cause?.code || error.code || error.message));
    }
  }
  throw new Error('No bootstrap catalog available; refusing to ship an empty first-launch list');
}
prepare().catch(error => { console.error(error.message); process.exitCode = 1; });
