import { useState, type FormEvent } from 'react'
import { Button, Modal, PasswordInput, Stack, Text, TextInput } from '@mantine/core'
import toast from 'react-hot-toast'
import { bootstrapAdmin, login, type CurrentUser } from '../../api'
import { generatedApi } from '../../api.generated'

type AuthModalsProps = {
  dialog: 'bootstrap' | 'login' | null
  onClose: () => void
  onBootstrapComplete: () => void
  onSignedIn: (user: CurrentUser) => void
  mfaOpened: boolean
  onCloseMfa: () => void
}

export function AuthModals({
  dialog,
  onClose,
  onBootstrapComplete,
  onSignedIn,
  mfaOpened,
  onCloseMfa,
}: AuthModalsProps) {
  return (
    <>
      <BootstrapModal
        opened={dialog === 'bootstrap'}
        onClose={onClose}
        onComplete={onBootstrapComplete}
      />
      <LoginModal opened={dialog === 'login'} onClose={onClose} onSignedIn={onSignedIn} />
      <MfaModal opened={mfaOpened} onClose={onCloseMfa} />
    </>
  )
}

type AccountModalProps = {
  opened: boolean
  onClose: () => void
  title: string
  submitLabel: string
  fields: Array<'displayName' | 'totp' | 'bootstrapToken'>
  onSubmit: (data: Record<string, string>) => Promise<void>
}

function AccountModal({
  opened,
  onClose,
  title,
  submitLabel,
  fields,
  onSubmit,
}: AccountModalProps) {
  const [error, setError] = useState('')
  const [saving, setSaving] = useState(false)

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const data = Object.fromEntries(new FormData(event.currentTarget)) as Record<string, string>
    setSaving(true)
    setError('')

    try {
      await onSubmit(data)
      toast.success(`${submitLabel} complete`)
    } catch (reason) {
      const message = reason instanceof Error ? reason.message : 'Request failed.'
      setError(message)
      toast.error(message)
    } finally {
      setSaving(false)
    }
  }

  return (
    <Modal opened={opened} onClose={onClose} title={title} centered>
      <form onSubmit={submit}>
        <Stack>
          <TextInput name="email" label="Work email" type="email" required />
          {fields.includes('displayName') && (
            <TextInput name="displayName" label="Display name" required />
          )}
          <PasswordInput name="password" label="Password" minLength={12} required />
          {fields.includes('totp') && (
            <TextInput
              name="totp"
              label="Authenticator code"
              inputMode="numeric"
              maxLength={6}
              description="Required only when MFA is enabled."
            />
          )}
          {fields.includes('bootstrapToken') && (
            <PasswordInput name="bootstrapToken" label="Bootstrap token" required />
          )}
          {error && (
            <Text c="red" size="sm">
              {error}
            </Text>
          )}
          <Button type="submit" loading={saving}>
            {submitLabel}
          </Button>
        </Stack>
      </form>
    </Modal>
  )
}

function BootstrapModal({
  opened,
  onClose,
  onComplete,
}: {
  opened: boolean
  onClose: () => void
  onComplete: () => void
}) {
  return (
    <AccountModal
      opened={opened}
      onClose={onClose}
      title="Create your administrator"
      submitLabel="Create administrator"
      fields={['displayName', 'bootstrapToken']}
      onSubmit={async (data) => {
        await bootstrapAdmin({
          email: data.email,
          displayName: data.displayName,
          password: data.password,
          bootstrapToken: data.bootstrapToken,
        })
        onComplete()
      }}
    />
  )
}

function LoginModal({
  opened,
  onClose,
  onSignedIn,
}: {
  opened: boolean
  onClose: () => void
  onSignedIn: (user: CurrentUser) => void
}) {
  return (
    <AccountModal
      opened={opened}
      onClose={onClose}
      title="Welcome back"
      submitLabel="Sign in"
      fields={['totp']}
      onSubmit={async (data) => onSignedIn(await login(data.email, data.password, data.totp || undefined))}
    />
  )
}

function MfaModal({ opened, onClose }: { opened: boolean; onClose: () => void }) {
  const [uri, setUri] = useState('')
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  async function start() {
    setBusy(true)
    setError('')
    try {
      setUri((await generatedApi.beginTotpSetup()).otpauth_url)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Unable to start MFA setup.')
    } finally {
      setBusy(false)
    }
  }

  async function confirm() {
    setBusy(true)
    setError('')
    try {
      await generatedApi.confirmTotpSetup(code)
      toast.success('MFA enabled')
      onClose()
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Invalid authenticator code.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal opened={opened} onClose={onClose} title="Multi-factor authentication" centered>
      <Stack>
        <Text size="sm" c="dimmed">
          Add this account to an authenticator app, then confirm its six-digit code.
        </Text>
        {!uri ? (
          <Button onClick={start} loading={busy}>
            Generate setup link
          </Button>
        ) : (
          <>
            <TextInput label="Authenticator setup URI" value={uri} readOnly />
            <TextInput
              label="Authenticator code"
              inputMode="numeric"
              maxLength={6}
              value={code}
              onChange={(event) => setCode(event.currentTarget.value)}
            />
            <Button onClick={confirm} loading={busy}>
              Enable MFA
            </Button>
          </>
        )}
        {error && (
          <Text c="red" size="sm">
            {error}
          </Text>
        )}
      </Stack>
    </Modal>
  )
}
