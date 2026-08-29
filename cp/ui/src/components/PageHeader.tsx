import { Text, Title } from '@mantine/core'

type PageHeaderProps = {
  eyebrow: string
  title: string
  description?: string
}

export function PageHeader({ eyebrow, title, description }: PageHeaderProps) {
  return (
    <div>
      <Text size="xs" fw={700} c="teal">
        {eyebrow}
      </Text>
      <Title mt={7}>{title}</Title>
      {description && (
        <Text c="dimmed" mt="sm">
          {description}
        </Text>
      )}
    </div>
  )
}
