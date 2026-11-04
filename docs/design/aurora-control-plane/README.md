# Aurora control plane UI

The web control plane now follows the Flutter desktop's Aurora design: warm canvas, terracotta actions, 15px translucent panels, system typography, Lucide icons and a floating sidebar. The same tokens cover all seven routes, authentication/MFA, enrollment, device confirmations and signed-out states. Appearance persists through Mantine's color-scheme storage.

See [the visual contract](contract.md), [light desktop preview](desktop-overview-final.png), [dark desktop preview](desktop-dark.png), [mobile devices](mobile-devices-final.png) and [verification evidence](evidence.json).

## Local visual review

The following serves synthetic data only. It does not contact or authenticate against a real control plane. The fixture's response shapes follow `controlplane-ui/src/api.ts`, `api.generated.ts` and `controlplane-api/openapi.yaml`. Unmodeled routes return 501. The Postman owner-mock search was skipped because the CLI was signed out.

From the repository root, with Postman CLI 1.82 or compatible installed:

```sh
postman simulation run postman/simulations/aurora-ui/aurora-ui.sim.yaml --port 4011 --no-history
```

In another terminal:

```sh
cd controlplane-ui
VITE_CONTROL_PLANE_URL=http://127.0.0.1:4011/controlplane npm run dev -- --host 127.0.0.1 --port 5174
```

Open `http://127.0.0.1:5174`. Local fixture state can be reset to test empty, error, partial, loading and permission states. Refresh the browser after changing it:

```sh
curl -X POST http://127.0.0.1:4011/controlplane/__ui/state \
  -H 'Content-Type: application/json' \
  -d '{"fail":["devices"]}'
```

Other bodies: `{}` for populated defaults, `{"empty":true}`, `{"delay":2000}`, or `{"signedIn":false}`. The fixture ignores credentials and is only intended for local visual review. Do not deploy it.

## Verification

`npm run build` passes. All routes were rendered at 1440×1000 and 390×844 with no body overflow. Search, table keyboard scrolling, mobile navigation, appearance persistence, enrollment, device restore, policy save and configuration publication were exercised against the local HTTP fixture. Empty, delayed, failed, partially available and signed-out states were inspected. Lighthouse accessibility and best practices both scored 100 on the desktop dark overview and mobile dark policy snapshots after contrast fixes.

The frontend-design-direction evidence checker passes for `evidence.json`. These checks establish frontend behavior against the fixture; live authentication, node operations and device enrollment remain outside this UI verification. Vite still reports its advisory for a JavaScript chunk over 500 kB.
