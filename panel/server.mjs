// Web control panel for ./llm. No dependencies beyond Node itself.
// Every action runs the ./llm script with a fixed, validated argument list.
//
// Started by `./llm start panel`, which sets PANEL_HOST, PANEL_PORT, LLM_DIR,
// RUN_DIR and LAN_IP. Set PANEL_TOKEN (agents.local.conf) to require a token; it is
// mandatory when the panel listens on anything but loopback.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const LLM_DIR = process.env.LLM_DIR ?? path.resolve(HERE, '..');
const LLM = path.join(LLM_DIR, 'llm');
const RUN_DIR = process.env.RUN_DIR ?? path.join(LLM_DIR, '.runtime');
const HOST = process.env.PANEL_HOST ?? '127.0.0.1';
const PORT = Number(process.env.PANEL_PORT ?? 3900);
const TOKEN = process.env.PANEL_TOKEN ?? '';
// Aether chat runs as its own server on loopback; the panel serves it at /chat/ so
// everything lives behind one address.
const AETHER_PORT = Number(process.env.AETHER_PORT ?? 3910);
const AETHER_TOKEN = process.env.AETHER_WEB_TOKEN ?? '';
// Aether's engineers (same file the desktop app uses). Only names and addresses are
// read, never keys: the Chat tab shows which engineers' backends are running.
const AETHER_CONFIG = path.join(os.homedir(), '.aether-lite', 'config.json');
// Model, role and lead setting given to new agents created from each server (aether-sync.py reads it).
const DEFAULTS_FILE = path.join(RUN_DIR, 'agent-defaults.json');
const LEAD = new Set(['', 'prefer', 'never']);

function readDefaults() {
  try { return JSON.parse(fs.readFileSync(DEFAULTS_FILE, 'utf8')); } catch { return {}; }
}

function cleanDefaults(body) {
  const out = readDefaults();
  for (const svc of ['freellm', 'ollama']) {
    const d = body?.[svc];
    if (!d) continue;
    const model = String(d.model ?? '').trim(), role = String(d.role ?? '').trim(), lead = String(d.lead ?? '');
    if (model.length > 200 || role.length > 80 || !LEAD.has(lead)) return null;
    out[svc] = { model, role, lead };
  }
  return out;
}

// Services the panel may control. The panel never stops itself.
const SERVICES = { freellm: 'agent', ollama: 'ollama', aether: 'aether' };
const SINGLE = new Set(['aether']);
const MAX_INSTANCES = 20;

const LOOPBACK = new Set(['127.0.0.1', '::1', 'localhost']);
if (!LOOPBACK.has(HOST) && !TOKEN) {
  console.error(`Refusing to listen on ${HOST} without PANEL_TOKEN: anyone on the network could start and stop services.`);
  console.error('Set PANEL_TOKEN in agents.local.conf, or keep PANEL_HOST=127.0.0.1.');
  process.exit(1);
}

// Long actions (start, clone, update) run one at a time; status never waits.
let queue = Promise.resolve();
let busy = null;

// stdout and stderr are collected in arrival order, so warnings stay next
// to the lines they belong to.
function llm(args, timeoutMs) {
  return new Promise(resolve => {
    const child = spawn(LLM, args, { cwd: LLM_DIR, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    const add = chunk => { if (output.length < 8 << 20) output += chunk; };
    child.stdout.on('data', add);
    child.stderr.on('data', add);
    const timer = setTimeout(() => child.kill('SIGTERM'), timeoutMs);
    child.on('error', err => { clearTimeout(timer); resolve({ ok: false, output: String(err.message) }); });
    child.on('close', code => { clearTimeout(timer); resolve({ ok: code === 0, output: output.trimEnd() }); });
  });
}

function queued(label, args, timeoutMs = 15 * 60_000) {
  const run = queue.then(async () => {
    busy = label;
    try { return await llm(args, timeoutMs); } finally { busy = null; }
  });
  queue = run.catch(() => {});
  return run;
}

function actionArgs(body) {
  const { action, service, count, port } = body ?? {};
  const portArg = port === undefined || port === null ? [] : Number.isInteger(port) && port > 0 && port < 65536 ? [`:${port}`] : null;
  if (portArg === null) return null;
  switch (action) {
    case 'start':
      if (!(service in SERVICES)) return null;
      if (SINGLE.has(service)) return ['start', service];
      if (!Number.isInteger(count) || count < 1 || count > MAX_INSTANCES) return null;
      return ['start', service, String(count)];
    case 'stop':
      if (!(service in SERVICES)) return null;
      return ['stop', service, ...portArg];
    case 'clone':
      return ['clone', ...portArg];
    case 'sync':
      return ['sync'];
    case 'update':
      return ['update'];
    default:
      return null;
  }
}

// Each engineer, and the local instance it talks to (if it is one of ours).
function engineers(status) {
  let cfg;
  try { cfg = JSON.parse(fs.readFileSync(AETHER_CONFIG, 'utf8')); } catch { return []; }
  const byPort = new Map();
  for (const svc of status.services ?? []) {
    for (const inst of svc.instances ?? []) byPort.set(inst.port, { service: svc.name, label: svc.label, base: svc.basePort, state: inst.state });
  }
  for (const svc of status.services ?? []) {
    // Ports a service would use next, so an engineer on a never-started port still maps to it.
    if (svc.name === 'freellm' || svc.name === 'ollama') {
      for (let p = svc.basePort; p < svc.basePort + MAX_INSTANCES; p++) {
        if (!byPort.has(p)) byPort.set(p, { service: svc.name, label: svc.label, base: svc.basePort, state: 'stopped' });
      }
    }
  }
  return (cfg.engineers ?? []).map(e => {
    let port = null;
    try {
      const u = new URL(e.base_url ?? '');
      if (['localhost', '127.0.0.1', '[::1]'].includes(u.hostname)) port = Number(u.port) || null;
    } catch {}
    const inst = port ? byPort.get(port) : null;
    return {
      id: e.id, name: e.name, role: e.role ?? '', avatar: e.avatar ?? '◆', color: e.color ?? '',
      provider: e.provider, port, model: e.model ?? '', lead: e.lead ?? '', managed: e.managed === 'llm',
      service: inst?.service ?? null, index: inst ? port - inst.base + 1 : null,
      state: inst ? inst.state : null,   // null = not one of ours (CLI, remote API…)
    };
  });
}

function send(res, status, body, type = 'application/json; charset=utf-8') {
  res.writeHead(status, {
    'content-type': type,
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
  });
  res.end(typeof body === 'string' ? body : JSON.stringify(body));
}

// Blocks DNS rebinding: only IP literals and localhost may be used as Host.
function hostAllowed(req) {
  const host = (req.headers.host ?? '').replace(/:\d+$/, '').replace(/^\[|\]$/g, '');
  return host === 'localhost' || /^[\d.]+$/.test(host) || /^[0-9a-f:]+$/i.test(host);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => {
      data += chunk;
      if (data.length > 10_000) { reject(new Error('body too large')); req.destroy(); }
    });
    req.on('end', () => { try { resolve(JSON.parse(data || '{}')); } catch (e) { reject(e); } });
  });
}

function tailFile(file, lines) {
  const stat = fs.statSync(file);
  const size = Math.min(stat.size, 256 * 1024);
  const fd = fs.openSync(file, 'r');
  try {
    const buf = Buffer.alloc(size);
    fs.readSync(fd, buf, 0, size, stat.size - size);
    return buf.toString('utf8').split('\n').slice(-lines).join('\n');
  } finally {
    fs.closeSync(fd);
  }
}

const INDEX = path.join(HERE, 'index.html');
const THEMES = path.join(HERE, 'themes.css');

// Forward /chat/* to Aether, streaming both ways (its event stream stays open).
// The page and its scripts are public like the panel's own page; Aether's API and
// event stream need the panel token when one is set, because Aether's engineers can
// run commands on this Mac.
function proxyChat(req, res, url) {
  const sub = url.pathname.slice('/chat'.length) || '/';
  if (TOKEN && (sub.startsWith('/api/') || sub === '/events')) {
    const given = req.headers['x-aether-token'] || url.searchParams.get('token');
    if (given !== TOKEN) return send(res, 401, { error: 'token required' });
  }
  const query = new URLSearchParams(url.search);
  query.delete('token');
  if (AETHER_TOKEN && sub === '/events') query.set('token', AETHER_TOKEN);
  const headers = { ...req.headers, host: `127.0.0.1:${AETHER_PORT}` };
  delete headers['x-aether-token'];
  if (AETHER_TOKEN) headers['x-aether-token'] = AETHER_TOKEN;
  const qs = query.toString();
  const upstream = http.request(
    { host: '127.0.0.1', port: AETHER_PORT, method: req.method, path: sub + (qs ? `?${qs}` : ''), headers },
    up => { res.writeHead(up.statusCode ?? 502, up.headers); up.pipe(res); },
  );
  upstream.on('error', () => {
    if (!res.headersSent) send(res, 502, { error: 'Aether chat is not running. Start it from the Services tab.' });
    else res.destroy();
  });
  res.on('close', () => upstream.destroy());
  req.pipe(upstream);
}

const server = http.createServer(async (req, res) => {
  try {
    if (!hostAllowed(req)) return send(res, 403, { error: 'bad host' });
    const url = new URL(req.url, 'http://panel');

    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
      return send(res, 200, fs.readFileSync(INDEX, 'utf8'), 'text/html; charset=utf-8');
    }
    if (req.method === 'GET' && url.pathname === '/themes.css') {
      return send(res, 200, fs.readFileSync(THEMES, 'utf8'), 'text/css; charset=utf-8');
    }
    if (url.pathname === '/api/ping') return send(res, 200, { ok: true });
    if (url.pathname === '/chat') { res.writeHead(301, { location: '/chat/' }); return res.end(); }
    if (url.pathname.startsWith('/chat/')) return proxyChat(req, res, url);
    if (!url.pathname.startsWith('/api/')) return send(res, 404, { error: 'not found' });

    if (TOKEN && req.headers['x-panel-token'] !== TOKEN) return send(res, 401, { error: 'token required' });

    if (req.method === 'GET' && url.pathname === '/api/status') {
      const r = await llm(['status', '--json'], 30_000);
      if (!r.ok) return send(res, 500, { error: r.output });
      const status = JSON.parse(r.output);
      return send(res, 200, { ...status, engineers: engineers(status), busy });
    }

    if (req.method === 'GET' && url.pathname === '/api/logs') {
      const service = url.searchParams.get('service');
      const port = Number(url.searchParams.get('port'));
      if (!(service in SERVICES) || !Number.isInteger(port) || port < 1 || port > 65535) {
        return send(res, 400, { error: 'bad service or port' });
      }
      const file = path.join(RUN_DIR, `${SERVICES[service]}-${port}`, 'server.log');
      if (!fs.existsSync(file)) return send(res, 404, { error: 'no log yet' });
      return send(res, 200, { log: tailFile(file, 300) });
    }

    if (url.pathname === '/api/defaults') {
      if (req.method === 'GET') return send(res, 200, readDefaults());
      if (req.method !== 'POST') return send(res, 405, { error: 'method not allowed' });
      if (req.headers['x-llm-panel'] !== '1') return send(res, 403, { error: 'missing header' });
      const next = cleanDefaults(await readBody(req));
      if (!next) return send(res, 400, { error: 'invalid defaults' });
      fs.mkdirSync(RUN_DIR, { recursive: true });
      fs.writeFileSync(DEFAULTS_FILE, JSON.stringify(next, null, 2));
      return send(res, 200, next);
    }

    if (req.method === 'POST' && url.pathname === '/api/action') {
      // A custom header forces a CORS preflight, which this server never
      // approves, so other websites cannot trigger actions from a browser.
      if (req.headers['x-llm-panel'] !== '1') return send(res, 403, { error: 'missing header' });
      const args = actionArgs(await readBody(req));
      if (!args) return send(res, 400, { error: 'invalid action' });
      const r = await queued(args.join(' '), args);
      return send(res, 200, { ...r, command: `./llm ${args.join(' ')}` });
    }

    return send(res, 404, { error: 'not found' });
  } catch (err) {
    return send(res, 500, { error: String(err?.message ?? err) });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`Control panel on http://${HOST.includes(':') ? `[${HOST}]` : HOST}:${PORT}`);
});
