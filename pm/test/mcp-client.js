'use strict';
// Speaks MCP over stdio to pm/mcp/index.js and checks the handshake, the tool
// list and two real tool calls against a running daemon.
//
//   node mcp-client.js <path-to-mcp/index.js> <token> <daemon-url>

const { spawn } = require('child_process');

const [, , script, token, api] = process.argv;
const child = spawn(process.execPath, [script], {
  env: { ...process.env, PM_TOKEN: token, PM_URL: api },
  stdio: ['pipe', 'pipe', 'pipe'],
});

let buf = '';
const pending = new Map();
const send = (method, params) => {
  const id = send.id = (send.id || 0) + 1;
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  return new Promise((res, rej) => {
    pending.set(id, { res, rej });
    setTimeout(() => rej(new Error(`timeout on ${method}`)), 20000);
  });
};

child.stdout.on('data', (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    if (msg.id && pending.has(msg.id)) {
      const { res, rej } = pending.get(msg.id);
      pending.delete(msg.id);
      clearTimeout(0);
      msg.error ? rej(new Error(msg.error.message)) : res(msg.result);
    }
  }
});
child.stderr.on('data', (d) => process.stderr.write(`[mcp] ${d}`));

const results = [];
const check = (ok, label, detail) => results.push(`${ok ? 'OK' : 'FAIL'} ${label}${ok || !detail ? '' : ` — ${detail}`}`);

(async () => {
  const init = await send('initialize', {
    protocolVersion: '2024-11-05',
    capabilities: {},
    clientInfo: { name: 'pm-test', version: '0' },
  });
  check(init.serverInfo && init.serverInfo.name === 'pm', 'initialize: server identifies as pm',
    JSON.stringify(init.serverInfo));
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');

  const { tools } = await send('tools/list', {});
  const names = tools.map((t) => t.name).sort();
  const want = ['pm_create', 'pm_delete', 'pm_list', 'pm_logs', 'pm_restart', 'pm_start', 'pm_status', 'pm_stop'];
  check(JSON.stringify(names) === JSON.stringify(want), `tools/list exposes all 8 tools`,
    `got ${JSON.stringify(names)}`);
  check(tools.every((t) => t.inputSchema && t.inputSchema.type === 'object'),
    'every tool has an object inputSchema');

  const listed = await send('tools/call', { name: 'pm_list', arguments: {} });
  const listText = listed.content[0].text;
  check(!listed.isError && /blog/.test(listText), 'pm_list reaches the daemon and finds the live project',
    listText.slice(0, 120));

  const bad = await send('tools/call', { name: 'pm_status', arguments: { name: 'does-not-exist' } });
  check(bad.isError === true && /no such project/.test(bad.content[0].text),
    'pm_status surfaces a daemon error as isError', JSON.stringify(bad.content[0].text).slice(0, 120));

  child.kill();
  console.log(results.join('\n'));
  process.exit(results.some((r) => r.startsWith('FAIL')) ? 1 : 0);
})().catch((e) => {
  console.log(`FAIL mcp client crashed — ${e.message}`);
  child.kill();
  process.exit(1);
});
