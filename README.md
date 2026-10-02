<h1 align="center">📡 Reticulum Party Line</h1>

<p align="center">
  <strong>Encrypted push-to-talk voice &amp; group party line over Reticulum.</strong><br>
  No accounts. No phone numbers. No third-party servers. End-to-end encrypted PTT clips over a Reticulum reflector.
</p>

---

<p align="center">
  <img src="https://img.shields.io/badge/built%20for-Reticulum-4a5e81" alt="Built on Reticulum">
  <img src="https://img.shields.io/badge/Supported%20on-Linux%20%7C%20macOS%20%7C%20Android%20%7C%20Docker-blue" alt="Supported Systems">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT">
</p>

<p align="center">
  <a href="#-quickstart">Quick Start</a> ·
  <a href="#-what-youll-see">Terminal Screen</a> ·
  <a href="#-usage">Usage</a> ·
  <a href="#-transport-backbone-vs-direct">Transport</a> ·
  <a href="#-the-embedded-bridge">Bridge</a> ·
  <a href="#%EF%B8%8F-troubleshooting">Troubleshooting</a> ·
  <a href="#-reference">Reference</a> ·
  <a href="#-faq">FAQ</a>
</p>


---

## 👍 Overview

Enjoy the experience of a walkie-talkie over [Reticulum](https://reticulum.network/manual/whatis.html#what-does-reticulum-offer). 

Want to talk? Agree on a shared secret — hold a key, speak, release. The other side hears it.

---


## The Party Line Trifecta

Three networks, one app. The Party Line ships in triplicate. Same TUI, same encryption. Pick the transport that matches your threat model:

| | | |
|---|---|---|
| [![Reticulum Party Line](https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/header/header--partyline--reticulum-network-stack.jpg)](/#) | [![Tor Party Line](https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/header/header--partyline--tor-onion-router-overlay-network.jpg)](https://gitlab.com/MarcusHoltz/tor-party-line) | [![I2P Party Line](https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/header/header--partyline--invisible-internet-project-i2p-garlic-roter.jpg)](https://gitlab.com/MarcusHoltz/i2p-party-line) |
| **Reticulum Party Line** | [Tor Party Line](https://gitlab.com/MarcusHoltz/tor-party-line) | [I2P Party Line](https://gitlab.com/MarcusHoltz/i2p-party-line) | 


<p align="center">
  <a href="https://gitlab.com/MarcusHoltz/party-line-pager">
    <img src="https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/posts/party-line-pager--tor-i2p-rns-call-pager.svg" alt="PartylinePager" width="25%">
  </a>
</p>

 <img src="https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/posts/party-line-pager--tor-i2p-rns-call-pager.svg" alt="PartylinePager" height="14"> **[PartylinePager](https://gitlab.com/MarcusHoltz/party-line-pager)** completes the suite: **Message** the party line **address** to anyone **subscribed** across **chat** networks Telegram, Matrix, Signal, IRC, XMPP, Mastodon, Email, and more.


---

## 🚀 Quickstart


### Script

Run the script.

```bash
chmod +x rns-party-line.sh && ./rns-party-line.sh
```


---

### Docker

Run docker interactively.

```bash
docker compose run --rm partyline
```

The container runs as a non-root `partyline` user (uid 1000). The
entrypoint fixes bind-mount ownership, starts a fallback PulseAudio
if no host sound server is reachable, then drops privileges via
`setpriv` before launching the app.

> **Podman / rootless Docker:** works out of the box. One cosmetic
> gotcha: without `--userns=keep-id`, bind-mounted files (the
> `data/` directory) are owned by a subordinate uid on the host
> (e.g. 100999) instead of your user. The container itself is
> unaffected. To get host-owned files, pass `--userns=keep-id`:
>
> ```bash
> podman run --rm --userns=keep-id \
>   -v ./data:/app/data \
>   <image> rns-party-line.sh
> ```


---

### Immutable distros (Bazzite, Silverblue, SteamOS, etc.)

If you're on an immutable or atomic Linux distro, use
[Distrobox](https://distrobox.it/) instead of Docker. Your mic,
speakers, and network are shared with the container automatically.

```bash
distrobox create --image debian:trixie --name partyline-rns
distrobox enter partyline-rns
```

Once inside, grab the script and run it. First run installs
dependencies (one-time, takes ~1 min):

```bash
curl -LO https://gitlab.com/MarcusHoltz/reticulum-party-line/-/raw/main/rns-party-line.sh
chmod +x rns-party-line.sh && ./rns-party-line.sh
```

A ready-to-go image with everything pre-installed is also available
from Docker Hub, GHCR, or GitLab CR:

```bash
# Docker Hub
distrobox create --image marcusholtz/reticulum-party-line-box:latest --name partyline-rns

# GitHub Container Registry
distrobox create --image ghcr.io/marcusholtz/reticulum-party-line-box:latest --name partyline-rns

# GitLab Container Registry
distrobox create --image registry.gitlab.com/marcusholtz/reticulum-party-line/box:latest --name partyline-rns
```

Then enter and run:

```bash
distrobox enter partyline-rns
rns-party-line.sh
```

> A `distrobox.ini` file is included in the repo for one-command
> setup: `distrobox assemble create --file distrobox.ini`

#### Where distrobox keeps your data

The distrobox image stores persistent state in the XDG data directory on
your **host** filesystem, following the same convention as Universal Blue
images:

```
~/.local/share/reticulum-party-line/
├── config          saved options
├── shared_secret   pre-shared secret (chmod 600)
├── identity        RNS identity file (64 bytes; the crypto signature)
└── destination     your destination address
```

Ephemeral data (audio, FIFOs, `run/`, `pids/`, RNS storage, the bridge)
goes to `RUNTIME_DIR`, a tmpfs at `/dev/shm/partyline-$$` by default, and
never touches disk.

Distrobox bind-mounts your home, so this path is a real directory on your
disk, not a container layer. Your identity survives `distrobox rm` and
container replacement, and travels with your home directory if you move it
to another machine. Back up `identity` — losing it means a new
destination. Override the location with `DATA_DIR`:

```bash
DATA_DIR=/mnt/secure/reticulum-party-line rns-party-line.sh
```


---

### On first run

1. 📡 Your Reticulum destination hash is generated and displayed

2. 🔑 Press **1** -> set a shared secret (both callers need the same one)

3. 📡 Share your destination hash + secret -> one side listens, the other calls

---

## 📺 What You'll See

**Main menu** — after the shared secret is set and a reflector has been started at least once:

```text
  ╦═╗╔╗╔╔═╗  ╔═╗┌─┐┬─┐┌┬┐┬ ┬  ╦  ┬┌┐┌┌─┐
  ╠╦╝║║║╚═╗  ╠═╝├─┤├┬┘ │ └┬┘  ║  ││││├┤ 
  ╩╚═╝╚╝╚═╝  ╩  ┴ ┴┴└─ ┴  ┴   ╩═╝┴┘└┘└─┘
          Reticulum Network Stack
  
  ───────────────────────────────────────────
  Address: 3a1c9d4e07b21f88c2a04e7d612b0f4e
  Secret: ●  RNS: ●  Auto-listen: ●  PTT: [SPACE]
  ▸ Ready. Press 4 to listen, or 5 to call.

  ═══ SETUP ═══
  1 │ Set shared secret   (both ends need the same secret)
  2 │ Audio setup & test  (mic, speakers, diagnostics)
  3 │ Share my address    (QR code)
    ─────────────────────────────────────
  ═══ CALL ═══
  4 │ Listen for calls
  5 │ Call a relay address
  6 │ Host party line     (relay / group bridge)
    ─────────────────────────────────────
  ═══ SYSTEM ═══
  7 │ Settings
  8 │ Status
  9 │ Install dependencies       (script mode)
  n │ New identity (rotate)      (script mode)
  u │ Uninstall                  (script mode)
    ─────────────────────────────────────
  0 │ Exit

  Select:
```

<table>
<tr>
<td width="50%" valign="top">

**In a call** — 1-to-1, connected:

```text
 CALL CONNECTED  3a1c9d4e...b0f4e

  ● Local cipher:  AES-256-CBC
  ● Remote cipher: AES-256-CBC

  Last sent:  --
  Last recv:  --
  Remote:     Idle

   Ready  [SPACE]=Talk [T]=Chat [S]=Settings [Q]=Hang up
```

</td>
<td width="50%" valign="top">

**Hosting a party line** — live caller count:

```text
 CALL CONNECTED

  ● Local cipher:  AES-256-CBC
  ● Mode:          RELAY (group call)

  Group:      4 callers

   Ready  [SPACE]=Talk [T]=Chat [S]=Settings [Q]=Hang up
```

</td>
</tr>
</table>

---

## 📖 Usage

Now that you're up and running... let's dive into how you can *really* use this Reticulum Party Line!


---

### Sharing your address + secret

Before a call, both people need your Reticulum destination hash **and** the shared secret. Hashes are 32 hex characters, no suffix:

```text
address: 3a1c9d4e07b21f88c2a04e7d612b0f4e
secret: your-shared-secret-here
```

The safest handoff is a one-time link that self-destructs after a single read, so the plaintext is never stored:

> Try [yopass.se](https://share.yopass.se) <--- click the link! It is free, open-source, and [self-hostable](https://github.com/jhaals/yopass).


---

### Menu reference

| Key | Action |
|-----|--------|
| 1 | Set shared secret (required before any call is heard) |
| 2 | Audio setup &amp; test |
| 3 | Share my address (QR code) |
| 4 | Listen for a call |
| 5 | Call a relay address |
| 6 | Host party line (group bridge) |
| 7 | Settings (cipher, bitrate, PTT mode, HMAC, audio, security) |
| 8 | Status (address, config) |
| 0 | Exit |

Script-only: `9` install deps · `n` rotate identity · `u` uninstall.


---

### In-call keys

| Key | Action |
|-----|--------|
| **Hold SPACE** | Record; sends on release (hold-to-talk) |
| **T** | Send encrypted text |
| **S** | Mid-call settings (fix audio, change push-to-talk) |
| **M** | Mute/unmute mic (full-duplex only) |
| **Q** | Hang up |

> **Hold-to-talk:** press SPACE, wait a beat, *then* speak; release to send.

> Prefer tap-to-talk? Make that change! -> **Settings -> 4 (PTT mode) -> toggle**: tap to start, tap to stop and send. Android uses toggle automatically (its keyboard fires on key release, not press).


---

### Script commands &amp; flags

```text
Commands: listen | call [ADDR] | relay | status | test | config | install | uninstall | help

  -s, --secret S        Shared secret this run (must match all parties)
      --save-secret     Persist --secret to disk (chmod 600)
  -a, --address ADDR    Relay address (32-char hex) to call
  -c, --cipher NAME     OpenSSL cipher (aes-256-cbc, chacha20…)        [aes-256-cbc]
  -b, --bitrate N       Opus bitrate kbps                              [16]
      --hmac            HMAC-sign protocol messages   (--no-hmac)      [on]
      --auto-listen     Auto-listen at startup        (--no-auto-listen) [off]
      --dial-attempts N Retry initial dial N times                      [3]
      --dial-timeout N  Per-attempt connect timeout in seconds          [60]
      --full-duplex    Live bidirectional audio (TCP only) (--no-full-duplex)[off]
      --start-muted    Begin full-duplex calls muted     (--no-start-muted)[on]
      --save            Persist all supplied options to config
  -h, --help   -V, --version
```

Full-duplex mode replaces push-to-talk with live bidirectional audio.
It requires TCP-class transport (backbone hubs or LAN); LoRa and packet
radio cannot sustain the bandwidth.

By default, full-duplex sessions start muted. Press **[M]** to unmute
when ready to speak. To start with the mic live, pass `--no-start-muted`
or toggle in **Settings > f (Start muted)**.

```bash
# Full-duplex mode (requires TCP-class transport: backbone or LAN)
docker compose run --rm partyline relay --full-duplex
docker compose run --rm partyline call <dest-hash> --full-duplex --secret 'shhhsecretshere'
```

The transport itself is configured through environment variables — usually via `docker-compose.yml` or an `.env` file — because reflector host, port, and identity file are per-deployment rather than per-invocation:

| Variable | Default | Purpose |
|----------|---------|---------|
| `RNS_HUBS` | 5 seeded public nodes | Comma-separated `host:port` backbone transport nodes, dialled outbound by both roles. The no-open-ports path. Set to `""` to disable and force direct mode. |
| `RNS_AUTOCONNECT` | `4` | Max additional backbone peers RNS may discover and connect to on top of `RNS_HUBS`. Needs `lxmf`; ignored without it. |
| `REFLECTOR_HOST` | *(unset)* | Direct-dial target host. Setting it **bypasses the backbone entirely** and dials this host on `REFLECTOR_PORT`. For LAN and airgapped use. |
| `REFLECTOR_PORT` | `4242` | TCP transport port for direct mode, both roles |
| `RNS_LISTEN_HOST` | `0.0.0.0` | Bind IP for the reflector's TCPServerInterface |
| `RNS_IDENTITY_FILE` | `$DATA_DIR/identity` | Persistent identity (64 bytes; the crypto signature) |
| `RUNTIME_DIR` | `/dev/shm/partyline-$$` | Ephemeral tmpfs for audio, FIFOs, RNS storage |
| `DATA_DIR` | `/app/data` (Docker), `$XDG_DATA_HOME/reticulum-party-line` (distrobox) | Persistent: shared secret, config, identity, address |

---

## 🌐 Transport: backbone vs direct

Two ways to reach a relay. `REFLECTOR_HOST` picks between them.

| | Backbone (default) | Direct (`REFLECTOR_HOST` set) |
|---|---|---|
| Caller needs | The 32-hex address | The address **and** your host:port |
| Open ports | None, either end | `REFLECTOR_PORT` inbound on the relay |
| Works behind NAT/CGNAT | Yes | Only with port forwarding |
| Path | Out to `RNS_HUBS`, routed across the Reticulum backbone | One TCP hop, client to relay |
| Use when | Anything over the internet | LAN, airgapped, or compose-internal testing |

Backbone mode is on by default: `RNS_HUBS` seeds five public transport nodes and RNS connects out to all of them. Setting `REFLECTOR_HOST` bypasses the backbone completely and dials that host instead. Emptying `RNS_HUBS` with no `REFLECTOR_HOST` leaves no transport at all, and the client says so rather than hanging.

Hub churn is the one thing to watch. These are volunteer nodes and they come and go. `RNS_AUTOCONNECT` (default 4) lets RNS discover and attach to that many additional backbone peers on its own, so the seeded list going stale degrades gracefully instead of stranding you. That needs `lxmf` installed; the bridge drops discovery quietly if it is missing. Current node list: <https://directory.rns.recipes/>.

```bash
# Override the seeds
RNS_HUBS='rns.example.org:4242,other.example:4965' ./rns-party-line.sh relay

# Force direct mode (LAN, no backbone)
REFLECTOR_HOST=192.168.1.50 ./rns-party-line.sh call <hash>

# Backbone only, no discovery
RNS_AUTOCONNECT=0 ./rns-party-line.sh relay
```

---

## 🧩 The embedded bridge

`rns-party-line.sh` is the whole program. The RNS transport bridge (`rns_bridge.py`) lives as a quoted heredoc inside `_emit_rns_bridge()` — the marker is single-quoted, so the body is copied out byte for byte with no expansion and no escaping. At startup, `write_rns_bridge()` extracts that heredoc to `$RUNTIME_DIR/rns_bridge.py` (tmpfs) and runs it from there. The heredoc is the single source of truth: a clone of this repo needs nothing else to run the bridge.

If you want to hand-edit the bridge with real tooling instead of pasting into the heredoc: `write_rns_bridge()` will use a `rns_bridge.py` file placed next to `rns-party-line.sh` (`BRIDGE_PY_SOURCE`) in place of the heredoc whenever one exists, and ignores it otherwise. This file is never shipped and never tracked in git, so a clone or a released single file always runs the embedded heredoc.

A pre-commit hook validates the staged `rns-party-line.sh`: it must be valid bash and the embedded bridge must be valid Python. Enable it once per clone:

```bash
git config core.hooksPath .githooks
```

Override with `git commit --no-verify` if you must.

---

## 🔨 Troubleshooting

Say it isn't so, this script didn't work instantly? Woe is not without effort:


---

### Sharing address + secret

Getting your destination hash and secret to someone, securely. Hand them a one-time link that self-destructs after one read. Both sides set the same secret (menu -> **1**), then one listens, one calls.

> Visit: **[yopass.se](https://share.yopass.se)** -> paste `address:` + `secret:`, set a 1-hour expiry, send the link.


---

### No sound / silence on calls

Almost always the wrong input/output device. Full instructions live under [Audio setup](#audio-setup) in the reference. First stop: Settings → 7 → Audio devices → **4 (Test all outputs)** and pick the number you actually hear.

**Separate the two ends before you go hunting.** *Test all outputs* plays locally
generated noise, so hearing it proves only that playback works. `./rns-party-line.sh
test` records from the mic and plays that back, which is the half that usually
fails. If option 4 is audible but the loopback test is not, the problem is
capture, not playback.

`./rns-party-line.sh test` now checks this for you: a capture that is entirely zero
bytes is reported as `Captured N bytes, but every one of them is silence`,
along with the input device it came from. A dead capture device still fills the
file with zeros, so without that check every later step succeeds on silence and
the test reports success while you hear nothing.

**In a live call the same check runs on every push-to-talk.** If your clip came
back silent, the `Last sent:` row reads `SILENT (no mic)` instead of a size and
nothing is transmitted. Without it a dead mic is invisible to the person
talking: the clip encodes, encrypts and fans out normally, and only the
listeners know. If you see that row, your input device is the problem, not the
call.

The most common cause under Docker is an image built before the audio fix: its
entrypoint pointed the default source at `partyline_null.monitor`, so every
recording is silence by construction. Rebuild with `docker compose build`
and confirm with `docker compose run --rm partyline test` that your mic
is working, or check sources with `docker compose --profile shell run --rm
shell pactl list short sources`.

### Your desktop's own audio broke after running Docker

Symptom, on the **host**:

```console
$ pactl info | grep Default
Default Sink: partyline_null
Default Source: partyline_null.monitor
```

An image built before the host-audio fix, run against a compose file that sets
`PULSE_SERVER`, is a bad combination. The old entrypoint ran `pactl
load-module module-null-sink` and `pactl set-default-sink/source` with
`PULSE_SERVER` already pointing at *your* sound server, so it repointed your
desktop's default input and output at a null sink. Every `docker compose run`
leaked one more module, and they persist until the session restarts.

Clean up on the host:

```bash
# Unload every leaked null sink (repeat until the grep comes back empty)
pactl list short modules | grep module-null-sink | \
    awk '{print $1}' | xargs -r -n1 pactl unload-module

# Point the defaults back at real hardware
pactl list short sinks
pactl list short sources
pactl set-default-sink   alsa_output.pci-0000_00_14.2.analog-stereo
pactl set-default-source alsa_input.pci-0000_00_14.2.analog-stereo
```

On PipeWire the two `set-default-*` lines are usually unnecessary: unloading the
leaked modules is enough, and PipeWire re-picks real hardware defaults on its own
the moment the null sinks disappear. Run `pactl get-default-sink` and
`pactl get-default-source` after the unload and only set them by hand if they
still name `partyline_null`. Verified on PipeWire with 7 leaked modules.

Then `docker compose build shell` so the container stops doing it. The current
entrypoint checks for a reachable host server first and, when it finds one,
uses it verbatim and loads no modules at all. The null-sink fallback only runs
when no server is reachable, and unsets `PULSE_SERVER` before touching
anything, so it can no longer reach your session.

---

### Remote hears nothing / red ● in call header

**Cipher mismatch** — decryption fails silently when both sides differ. Agree on the same cipher in Settings, or change mid-call via **S -> Settings**.


---

### Client says "no path" or the dial times out

The client's Reticulum instance needs to discover the reflector's destination hash before it can open a link. Two things to check:

1. **Backbone reachable.** By default both ends dial out to `RNS_HUBS`. Check option **8**, which reports how many hubs are seeded. If every seeded node is dead, calls fail with no path even though nothing is misconfigured: refresh the list from <https://directory.rns.recipes/>. If `REFLECTOR_HOST` is set you are in direct mode instead, and the client must be able to reach that host on `REFLECTOR_PORT` (under compose, the service name `reflector` is the hostname).
2. **The reflector has announced at least once.** Reflectors announce on startup and then every 5 minutes (`PARTYLINE_ANNOUNCE_S`). Watch the reflector's log, you should see it publish `DEST_HASH=...` within seconds of boot.


---

### Call hangs on "Connecting..."

**Symptom:** One client sits at `Connecting... 25s (1/3)` while other
clients connect to the same relay immediately.

**Cause:** Reticulum path discovery or link establishment failed on the
chosen route. The bridge process is alive, but the path is unreachable or
the link handshake stalled.

**What the app does:** Automatically retries up to `DIAL_ATTEMPTS` times
(default 3), killing the bridge between attempts to force a fresh path
resolution. Progress shows elapsed time and attempt number. Most connections
that fail on attempt 1 succeed on attempt 2.

**If all attempts fail:** The peer is probably offline or the destination
hash is not announced on any reachable transport node. Check option 8 for
backbone status and verify the relay has announced at least once.

**Tuning:** `--dial-timeout` controls how long each attempt waits (default
60s, sized to exceed the bridge's internal path + link timeouts). `--dial-attempts`
controls how many retries. Lower timeout = faster feedback loop but risks
killing attempts that would have succeeded. Persist with `--save`.


---

### Truncated audio, silent drops, "resource concluded with 0 bytes"

Very unlikely on a direct TCP path: the [measured Reticulum link](#architecture) holds an ~8 KB MDU per packet, so a typical 20 KB PTT clip fits inside a single window even at the SLOW rate class. If it *does* fail, the `AUDIO:` blob is carried over `RNS.Resource`, which fails loudly with `FAILED` / `CORRUPT` rather than silently. Check the bridge log at `$RUNTIME_DIR/relay/bridge.stderr` for the reason.


---

### Android call drops with the screen off

The app holds a partial wakelock via `termux-wake-lock`. Install **Termux:API** from [F-Droid](https://f-droid.org/en/packages/com.termux.api/) (not the Play Store), then `pkg install termux-api`. Android Settings → Apps → Termux → Battery → **Unrestricted**. Genuine drops auto-reconnect silently up to `RECONNECT_ATTEMPTS` times.


---


## I hear a brief pause mid-message on Android

Nothing is wrong. Messages longer than `PTT_CHUNK_SECONDS` (default 10 s) are split into chunks and played back sequentially. There is a ~300 ms gap between chunks while the media player loads the next file; the audio resumes exactly where it left off.


---

### Running automated headless deployments

Skip the menu. Pass flags directly. No interactive prompts. Works on Docker and Script.


#### Run-once commands, removed when done

`docker compose run --rm` runs, exits when complete, as if running the script.

```bash
# Place a call
docker compose run --rm partyline call 3a1c9d4e07b21f88c2a04e7d612b0f4e --secret 'shhhsecretshere'

# 1-to-1: listen for an incoming call
docker compose run --rm partyline listen --secret 'shhhsecretshere'

# Diagnostics
docker compose run --rm partyline test
docker compose run --rm partyline status
```


#### Save some settings, then run without those flags

```bash
docker compose run --rm partyline config --secret 'shhhsecretshere' --hmac --save
docker compose run --rm partyline call 3a1c9d4e07b21f88c2a04e7d612b0f4e
```
> a destination hash is required per call; everything else above is saved and remembered


#### Headless reflector (always-on group bridge)

A headless reflector is available behind a compose profile. Callers dial your destination hash and are bridged together... in a PARTY LINE!

```bash
docker compose --profile reflector up -d reflector    # start relay in background
docker compose --profile reflector logs -f reflector  # watch live activity
docker compose --profile reflector restart reflector  # reload without losing your address
docker compose --profile reflector down               # stop everything
```

The reflector prints `Relay address: 3a1c...4e2b` on startup. Share that hash and the shared secret.


#### Running this script detached, no auto-restart

You can apply any of the script's commands:

```bash
docker compose run -d partyline relay
```

To reattach to the running container's interactive session:

```bash
docker attach <container_id_or_name>
```

- Press **Ctrl+P then Ctrl+Q** to detach again without stopping the container.
- **Ctrl+C** will terminate the process inside the container, use with caution.

> Script usage is identical: `./rns-party-line.sh call <hash> --secret 'shhhsecretshere'`. For more info, see [Configuration & defaults](#config-and-defaults)


---

### Anti-flood limits

Tune any of these in the [Reference](#-reference) tables.

- Push-to-talk **auto-stops at `MAX_PTT_SECONDS`** (default 120 s) even if you keep holding — release and press again to continue. A clip over the size cap shows **`too long`** instead of sending.
- Text messages are length-capped, and on a group call the relay **rate-limits each caller** (default 15 messages/sec), so holding a key down or pasting a wall of text won't flood or mute the room — the excess is silently dropped.


---


### Environment variable use

Environment variable take a precedence order: 

1. built-in defaults

2. .env

3. saved config

4. CLI flags

---

## 📚 Reference

<details id="audio-setup">
<summary><strong>Audio setup (all platforms)</strong></summary>

<br>

| Platform | Backend | Device selection |
|----------|---------|-----------------|
| Linux Script | PipeWire → PulseAudio → ALSA (auto) | Desktop sound settings, in-app picker, or env vars |
| Linux Docker | Host sound server over the bind-mounted PulseAudio socket | Desktop sound settings, in-app picker, or env vars |
| Android/Termux | termux-microphone-record + ffplay | OS routes automatically |
| macOS | ffmpeg (AVFoundation) | System Settings → Sound |

**Linux — in-app picker:** Settings → 7 → Audio devices. Lists devices by friendly name and offers *System default* (routes through your sound server to whatever you selected in your desktop settings — right for almost everyone). `← current` marks the active device; `[HDMI]` flags display-audio outputs.

**Backend order:** sound server (`parecord`/`paplay`, works with both [PulseAudio](https://www.freedesktop.org/wiki/Software/PulseAudio/) and [PipeWire](https://pipewire.org/)) → [ALSA](https://www.alsa-project.org/) direct.

**Docker audio comes from the host.** A container has no sound hardware, so
`docker-compose.yml` bind-mounts the host's PulseAudio / pipewire-pulse socket
(`$XDG_RUNTIME_DIR/pulse`) and points `PULSE_SERVER` at it. The container then
plays and records through your desktop's live audio session, exactly as the
script does. Two consequences:

- If your host uid is not 1000, set `UID=$(id -u)` in `.env`, or the socket
  path inside the container won't match.
- On Fedora/RHEL with SELinux enforcing, `security_opt: label:disable` (already
  set in the compose file) is required. Without it `container_t` is denied
  write access to the socket and `paplay`/`parecord` fail silently, which looks
  exactly like "audio is broken".

With no socket mounted (a headless relay, CI), `docker-entrypoint.sh` falls
back to a throwaway in-container PulseAudio with a null sink. That keeps
backend detection from erroring out, but **nothing played through it is
audible** — it is a black hole by design. If you can pass data but hear
nothing in Docker, check that the socket mount is present first.

For a bare-ALSA host with no sound server, uncomment the `devices: /dev/snd`
block in `docker-compose.yml` instead. It ships commented out because a host
with no `/dev/snd` (headless server, most VMs) makes `docker compose up` fail
on the missing device.

**Verify the full pipeline:**
```bash
docker compose run --rm shell bash /app/src/rns-party-line.sh test   # Docker
./rns-party-line.sh test                                             # Script
```
Records 3 s, Opus-encodes, encrypts, decrypts, plays back. Hear yourself = the whole pipeline works.
It now stops early and names the input device if the recording came back silent.

**Forcing a specific ALSA device** (headless / bare-ALSA / Docker):
```bash
ALSA_DEVICE=plughw:1,0 ./rns-party-line.sh    # Script, inline
# Docker: set in .env
ALSA_DEVICE=plughw:0,0        # mic
ALSA_PLAY_DEVICE=plughw:0,0   # speakers
```
Find the numbers on the **host** (not inside Docker): `arecord -l` (mics), `aplay -l` (speakers).

**Android / Termux:** the OS controls routing — no per-device selection. Needs Termux + **Termux:API from F-Droid**, then `pkg install termux-api`.

**macOS:** select input/output in **System Settings → Sound** before launch. [`ffmpeg`](https://ffmpeg.org/) routes through AVFoundation automatically.

</details>


<details id="config-and-defaults">
<summary><strong>Configuration &amp; defaults</strong></summary>

<br>

Settings precedence (lowest → highest): **built-in defaults → `.env`** (Docker only) **→ saved config** (`$DATA_DIR/config`) **→ CLI flags**.

**Reticulum transport**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `RNS_HUBS` | 5 seeded public nodes | Comma-separated `host:port` backbone transport nodes, dialled outbound by both roles. The no-open-ports path. Set to `""` to disable and force direct mode. |
| `RNS_AUTOCONNECT` | `4` | Max additional backbone peers RNS may discover and connect to on top of `RNS_HUBS`. Needs `lxmf`; ignored without it. |
| `REFLECTOR_HOST` | *(unset)* | Direct-dial target host. Setting it **bypasses the backbone entirely** and dials this host on `REFLECTOR_PORT`. For LAN and airgapped use. |
| `REFLECTOR_PORT` | `4242` | TCP transport port for direct mode, both roles |
| `RNS_LISTEN_HOST` | `0.0.0.0` | Bind IP for the reflector's TCPServerInterface |
| `RNS_IDENTITY_FILE` | `$DATA_DIR/identity` | Persistent identity file (64 bytes) |
| `RNS_CONFIG_DIR` | `$RUNTIME_DIR/reticulum` | RNS storage (path table, announce cache, transport identity) — ephemeral |
| `BRIDGE_PY` | `$RUNTIME_DIR/rns_bridge.py` | Where `rns-party-line.sh` emits its embedded bridge |
| `BRIDGE_PY_SOURCE` | `$BASE_DIR/rns_bridge.py` | Dev shortcut. If this file exists it is copied instead of the embed, so scratch edits take effect without re-embedding. `rns_bridge.py` is untracked, so a clone or a released single file always runs the embed. Set to `""` to force the embed. |
| `BRIDGE_PYTHON` | `python3` | Interpreter used to run the bridge |
| `PARTYLINE_ANNOUNCE_S` | `300` | Seconds between destination announces |

**Data directories**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `DATA_DIR` | `/app/data` (Docker), `$XDG_DATA_HOME/reticulum-party-line` (distrobox), `./data/script` (host) | Persistent: `shared_secret`, `config`, `identity`, `destination` |
| `RUNTIME_DIR` | `/dev/shm/partyline-$$` | Ephemeral tmpfs: `audio/`, `run/`, `pids/`, RNS `storage/`, emitted `rns_bridge.py` |

Everything under `RUNTIME_DIR` is wiped on process exit. Only the four small files under `DATA_DIR` survive a reboot.

**Audio / codec / behaviour**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `OPUS_BITRATE` | `16` | Opus encoding bitrate (kbps) |
| `CIPHER` | `aes-256-cbc` | Encryption cipher |
| `AUTO_LISTEN` | `0` | Start listening automatically at startup |
| `PTT_KEY` | `SPACE` | Push-to-talk key |
| `PTT_TOGGLE_MODE` | `0` | `0` = hold-to-talk, `1` = tap-start/tap-stop toggle |
| `HMAC_AUTH` | `1` | HMAC-sign all protocol messages (both sides must match) |
| `OVERWRITE_DELETE` | `0` | Overwrite persistent temp files with random bytes before deletion |
| `SAMPLE_RATE` | `8000` | Audio sample rate (Hz) |
| `ALSA_DEVICE` | *(empty)* | Force a specific ALSA capture device (e.g. `plughw:1,0`); bypasses sound server |
| `ALSA_PLAY_DEVICE` | *(empty)* | Force a specific ALSA playback device |
| `PULSE_SOURCE` | *(empty)* | PipeWire/PulseAudio capture device name; empty = system default |
| `PULSE_SINK` | *(empty)* | PipeWire/PulseAudio playback device name; empty = system default |

**Keepalive &amp; anti-flood**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `RELAY_IDLE_TIMEOUT` | `240` | Drop a caller after this many seconds of total silence |
| `HEARTBEAT_INTERVAL` | `20` | Keepalive PING interval |
| `CLIENT_TIMEOUT` | `180` | No inbound traffic this long = dropped; tear down + reconnect |
| `RECONNECT_ATTEMPTS` | `3` | Silent re-dials after a drop; `0` disables auto-reconnect |
| `DIAL_ATTEMPTS` | `3` | Retry initial dial this many times before giving up (re-launches the bridge on each retry) |
| `DIAL_TIMEOUT` | `60` | Per-attempt connect timeout in seconds; must exceed bridge internals (`--path-timeout` 30 + `--link-timeout` 20 = 50 s) |
| `MAX_PTT_SECONDS` | `120` | Hard cap on one push-to-talk transmission |
| `MAX_AUDIO_B64` | `MAX_LINE_BYTES` | Sender skips an AUDIO blob over this (base64 bytes); defaults to the relay line cap |
| `MAX_LINE_BYTES` | `524288` | Relay drops any inbound line larger than this before forwarding |
| `MAX_MSG_B64` | `65536` | Receiving client drops a text MSG whose base64 exceeds this |
| `RELAY_MAX_MSG_PER_SEC` | `15` | Relay drops a caller's messages beyond this rate |
| `RELAY_MAX_INFLIGHT` | `64` | Caps concurrent background forwards per caller |
| `RELAY_WRITE_TIMEOUT` | `30` | Seconds before the relay abandons a write to a stalled client |
| `DECRYPT_TIMEOUT` | `10` | Seconds before killing a stalled `openssl` decrypt process |
| `PTT_CHUNK_SECONDS` | `10` | Split PTT audio into chunks of this many seconds before encoding and sending |

`.env` is read **only by Docker Compose** (the script ignores it). Every CLI flag has a matching `.env` variable; booleans are `0`/`1`.

</details>


<details id="shared-secret-docker">
<summary><strong>Shared secret (Docker)</strong></summary>

<br>

The shared secret is deliberately **not** an environment variable - env values leak via `docker inspect`, `/proc/<pid>/environ`, and logs. Instead the `secrets/` directory is **bind-mounted read-only** into the container and the app reads the secret from a file.

`secrets/shared_secret.txt` is **git-ignored**, so your real secret is never tracked or committed. An absent or empty file means "no secret set" - a relay needs none, and `--secret` always takes precedence.

```bash
# Per run (overrides the file):
docker compose run --rm partyline call <hash> --secret 'your-secret'

# Or persist once (used by every run):
echo -n 'your-secret' > secrets/shared_secret.txt   # -n strips the trailing newline
chmod 600 secrets/shared_secret.txt
```

`docker-compose.yml` already wires it up:

```yaml
services:
  partyline:
    volumes:
      - ./secrets:/run/secrets:ro                          # dir mounted read-only; the file is optional
    environment:
      SHARED_SECRET_FILE: /run/secrets/shared_secret.txt   # app reads from here
```

> A directory bind mount is used on purpose: a Compose `secrets:` file source must exist or `docker compose up` fails, which would force the secret file to be committed. Mounting the directory works on a fresh clone even when the file doesn't exist yet.

**Precedence (highest first):** `--secret` flag -> `SHARED_SECRET_FILE` (the bind-mounted file) -> saved secret (`$DATA_DIR/shared_secret`) -> interactive prompt. The `secrets/` directory is git-ignored, so your real secret is never committed.

**SELinux (Fedora/RHEL):** `docker-compose.yml` sets `security_opt: label:disable`, which runs the container as `spc_t` (unconfined), so it can read the secrets mount without a `:z` relabel. It also covers PulseAudio socket access. Without it you'd see an AVC denial on the secrets file.

Rebuild after a code change: `docker compose build`.

</details>


<details id="your-identity-backup--restore">
<summary><strong>Your Reticulum identity (backup / restore / rotate)</strong></summary>

<br>

Your identity is a **64-byte file** at `$RNS_IDENTITY_FILE` (default `$DATA_DIR/identity`). The 32-hex destination hash printed to callers is derived from that identity plus the app-name/aspects tuple, so as long as the file survives, your address survives.

```bash
# Show your address (published on first menu launch, no listener needed)
cat data/destination

# Back up your identity (both files fit in a text message)
cp data/identity      identity.backup
cp data/destination   destination.backup

# Restore
cp identity.backup      data/identity
cp destination.backup   data/destination
chmod 600 data/identity
```

**Change your address:** menu **n** (script mode) — deletes the identity and destination files, immediately generates a fresh identity, and prints the new destination hash before you leave the screen. A running auto-listener is restarted so it announces the new address. The old address stops resolving as soon as this node stops announcing it; any peers holding it in their path table will fail over on retry.

**Vanity addresses:** not available. Reticulum destination hashes are derived from the identity's public key, so pretty-prefix mining would require brute-forcing keypairs against 128 bits of destination-hash entropy. The [tor-party-line vanity feature](https://github.com/MarcusHoltz/tor-party-line) — which works because Tor's 56-char v3 addresses embed 32 bytes of Ed25519 public key — has no equivalent here.

</details>


<details>
<summary><strong>Running Script (no Docker)</strong></summary>

<br>

```bash
chmod +x rns-party-line.sh
./rns-party-line.sh
```

Auto-detects your platform and offers to install dependencies via your package manager (you're asked before anything is installed). Undo everything with `./rns-party-line.sh uninstall`.

| Platform | Package manager | Audio |
|----------|----------------|-------|
| Linux | apt / dnf / pacman | PulseAudio/PipeWire (`parecord`/`paplay`), ALSA fallback |
| macOS | Homebrew (auto-installed) | ffmpeg |
| Android/Termux | `pkg` | termux-microphone-record |

**RNS goes in a private venv, not your system Python.** Menu option 9 creates one at `$DATA_DIR/venv` (`./data/script/venv` by default) and installs `rns` plus `lxmf` there. Most current distros ship a [PEP 668](https://peps.python.org/pep-0668/) "externally managed" interpreter (Arch, Debian 12+, Fedora 38+) that refuses a bare `pip install rns` outright, and Arch ships no system `pip` at all. The venv behaves identically everywhere and touches no system packages. It also makes uninstall exact: removing the data directory removes RNS with it.

Set `BRIDGE_PYTHON` to override the interpreter if you manage RNS yourself. If no venv exists, a system-wide RNS is used as before. Termux is the one exception and still installs via plain `pip` into its prefix, since it has no PEP 668 marker.

`lxmf` is optional but installed by default. RNS gates on-network peer discovery behind it, so without it you are limited to the hubs seeded in `RNS_HUBS` and get no automatic replacement as volunteer nodes go offline. The bridge detects its absence and silently drops discovery rather than failing.

</details>


<details>
<summary><strong>What gets installed</strong></summary>

<br>

Docker bundles everything — skip this. Script/Termux: the script asks before installing.

| Package | What it does |
|---------|-------------|
| [**rns**](https://reticulum.network/) (Python) | The Reticulum transport itself; pip-installed into the private venv at `$DATA_DIR/venv` |
| [**lxmf**](https://github.com/markqvist/LXMF) (Python) | Optional. Enables backbone peer discovery; installed alongside `rns` |
| [**python3**](https://www.python.org/) | Runs the embedded `rns_bridge.py` bridge |
| [**opus-tools**](https://opus-codec.org/) (`opusenc`/`opusdec`) | Compresses voice ~10× for the wire |
| [**socat**](http://www.dest-unreach.org/socat/) | Still used to plumb the client-side FIFOs |
| [**openssl**](https://www.openssl.org/) | AES-256-CBC encryption + HMAC-SHA256 signing |
| **pulseaudio-utils** (`parecord`/`paplay`) | Sound-server audio (PulseAudio + PipeWire) |
| **alsa-utils** (`arecord`/`aplay`) | ALSA direct fallback (headless/Docker) |
| [**ffmpeg**](https://ffmpeg.org/) / **ffplay** | Audio on macOS (AVFoundation) and Android/Termux |
| [**qrencode**](https://fukuchi.org/works/qrencode/) | Destination-hash QR code in the terminal (optional) |
| **termux-api** *(Android only)* | Mic access + `termux-wake-lock`. Install from F-Droid |


</details>


<details>
<summary><strong>Party line capacity</strong></summary>

<br>

Bandwidth is still the ceiling, but Reticulum with `RNS.Resource` in-window transfer is dramatically more capable than the ~5 KB/s Tor path. On a measured direct `TCPClientInterface` link (see [Architecture](#architecture)):

- `link.get_mdu()` = **8111 bytes** (Reticulum's per-packet payload on the measured link)
- `StreamDataMessage.MAX_DATA` = **8103 bytes** (per Channel/Buffer segment)
- RTT class: **FAST** on any nearby hub (< 180 ms)

A 20 KB encrypted PTT clip fits inside a single window even at the SLOW class. The fan-out ceiling is set by the reflector's outbound TCP capacity, not the protocol.

| Callers | Outbound per message | Expected experience |
|---------|---------------------|---------------------|
| 2–3 | 40–60 KB | Reliable on any consumer connection |
| 3–5 | 60–100 KB | Good; occasional delay on mobile data |
| 5–10 | 100–200 KB | Depends on the reflector's uplink; still workable |
| 10+ | 200 KB+ | Constrained by the reflector's egress |

The old 3–5 caller cap in tor-party-line was a Tor throughput limit; Reticulum lifts it. The remaining limit is what the reflector's uplink can push. Lower the Opus bitrate (Settings → Opus encoding) to help at higher counts.

</details>


<details id="security-model">
<summary><strong>Security model</strong></summary>

<br>

| Property | Notes |
|----------|-------|
| **Payload encryption** | AES-256-CBC + [PBKDF2](https://datatracker.ietf.org/doc/html/rfc8018) (10k iterations). 21 cipher options (AES/Camellia/ARIA in CBC/CTR, AES-256 also in CFB/OFB, plus ChaCha20). No AEAD/GCM — [`openssl enc`](https://www.openssl.org/docs/man3.0/man1/openssl-enc.html) can't stream them. |
| **Transport encryption** | Reticulum encrypts the client↔reflector link. The reflector *terminates* that link and could otherwise read every clip in the clear. |
| **Zero-knowledge relay** | Preserved via the deliberate double-wrap: AES-encrypted payloads pass through the reflector, which holds no shared secret and cannot decrypt. Do not "optimise" the wrap away. |
| **Authenticity** | Every caller is cryptographically identified by their RNS identity. This is what Reticulum gives you that Tor did not. |
| **Anonymity** | ⚠️ **Not preserved.** Reticulum is not onion routing. Over a TCP interface the reflector sees each client's IP address, and RNS destination hashes are announced across the network. If you need caller anonymity, use [tor-party-line](https://github.com/MarcusHoltz/tor-party-line) instead. |
| **Secret storage** | Shared secret encrypted at rest with an optional passphrase. |
| **HMAC signing** | Optional. Cryptographically signs every protocol message; prevents replay attacks. |
| **Overwrite before delete** | Applies to the persistent `$DATA_DIR`. `$RUNTIME_DIR` is a tmpfs, so runtime files (recordings, chunks, payloads, nonce logs) never touch disk. **SSD caveat:** wear-leveling defeats overwrite on any persistent path — full-disk encryption ([LUKS](https://gitlab.com/cryptsetup/cryptsetup)/[FileVault](https://support.apple.com/en-us/102650)) is the only reliable defense against physical recovery. |
| **No forward secrecy** | Compromise of the shared secret exposes all calls made with it. Rotate secrets between sensitive conversations. |
| **Flood / DoS protection** | The relay holds no secret, so it can't verify traffic — instead it **rate-limits each caller** (`RELAY_MAX_MSG_PER_SEC`, default 15/s) and **drops oversized or excess messages** before fan-out. The sender caps push-to-talk length (`MAX_PTT_SECONDS`), audio size (`MAX_AUDIO_B64`), and text length; receivers drop messages over `MAX_MSG_B64`. The Reticulum bridge also gates by `MAX_LINE_BYTES` at Resource-accept time, so oversized blobs are rejected before a single byte transfers. |

</details>


<details id="architecture">
<summary><strong>Architecture &amp; code map</strong></summary>

<br>

**Audio pipeline** — push-to-talk, half-duplex: one complete recording per PTT press, sent as a single message. No live streaming.

```text
SENDER                                          RECEIVER
──────                                          ────────
Microphone                                      Speaker
    │                                               ▲
    ▼                                               │
Raw PCM (8 kHz, 16-bit, mono)                   Opus decode
    │                                               ▲
    ▼                                               │
Opus encode (16 kbps)                           AES-256-CBC decrypt
    │                                               ▲
    ▼                                               │
AES-256-CBC encrypt                             Base64 decode
    │                                               ▲
    ▼                                               │
Base64 ──▶ rns_bridge (Resource) ──▶ Reticulum ──▶ rns_bridge ──▶ Receive
```

**Hybrid transport** - the bridge splits the wire protocol by shape:

| Wire line | Carrier | Why |
|-----------|---------|-----|
| `PING`, `GROUP:<n>`, `CIPHER:<name>`, `HANGUP`, short `MSG:` | `RNS.Packet` | Small, fits in the link MDU; no need for segmentation |
| `AUDIO:<base64>` | `RNS.Resource` | Ordered assembly, integrity, explicit `FAILED`/`CORRUPT` on error instead of silent drop |
| Any non-AUDIO line larger than the link MDU | `RNS.Resource` | Fallback so an oversized `MSG:` doesn't lose bytes |

**Wire protocol** — line-based text, unchanged from tor-party-line:

| Message | Meaning |
|---------|---------|
| `ID:<address>` | Sender's Reticulum destination hash |
| `CIPHER:<name>` | Sender's active cipher (on connect + on change) |
| `PTT_START` / `PTT_STOP` | Recording start/end boundaries |
| `AUDIO:<base64>` | Complete encrypted audio message |
| `MSG:<base64>` | Encrypted text message |
| `HANGUP` / `PING` | Disconnect / keepalive |
| `RELAY:1` | Relay greeting → triggers group mode on the receiver |
| `GROUP:<n>` | Group size update, broadcast when callers join or leave |

> **Cipher mismatch:** decryption fails silently when both sides differ. The call header shows a red ● when the exchanged `CIPHER:` values don't match. Fix via **S → Settings** mid-call.

**`docker/` folder:**

| File | Purpose |
|------|---------|
| `entrypoint.sh` | Fixes bind-mount ownership, starts fallback PulseAudio if needed, drops to non-root `partyline` user (uid 1000) via `setpriv`. Baked into the image at build time. |
| `hooks/audit-pins.sh` | CI-only: validates Dockerfile digest and version pins |
| `hooks/update-pins.sh` | CI-only: checks for newer base images and pip versions |

**Container / runtime layout:**

```text
docker compose --profile reflector up -d reflector
        │
        ▼
[docker/entrypoint.sh]  (runs as root, then drops to partyline:1000)
  1. Fix bind-mount ownership (chown partyline:partyline)
  2. Start fallback PulseAudio if no host sound server is reachable
  3. exec setpriv --reuid=partyline --regid=partyline /app/src/rns-party-line.sh
        │
        ▼
[rns-party-line.sh relay]
  1. write_rns_bridge   →  emits embedded rns_bridge.py to $RUNTIME_DIR
  2. emit handler.sh    →  fanout / rate limit / GROUP: beacon (from tor-party-line, unchanged)
  3. fork: python3 rns_bridge.py listen ... -- bash handler.sh <args>
  4. wait for DEST_HASH → write to destination file, print to operator
        │
        ▼
[rns_bridge.py listen]  (Python)
  - Reticulum instance: outbound TCPClientInterface per $RNS_HUBS entry
    (+ discovery when lxmf is present), plus a TCPServerInterface on
    0.0.0.0:$REFLECTOR_PORT for the direct-mode fallback
  - Destination(SINGLE, "partyline", "relay"), announce every 5 min
  - On incoming Link: fork handler.sh with a fresh pipe pair, bridge
    Link↔stdio through a per-link LinkBridge (queue + writer thread)
  - Control lines → RNS.Packet   |   AUDIO: → RNS.Resource(auto_compress=False)

[Volumes]
  ./data          (bind mount) → /app/data                 (persistent: identity, secret, config, destination)
  /dev/shm        (tmpfs 512M) → RUNTIME_DIR               (audio/, run/, pids/, RNS storage, emitted bridge)
  ./secrets       (bind mount) → /run/secrets              (read-only compose secret)
```

**Client side:**

```text
[rns-party-line.sh call <hash>]
  1. write_rns_bridge   →  emits rns_bridge.py
  2. mkfifo SEND_PIPE, RECV_PIPE
  3. fork: python3 rns_bridge.py connect ... --send-pipe ... --recv-pipe ...
  4. wait for --ready-file (touched on real RNS link_established)
  5. run in_call_session on the FIFOs
```

**Code map** — all logic lives in `rns-party-line.sh` (~6 000 lines including the embedded bridge):

| Region | Contents |
|--------|----------|
| Header + config | Docker/script detection, config globals (persistent DATA_DIR + tmpfs RUNTIME_DIR), color codes |
| Core helpers | logging, config load/save, dep check, package-manager wrappers, `write_rns_bridge`, `wait_dest_hash`, `_emit_rns_bridge` (heredoc-embedded 680-line bridge), `_bridge_stderr_hint` |
| Audio backend | `detect_audio_backend`, PulseAudio/PipeWire probes, ALSA fallback |
| Install / uninstall | `install_deps`, `uninstall_all` |
| Transport stubs + identity | Transport lifecycle no-ops (the embedded bridge manages Reticulum directly), `rotate_identity` (deletes the identity file and regenerates), `ensure_address` (derives and writes the destination hash offline, no interfaces), address file reader |
| Secrets / crypto | shared secret handling, cipher helpers, encryption, HMAC protocol signing |
| Audio pipeline | record, play, PTT send/stop, `play_chunk`, cross-platform `start_play_worker` |
| Call infrastructure | cleanup, auto-listener, wakelock, `listen_for_call`, `_dial_remote` (bridges to `rns_bridge.py connect` + `--ready-file`), `call_remote` (32-hex validation) |
| Relay mode | `relay_mode` (spawns `rns_bridge.py listen ... -- bash handler.sh ...`), handler.sh heredoc (fanout, rate limit, GROUP: beacon), call-header drawing |
| `in_call_session` | PTT event loop, receive handler, mid-call settings |
| Menus | `main_menu` (calls `ensure_address` before the first draw so a cold start shows an address), `settings_menu`, `audio_menu`, `test_audio`, `show_status` |
| CLI | `print_cli_help`, `parse_args`, `apply_cli_overrides` |
| Entry point | bootstrap (DATA_DIR + RUNTIME_DIR mkdir), dep check, `start_auto_listener`, command dispatch |

**The bridge itself** (`rns_bridge.py`, embedded as a heredoc):

| Symbol | Role |
|--------|------|
| `wants_resource(line, mdu)` | Classifier: AUDIO or oversized line → Resource, else Packet |
| `LinkBridge` | Per-Link bidirectional bytes pipe. Writer thread drains `inbound_q` into the child/FIFO so RNS receive threads never block on downstream backpressure |
| `Listener` | `listen` role: announce destination, accept Links, fork handler per Link |
| `Connector` | `connect` role: `Transport.await_path` → `RNS.Link`, touch `--ready-file` on real establishment, bridge to `SEND_PIPE` / `RECV_PIPE` |
| `print_address` | `address` role: derive the destination hash from the identity (creating it on first run) and write `--dest-hash-out`. No Reticulum instance, no interfaces, no announce |

</details>


<details>
<summary><strong>Anonymity trade-off (why this project exists as a sibling)</strong></summary>

<br>

This project is a sibling of [tor-party-line](https://github.com/MarcusHoltz/tor-party-line), not a replacement:

> Tor provides anonymity, Reticulum provides authenticity. They're different products. Don't force one into or upon the other.

Use **tor-party-line** if any of the following matter more than latency and throughput:

- You want callers hidden from each other and from the reflector operator
- You need to work behind CGNAT / hostile firewalls with no reachable transport
- You want to survive network-level censorship (via Snowflake)

Use **this project** (reticulum-party-line) if any of the following matter more than anonymity:

- You want cryptographic authenticity of every caller
- You want the throughput headroom that lets a group call scale past 3–5 callers
- You're on LoRa, packet radio, or another Reticulum-friendly link
- You already have a Reticulum network and want voice on it

</details>


---

## ❓ FAQ

**Can the relay or anyone in the middle hear me?**
The relay cannot: audio is encrypted end-to-end with the shared secret before it hits the network, and the relay never receives that secret. Reticulum's transport encryption additionally protects the wire between each client and the relay.

**Can someone find my IP?**
Yes. Reticulum is not onion routing. Over a TCP interface the relay operator sees each client's IP address, and RNS destination hashes are announced across the network. Use [tor-party-line](https://github.com/MarcusHoltz/tor-party-line) if you need anonymity.

**Do I need port forwarding?**
No. Both roles dial *outbound* to the backbone nodes in `RNS_HUBS`, so neither the reflector nor the caller needs a reachable port. NAT and CGNAT are fine. You only need a forwarded port if you deliberately opt into direct mode by setting `REFLECTOR_HOST`.

**Does Reticulum hole-punch through my NAT?**
No, and this trips people up. There is no STUN, no UPnP, no NAT traversal anywhere in RNS. What you get instead is a rendezvous: both ends make ordinary outbound TCP connections to a shared transport node, which routes between them. The effect looks like hole punching (no open ports, works behind NAT) but the mechanism is closer to a VPN concentrator.

**Why push-to-talk instead of a real phone call?**
Half-duplex sidesteps mixer, echo cancellation, and jitter buffer complexity, and it maps cleanly onto Reticulum's discrete-message primitives. PTT sends a complete clip per transmission. Expect a small delay end-to-end.

**What happens if two people talk at once?**
Clips play back one at a time, in the order they arrive — there's no speaker indicator or busy signal. If you press SPACE while another clip is still playing, yours records and queues behind it. Dead air is the "channel free" signal, same as a handheld radio.

**Do I need an account or phone number?**
None. Your identity is your Reticulum destination hash; authentication is the shared secret.

**How do I audit it?**
Read `rns-party-line.sh` — one Bash file with the Python bridge embedded as a heredoc, [code map](#architecture) above. No binaries, no telemetry.

**Why keep the AES layer if Reticulum already encrypts the link?**
Because the reflector terminates the Reticulum link. Without a second layer, whoever runs the room hears every clip in the clear — the inversion of tor-party-line's threat model, where the relay provably cannot listen. The double-wrap costs ~48 bytes per frame and is deliberate.

**Is it legal?**
Reticulum and end-to-end encryption are legal in most countries. Comply with your local law.


---

## 🔀 Alternatives

Related projects:

| Tool | Hides IP | No account | Voice | Group | Notes |
|------|:---:|:---:|:---:|:---:|------|
| **📡 Reticulum Party Line** *(this)* | ❌ | ✅ | ✅ PTT / full-duplex | ✅ | Terminal, single script, Reticulum transport, cryptographic authenticity; full-duplex over TCP |
| **🧅 [Tor Party Line](https://github.com/MarcusHoltz/tor-party-line)** | ✅ Tor | ✅ | ✅ PTT | ✅ | Sibling project; same UX with Tor's anonymity properties |
| [Mumble](https://www.mumble.info/) | ❌ | ✅ | ✅ full-duplex | ✅ | Low-latency, required server software |
| [Jami](https://jami.net/) | ⚠️ P2P | ✅ | ✅ full-duplex | ✅ | Serverless GUI; metadata via DHT |
| [Briar](https://briarproject.org/) | ✅ Tor | ✅ | ❌ | ✅ | Tor messaging, no voice |
| [Cwtch](https://cwtch.im/) | ✅ Tor | ✅ | ❌ | ✅ | Metadata-resistant text, no voice |
| [Signal](https://signal.org/) | ❌ | ❌ | ✅ full-duplex | ✅ | Great E2EE; needs a phone number |
| [OnionShare](https://onionshare.org/) | ✅ Tor | ✅ | ❌ | ⚠️ | Tor files + chat, not voice |

Voice-adjacent Reticulum projects worth knowing about — none are drop-in replacements for what this project does today:

- [**LXST**](https://github.com/markqvist/LXST) — Reticulum audio stack. Full-duplex 1-to-1 and rnphone. Group calls are an unreleased internal prototype at time of writing. Licence: CC BY-NC-ND 4.0 during early alpha, so private modification only.
- [**Sideband**](https://github.com/markqvist/Sideband), [**kc1awv/lxst_phone**](https://github.com/kc1awv/lxst_phone), [**Ratspeak**](https://github.com/ratspeak/Ratspeak) — voice-capable RNS clients, all 1-to-1 today.


---

## 🔐 Security Audit Notes

Audited 2026-09-03. No critical issues found. The script uses
sound security practices throughout.

### Positive findings

- **No `eval` or `source`**: the script never executes
  dynamically constructed code or sources external files.
- **Secret handling via fd:3**: the room secret is passed to
  `openssl` through a here-string on file descriptor 3, never
  as a CLI argument (which would leak into `/proc/*/cmdline`).
- **Restrictive file permissions**: sensitive files (FIFO pipes,
  secret storage) are created with `chmod 600` or written inside
  `umask 077` blocks.
- **HMAC authentication**: every voice packet is signed with
  `openssl dgst -sha256 -hmac` using a nonce and replay
  detection via sequence numbers. Packets with invalid or
  replayed signatures are silently dropped.
- **Quoted heredocs**: all heredocs that embed secrets use the
  quoted form (`<<'EOF'`) to prevent variable expansion.
  The embedded `rns_bridge.py` heredoc also uses the quoted
  form to prevent shell expansion of Python f-strings.
- **No credential leakage**: connection strings, secrets, and
  keys are never logged, echoed, or written to world-readable
  paths.
- **Untrusted relay**: the room secret is discarded after
  bridge setup. The relay operator cannot decrypt traffic.

### Low-severity observations

- **HMAC timing**: `openssl dgst` comparison uses a string
  equality check, which is theoretically vulnerable to timing
  side-channels. Practically unexploitable over Reticulum
  (latency jitter dwarfs any timing signal), but noted for
  completeness.
- **FIFO permissions**: named pipes are created with default
  umask, then `chmod 600` is applied. A brief window exists
  between creation and chmod. Mitigated by the script running
  inside a container with no other users.

### Cross-repo relationship

Three sibling projects share approximately 80% of their code
(~4,600 lines, 109 of ~130 functions are identical):

| Project | Transport | Key difference |
|---------|-----------|----------------|
| [Tor Party Line](https://github.com/MarcusHoltz/tor-party-line) | Tor hidden services | Trusted relay (secret written to relay host) |
| [I2P Party Line](https://github.com/MarcusHoltz/i2p-party-line) | i2pd tunnels | Untrusted relay (secret discarded after setup) |
| **Reticulum Party Line** *(this)* | RNS bridge | Untrusted relay, Python bridge for Reticulum mesh |

Shared code covers: room lifecycle, audio capture/playback,
HMAC signing, encryption, PTT handling, the TUI, configuration,
and all user-facing features. Transport-specific code (RNS
bridge management via embedded `rns_bridge.py`, 32-char hex
destination hashes) lives only in this repo.

When a shared function changes in one script, the same change
is applied to the other two, adapted for transport-specific
naming where needed.


---

## 🙏 Credits

Forked from [tor-party-line](https://github.com/MarcusHoltz/tor-party-line) by [MarcusHoltz](https://github.com/MarcusHoltz), which is itself built upon [TerminalPhone](https://gitlab.com/here_forawhile/terminalphone) by [here_forawhile](https://gitlab.com/here_forawhile).

Reticulum by [markqvist](https://github.com/markqvist).


---

## 📄 License

MIT — see [LICENSE](LICENSE).
