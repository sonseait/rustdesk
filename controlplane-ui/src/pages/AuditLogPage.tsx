import { useState } from 'react'
import { Badge, Stack, Text } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import dayjs from 'dayjs'
import { DataTable } from 'mantine-datatable'
import { ClipboardList } from 'lucide-react'
import { getAuditEvents, type CurrentUser } from '../api'
import { PageHeader } from '../components/PageHeader'
import { SignInRequired } from '../components/SignInRequired'
import { QueryFeedback, ResourcePanel, ResourceSearch } from '../components/ResourcePanel'

export function AuditLogPage({ user }: { user: CurrentUser | null }) {
  const [search, setSearch] = useState('')
  const audit = useQuery({ queryKey: ['audit-events'], queryFn: getAuditEvents, enabled: Boolean(user) })
  if (!user) return <SignInRequired title="Audit log" />
  return <Stack className="page-stack" mx="auto">
    <PageHeader eyebrow="WORKSPACE ACTIVITY" title="Audit log" description="A clear trail of who did what, and when." />
    <ResourcePanel title="Activity trail" description="Administrative events across your control plane" count={audit.data?.length} icon={ClipboardList} actions={<ResourceSearch value={search} onChange={setSearch} placeholder="Search activity…" />}>
      <QueryFeedback query={audit} label="audit events" />
      <DataTable styles={{ table: { minWidth: 760 } }} scrollAreaProps={{ viewportProps: { tabIndex: 0, 'aria-label': 'Scrollable records' } }} minHeight={260} fetching={audit.isLoading} records={(audit.data ?? []).filter((event) => [event.action, event.actor_email ?? 'System', event.target_type].some((value) => value.toLowerCase().includes(search.toLowerCase())))} noRecordsText={audit.isError ? 'Records are unavailable. Try again above.' : search ? 'No events match your search.' : 'No activity yet. Administrative events will appear here.'} columns={[
        { accessor: 'action', title: 'Action', render: ({ action }) => <Text fw={600} size="sm">{action}</Text> },
        { accessor: 'actor_email', title: 'Actor', render: ({ actor_email }) => actor_email ?? 'System' },
        { accessor: 'target_type', title: 'Target', render: ({ target_type }) => <Badge color="gray">{target_type}</Badge> },
        { accessor: 'created_at', title: 'Time', render: ({ created_at }) => dayjs(created_at).format('DD MMM YYYY, HH:mm') },
      ]} />
    </ResourcePanel>
  </Stack>
}
