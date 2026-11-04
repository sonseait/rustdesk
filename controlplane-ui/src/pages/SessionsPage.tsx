import { useState } from 'react'
import { Badge, Stack, Text } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import dayjs from 'dayjs'
import { DataTable } from 'mantine-datatable'
import { Activity } from 'lucide-react'
import { getRemoteSessions, type CurrentUser } from '../api'
import { PageHeader } from '../components/PageHeader'
import { SignInRequired } from '../components/SignInRequired'
import { QueryFeedback, ResourcePanel, ResourceSearch } from '../components/ResourcePanel'

export function SessionsPage({ user }: { user: CurrentUser | null }) {
  const [search, setSearch] = useState('')
  const sessions = useQuery({ queryKey: ['remote-sessions'], queryFn: getRemoteSessions, enabled: Boolean(user) })
  if (!user) return <SignInRequired title="Sessions" />
  return <Stack className="page-stack" mx="auto">
    <PageHeader eyebrow="CONTROLLED ACCESS" title="Remote sessions" description="Follow the connections between devices in your workspace." />
    <ResourcePanel title="Connection history" description="Session authorizations and expiration times" count={sessions.data?.length} icon={Activity} actions={<ResourceSearch value={search} onChange={setSearch} placeholder="Search sessions…" />}>
      <QueryFeedback query={sessions} label="remote sessions" />
      <DataTable styles={{ table: { minWidth: 850 } }} scrollAreaProps={{ viewportProps: { tabIndex: 0, 'aria-label': 'Scrollable records' } }} minHeight={260} fetching={sessions.isLoading} records={(sessions.data ?? []).filter((session) => [session.status, session.source_device_id, session.target_device_id].some((value) => value.toLowerCase().includes(search.toLowerCase())))} noRecordsText={sessions.isError ? 'Records are unavailable. Try again above.' : search ? 'No sessions match your search.' : 'No sessions yet. Authorized connections will appear here.'} columns={[
        { accessor: 'status', title: 'Status', render: ({ status, expires_at }) => <Badge color={status === 'authorized' && dayjs(expires_at).isAfter(dayjs()) ? 'green' : 'gray'}>{status === 'authorized' && dayjs(expires_at).isBefore(dayjs()) ? 'Expired' : status}</Badge> },
        { accessor: 'source_device_id', title: 'Source device', render: ({ source_device_id }) => <Text className="mono">{source_device_id}</Text> },
        { accessor: 'target_device_id', title: 'Target device', render: ({ target_device_id }) => <Text className="mono">{target_device_id}</Text> },
        { accessor: 'authorized_at', title: 'Authorized', render: ({ authorized_at }) => dayjs(authorized_at).format('DD MMM YYYY, HH:mm') },
        { accessor: 'expires_at', title: 'Expires', render: ({ expires_at }) => dayjs(expires_at).format('DD MMM YYYY, HH:mm') },
      ]} />
    </ResourcePanel>
  </Stack>
}
