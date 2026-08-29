import { Card, Stack, Text } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { DataTable } from 'mantine-datatable'
import { getRoles, getUsers, type CurrentUser } from '../api'
import { PageHeader } from '../components/PageHeader'
import { SignInRequired } from '../components/SignInRequired'

export function PeoplePage({ user }: { user: CurrentUser | null }) {
  const users = useQuery({
    queryKey: ['users'],
    queryFn: getUsers,
    enabled: Boolean(user),
  })
  const roles = useQuery({
    queryKey: ['roles'],
    queryFn: getRoles,
    enabled: Boolean(user),
  })

  if (!user) return <SignInRequired title="People & roles" />

  return (
    <Stack maw={1120} mx="auto">
      <PageHeader eyebrow="ACCESS MANAGEMENT" title="People & roles" />

      <Card withBorder>
        <DataTable
          withTableBorder
          striped
          minHeight={180}
          fetching={users.isLoading}
          records={users.data ?? []}
          idAccessor="user.id"
          columns={[
            {
              accessor: 'user.display_name',
              title: 'Name',
              render: ({ user: row }) => row.display_name,
            },
            {
              accessor: 'user.email',
              title: 'Email',
              render: ({ user: row }) => row.email,
            },
            {
              accessor: 'roles',
              title: 'Roles',
              render: ({ roles: userRoles }) => userRoles.join(', '),
            },
          ]}
        />
      </Card>

      <Card withBorder>
        <Text fw={700} mb="sm">
          Available roles
        </Text>
        <DataTable
          withTableBorder
          striped
          minHeight={140}
          fetching={roles.isLoading}
          records={roles.data ?? []}
          columns={[
            { accessor: 'name', title: 'Role' },
            { accessor: 'description', title: 'Description' },
          ]}
        />
      </Card>
    </Stack>
  )
}
