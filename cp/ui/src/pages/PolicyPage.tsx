import { useState } from 'react'
import { Button, Card, Group, NumberInput, Select, SimpleGrid, Stack, Switch, Text, TextInput } from '@mantine/core'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import toast from 'react-hot-toast'
import { z } from 'zod'
import {
  getCurrentServerConfig,
  getServerPolicy,
  updateCurrentServerConfig,
  updateServerPolicy,
  type AnonymousRemotePolicy,
  type CurrentUser,
} from '../api'
import { PageHeader } from '../components/PageHeader'
import { SignInRequired } from '../components/SignInRequired'

const defaultPolicy: AnonymousRemotePolicy = {
  enabled: false,
  max_session_minutes: 30,
  max_concurrent_devices: 1,
  max_devices_per_window: 10,
  window_minutes: 60,
}

const policySchema = z.object({
  enabled: z.boolean(),
  max_session_minutes: z.number().int().min(1).max(480),
  max_concurrent_devices: z.number().int().min(1).max(10_000),
  max_devices_per_window: z.number().int().min(1).max(100_000),
  window_minutes: z.number().int().min(1).max(1440),
})

export function PolicyPage({ user }: { user: CurrentUser | null }) {
  const [policy, setPolicy] = useState(defaultPolicy)
  const [loaded, setLoaded] = useState(false)
  const [saving, setSaving] = useState(false)
  const [message, setMessage] = useState('')

  if (!user) return <SignInRequired title="Server policy" />

  async function load() {
    try {
      setPolicy(await getServerPolicy())
      setLoaded(true)
    } catch (reason) {
      setMessage(reason instanceof Error ? reason.message : 'Unable to load policy.')
    }
  }

  async function save() {
    const validPolicy = policySchema.safeParse(policy)
    if (!validPolicy.success) {
      setMessage(validPolicy.error.issues[0]?.message ?? 'Invalid policy.')
      return
    }

    setSaving(true)
    setMessage('')
    try {
      setPolicy(await updateServerPolicy(validPolicy.data))
      setMessage('Policy saved.')
      toast.success('Server policy saved')
    } catch (reason) {
      const errorMessage = reason instanceof Error ? reason.message : 'Unable to save policy.'
      setMessage(errorMessage)
      toast.error(errorMessage)
    } finally {
      setSaving(false)
    }
  }

  return (
    <Stack maw={760} mx="auto" gap="lg">
      <PageHeader
        eyebrow="CURRENT RUSTDESK SERVER"
        title="Server policy"
        description="Anonymous limits are independent from managed-device authorization."
      />

      {!loaded ? (
        <Button variant="light" onClick={load}>
          Load current policy
        </Button>
      ) : (
        <Card withBorder>
          <Stack>
            <Switch
              checked={policy.enabled}
              onChange={(event) => setPolicy({ ...policy, enabled: event.currentTarget.checked })}
              label="Allow anonymous remote sessions"
              description="Disabled is the safe default."
            />
            <SimpleGrid cols={{ base: 1, sm: 2 }}>
              <LimitInput
                label="Maximum session length"
                value={policy.max_session_minutes}
                onChange={(value) => setPolicy({ ...policy, max_session_minutes: numeric(value) })}
                suffix=" min"
              />
              <LimitInput
                label="Concurrent devices"
                value={policy.max_concurrent_devices}
                onChange={(value) => setPolicy({ ...policy, max_concurrent_devices: numeric(value) })}
              />
            </SimpleGrid>
            <SimpleGrid cols={{ base: 1, sm: 2 }}>
              <LimitInput
                label="New devices per window"
                value={policy.max_devices_per_window}
                onChange={(value) => setPolicy({ ...policy, max_devices_per_window: numeric(value) })}
              />
              <LimitInput
                label="Rate-limit window"
                value={policy.window_minutes}
                onChange={(value) => setPolicy({ ...policy, window_minutes: numeric(value) })}
                suffix=" min"
              />
            </SimpleGrid>
            {message && (
              <Text size="sm" c={message === 'Policy saved.' ? 'teal' : 'red'}>
                {message}
              </Text>
            )}
            <Group justify="flex-end">
              <Button loading={saving} onClick={save}>
                Save policy
              </Button>
            </Group>
          </Stack>
        </Card>
      )}

      <ManagedDeploymentConfig />
    </Stack>
  )
}

function ManagedDeploymentConfig() {
  const queryClient = useQueryClient()
  const config = useQuery({
    queryKey: ['current-server-config'],
    queryFn: getCurrentServerConfig,
  })
  const [mode, setMode] = useState<string | null>(null)
  const [issuer, setIssuer] = useState<string | null>(null)
  const [rendezvous, setRendezvous] = useState<string | null>(null)
  const [relay, setRelay] = useState<string | null>(null)
  const [serverKey, setServerKey] = useState<string | null>(null)
  const save = useMutation({
    mutationFn: updateCurrentServerConfig,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['current-server-config'] })
      toast.success('Managed protocol configuration saved')
    },
    onError: () => toast.error('Unable to save managed protocol configuration'),
  })

  const selectedMode = mode ?? config.data?.managed_mode ?? 'off'
  const selectedIssuer = issuer ?? config.data?.credential_issuer_public_key ?? ''

  return (
    <Card withBorder>
      <Stack>
        <Group justify="space-between">
          <div>
            <Text fw={700}>Managed client deployment</Text>
            <Text size="sm" c="dimmed">
              Clients fetch this signed hbbs/hbbr configuration every five minutes.
            </Text>
          </div>
          <Text size="sm" c="dimmed">
            Revision {config.data?.revision ?? '--'}
          </Text>
        </Group>
        <Select
          label="Managed mode"
          value={selectedMode}
          onChange={setMode}
          data={[
            { value: 'off', label: 'Off - legacy only' },
            { value: 'optional', label: 'Optional - managed and legacy' },
            { value: 'required', label: 'Required - managed devices only' },
          ]}
        />
        <TextInput
          label="Rendezvous server (hbbs)"
          value={rendezvous ?? config.data?.rendezvous_server ?? ''}
          onChange={(event) => setRendezvous(event.currentTarget.value)}
        />
        <TextInput
          label="Relay server (hbbr)"
          value={relay ?? config.data?.relay_server ?? ''}
          onChange={(event) => setRelay(event.currentTarget.value)}
        />
        <TextInput
          label="RustDesk server public key"
          value={serverKey ?? config.data?.server_public_key ?? ''}
          onChange={(event) => setServerKey(event.currentTarget.value)}
        />
        <TextInput
          label="Credential issuer public key"
          description="64 hexadecimal characters. Required outside off mode."
          value={selectedIssuer}
          onChange={(event) => setIssuer(event.currentTarget.value)}
          disabled={selectedMode === 'off'}
        />
        <Group justify="flex-end">
          <Button
            loading={save.isPending}
            onClick={() =>
              save.mutate({
                managed_mode: selectedMode as 'off' | 'optional' | 'required',
                credential_issuer_public_key: selectedMode === 'off' ? null : selectedIssuer || null,
                rendezvous_server: rendezvous ?? config.data?.rendezvous_server ?? '',
                relay_server: relay ?? config.data?.relay_server ?? '',
                server_public_key: serverKey ?? config.data?.server_public_key ?? '',
              })
            }
          >
            Publish revision
          </Button>
        </Group>
      </Stack>
    </Card>
  )
}

function LimitInput(props: Parameters<typeof NumberInput>[0]) {
  const max =
    props.label === 'Maximum session length'
      ? 480
      : props.label === 'Rate-limit window'
        ? 1440
        : 100_000

  return <NumberInput min={1} max={max} {...props} />
}

function numeric(value: string | number | bigint) {
  return typeof value === 'string' ? parseInt(value, 10) || 1 : Number(value)
}
