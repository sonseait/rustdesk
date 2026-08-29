import { Badge, Button, Card, Group, Paper, SimpleGrid, Stack, Text, Title } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import dayjs from 'dayjs'
import {
  getCurrentServerConfig,
  getDevices,
  getRemoteSessions,
  type CurrentUser,
} from '../api'

type OverviewPageProps = {
  user: CurrentUser | null
  onBootstrap: () => void
  onSignIn: () => void
}

export function OverviewPage({ user, onBootstrap, onSignIn }: OverviewPageProps) {
  const devices = useQuery({
    queryKey: ['devices'],
    queryFn: getDevices,
    enabled: Boolean(user),
    refetchInterval: 15_000,
  })
  const sessions = useQuery({
    queryKey: ['remote-sessions'],
    queryFn: getRemoteSessions,
    enabled: Boolean(user),
    refetchInterval: 15_000,
  })
  const config = useQuery({
    queryKey: ['current-server-config'],
    queryFn: getCurrentServerConfig,
    enabled: Boolean(user),
    refetchInterval: 15_000,
  })

  const cards = [
    {
      label: 'Managed devices',
      value: devices.data?.filter((device) => !device.revoked_at).length,
      detail: 'Active enrolled devices',
    },
    {
      label: 'Active sessions',
      value: sessions.data?.filter(
        (session) => session.status === 'authorized' && dayjs(session.expires_at).isAfter(dayjs()),
      ).length,
      detail: 'Sessions not yet expired',
    },
    {
      label: 'Current server',
      value: config.data ? `r${config.data.revision}` : undefined,
      detail: config.data
        ? `Managed mode: ${config.data.managed_mode}`
        : 'Loading configuration',
    },
  ]

  return (
    <Stack maw={1120} mx="auto" gap="xl">
      <Group justify="space-between" align="end">
        <div>
          <Text size="xs" fw={700} c="teal">
            MANAGED REMOTE ACCESS
          </Text>
          <Title order={1} mt={8}>
            A clear view of every connection.
          </Title>
          <Text c="dimmed" mt="sm" maw={560}>
            Manage users, devices, policies, and the current RustDesk server from one private
            control plane.
          </Text>
        </div>
        <Badge size="lg" color={user ? 'teal' : 'gray'}>
          {user ? 'CONNECTED' : 'READY TO ENROLL'}
        </Badge>
      </Group>

      {!user && (
        <Paper p="lg" bg="dark.8" c="white">
          <Group justify="space-between">
            <div>
              <Text fw={700}>Complete initial setup</Text>
              <Text size="sm" c="gray.4">
                Create the first administrator, or sign in if setup is complete.
              </Text>
            </div>
            <Group>
              <Button variant="subtle" color="gray" onClick={onSignIn}>
                Sign in
              </Button>
              <Button color="lime" c="dark" onClick={onBootstrap}>
                Create administrator
              </Button>
            </Group>
          </Group>
        </Paper>
      )}

      <SimpleGrid cols={{ base: 1, sm: 3 }}>
        {cards.map((card) => (
          <Card key={card.label} withBorder>
            <Text fz={32}>{card.value ?? '--'}</Text>
            <Text fw={700} size="sm">
              {card.label}
            </Text>
            <Text c="dimmed" size="xs">
              {card.detail}
            </Text>
          </Card>
        ))}
      </SimpleGrid>
    </Stack>
  )
}
