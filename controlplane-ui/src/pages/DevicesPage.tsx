import { useState, type FormEvent } from 'react'
import { Badge, Button, Group, Modal, NumberInput, Paper, Stack, Text, TextInput } from '@mantine/core'
import { useDisclosure } from '@mantine/hooks'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import dayjs from 'dayjs'
import { DataTable } from 'mantine-datatable'
import toast from 'react-hot-toast'
import { Check, Copy, KeyRound, Monitor, Plus, ShieldAlert } from 'lucide-react'
import { QueryFeedback, ResourcePanel, ResourceSearch } from '../components/ResourcePanel'
import {
  createEnrollmentToken,
  getDevices,
  getEnrollmentTokens,
  revokeDevice,
  restoreDevice,
  revokeEnrollmentToken,
  type CurrentUser,
} from '../api'
import { PageHeader } from '../components/PageHeader'
import { SignInRequired } from '../components/SignInRequired'

export function DevicesPage({ user }: { user: CurrentUser | null }) {
  const [opened, { open, close }] = useDisclosure()
  const [search, setSearch] = useState('')
  const [confirmation, setConfirmation] = useState<{ id: string; action: 'revoke' | 'restore' | 'token' } | null>(null)
  const queryClient = useQueryClient()
  const devices = useQuery({ queryKey: ['devices'], queryFn: getDevices, enabled: Boolean(user) })
  const tokens = useQuery({
    queryKey: ['enrollment-tokens'],
    queryFn: getEnrollmentTokens,
    enabled: Boolean(user),
  })
  const revoke = useMutation({
    mutationFn: revokeDevice,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['devices'] })
      toast.success('Device revoked')
    },
    onError: () => toast.error('Unable to revoke device'),
  })
  const revokeToken = useMutation({
    mutationFn: revokeEnrollmentToken,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['enrollment-tokens'] })
      toast.success('Enrollment token revoked')
    },
    onError: () => toast.error('Unable to revoke enrollment token'),
  })
  const restore = useMutation({
    mutationFn: restoreDevice,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['devices'] })
      toast.success('Access restored. The device will recover automatically when online.')
    },
    onError: (error: Error) => toast.error(error.message),
  })

  if (!user) return <SignInRequired title="Devices" />

  return (
    <Stack className="page-stack" mx="auto">
      <Group justify="space-between" className="page-toolbar">
        <PageHeader eyebrow="MANAGED CLIENTS" title="Your devices" description="A home for every device in your workspace. Enroll, review and manage access." />
        <Button onClick={open} leftSection={<Plus size={16} />}>Create enrollment token</Button>
      </Group>

      <ResourcePanel title="Device directory" description="All enrolled devices and their access state" icon={Monitor} count={devices.data?.length} actions={<ResourceSearch value={search} onChange={setSearch} placeholder="Search devices…" />}>
        <QueryFeedback query={devices} label="devices" />
        <DataTable styles={{ table: { minWidth: 1000 } }} scrollAreaProps={{ viewportProps: { tabIndex: 0, 'aria-label': 'Scrollable records' } }}
          minHeight={180}
          fetching={devices.isLoading}
          records={(devices.data ?? []).filter((device) => [device.display_name, device.hostname, device.rustdesk_id, device.operating_system].some((value) => value.toLowerCase().includes(search.toLowerCase())))}
          noRecordsText={devices.isError ? 'Records are unavailable. Try again above.' : search ? 'No devices match your search.' : 'No devices yet. Create an enrollment token to add your first device.'}
          columns={[
            { accessor: 'display_name', title: 'Device', render: (device) => <div className="cell-identity"><span className="panel-icon"><Monitor size={17} /></span><div><Text fw={600} size="sm">{device.display_name || device.hostname}</Text><Text c="dimmed" size="xs">{device.hostname}</Text></div></div> },
            { accessor: 'rustdesk_id', title: 'RustDesk ID' },
            { accessor: 'operating_system', title: 'OS' },
            { accessor: 'client_version', title: 'Version' },
            { accessor: 'last_seen_at', title: 'Last seen', render: ({ last_seen_at }) => last_seen_at ? dayjs(last_seen_at).format('YYYY-MM-DD HH:mm') : 'Never' },
            {
              accessor: 'enrolled_at',
              title: 'Enrolled',
              render: ({ enrolled_at }) => dayjs(enrolled_at).format('YYYY-MM-DD'),
            },
            {
              accessor: 'id',
              title: '',
              render: ({ id, revoked_at }) =>
                revoked_at ? (
                  <Group gap="xs">
                    <Badge color="red">Revoked</Badge>
                    <Button size="xs" variant="subtle" disabled={restore.isPending || revoke.isPending}
                      loading={restore.isPending && restore.variables === id}
                      onClick={() => setConfirmation({ id, action: 'restore' })}>
                      Restore access
                    </Button>
                  </Group>
                ) : (
                  <Button size="xs" color="red" variant="subtle" disabled={revoke.isPending || restore.isPending}
                    onClick={() => setConfirmation({ id, action: 'revoke' })}>
                    Revoke
                  </Button>
                ),
            },
          ]}
        />
      </ResourcePanel>

      <ResourcePanel title="Enrollment tokens" description="Invite devices into your managed workspace" icon={KeyRound} count={tokens.data?.length}>
        <QueryFeedback query={tokens} label="enrollment tokens" />
        <DataTable styles={{ table: { minWidth: 650 } }} scrollAreaProps={{ viewportProps: { tabIndex: 0, 'aria-label': 'Scrollable records' } }}
          minHeight={180}
          fetching={tokens.isLoading}
          records={tokens.data ?? []}
          noRecordsText={tokens.isError ? 'Enrollment tokens are unavailable. Try again above.' : 'No enrollment tokens. Create a token to get started.'}
          columns={[
            { accessor: 'label', title: 'Label' },
            {
              accessor: 'revoked_at', title: 'State',
              render: ({ revoked_at, expires_at, enrollment_count, max_enrollments }) =>
                revoked_at ? <Badge color="red">Revoked</Badge> :
                dayjs(expires_at).isBefore(dayjs()) ? <Badge color="gray">Expired</Badge> :
                enrollment_count >= max_enrollments ? <Badge color="orange">Exhausted</Badge> : <Badge color="green">Active</Badge>,
            },
            {
              accessor: 'enrollment_count',
              title: 'Used',
              render: ({ enrollment_count, max_enrollments }) =>
                `${enrollment_count}/${max_enrollments}`,
            },
            {
              accessor: 'expires_at',
              title: 'Expires',
              render: ({ expires_at }) => dayjs(expires_at).format('YYYY-MM-DD HH:mm'),
            },
            {
              accessor: 'id', title: '', render: ({ id, revoked_at }) => !revoked_at && (
                <Button size="xs" color="red" variant="subtle" disabled={revokeToken.isPending}
                  onClick={() => setConfirmation({ id, action: 'token' })}>
                  Revoke
                </Button>
              ),
            },
          ]}
        />
      </ResourcePanel>

      <Modal opened={Boolean(confirmation)} onClose={() => setConfirmation(null)} title={confirmation?.action === 'restore' ? 'Restore device access?' : confirmation?.action === 'token' ? 'Revoke enrollment token?' : 'Revoke device access?'} centered>
        <Stack><span className="state-icon"><ShieldAlert size={22} /></span><Text size="sm" c="dimmed">{confirmation?.action === 'restore' ? 'The retained device key will recover automatically when online. For lost or compromised keys, provision a new identity instead.' : confirmation?.action === 'token' ? 'Pending enrollment retries using this token will be denied.' : 'This device will lose its managed access. You can restore access from the device directory.'}</Text><Group justify="flex-end"><Button variant="default" onClick={() => setConfirmation(null)}>Cancel</Button><Button color={confirmation?.action === 'restore' ? 'terracotta' : 'red'} onClick={() => { if (!confirmation) return; const mutation = confirmation.action === 'restore' ? restore : confirmation.action === 'token' ? revokeToken : revoke; mutation.mutate(confirmation.id); setConfirmation(null) }}>{confirmation?.action === 'restore' ? 'Restore access' : 'Revoke access'}</Button></Group></Stack>
      </Modal>

      <EnrollmentTokenModal
        key={opened ? 'opened' : 'closed'}
        opened={opened}
        onClose={close}
        onCreated={() => queryClient.invalidateQueries({ queryKey: ['enrollment-tokens'] })}
      />
    </Stack>
  )
}

type EnrollmentTokenModalProps = {
  opened: boolean
  onClose: () => void
  onCreated: () => void
}

function EnrollmentTokenModal({ opened, onClose, onCreated }: EnrollmentTokenModalProps) {
  const [secret, setSecret] = useState('')
  const [copied, setCopied] = useState(false)
  const [expiresInHours, setExpiresInHours] = useState(24)
  const [maxEnrollments, setMaxEnrollments] = useState(1)
  const mutation = useMutation({
    mutationFn: createEnrollmentToken,
    onSuccess: (result) => {
      setSecret(result.secret)
      onCreated()
      toast.success('Enrollment token created')
    },
    onError: () => toast.error('Unable to create token'),
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const data = new FormData(event.currentTarget)
    mutation.mutate({
      label: String(data.get('label')),
      expires_in_hours: expiresInHours,
      max_enrollments: maxEnrollments,
    })
  }

  return (
    <Modal opened={opened} onClose={onClose} closeOnEscape={!mutation.isPending} closeOnClickOutside={!mutation.isPending} closeButtonProps={{ disabled: mutation.isPending, 'aria-label': 'Close dialog' }} title="Create enrollment token" centered>
      <form onSubmit={submit}>
        <Stack>
          <Text size="sm" c="dimmed">Create a time-limited token to enroll devices into your workspace.</Text>
          <fieldset disabled={Boolean(secret) || mutation.isPending} className="enrollment-fields">
          <TextInput placeholder="e.g. Design team laptops" name="label" label="Label" required />
          <NumberInput
            name="expires_in_hours"
            label="Expires in"
            value={expiresInHours}
            onChange={(value) => setExpiresInHours(Number(value) || 1)}
            min={1}
            max={720}
            suffix=" hours"
          />
          <NumberInput
            name="max_enrollments"
            label="Maximum enrollments"
            value={maxEnrollments}
            onChange={(value) => setMaxEnrollments(Number(value) || 1)}
            min={1}
            max={10_000}
          />
          </fieldset>
          {secret && (
            <Paper className="secret-panel" role="status">
              <Text size="xs">Copy this token now. It will not be shown again.</Text>
              <Text ff="monospace" mt={4} style={{ wordBreak: 'break-all' }}>
                {secret}
              </Text>
              <Button mt="sm" size="xs" variant="light" leftSection={copied ? <Check size={14} /> : <Copy size={14} />} onClick={async () => { try { await navigator.clipboard.writeText(secret); setCopied(true) } catch { toast.error('Unable to copy. Select and copy the token manually.') } }}>{copied ? 'Copied' : 'Copy token'}</Button>
            </Paper>
          )}
          {secret ? <Button onClick={onClose}>Done</Button> : <Button type="submit" loading={mutation.isPending}>Create token</Button>}
        </Stack>
      </form>
    </Modal>
  )
}
