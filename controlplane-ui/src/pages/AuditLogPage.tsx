import { Card, Stack } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import dayjs from 'dayjs'
import { DataTable } from 'mantine-datatable'
import { getAuditEvents, type CurrentUser } from '../api'
import { PageHeader } from '../components/PageHeader'
import { SignInRequired } from '../components/SignInRequired'

export function AuditLogPage({ user }: { user: CurrentUser | null }) {
  const audit = useQuery({
    queryKey: ['audit-events'],
    queryFn: getAuditEvents,
    enabled: Boolean(user),
  })

  if (!user) return <SignInRequired title="Audit log" />

  return (
    <Stack maw={1120} mx="auto">
      <PageHeader eyebrow="AUDITABILITY" title="Audit log" />
      <Card withBorder>
        <DataTable
          withTableBorder
          striped
          minHeight={180}
          fetching={audit.isLoading}
          records={audit.data ?? []}
          columns={[
            { accessor: 'action', title: 'Action' },
            {
              accessor: 'actor_email',
              title: 'Actor',
              render: ({ actor_email }) => actor_email ?? 'System',
            },
            { accessor: 'target_type', title: 'Target' },
            {
              accessor: 'created_at',
              title: 'Time',
              render: ({ created_at }) => dayjs(created_at).format('YYYY-MM-DD HH:mm'),
            },
          ]}
        />
      </Card>
    </Stack>
  )
}
