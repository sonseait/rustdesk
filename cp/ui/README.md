# RustDesk Control Plane UI

Standalone React administration portal for `../cp`.

```sh
npm install
npm run dev
```

The development server proxies `/api` to `http://127.0.0.1:8080`. Set
`VITE_API_BASE_URL` in `.env.local` when the API is hosted elsewhere. Build a
static production bundle with `npm run build`.

For production, serve this bundle and the API behind the same HTTPS origin so
the HttpOnly session cookie remains same-site. Do not put the bootstrap token
in a Vite environment variable; it is entered only for the one-time setup
request.
