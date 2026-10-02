<a href="https://gitlab.com/MarcusHoltz/reticulum-party-line"><img src="https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/header/header--partyline--reticulum-network-stack.jpg" alt="Reticulum Party Line"></a>

<table><tr>
<td><a href="https://reticulum.network/"><img src="https://img.shields.io/badge/built%20for-Reticulum-4a5e81?style=for-the-badge" alt="Built for Reticulum"></a></td>
<td><a href="https://gitlab.com/MarcusHoltz/reticulum-party-line/-/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-green?style=for-the-badge" alt="License: MIT"></a></td>
<td><a href="https://gitlab.com/MarcusHoltz/reticulum-party-line"><img src="https://img.shields.io/badge/source-GitLab-orange?style=for-the-badge&logo=gitlab" alt="Source: GitLab"></a></td>
<td><a href="https://github.com/MarcusHoltz/reticulum-party-line"><img src="https://img.shields.io/badge/source-GitHub-black?style=for-the-badge&logo=github" alt="Source: GitHub"></a></td>
</tr></table>

# marcusholtz/reticulum-party-line

Encrypted push-to-talk voice and group party line over [Reticulum](https://reticulum.network/manual/whatis.html). No accounts, no phone numbers, no third-party servers.

## Supported Architectures

| Architecture | Tag |
| :---: | --- |
| x86-64 | `amd64` |

## Quick Start: Interactive Calling

Pull and run the interactive menu. Make calls, listen for calls, set secrets, test audio.

### docker-compose (recommended)

Save as `docker-compose.yml`, then run `docker compose run --rm partyline`:

```yaml
services:
  partyline:
    image: marcusholtz/reticulum-party-line:latest
    container_name: reticulum-party-line
    stdin_open: true
    tty: true
    shm_size: "512m"
    security_opt:
      - label:disable
    tmpfs:
      - /dev/shm:size=512m,mode=1777
    volumes:
      - ./data:/app/data
      - ./secrets:/run/secrets:ro
      - ${XDG_RUNTIME_DIR:-/run/user/1000}/pulse:/run/user/${UID:-1000}/pulse
    environment:
      - DATA_DIR=/app/data
      - RUNTIME_DIR=/dev/shm/partyline
      - SHARED_SECRET_FILE=/run/secrets/shared_secret.txt
      - REFLECTOR_PORT=4242
      - TERM=xterm
      - PULSE_SERVER=unix:/run/user/${UID:-1000}/pulse/native
      - XDG_RUNTIME_DIR=/run/user/${UID:-1000}
    entrypoint: ["docker-entrypoint.sh", "bash", "/app/src/rns-party-line.sh"]
```

### docker cli

```bash
docker run -it --rm \
  --name reticulum-party-line \
  --security-opt label:disable \
  --shm-size 512m \
  --tmpfs /dev/shm:size=512m,mode=1777 \
  -v ./data:/app/data \
  -v ./secrets:/run/secrets:ro \
  -v ${XDG_RUNTIME_DIR}/pulse:/run/user/$(id -u)/pulse \
  -e DATA_DIR=/app/data \
  -e RUNTIME_DIR=/dev/shm/partyline \
  -e SHARED_SECRET_FILE=/run/secrets/shared_secret.txt \
  -e REFLECTOR_PORT=4242 \
  -e TERM=xterm \
  -e PULSE_SERVER=unix:/run/user/$(id -u)/pulse/native \
  -e XDG_RUNTIME_DIR=/run/user/$(id -u) \
  marcusholtz/reticulum-party-line:latest \
  docker-entrypoint.sh bash /app/src/rns-party-line.sh
```

### First run

1. RNS initializes and discovers network peers
2. Your Reticulum destination hash appears
3. Press **1** to set a shared secret (both sides need the same one)
4. Share your destination hash + secret, one side runs relay, the other calls

Your RNS identity persists in `./data/` across restarts.

## Quick Start: Headless Reflector

Run a persistent reflector daemon. Callers dial your destination hash and are bridged together.

### docker-compose

Using the same `docker-compose.yml` above, add a `reflector` profile service, or use the one from the [source repo](https://gitlab.com/MarcusHoltz/reticulum-party-line):

```bash
# Start reflector in background
docker compose --profile reflector up -d reflector

# Watch live activity
docker compose logs -f reflector

# Stop
docker compose --profile reflector down
```

### docker cli

```bash
docker run -d \
  --name reticulum-reflector \
  --restart unless-stopped \
  --security-opt label:disable \
  --shm-size 512m \
  --tmpfs /dev/shm:size=512m,mode=1777 \
  -v ./data:/app/data \
  -v ./secrets:/run/secrets:ro \
  -e DATA_DIR=/app/data \
  -e RUNTIME_DIR=/dev/shm/partyline \
  -e SHARED_SECRET_FILE=/run/secrets/shared_secret.txt \
  -e REFLECTOR_PORT=4242 \
  marcusholtz/reticulum-party-line:latest \
  docker-entrypoint.sh bash /app/src/rns-party-line.sh relay
```

No audio mounts needed for reflector mode (it forwards encrypted blobs, never decodes audio).

## Parameters

| Parameter | Function |
| :---: | --- |
| `-e SHARED_SECRET_FILE` | Path to secret file inside container. Default: `/run/secrets/shared_secret.txt` |
| `-e DATA_DIR=/app/data` | Persistent data (identity, config, secret) |
| `-e RUNTIME_DIR=/dev/shm/partyline` | Ephemeral runtime (audio, pids, RNS storage) |
| `-e REFLECTOR_PORT=4242` | Reflector listen port |
| `-e RNS_LISTEN_HOST=0.0.0.0` | Reflector bind address |
| `-e OPUS_BITRATE=16` | Opus encoding bitrate in kbps |
| `-e CIPHER=aes-256-cbc` | Encryption cipher (21 options) |
| `-e HMAC_AUTH=1` | HMAC-sign protocol messages (`0`/`1`) |
| `-e PULSE_SERVER` | PulseAudio/PipeWire socket path |
| `--shm-size 512m` | Required: audio queue and runtime dir live in `/dev/shm` |
| `-v /app/data` | Identity, secret, config (persistent) |
| `-v /run/secrets` | Shared secret file (read-only mount) |
| `-v /run/user/$UID/pulse` | Host audio socket |

## Shared Secret

The secret is **not** an environment variable. It is a bind-mounted file:

```bash
mkdir -p secrets
echo -n 'your-shared-secret' > secrets/shared_secret.txt
chmod 600 secrets/shared_secret.txt
```

Per-run override: `docker compose run --rm partyline call <dest> --secret 'my-secret'`

A reflector does not need a secret.

## Audio

The entrypoint starts a headless PulseAudio server inside the container. The host's PulseAudio/PipeWire socket mount is the route to real speakers.

```bash
arecord -l    # find capture devices on the host
aplay -l      # find playback devices on the host
```

## Security

| Property | Detail |
| --- | --- |
| Encryption | AES-256-CBC + PBKDF2 + HMAC-SHA256 |
| Relay | Zero-knowledge reflector: forwards blobs, never has the secret |
| Authentication | Destination hash + pre-shared secret |
| Forward secrecy | None; rotate secrets between conversations |
| Source | Single bash script + Python RNS bridge, no telemetry |

## The Party Line Trifecta

Three networks, same app, same encryption:

| | | |
|---|---|---|
| [![Reticulum Party Line](https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/header/header--partyline--reticulum-network-stack.jpg)](https://hub.docker.com/r/marcusholtz/reticulum-party-line) | [![Tor Party Line](https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/header/header--partyline--tor-onion-router-overlay-network.jpg)](https://hub.docker.com/r/marcusholtz/tor-party-line) | [![I2P Party Line](https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/header/header--partyline--invisible-internet-project-i2p-garlic-roter.jpg)](https://hub.docker.com/r/marcusholtz/i2p-party-line) |
| **Reticulum Party Line** | [Tor Party Line](https://hub.docker.com/r/marcusholtz/tor-party-line) | [I2P Party Line](https://hub.docker.com/r/marcusholtz/i2p-party-line) |

## License

MIT
