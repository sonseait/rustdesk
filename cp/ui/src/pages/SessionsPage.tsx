import { Badge, Card, Stack } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import dayjs from 'dayjs'
import { DataTable } from 'mantine-datatable'
import { getRemoteSessions, type CurrentUser } from '../api'
import { PageHeader } from '../components/PageHeader'
import { SignInRequired } from '../components/SignInRequired'

export function SessionsPage({ user }: { user: CurrentUser | null }) {
  const sessions = useQuery({
    queryKey: ['remote-sessions'],
    queryFn: getRemoteSessions,
    enabled: Boolean(user),
  })

  if (!user) return <SignInRequired title="Sessions" />

  return (
    <Stack maw={1120} mx="auto">
      <PageHeader eyebrow="CONTROLLED ACCESS" title="Remote sessions" />
      <Card withBorder>
        <DataTable
          withTableBorder
          striped
          minHeight={180}
          fetching={sessions.isLoading}
          records={sessions.data ?? []}
          columns={[
            {
              accessor: 'status',
              title: 'Status',
              render: ({ status }) => (
                <Badge color={status === 'authorized' ? 'teal' : 'gray'}>{status}</Badge>
              ),
            },
            { accessor: 'source_device_id', title: 'Source device' },
            { accessor: 'target_device_id', title: 'Target device' },
            {
              accessor: 'authorized_at',
              title: 'Authorized',
              render: ({ authorized_at }) => dayjs(authorized_at).format('YYYY-MM-DD HH:mm'),
            },
            {
              accessor: 'expires_at',
              title: 'Expires',
              render: ({ expires_at }) => dayjs(expires_at).format('HH:mm:ss'),
            },
          ]}
        />
      </Card>
    </Stack>
  )
}
