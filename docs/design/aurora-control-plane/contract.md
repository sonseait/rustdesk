# Aurora control plane design contract

The control plane is an operational workspace for administrators managing remote-access devices, people, sessions, server nodes and policies. Device enrollment and reviewing operational state are the primary workflows. Existing API contracts and device revoke/restore actions must remain intact.

Reference: `desktop/flutter/lib/features/workspace/workspace_page.dart`, `app/aurora_app.dart`, and `features/common/aurora_surface.dart`.

- Match desktop's warm canvas (#FFF9F5 / #FFEEE5), terracotta accent (#A24C31), dark brown text (#2A1A15), warm borders (#E7C9BB), 15px translucent panels and 232px floating sidebar. Use the desktop system sans-serif typography and Lucide icons.
- Use the desktop's terracotta feature panel for the main overview action, with operational metrics and device/session summaries below. Show actual data only; signed-out and empty states must not invent metrics.
- All seven routes, authentication, enrollment and MFA dialogs share tokens, typography, focus treatment and responsive controls. Provide persistent light/dark appearance matching desktop's dark palette (#181210 / #261B17 / #F6E9E2 / #FFB294).
- Desktop target: 1440x1000. Mobile target: 390x844. At mobile widths collapse the sidebar into a labeled menu, stack grids and toolbars, and keep wide operational tables in their own horizontal scrolling regions without body overflow.
- Loading: retain content structure, show skeletons/loaders. Empty: describe the missing resource and next step. Error: inline explanation and retry. Partial: keep successful sections visible and mark failed sections. Success: existing mutation feedback plus updated tables. Permission: explain sign-in boundary and expose sign-in.
- Verify routing, appearance persistence, keyboard menu/dialog navigation, visible focus, narrow/wide overflow, long content and reduced-motion CSS. Render fixture states locally for UI inspection; fixture data must never be included in the application build.
