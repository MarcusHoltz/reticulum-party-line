# ── Stage 1: build mkp224o (vanity .onion address generator) ─────────────────
# Compiled in (rather than pulled as a Docker image) so the vanity feature needs
# no Docker socket. Pinned to a fixed commit for reproducible, auditable builds.
FROM debian:bookworm-slim@sha256:0104b334637a5f19aa9c983a91b54c89887c0984081f2068983107a6f6c21eeb AS mkp224o-builder
ARG MKP224O_REF=5172c0fd71740ca0b11da8149a2575dcf331d7ab
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    gcc \
    libc6-dev \
    make \
    autoconf \
    automake \
    libsodium-dev \
    pkg-config \
    git \
    && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/cathugger/mkp224o.git /tmp/mkp224o \
    && cd /tmp/mkp224o \
    && git checkout "${MKP224O_REF}" \
    && ./autogen.sh && ./configure && make

# ── Stage 2: runtime image ───────────────────────────────────────────────────
FROM debian:bookworm-slim@sha256:0104b334637a5f19aa9c983a91b54c89887c0984081f2068983107a6f6c21eeb

RUN apt-get update && apt-get install -y --no-install-recommends \
    tor \
    opus-tools \
    socat \
    openssl \
    alsa-utils \
    pulseaudio-utils \
    qrencode \
    ncurses-bin \
    libsodium23 \
    && rm -rf /var/lib/apt/lists/*

# Vanity .onion generator (Docker-only feature). libsodium23 above is its runtime dep.
COPY --from=mkp224o-builder /tmp/mkp224o/mkp224o /usr/local/bin/mkp224o

# Tor on Debian uses the 'debian-tor' user.
# Pre-create data directories with correct permissions.
RUN mkdir -p /var/lib/tor/hidden_service /data/.partyline \
    && chmod 700 /var/lib/tor /var/lib/tor/hidden_service \
    && chown -R debian-tor:debian-tor /var/lib/tor

COPY entrypoint.sh partyline.sh /
RUN chmod +x /entrypoint.sh /partyline.sh

ENV LANG=C.UTF-8

ENTRYPOINT ["/entrypoint.sh"]
