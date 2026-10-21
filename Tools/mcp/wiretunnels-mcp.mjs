#!/usr/bin/env node
// MCP (stdio) bridge for the Debug build of WireTunnels. No dependencies.
// App tools go to the app's local control socket; system_* tools are read-only
// views of macOS state (DNS, interfaces, routes) so a test can verify the real effect.
import { execFile } from 'node:child_process';
import { createConnection } from 'node:net';
import { homedir } from 'node:os';
import { createInterface } from 'node:readline';
import { promisify } from 'node:util';

const run = promisify(execFile);
const SOCKET = process.env.WIRETUNNELS_SOCKET
  ?? `${homedir()}/Library/Application Support/WireTunnels/debug-control.sock`;

const tunnel = { tunnel: { type: 'string', description: 'Tunnel id (UUID) or exact name' } };
const object = (properties, required = []) => ({ type: 'object', properties, required });
const appTool = (name, description, properties = {}, required = [], timeout = 15000) =>
  ({ name, description, inputSchema: object(properties, required), timeout });

async function sh(command, args) {
  try {
    const { stdout } = await run(command, args, { timeout: 10000 });
    return stdout.trim();
  } catch (error) {
    return `(${command} failed: ${error.message})`;
  }
}

async function systemDns() {
  const listing = (await sh('/usr/sbin/networksetup', ['-listallnetworkservices'])).split('\n').slice(1)
    .map((line) => line.replace(/^\*/, ''));
  const services = {};
  for (const service of listing) {
    services[service] = {
      dns: await sh('/usr/sbin/networksetup', ['-getdnsservers', service]),
      search: await sh('/usr/sbin/networksetup', ['-getsearchdomains', service]),
    };
  }
  const resolvers = (await sh('/usr/sbin/scutil', ['--dns'])).split('\n\n')[0];
  return { services, resolvers };
}

async function systemNetwork() {
  const interfaces = (await sh('/sbin/ifconfig', ['-l'])).split(/\s+/).filter((name) => name.startsWith('utun'));
  const details = {};
  for (const name of interfaces) details[name] = await sh('/sbin/ifconfig', [name]);
  const routes = (family) => sh('/usr/sbin/netstat', ['-rn', '-f', family]).then((text) =>
    text.split('\n').filter((line) => /^(default|0\/1|128\.0\/1|::\/1|8000::\/1)\b/.test(line)));
  return { utun: details, ipv4: await routes('inet'), ipv6: await routes('inet6') };
}

const TOOLS = [
  appTool('app_status', 'App readiness: helper approval, tool install, last error, warnings'),
  appTool('list_tunnels', 'All tunnels with live state (active, interface, handshake, traffic, DNS, routes)'),
  appTool('refresh_status', 'Force a status refresh and list tunnels'),
  appTool('get_log', 'Last lines of the app log (keys are redacted)', { lines: { type: 'integer' } }),
  appTool('read_config', 'Config text of a tunnel; PrivateKey/PresharedKey are hidden', tunnel, ['tunnel']),
  appTool('connect', 'Connect a tunnel (waits for the result, up to ~2 min)', tunnel, ['tunnel'], 150000),
  appTool('disconnect', 'Disconnect a tunnel', tunnel, ['tunnel'], 150000),
  appTool('stop_all', 'Disconnect everything', {}, [], 150000),
  appTool('duplicate_tunnel', 'Duplicate a personal tunnel', tunnel, ['tunnel']),
  appTool('create_tunnel', 'Create a personal tunnel from config text',
    { name: { type: 'string' }, config: { type: 'string' } }, ['name', 'config']),
  appTool('update_tunnel', 'Rename and/or replace the config; omit config to keep the current file',
    { ...tunnel, name: { type: 'string' }, config: { type: 'string' } }, ['tunnel']),
  appTool('delete_tunnel', 'Delete a disconnected personal tunnel', tunnel, ['tunnel']),
  appTool('set_kill_switch', 'Enable or disable the kill switch',
    { ...tunnel, enabled: { type: 'boolean' } }, ['tunnel', 'enabled']),
  appTool('set_split_dns', 'Set split-DNS domains',
    { ...tunnel, domains: { type: 'array', items: { type: 'string' } }, reconnect: { type: 'boolean' } },
    ['tunnel', 'domains'], 150000),
  appTool('set_excluded_routes', 'Set CIDR ranges that bypass the tunnel',
    { ...tunnel, routes: { type: 'array', items: { type: 'string' } } }, ['tunnel', 'routes']),
  { name: 'system_dns', description: 'Read-only: DNS servers and search domains of every network service, plus the first scutil resolver',
    inputSchema: object({}), system: systemDns },
  { name: 'system_network', description: 'Read-only: utun interfaces and the default IPv4/IPv6 routes',
    inputSchema: object({}), system: systemNetwork },
];

function callApp(tool, args, timeout) {
  return new Promise((resolve, reject) => {
    const socket = createConnection(SOCKET);
    let buffer = '';
    socket.setTimeout(timeout, () => { socket.destroy(); reject(new Error(`WireTunnels did not answer within ${timeout / 1000}s`)); });
    socket.on('connect', () => socket.write(`${JSON.stringify({ tool, args })}\n`));
    socket.on('data', (chunk) => { buffer += chunk; });
    socket.on('end', () => {
      try {
        const reply = JSON.parse(buffer);
        reply.ok ? resolve(reply.result) : reject(new Error(reply.error));
      } catch { reject(new Error('Invalid reply from WireTunnels')); }
    });
    socket.on('error', (error) => reject(new Error(
      ['ENOENT', 'ECONNREFUSED'].includes(error.code)
        ? `WireTunnels (Debug build) is not running or has no control socket at ${SOCKET}`
        : error.message)));
  });
}

async function callTool({ name, arguments: args = {} }) {
  const tool = TOOLS.find((candidate) => candidate.name === name);
  if (!tool) throw new Error(`Unknown tool: ${name}`);
  return tool.system ? tool.system() : callApp(name, args, tool.timeout);
}

const send = (message) => process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', ...message })}\n`);

async function handle(request) {
  const { id, method, params } = request;
  if (id === undefined) return; // notifications need no reply
  try {
    if (method === 'initialize') {
      send({ id, result: { protocolVersion: params?.protocolVersion ?? '2024-11-05',
        capabilities: { tools: {} }, serverInfo: { name: 'wiretunnels-debug', version: '1.0.0' } } });
    } else if (method === 'ping') {
      send({ id, result: {} });
    } else if (method === 'tools/list') {
      send({ id, result: { tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) } });
    } else if (method === 'tools/call') {
      try {
        const result = await callTool(params);
        send({ id, result: { content: [{ type: 'text', text: typeof result === 'string' ? result : JSON.stringify(result, null, 2) }] } });
      } catch (error) {
        send({ id, result: { isError: true, content: [{ type: 'text', text: error.message }] } });
      }
    } else {
      send({ id, error: { code: -32601, message: `Method not found: ${method}` } });
    }
  } catch (error) {
    send({ id, error: { code: -32603, message: error.message } });
  }
}

createInterface({ input: process.stdin }).on('line', (line) => {
  let request;
  try { request = JSON.parse(line); } catch { return send({ id: null, error: { code: -32700, message: 'Parse error' } }); }
  handle(request);
});
