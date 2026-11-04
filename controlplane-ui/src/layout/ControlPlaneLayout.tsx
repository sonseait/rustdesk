import { useEffect, type ReactNode } from 'react'
import { ActionIcon, Avatar, Badge, Button, Drawer, Group, NavLink, Stack, Text, Tooltip, useMantineColorScheme } from '@mantine/core'
import { useDisclosure } from '@mantine/hooks'
import { Activity, ArrowUpRight, ChevronRight, ClipboardList, LayoutDashboard, Menu, Monitor, Moon, Server, ShieldCheck, SlidersHorizontal, Sun, Users, type LucideIcon } from 'lucide-react'
import { Link, useLocation } from 'react-router-dom'
import { type CurrentUser } from '../api'
import { SessionLoading, SignInActionContext } from '../components/SignInRequired'

type LayoutProps = {
  children: ReactNode
  user: CurrentUser | null
  sessionLoading: boolean
  onSignIn: () => void
  onOpenMfa: () => void
}

export const navigation: Array<{ label: string; path: string; icon: LucideIcon; group: string }> = [
  { label: 'Overview', path: '/', icon: LayoutDashboard, group: 'WORKSPACE' },
  { label: 'Devices', path: '/devices', icon: Monitor, group: 'WORKSPACE' },
  { label: 'People & roles', path: '/people', icon: Users, group: 'WORKSPACE' },
  { label: 'Sessions', path: '/sessions', icon: Activity, group: 'WORKSPACE' },
  { label: 'Server nodes', path: '/nodes', icon: Server, group: 'ADMINISTRATION' },
  { label: 'Server policy', path: '/policy', icon: SlidersHorizontal, group: 'ADMINISTRATION' },
  { label: 'Audit log', path: '/audit', icon: ClipboardList, group: 'ADMINISTRATION' },
]

export function ControlPlaneLayout({ children, user, sessionLoading, onSignIn, onOpenMfa }: LayoutProps) {
  const [opened, { open, close }] = useDisclosure()
  const location = useLocation()
  const { colorScheme, toggleColorScheme } = useMantineColorScheme()
  const current = navigation.find((item) => item.path === location.pathname)
  useEffect(() => { close() }, [location.pathname, close])

  function sidebar() {
    return <>
      <Link to="/" className="aurora-brand" aria-label="Aurora control plane home">
        <span className="aurora-mark"><Monitor size={19} strokeWidth={1.8} /></span>
        <span><strong>AURORA</strong><small>Control plane</small></span>
      </Link>
      <nav aria-label="Main navigation" className="sidebar-nav">
        {['WORKSPACE', 'ADMINISTRATION'].map((group) => <div className="nav-group" key={group}>
          <Text className="nav-group-label">{group}</Text>
          {navigation.filter((item) => item.group === group).map(({ icon: Icon, ...item }) =>
            <NavLink key={item.path} component={Link} to={item.path} label={item.label}
              leftSection={<Icon size={17} strokeWidth={1.7} />} active={location.pathname === item.path}
              aria-current={location.pathname === item.path ? 'page' : undefined} onClick={close} />)}
        </div>)}
      </nav>
      <div className="sidebar-bottom">
        <div className="privacy-note"><ShieldCheck size={19} /><div><Text fw={600} size="sm">Your workspace. Your control.</Text><Text size="xs" c="dimmed">Private infrastructure, managed access.</Text></div></div>
        <div className="server-status"><span className={`status-dot ${user ? 'is-online' : ''}`} /><Text size="xs">{sessionLoading ? 'Restoring session' : user ? 'Authenticated workspace' : 'Sign in to your workspace'}</Text></div>
      </div>
    </>
  }

  return <SignInActionContext.Provider value={onSignIn}>
    <div className="aurora-app">
      <a href="#main-content" className="skip-link" onClick={(event) => { event.preventDefault(); document.getElementById('main-content')?.focus() }}>Skip to content</a>
      <aside className="aurora-sidebar">{sidebar()}</aside>
      <Drawer opened={opened} onClose={close} title="Navigation" size={290} classNames={{ body: 'mobile-sidebar' }}>
        {sidebar()}
      </Drawer>
      <div className="aurora-workspace">
        <header className="workspace-header">
          <Group gap="sm" wrap="nowrap" className="workspace-breadcrumb">
            <ActionIcon className="mobile-menu" onClick={open} aria-label="Open navigation"><Menu size={18} /></ActionIcon>
            <Text size="sm" c="dimmed" className="breadcrumb-root">Workspace</Text><ChevronRight size={13} className="breadcrumb-root" />
            <Text size="sm" fw={600}>{current?.label ?? 'Overview'}</Text>
          </Group>
          <Group gap={8} wrap="nowrap">
            <Badge className="workspace-badge" color="terracotta" leftSection={<ShieldCheck size={12} />}>CONTROL PLANE</Badge>
            <Tooltip label={colorScheme === 'dark' ? 'Switch to light appearance' : 'Switch to dark appearance'}>
              <ActionIcon onClick={toggleColorScheme} aria-label={colorScheme === 'dark' ? 'Switch to light appearance' : 'Switch to dark appearance'}>{colorScheme === 'dark' ? <Sun size={17} /> : <Moon size={17} />}</ActionIcon>
            </Tooltip>
            {user ? <Tooltip label={`${user.display_name} · Account security`}><button className="account-button" onClick={onOpenMfa} aria-label="Open account security"><Avatar aria-hidden="true" size={34} radius="md" color="terracotta">{user.display_name.trim().slice(0, 2).toUpperCase() || 'A'}</Avatar></button></Tooltip>
              : <Button variant="light" onClick={onSignIn} rightSection={<ArrowUpRight size={14} />}>Sign in</Button>}
          </Group>
        </header>
        <main id="main-content" tabIndex={-1} className="workspace-content">{sessionLoading ? <SessionLoading /> : children}</main>
        <footer className="workspace-footer"><span>Aurora Remote</span><span>Private by design.</span></footer>
      </div>
    </div>
  </SignInActionContext.Provider>
}
