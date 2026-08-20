FROM rust:1.75-bookworm AS build
WORKDIR /src
COPY . .
RUN cargo build --release -p control-plane-api

FROM debian:bookworm-slim
RUN useradd --system --create-home controlplane
COPY --from=build /src/target/release/control-plane-api /usr/local/bin/control-plane-api
USER controlplane
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/control-plane-api"]
