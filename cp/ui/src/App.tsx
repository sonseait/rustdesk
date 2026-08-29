import { useEffect, useState } from 'react'
import { MantineProvider } from '@mantine/core'
import { useDisclosure } from '@mantine/hooks'
import { HashRouter, Navigate, Route, Routes } from 'react-router-dom'
import { getCurrentUser, type CurrentUser } from './api'
import { AuthModals } from './features/auth/AuthModals'
import { ControlPlaneLayout } from './layout/ControlPlaneLayout'
import { AuditLogPage } from './pages/AuditLogPage'
import { DevicesPage } from './pages/DevicesPage'
import { OverviewPage } from './pages/OverviewPage'
import { PeoplePage } from './pages/PeoplePage'
import { PolicyPage } from './pages/PolicyPage'
import { ServerNodesPage } from './pages/ServerNodesPage'
import { SessionsPage } from './pages/SessionsPage'
import { theme } from './theme'

export default function App() {
  return (
    <HashRouter>
      <MantineProvider theme={theme}>
        <ControlPlaneApp />
      </MantineProvider>
    </HashRouter>
  )
}

function ControlPlaneApp() {
  const [user, setUser] = useState<CurrentUser | null>(null)
  const [sessionLoading, setSessionLoading] = useState(true)
  const [authDialog, setAuthDialog] = useState<'bootstrap' | 'login' | null>(null)
  const [mfaOpened, mfaControls] = useDisclosure()

  useEffect(() => {
    getCurrentUser()
      .then(setUser)
      .catch(() => undefined)
      .finally(() => setSessionLoading(false))
  }, [])

  return (
    <ControlPlaneLayout
      user={user}
      sessionLoading={sessionLoading}
      onSignIn={() => setAuthDialog('login')}
      onOpenMfa={mfaControls.open}
    >
      <Routes>
        <Route
          path="/"
          element={
            <OverviewPage
              user={user}
              onBootstrap={() => setAuthDialog('bootstrap')}
              onSignIn={() => setAuthDialog('login')}
            />
          }
        />
        <Route path="/people" element={<PeoplePage user={user} />} />
        <Route path="/devices" element={<DevicesPage user={user} />} />
        <Route path="/nodes" element={<ServerNodesPage user={user} />} />
        <Route path="/sessions" element={<SessionsPage user={user} />} />
        <Route path="/policy" element={<PolicyPage user={user} />} />
        <Route path="/audit" element={<AuditLogPage user={user} />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>

      <AuthModals
        dialog={authDialog}
        onClose={() => setAuthDialog(null)}
        onBootstrapComplete={() => setAuthDialog('login')}
        onSignedIn={(nextUser) => {
          setUser(nextUser)
          setAuthDialog(null)
        }}
        mfaOpened={mfaOpened}
        onCloseMfa={mfaControls.close}
      />
    </ControlPlaneLayout>
  )
}
