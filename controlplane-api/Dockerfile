FROM node:22-alpine AS ui-build
WORKDIR /ui
COPY controlplane-ui/package.json controlplane-ui/yarn.lock controlplane-ui/.yarnrc.yml ./
RUN corepack enable && yarn install --immutable
COPY controlplane-ui/ ./
RUN yarn build

FROM rust:1.88-bookworm AS build
WORKDIR /src
COPY controlplane-api/ ./
RUN cargo build --locked --release -p control-plane-api

FROM gcr.io/distroless/cc-debian12:nonroot
WORKDIR /app
COPY --from=build /src/target/release/control-plane-api /usr/local/bin/control-plane-api
COPY --from=ui-build /ui/dist /app/ui
ENV UI_DIR=/app/ui
USER nonroot:nonroot
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD ["/usr/local/bin/control-plane-api", "--healthcheck"]
ENTRYPOINT ["/usr/local/bin/control-plane-api"]
