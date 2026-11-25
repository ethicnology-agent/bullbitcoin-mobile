# Blockstream's electrs (Esplora API and Electrum), built from the revision
# stack.py pins (ELECTRS). Nigiri's electrs image predates POST /txs/package,
# which bark uses to broadcast a board's funding transaction, so boards
# never reached the network. Build context: the electrs checkout.
FROM docker.io/library/rust:1.92-trixie@sha256:6ca5ad23231207874325a751b9df584d51cd42c066c74c6963c264e3233c3e8e AS build
RUN apt-get update \
	&& apt-get install -y --no-install-recommends clang libclang-dev cmake \
	&& rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN cargo build --release --locked --bin electrs

FROM docker.io/library/debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0
COPY --from=build /src/target/release/electrs /usr/local/bin/electrs
ENTRYPOINT ["/usr/local/bin/electrs"]
