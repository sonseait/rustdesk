import { generatedApi, type CurrentUser as GeneratedCurrentUser } from './api.generated'

const apiBaseUrl = import.meta.env.VITE_API_BASE_URL ?? '/api'

export type BootstrapAdmin = {
  email: string
  displayName: string
  password: string
  bootstrapToken: string
}

export async function bootstrapAdmin(admin: BootstrapAdmin) {
  const response = await fetch(`${apiBaseUrl}/v1/bootstrap/admin`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${admin.bootstrapToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      email: admin.email,
      display_name: admin.displayName,
      password: admin.password,
    }),
  })
  if (!response.ok) {
    const body = await response.json().catch(() => ({ error: 'Unable to reach the control plane.' }))
    throw new Error(body.error ?? 'Unable to create administrator.')
  }
  return response.json() as Promise<{ id: string; email: string; display_name: string }>
}

export type CurrentUser = GeneratedCurrentUser

export function login(email: string, password: string, totpCode?: string) {
  return generatedApi.login({ email, password, ...(totpCode ? { totp_code: totpCode } : {}) })
}

export function getCurrentUser() {
  return generatedApi.currentUser()
}

export type AnonymousRemotePolicy = {
  enabled: boolean
  max_session_minutes: number
  max_concurrent_devices: number
  max_devices_per_window: number
  window_minutes: number
}

export async function getServerPolicy() {
  const response = await fetch(`${apiBaseUrl}/v1/server-policy`, { credentials: 'include' })
  if (!response.ok) throw new Error('Unable to load server policy.')
  return response.json() as Promise<AnonymousRemotePolicy>
}

export async function updateServerPolicy(policy: AnonymousRemotePolicy) {
  const response = await fetch(`${apiBaseUrl}/v1/server-policy`, {
    method: 'PUT', credentials: 'include', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(policy),
  })
  if (!response.ok) {
    const body = await response.json().catch(() => ({ error: 'Unable to save server policy.' }))
    throw new Error(body.error ?? 'Unable to save server policy.')
  }
  return response.json() as Promise<AnonymousRemotePolicy>
}

export type CurrentServerConfig = { revision: number; managed_mode: 'off' | 'optional' | 'required'; credential_issuer_public_key: string | null; rendezvous_server: string; relay_server: string; server_public_key: string; updated_at: string }
export const getCurrentServerConfig = () => getAdminResource<CurrentServerConfig>('/v1/current-server/config')
export async function updateCurrentServerConfig(config: Pick<CurrentServerConfig, 'managed_mode' | 'credential_issuer_public_key' | 'rendezvous_server' | 'relay_server' | 'server_public_key'>) {
  const response = await fetch(`${apiBaseUrl}/v1/current-server/config`, {
    method: 'PUT', credentials: 'include', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(config),
  })
  if (!response.ok) {
    const body = await response.json().catch(() => ({ error: 'Unable to save current-server configuration.' }))
    throw new Error(body.error ?? 'Unable to save current-server configuration.')
  }
  return response.json() as Promise<CurrentServerConfig>
}

export type UserSummary = { user: { id: string; email: string; display_name: string; created_at: string }; roles: string[] }
export type Role = { name: string; description: string }
export type AuditEvent = { id: string; action: string; target_type: string; target_id: string; actor_email: string | null; created_at: string }

async function getAdminResource<T>(path: string) {
  const response = await fetch(`${apiBaseUrl}${path}`, { credentials: 'include' })
  if (!response.ok) throw new Error('Unable to load data. Sign in as an administrator.')
  return response.json() as Promise<T>
}

export const getUsers = () => getAdminResource<UserSummary[]>('/v1/users')
export const getRoles = () => getAdminResource<Role[]>('/v1/roles')
export const getAuditEvents = () => getAdminResource<AuditEvent[]>('/v1/audit-events')
export type RemoteSession = { id: string; ticket_id: string; source_device_id: string; target_device_id: string; permission: string; status: string; authorized_at: string; expires_at: string }
export const getRemoteSessions = () => getAdminResource<RemoteSession[]>('/v1/remote-sessions')
export type ServerNode = { id: string; name: string; endpoint: string; status: string; health: { effective_config?: { revision: number; managed_mode: string }; last_rollout?: { applied?: { revision: number }; rolled_back?: { attempted_revision: number; reason: string } } }; last_seen_at: string | null; created_at: string }
export const getServerNodes = () => getAdminResource<ServerNode[]>('/v1/server-nodes')

export type Device = { id: string; rustdesk_id: string; display_name: string; hostname: string; operating_system: string; client_version: string; enrolled_at: string; last_seen_at: string | null; revoked_at: string | null }
export type EnrollmentToken = { id: string; label: string; max_enrollments: number; enrollment_count: number; expires_at: string; revoked_at: string | null }
export type CreatedEnrollmentToken = { token: EnrollmentToken; secret: string }
export const getDevices = () => getAdminResource<Device[]>('/v1/devices')
export const getEnrollmentTokens = () => getAdminResource<EnrollmentToken[]>('/v1/enrollment-tokens')
export async function createEnrollmentToken(input: { label: string; expires_in_hours: number; max_enrollments: number }) {
  const response = await fetch(`${apiBaseUrl}/v1/enrollment-tokens`, { method: 'POST', credentials: 'include', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input) })
  if (!response.ok) throw new Error('Unable to create enrollment token.')
  return response.json() as Promise<CreatedEnrollmentToken>
}
export async function revokeDevice(id: string) { const response = await fetch(`${apiBaseUrl}/v1/devices/${id}/revoke`, { method: 'POST', credentials: 'include' }); if (!response.ok) throw new Error('Unable to revoke device.') }
