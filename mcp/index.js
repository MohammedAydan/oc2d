#!/usr/bin/env node
'use strict';
// pm MCP server — stdio transport, thin HTTP client for the pm daemon.
// Uses the low-level Server API so it stays compatible across SDK minors.

const { Server } = require('@modelcontextprotocol/sdk/server/index.js');
const { StdioServerTransport } = require('@modelcontextprotocol/sdk/server/stdio.js');
const { CallToolRequestSchema, ListToolsRequestSchema } = require('@modelcontextprotocol/sdk/types.js');

const URL_BASE = (process.env.PM_URL || 'http://127.0.0.1:8300').replace(/\/+$/, '');
const TOKEN = process.env.PM_TOKEN || '';

const NAME = { type: 'string', pattern: '^[a-z][a-z0-9-]{1,30}$', description: 'Project name' };

const TOOLS = [
  { name: 'pm_create',
    description: 'Create a project, start it as a systemd service, and expose it at its subdomain over HTTPS with a valid certificate. Takes up to ~90s while the certificate is issued.',
    inputSchema: { type: 'object', required: ['name'], properties: {
      name: NAME,
      subdomain: { type: 'string', description: 'Defaults to <name>.<parent domain>' },
    } } },
  { name: 'pm_list', description: 'List all projects with status, port and subdomain.',
    inputSchema: { type: 'object', properties: {} } },
  { name: 'pm_status', description: 'Get one project’s current status.',
    inputSchema: { type: 'object', required: ['name'], properties: { name: NAME } } },
  { name: 'pm_start', description: 'Start a project’s systemd service.',
    inputSchema: { type: 'object', required: ['name'], properties: { name: NAME } } },
  { name: 'pm_stop', description: 'Stop a project’s systemd service.',
    inputSchema: { type: 'object', required: ['name'], properties: { name: NAME } } },
  { name: 'pm_restart', description: 'Restart a project’s systemd service.',
    inputSchema: { type: 'object', required: ['name'], properties: { name: NAME } } },
  { name: 'pm_delete', description: 'Stop and remove a project, its systemd unit and its Caddy route. Pass purge to also delete the project files.',
    inputSchema: { type: 'object', required: ['name'], properties: {
      name: NAME, purge: { type: 'boolean', description: 'Also delete the project directory' } } } },
  { name: 'pm_logs', description: 'Read recent journal output from a project.',
    inputSchema: { type: 'object', required: ['name'], properties: {
      name: NAME, lines: { type: 'integer', minimum: 1, maximum: 5000, default: 100 } } } },
];

async function api(method, path, body) {
  const res = await fetch(URL_BASE + path, {
    method,
    headers: {
      authorization: `Bearer ${TOKEN}`,
      ...(body ? { 'content-type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(150000),
  });
  const text = await res.text();
  let data;
  try { data = JSON.parse(text); } catch { data = { raw: text }; }
  if (!res.ok) throw new Error(data.error || `daemon returned ${res.status}`);
  return data;
}

const summarize = {
  pm_create: (r) => `${r.name} running on port ${r.port}${r.https ? `, live at ${r.https}` : ' (HTTPS not ready yet)'}`,
  pm_list: (r) => (r.projects.length
    ? r.projects.map((p) => `${p.name}: ${p.status}, :${p.port}, ${p.subdomain}`).join('\n')
    : 'no projects'),
  pm_status: (r) => `${r.name} is ${r.status} on port ${r.port}${r.subdomain ? ` (${r.subdomain})` : ''}`,
  pm_start: (r) => `${r.name} is ${r.status}`,
  pm_stop: (r) => `${r.name} is ${r.status}`,
  pm_restart: (r) => `${r.name} is ${r.status}`,
  pm_delete: (r) => `deleted ${r.deleted}${r.purged ? ' (files removed)' : ''}${r.subdomain ? `, route ${r.subdomain} removed` : ''}`,
  pm_logs: (r) => (r.logs || '(no output)'),
};

const server = new Server({ name: 'pm', version: '0.1.0' }, { capabilities: { tools: {} } });

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args = {} } = req.params;
  const text = (body) => ({ content: [{ type: 'text', text: body }] });

  if (!TOKEN) return text('pm is not configured: PM_TOKEN is empty.');
  try {
    switch (name) {
      case 'pm_create': {
        const r = await api('POST', '/projects', { name: args.name, subdomain: args.subdomain });
        return text(`${summarize[name](r)}\n\n${JSON.stringify(r, null, 2)}`);
      }
      case 'pm_list': {
        const r = await api('GET', '/projects');
        return text(`${summarize[name](r)}\n\n${JSON.stringify(r, null, 2)}`);
      }
      case 'pm_status': return text(summarize[name](await api('GET', `/projects/${encodeURIComponent(args.name)}`)));
      case 'pm_logs': {
        const q = args.lines ? `?lines=${Math.min(Math.max(+args.lines, 1), 5000)}` : '';
        const r = await api('GET', `/projects/${encodeURIComponent(args.name)}/logs${q}`);
        return text(summarize[name](r));
      }
      case 'pm_delete': {
        const q = args.purge ? '?purge=1' : '';
        return text(summarize[name](await api('DELETE', `/projects/${encodeURIComponent(args.name)}${q}`)));
      }
      case 'pm_start': case 'pm_stop': case 'pm_restart': {
        const verb = name.slice(3);
        const r = await api('POST', `/projects/${encodeURIComponent(args.name)}/${verb}`);
        return text(summarize[name](r));
      }
      default: return { content: [{ type: 'text', text: `unknown tool ${name}` }], isError: true };
    }
  } catch (e) {
    return { content: [{ type: 'text', text: `pm_${name.replace('pm_', '')} failed: ${e.message}` }], isError: true };
  }
});

server.connect(new StdioServerTransport()).catch((e) => {
  process.stderr.write(`pm-mcp fatal: ${e.message}\n`);
  process.exit(1);
});
