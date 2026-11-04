import { Text, Title } from '@mantine/core'

type PageHeaderProps = { eyebrow: string; title: string; description?: string }

export function PageHeader({ eyebrow, title, description }: PageHeaderProps) {
  return <div className="page-heading">
    <Text className="eyebrow">{eyebrow}</Text>
    <Title order={1}>{title}</Title>
    {description && <Text c="dimmed" size="sm" mt={8} maw={650}>{description}</Text>}
  </div>
}
