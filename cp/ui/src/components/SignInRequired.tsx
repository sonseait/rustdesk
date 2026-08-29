import { Stack, Text, Title } from '@mantine/core'

export function SessionLoading() {
  return (
    <Stack maw={760} mx="auto" mt={80}>
      <Text size="xs" fw={700} c="teal">
        CONTROL PLANE
      </Text>
      <Title>Restoring your session</Title>
      <Text c="dimmed">Checking your existing sign-in with the control plane.</Text>
    </Stack>
  )
}

export function SignInRequired({ title }: { title: string }) {
  return (
    <Stack maw={760} mx="auto" mt={80}>
      <Text size="xs" fw={700} c="teal">
        CONTROL PLANE
      </Text>
      <Title>{title}</Title>
      <Text c="dimmed">Sign in to manage this control plane.</Text>
    </Stack>
  )
}
