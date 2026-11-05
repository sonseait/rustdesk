import assert from 'node:assert/strict'
import { test } from 'node:test'
import { readFileSync } from 'node:fs'

import { deviceDisplayName } from '../src/deviceIdentity.ts'
type Identity = { id: string; display_name: string; hostname: string; rustdesk_id: string }
const device = (values: Partial<Identity> = {}): Identity => ({
  id: 'device-uuid', display_name: 'Managed RustDesk device', hostname: 'LAPTOP-KETOAN', rustdesk_id: '123456789', ...values,
})

test('legacy names use the machine hostname', () => {
  assert.equal(deviceDisplayName(device()), 'LAPTOP-KETOAN')
})
test('custom names are preserved', () => {
  assert.equal(deviceDisplayName(device({ display_name: 'Reception' })), 'Reception')
})
test('missing or placeholder hostnames fall back to RustDesk ID then device ID', () => {
  for (const hostname of ['', 'unknown-host', 'localhost', ' UNKNOWN-HOST ']) {
    assert.equal(deviceDisplayName(device({ hostname })), 'RustDesk 123456789')
    assert.equal(deviceDisplayName(device({ hostname, rustdesk_id: '' })), 'device-uuid')
  }
})
test('blank display names use a trimmed hostname', () => {
  assert.equal(deviceDisplayName(device({ display_name: ' ', hostname: ' PC-01 ' })), 'PC-01')
})
test('enrollment and heartbeat use the native cross-platform hostname', () => {
  const source = readFileSync(new URL('../../desktop/src/managed_client.rs', import.meta.url), 'utf8')
  assert.ok(!source.includes('"Managed RustDesk device"'))
  assert.ok(!source.includes('std::env::var("HOSTNAME")'))
  assert.match(source, /enroll\(managed_bootstrap::BOOTSTRAP_TOKEN.into\(\), crate::common::hostname\(\)\)/)
  assert.match(source, /hostname: crate::common::hostname\(\)/)
  assert.match(source, /"hostname": crate::common::hostname\(\)/)
})
