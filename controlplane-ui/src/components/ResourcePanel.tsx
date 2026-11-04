import { type ReactNode } from 'react'
import { Button, Card, Group, Text, TextInput, Title } from '@mantine/core'
import { AlertCircle, Search, type LucideIcon } from 'lucide-react'

type ResourcePanelProps = { title: string; description?: string; count?: number; icon?: LucideIcon; children: ReactNode; actions?: ReactNode }
export function ResourcePanel({ title, description, count, icon: Icon, children, actions }: ResourcePanelProps) {
  return <Card withBorder className="resource-panel">
    <Group justify="space-between" className="resource-panel-heading" gap="sm">
      <Group gap="sm" wrap="nowrap">{Icon && <span className="panel-icon"><Icon size={17} /></span>}<div><Group gap={8}><Title order={2} fz="md">{title}</Title>{count !== undefined && <span className="count-label">{count}</span>}</Group>{description && <Text size="xs" c="dimmed" mt={3}>{description}</Text>}</div></Group>
      {actions}
    </Group>
    {children}
  </Card>
}

export function ResourceSearch({ value, onChange, placeholder }: { value: string; onChange: (value: string) => void; placeholder: string }) {
  return <TextInput className="resource-search" aria-label={placeholder} placeholder={placeholder} value={value} onChange={(event) => onChange(event.currentTarget.value)} leftSection={<Search size={15} />} />
}

export function QueryFeedback({ query, label }: { query: { isError: boolean; refetch: () => unknown }; label: string }) {
  if (!query.isError) return null
  return <div className="query-error" role="alert"><AlertCircle size={17} /><Text size="sm">Unable to load {label}.</Text><Button variant="subtle" size="xs" onClick={() => query.refetch()}>Try again</Button></div>
}
