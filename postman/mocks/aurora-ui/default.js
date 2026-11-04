// Local-only visual fixtures. Shapes follow controlplane-ui/src/api.ts and
// api.generated.ts. This is not an implementation or security test of the API.
const http = require('node:http');
const now = new Date().toISOString();
const later = new Date(Date.now() + 3600_000).toISOString();
const administrator = { id: 'ui-admin', email: 'admin@example.test', display_name: 'Alex Morgan' };
const seedDevices = [
  { id: 'design-mac', rustdesk_id: '483 219 706', display_name: 'Design studio · MacBook Pro', hostname: 'studio-mbp', operating_system: 'macOS', client_version: '1.4.0', enrolled_at: now, last_seen_at: now, revoked_at: null },
  { id: 'engineering-pc', rustdesk_id: '702 481 935', display_name: 'Engineering workstation', hostname: 'eng-workstation-01', operating_system: 'Windows 11', client_version: '1.4.0', enrolled_at: now, last_seen_at: now, revoked_at: null },
  { id: 'build-server', rustdesk_id: '915 308 642', display_name: 'Build server · Dubai', hostname: 'build-dxb-01', operating_system: 'Ubuntu 24.04', client_version: '1.4.0', enrolled_at: now, last_seen_at: now, revoked_at: now },
];
let state;
function reset(next = {}) { state = { signedIn: true, empty: false, fail: [], delay: 0, devices: seedDevices.map(d => ({ ...d })), tokens: [{ id: 'token-1', label: 'Engineering onboarding', max_enrollments: 5, enrollment_count: 2, expires_at: later, revoked_at: null }], policy: { enabled: false, max_session_minutes: 30, max_concurrent_devices: 1, max_devices_per_window: 10, window_minutes: 60 }, config: { revision: 12, managed_mode: 'required', credential_issuer_public_key: 'a'.repeat(64), rendezvous_server: 'connect.example.test:21116', relay_server: 'relay.example.test:21117', server_public_key: 'example-public-key', updated_at: now }, ...next }; pm.state.set('aurora-ui.state', state); }
reset();
http.createServer(async (req, res) => {
  const path = new URL(req.url, 'http://localhost').pathname;
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Cache-Control', 'no-store');
  const send = (status, body) => { pm.state.set('aurora-ui.state', state); res.statusCode = status; res.end(body === undefined ? undefined : JSON.stringify(body)); };
  const read = async () => { if (req.body) return typeof req.body === 'string' ? JSON.parse(req.body) : req.body; let raw = ''; for await (const chunk of req) raw += chunk; return raw ? JSON.parse(raw) : {}; };
  if (path === '/__ui/state' && req.method === 'POST') { reset(await read()); return send(200, { state: 'reset' }); }
  if (state.delay) await new Promise(resolve => setTimeout(resolve, state.delay));
  if (path === '/v1/auth/login') { state.signedIn = true; return send(200, administrator); }
  if (path === '/v1/bootstrap/admin') return send(200, administrator);
  if (path === '/v1/auth/me') return send(state.signedIn ? 200 : 401, state.signedIn ? administrator : { error: 'Sign in required.' });
  if (!state.signedIn) return send(401, { error: 'Sign in required.' });
  if (state.fail.some(value => path.includes(value))) return send(503, { error: 'Fixture service temporarily unavailable.' });
  if (path === '/v1/auth/totp') return send(200, { otpauth_url: 'otpauth://totp/Aurora:admin@example.test?secret=JBSWY3DPEHPK3PXP&issuer=Aurora' });
  if (path === '/v1/auth/totp/confirm') return send(204);
  if (path === '/v1/current-server/config') { if (req.method === 'PUT') state.config = { ...state.config, ...await read(), revision: state.config.revision + 1 }; return send(200, state.config); }
  if (path === '/v1/server-policy') { if (req.method === 'PUT') state.policy = await read(); return send(200, state.policy); }
  if (path === '/v1/devices') return send(200, state.empty ? [] : state.devices);
  const deviceAction = path.match(/^\/v1\/devices\/([^/]+)\/(revoke|restore)$/);
  if (deviceAction) { const device = state.devices.find(d => d.id === deviceAction[1]); if (!device) return send(404, { error: 'Unknown device.' }); device.revoked_at = deviceAction[2] === 'revoke' ? now : null; return send(204); }
  if (path === '/v1/enrollment-tokens') {
    if (req.method === 'POST') { const input = await read(); const token = { id: 'new-token', label: input.label, max_enrollments: input.max_enrollments, enrollment_count: 0, expires_at: later, revoked_at: null }; state.tokens.push(token); return send(200, { token, secret: 'ui-fixture-token-not-a-real-secret' }); }
    return send(200, state.empty ? [] : state.tokens);
  }
  if (path.startsWith('/v1/enrollment-tokens/') && req.method === 'DELETE') { const token = state.tokens.find(t => t.id === path.split('/').pop()); if (!token) return send(404, { error: 'Unknown token.' }); token.revoked_at = now; return send(204); }
  if (path === '/v1/users') return send(200, state.empty ? [] : [{ user: { ...administrator, created_at: now }, roles: ['administrator'] }, { user: { id: 'member-2', email: 'engineering@example.test', display_name: 'Engineering team with a longer account display name', created_at: now }, roles: ['operator', 'viewer'] }]);
  if (path === '/v1/roles') return send(200, state.empty ? [] : [{ name: 'administrator', description: 'Manage workspace access, infrastructure and policy.' }, { name: 'operator', description: 'Operate managed devices and review remote sessions.' }, { name: 'viewer', description: 'Review workspace information.' }]);
  if (path === '/v1/remote-sessions') return send(200, state.empty ? [] : [{ id: 'session-1', ticket_id: 'ticket-1', source_device_id: 'design-mac', target_device_id: 'engineering-pc', permission: 'remote_desktop', status: 'authorized', authorized_at: now, expires_at: later }]);
  if (path === '/v1/audit-events') return send(200, state.empty ? [] : [{ id: 'event-1', action: 'device.enrolled', target_type: 'device', target_id: 'design-mac', actor_email: administrator.email, created_at: now }, { id: 'event-2', action: 'configuration.updated', target_type: 'server_config', target_id: 'revision-12', actor_email: null, created_at: now }]);
  if (path === '/v1/server-nodes') return send(200, state.empty ? [] : [{ id: 'node-1', name: 'Dubai · Rendezvous', endpoint: 'connect.example.test:21116', status: 'healthy', health: { effective_config: { revision: 12, managed_mode: 'required' }, last_rollout: { applied: { revision: 12 } } }, last_seen_at: now, created_at: now }, { id: 'node-2', name: 'Frankfurt · Relay', endpoint: 'relay.example.test:21117', status: 'unhealthy', health: { effective_config: { revision: 11, managed_mode: 'required' }, last_rollout: { rolled_back: { attempted_revision: 12, reason: 'Configuration validation failed.' } } }, last_seen_at: now, created_at: now }]);
  return send(501, { error: 'This route is not modeled by the local UI fixture.' });
}).listen(process.env.PORT || 4010, '127.0.0.1');
