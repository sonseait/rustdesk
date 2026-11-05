import dayjs from 'dayjs'

export type ExpiryPreset = 'day' | 'month' | 'year' | 'never' | 'exact'

export function enrollmentExpiry(preset: ExpiryPreset, exact: string, now = new Date()): string | null {
  if (preset === 'never') return null
  if (preset === 'exact') {
    const expiry = new Date(exact)
    if (!Number.isFinite(expiry.getTime()) || expiry <= now) throw new Error('Choose a future date and time')
    return expiry.toISOString()
  }
  return dayjs(now).add(1, preset).toISOString()
}
