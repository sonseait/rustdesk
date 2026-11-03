import { Badge, Card, Stack, Text } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import dayjs from 'dayjs'
import { DataTable } from 'mantine-datatable'
import { getCurrentServerConfig, getServerNodes, type CurrentUser } from '../api'
import { PageHeader } from '../components/PageHeader'
import { SignInRequired } from '../components/SignInRequired'

export function ServerNodesPage({ user }: { user: CurrentUser | null }) {
  const nodes = useQuery({
    queryKey: ['server-nodes'],
    queryFn: getServerNodes,
    enabled: Boolean(user),
    refetchInterval: 15_000,
  })
  const desired = useQuery({
    queryKey: ['current-server-config'],
    queryFn: getCurrentServerConfig,
    enabled: Boolean(user),
    refetchInterval: 15_000,
  })

  if (!user) return <SignInRequired title="Server nodes" />

  return (
    <Stack maw={1120} mx="auto">
      <PageHeader
        eyebrow="DATA PLANE OPERATIONS"
        title="Server nodes"
        description={`Desired revision ${desired.data?.revision ?? '--'} is compared with each agent's effective revision.`}
      />
      <Card withBorder>
        <DataTable
          withTableBorder
          striped
          minHeight={180}
          fetching={nodes.isLoading}
          records={nodes.data ?? []}
          columns={[
            { accessor: 'name', title: 'Node' },
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
      </Card>
    </Stack>
  )
}
