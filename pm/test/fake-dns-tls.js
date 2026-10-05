'use strict';
// Test-only shim, loaded with NODE_OPTIONS=--require by test/local-test.sh.
//
// pm's create flow blocks on a real `https://<subdomain>/` probe before it will
// report httpsReady. In the suite those subdomains do not exist and there is no
// Caddy, so the probe could never succeed — and httpsReady was only ever
// asserted for *shape*, never for being true. That is how a broken TLS probe
// (plain http.get against an https:// URL) passed 79 assertions unnoticed.
//
// This makes the probe meaningful without touching the host:
//   * *.pmtest.example.com resolves to loopback
//   * a self-signed TLS terminator answers on 127.0.0.1:4438443
//   * https requests that omit a port (i.e. :443) are redirected there
//
// The daemon's own code path — scheme selection, status check — is untouched.

const dns = require('dns');
const https = require('https');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const TLS_PORT = 48443; // any free high port; 443 itself needs root
const SUFFIX = '.pmtest.example.com';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pm-tls-'));
const key = path.join(dir, 'k.pem');
const crt = path.join(dir, 'c.pem');
execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes',
  '-keyout', key, '-out', crt, '-days', '2',
  '-subj', '/CN=pmtest.example.com',
  '-addext', 'subjectAltName=DNS:pmtest.example.com,DNS:*.pmtest.example.com'],
{ stdio: 'ignore' });
const creds = { key: fs.readFileSync(key), cert: fs.readFileSync(crt) };

const origLookup = dns.lookup;
dns.lookup = function (hostname, opts, cb) {
  if (typeof opts === 'function') { cb = opts; opts = {}; }
  if (hostname !== 'pmtest.example.com' && !hostname.endsWith(SUFFIX)) {
    return origLookup.apply(this, arguments);
  }
  const done = (typeof cb === 'function' ? cb : opts && opts.callback);
  if (!done) return;
  const addr = { address: '127.0.0.1', family: 4 };
  return process.nextTick(() => done(null, (opts && opts.all) ? [addr] : addr));
};

const tls = https.createServer(creds, (req, res) => {
  res.writeHead(200, { 'content-type': 'text/html' });
  res.end('<h1>served over TLS</h1>\n');
});
tls.listen(TLS_PORT, '127.0.0.1', () => {
  process.stderr.write(`[fake-tls] 127.0.0.1:${TLS_PORT} serves *${SUFFIX}\n`);
});

const origGet = https.get;
https.get = function (input, opts, cb) {
  const isUrl = typeof input === 'string' || input instanceof URL;
  if (!isUrl) return origGet.apply(https, arguments);
  const url = new URL(input.toString());
  if (url.protocol !== 'https:' || url.port !== '') return origGet.apply(https, arguments);
  url.port = String(TLS_PORT);
  return origGet.call(https, url.toString(), Object.assign({}, opts, {
    ca: creds.cert,                          // the cert is self-signed by design
    checkServerIdentity: () => undefined,     // skip hostname verification too
  }), cb);
};

process.on('exit', () => { try { tls.close(); } catch { /* closing */ } });
