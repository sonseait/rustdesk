FROM rust:1.88-bookworm AS build
WORKDIR /src
COPY . .
RUN cargo build --release -p control-plane-api

FROM debian:bookworm-slim
RUN apt-get update && \
    apt-get install --no-install-recommends --yes ca-certificates curl && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --system --create-home controlplane
COPY --from=build /src/target/release/control-plane-api /usr/local/bin/control-plane-api
USER controlplane
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD curl --fail --silent --show-error http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/control-plane-api"]
