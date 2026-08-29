import { useState, type FormEvent } from 'react'
import { Badge, Button, Card, Group, Modal, NumberInput, Paper, Stack, Text, TextInput, Title } from '@mantine/core'
import { useDisclosure } from '@mantine/hooks'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import dayjs from 'dayjs'
import { DataTable } from 'mantine-datatable'
import toast from 'react-hot-toast'
import {
  createEnrollmentToken,
  getDevices,
  getEnrollmentTokens,
  revokeDevice,
  type CurrentUser,
} from '../api'
import { PageHeader } from '../components/PageHeader'
import { SignInRequired } from '../components/SignInRequired'

export function DevicesPage({ user }: { user: CurrentUser | null }) {
  const [opened, { open, close }] = useDisclosure()
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

  if (!user) return <SignInRequired title="Devices" />

  return (
    <Stack maw={1120} mx="auto">
      <Group justify="space-between">
        <PageHeader eyebrow="MANAGED CLIENTS" title="Devices" />
        <Button onClick={open}>Create enrollment token</Button>
      </Group>

      <Card withBorder>
        <DataTable
          withTableBorder
          striped
          minHeight={180}
          fetching={devices.isLoading}
          records={devices.data ?? []}
          columns={[
            { accessor: 'display_name', title: 'Device' },
            { accessor: 'rustdesk_id', title: 'RustDesk ID' },
            { accessor: 'operating_system', title: 'OS' },
            { accessor: 'client_version', title: 'Version' },
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
                  <Badge color="red">Revoked</Badge>
                ) : (
                  <Button size="xs" color="red" variant="subtle" onClick={() => revoke.mutate(id)}>
                    Revoke
                  </Button>
                ),
            },
          ]}
        />
      </Card>

      <Card withBorder>
        <Text fw={700} mb="sm">
          Enrollment tokens
        </Text>
        <DataTable
          minHeight={90}
          fetching={tokens.isLoading}
          records={tokens.data ?? []}
          withTableBorder
          striped
          columns={[
            { accessor: 'label', title: 'Label' },
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
          ]}
        />
      </Card>

      <EnrollmentTokenModal
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
    <Modal opened={opened} onClose={onClose} title="Create enrollment token" centered>
      <form onSubmit={submit}>
        <Stack>
          <TextInput name="label" label="Label" required />
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
          {secret && (
            <Paper p="sm" bg="yellow.1">
              <Text size="xs">Copy this token now. It will not be shown again.</Text>
              <Text ff="monospace" mt={4} style={{ wordBreak: 'break-all' }}>
                {secret}
              </Text>
            </Paper>
          )}
          <Button type="submit" loading={mutation.isPending}>
            Create token
          </Button>
        </Stack>
      </form>
    </Modal>
  )
}
