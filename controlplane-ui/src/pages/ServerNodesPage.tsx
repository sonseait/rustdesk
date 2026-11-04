import { useState } from 'react'
import { Activity, ArrowRight, Server } from 'lucide-react'
import { QueryFeedback, ResourcePanel, ResourceSearch } from '../components/ResourcePanel'
import { Badge, Button, Group, SimpleGrid, Skeleton, Stack, Text } from '@mantine/core'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import dayjs from 'dayjs'
import { DataTable } from 'mantine-datatable'
import { getCurrentServerConfig, getServerNodes, type CurrentUser } from '../api'
import { PageHeader } from '../components/PageHeader'
import { SignInRequired } from '../components/SignInRequired'

export function ServerNodesPage({ user }: { user: CurrentUser | null }) {
  const [search, setSearch] = useState('')
  const nodes = useQuery({
    queryKey: ['server-nodes'],
    queryFn: getServerNodes,
    enabled: Boolean(user),
    retry: 1,
    refetchInterval: 15_000,
  })
  const desired = useQuery({
    queryKey: ['current-server-config'],
    queryFn: getCurrentServerConfig,
    enabled: Boolean(user),
    retry: 1,
    refetchInterval: 15_000,
  })

  if (!user) return <SignInRequired title="Server nodes" />

  return (
    <Stack className="page-stack" mx="auto">
      <PageHeader
        eyebrow="DATA PLANE OPERATIONS"
        title="Server nodes"
        description="Server connection settings and health reported by your node agents."
      />
      <ResourcePanel title="Configured server" description="Connection settings published to your managed desktops" icon={Server} actions={<Button component={Link} to="/policy" variant="subtle" size="xs" rightSection={<ArrowRight size={14} />}>Manage configuration</Button>}>
        <QueryFeedback query={desired} label="desired configuration" />
        <Stack p="lg" gap="md">
          {desired.isLoading ? <Skeleton height={120} /> : desired.data && <>
            <Group justify="space-between">
              <Badge color={desired.data.rendezvous_server && desired.data.relay_server && desired.data.server_public_key ? 'terracotta' : 'gray'}>
                {desired.data.rendezvous_server && desired.data.relay_server && desired.data.server_public_key ? 'Configured' : 'Setup incomplete'}
              </Badge>
              <Text size="xs" c="dimmed">Updated {dayjs(desired.data.updated_at).format('YYYY-MM-DD HH:mm:ss')}</Text>
            </Group>
            <SimpleGrid cols={{ base: 1, sm: 2 }} spacing="lg">
              {[
                ['Rendezvous server (hbbs)', desired.data.rendezvous_server || 'Not configured'],
                ['Relay server (hbbr)', desired.data.relay_server || 'Not configured'],
                ['Desired configuration', `Revision ${desired.data.revision}`],
                ['Managed mode', { off: 'Off · legacy connections', optional: 'Optional · managed and legacy', required: 'Required · managed devices only' }[desired.data.managed_mode]],
              ].map(([label, value]) => <div key={label} style={{ minWidth: 0 }}><Text size="xs" c="dimmed" mb={4}>{label}</Text><Text size="sm" fw={600} style={{ overflowWrap: 'anywhere' }}>{value}</Text></div>)}
            </SimpleGrid>
            <div><Text size="xs" c="dimmed" mb={4}>RustDesk server public key</Text><Text className="mono" style={{ overflowWrap: 'anywhere' }}>{desired.data.server_public_key || 'Not configured'}</Text></div>
            <Text size="xs" c="dimmed">These settings describe the configured server. Live health and effective revision require a node agent report.</Text>
          </>}
        </Stack>
      </ResourcePanel>
      {nodes.isSuccess && nodes.data.length === 0 && <div className="node-monitoring-notice" role="status">
        <span className="panel-icon"><Activity size={18} /></span>
        <div><Text size="sm" fw={600}>Waiting for the first node agent report</Text><Text size="xs" c="dimmed" mt={4}>No node agent has registered with this control plane. Server health, effective revision and rollout status will appear when an agent reports. This does not mean your RustDesk server is offline.</Text></div>
        <Button variant="light" size="xs" onClick={() => nodes.refetch()} loading={nodes.isFetching}>Refresh reports</Button>
      </div>}
      <ResourcePanel title="Reporting nodes" description="Live health and configuration rollout reported by node agents" icon={Activity} count={nodes.data?.length} actions={<ResourceSearch value={search} onChange={setSearch} placeholder="Search nodes…" />}>
        <QueryFeedback query={nodes} label="server nodes" />
        <DataTable styles={{ table: { minWidth: 950 } }} scrollAreaProps={{ viewportProps: { tabIndex: 0, 'aria-label': 'Scrollable records' } }}
          minHeight={180}
          fetching={nodes.isLoading}
          records={(nodes.data ?? []).filter((node) => [node.name, node.endpoint, node.status].some((value) => value.toLowerCase().includes(search.toLowerCase())))}
          noRecordsText={nodes.isError ? 'Records are unavailable. Try again above.' : search ? 'No nodes match your search.' : 'No node agent reports yet.'}
          columns={[
            { accessor: 'name', title: 'Node', render: (node) => <div className="cell-identity"><span className="panel-icon"><Server size={17} /></span><div><Text size="sm" fw={600}>{node.name}</Text><Text size="xs" c="dimmed">{node.endpoint}</Text></div></div> },
            {
              accessor: 'status',
              title: 'Health',
              render: ({ status }) => (
                <Badge color={status === 'healthy' ? 'teal' : status === 'unhealthy' ? 'red' : 'gray'}>
                  {status}
                </Badge>
              ),
            },
            {
              accessor: 'health.effective_config.revision',
              title: 'Desired / effective',
              render: ({ health }) =>
                `${desired.data?.revision ?? '--'} / ${health.effective_config?.revision ?? '--'}`,
            },
            {
              accessor: 'health.last_rollout',
              title: 'Rollout',
              render: ({ health }) => {
                if (health.last_rollout?.rolled_back) {
                  return (
                    <Text c="red" size="sm">
                      Rolled back: {health.last_rollout.rolled_back.reason}
                    </Text>
                  )
                }
                if (health.last_rollout?.applied) {
                  return <Badge color="teal">Applied r{health.last_rollout.applied.revision}</Badge>
                }
                return (
                  <Text c="dimmed" size="sm">
                    Waiting
                  </Text>
                )
              },
            },
            {
              accessor: 'last_seen_at',
              title: 'Last seen',
              render: ({ last_seen_at }) =>
                last_seen_at ? dayjs(last_seen_at).format('YYYY-MM-DD HH:mm:ss') : 'Never',
            },
          ]}
        />
      </ResourcePanel>
    </Stack>
  )
}
