import { Badge, Button, Card, Group, SimpleGrid, Skeleton, Stack, Text } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import dayjs from 'dayjs'
import { Activity, ArrowRight, ChevronRight, ClipboardList, Monitor, Server, ShieldCheck, SlidersHorizontal, Users } from 'lucide-react'
import { Link } from 'react-router-dom'
import { getCurrentServerConfig, getDevices, getRemoteSessions, type CurrentUser } from '../api'
import { PageHeader } from '../components/PageHeader'
import { QueryFeedback, ResourcePanel } from '../components/ResourcePanel'

type OverviewPageProps = { user: CurrentUser | null; onBootstrap: () => void; onSignIn: () => void }

export function OverviewPage({ user, onBootstrap, onSignIn }: OverviewPageProps) {
  const devices = useQuery({ queryKey: ['devices'], queryFn: getDevices, enabled: Boolean(user), refetchInterval: 15_000 })
  const sessions = useQuery({ queryKey: ['remote-sessions'], queryFn: getRemoteSessions, enabled: Boolean(user), refetchInterval: 15_000 })
  const config = useQuery({ queryKey: ['current-server-config'], queryFn: getCurrentServerConfig, enabled: Boolean(user), refetchInterval: 15_000 })
  const activeDevices = devices.data?.filter((device) => !device.revoked_at)
  const cards = [
    { label: 'Managed devices', value: activeDevices?.length, detail: 'Active enrolled devices', icon: Monitor, query: devices },
    { label: 'Active sessions', value: sessions.data?.filter((session) => session.status === 'authorized' && dayjs(session.expires_at).isAfter(dayjs())).length, detail: 'Authorized and not expired', icon: Activity, query: sessions },
    { label: 'Configuration', value: config.data ? `r${config.data.revision}` : undefined, detail: config.data ? `Managed mode · ${config.data.managed_mode}` : user ? 'Server configuration revision' : 'Sign in to view configuration', icon: Server, query: config },
  ]

  return <Stack className="page-stack" mx="auto">
    <PageHeader eyebrow="YOUR WORKSPACE, AT A GLANCE" title={user ? `Welcome back${user.display_name ? `, ${user.display_name}` : ''}` : 'Welcome to Aurora'} description="A little closer to every device. A clear view of your remote workspace." />
    <div className="overview-feature-grid">
      <section className="feature-panel">
        <div><Text className="eyebrow">{user ? 'MANAGED ACCESS' : 'LET’S GET STARTED'}</Text><h2>{user ? 'Every device, in good hands.' : 'Your workspace starts here.'}</h2><p>{user ? 'Enroll your devices and manage secure remote access from one private workspace.' : 'Sign in to your control plane, or create the first administrator to set up your workspace.'}</p></div>
        <div className="feature-actions">{user ? <><Button component={Link} to="/devices" rightSection={<ArrowRight size={15} />}>Manage devices</Button><Button component={Link} to="/sessions" variant="subtle">View sessions</Button></> : <><Button onClick={onSignIn} rightSection={<ArrowRight size={15} />}>Sign in to workspace</Button><Button variant="subtle" onClick={onBootstrap}>Create administrator</Button></>}</div>
      </section>
      <Card withBorder className="server-identity">
        <div className="server-identity-top"><Group gap={10}><span className="panel-icon"><ShieldCheck size={18} /></span><Text fw={700}>Workspace identity</Text></Group><Badge color={user ? 'green' : 'gray'}>{user ? 'Signed in' : 'Signed out'}</Badge></div>
        <div><div className="server-detail-row"><span>Administrator</span><span>{user?.display_name || 'Sign in required'}</span></div><div className="server-detail-row"><span>Control plane</span><span>{window.location.host}</span></div><div className="server-detail-row"><span>Access mode</span><span>{config.data?.managed_mode ?? (user ? 'Awaiting configuration' : 'Administrator access')}</span></div></div>
      </Card>
    </div>
    <SimpleGrid cols={{ base: 1, xs: 3 }} spacing={14}>
      {cards.map(({ label, value, detail, icon: Icon, query }) => <Card key={label} withBorder className="metric-card">
        <div className="metric-top"><span className="panel-icon"><Icon size={17} /></span><Text size="sm" fw={600}>{label}</Text></div>
        {user && query.isLoading ? <Skeleton height={36} width={70} mt={14} mb={3} /> : <div className="metric-value">{value ?? '—'}</div>}
        <Text c="dimmed" size="xs">{!user && label !== 'Configuration' ? 'Sign in to view activity' : detail}</Text>
        {user && <QueryFeedback query={query} label={label.toLowerCase()} />}
      </Card>)}
    </SimpleGrid>
    <div className="overview-lower-grid">
      <ResourcePanel title="Recent devices" description="Your most recently enrolled devices" icon={Monitor} actions={<Button component={Link} to="/devices" variant="subtle" size="xs" rightSection={<ArrowRight size={13} />}>View all</Button>}>
        {user && <QueryFeedback query={devices} label="devices" />}
        {user && devices.isLoading ? <Stack p="lg">{[1, 2, 3].map((id) => <Skeleton height={38} key={id} />)}</Stack> : activeDevices?.length ? [...activeDevices].sort((a, b) => dayjs(b.enrolled_at).valueOf() - dayjs(a.enrolled_at).valueOf()).slice(0, 3).map((device) => <div className="overview-device-row" key={device.id}>
          <span className="panel-icon"><Monitor size={18} /></span><div className="device-summary"><Text size="sm" fw={600}>{device.display_name || device.hostname}</Text><Text size="xs" c="dimmed">{device.operating_system} · {device.rustdesk_id}</Text></div><Badge color="terracotta">Enrolled</Badge>
        </div>) : <div className="empty-inline"><Monitor size={24} /><Text fw={600} size="sm">{user ? devices.isError ? 'Devices unavailable' : 'No devices enrolled yet' : 'Your devices belong here'}</Text><Text size="xs">{user ? 'Manage devices to create an enrollment token.' : 'Sign in to see your managed devices.'}</Text></div>}
      </ResourcePanel>
      <ResourcePanel title="Workspace shortcuts" description="Everything you need, close at hand" icon={SlidersHorizontal}>
        {[{ title: 'People & roles', detail: 'Review your team’s access', path: '/people', icon: Users }, { title: 'Server policy', detail: 'Configure how devices connect', path: '/policy', icon: ShieldCheck }, { title: 'Audit log', detail: 'Follow workspace activity', path: '/audit', icon: ClipboardList }].map(({ title, detail, path, icon: Icon }) => <Link className="quick-link" to={path} key={path}><Icon size={17} /><div><Text size="sm" fw={600}>{title}</Text><Text size="xs" c="dimmed" mt={3}>{detail}</Text></div><ChevronRight size={15} /></Link>)}
      </ResourcePanel>
    </div>
  </Stack>
}
