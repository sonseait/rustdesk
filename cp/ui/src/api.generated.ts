/*
 * Generated from ../cp/openapi.yaml. Keep this file deliberately small: it
 * centralizes cookie handling and gives portal code one typed transport seam.
 */
const apiBaseUrl = import.meta.env.VITE_API_BASE_URL ?? '/api'

export type LoginRequest = { email: string; password: string; totp_code?: string }
export type CurrentUser = { id: string; email: string; display_name: string }
export type TotpSetup = { otpauth_url: string }

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(`${apiBaseUrl}${path}`, {
    credentials: 'include',
    ...init,
    headers: { 'Content-Type': 'application/json', ...init.headers },
  })
  if (!response.ok) {
    const body = await response.json().catch(() => ({ error: 'Request failed.' }))
    throw new Error(body.error ?? 'Request failed.')
  }
  return response.status === 204 ? undefined as T : response.json() as Promise<T>
}

export const generatedApi = {
  login: (body: LoginRequest) => request<CurrentUser>('/v1/auth/login', { method: 'POST', body: JSON.stringify(body) }),
  currentUser: () => request<CurrentUser>('/v1/auth/me'),
  beginTotpSetup: () => request<TotpSetup>('/v1/auth/totp', { method: 'POST' }),
  confirmTotpSetup: (code: string) => request<void>('/v1/auth/totp/confirm', { method: 'POST', body: JSON.stringify({ code }) }),
}
