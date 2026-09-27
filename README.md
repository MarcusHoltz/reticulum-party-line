<h1 align="center">🧅 Tor Party Line</h1>

<p align="center">
  <strong>Encrypted push-to-talk voice & group party line over Tor hidden services.</strong><br>
  No accounts. No phone numbers. No servers. End-to-end encrypted voice over Tor.
</p>


---

<p align="center">
  <img src="https://raw.githubusercontent.com/MarcusHoltz/marcusholtz.github.io/refs/heads/main/assets/img/header/header--tor--tor-party-line-terminal-phone.jpg" alt="Tor Party Line - Know the Onion talk with the Onion" width="760">
</p>

---



<p align="center">
  <img src="https://img.shields.io/badge/built%20for-Tor-7d4698" alt="Built on Tor">
  <img src="https://img.shields.io/badge/Supported%20on-Linux%20%7C%20macOS%20%7C%20Android%20%7C%20Docker-blue" alt="Supported Systems">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT">
  </p>

<p align="center">
  <a href="#-quickstart">Quick Start</a> ·
  <a href="#-what-youll-see">Terminal Screen</a> ·
  <a href="#-usage">Usage</a> ·
  <a href="#%EF%B8%8F-troubleshooting">Troubleshooting</a> ·
  <a href="#-reference">Reference</a> ·
  <a href="#-faq">FAQ</a>
</p>

---

## 👍 Overview

Enjoy the experience of a walkie-talkie over [Tor](https://community.torproject.org/onion-services/overview/). 

Want to talk? Agree on a shared secret — hold a key, speak, release. The other side hears it.


---

## 🚀 Quickstart


### Script

Run the script. 

```bash
chmod +x partyline.sh && ./partyline.sh
```


---

### Docker

Run docker interactivly.

```bash
docker compose run --rm partyline
```


---

### On first run

1. ⏳ Tor bootstraps — 1–3 min (progress shown on screen)

2. 🧅 Your permanent `.onion` address is generated and displayed

3. 🔑 Press **1** → set a shared secret (both callers need the same one)

4. 📡 Share your `.onion` + secret → one side listens, the other calls


---

## 📺 What You'll See

**Main menu** — after Tor bootstraps and your secret is set:

```text
  ╔╦╗┌─┐┬─┐  ╔═╗┌─┐┬─┐┌┬┐┬ ┬  ╦  ┬┌┐┌┌─┐
   ║ │ │├┬┘  ╠═╝├─┤├┬┘ │ └┬┘  ║  ││││├┤
   ╩ └─┘┴└─  ╩  ┴ ┴┴└─ ┴  ┴   ╩═╝┴┘└┘└─┘

  ───────────────────────────────────────────
  Encrypted Voice & Group Bridge over Tor
  ───────────────────────────────────────────
  v2.0.0 | Push-to-Talk | End-to-End AES-256-CBC

  Address: 7g2xq4zd...onion
  Secret: ●  Tor: ●  Snowflake: ●  Auto-listen: ●  PTT: [SPACE]
  ▸ Ready. Press 4 to listen, or 5 to call.

  ═══ SETUP ═══
  1 │ Set shared secret   (both ends need the same secret)
  2 │ Audio setup & test  (mic, speakers, diagnostics)
  3 │ Share my address    (QR code)
    ─────────────────────────────────────
  ═══ CALL ═══
  4 │ Listen for calls
  5 │ Call an onion address
  6 │ Host party line     (relay / group bridge)
    ─────────────────────────────────────
  ═══ SYSTEM ═══
  7 │ Settings
  8 │ Status
  v │ Vanity .onion address  (custom prefix)
    ─────────────────────────────────────
  0 │ Exit

  Select:
```

<table>
<tr>
<td width="50%" valign="top">

**In a call** — 1-to-1, connected:

```text
 CALL CONNECTED  7g2xq4zd...onion

  ● Local cipher:  AES-256-CBC
  ● Remote cipher: AES-256-CBC

  Last sent:  --
  Last recv:  --
  Remote:     Idle

   Ready  [SPACE]=Talk [T]=Chat [S]=Set [Q]=Hang up
```

</td>
<td width="50%" valign="top">

**Hosting a party line** — live caller count:

```text
 CALL CONNECTED

  ● Local cipher:  AES-256-CBC
  ● Mode:          RELAY (group call)

  Group:      4 callers

   Ready  [SPACE]=Talk [T]=Chat [S]=Set [Q]=Hang up
```

</td>
</tr>
</table>


---

## 📖 Usage

Now that you're up and running... let's dive into how you can *really* use this Tor Party Line!


---

### Sharing your address + secret

Before a call, both people need your `.onion` address **and** the shared secret. 

```text
onion: abc123...onion
secret: your-shared-secret-here
```

The safest handoff is a one-time link that self-destructs after a single read — the plaintext is never stored:

> Try [yopass.se](https://share.yopass.se) <--- click the link! It is free, open-source, and [self-hostable](https://github.com/jhaals/yopass).


---

### Menu reference

| Key | Action |
|-----|--------|
| 1 | Set shared secret (required before any call is heard) |
| 2 | Audio setup & test |
| 3 | Share my address (QR code) |
| 4 | Listen for a call |
| 5 | Call an `.onion` address |
| 6 | Host party line (group bridge) |
| 7 | Settings (cipher, bitrate, PTT mode, HMAC, Tor, audio, security) |
| 8 | Status (Tor circuits, onion, config) |
| 0 | Exit |

- Script-only: `r` restart Tor · `9` install deps · `n` rotate `.onion` · `u` uninstall.

- Docker-only: `v` [vanity address](#vanity-onion-address-docker).


---

### In-call keys

| Key | Action |
|-----|--------|
| **Hold SPACE** | Record; sends on release (hold-to-talk) |
| **T** | Send encrypted text |
| **S** | Mid-call settings (fix audio, change push-to-talk) |
| **Q** | Hang up |

> **Hold-to-talk:** press SPACE, wait a beat, *then* speak; release to send. 

> Prefer tap-to-talk? Make that change! → **Settings → 4 (PTT mode) → toggle**: tap to start, tap to stop and send. Android uses toggle automatically (its keyboard fires on key release, not press).


---

### Script commands & flags

**command** picks the action; **flags** override options for that run.

```text
Commands: listen | call [ADDR] | relay | status | test | config | install | uninstall | help

  -s, --secret S        Shared secret this run (must match all parties)
      --save-secret     Persist --secret to disk (chmod 600)
  -a, --address ADDR    .onion to call  (alias --onion)
  -p, --port N          Listen / hidden-service port                [7777]
      --socks-port N    Tor SOCKS port                 [9052 Script / 9050 Docker]
  -c, --cipher NAME     OpenSSL cipher (aes-256-cbc, chacha20…)    [aes-256-cbc]
  -b, --bitrate N       Opus bitrate kbps                           [16]
      --exclude-nodes L Tor ExcludeNodes (e.g. '{US},{GB}')
      --hmac            HMAC-sign protocol messages    (--no-hmac)        [on]
      --snowflake       Use Snowflake bridge           (--no-snowflake)   [off]
      --single-hop      Single-hop HS (faster, less anon) (--no-single-hop) [off]
      --auto-listen     Auto-listen after Tor starts    (--no-auto-listen) [off]
      --show-circuit    Show circuit hops in header     (--no-show-circuit)[off]
      --save            Persist all supplied options to config
  -h, --help   -V, --version
```


---

## 🔨 Troubleshooting

Say it isnt so, this script didnt work instantly? Woe is not without effort:


---

### Sharing address + secret

Getting your onion address and secret to someone, securly. Hand them a one-time link that self-destructs after one read. Both sides set the same secret (menu → **1**), then one listens, one calls.

> Visit: **[yopass.se](https://share.yopass.se)** → paste `onion:` + `secret:`, set a 1-hour expiry, send the link. 


---

### No sound / silence on calls

Almost always the wrong input/output device. A device can "open" in a test and still be silent — only your ears decide.

1. **Find a working speaker:** Settings → 7 → Audio devices → **4 (Test all outputs)** plays white noise to each device in turn. On PipeWire/PulseAudio, pick *"System default output (server)"* first — it avoids the raw-ALSA device-busy trap where disconnected ports "play" silently. Enter the number you **actually hear**; that exact route is what live calls use.

2. **Verify:** Test audio pipeline — if you hear your voice, calls work.

3. **Still stuck:** Settings → 7 → **6 (Audio diagnostics)** shows the backend, the live call route, and any muted/0% sink (the common "command succeeds, nothing comes out" cause).

4. Or set the correct mic/speakers as the system default in your desktop sound settings (GNOME, KDE, `pavucontrol`). With nothing pinned, the app follows the system default. Multi-card box? `pactl info | grep Default` shows what's selected — mic and speakers can be on different cards.


---

### Remote hears nothing / red ● in call header

**Cipher mismatch** — decryption fails silently when both sides differ. Agree on the same cipher in Settings, or change mid-call via **S → Settings**.


---

### Tor stuck / address never appears

First bootstrap takes 1–3 min. Script: press **r** to restart Tor. Tor blocked on your network? Enable [Snowflake](https://snowflake.torproject.org/) in Settings → Tor (Script only). Docker: exit (**0**) and re-run `docker compose run --rm partyline`.


---

### Android call drops with the screen off

The app holds a partial wakelock via `termux-wake-lock` ([Termux:API](https://github.com/termux/termux-api)). Without it, Android deep-sleeps the process mid-call.

1. Install **Termux:API** from [F-Droid](https://f-droid.org/en/packages/com.termux.api/) (not the Play Store), then `pkg install termux-api` — without it the mic won't work either.

2. Android Settings → Apps → Termux → Battery → **Unrestricted**.

3. Genuine drops auto-reconnect silently up to `RECONNECT_ATTEMPTS` times.


---


## I hear a brief pause mid-message on Android

Nothing is wrong. Messages longer than `PTT_CHUNK_SECONDS` (default 10 s) are split into chunks and played back sequentially. On Android/Termux there is a ~300 ms gap between chunks while the media player loads to the next file — the audio resumes exactly where it left off.


---

### Running automated headless deployments

Skip the menu. Pass flags directly. No interactive prompts. Works on Docker and Script.


#### Run-once commands, removed when done

`docker compose run --rm` runs, exits when complete, as if running the script.

```bash
# Place a call
docker compose run --rm partyline call abcdef0123456789.onion --secret 'shhhsecretshere'

# 1-to-1: listen for an incoming call
docker compose run --rm partyline listen --secret 'shhhsecretshere'

# Diagnostics
docker compose run --rm partyline test
docker compose run --rm partyline status
```


#### Save some settings, then run without those flags

```bash
docker compose run --rm partyline config --secret 'shhhsecretshere' --port 7777 --hmac --save
docker compose run --rm partyline call abcdef0123456789.onion
```
> an .onion address is required per call; everything else above is saved and remembered


#### Compose up starts group bridge on auto-restart

By default, if you bring up this project it starts the relay, an always-on group bridge: callers dial your `.onion` and are bridged together... in a PARTY LINE!

`docker compose up -d` starts the group bridge directly — when no command is given and there is no interactive terminal attached (i.e. detached mode), the container auto-selects relay mode:

```bash
docker compose up -d       # start relay in background (Tor bootstraps, group bridge opens)
docker compose logs -f     # watch live activity
docker compose restart     # reload without losing your .onion address
docker compose down        # stop everything
```

> Grab a [vanity address](#vanity-onion-address-docker) before going live so your `.onion` is slightly memorable.


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
- **Ctrl+C** will terminate the process inside the container — use with caution.

> Script usage is identical: `./partyline.sh call <onion> --secret 'shhhsecretshere'`. For more info, see [Configuration & defaults](#config-and-defaults)


---

### Anti-flood limits

Tune any of these in the [Reference](#-reference) tables.

- Push-to-talk **auto-stops at `MAX_PTT_SECONDS`** (default 120 s) even if you keep holding — release and press again to continue. A clip over the size cap shows **`too long`** instead of sending. 

- Text messages are length-capped, and on a group call the relay **rate-limits each caller** (default 15 messages), so holding a key down or pasting a wall of text won't flood or mute the room — the excess is silently dropped. 


---


### Environment variable use

Environment variable take a precedence order: 

1. built-in defaults

2. .env

3. saved config

4. CLI flags


---

## 📚 Reference

<details>
<summary><strong>Audio setup (all platforms)</strong></summary>

<br>

| Platform | Backend | Device selection |
|----------|---------|-----------------|
| Linux Script | PipeWire → PulseAudio → ALSA (auto) | Desktop sound settings, in-app picker, or env vars |
| Linux Docker | ALSA direct | In-app picker or env vars |
| Android/Termux | termux-microphone-record + ffplay | OS routes automatically |
| macOS | ffmpeg (AVFoundation) | System Settings → Sound |

**Linux — in-app picker:** Settings → 7 → Audio devices. Lists devices by friendly name and offers *System default* (routes through your sound server to whatever you selected in your desktop settings — right for almost everyone). `← current` marks the active device; `[HDMI]` flags display-audio outputs.

**Backend order:** sound server (`parecord`/`paplay`, works with both [PulseAudio](https://www.freedesktop.org/wiki/Software/PulseAudio/) and [PipeWire](https://pipewire.org/)) → [ALSA](https://www.alsa-project.org/) direct. The app records a brief probe first; if the server corks the stream (Docker, headless, no socket), detection falls through to ALSA.

**Why the sound server wins on multi-card desktops:** ALSA opens capture devices in card order and picks the first that *opens* — but every card opens even with no mic attached, so it often picks the wrong one. The sound server already knows your selected default.

**Verify the full pipeline:**
```bash
docker compose run --rm partyline test   # Docker
./partyline.sh test                       # Script
```
Records 3 s, Opus-encodes, encrypts, decrypts, plays back. Hear yourself = the whole pipeline works. Output shows the backend used (e.g. `Playing back via pw-play`). Probing order: `pw-play` → `paplay` → `aplay -D default`/`pulse` → raw `plughw` (raw last — when PipeWire/PulseAudio owns the card, direct `plughw` hits `EBUSY`).

No sound-server tools at all?
```bash
sudo apt install pulseaudio-utils pipewire-bin   # Debian/Ubuntu
sudo dnf install pulseaudio-utils                # Fedora
```
Or menu → 9 (install dependencies).

**Forcing a specific ALSA device** (headless / bare-ALSA / Docker) — setting these env vars forces ALSA-direct and bypasses the sound server:
```bash
ALSA_DEVICE=plughw:1,0 ./partyline.sh    # Script, inline
# Docker: set in .env (copy .env.example first)
ALSA_DEVICE=plughw:0,0        # mic
ALSA_PLAY_DEVICE=plughw:0,0   # speakers
```
Find the numbers on the **host** (not inside Docker): `arecord -l` (mics), `aplay -l` (speakers). Format is `plughw:CARD,DEVICE`. Use `plughw:`, not `hw:` — the plug layer converts sample rates automatically; `hw` requires an exact match and fails otherwise. The in-app picker overrides `.env`.

**Android / Termux:** the OS controls routing — no per-device selection. Needs Termux + **Termux:API from F-Droid**, then `pkg install termux-api`. Bluetooth: pair in Android settings, enable the **Headset / HFP** profile for a mic (A2DP is music-only). Audio stuck on phone speaker → toggle Bluetooth off/on.

**macOS:** select input/output in **System Settings → Sound** before launch. [`ffmpeg`](https://ffmpeg.org/) routes through [AVFoundation](https://developer.apple.com/av-foundation/)/CoreAudio automatically. Apple Silicon under Rosetta: [Homebrew](https://brew.sh/) runs with `arch -arm64` transparently — no action needed.

</details>




<details id="config-and-defaults">
<summary><strong>Configuration & defaults</strong></summary>

<br>

Settings precedence (lowest → highest): **built-in defaults → `.env`** (Docker only) **→ saved config** (`data/.partyline/config`) **→ CLI flags**.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `LISTEN_PORT` | `7777` | TCP port for incoming connections |
| `TOR_SOCKS_PORT` | `9052` Script / `9050` Docker | [Tor SOCKS proxy](https://2019.www.torproject.org/docs/tor-manual.html.en) port |
| `SNOWFLAKE_ENABLED` | `0` | Use Snowflake censorship-circumvention bridge (Script only; `0`/`1`) |
| `SINGLE_HOP` | `0` | Single-hop hidden service — faster but sacrifices server anonymity (`0`/`1`) |
| `EXCLUDE_NODES` | *(none)* | Tor ExcludeNodes: comma-separated country codes, e.g. `{US},{GB}` |
| `SHOW_CIRCUIT` | `0` | Show Tor circuit hop countries in the call header (`0`/`1`) |
| `OPUS_BITRATE` | `16` | Opus encoding bitrate (kbps) |
| `CIPHER` | `aes-256-cbc` | Encryption cipher |
| `AUTO_LISTEN` | `0` | Start listening automatically when Tor boots |
| `PTT_KEY` | `SPACE` | Push-to-talk key |
| `PTT_TOGGLE_MODE` | `0` | `0` = hold-to-talk, `1` = tap-start/tap-stop toggle |
| `HMAC_AUTH` | `1` | HMAC-sign all protocol messages (both sides must match) |
| `OVERWRITE_DELETE` | `0` | Overwrite temp files with random bytes before deletion |
| `SAMPLE_RATE` | `8000` | Audio sample rate (Hz) |
| `ALSA_DEVICE` | *(empty)* | Force a specific ALSA capture device (e.g. `plughw:1,0`); bypasses sound server |
| `ALSA_PLAY_DEVICE` | *(empty)* | Force a specific ALSA playback device (e.g. `plughw:0,0`); bypasses sound server |
| `PULSE_SOURCE` | *(empty)* | PipeWire/PulseAudio capture device name; empty = system default |
| `PULSE_SINK` | *(empty)* | PipeWire/PulseAudio playback device name; empty = system default |
| `RELAY_IDLE_TIMEOUT` | `240` | Drop a caller after this many seconds of total silence |
| `HEARTBEAT_INTERVAL` | `20` | Keepalive PING interval; keep well below `RELAY_IDLE_TIMEOUT` |
| `CLIENT_TIMEOUT` | `180` | No inbound traffic this long = dropped; tear down + reconnect |
| `RECONNECT_ATTEMPTS` | `3` | Silent re-dials after a drop; `0` disables auto-reconnect |
| `MAX_PTT_SECONDS` | `120` | Hard cap on one push-to-talk transmission; recorder self-stops at the limit |
| `MAX_AUDIO_B64` | `524288` | Sender skips an AUDIO blob over this (base64 bytes); backstop to `MAX_PTT_SECONDS` |
| `MAX_LINE_BYTES` | `524288` | Relay drops any inbound line larger than this before forwarding |
| `MAX_MSG_B64` | `65536` | Receiving client drops a text MSG whose base64 exceeds this |
| `RELAY_MAX_MSG_PER_SEC` | `15` | Relay drops a caller's messages beyond this rate (anti-flood; one caller can't mute the rest) |
| `RELAY_MAX_INFLIGHT` | `64` | Caps concurrent background forwards per caller (fork-bomb guard) |
| `RELAY_WRITE_TIMEOUT` | `30` | Seconds before the relay abandons a write to a stalled client |
| `DECRYPT_TIMEOUT` | `10` | Seconds before killing a stalled `openssl` decrypt process |
| `PTT_CHUNK_SECONDS` | `10` | Split PTT audio into chunks of this many seconds before encoding and sending |

`.env` is read **only by Docker Compose** (the script ignores it). Copy `.env.example` and edit. Every flag has a matching `.env` variable; booleans are `0`/`1`:

| CLI flag | `.env` var | Default |
|----------|-----------|---------|
| `-p, --port` | `LISTEN_PORT` | `7777` |
| `--socks-port` | `TOR_SOCKS_PORT` | `9052` |
| `-b, --bitrate` | `OPUS_BITRATE` | `16` |
| `-c, --cipher` | `CIPHER` | `aes-256-cbc` |
| `--hmac` | `HMAC_AUTH` | `1` |
| `--snowflake` | `SNOWFLAKE_ENABLED` | `0` |
| `--single-hop` | `SINGLE_HOP` | `0` |
| `--auto-listen` | `AUTO_LISTEN` | `0` |
| `--show-circuit` | `SHOW_CIRCUIT` | `0` |
| `--exclude-nodes` | `EXCLUDE_NODES` | *(none)* |
| `-s, --secret` | *(use Docker secret — see below)* | — |

Audio (`ALSA_DEVICE`, `ALSA_PLAY_DEVICE`, `PULSE_SOURCE`, `PULSE_SINK`, `XDG_RUNTIME_DIR`), keep-alive tuning (`RELAY_IDLE_TIMEOUT`, `HEARTBEAT_INTERVAL`, `CLIENT_TIMEOUT`, `RECONNECT_ATTEMPTS`), and the anti-flood limits (`MAX_PTT_SECONDS`, `MAX_AUDIO_B64`, `MAX_LINE_BYTES`, `MAX_MSG_B64`, `RELAY_MAX_MSG_PER_SEC`, `RELAY_MAX_INFLIGHT`, `RELAY_WRITE_TIMEOUT`) are also `.env`-settable — see `.env.example`.

</details>




<details id="shared-secret-docker">
<summary><strong>Shared secret (Docker)</strong></summary>

<br>

The shared secret is deliberately **not** an environment variable — env values leak via `docker inspect`, `/proc/<pid>/environ`, and logs. Instead the `secrets/` directory is **bind-mounted read-only** into the container and the app reads the secret from a file.

`secrets/shared_secret.txt` is **git-ignored**, so your real secret is never tracked or committed. An absent or empty file means "no secret set" — a relay needs none, and `--secret` always takes precedence.

```bash
# Per run (overrides the file):
docker compose run --rm partyline call <onion> --secret 'your-secret'

# Or persist once (used by every run, including up -d):
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
      - SHARED_SECRET_FILE=/run/secrets/shared_secret.txt  # app reads from here
```

> A directory bind mount is used on purpose: a Compose `secrets:` file source must exist or `docker compose up` fails, which would force the secret file to be committed. Mounting the directory works on a fresh clone even when the file doesn't exist yet.

**Precedence (highest first):** `--secret` flag → `SHARED_SECRET_FILE` (the bind-mounted file) → saved secret (`data/script/shared_secret`) → interactive prompt. The `secrets/` directory is git-ignored (only an empty `.gitkeep` is tracked), so your real secret is never committed.

**SELinux (Fedora/RHEL):** `docker-compose.yml` sets `security_opt: label:disable`, which runs the container as `spc_t` (unconfined) — that's what lets it read the secrets mount without a `:z` relabel. It also covers PulseAudio socket access. Without it you'd see an AVC denial on the secrets file.

Rebuild after a code change: `docker compose build`.

</details>




<details id="your-onion-identity-backup--restore--vanity">
<summary><strong>Your .onion identity (backup / restore / vanity)</strong></summary>

<br>

The private key lives in `./data/docker/tor/hidden_service/` — a plain directory inside the project. It survives all `docker compose run` restarts and is part of the project directory like everything else. Zip the whole project folder and your identity comes with it.

```bash
# Show your address
docker compose run --rm --entrypoint bash partyline \
    -c 'cat /var/lib/tor/hidden_service/hostname'

# Back up your identity
cp -r data/docker/tor/hidden_service onion-backup

# Restore from backup
cp -r onion-backup/. data/docker/tor/hidden_service/
chmod 700 data/docker/tor/hidden_service
chmod 600 data/docker/tor/hidden_service/hs_ed25519_*
```

**Change your address** — destroys the old one (back up first): Script menu **n** = random rotate; Docker menu **v** = vanity.

<a id="vanity-onion-address-docker"></a>
**Vanity address (Docker):**

A vanity `.onion` address starts with characters you choose — for example `torpedo...onion` instead of a random 56-character string. The address is still cryptographically generated; the prefix is found by brute-forcing key pairs until one produces a matching address. There is no shortcut and no way to claim a specific address someone else already holds.

**Benefits**

- Makes your address recognizable at a glance — useful for branding, logging, or just sanity-checking you dialed the right peer.

- Longer custom prefixes are statistically harder to spoof with a look-alike address.

**How to Access**

In the Docker menu **v** runs the bundled [`mkp224o`](https://github.com/cathugger/mkp224o) brute-forcer for an address starting with letters you choose. Prefix: 1–8 chars, base32 only (`a`–`z`, `2`–`7`). Search time scales ~32× per extra char:

| Prefix length | Typical time |
|--------------|--------------|
| 3 chars | Seconds |
| 5 chars | 1–5 min |
| 6 chars | 30 min – hours |
| 7 chars | Days |
| 8 chars | Months |

Ctrl-C aborts safely. **Installing the new key permanently replaces your current `.onion`.**


**Where the keys are stored**

The three files that make up an onion identity are stored in `./data/docker/tor/hidden_service/` (bind-mounted into the container at `/var/lib/tor/hidden_service/`):

| File | Purpose |
|------|---------|
| `hostname` | Your `.onion` address (public, shareable) |
| `hs_ed25519_public_key` | Ed25519 public key |
| `hs_ed25519_secret_key` | Ed25519 private key — keep this secret |


**Bringing your own vanity key**

If you generated a key pair externally (e.g., with a faster machine or a different tool), copy the three files into `data/docker/tor/hidden_service/` before the first run:

```bash
mkdir -p data/docker/tor/hidden_service
cp hostname hs_ed25519_public_key hs_ed25519_secret_key data/docker/tor/hidden_service/
chmod 700 data/docker/tor/hidden_service
chmod 600 data/docker/tor/hidden_service/hs_ed25519_*
```

All three files (`hostname`, `hs_ed25519_public_key`, `hs_ed25519_secret_key`) must be present and consistent or Tor will reject the service.

</details>




<details>
<summary><strong>Running Script (no Docker)</strong></summary>

<br>

```bash
chmod +x partyline.sh
./partyline.sh
```

Auto-detects your platform and offers to install dependencies via your package manager (you're asked before anything is installed). Undo everything with `./partyline.sh uninstall`.

| Platform | Package manager | Audio |
|----------|----------------|-------|
| Linux | apt / dnf / pacman | PulseAudio/PipeWire (`parecord`/`paplay`), ALSA fallback |
| macOS | Homebrew (auto-installed) | ffmpeg |
| Android/Termux | `pkg` | termux-microphone-record |

<a id="snowflake"></a>**Snowflake** (censorship circumvention via [snowflake.torproject.org](https://snowflake.torproject.org/)) is Script-only — not available in Docker.

</details>




<details>
<summary><strong>What gets installed (Script only)</strong></summary>

<br>

Docker bundles everything — skip this. Script/Termux: the script asks before installing. None of these phone home; all are standard open-source tools.

| Package | What it does |
|---------|-------------|
| [**tor**](https://www.torproject.org/) | Creates your `.onion` address, tunnels all traffic anonymously |
| [**opus-tools**](https://opus-codec.org/) (`opusenc`/`opusdec`) | Compresses voice ~10× for Tor's limited bandwidth |
| [**socat**](http://www.dest-unreach.org/socat/) | Moves audio through the Tor SOCKS proxy — the wire between callers |
| [**openssl**](https://www.openssl.org/) | AES-256-CBC encryption + HMAC-SHA256 signing |
| **pulseaudio-utils** (`parecord`/`paplay`) | Sound-server audio (PulseAudio + PipeWire) |
| **alsa-utils** (`arecord`/`aplay`) | ALSA direct fallback (headless/Docker) |
| [**ffmpeg**](https://ffmpeg.org/) / **ffplay** | Audio on macOS (AVFoundation) and Android/Termux |
| [**qrencode**](https://fukuchi.org/works/qrencode/) | `.onion` QR code in the terminal (optional, on first use) |
| **termux-api** *(Android only)* | Mic access + `termux-wake-lock`. Install from F-Droid |

</details>




<details>
<summary><strong>Party line capacity</strong></summary>

<br>

Tor bandwidth is the bottleneck. A 10-second voice message is ~20 KB encrypted, fanned out to N-1 listeners:

| Callers | Outbound per message | Expected experience |
|---------|---------------------|---------------------|
| 2–3 | 20–40 KB | Reliable on most connections |
| 3–5 | 40–80 KB | Good; occasional delay on mobile data |
| 5–10 | 80–180 KB | Pushing limits; noticeable delays |
| 10+ | 180 KB+ | Unreliable; queuing and message loss |

Realistic ceiling: **3–5 callers** on a phone (Termux), **5–10** on a wired Linux machine. Lower the Opus bitrate (Settings → Opus encoding) to help at higher counts.

</details>




<details>
<summary><strong>Settings that require a restart</strong></summary>

<br>

These are written into [`torrc`](https://2019.www.torproject.org/docs/tor-manual.html.en) and read only at Tor startup — the running process can't reload them mid-session:

- **ExcludeNodes / country exclusions** — Settings → Tor settings → Country exclusions
- **Single-hop mode** — Settings → Tor settings → Single-hop mode
- **LISTEN_PORT** — edit `.env`

Everything else (cipher, bitrate, HMAC, PTT mode) takes effect immediately, even mid-call. To restart: press **0** to exit, then re-run `docker compose run --rm partyline`.

</details>




<details>
<summary><strong>Exclude countries from Tor circuits (Five Eyes / Nine Eyes / Fourteen Eyes)</strong></summary>

<br>

Tor builds circuits through relays in countries all over the world. This setting lets you exclude specific countries so your circuit never passes through a relay operating under that jurisdiction.

**In-app:** Settings → Tor settings → Country exclusions. Three presets are built in:

| Preset | Countries |
|--------|-----------|
| **Five Eyes** | US, GB, CA, AU, NZ |
| **Nine Eyes** | Five Eyes + DK, FR, NL, NO |
| **Fourteen Eyes** | Nine Eyes + DE, BE, IT, SE, ES |

The [Five Eyes](https://en.wikipedia.org/wiki/Five_Eyes) (FVEY) is a long-standing signals-intelligence sharing agreement. Nine and Fourteen Eyes expand that network with additional SIGINT partners. Excluding these countries reduces the chance of your circuit passing through a relay operated in a jurisdiction that participates in mass-surveillance data sharing.

A **Custom** option lets you enter any combination of country codes in Tor format (`{CC}`, comma-separated). A full reference table of ~80 countries is shown in the Settings menu.

**CLI:**
```bash
./partyline.sh --exclude-nodes '{US},{GB},{CA},{AU},{NZ}'
```

**`.env` (Docker):**
```env
EXCLUDE_NODES={US},{GB},{CA},{AU},{NZ},{DK},{FR},{NL},{NO}
```

**What this does — and doesn't do:**

- ✅ Prevents your circuit from being routed *through* relays in the excluded countries
- ✅ Reduces passive traffic-analysis exposure to those intelligence communities
- ❌ Does **not** hide from your own ISP that you're using Tor
- ❌ Does **not** prevent your ISP's upstream network path from crossing excluded jurisdictions before reaching the Tor network — that's outside Tor's control
- ❌ Shrinking the usable relay pool can slow circuit build time and hurt reliability on networks with few non-excluded relays

> **Note:** ExcludeNodes is a `torrc` directive — it takes effect only when Tor starts. Changing it mid-session requires an app restart. The Tor Project recommends using this feature sparingly and with awareness of the reliability trade-off.

</details>




<details>
<summary><strong>Security model</strong></summary>

<br>

| Property | Notes |
|----------|-------|
| **Encryption** | AES-256-CBC + [PBKDF2](https://datatracker.ietf.org/doc/html/rfc8018) (100k iterations). 21 cipher options (AES/Camellia/ARIA in CBC/CTR/CFB/OFB + ChaCha20). No AEAD/GCM — [`openssl enc`](https://www.openssl.org/docs/man3.0/man1/openssl-enc.html) can't stream them. |
| **Secret storage** | Shared secret encrypted at rest; passphrase required to load. |
| **HMAC signing** | Optional. Cryptographically signs every protocol message; prevents replay attacks. |
| **Overwrite before delete** | Optional (Settings → Security). Random-overwrites every temp file (recordings, chunks, payloads, nonce logs) before deletion. **SSD caveat:** wear-leveling defeats this — full-disk encryption ([LUKS](https://gitlab.com/cryptsetup/cryptsetup)/[FileVault](https://support.apple.com/en-us/102650)) is the only reliable defense against physical recovery. |
| **Zero-knowledge relay** | Forwards encrypted blobs. Never receives the shared secret. Cannot decrypt audio. |
| **No forward secrecy** | Compromise of the shared secret exposes all calls made with it. Rotate secrets between sensitive conversations. |
| **Authentication** | Callers identified by `.onion` address + pre-shared secret. No certs, no key exchange, no accounts — anyone with the secret can call in. |
| **Flood / DoS protection** | The relay holds no secret, so it can't verify traffic — instead it **rate-limits each caller** (`RELAY_MAX_MSG_PER_SEC`, default 15/s) and **drops oversized or excess messages** before fan-out, so no one caller can flood, mute, or fork-bomb the group. The sender also **caps push-to-talk length** (`MAX_PTT_SECONDS`, default 120 s), **audio size** (`MAX_AUDIO_B64`), and **text length**; receivers drop messages over `MAX_MSG_B64`. All tunable via `.env` — see [Configuration](#-reference). These drops are **intentional**, not bugs. |

</details>




<details id="-architecture">
<summary><strong>Architecture & code map</strong></summary>

<br>

**Audio pipeline** — push-to-talk, half-duplex: one complete recording per PTT press, sent as a single packet. No live streaming.

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
Base64 ──▶ socat ──▶ Tor ──▶ socat ──▶ Receive
```

**Wire protocol** — line-based text over TCP through the Tor hidden service:

| Message | Meaning |
|---------|---------|
| `ID:<onion>` | Sender's `.onion` address |
| `CIPHER:<name>` | Sender's active cipher (on connect + on change) |
| `PTT_START` / `PTT_STOP` | Recording start/end boundaries |
| `AUDIO:<base64>` | Complete encrypted audio message |
| `MSG:<base64>` | Encrypted text message |
| `HANGUP` / `PING` | Disconnect / keepalive |
| `RELAY:1` | Relay greeting → triggers group mode on the receiver |
| `GROUP:<n>` | Group size update, broadcast when callers join or leave |

> **Cipher mismatch:** decryption fails silently when both sides differ. The call header shows a red ● when the exchanged `CIPHER:` values don't match. Fix via **S → Settings** mid-call.

**Container layout:**

```text
docker compose run --rm partyline
        │
        ▼
[entrypoint.sh]  (root)
  1. Fix /var/lib/tor permissions (chown debian-tor:debian-tor)
  2. Generate /tmp/partyline.torrc from saved config
  3. tor -f torrc &  (User debian-tor → drops privileges on start)
  4. Wait for "Bootstrapped 100%"
  5. Wait for hidden_service/hostname
  6. exec /partyline.sh
        │
        ▼
[partyline.sh]  (interactive TTY required)
  Codec:    opusenc / opusdec  (8 kHz, 16 kbps, speech)
  Encrypt:  openssl enc aes-256-cbc -pbkdf2 -iter 100000
  HMAC:     openssl dgst -sha256 -hmac  (optional)
  Transport: socat SOCKS4A:127.0.0.1:9050 (outbound via Tor)
             socat TCP-LISTEN:7777        (inbound)
  QR code:  qrencode -t ANSIUTF8

[Volumes]
  ./data/docker/tor       (bind mount) → /var/lib/tor       (.onion key pair, Tor state)
  ./data/docker/partyline (bind mount) → /data/.partyline   (encrypted secret, config, FIFOs)
```

**Code map** — all logic lives in `partyline.sh` (5 597 lines total):

| Lines | Contents |
|-------|---------|
| 1–153 | Config globals, Docker/script detection, color codes, platform & Homebrew setup |
| 154–508 | Core helpers: logging, config load/save, dep check, package-manager wrappers (`_pm_init`, `pm_install`, …) |
| 509–659 | Audio backend detection (`detect_audio_backend`, `_server_available`, ALSA probes) |
| 660–942 | Dependency install/uninstall (`install_deps`, `uninstall_all`) |
| 943–1246 | Tor management: `setup_tor`, `install_snowflake`, `_tor_spawn/wait`, `start/stop_tor`, `rotate_onion` |
| 1247–1566 | Vanity onion, Docker Tor restart, country codes, circuit hops (`generate_vanity_onion`, `get_circuit_hops`) |
| 1567–1758 | Secrets, cipher helpers, encryption, HMAC protocol signing (`encrypt_file`, `proto_send`/`proto_verify`) |
| 1759–2053 | Audio pipeline: record, play, PTT send/stop (`_record_raw`, `_play_with`, `stop_and_send`, `play_chunk`) |
| 2054–2568 | Call infrastructure: cleanup, auto-listener, wakelock, `listen_for_call`, `_dial_remote`, `call_remote` |
| 2569–2983 | Relay mode, call header drawing, circuit refresh (`relay_mode`, `broadcast_count`, `draw_call_header`) |
| 2984–3426 | `in_call_session` — PTT event loop, receive handler, mid-call settings |
| 3427–3656 | `test_audio`, `show_status` |
| 3657–4152 | Audio device menus: picker, Android flow, noise generator, output tester, diagnostics, `audio_menu` |
| 4153–4867 | Settings menus: Opus, PTT, Tor, ports, single-hop, country exclusions (`settings_menu` + sub-menus) |
| 4868–5043 | Security settings: HMAC, overwrite-on-delete (`settings_security`, `settings_hmac`, `settings_overwrite_delete`) |
| 5044–5310 | Banner and main menu (`show_banner`, `main_menu`) |
| 5312–5488 | CLI interface: `print_cli_help`, `parse_args`, `_cli_getval`, `apply_cli_overrides` |
| 5489–5597 | Entry point: bootstrap, dep check, Tor start, command dispatch |

`entrypoint.sh` is Docker-only: sets `/var/lib/tor` permissions, generates `torrc`, starts Tor as `debian-tor`, waits for bootstrap, then `exec`s `partyline.sh`.

</details>


---

## ❓ FAQ

**Can the relay or anyone in the middle hear me?**
No — audio is encrypted end-to-end before it hits the network, and the relay never receives the shared secret.

**Do I need port forwarding?**
No. Tor hidden services handle inbound through Tor itself — it works behind NAT, CGNAT, and firewalls.

**Can someone find my IP?**
No — onion routing hides both ends. (Exception: single-hop mode, off by default, trades anonymity for speed.)

**Why push-to-talk instead of a real phone call?**
Tor latency and bandwidth make full-duplex unreliable. PTT sends a complete clip per transmission, which survives Tor. Expect a few seconds of end-to-end latency — that's Tor, not the app.

**Do I need an account or phone number?**
None. Your identity is your `.onion` address; authentication is the shared secret.

**How do I audit it?**
Read `partyline.sh` — one Bash file, [code map](#-architecture) above. No binaries, no telemetry, no network calls except via Tor.

**Tor is blocked on my network.**
Enable [Snowflake](#snowflake) (Script only).

**What does Tor NOT protect against?**
No forward secrecy (rotate secrets regularly). It doesn't hide *that* you're using Tor — use Snowflake if that matters. SSDs defeat overwrite-on-delete — use full-disk encryption.

**Is it legal?**
Tor and end-to-end encryption are legal in most countries. Comply with your local law.


---

## 🔀 Alternatives

Here are some other related projects:

| Tool | Hides IP | No account | Voice | Group | Notes |
|------|:---:|:---:|:---:|:---:|------|
| **🧅 Tor Party Line** | ✅ Tor | ✅ | ✅ PTT | ✅ | Terminal, single script; half-duplex |
| [Mumble](https://www.mumble.info/) | ❌ | ✅ | ✅ full-duplex | ✅ | Low-latency, required software |
| [Jami](https://jami.net/) | ⚠️ P2P | ✅ | ✅ full-duplex | ✅ | Serverless GUI; metadata via DHT |
| [Briar](https://briarproject.org/) | ✅ Tor | ✅ | ❌ | ✅ | Tor messaging, no voice |
| [Cwtch](https://cwtch.im/) | ✅ Tor | ✅ | ❌ | ✅ | Metadata-resistant text, no voice |
| [Signal](https://signal.org/) | ❌ | ❌ | ✅ full-duplex | ✅ | Great E2EE; needs a phone number |
| [OnionShare](https://onionshare.org/) | ✅ Tor | ✅ | ❌ | ⚠️ | Tor files + chat, not voice |


---

## 🙏 Credits

This project is built upon [TerminalPhone](https://gitlab.com/here_forawhile/terminalphone) by [here_forawhile](https://gitlab.com/here_forawhile).


---

## 📄 License

MIT — see [LICENSE](LICENSE).
