<a href="https://gitlab.com/MarcusHoltz/reticulum-party-line"><img src="https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/header/header--partyline--reticulum-network-stack.jpg" alt="Reticulum Party Line"></a>

<table><tr>
<td><a href="https://reticulum.network/"><img src="https://img.shields.io/badge/built%20for-Reticulum-4a5e81?style=for-the-badge" alt="Built for Reticulum"></a></td>
<td><a href="https://distrobox.it/"><img src="https://img.shields.io/badge/distrobox-ready-blue?style=for-the-badge" alt="Distrobox"></a></td>
<td><a href="https://gitlab.com/MarcusHoltz/reticulum-party-line/-/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-green?style=for-the-badge" alt="License: MIT"></a></td>
<td><a href="https://gitlab.com/MarcusHoltz/reticulum-party-line"><img src="https://img.shields.io/badge/source-GitLab-orange?style=for-the-badge&logo=gitlab" alt="Source: GitLab"></a></td>
<td><a href="https://github.com/MarcusHoltz/reticulum-party-line"><img src="https://img.shields.io/badge/source-GitHub-black?style=for-the-badge&logo=github" alt="Source: GitHub"></a></td>
</tr></table>

# marcusholtz/reticulum-party-line-box

Distrobox-ready image for encrypted push-to-talk voice and group party line over [Reticulum](https://reticulum.network/manual/whatis.html). No accounts, no phone numbers, no third-party servers.

Built for [Distrobox](https://distrobox.it/), not Docker Compose. Your mic, speakers, and network are shared with the container automatically. Ideal for immutable or atomic Linux distros (Bazzite, Silverblue, SteamOS, etc.).

> For Docker Compose or standalone Docker usage, see [`marcusholtz/reticulum-party-line`](https://hub.docker.com/r/marcusholtz/reticulum-party-line).

## Supported Architectures

| Architecture | Tag |
| :---: | --- |
| x86-64 | `amd64` |

## Quick Start

### Create and enter

```bash
distrobox create --image marcusholtz/reticulum-party-line-box:latest --name partyline-rns
distrobox enter partyline-rns
```

### Run the party line

Once inside the container:

```bash
rns-party-line.sh
```

### Alternative registries

```bash
# GitHub Container Registry
distrobox create --image ghcr.io/marcusholtz/reticulum-party-line-box:latest --name partyline-rns

# GitLab Container Registry
distrobox create --image registry.gitlab.com/marcusholtz/reticulum-party-line/box:latest --name partyline-rns
```

### One-command setup with distrobox.ini

A `distrobox.ini` manifest is included in the [source repo](https://gitlab.com/MarcusHoltz/reticulum-party-line). It creates the container and exports `rns-party-line.sh` to `~/.local/bin`:

```bash
distrobox assemble create --file distrobox.ini
```

After assembly, run `rns-party-line.sh` directly from your host shell.

## First Run

1. RNS initializes and discovers network peers
2. Your Reticulum destination hash appears
3. Press **1** to set a shared secret (both sides need the same one)
4. Share your destination hash + secret, one side runs relay, the other calls

Your RNS identity persists inside the distrobox home directory across restarts.

## What's Inside

Everything pre-installed, no first-run dependency installation needed:

- Python 3.12 + [RNS](https://pypi.org/project/rns/) + [LXMF](https://pypi.org/project/lxmf/)
- Opus codec, OpenSSL, socat, FFmpeg
- PulseAudio utilities, ALSA utilities
- `pcm_rms` (compiled C audio level meter)
- `rns-party-line.sh` at `/usr/local/bin/`

## How It Differs from the Docker Image

| | Docker image | Distrobox image |
| --- | --- | --- |
| Image | `reticulum-party-line` | `reticulum-party-line-box` |
| Run with | `docker compose` / `docker run` | `distrobox create` + `distrobox enter` |
| Audio | PulseAudio socket bind-mount | Automatic host audio passthrough |
| Network | Container networking | Host network (shared) |
| User mapping | Container root | Mapped to your host user |
| Entrypoint | `docker-entrypoint.sh` | None (distrobox manages init) |

## Security

| Property | Detail |
| --- | --- |
| Encryption | AES-256-CBC + PBKDF2 + HMAC-SHA256 |
| Relay | Zero-knowledge reflector: forwards blobs, never has the secret |
| Authentication | Destination hash + pre-shared secret |
| Forward secrecy | None; rotate secrets between conversations |
| Source | Single bash script + Python RNS bridge, no telemetry |

## The Party Line Trifecta (Distrobox)

Three networks, same app, same encryption:

| | | |
|---|---|---|
| [![Reticulum Party Line](https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/header/header--partyline--reticulum-network-stack.jpg)](https://hub.docker.com/r/marcusholtz/reticulum-party-line-box) | [![Tor Party Line](https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/header/header--partyline--tor-onion-router-overlay-network.jpg)](https://hub.docker.com/r/marcusholtz/tor-party-line-box) | [![I2P Party Line](https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/header/header--partyline--invisible-internet-project-i2p-garlic-roter.jpg)](https://hub.docker.com/r/marcusholtz/i2p-party-line-box) |
| **Reticulum Party Line** | [Tor Party Line](https://hub.docker.com/r/marcusholtz/tor-party-line-box) | [I2P Party Line](https://hub.docker.com/r/marcusholtz/i2p-party-line-box) |

## License

MIT
