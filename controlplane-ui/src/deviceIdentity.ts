import type { Device } from './api'

export function deviceDisplayName(device: Pick<Device, 'id' | 'display_name' | 'hostname' | 'rustdesk_id'>): string {
  const name = device.display_name.trim()
  if (name && name !== 'Managed RustDesk device') return name

  const hostname = device.hostname.trim()
  if (hostname && !['unknown-host', 'localhost'].includes(hostname.toLowerCase())) return hostname

  const rustdeskId = device.rustdesk_id.trim()
  return rustdeskId ? `RustDesk ${rustdeskId}` : device.id
}
