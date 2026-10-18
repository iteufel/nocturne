FROM rust:1.99.1-bookworm AS build
WORKDIR /source
COPY remote/Cargo.toml remote/Cargo.lock ./
COPY remote/broker broker
COPY remote/tunnel tunnel
RUN cargo build --locked --release -p nocturne-broker

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /source/target/release/nocturne-broker /usr/local/bin/nocturne-broker
USER 10001:10001
ENV NOCTURNE_BROKER_HTTP=0.0.0.0:8080 NOCTURNE_BROKER_HTTPS=0.0.0.0:8443
EXPOSE 8080/tcp 8443/tcp 7842/udp
HEALTHCHECK --interval=30s --timeout=5s CMD curl -fsS http://127.0.0.1:8080/generate_204 || exit 1
ENTRYPOINT ["/usr/local/bin/nocturne-broker"]
