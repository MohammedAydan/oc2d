#!/usr/bin/env node
'use strict';
// pm daemon — manages projects (systemd units + Caddy routes) and answers
// Caddy's on_demand_tls authorization gate. Single JSON state file, no DB.

const http = require('http');
const fs = require('fs');
const path = require('path');
const net = require('net');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const CFG = {
  tokenFile: process.env.PM_TOKEN_FILE || '/etc/pm/token',
  parent: (process.env.PM_PARENT || '').toLowerCase().replace(/\.+$/, ''),
  projectsDir: process.env.PM_PROJECTS_DIR || '/srv/pm/projects',
  unitsDir: process.env.PM_UNITS_DIR || '/etc/systemd/system',
  stateFile: process.env.PM_STATE || '/var/lib/pm/state.json',
  port: +(process.env.PM_PORT || 8300),
  caddyAdmin: (process.env.PM_CADDY_ADMIN || 'http://127.0.0.1:2019').replace(/\/+$/, ''),
  runUser: process.env.PM_RUN_USER || 'pm',
  readyTimeoutMs: +(process.env.PM_READY_TIMEOUT_MS || 15000),
  httpsTimeoutMs: +(process.env.PM_HTTPS_TIMEOUT_MS || 90000),
  fallbackAsks: (process.env.PM_FALLBACK_ASKS || '')
    .split(',').map((s) => s.trim()).filter(Boolean),
};
const [PORT_LO, PORT_HI] = (process.env.PM_PORT_RANGE || '4096-5000').split('-').map(Number);

const NAME_RE = /^[a-z][a-z0-9-]{1,30}$/;
const UNIT = (n) => `pm-${n}.service`;

// ---------------------------------------------------------------- utilities

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { encoding: 'utf8', timeout: opts.timeout || 30000 });
  return { code: r.status === null ? 1 : r.status, out: (r.stdout || '').trim(), err: (r.stderr || '').trim() };
}

function readState() {
  try {
    const s = JSON.parse(fs.readFileSync(CFG.stateFile, 'utf8'));
    return Array.isArray(s.projects) ? s : { projects: [] };
  } catch {
    return { projects: [] };
  }
}

function writeState(s) {
  fs.mkdirSync(path.dirname(CFG.stateFile), { recursive: true, mode: 0o750 });
  const tmp = `${CFG.stateFile}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(s, null, 2) + '\n', { mode: 0o640 });
  fs.renameSync(tmp, CFG.stateFile); // atomic
}

const TOKEN = (() => {
  try {
    return fs.readFileSync(CFG.tokenFile, 'utf8').trim();
  } catch {
    console.error(`pmd: cannot read token file ${CFG.tokenFile}`);
    process.exit(1);
  }
})();

function tokenMatches(given) {
  const a = Buffer.from(given || '');
  const b = Buffer.from(TOKEN);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

const findProject = (name) => readState().projects.find((p) => p.name === name) || null;

function portFree(port) {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.once('error', () => resolve(false));
    s.once('listening', () => s.close(() => resolve(true)));
    s.listen(port, '127.0.0.1');
  });
}

async function firstFreePort() {
  const taken = new Set(readState().projects.map((p) => p.port));
  for (let p = PORT_LO; p <= PORT_HI; p++) if (!taken.has(p) && (await portFree(p))) return p;
  throw new Error(`no free port in ${PORT_LO}-${PORT_HI}`);
}

function waitFor(fn, timeoutMs, stepMs = 250) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve) => {
    (async () => {
      for (;;) {
        let ok = false;
        try { ok = await fn(); } catch { ok = false; }
        if (ok) return resolve(true);
        if (Date.now() >= deadline) return resolve(false);
        await new Promise((r) => setTimeout(r, stepMs));
      }
    })();
  });
}

const httpProbe = (url, accept) =>
  new Promise((resolve) => {
    const req = http.get(url, { timeout: 5000 }, (res) => { res.resume(); resolve(accept(res.statusCode)); });
    req.on('error', () => resolve(false));
    req.on('timeout', () => { req.destroy(); resolve(false); });
  });

// ------------------------------------------------------------------- caddy

function caddy(method, p, body) {
  return new Promise((resolve, reject) => {
    const u = new URL(CFG.caddyAdmin + p);
    const data = body === undefined ? null : Buffer.from(JSON.stringify(body));
    const req = http.request(
      { hostname: u.hostname, port: u.port || 80, path: u.pathname + u.search, method,
        headers: data ? { 'content-type': 'application/json', 'content-length': data.length } : {} },
      (res) => {
        let raw = '';
        res.on('data', (d) => (raw += d));
        res.on('end', () => {
          if (res.statusCode >= 400) return reject(new Error(`caddy admin ${res.statusCode}: ${raw.slice(0, 200)}`));
          try { resolve(raw ? JSON.parse(raw) : null); } catch { resolve(null); }
        });
      }
    );
    req.on('error', reject);
    req.setTimeout(5000, () => req.destroy(new Error('caddy admin timeout')));
    if (data) req.write(data);
    req.end();
  });
}

// A route is PM-managed when it matches exactly one host. `subs` is the set of
// subdomains PM believes it owns; callers pass deleted names explicitly so a
// route is never classified by guessing.
const routeHost = (r) => (r && r.match && r.match.length === 1 && r.match[0].host &&
  r.match[0].host.length === 1 ? r.match[0].host[0] : null);

/**
 * Rebuild PM's routes from state.json, keeping every other route untouched.
 * Caddy's live config is in-memory, so this is also what restores routes after
 * a Caddy restart.
 */
async function caddySync(droppedSubdomains = []) {
  const servers = await caddy('GET', '/config/apps/http/servers');
  const srv = servers && Object.keys(servers)[0];
  if (!srv) throw new Error('no http server in caddy config');
  const base = `/config/apps/http/servers/${srv}/routes`;
  const routes = (await caddy('GET', base)) || [];

  const projects = readState().projects.filter((p) => p.subdomain && !droppedSubdomains.includes(p.subdomain));
  const subs = new Set(projects.map((p) => p.subdomain));
  // Routes for dropped subdomains must be removed as well: once a project is
  // gone from state.json its route is no longer in `subs`, so it would be kept
  // forever and keep proxying to a dead port.
  const owned = new Set([...subs, ...droppedSubdomains.filter(Boolean)]);

  const keep = routes.filter((r) => !owned.has(routeHost(r)));
  const ours = projects.map((p) => ({
    match: [{ host: [p.subdomain] }],
    handle: [{ handler: 'reverse_proxy', upstreams: [{ dial: `127.0.0.1:${p.port}` }] }],
    terminal: true,
  }));

  // Exact-host routes first: the Caddyfile's wildcard block is kept in `keep`,
  // and Caddy evaluates routes in order (also sorting by matcher specificity).
  await caddy('PUT', base, [...ours, ...keep]);
  return ours.length;
}

async function caddySyncQuiet(drop) {
  try { return await caddySync(drop); } catch (e) { console.error('pmd: caddy sync:', e.message); return 0; }
}

// ---------------------------------------------------------------- scaffold

function scaffold(dir, name, port) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o750 });
  fs.writeFileSync(path.join(dir, 'index.html'),
`<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>${name}</title></head>
<body style="font-family:system-ui;margin:4rem auto;max-width:40rem">
<h1>${name}</h1>
<p>Served by <strong>pm</strong> on <code>127.0.0.1:${port}</code>.</p>
</body>
</html>
`);
  fs.writeFileSync(path.join(CFG.unitsDir, UNIT(name)),
`[Unit]
Description=pm project: ${name}
After=network.target

[Service]
Type=simple
User=${CFG.runUser}
Group=${CFG.runUser}
WorkingDirectory=${dir}
ExecStart=/usr/bin/python3 -m http.server ${port} --bind 127.0.0.1 --directory ${dir}
Restart=always
RestartSec=2
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
`);
}

const unitActive = (name) => run('systemctl', ['is-active', '--quiet', UNIT(name)]).code === 0;
const reconcile = (p) => ({ ...p, unit: UNIT(p.name), status: unitActive(p.name) ? 'running' : 'stopped' });

// --------------------------------------------------------------- lifecycle

async function createProject({ name, subdomain }) {
  if (!NAME_RE.test(name || '')) {
    throw Object.assign(new Error('invalid name (want ^[a-z][a-z0-9-]{1,30}$)'), { status: 400 });
  }
  if (!CFG.parent) throw new Error('PM_PARENT is not set on the daemon');
  if (findProject(name)) throw Object.assign(new Error(`project "${name}" already exists`), { status: 409 });

  const sub = (subdomain || `${name}.${CFG.parent}`).toLowerCase();
  if (sub !== CFG.parent && !sub.endsWith(`.${CFG.parent}`)) {
    throw Object.assign(new Error(`subdomain must end in .${CFG.parent}`), { status: 400 });
  }
  if (readState().projects.some((p) => p.subdomain === sub)) {
    throw Object.assign(new Error(`subdomain "${sub}" already in use`), { status: 409 });
  }

  const port = await firstFreePort();
  const dir = path.join(CFG.projectsDir, name);
  let step = 'scaffold';
  let recorded = false;

  try {
    scaffold(dir, name, port);

    step = 'write systemd unit';
    run('systemctl', ['daemon-reload']);
    const en = run('systemctl', ['enable', '--now', UNIT(name)], { timeout: 20000 });
    if (en.code !== 0) throw new Error(`systemctl enable --now failed: ${en.err || en.out}`);

    step = `wait for 127.0.0.1:${port}`;
    if (!await waitFor(() => httpProbe(`http://127.0.0.1:${port}/`, () => true), CFG.readyTimeoutMs)) {
      throw new Error(`port ${port} did not answer within ${CFG.readyTimeoutMs}ms`);
    }

    const project = { name, path: dir, port, unit: UNIT(name), status: 'running', subdomain: sub };
    const state = readState();
    state.projects.push(project);
    writeState(state);
    recorded = true;

    step = `caddy route ${sub} -> 127.0.0.1:${port}`;
    await caddySync();

    step = `https://${sub}`;
    const ready = await waitFor(
      () => httpProbe(`https://${sub}/`, (c) => c === 200 || c === 301 || c === 302 || c === 401),
      CFG.httpsTimeoutMs, 1000
    );
    return { ...project, https: ready ? `https://${sub}` : null, httpsReady: ready };
  } catch (e) {
    if (recorded) {
      const s = readState();
      s.projects = s.projects.filter((p) => p.name !== name);
      writeState(s);
      await caddySyncQuiet([sub]);
    }
    run('systemctl', ['disable', '--now', UNIT(name)], { timeout: 20000 });
    fs.rmSync(path.join(CFG.unitsDir, UNIT(name)), { force: true });
    fs.rmSync(dir, { recursive: true, force: true });
    run('systemctl', ['daemon-reload']);
    throw new Error(`step "${step}" failed: ${e.message}`);
  }
}

async function deleteProject(name, purge) {
  const p = findProject(name);
  if (!p) throw Object.assign(new Error(`no such project "${name}"`), { status: 404 });

  run('systemctl', ['disable', '--now', UNIT(name)], { timeout: 20000 });
  fs.rmSync(path.join(CFG.unitsDir, UNIT(name)), { force: true });
  run('systemctl', ['daemon-reload']);

  const s = readState();
  s.projects = s.projects.filter((x) => x.name !== name);
  writeState(s);
  await caddySyncQuiet([p.subdomain]);

  if (purge) fs.rmSync(p.path, { recursive: true, force: true });
  return { deleted: name, purged: !!purge, subdomain: p.subdomain || null };
}

// ----------------------------------------------------------------- plumbing

function json(res, code, body) {
  const b = Buffer.from(JSON.stringify(body) + '\n');
  res.writeHead(code, { 'content-type': 'application/json', 'content-length': b.length });
  res.end(b);
}

function readBody(req) {
  return new Promise((resolve) => {
    let raw = '';
    req.on('data', (d) => { raw += d; if (raw.length > 1e6) req.destroy(); });
    req.on('end', () => {
      if (!raw) return resolve({});
      try { resolve(JSON.parse(raw)); } catch { resolve({}); }
    });
    req.on('error', () => resolve({}));
  });
}

// Caddy's on_demand_tls authorization gate.
//
// Caddy calls this with GET ?domain=... and cannot send credentials, so it is
// unauthenticated by necessity — hence loopback-only, and the daemon binds
// 127.0.0.1 anyway. Every other endpoint requires the bearer token.
async function checkDomain(domain) {
  const d = (domain || '').toLowerCase().replace(/\.+$/, '');
  if (readState().projects.some((p) => p.subdomain === d)) return true;
  if (!/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/.test(d)) return false;

  // Subdomains PM doesn't own are offered to the gate that was in place before
  // PM was installed, so pre-existing sites keep getting certificates.
  for (const ask of CFG.fallbackAsks) {
    const ok = await new Promise((resolve) => {
      let req;
      try {
        const u = new URL(ask);
        u.searchParams.set('domain', d);
        req = http.get(u, { timeout: 4000 }, (res) => {
          res.resume();
          resolve(res.statusCode >= 200 && res.statusCode < 300);
        });
      } catch { return resolve(false); }
      req.on('error', () => resolve(false));
      req.on('timeout', () => { req.destroy(); resolve(false); });
    });
    if (ok) return true;
  }
  return false;
}

// Serialize mutations so two concurrent creates can't race on state.json.
let chain = Promise.resolve();
const serial = (fn) => { const r = chain.then(fn, fn); chain = r.then(() => {}, () => {}); return r; };

async function handle(req, res) {
  const u = new URL(req.url, 'http://127.0.0.1');
  const parts = u.pathname.split('/').filter(Boolean);
  const method = req.method;

  if (method === 'GET' && u.pathname === '/health') {
    return json(res, 200, { ok: true, parent: CFG.parent, projects: readState().projects.length,
      portRange: `${PORT_LO}-${PORT_HI}` });
  }

  if (u.pathname === '/internal/check-domain' && (method === 'GET' || method === 'POST')) {
    const remote = req.socket.remoteAddress || '';
    if (!['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(remote)) {
      return json(res, 403, { error: 'loopback only' });
    }
    const domain = method === 'GET' ? u.searchParams.get('domain') : (await readBody(req)).domain;
    const allowed = await checkDomain(domain);
    return json(res, allowed ? 200 : 403, { domain, allowed });
  }

  if (!tokenMatches((req.headers.authorization || '').replace(/^Bearer\s+/i, ''))) {
    return json(res, 401, { error: 'unauthorized' });
  }

  if (method === 'POST' && u.pathname === '/projects') return json(res, 201, await createProject(await readBody(req)));
  if (method === 'GET' && u.pathname === '/projects') return json(res, 200, { projects: readState().projects.map(reconcile) });

  if (parts[0] !== 'projects' || !parts[1]) return json(res, 404, { error: 'not found' });
  const name = parts[1];

  if (method === 'GET' && !parts[2]) {
    const p = findProject(name);
    return p ? json(res, 200, reconcile(p)) : json(res, 404, { error: `no such project "${name}"` });
  }

  if (method === 'GET' && parts[2] === 'logs') {
    if (!findProject(name)) return json(res, 404, { error: `no such project "${name}"` });
    const lines = Math.min(Math.max(+(u.searchParams.get('lines') || 100), 1), 5000);
    return json(res, 200, { name, lines, logs: run('journalctl', ['-u', UNIT(name), '--no-pager', '-n', String(lines), '-o', 'cat']).out });
  }

  if (method === 'POST' && ['start', 'stop', 'restart'].includes(parts[2])) {
    if (!findProject(name)) return json(res, 404, { error: `no such project "${name}"` });
    const r = run('systemctl', [parts[2], UNIT(name)], { timeout: 20000 });
    if (r.code !== 0) return json(res, 500, { error: `systemctl ${parts[2]} failed`, detail: r.err });
    return json(res, 200, reconcile(findProject(name)));
  }

  if (method === 'DELETE' && !parts[2]) {
    return json(res, 200, await deleteProject(name, u.searchParams.get('purge') === '1'));
  }

  return json(res, 404, { error: 'not found' });
}

const server = http.createServer((req, res) => {
  const mutating = req.method === 'POST' || req.method === 'DELETE';
  (mutating ? serial(() => handle(req, res)) : handle(req, res))
    .catch((e) => { if (!res.headersSent) json(res, e.status || 500, { error: e.message }); });
});

server.listen(CFG.port, '127.0.0.1', async () => {
  const n = await caddySyncQuiet();
  console.log(`pmd listening on 127.0.0.1:${CFG.port} parent=${CFG.parent} caddy-routes=${n}`);
});
server.on('error', (e) => { console.error('pmd:', e.message); process.exit(1); });
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => server.close(() => process.exit(0)));
