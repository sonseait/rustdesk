import assert from 'node:assert/strict'
import { test } from 'node:test'
import { enrollmentExpiry } from '../src/enrollmentExpiry.ts'

const now = new Date('2026-01-31T12:00:00Z')
test('presets use calendar days, months and years', () => {
  assert.equal(enrollmentExpiry('day', '', now), '2026-02-01T12:00:00.000Z')
  assert.equal(enrollmentExpiry('month', '', now), '2026-02-28T12:00:00.000Z')
  assert.equal(enrollmentExpiry('year', '', now), '2027-01-31T12:00:00.000Z')
})
test('never has no expiry', () => assert.equal(enrollmentExpiry('never', '', now), null))
test('exact converts local datetime to UTC and rejects invalid or past input', () => {
  const exact = '2027-06-10T16:30'
  assert.equal(enrollmentExpiry('exact', exact, now), new Date(exact).toISOString())
  for (const invalid of ['', 'invalid', '2020-01-01T00:00']) {
    assert.throws(() => enrollmentExpiry('exact', invalid, now))
  }
})
