'use strict';
// Stand-ins for pm's local test suite:
//   fake-caddy  — the Caddy admin API subset pm uses (in-memory routes)
//   fake-gate   — a "pre-existing" on_demand_tls ask endpoint pm must delegate to
//
// Both listen on loopback only and exit when the harness closes stdin.

const http = require('http');
const PORT_CADDY = +(process.env.FAKE_CADDY_PORT || 8390);
const PORT_GATE = +(process.env.FAKE_GATE_PORT || 8399);
const LEGACY = (process.env.FAKE_GATE_ALLOW || 'legacy.example.com').split(',');

const routes = [
  // A route pm did not create — it must survive every caddySync().
  { match: [{ host: ['somebody-elses-site.example.org'] }],
    handle: [{ handler: 'static_response', status_code: 200 }], terminal: true },
];

const json = (res, code, body) => {
  const b = Buffer.from(JSON.stringify(body));
  res.writeHead(code, { 'content-type': 'application/json', 'content-length': b.length });
  res.end(b);
};

http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  const body = () => new Promise((r) => {
    let raw = '';
    req.on('data', (d) => (raw += d));
    req.on('end', () => { try { r(raw ? JSON.parse(raw) : null); } catch { r(null); } });
  });

  if (u.pathname === '/config/apps/http/servers') {
    return json(res, 200, { srv0: { listen: [':443'], routes } });
  }
  if (u.pathname.endsWith('/routes')) {
    if (req.method === 'GET') return json(res, 200, routes);
    if (req.method === 'PUT') {
      const next = (await body()) || [];
      routes.length = 0;
      routes.push(...next);
      console.error('[fake-caddy] routes now: ' +
        JSON.stringify(routes.map((r) => (r.match && r.match[0] && r.match[0].host) || r.handle[0].handler)));
      return json(res, 200, {});
    }
  }
  return json(res, 404, { error: 'fake-caddy: no such path ' + u.pathname });
}).listen(PORT_CADDY, '127.0.0.1', () =>
  console.error(`[fake-caddy] 127.0.0.1:${PORT_CADDY}`));

// Mirrors oc2d's real contract: GET /internal/check-domain?domain=... -> 200/403.
http.createServer((req, res) => {
  const d = (new URL(req.url, 'http://x').searchParams.get('domain') || '').toLowerCase();
  const ok = LEGACY.includes(d);
  console.error(`[fake-gate] ${d} -> ${ok ? 200 : 403}`);
  res.writeHead(ok ? 200 : 403, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ domain: d, allowed: ok }));
}).listen(PORT_GATE, '127.0.0.1', () =>
  console.error(`[fake-gate] 127.0.0.1:${PORT_GATE} allows ${LEGACY.join(',')}`));

// No stdin handling: the http servers hold the event loop open, and a harness
// background job gets /dev/null on stdin, which would trip an 'end' listener.
