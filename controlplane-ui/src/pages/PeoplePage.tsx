import { useState } from 'react'
import { Avatar, Badge, Group, Stack, Text } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { DataTable } from 'mantine-datatable'
import { ShieldCheck, Users } from 'lucide-react'
import { getRoles, getUsers, type CurrentUser } from '../api'
import { PageHeader } from '../components/PageHeader'
import { SignInRequired } from '../components/SignInRequired'
import { QueryFeedback, ResourcePanel, ResourceSearch } from '../components/ResourcePanel'

export function PeoplePage({ user }: { user: CurrentUser | null }) {
  const [search, setSearch] = useState('')
  const users = useQuery({ queryKey: ['users'], queryFn: getUsers, enabled: Boolean(user) })
  const roles = useQuery({ queryKey: ['roles'], queryFn: getRoles, enabled: Boolean(user) })
  if (!user) return <SignInRequired title="People & roles" />
  return <Stack className="page-stack" mx="auto">
    <PageHeader eyebrow="ACCESS MANAGEMENT" title="People & roles" description="The people behind your workspace, and the access they need." />
    <ResourcePanel title="Workspace members" description="Administrator accounts and assigned roles" icon={Users} count={users.data?.length} actions={<ResourceSearch value={search} onChange={setSearch} placeholder="Search people…" />}>
      <QueryFeedback query={users} label="workspace members" />
      <DataTable styles={{ table: { minWidth: 720 } }} scrollAreaProps={{ viewportProps: { tabIndex: 0, 'aria-label': 'Scrollable records' } }} minHeight={220} fetching={users.isLoading} records={(users.data ?? []).filter(({ user: member, roles: memberRoles }) => [member.display_name, member.email, ...memberRoles].some((value) => value.toLowerCase().includes(search.toLowerCase())))} idAccessor="user.id" noRecordsText={users.isError ? 'Records are unavailable. Try again above.' : search ? 'No members match your search.' : 'No workspace members to display.'} columns={[
        { accessor: 'user.display_name', title: 'Name', render: ({ user: member }) => <div className="cell-identity"><Avatar color="terracotta" radius="md" size={34}>{member.display_name.slice(0, 2).toUpperCase()}</Avatar><Text fw={600} size="sm">{member.display_name}</Text></div> },
        { accessor: 'user.email', title: 'Email', render: ({ user: member }) => member.email },
        { accessor: 'roles', title: 'Roles', render: ({ roles: memberRoles }) => <Group gap={5}>{memberRoles.length ? memberRoles.map((role) => <Badge key={role}>{role}</Badge>) : <Text size="xs" c="dimmed">No roles assigned</Text>}</Group> },
      ]} />
    </ResourcePanel>
    <ResourcePanel title="Available roles" description="Permissions defined for this workspace" icon={ShieldCheck} count={roles.data?.length}>
      <QueryFeedback query={roles} label="roles" />
      <DataTable styles={{ table: { minWidth: 540 } }} scrollAreaProps={{ viewportProps: { tabIndex: 0, 'aria-label': 'Scrollable records' } }} minHeight={160} fetching={roles.isLoading} records={roles.data ?? []} idAccessor="name" noRecordsText={roles.isError ? 'Roles are unavailable. Try again above.' : 'No roles configured for this workspace.'} columns={[
        { accessor: 'name', title: 'Role', render: ({ name }) => <Badge>{name}</Badge> },
        { accessor: 'description', title: 'Description' },
      ]} />
    </ResourcePanel>
  </Stack>
}
