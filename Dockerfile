# ── Stage 1: pip install + pcm_rms ───────────────────────────────────────────
# gcc is needed for pip-compiled extensions and pcm_rms. Kept out of runtime.
FROM python:3.12-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libc6-dev \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir rns==1.4.2 lxmf==1.1.1

RUN printf '%s\n' \
    '#include <stdio.h>' \
    '#include <math.h>' \
    '#include <stdint.h>' \
    'int main(void) {' \
    '    int16_t buf[4096];' \
    '    double sum = 0.0;' \
    '    long count = 0;' \
    '    size_t n;' \
    '    while ((n = fread(buf, sizeof(int16_t), 4096, stdin)) > 0) {' \
    '        for (size_t i = 0; i < n; i++) {' \
    '            double s = (double)buf[i];' \
    '            sum += s * s;' \
    '        }' \
    '        count += n;' \
    '    }' \
    '    if (count == 0) { printf("-91.0\n"); return 0; }' \
    '    double rms = sqrt(sum / count);' \
    '    double dbfs = 20.0 * log10(rms / 32768.0);' \
    '    printf("%.1f\n", dbfs);' \
    '    return 0;' \
    '}' > /tmp/pcm_rms.c \
    && gcc -O2 -o /tmp/pcm_rms /tmp/pcm_rms.c -lm

# ── Stage 2: runtime image ──────────────────────────────────────────────────
FROM python:3.12-slim

# Runtime deps carried from tor-party-line (section 11.7):
#   keep:  socat, opus-tools, openssl, ffmpeg, alsa-utils, pulseaudio-utils
#   add:   rns (pip, below)
#   drop:  tor
# procps for pgrep/kill in the script; coreutils for stdbuf/timeout/etc;
# util-linux for flock (rns-party-line.sh uses it for FIFO locking).
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
        bash \
        socat \
        opus-tools \
        openssl \
        ffmpeg \
        alsa-utils \
        pulseaudio \
        pulseaudio-utils \
        procps \
        coreutils \
        util-linux \
        ca-certificates \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# lxmf is not used for messaging here. RNS gates on-network interface
# discovery behind it, and discovery is what keeps the backbone hub list from
# going stale as volunteer nodes churn (RNS_HUBS in rns-party-line.sh). Without it
# RNS logs "Using on-network interface discovery requires the LXMF module"
# at Critical and never publishes a destination.
COPY --from=builder /usr/local/lib/python3.12/site-packages/ /usr/local/lib/python3.12/site-packages/
COPY --from=builder /usr/local/bin/ /usr/local/bin/
COPY --from=builder /tmp/pcm_rms /usr/local/bin/pcm_rms

RUN useradd -m -u 1000 partyline \
    && mkdir -p /app \
    && chown partyline:partyline /app
WORKDIR /app

COPY --chown=partyline:partyline docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

COPY --chown=partyline:partyline rns-party-line.sh /app/src/rns-party-line.sh
RUN chmod +x /app/src/rns-party-line.sh

# DATA_DIR holds the tiny persistent set (shared_secret, config, RNS identity,
# destination). RUNTIME_DIR is a tmpfs mount from compose (see
# docker-compose.yml). Both are re-set in compose; kept here as documentation
# of the PLAN §20.6 split.
ENV DOCKER_MODE=1
ENV DATA_DIR=/app/data
ENV RUNTIME_DIR=/dev/shm/partyline

# ENTRYPOINT brings up a headless PulseAudio server (see docker-entrypoint.sh)
# before handing off to CMD, so rns-party-line.sh's audio backend detection finds
# something to talk to instead of "no working audio backend found".
ENTRYPOINT ["docker-entrypoint.sh"]

# Default CMD is a shell (dev). The compose file overrides this per service:
# reflector -> `rns-party-line.sh relay`; clients -> `rns-party-line.sh`.
CMD ["bash"]
