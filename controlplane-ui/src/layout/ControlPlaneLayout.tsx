import { type ReactNode } from 'react'
import {
  ActionIcon,
  AppShell,
  Badge,
  Button,
  Group,
  NavLink,
  Stack,
  Text,
  ThemeIcon,
} from '@mantine/core'
import { useDisclosure } from '@mantine/hooks'
import {
  ClipboardList,
  Menu,
  Monitor,
  Settings2,
  ShieldCheck,
  Users,
} from 'lucide-react'
import { useLocation, useNavigate } from 'react-router-dom'
import { type CurrentUser } from '../api'
import { SessionLoading } from '../components/SignInRequired'

type Section = 'overview' | 'people' | 'devices' | 'nodes' | 'sessions' | 'policy' | 'audit'

type LayoutProps = {
  children: ReactNode
  user: CurrentUser | null
  sessionLoading: boolean
  onSignIn: () => void
  onOpenMfa: () => void
}

const navigation: Array<{ id: Section; label: string; path: string }> = [
  { id: 'overview', label: 'Overview', path: '/' },
  { id: 'people', label: 'People & roles', path: '/people' },
  { id: 'devices', label: 'Devices', path: '/devices' },
  { id: 'nodes', label: 'Server nodes', path: '/nodes' },
  { id: 'sessions', label: 'Sessions', path: '/sessions' },
  { id: 'policy', label: 'Server policy', path: '/policy' },
  { id: 'audit', label: 'Audit log', path: '/audit' },
]

export function ControlPlaneLayout({
  children,
  user,
  sessionLoading,
  onSignIn,
  onOpenMfa,
}: LayoutProps) {
  const [opened, { toggle, close }] = useDisclosure()
  const location = useLocation()
  const navigate = useNavigate()

  return (
    <AppShell
      header={{ height: 64 }}
      navbar={{
        width: 250,
        breakpoint: 'sm',
        collapsed: { mobile: !opened },
      }}
      padding="xl"
    >
      <AppShell.Header>
        <Group h="100%" px="lg" justify="space-between">
          <Group>
            <ActionIcon variant="subtle" hiddenFrom="sm" onClick={toggle}>
              <Menu size={18} />
            </ActionIcon>
            <Group gap="xs">
              <ThemeIcon radius="xl">
                <ShieldCheck size={16} />
              </ThemeIcon>
              <Text fw={700}>RustDesk CONTROL</Text>
            </Group>
          </Group>
          <Button variant="subtle" onClick={user ? onOpenMfa : onSignIn}>
            {user?.display_name ?? 'Sign in'}
          </Button>
        </Group>
      </AppShell.Header>

      <AppShell.Navbar p="md">
        <AppShell.Section grow>
          <Stack gap={4}>
            {navigation.map((item) => (
              <NavLink
                key={item.id}
                label={item.label}
                leftSection={<NavigationIcon section={item.id} />}
                active={location.pathname === item.path}
                onClick={() => {
                  navigate(item.path)
                  close()
                }}
              />
            ))}
          </Stack>
        </AppShell.Section>
        <Text size="xs" c="dimmed">
          CURRENT SERVER
        </Text>
        <Badge mt="xs" color={user ? 'teal' : 'gray'} variant="light">
          {user ? 'CONNECTED' : 'SIGN IN REQUIRED'}
        </Badge>
      </AppShell.Navbar>

      <AppShell.Main>{sessionLoading ? <SessionLoading /> : children}</AppShell.Main>
    </AppShell>
  )
}

function NavigationIcon({ section }: { section: Section }) {
  const Icon =
    section === 'overview' || section === 'devices'
      ? Monitor
      : section === 'people'
        ? Users
        : section === 'policy'
          ? Settings2
          : ClipboardList

  return <Icon size={16} />
}
