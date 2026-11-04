import { createContext, useContext } from 'react'
import { Button, Card, Loader, Stack, Text, Title } from '@mantine/core'
import { ArrowRight, LockKeyhole } from 'lucide-react'

export const SignInActionContext = createContext<() => void>(() => {})

export function SessionLoading() {
  return <div className="session-state" role="status"><Loader size="sm" /><Title order={2}>Restoring your workspace</Title><Text c="dimmed" size="sm">Checking your existing sign-in…</Text></div>
}

export function SignInRequired({ title }: { title: string }) {
  const signIn = useContext(SignInActionContext)
  return <Stack className="page-stack">
    <div className="page-heading"><Text className="eyebrow">YOUR WORKSPACE</Text><Title order={1}>{title}</Title></div>
    <Card withBorder className="permission-panel">
      <span className="state-icon"><LockKeyhole size={25} /></span>
      <Title order={2}>Your workspace awaits</Title>
      <Text c="dimmed" size="sm" maw={340}>Sign in with your administrator account to view and manage {title.toLowerCase()}.</Text>
      <Button onClick={signIn} rightSection={<ArrowRight size={15} />}>Sign in to continue</Button>
    </Card>
  </Stack>
}
