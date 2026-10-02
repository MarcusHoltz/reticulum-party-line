#!/usr/bin/env bash
# Reticulum Party Line - Encrypted Push-to-Talk Voice & Group Bridge over Reticulum
# Forked from TerminalPhone by here_forawhile
# Cross-platform: Docker, Linux (script mode), macOS, Android/Termux
# License: MIT

set -euo pipefail

# Re-exec under bash if launched under another shell (zsh is the macOS default and
# cannot parse bash-only constructs). macOS ships /bin/bash (3.2); this script stays
# within 3.2 features, so a plain `bash` is enough — no Homebrew bash required. This
# must run before any bash-specific syntax is parsed, so it sits at the very top.
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    echo "This script requires bash. Run:  bash rns-party-line.sh" >&2
    exit 1
fi

#=============================================================================
# CONFIGURATION
#=============================================================================
APP_NAME="Reticulum Party Line"
VERSION="2.1.0"
BASE_DIR="$(cd "$(dirname "$0")" && pwd -P)"

# ─── Docker mode detection ────────────────────────────────────────────────────
# MUST come before path assignments so all derived paths use the correct DATA_DIR.
# DOCKER_MODE=1 is set by the docker Dockerfile (ENV). When active,
# docker-entrypoint.sh has already set up the environment.
# When DOCKER_MODE=0 (script mode), full original behavior on any platform.
DOCKER_MODE="${DOCKER_MODE:-0}"

if [ $DOCKER_MODE -eq 1 ]; then
    DATA_DIR="${DATA_DIR:-/app/data}"                      # PLAN §20.6 persistent
    RUNTIME_DIR="${RUNTIME_DIR:-/dev/shm/partyline-$$}"    # tmpfs; compose sizes /dev/shm
else
    DATA_DIR="${DATA_DIR:-$BASE_DIR/data/script}"
    RUNTIME_DIR="${RUNTIME_DIR:-/dev/shm/partyline-$$}"    # Linux tmpfs; Termux/macOS override below
fi
# PLAN §20.5, §20.6 split:
#   DATA_DIR      persistent   -- shared_secret, config, RNS identity, destination
#   RUNTIME_DIR   ephemeral    -- audio, run/, pids, RNS storage/, bridge deploy
# ONION_FILE stays under DATA_DIR because get_onion() should return the same
# address across restarts (it's derived from the persistent identity).
ONION_FILE="$DATA_DIR/destination"
# ─────────────────────────────────────────────────────────────────────────────

# Persistent (survive reboot): shared secret, saved config, identity, address.
SECRET_FILE="$DATA_DIR/shared_secret"
CONFIG_FILE="$DATA_DIR/config"

# Ephemeral (RUNTIME_DIR on tmpfs -- PLAN §19.1, §20.5). Plaintext audio, run
# flags, pipe FIFOs, pid files, and every $$-scoped file live here so nothing
# from a call touches persistent media.
AUDIO_DIR="$RUNTIME_DIR/audio"
PID_DIR="$RUNTIME_DIR/pids"
PTT_FLAG="$RUNTIME_DIR/run/ptt_$$"
CONNECTED_FLAG="$RUNTIME_DIR/run/connected_$$"
MENU_FLAG="$RUNTIME_DIR/run/menu_$$"                # background recv loop suppression during menus
DROP_REASON_FILE="$RUNTIME_DIR/run/drop_reason_$$"  # why the last call ended: "hangup" or "lost"
RECV_PIPE="$RUNTIME_DIR/run/recv_$$"
SEND_PIPE="$RUNTIME_DIR/run/send_$$"
CIPHER_RUNTIME_FILE="$RUNTIME_DIR/run/cipher_$$"
HMAC_RUNTIME_FILE="$RUNTIME_DIR/run/hmac_$$"
NONCE_LOG_FILE="$RUNTIME_DIR/run/nonces_$$"
AUTO_LISTEN_FLAG="$RUNTIME_DIR/run/autolisten_$$"
AUTO_LISTEN_PID=""


# Defaults
# Options exposed as CLI flags also accept a value from the environment (the
# ${VAR:-default} form), so a Docker `.env` value forwarded by docker-compose is
# honored instead of overwritten. This mirrors ALSA_DEVICE below and gives
# Docker users `.env` parity with the command-line flags. A saved config
# (load_config) and then CLI flags (apply_cli_overrides) still take precedence.

# ─── Reticulum transport (PLAN.md §11.7, §17, §20.6) ────────────────────────
# Replaces Tor. Under DOCKER_MODE these arrive via docker-compose env; on the
# host they fall back to dev defaults.
REFLECTOR_HOST="${REFLECTOR_HOST:-}"           # TCPClientInterface target host (client role only)
REFLECTOR_PORT="${REFLECTOR_PORT:-4242}"       # TCP transport port for both roles
RNS_LISTEN_HOST="${RNS_LISTEN_HOST:-0.0.0.0}"  # bind ip for the reflector's TCPServerInterface

# Public Reticulum backbone transport nodes, dialled outbound by both roles.
# This is what makes the no-open-ports case work: relay and caller each open
# an outbound TCP connection to a shared transport node, which routes between
# them, so neither end needs a reachable port and host firewalls are a
# non-issue. Seeds only; RNS_AUTOCONNECT lets RNS find more peers itself as
# volunteer nodes come and go. Overridable, and settable to "" to opt out.
# Verified reachable 2026-08-25; current list at https://directory.rns.recipes/
RNS_HUBS="${RNS_HUBS:-rns.mari-el.net:4242,use.inertia.chat:4242,45.77.109.86:4965,suah.dev:4343,sydney.reticulum.au:4242}"
RNS_AUTOCONNECT="${RNS_AUTOCONNECT:-4}"        # max discovered backbone peers to add on top of RNS_HUBS
RNS_IDENTITY_FILE="${RNS_IDENTITY_FILE:-$DATA_DIR/identity}"     # persistent identity (PLAN §20.2)
RNS_CONFIG_DIR="${RNS_CONFIG_DIR:-$RUNTIME_DIR/reticulum}"       # RNS storage on tmpfs (PLAN §19.3)
BRIDGE_PY_SOURCE="${BRIDGE_PY_SOURCE:-$BASE_DIR/rns_bridge.py}"  # dev source; §16.1 will make this an embedded heredoc
BRIDGE_PY="${BRIDGE_PY:-$RUNTIME_DIR/rns_bridge.py}"             # emitted copy actually invoked (tmpfs)
FD_ENGINE_PY="${FD_ENGINE_PY:-$RUNTIME_DIR/fullduplex_engine.py}" # emitted from embedded heredoc
# Reticulum lives in a venv under DATA_DIR rather than in the system Python.
# Distros increasingly ship a PEP 668 "externally managed" interpreter (Arch,
# Debian 12+, Fedora 38+) where a plain `pip install rns` is refused outright,
# and Arch ships no system pip at all, so the README's old bare `pip install
# rns` could not work there. A venv is the one path that behaves the same on
# every distro without touching system packages, and it keeps uninstall honest
# (one directory to delete, inside DATA_DIR, instead of guessing what pip did).
# An explicit BRIDGE_PYTHON in the environment still wins, and a system-wide
# RNS is still used when no venv exists, so existing installs keep working.
PL_VENV="${PL_VENV:-$DATA_DIR/venv}"
if [ -z "${BRIDGE_PYTHON:-}" ] && [ -x "$PL_VENV/bin/python" ]; then
    BRIDGE_PYTHON="$PL_VENV/bin/python"
fi
BRIDGE_PYTHON="${BRIDGE_PYTHON:-python3}"
RELAY_IDLE_TIMEOUT="${RELAY_IDLE_TIMEOUT:-240}"   # relay: drop a caller after N s of total silence (no audio/chat/PING)
                                                  # must exceed MAX_PTT_SECONDS + HEARTBEAT_INTERVAL + encode/transport overhead:
                                                  #   worst-case gap = 120 (recording, PTT_FLAG suppresses PING) + encode + RNS latency
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-20}"    # client: send PING every N s so silence is not mistaken for a dropout
                                                  # keep well below RELAY_IDLE_TIMEOUT; RELAY_IDLE_TIMEOUT must stay > MAX_PTT_SECONDS + this value
CLIENT_TIMEOUT="${CLIENT_TIMEOUT:-180}"           # client: treat no inbound traffic for N s as a dropped connection (must exceed the relay's ~10s GROUP beacon)
RECONNECT_ATTEMPTS="${RECONNECT_ATTEMPTS:-3}"     # client: re-dial this many times after a detected drop before giving up to the menu
DIAL_ATTEMPTS="${DIAL_ATTEMPTS:-3}"              # client: retry initial dial this many times before giving up
DIAL_TIMEOUT="${DIAL_TIMEOUT:-60}"               # client: per-attempt timeout in seconds for bridge connect (the bridge
                                                 # has its own --path-timeout 30 + --link-timeout 20 = 50 s worst case,
                                                 # so this outer backstop must exceed that to avoid killing a bridge
                                                 # that is making progress; 60 s gives 10 s margin)
OPUS_BITRATE="${OPUS_BITRATE:-16}"       # kbps — good balance of quality and bandwidth for Reticulum
OPUS_FRAMESIZE=60     # ms
SAMPLE_RATE=8000      # Hz
MACOS_AUDIO_INDEX="${MACOS_AUDIO_INDEX:-0}"  # avfoundation audio input device index (":0" is the default mic); pick via the macOS audio menu
PTT_KEY=" "           # spacebar
CHUNK_DURATION=1      # seconds per audio chunk
CIPHER="${CIPHER:-aes-256-cbc}"          # OpenSSL cipher for encryption
AUTO_LISTEN="${AUTO_LISTEN:-0}"          # Auto-listen at startup (off by default)
VOL_PTT=0             # Volume-down double-tap PTT (Termux only, experimental)
PTT_TOGGLE_MODE=0     # Desktop: 1 = press-to-start/press-again-to-stop toggle (Termux is always toggle)
HMAC_AUTH="${HMAC_AUTH:-1}"              # HMAC-sign all protocol messages (on by default)

NORMALIZE_PLAYBACK="${NORMALIZE_PLAYBACK:-0}"  # Normalize received audio volume (0=off, 1=on)
FULL_DUPLEX="${FULL_DUPLEX:-0}"                # Full-duplex audio (0=PTT, 1=full-duplex; requires TCP-class transport)
OVERWRITE_DELETE=0    # Overwrite temp files with random data before deletion (off by default)
START_MUTED="${START_MUTED:-1}"  # Start full-duplex sessions muted (1=muted, 0=live)
ALSA_DEVICE="${ALSA_DEVICE:-}"   # Override ALSA device; preserves env var if set by docker-compose
ALSA_PLAY_DEVICE="${ALSA_PLAY_DEVICE:-}"  # Override ALSA playback device (preserves env var)
PULSE_SOURCE="${PULSE_SOURCE:-}" # PipeWire/PulseAudio capture device name; empty = system default
PULSE_SINK="${PULSE_SINK:-}"     # PipeWire/PulseAudio playback device name; empty = system default
MAX_LINE_BYTES="${MAX_LINE_BYTES:-524288}"       # relay: drop inbound lines > this many bytes (default 512KB)
MAX_MSG_B64="${MAX_MSG_B64:-65536}"             # client: drop MSG: base64 payloads > this many bytes (default 64KB ≈ 48KB text)
DECRYPT_TIMEOUT="${DECRYPT_TIMEOUT:-10}"        # seconds before killing a stalled openssl decrypt
RELAY_WRITE_TIMEOUT="${RELAY_WRITE_TIMEOUT:-30}"  # relay: abandon a blocked FIFO write to a slow/stalled client after N s
                                                  # 30 s gives ample headroom for a 28 KB AUDIO: chunk over RNS; matches handler.sh fallback
MAX_PTT_SECONDS="${MAX_PTT_SECONDS:-120}"        # send: hard cap on one push-to-talk transmission (anti-flood; ~320KB base64 at 16kbps, under MAX_LINE_BYTES)
PTT_CHUNK_SECONDS="${PTT_CHUNK_SECONDS:-10}"     # send: split PTT audio into chunks of this many seconds before encoding+sending
MAX_AUDIO_B64="${MAX_AUDIO_B64:-$MAX_LINE_BYTES}" # send: skip an AUDIO: blob whose base64 exceeds this (defaults to the relay line cap; bitrate-robust backstop)
RELAY_MAX_MSG_PER_SEC="${RELAY_MAX_MSG_PER_SEC:-15}" # relay: drop a caller's messages beyond this many per second (anti-flood; audio is ~1/s)
RELAY_MAX_INFLIGHT="${RELAY_MAX_INFLIGHT:-64}"   # relay: cap concurrent background FIFO-forward processes (fork-bomb guard)

# Capture whether ALSA devices came from the ENVIRONMENT (.env / Docker / shell)
# *before* load_config later overwrites ALSA_DEVICE from the saved config. An
# env-provided device is a deliberate hard ALSA override (bare-ALSA / headless /
# Docker escape hatch); a value that only appears from the saved config is a
# soft preference that yields to a working sound server.
ALSA_DEVICE_ENV="${ALSA_DEVICE:-}"
ALSA_PLAY_DEVICE_ENV="${ALSA_PLAY_DEVICE:-}"

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m' # No Color
BG_GREEN='\033[42m'
RNS_PURPLE='\033[38;2;125;70;152m'

# Platform detection
IS_TERMUX=0
IS_MACOS=0
if [ -n "${TERMUX_VERSION:-}" ] || { [ -n "${PREFIX:-}" ] && [[ "${PREFIX:-}" == *"com.termux"* ]]; }; then
    IS_TERMUX=1
elif [[ "$(uname -s)" == "Darwin" ]]; then
    IS_MACOS=1
fi

# /dev/shm does not exist on Android or macOS. Override RUNTIME_DIR (and every
# path derived from it) when the default was not replaced by the environment.
if [ $DOCKER_MODE -eq 0 ] && [[ "$RUNTIME_DIR" == /dev/shm/* ]]; then
    _old_rt="$RUNTIME_DIR"
    if [ $IS_TERMUX -eq 1 ]; then
        RUNTIME_DIR="$PREFIX/tmp/partyline-$$"
    elif [ $IS_MACOS -eq 1 ]; then
        RUNTIME_DIR="${TMPDIR%/}/partyline-$$"
    fi
    if [ "$RUNTIME_DIR" != "$_old_rt" ]; then
        AUDIO_DIR="$RUNTIME_DIR/audio"
        PID_DIR="$RUNTIME_DIR/pids"
        PTT_FLAG="$RUNTIME_DIR/run/ptt_$$"
        CONNECTED_FLAG="$RUNTIME_DIR/run/connected_$$"
        MENU_FLAG="$RUNTIME_DIR/run/menu_$$"
        DROP_REASON_FILE="$RUNTIME_DIR/run/drop_reason_$$"
        RECV_PIPE="$RUNTIME_DIR/run/recv_$$"
        SEND_PIPE="$RUNTIME_DIR/run/send_$$"
        CIPHER_RUNTIME_FILE="$RUNTIME_DIR/run/cipher_$$"
        HMAC_RUNTIME_FILE="$RUNTIME_DIR/run/hmac_$$"
        NONCE_LOG_FILE="$RUNTIME_DIR/run/nonces_$$"
        AUTO_LISTEN_FLAG="$RUNTIME_DIR/run/autolisten_$$"
        RNS_CONFIG_DIR="$RUNTIME_DIR/reticulum"
        BRIDGE_PY="$RUNTIME_DIR/rns_bridge.py"
    fi
    unset _old_rt
fi

# Ensure Homebrew is in PATH on macOS (Apple Silicon: /opt/homebrew, Intel: /usr/local)
# BREW_ARCH holds an "arch -arch" prefix so brew runs under the architecture that
# matches its prefix. This avoids the "Cannot install under Rosetta 2 in ARM default
# prefix" error when the script itself is launched as an x86_64 (Rosetta) process.
BREW_ARCH=""
if [ $IS_MACOS -eq 1 ]; then
    for _brew_prefix in /opt/homebrew /usr/local; do
        if [ -x "$_brew_prefix/bin/brew" ]; then
            export PATH="$_brew_prefix/bin:$_brew_prefix/sbin:$PATH"
            # /opt/homebrew is the ARM prefix; force arm64 so a Rosetta shell can still use it.
            if [ "$_brew_prefix" = "/opt/homebrew" ] && [ "$(uname -m)" = "x86_64" ]; then
                BREW_ARCH="arch -arm64"
            fi
            break
        fi
    done
    # Homebrew's openssl is keg-only (never symlinked onto PATH), so `openssl` would
    # otherwise resolve to the system LibreSSL, whose `enc -pbkdf2` support is
    # unreliable across macOS versions. Prepend the openssl keg bin so the
    # already-installed OpenSSL is used, keeping -pbkdf2 interop with Linux peers.
    # Guarded by a dir check, so a not-yet-installed openssl is a harmless no-op.
    if command -v brew >/dev/null 2>&1; then
        _ssl_bin="$(brew --prefix openssl 2>/dev/null)/bin"
        [ -d "$_ssl_bin" ] && export PATH="$_ssl_bin:$PATH"
    fi
fi
# Run brew under the correct architecture (no-op prefix when BREW_ARCH is empty).
brew_run() {
    $BREW_ARCH brew "$@"
}

# State
AUDIO_BACKEND=""      # Capture backend, detected at first use: "pulse" | "alsa" | "ffmpeg" | "termux" | "none"
PLAY_PLAYER=""        # Playback program chosen by probe: "pw-play" | "paplay" | "aplay"
PLAY_DEV=""           # Playback device/target for PLAY_PLAYER (empty = system default)
REC_PID=""
REC_FILE=""
VOL_MON_PID=""        # Termux volume-PTT monitor PID
LAST_SENT_INFO=""

CALL_ACTIVE=0
ORIGINAL_STTY=""

#=============================================================================
# HELPERS
#=============================================================================

# Portable case conversion (works with Bash 3.2 on macOS)
to_upper() { tr '[:lower:]' '[:upper:]' <<<"$1"; }
to_lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

# Colored enabled/disabled label for a boolean (1=on) setting, for use inside
# `echo -e`. Optional second arg overrides the "enabled" color (default GREEN).
onoff_label() {
    if [ "${1:-0}" -eq 1 ] 2>/dev/null; then
        printf '%s' "${2:-$GREEN}enabled${NC}"
    else
        printf '%s' "${RED}disabled${NC}"
    fi
}

# Section banner printed at the top of every menu/screen. Second arg overrides
# the rule color (default CYAN; the uninstaller passes RED).
header() { echo -e "\n${BOLD}${2:-$CYAN}═══ $1 ═══${NC}\n"; }

# Standard feedback for an unrecognized menu choice, then a brief beat.
menu_invalid() { echo -e "\n  ${RED}Invalid choice${NC}"; sleep 1; }

# Block until the user presses Enter before the screen is redrawn.
pause() { echo -ne "\n  ${DIM}Press Enter to continue...${NC}"; read -r _; }

# Yes/No confirmation. The prompt is printed with `echo -ne`, so it may contain
# color codes and \n. confirm_yes treats Enter/empty as yes; confirm_no treats
# Enter/empty as no. Only a bare y/Y or n/N flips the default (matches the prior
# inline checks exactly). Both return 0 for yes, 1 for no.
confirm_yes() { local _r; echo -ne "$1"; read -r _r; case "$_r" in n|N) return 1 ;; *) return 0 ;; esac; }
confirm_no()  { local _r; echo -ne "$1"; read -r _r; case "$_r" in y|Y) return 0 ;; *) return 1 ;; esac; }

# Terminate a PID: SIGTERM, then SIGKILL after a short grace period if it is
# still alive, then reap it so FIFOs/handles are fully released.
kill_pid() {
    local p="$1"
    [ -n "$p" ] || return 0
    kill "$p" 2>/dev/null || true
    if kill -0 "$p" 2>/dev/null; then
        sleep 0.3
        kill -9 "$p" 2>/dev/null || true
    fi
    wait "$p" 2>/dev/null || true
}

# Lowercase a string. Portable replacement for bash-4's ${var,,}, which macOS's
# native bash 3.2 does not support.
_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Portable file size (macOS stat uses -f%z, GNU stat uses -c%s)
file_size() {
    if [ $IS_MACOS -eq 1 ]; then
        stat -f%z "$1" 2>/dev/null || echo 0
    else
        stat -c%s "$1" 2>/dev/null || echo 0
    fi
}

# Overwrite-before-delete wrapper — overwrites files with random data before
# removal when OVERWRITE_DELETE=1. Falls back to standard rm otherwise.
# Note: On SSDs, overwriting does not guarantee erasure of the original data
# due to wear leveling. Full-disk encryption is the only reliable defense.
# Usage: overwrite_rm [-r] file1 [file2 ...]
overwrite_rm() {
    local recursive=0
    if [ "${1:-}" = "-r" ]; then
        recursive=1
        shift
    fi

    for target in "$@"; do
        [ -e "$target" ] || continue

        if [ "$OVERWRITE_DELETE" -eq 1 ] 2>/dev/null; then
            if [ -d "$target" ]; then
                find "$target" -type f 2>/dev/null | while IFS= read -r _sr_f; do
                    local _sr_sz
                    _sr_sz=$(file_size "$_sr_f")
                    if [ "$_sr_sz" -gt 0 ] 2>/dev/null; then
                        dd if=/dev/urandom of="$_sr_f" bs="$_sr_sz" count=1 conv=notrunc 2>/dev/null || true
                        sync "$_sr_f" 2>/dev/null || true
                    fi
                done
            elif [ -f "$target" ]; then
                local _sr_sz
                _sr_sz=$(file_size "$target")
                if [ "$_sr_sz" -gt 0 ] 2>/dev/null; then
                    dd if=/dev/urandom of="$target" bs="$_sr_sz" count=1 conv=notrunc 2>/dev/null || true
                    sync "$target" 2>/dev/null || true
                fi
            fi
        fi

        if [ "$recursive" -eq 1 ] || [ -d "$target" ]; then
            rm -rf "$target" 2>/dev/null || true
        else
            rm -f "$target" 2>/dev/null || true
        fi
    done
}

cleanup() {
    # Capture the exit status before any command clobbers it. `set -e` aborts
    # on the first failed command, then this trap still runs — so without this
    # the failure is reported to the user as a successful shutdown.
    local _exit_status=$?

    # Restore terminal
    if [ -n "$ORIGINAL_STTY" ]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || true
    fi
    stty sane 2>/dev/null || true

    # Kill background processes
    kill_bg_processes

    # PLAN §20.6: RUNTIME_DIR is a tmpfs, so a coarse rm -rf on it clears
    # audio, run/, pids/, relay/, RNS storage, and the emitted bridge in
    # one shot. If RUNTIME_DIR points somewhere unusual, leave it alone.
    if [ -n "$RUNTIME_DIR" ] && [[ "$RUNTIME_DIR" == /dev/shm/* || "$RUNTIME_DIR" == /tmp/* || "$RUNTIME_DIR" == */com.termux/*/tmp/* || "$RUNTIME_DIR" == /var/folders/* ]]; then
        rm -rf "$RUNTIME_DIR" 2>/dev/null || true
    else
        overwrite_rm "$PTT_FLAG" "$CONNECTED_FLAG" "$MENU_FLAG" "$RECV_PIPE" "$SEND_PIPE"
        overwrite_rm -r "$AUDIO_DIR"
    fi

    if [ "$_exit_status" -eq 0 ]; then
        echo -e "\n${GREEN}${APP_NAME} shut down cleanly.${NC}"
    else
        echo -e "\n${RED}${APP_NAME} exited with error (status $_exit_status).${NC}"
    fi
}

kill_bg_processes() {
    # Kill any child processes
    local pids
    pids=$(jobs -p 2>/dev/null) || true
    if [ -n "$pids" ]; then
        kill $pids 2>/dev/null || true
        wait $pids 2>/dev/null || true
    fi

    # Kill stored PIDs
    if [ -d "$PID_DIR" ]; then
        for pidfile in "$PID_DIR"/*.pid; do
            [ -f "$pidfile" ] || continue
            local pid
            pid=$(cat "$pidfile" 2>/dev/null) || continue
            kill "$pid" 2>/dev/null || true
        done
        rm -f "$PID_DIR"/*.pid 2>/dev/null || true
    fi
}

save_pid() {
    local name="$1" pid="$2"
    mkdir -p "$PID_DIR"
    echo "$pid" > "$PID_DIR/${name}.pid"
}

log_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

log_ok() {
    echo -e "${GREEN}[  OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_err() {
    echo -e "${RED}[FAIL]${NC} $1"
}

# ─── Reticulum bridge deployment (PLAN §16.1 one-file constraint) ──────────
# The RNS transport bridge is embedded as a quoted heredoc in
# _emit_rns_bridge below and extracted to $BRIDGE_PY at startup. This
# mirrors how handler.sh is emitted further down, and the heredoc is the
# authoritative copy: this script is the whole program.
#
# BRIDGE_PY_SOURCE is a dev shortcut. rns_bridge.py is an untracked scratch
# extract of the heredoc (see tools/embed_bridge.py) so the Python can be
# edited with real tooling; when that file is present it wins, so edits take
# effect without re-embedding first. It is not in git, so a clone or a
# released single file always runs the heredoc. Run
# `tools/embed_bridge.py --check` before committing to catch the case where
# the scratch file was edited but never folded back in.
write_rns_bridge() {
    mkdir -p "$(dirname "$BRIDGE_PY")" "$RNS_CONFIG_DIR" "$(dirname "$RNS_IDENTITY_FILE")"
    if ! command -v "$BRIDGE_PYTHON" >/dev/null 2>&1; then
        log_err "$BRIDGE_PYTHON not on PATH"
        return 1
    fi

    # Stage, validate, then rename into place. Two bridges can be brought up
    # in one container (auto-listener plus a call) and compose pins a single
    # RUNTIME_DIR for all of them, so writing $BRIDGE_PY directly means one
    # can truncate the file another is starting from. The rename is atomic,
    # so a starting interpreter sees either the old file or the new one.
    local staged="${BRIDGE_PY}.$$"
    if [ -n "${BRIDGE_PY_SOURCE:-}" ] && [ -f "$BRIDGE_PY_SOURCE" ]; then
        cp "$BRIDGE_PY_SOURCE" "$staged" || return 1
    else
        _emit_rns_bridge "$staged" || { rm -f "$staged"; return 1; }
    fi

    # A drifted or truncated bridge otherwise dies as a SyntaxError inside a
    # redirected stderr file nobody reads, surfacing only as "did not publish
    # a destination in 30s". Fail here instead, where we can say why.
    if ! "$BRIDGE_PYTHON" -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' \
            "$staged" 2>/dev/null; then
        log_err "Bridge source is not valid Python. The embedded copy in this"
        log_err "script is corrupt, or BRIDGE_PY_SOURCE points at a broken file:"
        log_err "  ${BRIDGE_PY_SOURCE:-<embedded heredoc>}"
        rm -f "$staged"
        return 1
    fi

    mv -f "$staged" "$BRIDGE_PY" || { rm -f "$staged"; return 1; }
    return 0
}

# Bridge failures are opaque by default: rns_bridge.py writes its stderr to a
# file under $RUNTIME_DIR that nothing ever reads back, so a real diagnosis
# ("Using on-network interface discovery requires the LXMF module") surfaces
# to the user as nothing but a generic 30s timeout. Echo the tail of it
# alongside whatever error the caller is already logging.
_bridge_stderr_hint() {
    local f="$1" n="${2:-6}"
    [ -s "$f" ] || return 0
    log_err "Bridge stderr (last $n lines of $f):"
    tail -n "$n" "$f" | while IFS= read -r line; do
        echo -e "  ${DIM}| ${line}${NC}" >&2
    done
}

# The bridge lives as an embedded heredoc. The marker is single-quoted so no
# expansion or escaping happens: the body is copied out byte for byte and can
# be pasted in as-is. The one hazard is a Python line equal to the marker,
# which would end the heredoc early and run the rest as shell commands;
# tools/embed_bridge.py refuses to write in that case.
#
# $1 is where to write. Regenerate this block with:
#   tools/embed_bridge.py --extract   # heredoc -> rns_bridge.py, to edit
#   tools/embed_bridge.py --embed     # rns_bridge.py -> heredoc, when done
_emit_rns_bridge() {
    cat > "$1" << 'RNS_BRIDGE_PY_EOF'
#!/usr/bin/env python3
"""
rns_bridge.py -- reticulum-party-line transport shim.

Bridges Reticulum Links to line-oriented stdio, so rns-party-line.sh's relay_mode
(handler.sh) and _dial_remote (SEND_PIPE/RECV_PIPE) can talk over RNS with no
knowledge of RNS. Replaces the two socat addresses at rns-party-line.sh:3037 and
:2635. See PLAN.md sections 11, 15, 16.2, 17, 20.6.

Roles (first positional argv):

  listen    Reflector-side. Announces a destination, accepts incoming Links,
            and forks a handler subprocess per Link with the Link bridged to
            the handler's stdio. Everything after `--` is the handler argv,
            invoked exactly once per Link.

  connect   Client-side. Opens a Link to a known destination hash and bridges
            it to two FIFOs (SEND_PIPE / RECV_PIPE) that rns-party-line.sh already
            uses. Touches --ready-file from the link_established callback so
            that _dial_remote can wait on real link establishment instead of
            socat-process setup (PLAN.md 11.3).

Hybrid transport (PLAN.md 16.2):

  RNS.Packet    for control lines (short: PING, GROUP:, CIPHER:, HANGUP, MSG:)
  RNS.Resource  for AUDIO: lines   (large blobs, ordered assembly, integrity,
                                   explicit FAILED/CORRUPT signal)

  Anything larger than link.get_mdu() falls back to Resource regardless of
  prefix, so an unusually large MSG: does not lose bytes.
"""
import argparse
import fcntl
import io
import os
import queue
import selectors
import signal
import subprocess
import sys
import threading
import time

import RNS

APP_NAME    = "partyline"
DEST_ASPECT = "relay"

# MAX_LINE_BYTES ceiling from the host script. Keeps a hostile peer from
# asking the reflector to buffer arbitrarily much data before writing it out.
MAX_LINE_BYTES = 524_288

# Any line starting with this prefix goes on a Resource. Everything else on a
# Packet, unless it exceeds link.get_mdu() at send time.
AUDIO_PREFIX = b"AUDIO:"

# Announce cadence. PLAN.md 8.5 warns against announcing more often than every
# few hours in production. For dev / small rooms, keep it snappy.
ANNOUNCE_INTERVAL_S = int(os.environ.get("PARTYLINE_ANNOUNCE_S", "300"))


def log(msg):
    ts = time.strftime("%H:%M:%S")
    sys.stderr.write(f"[bridge {ts}] {msg}\n")
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# Classification: exposed so tests can drive it without an RNS runtime.
# ---------------------------------------------------------------------------

def wants_resource(line_bytes, mdu):
    """Return True if the line should be sent via Resource, False for Packet.

    PLAN.md 16.2: AUDIO: always Resource. Anything larger than the link MDU
    also Resource, because Packet payload > MDU on a Link will not fit.
    """
    if line_bytes.startswith(AUDIO_PREFIX):
        return True
    if len(line_bytes) > mdu:
        return True
    return False


# ---------------------------------------------------------------------------
# Common: identity + Reticulum bootstrap
# ---------------------------------------------------------------------------

def load_or_create_identity(path):
    # ensure_address (sync) and start_auto_listener (async) each run this in
    # a separate process, both racing check-then-create on first run or after
    # rotate_identity deletes the file. Without a lock, both can create and
    # write their own identity; whichever writes last wins the persisted file
    # while the already-running listener keeps using the one it loaded into
    # memory, so the address shown to the user can diverge from what's
    # actually announced. The lock file makes the pair check-then-create
    # atomic across processes: the loser blocks until the winner has written
    # the identity, then just reads it back.
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".lock", "w") as _lockfile:
        fcntl.flock(_lockfile, fcntl.LOCK_EX)
        try:
            if os.path.exists(path):
                return RNS.Identity.from_file(path)
            ident = RNS.Identity()
            ident.to_file(path)
            try:
                os.chmod(path, 0o600)
            except OSError:
                pass
            return ident
        finally:
            fcntl.flock(_lockfile, fcntl.LOCK_UN)


def _have_lxmf():
    """RNS refuses to run interface discovery without LXMF importable."""
    try:
        import LXMF  # noqa: F401
        return True
    except ImportError:
        return False


def parse_hostport(spec):
    """'host:port' -> (host, int(port)). Bare IPv6 needs [brackets]."""
    host, _, port = spec.rpartition(":")
    if not host or not port:
        raise ValueError(f"expected host:port, got '{spec}'")
    return (host.strip("[]"), int(port))


def parse_hubs(spec):
    """Comma-separated 'host:port' list -> [(host, port), ...]. '' -> []."""
    return [parse_hostport(s) for s in (spec or "").split(",") if s.strip()]


def init_reticulum(config_dir, tcp_listen=None, tcp_connect=None,
                   hubs=None, autoconnect=0):
    """Write a minimal RNS config into config_dir and bring Reticulum up.

    tcp_listen  = (ip, port)  to expose a TCPServerInterface
    tcp_connect = (host, port) to attach a TCPClientInterface
    hubs        = [(host, port), ...] public transport nodes to dial out to

    Hubs are the no-open-ports path: both ends make outbound TCP connections
    to shared transport nodes on the Reticulum backbone, which then route
    between them. Neither end has to be inbound-reachable, so NAT and host
    firewalls stop mattering. tcp_listen/tcp_connect remain for the direct
    LAN case, where one side is reachable and no backbone is wanted.

    autoconnect > 0 additionally lets RNS discover further peers from the
    network and connect to at most that many of them, so the seeded hub list
    going stale does not strand us (see the Reticulum manual, "Connect to the
    Distributed Backbone").
    """
    os.makedirs(config_dir, exist_ok=True)
    lines = [
        "[reticulum]",
        "enable_transport = No",
        "share_instance = No",
    ]
    if hubs and autoconnect > 0 and _have_lxmf():
        # Both keys live in [reticulum] and are read by RNS.Reticulum:
        # discover_interfaces collects peer info, autoconnect_discovered_
        # interfaces is an int cap on how many of those to actually dial.
        # RNS gates discovery behind LXMF and goes Critical without it, so
        # when LXMF is missing we quietly fall back to the seeded hubs only:
        # a smaller network beats a bridge that never publishes.
        lines += [
            "discover_interfaces = Yes",
            f"autoconnect_discovered_interfaces = {autoconnect}",
        ]
    lines += [
        "",
        "[logging]",
        "loglevel = 3",
        "",
        "[interfaces]",
    ]
    for i, (host, port) in enumerate(hubs or [], start=1):
        lines += [
            f"  [[Backbone Hub {i}]]",
            "    type = TCPClientInterface",
            "    enabled = Yes",
            f"    target_host = {host}",
            f"    target_port = {port}",
        ]
    if tcp_listen is not None:
        ip, port = tcp_listen
        lines += [
            "  [[TCP Server Interface]]",
            "    type = TCPServerInterface",
            "    enabled = Yes",
            f"    listen_ip = {ip}",
            f"    listen_port = {port}",
        ]
    if tcp_connect is not None:
        host, port = tcp_connect
        lines += [
            "  [[TCP Client Interface]]",
            "    type = TCPClientInterface",
            "    enabled = Yes",
            f"    target_host = {host}",
            f"    target_port = {port}",
        ]
    with open(os.path.join(config_dir, "config"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return RNS.Reticulum(configdir=config_dir)


# ---------------------------------------------------------------------------
# Per-link bridge: shared by both roles.
# ---------------------------------------------------------------------------

class LinkBridge:
    """Bidirectional bytes bridge between an RNS.Link and two file descriptors.

    inbound_fd  -- fd we write bytes received FROM the link TO
    outbound_fd -- fd we read bytes to send OVER the link FROM

    Uses a writer thread on the inbound side (PLAN.md 16.5, risk 5): if the
    downstream FIFO / pipe blocks because the consumer is busy playing audio
    or otherwise, only this thread stalls -- RNS's own receive threads stay
    responsive and the link stays healthy.
    """

    def __init__(self, link, inbound_fd, outbound_fd, label="link"):
        self.link = link
        self.inbound_fd = inbound_fd
        self.outbound_fd = outbound_fd
        self.label = label
        self.inbound_q = queue.Queue(maxsize=256)
        self.stop_evt = threading.Event()
        self._writer_thread = threading.Thread(
            target=self._writer_loop, name=f"{label}-writer", daemon=True)
        self._reader_thread = threading.Thread(
            target=self._reader_loop, name=f"{label}-reader", daemon=True)

    # -- inbound (link -> fd) --

    def deliver(self, payload_bytes):
        """Queue a fully assembled line/blob for delivery to inbound_fd.
        Called by RNS receive callbacks (packet + resource_concluded)."""
        # Preserve line framing that the source system relies on.
        if not payload_bytes.endswith(b"\n"):
            payload_bytes = payload_bytes + b"\n"
        try:
            self.inbound_q.put(payload_bytes, timeout=5)
        except queue.Full:
            log(f"{self.label}: inbound queue full, dropping {len(payload_bytes)} B")

    def _writer_loop(self):
        while not self.stop_evt.is_set():
            try:
                buf = self.inbound_q.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                # os.write is atomic for buf <= PIPE_BUF (4096 on Linux).
                # Larger payloads may be split by the kernel; loop.
                n = 0
                while n < len(buf) and not self.stop_evt.is_set():
                    written = os.write(self.inbound_fd, buf[n:])
                    if written == 0:
                        break
                    n += written
            except (BrokenPipeError, OSError) as e:
                log(f"{self.label}: inbound_fd closed ({e}); tearing down")
                self.stop()
                return

    # -- outbound (fd -> link) --

    def _reader_loop(self):
        buf = b""
        while not self.stop_evt.is_set():
            try:
                chunk = os.read(self.outbound_fd, 65536)
            except OSError as e:
                log(f"{self.label}: outbound_fd read error ({e})")
                break
            if not chunk:
                log(f"{self.label}: outbound_fd EOF")
                break
            buf += chunk
            while b"\n" in buf:
                line, _, buf = buf.partition(b"\n")
                if not line:
                    continue
                if len(line) > MAX_LINE_BYTES:
                    log(f"{self.label}: dropping oversize line ({len(line)} B)")
                    continue
                # Never let a single-line failure kill the reader thread;
                # log and keep serving the link.
                try:
                    self._send_line(line)
                except Exception as e:
                    log(f"{self.label}: send_line crashed on {len(line)} B: {e}")
        self.stop()

    def _send_line(self, line_bytes):
        # link.get_mdu() can return None briefly after establishment or during
        # teardown. Treat that the same as an exception: fall back to a small
        # conservative MDU so the classifier still makes a sane choice.
        try:
            mdu = self.link.get_mdu()
        except Exception:
            mdu = None
        if mdu is None:
            mdu = 400
        if wants_resource(line_bytes, mdu):
            try:
                RNS.Resource(line_bytes, self.link, auto_compress=False)
            except Exception as e:
                log(f"{self.label}: Resource send failed: {e}")
        else:
            try:
                RNS.Packet(self.link, line_bytes).send()
            except Exception as e:
                log(f"{self.label}: Packet send failed: {e}")

    # -- lifecycle --

    def start(self):
        self._writer_thread.start()
        self._reader_thread.start()
        # Wire up RNS callbacks that push into the inbound queue.
        self.link.set_packet_callback(self._on_packet)
        self.link.set_resource_strategy(RNS.Link.ACCEPT_APP)
        self.link.set_resource_callback(self._on_resource_advertised)
        self.link.set_resource_concluded_callback(self._on_resource_concluded)
        self.link.set_link_closed_callback(self._on_link_closed)

    def stop(self):
        if self.stop_evt.is_set():
            return
        self.stop_evt.set()
        try:
            os.close(self.inbound_fd)
        except OSError:
            pass
        try:
            os.close(self.outbound_fd)
        except OSError:
            pass
        try:
            self.link.teardown()
        except Exception:
            pass

    # RNS callbacks (run in RNS's own threads)

    def _on_packet(self, message, packet):
        self.deliver(bytes(message))

    def _on_resource_advertised(self, resource):
        # ACCEPT_APP gate: reject blobs above MAX_LINE_BYTES before a single
        # byte transfers. Strictly better than the current behaviour of
        # receiving then discarding.
        size = resource.get_data_size()
        if size > MAX_LINE_BYTES:
            log(f"{self.label}: rejecting Resource of {size} B (> {MAX_LINE_BYTES})")
            return False
        return True

    def _on_resource_concluded(self, resource):
        # A non-COMPLETE status (timeout, corruption, peer roam mid-transfer)
        # means resource.data is partial or absent. Reading it anyway would
        # hand a truncated blob downstream as if it were a whole AUDIO:/MSG:
        # line, defeating the integrity guarantee Resource exists to provide.
        if resource.status != RNS.Resource.COMPLETE:
            log(f"{self.label}: resource did not complete (status={resource.status})")
            return
        # resource.data is a BytesIO-like handle after conclusion.
        try:
            data = resource.data.read()
        except Exception as e:
            log(f"{self.label}: resource read failed: {e}")
            return
        if not data:
            log(f"{self.label}: resource concluded with 0 bytes (status={resource.status})")
            return
        self.deliver(data)

    def _on_link_closed(self, link):
        log(f"{self.label}: link closed")
        self.stop()


# ---------------------------------------------------------------------------
# Role: listen
# ---------------------------------------------------------------------------

class Listener:
    def __init__(self, args):
        self.args = args
        self.handler_argv = args.handler_argv
        self.identity = load_or_create_identity(args.identity)
        listen = parse_hostport(args.tcp_listen) if args.tcp_listen else None
        self.reticulum = init_reticulum(
            args.config_dir, tcp_listen=listen,
            hubs=parse_hubs(args.hubs), autoconnect=args.autoconnect)
        self.destination = RNS.Destination(
            self.identity, RNS.Destination.IN, RNS.Destination.SINGLE,
            APP_NAME, DEST_ASPECT
        )
        self.destination.set_proof_strategy(RNS.Destination.PROVE_ALL)
        self.destination.set_link_established_callback(self._on_link)
        self._bridges = []
        self._children = []
        log(f"identity {RNS.prettyhexrep(self.identity.hash)}")
        log(f"destination {RNS.prettyhexrep(self.destination.hash)}")
        # Emit destination hash to stdout on a well-known prefix so the shell
        # wrapper can capture it without parsing our log format.
        sys.stdout.write(f"DEST_HASH={self.destination.hash.hex()}\n")
        sys.stdout.flush()
        # And also to a file if the wrapper asks; simpler than parsing stdout.
        if getattr(args, "dest_hash_out", None):
            try:
                os.makedirs(os.path.dirname(args.dest_hash_out) or ".", exist_ok=True)
                with open(args.dest_hash_out, "w") as f:
                    f.write(self.destination.hash.hex() + "\n")
            except OSError as e:
                log(f"failed to write --dest-hash-out {args.dest_hash_out}: {e}")

    def _on_link(self, link):
        log("incoming link")
        # Explicit pipes so LinkBridge owns the fd lifecycle. subprocess.PIPE
        # gives back wrapped file objects whose finalizer closes the fd,
        # racing with LinkBridge.stop().
        stdin_r, stdin_w = os.pipe()
        stdout_r, stdout_w = os.pipe()
        try:
            child = subprocess.Popen(
                self.handler_argv,
                stdin=stdin_r,
                stdout=stdout_w,
                stderr=None,
                close_fds=True,
                bufsize=0,
            )
        except Exception as e:
            log(f"failed to spawn handler {self.handler_argv}: {e}")
            for fd in (stdin_r, stdin_w, stdout_r, stdout_w):
                try:
                    os.close(fd)
                except OSError:
                    pass
            link.teardown()
            return
        # Parent doesn't need the child-side halves.
        os.close(stdin_r)
        os.close(stdout_w)
        self._children.append(child)
        # Nothing else ever calls child.wait()/poll(): without this, every
        # finished handler.sh sits as a zombie in the process table until the
        # whole reflector is restarted. One caller hanging up is normal
        # churn, not an error, so just reap quietly.
        threading.Thread(target=self._reap_child, args=(child,),
                          name=f"reap-{child.pid}", daemon=True).start()
        bridge = LinkBridge(link, inbound_fd=stdin_w, outbound_fd=stdout_r,
                            label=f"link-{child.pid}")
        self._bridges.append(bridge)
        bridge.start()

    def _reap_child(self, child):
        child.wait()
        try:
            self._children.remove(child)
        except ValueError:
            pass

    def run(self):
        # Periodic announces.
        def announce_loop():
            while True:
                try:
                    self.destination.announce()
                except Exception as e:
                    log(f"announce failed: {e}")
                time.sleep(ANNOUNCE_INTERVAL_S)
        t = threading.Thread(target=announce_loop, name="announce", daemon=True)
        t.start()
        # Announce once immediately for discovery.
        try:
            self.destination.announce()
        except Exception as e:
            log(f"initial announce failed: {e}")
        # Block forever.
        signal.pause()


# ---------------------------------------------------------------------------
# Role: connect
# ---------------------------------------------------------------------------

class Connector:
    def __init__(self, args):
        self.args = args
        self.identity = load_or_create_identity(args.identity)
        connect = parse_hostport(args.tcp_connect) if args.tcp_connect else None
        self.reticulum = init_reticulum(
            args.config_dir, tcp_connect=connect,
            hubs=parse_hubs(args.hubs), autoconnect=args.autoconnect)
        self.dest_hash = bytes.fromhex(args.destination)
        self.ready_file = args.ready_file
        self.send_pipe = args.send_pipe
        self.recv_pipe = args.recv_pipe
        self._link = None
        self._bridge = None
        self._link_up = threading.Event()

    def _wait_for_path(self):
        if not RNS.Transport.has_path(self.dest_hash):
            log("requesting path...")
            RNS.Transport.request_path(self.dest_hash)
            if not RNS.Transport.await_path(self.dest_hash,
                                            timeout=self.args.path_timeout):
                raise RuntimeError(
                    f"no path to {self.dest_hash.hex()} after "
                    f"{self.args.path_timeout}s")
        log(f"have path to {self.dest_hash.hex()}")

    def _on_established(self, link):
        log("link established")
        self._link = link
        # Touch the ready-file BEFORE opening the FIFOs so rns-party-line.sh's
        # _dial_remote observes readiness only on real link establishment
        # (PLAN.md 11.3).
        if self.ready_file:
            try:
                open(self.ready_file, "w").close()
            except OSError as e:
                log(f"failed to touch ready-file {self.ready_file}: {e}")
        self._link_up.set()

    def _on_closed(self, link):
        log("link closed")
        if self._bridge:
            self._bridge.stop()
        os._exit(0)

    def run(self):
        self._wait_for_path()
        remote_ident = RNS.Identity.recall(self.dest_hash)
        if remote_ident is None:
            raise RuntimeError(f"recall failed for {self.dest_hash.hex()}")
        remote_dest = RNS.Destination(
            remote_ident, RNS.Destination.OUT, RNS.Destination.SINGLE,
            APP_NAME, DEST_ASPECT
        )
        RNS.Link(remote_dest,
                 established_callback=self._on_established,
                 closed_callback=self._on_closed)
        if not self._link_up.wait(timeout=self.args.link_timeout):
            raise RuntimeError(
                f"link did not establish in {self.args.link_timeout}s")
        # Open the FIFOs. On the send side we read (bytes to push to the
        # link); on the recv side we write (bytes received from the link).
        # The FIFOs must already exist -- rns-party-line.sh creates them.
        outbound_fd = os.open(self.send_pipe, os.O_RDONLY)
        inbound_fd = os.open(self.recv_pipe, os.O_WRONLY)
        self._bridge = LinkBridge(self._link, inbound_fd, outbound_fd,
                                  label="dial")
        self._bridge.start()
        signal.pause()


# ---------------------------------------------------------------------------
# Role: address
# ---------------------------------------------------------------------------

def print_address(args):
    """Publish this node's destination hash without touching the network.

    The hash is a pure function of the identity plus APP_NAME/DEST_ASPECT, so
    it can be derived (and the identity created on first run) before any
    interface comes up. Lets rns-party-line.sh show an address at startup instead
    of only after the first listen/relay.
    """
    identity = load_or_create_identity(args.identity)
    dest_hash = RNS.Destination.hash(identity, APP_NAME, DEST_ASPECT)
    sys.stdout.write(f"DEST_HASH={dest_hash.hex()}\n")
    sys.stdout.flush()
    if getattr(args, "dest_hash_out", None):
        try:
            os.makedirs(os.path.dirname(args.dest_hash_out) or ".", exist_ok=True)
            with open(args.dest_hash_out, "w") as f:
                f.write(dest_hash.hex() + "\n")
        except OSError as e:
            log(f"failed to write --dest-hash-out {args.dest_hash_out}: {e}")
            return 1
    return 0


# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(prog="rns_bridge.py")
    sub = p.add_subparsers(dest="role", required=True)

    common_config = argparse.ArgumentParser(add_help=False)
    common_config.add_argument("--config-dir", required=True,
        help="RNS config dir (should be on tmpfs; see PLAN 20.6)")
    common_config.add_argument("--identity", required=True,
        help="Path to persistent Identity file (in DATA_DIR)")
    common_config.add_argument("--hubs", default="",
        help="Comma-separated host:port list of public Reticulum transport "
             "nodes to dial out to. This is the no-open-ports path: with "
             "hubs set, neither end needs to be inbound-reachable.")
    common_config.add_argument("--autoconnect", type=int, default=0,
        help="Max discovered backbone peers to auto-connect to, on top of "
             "--hubs. 0 disables discovery. Ignored without --hubs.")
    common_config.add_argument("--max-line-bytes", type=int, default=None,
        help="Override the module MAX_LINE_BYTES ceiling (oversize-line drop "
             "and the Resource ACCEPT_APP size gate) with rns-party-line.sh's "
             "configured MAX_LINE_BYTES. Ignored by the address role.")

    lp = sub.add_parser("listen", parents=[common_config],
        help="Reflector role: accept links, fork handler per link")
    lp.add_argument("--tcp-listen", default="0.0.0.0:4242",
        help="ip:port for TCPServerInterface")
    lp.add_argument("--dest-hash-out", default=None,
        help="Write destination hash (hex) to this file once known. "
             "rns-party-line.sh polls this file to replace get_onion.")
    lp.add_argument("handler_argv", nargs=argparse.REMAINDER,
        help="Handler argv, prefixed with --. Example: -- bash handler.sh a b c")

    ap = sub.add_parser("address", parents=[common_config],
        help="Derive and print the destination hash, no network activity")
    ap.add_argument("--dest-hash-out", default=None,
        help="Write destination hash (hex) to this file")

    cp = sub.add_parser("connect", parents=[common_config],
        help="Client role: open a link to a destination and bridge to FIFOs")
    cp.add_argument("--tcp-connect", default=None,
        help="host:port for a direct TCPClientInterface to the reflector. "
             "Optional: omit it to reach the reflector over --hubs instead.")
    cp.add_argument("--destination", required=True,
        help="Destination hash in hex")
    cp.add_argument("--send-pipe", required=True,
        help="FIFO to read outbound bytes from (rns-party-line.sh SEND_PIPE)")
    cp.add_argument("--recv-pipe", required=True,
        help="FIFO to write inbound bytes to (rns-party-line.sh RECV_PIPE)")
    cp.add_argument("--ready-file", default=None,
        help="Touch this file on link_established (PLAN 11.3)")
    cp.add_argument("--path-timeout", type=int, default=30)
    cp.add_argument("--link-timeout", type=int, default=15)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    if getattr(args, "max_line_bytes", None):
        global MAX_LINE_BYTES
        MAX_LINE_BYTES = args.max_line_bytes
    if args.role == "listen":
        # Strip the leading "--" argparse leaves in REMAINDER.
        if args.handler_argv and args.handler_argv[0] == "--":
            args.handler_argv = args.handler_argv[1:]
        if not args.handler_argv:
            print("listen: handler argv required (after --)", file=sys.stderr)
            return 2
        Listener(args).run()
    elif args.role == "address":
        return print_address(args)
    elif args.role == "connect":
        if not args.tcp_connect and not args.hubs:
            print("connect: need --hubs or --tcp-connect; no way to reach "
                  "the network otherwise", file=sys.stderr)
            return 2
        Connector(args).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
RNS_BRIDGE_PY_EOF
}

# ─── Full-duplex engine deployment (same pattern as rns_bridge above) ────────
write_fullduplex_engine() {
    mkdir -p "$(dirname "$FD_ENGINE_PY")"
    local staged="${FD_ENGINE_PY}.$$"
    _emit_fullduplex_engine "$staged" || { rm -f "$staged"; return 1; }
    if ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' \
            "$staged" 2>/dev/null; then
        log_err "Full-duplex engine is not valid Python (embedded heredoc corrupt)"
        rm -f "$staged"
        return 1
    fi
    mv -f "$staged" "$FD_ENGINE_PY" || { rm -f "$staged"; return 1; }
    return 0
}

_emit_fullduplex_engine() {
    cat > "$1" << 'FULLDUPLEX_ENGINE_PY_EOF'
#!/usr/bin/env python3
"""
Partyline full-duplex audio engine.
Pipe-based bidirectional voice streaming with per-frame encryption.

Launched by in_call_session when FULL_DUPLEX=1. Reads/writes the
existing FIFO pipe pair. Non-audio protocol lines are forwarded to
stdout so the calling shell can handle them.

Dependencies: Python 3, libopus (system package).
No pip packages. All bindings via ctypes.
"""

import sys
import os
import time
import struct
import hashlib
import hmac as hmac_mod
import ctypes
import ctypes.util
import subprocess
import threading
import signal
import base64


# ─── Opus codec via ctypes ───────────────────────────────────────

class OpusCodec:
    APP_VOIP = 2048
    SET_BITRATE = 4002
    SET_VBR = 4006
    SET_FEC = 4012
    SET_DTX = 4016
    SET_SIGNAL = 4024
    SIGNAL_VOICE = 3001

    def __init__(self, sample_rate=8000, channels=1, bitrate=16000):
        self.sample_rate = sample_rate
        self.channels = channels
        self.bitrate = bitrate
        self.lib = None
        self.encoder = None
        self.decoder = None
        self.available = False
        self._load()

    def _load(self):
        paths = [ctypes.util.find_library("opus")]
        if "PREFIX" in os.environ:
            paths.insert(0, os.path.join(
                os.environ["PREFIX"], "lib", "libopus.so"))
        paths += [
            "/usr/lib/libopus.so.0",
            "/usr/lib/x86_64-linux-gnu/libopus.so.0",
            "/usr/lib/aarch64-linux-gnu/libopus.so.0",
            "/usr/lib/arm-linux-gnueabihf/libopus.so.0",
            "/data/data/com.termux/files/usr/lib/libopus.so",
            "/data/data/com.termux/files/usr/lib/libopus.so.0",
            "/opt/homebrew/lib/libopus.dylib",
            "/opt/homebrew/lib/libopus.0.dylib",
            "/usr/local/lib/libopus.dylib",
        ]
        for p in paths:
            if p and os.path.exists(p):
                try:
                    self.lib = ctypes.CDLL(p)
                    break
                except Exception:
                    pass
        if not self.lib:
            for name in ["opus", "libopus.so.0", "libopus.dylib"]:
                try:
                    self.lib = ctypes.CDLL(name)
                    break
                except Exception:
                    pass
        if not self.lib:
            return

        try:
            L = self.lib
            L.opus_encoder_create.restype = ctypes.c_void_p
            L.opus_encoder_create.argtypes = [
                ctypes.c_int, ctypes.c_int, ctypes.c_int,
                ctypes.POINTER(ctypes.c_int)]
            L.opus_encoder_ctl.restype = ctypes.c_int
            L.opus_encoder_ctl.argtypes = [
                ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
            L.opus_encode.restype = ctypes.c_int
            L.opus_encode.argtypes = [
                ctypes.c_void_p, ctypes.POINTER(ctypes.c_int16),
                ctypes.c_int, ctypes.c_char_p, ctypes.c_int32]
            L.opus_encoder_destroy.argtypes = [ctypes.c_void_p]
            L.opus_decoder_create.restype = ctypes.c_void_p
            L.opus_decoder_create.argtypes = [
                ctypes.c_int, ctypes.c_int,
                ctypes.POINTER(ctypes.c_int)]
            L.opus_decode.restype = ctypes.c_int
            L.opus_decode.argtypes = [
                ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int32,
                ctypes.POINTER(ctypes.c_int16), ctypes.c_int,
                ctypes.c_int]
            L.opus_decoder_destroy.argtypes = [ctypes.c_void_p]

            err = ctypes.c_int()
            self.encoder = L.opus_encoder_create(
                self.sample_rate, self.channels,
                self.APP_VOIP, ctypes.byref(err))
            if err.value != 0 or not self.encoder:
                return
            for req, val in [
                (self.SET_BITRATE, self.bitrate),
                (self.SET_VBR, 1),
                (self.SET_FEC, 1),
                (self.SET_DTX, 1),
                (self.SET_SIGNAL, self.SIGNAL_VOICE),
            ]:
                L.opus_encoder_ctl(
                    self.encoder, req, ctypes.c_int(val))
            self.decoder = L.opus_decoder_create(
                self.sample_rate, self.channels, ctypes.byref(err))
            if self.encoder and self.decoder:
                self.available = True
        except Exception:
            self.available = False

    def encode(self, pcm_bytes, frame_size):
        if not self.available:
            return pcm_bytes
        pcm = (ctypes.c_int16 * frame_size).from_buffer_copy(pcm_bytes)
        out = ctypes.create_string_buffer(1275)
        n = self.lib.opus_encode(
            self.encoder, pcm, frame_size, out, 1275)
        return out.raw[:n] if n > 0 else b""

    def decode(self, opus_bytes, frame_size):
        if not self.available:
            return opus_bytes
        out = (ctypes.c_int16 * frame_size)()
        n = self.lib.opus_decode(
            self.decoder, opus_bytes, len(opus_bytes),
            out, frame_size, 0)
        if n > 0:
            return bytes(out)[:n * 2]
        return b"\x00" * (frame_size * 2)

    def close(self):
        if not self.lib:
            return
        if self.encoder:
            try:
                self.lib.opus_encoder_destroy(self.encoder)
            except Exception:
                pass
            self.encoder = None
        if self.decoder:
            try:
                self.lib.opus_decoder_destroy(self.decoder)
            except Exception:
                pass
            self.decoder = None


# ─── Per-frame crypto ────────────────────────────────────────────

class CryptoEngine:
    """SHA-256-CTR + HMAC-SHA256 with monotonic replay protection.

    Wire format per frame:
      [8-byte seq] [ciphertext] [16-byte HMAC tag]
    Total overhead: 24 bytes.
    """

    def __init__(self, shared_secret):
        raw = shared_secret.encode("utf-8")
        salt = b"partyline-fullduplex-v1"
        derived = hashlib.pbkdf2_hmac(
            "sha256", raw, salt, 20000, dklen=64)
        self.enc_key = derived[:32]
        self.hmac_key = derived[32:]
        self.tx_seq = 0
        self.rx_seq_max = -1

    def _keystream(self, key, nonce, length):
        ks = bytearray()
        ctr = 0
        while len(ks) < length:
            ks.extend(hashlib.sha256(
                key + nonce + struct.pack(">Q", ctr)
            ).digest())
            ctr += 1
        return bytes(ks[:length])

    def encrypt(self, plaintext):
        self.tx_seq += 1
        seq = struct.pack(">Q", self.tx_seq)
        ks = self._keystream(self.enc_key, seq, len(plaintext))
        ct = bytes(a ^ b for a, b in zip(plaintext, ks))
        tag = hmac_mod.new(
            self.hmac_key, seq + ct, hashlib.sha256
        ).digest()[:16]
        return seq + ct + tag

    def decrypt(self, packet):
        if len(packet) < 24:
            return None
        seq_bytes = packet[:8]
        tag = packet[-16:]
        ct = packet[8:-16]
        expected = hmac_mod.new(
            self.hmac_key, seq_bytes + ct, hashlib.sha256
        ).digest()[:16]
        if not hmac_mod.compare_digest(tag, expected):
            return None
        seq_val = struct.unpack(">Q", seq_bytes)[0]
        if seq_val <= self.rx_seq_max:
            return None
        self.rx_seq_max = seq_val
        ks = self._keystream(self.enc_key, seq_bytes, len(ct))
        return bytes(a ^ b for a, b in zip(ct, ks))


# ─── Platform audio helpers ──────────────────────────────────────

def _has_bin(name):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        fp = os.path.join(d, name)
        if os.path.isfile(fp) and os.access(fp, os.X_OK):
            return True
    return False


IS_TERMUX = os.path.isdir("/data/data/com.termux")
IS_MACOS = sys.platform == "darwin"


def spawn_recorder(sample_rate):
    alsa_dev = os.environ.get("ALSA_DEVICE", "")
    pulse_src = os.environ.get("PULSE_SOURCE", "")
    cmd = None

    if IS_MACOS:
        cmd = ["rec", "-q", "-t", "raw", "-r", str(sample_rate),
               "-e", "signed", "-b", "16", "-c", "1", "-"]
    elif IS_TERMUX:
        for tool in ("pacat", "parec"):
            if _has_bin(tool):
                cmd = [tool]
                if tool == "pacat":
                    cmd.append("-r")
                cmd += ["--format=s16le", "--channels=1",
                        "--rate=%d" % sample_rate,
                        "--latency-msec=40"]
                break
    else:
        if not alsa_dev and _has_bin("parecord"):
            cmd = ["parecord", "--latency-msec=50",
                   "--rate=%d" % sample_rate,
                   "--channels=1", "--format=s16le", "--raw"]
            if pulse_src:
                cmd += ["-d", pulse_src]
        else:
            cmd = ["arecord"]
            if alsa_dev:
                cmd += ["-D", alsa_dev]
            cmd += ["-f", "S16_LE", "-r", str(sample_rate),
                    "-c", "1", "-t", "raw", "-q", "-"]
    if not cmd:
        return None
    try:
        return subprocess.Popen(
            cmd, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0)
    except Exception:
        return None


def spawn_player(sample_rate):
    alsa_play = os.environ.get("ALSA_PLAY_DEVICE", "")
    pulse_sink = os.environ.get("PULSE_SINK", "")
    cmd = None

    if IS_MACOS or IS_TERMUX:
        if _has_bin("play"):
            cmd = ["play", "-q", "-t", "raw", "-r",
                   str(sample_rate), "-e", "signed",
                   "-b", "16", "-c", "1", "-"]
        elif _has_bin("pacat"):
            cmd = ["pacat", "-p", "--format=s16le",
                   "--channels=1",
                   "--rate=%d" % sample_rate,
                   "--latency-msec=50"]
    else:
        if not alsa_play and _has_bin("pacat"):
            cmd = ["pacat", "-p", "--format=s16le",
                   "--channels=1",
                   "--rate=%d" % sample_rate,
                   "--latency-msec=50"]
            if pulse_sink:
                cmd += ["-d", pulse_sink]
        else:
            cmd = ["aplay"]
            if alsa_play:
                cmd += ["-D", alsa_play]
            cmd += ["-f", "S16_LE", "-r", str(sample_rate),
                    "-c", "1", "-t", "raw", "-q", "-"]
    if not cmd:
        return None
    try:
        return subprocess.Popen(
            cmd, stdin=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0)
    except Exception:
        return None


# ─── Engine ──────────────────────────────────────────────────────

class FullDuplexEngine:
    def __init__(self, recv_pipe, send_pipe, secret,
                 sample_rate=8000, bitrate=16000, start_muted=False):
        self.recv_pipe = recv_pipe
        self.send_pipe = send_pipe
        self.sample_rate = sample_rate
        self.frame_ms = 60
        self.frame_size = int(sample_rate * self.frame_ms / 1000)
        self.pcm_bytes = self.frame_size * 2

        self.codec = OpusCodec(sample_rate, 1, bitrate)
        self.crypto = CryptoEngine(secret)

        self.running = False
        self.muted = start_muted

        self.jitter = []
        self.jitter_lock = threading.Lock()
        self.jitter_max = 5

        self.rec_proc = None
        self.play_proc = None
        self.send_fd = None
        self.recv_file = None

    def run(self):
        if not self.codec.available:
            sys.stderr.write(
                "fd_engine: libopus not found; "
                "full-duplex unavailable\n")
            return 1

        self.running = True

        self.send_fd = os.open(self.send_pipe, os.O_WRONLY)
        self.recv_file = open(
            os.open(self.recv_pipe, os.O_RDONLY), "r",
            encoding="utf-8", errors="replace")

        self.rec_proc = spawn_recorder(self.sample_rate)
        self.play_proc = spawn_player(self.sample_rate)

        threads = [
            threading.Thread(
                target=self._capture_loop, daemon=True,
                name="fd-capture"),
            threading.Thread(
                target=self._receive_loop, daemon=True,
                name="fd-receive"),
            threading.Thread(
                target=self._playback_loop, daemon=True,
                name="fd-playback"),
        ]
        for t in threads:
            t.start()

        try:
            while self.running:
                time.sleep(0.1)
        except (KeyboardInterrupt, SystemExit):
            pass

        self.running = False
        self._cleanup()
        return 0

    # ── capture thread ──

    def _capture_loop(self):
        silence = b"\x00" * self.pcm_bytes
        while self.running:
            pcm = self._read_mic()
            if not pcm:
                continue
            if self.muted:
                pcm = silence

            opus = self.codec.encode(pcm, self.frame_size)
            if not opus:
                continue

            encrypted = self.crypto.encrypt(opus)
            b64 = base64.b64encode(encrypted).decode("ascii")
            line = ("FDAUDIO:" + b64 + "\n").encode("utf-8")

            try:
                os.write(self.send_fd, line)
            except (OSError, BrokenPipeError):
                self.running = False
                break

    def _read_mic(self):
        if not self.rec_proc or not self.rec_proc.stdout:
            time.sleep(self.frame_ms / 1000.0)
            return b"\x00" * self.pcm_bytes

        data = bytearray()
        remain = self.pcm_bytes
        while remain > 0 and self.running:
            try:
                chunk = self.rec_proc.stdout.read(remain)
                if not chunk:
                    break
                data.extend(chunk)
                remain -= len(chunk)
            except Exception:
                break

        if len(data) < self.pcm_bytes:
            data.extend(b"\x00" * (self.pcm_bytes - len(data)))
        return bytes(data)

    # ── receive thread ──

    def _receive_loop(self):
        while self.running:
            try:
                line = self.recv_file.readline()
            except Exception:
                break
            if not line:
                self.running = False
                break

            line = line.rstrip("\n\r")
            if not line:
                continue

            if line.startswith("FDAUDIO:"):
                b64 = line[8:]
                try:
                    encrypted = base64.b64decode(b64)
                except Exception:
                    continue
                opus = self.crypto.decrypt(encrypted)
                if opus is None:
                    continue
                pcm = self.codec.decode(opus, self.frame_size)
                if pcm:
                    with self.jitter_lock:
                        if len(self.jitter) >= self.jitter_max:
                            self.jitter.pop(0)
                        self.jitter.append(pcm)
            else:
                try:
                    sys.stdout.write(line + "\n")
                    sys.stdout.flush()
                except Exception:
                    pass

    # ── playback thread ──

    def _playback_loop(self):
        frame_sec = self.frame_ms / 1000.0
        prefill = 3
        filled = False

        while self.running:
            if not filled:
                with self.jitter_lock:
                    if len(self.jitter) >= prefill:
                        filled = True
                if not filled:
                    time.sleep(frame_sec * 0.25)
                    continue

            pcm = None
            with self.jitter_lock:
                if self.jitter:
                    pcm = self.jitter.pop(0)
                elif filled:
                    filled = False

            if pcm and self.play_proc and self.play_proc.stdin:
                try:
                    self.play_proc.stdin.write(pcm)
                    self.play_proc.stdin.flush()
                except Exception:
                    pass
            else:
                time.sleep(frame_sec * 0.5)

    # ── teardown ──

    def _cleanup(self):
        for proc in (self.rec_proc, self.play_proc):
            if proc:
                try:
                    proc.terminate()
                    proc.wait(timeout=1)
                except Exception:
                    try:
                        proc.kill()
                    except Exception:
                        pass
        if self.send_fd is not None:
            try:
                os.close(self.send_fd)
            except Exception:
                pass
        if self.recv_file:
            try:
                self.recv_file.close()
            except Exception:
                pass
        self.codec.close()


def main():
    if len(sys.argv) < 3:
        sys.stderr.write(
            "Usage: FD_SECRET=... fd_engine RECV_PIPE SEND_PIPE"
            " [SAMPLE_RATE] [BITRATE_BPS] [START_MUTED]\n")
        return 1

    recv_pipe = sys.argv[1]
    send_pipe = sys.argv[2]
    secret = os.environ.get("FD_SECRET", "")
    if not secret:
        sys.stderr.write("fd_engine: FD_SECRET not set\n")
        return 1
    sample_rate = int(sys.argv[3]) if len(sys.argv) > 3 else 8000
    bitrate = int(sys.argv[4]) if len(sys.argv) > 4 else 16000
    start_muted = len(sys.argv) > 5 and sys.argv[5] == "1"

    engine = FullDuplexEngine(
        recv_pipe, send_pipe, secret,
        sample_rate, bitrate, start_muted=start_muted)

    def on_stop(signum, frame):
        engine.running = False

    def on_mute(signum, frame):
        engine.muted = not engine.muted
        state = "muted" if engine.muted else "live"
        sys.stderr.write("fd_engine: mic %s\n" % state)

    signal.signal(signal.SIGTERM, on_stop)
    signal.signal(signal.SIGINT, on_stop)
    signal.signal(signal.SIGUSR1, on_mute)

    return engine.run()


if __name__ == "__main__":
    sys.exit(main())
FULLDUPLEX_ENGINE_PY_EOF
}

# Poll for the destination hash file the bridge writes on startup. Returns
# 0 on success (hash printed to stdout), 1 on timeout.
wait_dest_hash() {
    local path="$1" timeout="${2:-30}" i=0
    while [ "$i" -lt $((timeout * 10)) ]; do
        if [ -s "$path" ]; then
            local h
            h=$(head -1 "$path" | tr -d '[:space:]')
            if [ -n "$h" ]; then
                printf '%s' "$h"
                return 0
            fi
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}


uid() {
    # 6 random bytes as 12 hex chars. od reads the bytes directly (-N6), so this
    # is one subprocess instead of head|od|tr.
    local h; h=$(od -An -N6 -tx1 /dev/urandom)
    printf '%s' "${h//[[:space:]]/}"
}

load_config() {
    # Parse config as explicit key=value pairs — never source it. The config file
    # lives at a user-writable path (and is a bind mount in Docker); sourcing it
    # would execute arbitrary code with the current user's privileges.
    if [ -f "$CONFIG_FILE" ]; then
        local _lc_line _lc_key _lc_raw _lc_val
        while IFS= read -r _lc_line || [ -n "$_lc_line" ]; do
            case "$_lc_line" in ''|'#'*) continue ;; esac
            _lc_key="${_lc_line%%=*}"
            _lc_raw="${_lc_line#*=}"
            # Strip one layer of surrounding double or single quotes, then unescape \" → "
            if [[ "$_lc_raw" == \"*\" ]]; then
                _lc_val="${_lc_raw:1:${#_lc_raw}-2}"
                _lc_val="${_lc_val//\\\"/\"}"
            elif [[ "$_lc_raw" == \'*\' ]]; then
                _lc_val="${_lc_raw:1:${#_lc_raw}-2}"
            else
                _lc_val="$_lc_raw"
            fi
            case "$_lc_key" in
                RELAY_IDLE_TIMEOUT) RELAY_IDLE_TIMEOUT="$_lc_val" ;;
                HEARTBEAT_INTERVAL) HEARTBEAT_INTERVAL="$_lc_val" ;;
                CLIENT_TIMEOUT)     CLIENT_TIMEOUT="$_lc_val" ;;
                RECONNECT_ATTEMPTS) RECONNECT_ATTEMPTS="$_lc_val" ;;
                DIAL_ATTEMPTS)      DIAL_ATTEMPTS="$_lc_val" ;;
                DIAL_TIMEOUT)       DIAL_TIMEOUT="$_lc_val" ;;
                OPUS_BITRATE)       OPUS_BITRATE="$_lc_val" ;;
                OPUS_FRAMESIZE)     OPUS_FRAMESIZE="$_lc_val" ;;
                PTT_KEY)            PTT_KEY="$_lc_val" ;;
                CIPHER)             CIPHER="$_lc_val" ;;
                AUTO_LISTEN)        AUTO_LISTEN="$_lc_val" ;;
                VOL_PTT)            VOL_PTT="$_lc_val" ;;
                PTT_TOGGLE_MODE)    PTT_TOGGLE_MODE="$_lc_val" ;;
                HMAC_AUTH)          HMAC_AUTH="$_lc_val" ;;
                PTT_CHIME)          ;; # removed, kept for config-file compat
                NORMALIZE_PLAYBACK) NORMALIZE_PLAYBACK="$_lc_val" ;;
                FULL_DUPLEX)        FULL_DUPLEX="$_lc_val" ;;
                START_MUTED)        START_MUTED="$_lc_val" ;;
                OVERWRITE_DELETE)   OVERWRITE_DELETE="$_lc_val" ;;
                ALSA_DEVICE)        ALSA_DEVICE="$_lc_val" ;;
                ALSA_PLAY_DEVICE)   ALSA_PLAY_DEVICE="$_lc_val" ;;
                PULSE_SOURCE)       PULSE_SOURCE="$_lc_val" ;;
                PULSE_SINK)         PULSE_SINK="$_lc_val" ;;
                MAX_LINE_BYTES)     MAX_LINE_BYTES="$_lc_val" ;;
                MAX_MSG_B64)        MAX_MSG_B64="$_lc_val" ;;
                DECRYPT_TIMEOUT)    DECRYPT_TIMEOUT="$_lc_val" ;;
                RELAY_WRITE_TIMEOUT) RELAY_WRITE_TIMEOUT="$_lc_val" ;;
                MAX_PTT_SECONDS)    MAX_PTT_SECONDS="$_lc_val" ;;
                PTT_CHUNK_SECONDS)  PTT_CHUNK_SECONDS="$_lc_val" ;;
                MACOS_AUDIO_INDEX)  MACOS_AUDIO_INDEX="$_lc_val" ;;
                MAX_AUDIO_B64)      MAX_AUDIO_B64="$_lc_val" ;;
                RELAY_MAX_MSG_PER_SEC) RELAY_MAX_MSG_PER_SEC="$_lc_val" ;;
                RELAY_MAX_INFLIGHT) RELAY_MAX_INFLIGHT="$_lc_val" ;;
            esac
        done < "$CONFIG_FILE"
    fi
    # Docker secret path: the secret is mounted as a file (e.g.
    # /run/secrets/shared_secret.txt) and pointed to by SHARED_SECRET_FILE. This
    # keeps the secret out of `.env`/the environment (where `docker inspect` or
    # /proc could leak it). We read and trim it first and only use it when
    # non-empty, so a present-but-blank secret file (the shipped default, which
    # lets `docker compose` start without a manual setup step) falls through to
    # the on-disk secret or prompt instead of clobbering them. `--secret` still
    # overrides this later via apply_cli_overrides.
    local _docker_secret=""
    if [ -n "${SHARED_SECRET_FILE:-}" ] && [ -r "$SHARED_SECRET_FILE" ]; then
        _docker_secret="$(tr -d '\r\n' < "$SHARED_SECRET_FILE" 2>/dev/null)" || true
    fi
    if [ -n "$_docker_secret" ]; then
        SHARED_SECRET="$_docker_secret"
    elif [ -f "$SECRET_FILE" ] && [ "${SKIP_SECRET_PROMPT:-0}" != "1" ]; then
        # OpenSSL enc writes a "Salted__" magic header followed by an 8-byte random salt
        # when -pbkdf2 is used. Its presence tells us this file was encrypted by us;
        # absence means it was written in plaintext (older versions, or no passphrase chosen).
        local magic
        magic=$(head -c 8 "$SECRET_FILE" 2>/dev/null | cat -v)
        if [[ "$magic" == "Salted__"* ]] && [ ! -t 0 ]; then
            # Encrypted secret but no interactive terminal to ask for the
            # passphrase. Leave the secret unset — a scripted run should pass
            # --secret instead of being blocked on a prompt it cannot answer.
            log_warn "Encrypted secret on disk but no terminal to unlock it — pass --secret to set one."
            SHARED_SECRET=""
        elif [[ "$magic" == "Salted__"* ]]; then
            # Encrypted secret — prompt for passphrase
            echo -ne "  ${BOLD}Enter passphrase to unlock shared secret: ${NC}"
            read -rs _unlock_pass
            echo ""
            if [ -n "$_unlock_pass" ]; then
                SHARED_SECRET=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
                    -pass "fd:3" -in "$SECRET_FILE" 3<<< "${_unlock_pass}" 2>/dev/null) || true
                if [ -z "$SHARED_SECRET" ]; then
                    log_warn "Failed to unlock secret (wrong passphrase?)"
                    log_info "You can re-enter the secret with option 1"
                else
                    log_ok "Shared secret unlocked"
                fi
            else
                log_warn "No passphrase entered — secret not loaded"
                SHARED_SECRET=""
            fi
        else
            # Plaintext secret — load directly
            SHARED_SECRET=$(cat "$SECRET_FILE")
        fi
    else
        SHARED_SECRET=""
    fi
}

# Config is intentionally plaintext — it contains ports and preferences, not secrets.
# The shared secret lives separately in $SECRET_FILE, optionally encrypted with a passphrase.
save_config() {
    mkdir -p "$DATA_DIR"
    # Shadow the string-typed keys with locally-escaped copies so the heredoc
    # below is unchanged but any " in a value is stored as \"
    local PTT_KEY="${PTT_KEY//\"/\\\"}"; local CIPHER="${CIPHER//\"/\\\"}"
    local ALSA_DEVICE="${ALSA_DEVICE:-}";         ALSA_DEVICE="${ALSA_DEVICE//\"/\\\"}"
    local ALSA_PLAY_DEVICE="${ALSA_PLAY_DEVICE:-}"; ALSA_PLAY_DEVICE="${ALSA_PLAY_DEVICE//\"/\\\"}"
    local PULSE_SOURCE="${PULSE_SOURCE:-}";        PULSE_SOURCE="${PULSE_SOURCE//\"/\\\"}"
    local PULSE_SINK="${PULSE_SINK:-}";            PULSE_SINK="${PULSE_SINK//\"/\\\"}"
    cat > "$CONFIG_FILE" << EOF
RELAY_IDLE_TIMEOUT=$RELAY_IDLE_TIMEOUT
HEARTBEAT_INTERVAL=$HEARTBEAT_INTERVAL
CLIENT_TIMEOUT=$CLIENT_TIMEOUT
RECONNECT_ATTEMPTS=$RECONNECT_ATTEMPTS
DIAL_ATTEMPTS=$DIAL_ATTEMPTS
DIAL_TIMEOUT=$DIAL_TIMEOUT
OPUS_BITRATE=$OPUS_BITRATE
OPUS_FRAMESIZE=$OPUS_FRAMESIZE
PTT_KEY="$PTT_KEY"
CIPHER="$CIPHER"
AUTO_LISTEN=$AUTO_LISTEN
VOL_PTT=$VOL_PTT
PTT_TOGGLE_MODE=$PTT_TOGGLE_MODE
HMAC_AUTH=$HMAC_AUTH

NORMALIZE_PLAYBACK=$NORMALIZE_PLAYBACK
FULL_DUPLEX=$FULL_DUPLEX
START_MUTED=$START_MUTED
OVERWRITE_DELETE=$OVERWRITE_DELETE
ALSA_DEVICE="${ALSA_DEVICE:-}"
ALSA_PLAY_DEVICE="${ALSA_PLAY_DEVICE:-}"
PULSE_SOURCE="${PULSE_SOURCE:-}"
PULSE_SINK="${PULSE_SINK:-}"
PTT_CHUNK_SECONDS=$PTT_CHUNK_SECONDS
MACOS_AUDIO_INDEX=$MACOS_AUDIO_INDEX
EOF
}

#=============================================================================
# DEPENDENCY INSTALLER
#=============================================================================

check_dep() {
    command -v "$1" &>/dev/null
}

# ─── Package-manager abstraction ──────────────────────────────────────────────
# One place that knows how to query/install/remove packages and whether to use
# sudo, instead of the same apt/dnf/pacman/brew/pkg ladder copied at every call
# site. PM holds the active manager; PM_SUDO the sudo prefix (empty for termux,
# root, or when sudo is absent). _pm_init re-resolves while PM is empty so a
# brew bootstrapped mid-install on macOS is picked up on the next call.
PM=""
PM_SUDO=""
_pm_init() {
    [ -n "$PM" ] && return 0
    if   [ $IS_TERMUX -eq 1 ];                    then PM="termux"
    elif [ $IS_MACOS  -eq 1 ] && check_dep brew;  then PM="brew"
    elif check_dep apt-get;                       then PM="apt"
    elif check_dep dnf;                           then PM="dnf"
    elif check_dep pacman;                        then PM="pacman"
    else PM=""; fi
    if [ $IS_TERMUX -eq 1 ] || [ "${EUID:-$(id -u)}" -eq 0 ]; then PM_SUDO=""
    elif check_dep sudo;                                       then PM_SUDO="sudo"
    else PM_SUDO=""; fi
}

# Echo the package-name list for the active manager (names differ per distro).
pm_pkglist() {
    _pm_init
    case "$PM" in
        termux) echo "opus-tools socat openssl-tool ffmpeg termux-api python python-pip python-cryptography" ;;
        brew)   echo "opus-tools socat openssl ffmpeg" ;;
        apt|dnf) echo "opus-tools socat openssl alsa-utils pulseaudio-utils" ;;
        pacman) echo "opus-tools socat openssl alsa-utils libpulse" ;;
    esac
}

# Is a package installed?  Returns 0 if yes.
pm_query() {
    _pm_init
    case "$PM" in
        termux|apt) dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -q "^installed$" ;;
        dnf)        rpm -q "$1" &>/dev/null ;;
        pacman)     pacman -Q "$1" &>/dev/null ;;
        brew)       brew list --formula "$1" &>/dev/null ;;
        *)          return 1 ;;
    esac
}

pm_install() {
    _pm_init
    case "$PM" in
        termux) pkg install -y "$@" ;;
        brew)   brew_run install "$@" ;;
        apt)    $PM_SUDO apt-get install -y "$@" ;;
        dnf)    $PM_SUDO dnf install -y "$@" ;;
        pacman) $PM_SUDO pacman -S --noconfirm "$@" ;;
        *)      return 1 ;;
    esac
}

pm_remove() {
    _pm_init
    case "$PM" in
        termux) pkg remove -y "$@" ;;
        brew)   brew uninstall "$@" 2>/dev/null || true ;;
        apt)    $PM_SUDO apt-get remove -y "$@" 2>/dev/null || true ;;
        dnf)    $PM_SUDO dnf remove -y "$@" 2>/dev/null || true ;;
        pacman) $PM_SUDO pacman -R --noconfirm "$@" 2>/dev/null || true ;;
        *)      return 1 ;;
    esac
}

# Detect and cache the audio backend once per session.
# Priority (Linux script mode): PulseAudio/PipeWire (parecord/paplay) → ALSA direct → none
#
# Why prefer the sound server?
# On a multi-card desktop, ALSA direct cannot tell which card holds the real
# microphone: opening any plughw capture device succeeds even with no mic
# attached, so an auto-scan just picks the lowest-numbered card — usually the
# wrong one. The sound server already knows the user's selected default
# input/output and routes correctly regardless of card count. This is the
# standard terminal-audio path and the right default for script mode.
#
# Why parecord/paplay (PulseAudio tools) rather than pw-record/pw-play?
# They speak to both PulseAudio and PipeWire (every PipeWire desktop ships the
# pipewire-pulse compat layer), and — unlike pw-record — parecord flushes its
# file output frequently with --latency-msec, so a kill at end-of-talk keeps
# the audio. pw-record buffers and loses everything on signal.
#
# Why keep ALSA direct as a fallback?
# It covers bare-ALSA / old distros (Kali, Knoppix) and headless/Docker boxes
# with no sound server running. IMPORTANT: a *running* server owns the audio
# hardware, so direct `aplay -D plughw:X,Y` to the active sink fails with EBUSY
# even though `arecord` on an idle mic input still works — that is exactly the
# "recording OK, playback FAILED" symptom. So when a server is reachable we use
# it for both directions and never fall to ALSA-direct.
#
# Override policy: an ALSA device provided via the ENVIRONMENT (script mode:
# `ALSA_DEVICE=… ./rns-party-line.sh`, or Docker/.env) is a deliberate hard override
# and forces the ALSA backend. A device that only comes from the saved config is
# a soft preference — the sound server wins when it's actually delivering audio,
# so a stale saved value never strands a desktop on ALSA.
#
# Sets globals: AUDIO_BACKEND, and (ALSA backend only) ALSA_DEVICE/ALSA_PLAY_DEVICE
detect_audio_backend() {
    [ -n "$AUDIO_BACKEND" ] && return 0

    if [ $IS_TERMUX -eq 1 ]; then AUDIO_BACKEND="termux"; return 0; fi
    if [ $IS_MACOS -eq 1 ];  then AUDIO_BACKEND="ffmpeg"; return 0; fi

    # ── Hard override: ALSA device from the environment forces ALSA direct ──
    if [ -n "${ALSA_DEVICE_ENV:-}" ] || [ -n "${ALSA_PLAY_DEVICE_ENV:-}" ]; then
        ALSA_DEVICE="${ALSA_DEVICE_ENV:-$ALSA_DEVICE}"
        ALSA_PLAY_DEVICE="${ALSA_PLAY_DEVICE_ENV:-$ALSA_PLAY_DEVICE}"
        _detect_alsa_backend && return 0
    fi

    # ── Prefer the system sound server (honors the user's default devices) ──
    # Gate on reachability, not a capture probe: a reachable server owns the
    # hardware, so it is the only thing that can play back. A saved-config
    # ALSA_DEVICE does NOT short-circuit this — the server wins.
    if _server_available; then
        AUDIO_BACKEND="pulse"
        return 0
    fi

    # ── Fallback: ALSA direct (bare-ALSA, old distros, headless, Docker) ────
    _detect_alsa_backend && return 0

    AUDIO_BACKEND="none"
    log_warn "No working audio backend found (no PulseAudio/PipeWire, no ALSA capture device)."
    log_warn "Install pulseaudio-utils (and alsa-utils), or set ALSA_DEVICE=plughw:X,Y in .env."
    return 1
}

# Internal: return 0 if a PulseAudio/PipeWire server is present AND reachable.
# Requires the client tools (parecord/paplay) and a live server (pactl info, or
# a server socket as a fallback when pactl is absent). A reachable server owns
# the audio devices, so this is the decisive signal to route through it rather
# than ALSA direct (which would hit EBUSY on the active sink).
_server_available() {
    check_dep parecord || return 1
    check_dep paplay   || return 1
    if check_dep pactl && timeout 2 pactl info >/dev/null 2>&1; then
        return 0
    fi
    local _uid _rt; _uid=$(id -u 2>/dev/null); _rt="${XDG_RUNTIME_DIR:-/run/user/${_uid}}"
    [ -S "${_rt}/pulse/native" ] || [ -S "${_rt}/pipewire-0" ]
}

# Internal: ALSA-direct backend detection (validate override, else auto-scan
# hardware capture devices). Sets AUDIO_BACKEND=alsa on success. Returns 1 if
# no usable ALSA capture device is found.
_detect_alsa_backend() {
    if ! check_dep arecord || ! check_dep aplay; then
        return 1
    fi

    # ── Clear saved playback device if it is currently held by another process ──
    # Uses /proc/asound/ — no ALSA calls, no side-effects on ALSA IPC state.
    if [ -n "${ALSA_PLAY_DEVICE:-}" ] && _alsa_play_device_busy "$ALSA_PLAY_DEVICE"; then
        ALSA_PLAY_DEVICE=""
    fi

    # ── Try user-specified capture device first (retry transient EBUSY) ─────
    if [ -n "${ALSA_DEVICE:-}" ]; then
        if _alsa_device_works "$ALSA_DEVICE" 2; then
            AUDIO_BACKEND="alsa"
            [ -z "${ALSA_PLAY_DEVICE:-}" ] && ALSA_PLAY_DEVICE="$(_alsa_play_for_cap "$ALSA_DEVICE")"
            _alsa_play_fallback_to_pulse
            return 0
        fi
        ALSA_DEVICE=""
    fi

    # ── Auto-scan all ALSA capture devices ────────────────────────────────
    local card dev try_dev
    while IFS= read -r line; do
        [[ "$line" =~ ^card[[:space:]]([0-9]+)[^,]*,[[:space:]]device[[:space:]]([0-9]+) ]] || continue
        card="${BASH_REMATCH[1]}"; dev="${BASH_REMATCH[2]}"
        # Skip HDMI/DisplayPort — not real microphone inputs
        [[ "$(_lc "$line")" =~ hdmi|displayport ]] && continue
        try_dev="plughw:${card},${dev}"
        if _alsa_device_works "$try_dev"; then
            ALSA_DEVICE="$try_dev"
            ALSA_PLAY_DEVICE="$(_alsa_play_for_cap "$try_dev")"
            _alsa_play_fallback_to_pulse
            AUDIO_BACKEND="alsa"
            return 0
        fi
    done < <(arecord -l 2>/dev/null | grep "^card")

    return 1
}

# Internal: return 0 (busy) if the plughw playback device is held by another process.
# Reads /proc/asound/ — no ALSA calls, no side-effects on IPC state.
_alsa_play_device_busy() {
    local dev="$1"
    [[ "$dev" =~ plughw:([0-9]+),([0-9]+) ]] || return 1
    local _c="${BASH_REMATCH[1]}" _d="${BASH_REMATCH[2]}"
    local _status="/proc/asound/card${_c}/pcm${_d}p/sub0/status"
    [ -f "$_status" ] && grep -q "^state: RUNNING" "$_status" 2>/dev/null
}

# Internal: return 0 if the given plughw capture device can be opened.
# Uses a 400ms timeout — EBUSY exits immediately, success exits at 400ms (code 124).
# Optional 2nd arg = attempts (default 1); >1 retries transient EBUSY (e.g. the
# sound server momentarily holding the card) with a short pause between tries.
_alsa_device_works() {
    local dev="$1" retries="${2:-1}" attempt rc
    for (( attempt=1; attempt<=retries; attempt++ )); do
        timeout 0.4 arecord -D "$dev" -f S16_LE -r 8000 -c 1 -t raw /dev/null 2>/dev/null
        rc=$?
        { [ $rc -eq 0 ] || [ $rc -eq 124 ]; } && return 0  # 124 = timeout = opened OK
        [ "$attempt" -lt "$retries" ] && sleep 0.3
    done
    return 1
}

# Internal: find a free playback device on the same card as the capture device.
# Uses aplay -l (safe listing, no device open) and the proc-based busy check.
# No aplay -D probes — those corrupt ALSA IPC state and break subsequent calls.
_alsa_play_for_cap() {
    local cap="$1"
    local card="${cap##*:}"; card="${card%%,*}"
    local dev pdev _is_hdmi _pass
    for _pass in 0 1; do
        while IFS= read -r line; do
            [[ "$line" =~ ^card[[:space:]]${card}[^,]*,[[:space:]]device[[:space:]]([0-9]+) ]] || continue
            dev="${BASH_REMATCH[1]}"
            _is_hdmi=0; [[ "$(_lc "$line")" =~ hdmi|displayport ]] && _is_hdmi=1
            [ "$_pass" -eq 0 ] && [ "$_is_hdmi" -eq 1 ] && continue
            [ "$_pass" -eq 1 ] && [ "$_is_hdmi" -eq 0 ] && continue
            pdev="plughw:${card},${dev}"
            _alsa_play_device_busy "$pdev" || { echo "$pdev"; return 0; }
        done < <(aplay -l 2>/dev/null | grep "^card")
    done
    echo ""
}

# If ALSA_PLAY_DEVICE is still unset after hardware detection, prefer the 'pulse'
# ALSA plugin (PipeWire/PulseAudio) over the ALSA 'default' dmix device.
# dmix requires hw:0,0 to exist; on HDMI-only machines that slot is absent.
# Verifies the PulseAudio socket exists before selecting pulse — aplay -L lists
# 'pulse' even when the daemon is unreachable, so the socket check is necessary.
_alsa_play_fallback_to_pulse() {
    [ -n "${ALSA_PLAY_DEVICE:-}" ] && return 0
    local _uid; _uid=$(id -u 2>/dev/null)
    local _sock="${XDG_RUNTIME_DIR:-/run/user/${_uid}}/pulse/native"
    if [ -S "$_sock" ] && aplay -L 2>/dev/null | grep -q "^pulse$"; then
        ALSA_PLAY_DEVICE="pulse"
    fi
}

# Install Reticulum itself. No package manager we target ships RNS, so this is
# the one dependency the pm_* layer above cannot satisfy: it has to come from
# PyPI. Ordered cheapest-first: an already-importable RNS is left alone.
#
# Everywhere but Termux this builds a venv at $PL_VENV and installs there, even
# on distros where a bare `pip install --user rns` would still work. Two
# reasons: PEP 668 interpreters refuse the bare install outright (and Arch has
# no system pip to refuse with), and a venv confines the whole thing to
# DATA_DIR so `uninstall` removing the data directory removes RNS with it.
#
# Sets BRIDGE_PYTHON on success so the bridge launched later this run uses the
# interpreter we just populated, without needing a restart.
install_rns() {
    if "$BRIDGE_PYTHON" -c 'import RNS' 2>/dev/null; then
        log_ok "RNS found ($BRIDGE_PYTHON)"
        return 0
    fi

    _pm_init

    if [ $IS_TERMUX -eq 1 ]; then
        # Termux sets no PEP 668 marker and its pip installs into the prefix
        # normally, so a venv would add indirection and buy nothing.
        check_dep pip || pkg install -y python-pip
        # PyPI has no Termux/Android wheel for cryptography (rns's only
        # compiled dependency), so a bare pip install would try to build it
        # from source, needing rust/build-essential/libffi and a long compile
        # on a phone. Termux's own prebuilt package satisfies pip's
        # requirement instead, so pip just reuses it.
        pkg install -y python-cryptography
        log_info "Installing RNS via pip (Termux)..."
        if ! pip install --upgrade rns; then
            log_err "pip install rns failed"
            return 1
        fi
        pip install --upgrade lxmf 2>/dev/null \
            || log_warn "lxmf not installed, backbone peer discovery disabled"
        BRIDGE_PYTHON="python3"
    else
        log_info "Creating Python environment for Reticulum at $PL_VENV ..."
        if ! python3 -m venv "$PL_VENV" 2>/dev/null; then
            log_err "Could not create a Python venv at $PL_VENV"
            log_err "The venv module is missing. Install it, then re-run:"
            case "$PM" in
                apt)  log_err "  sudo apt-get install -y python3-venv" ;;
                dnf)  log_err "  sudo dnf install -y python3-virtualenv" ;;
                brew) log_err "  brew install python3" ;;
                *)    log_err "  (your distro's python3 venv package)" ;;
            esac
            return 1
        fi
        log_info "Installing RNS from PyPI (needs network) ..."
        if ! "$PL_VENV/bin/pip" install --disable-pip-version-check -q --upgrade rns; then
            log_err "pip install rns failed. Check network access to pypi.org"
            return 1
        fi
        # Optional. RNS gates on-network peer discovery behind lxmf; without it
        # you are limited to the hubs seeded in RNS_HUBS, which still works.
        "$PL_VENV/bin/pip" install --disable-pip-version-check -q --upgrade lxmf 2>/dev/null \
            || log_warn "lxmf not installed, backbone peer discovery disabled"
        BRIDGE_PYTHON="$PL_VENV/bin/python"
    fi

    if "$BRIDGE_PYTHON" -c 'import RNS' 2>/dev/null; then
        local _v; _v=$("$BRIDGE_PYTHON" -c 'import RNS; print(RNS.__version__)' 2>/dev/null) || _v="?"
        log_ok "RNS $_v installed ($BRIDGE_PYTHON)"
        return 0
    fi
    log_err "RNS still not importable after install"
    return 1
}

install_deps() {
    header "Dependency Installer"

    local deps_needed=()
    local all_deps
    # Script-mode audio uses parecord/paplay (pulseaudio-utils), which talk to both
    # PulseAudio and PipeWire (via pipewire-pulse) and honor the desktop's
    # default devices. alsa-utils (arecord/aplay) is the universal fallback for
    # bare-ALSA and headless/Docker hosts. The per-distro package names live in
    # pm_pkglist; here we only list the binaries we actually expect afterward.

    # Shared deps + platform-specific
    if [ $IS_TERMUX -eq 1 ]; then
        all_deps=(opusenc opusdec socat openssl ffmpeg termux-microphone-record termux-media-player python3 pip)
    elif [ $IS_MACOS -eq 1 ]; then
        all_deps=(opusenc opusdec socat openssl ffmpeg)
    else
        # parecord/paplay (pulseaudio-utils) drive the preferred sound-server
        # backend; arecord/aplay (alsa-utils) are the fallback. Check both so the
        # installer actually pulls pulseaudio-utils on boxes that already have
        # alsa-utils — without it, a running PipeWire/PulseAudio owns the output
        # device and direct ALSA playback fails with EBUSY.
        all_deps=(opusenc opusdec socat openssl parecord paplay arecord aplay)
    fi

    # Check which deps are missing
    for dep in "${all_deps[@]}"; do
        if check_dep "$dep"; then
            log_ok "$dep found"
        else
            deps_needed+=("$dep")
            log_warn "$dep NOT found"
        fi
    done

    # System binaries are only half the job: the bridge also needs RNS, which
    # no package manager here ships. It must be handled on BOTH exits from this
    # function: this early one, and the post-install verify at the end.
    # Returning here without it was why a box with every binary present still
    # got the "some dependencies are missing" prompt on every single launch.
    if [ ${#deps_needed[@]} -eq 0 ]; then
        echo -e "\n${GREEN}All system dependencies are installed!${NC}\n"
        install_rns || return 1
        return 0
    fi

    echo -e "\n${YELLOW}Missing dependencies: ${deps_needed[*]}${NC}"
    if ! confirm_yes "\n${BOLD}Install missing dependencies? [Y/n]: ${NC}"; then
        echo -e "\n  ${YELLOW}Installation skipped.${NC}"
        return 1
    fi
    echo ""

    # Determine sudo usage: already root → none needed; non-root with sudo → use it;
    # non-root without sudo → warn and attempt anyway (may fail).
    _pm_init
    if [ $IS_TERMUX -eq 1 ]; then
        log_info "Termux detected — no sudo needed"
    elif [ "${EUID:-$(id -u)}" -eq 0 ]; then
        log_info "Running as root — no sudo needed"
    elif [ -n "$PM_SUDO" ]; then
        log_info "Will use sudo for package installation (you may be prompted for your password)"
    else
        log_warn "Not running as root and sudo not found — package install may fail."
        log_warn "Run as root or install packages manually:"
        log_warn "  apt-get install -y opus-tools socat openssl alsa-utils pulseaudio-utils"
    fi

    # Check which of our specific packages are already on the system BEFORE
    # installing. We record only the ones we actually add so uninstall removes
    # what this script put there — nothing pre-existing.
    local _pre_existing="" _pkg
    for _pkg in $(pm_pkglist); do
        pm_query "$_pkg" && _pre_existing="$_pre_existing $_pkg"
    done

    # Detect package manager and install (per-manager pre-steps, then pm_install)
    case "$PM" in
        termux)
            log_info "Detected Termux"
            log_info "Upgrading existing packages first..."
            pkg upgrade -y
            ;;
        apt)
            log_info "Detected apt package manager"
            $PM_SUDO apt-get update -qq || true
            ;;
        dnf)    log_info "Detected dnf package manager" ;;
        pacman) log_info "Detected pacman package manager" ;;
    esac

    if [ $IS_MACOS -eq 1 ] && ! check_dep brew; then
        # macOS: install Homebrew if not present, then re-detect so PM=brew.
        log_info "Homebrew not found — installing Homebrew first..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        for _brew_prefix in /opt/homebrew /usr/local; do
            if [ -x "$_brew_prefix/bin/brew" ]; then
                export PATH="$_brew_prefix/bin:$_brew_prefix/sbin:$PATH"
                break
            fi
        done
        if ! check_dep brew; then
            log_err "Homebrew installation failed"
            log_err "Install Homebrew manually: https://brew.sh"
            return 1
        fi
        log_ok "Homebrew installed"
        PM=""; _pm_init   # re-resolve now that brew exists
    fi

    if [ -z "$PM" ]; then
        log_err "No supported package manager found!"
        log_err "Please install manually: opus-tools, socat, openssl"
        return 1
    fi

    [ "$PM" = "brew" ] && log_info "Installing dependencies via Homebrew..."
    [ "$PM" = "brew" ] && [ -n "$BREW_ARCH" ] && log_info "Running brew under arm64 (Rosetta shell detected)"
    pm_install $(pm_pkglist)

    if [ $IS_TERMUX -eq 1 ]; then
        echo -e "\n${YELLOW}${BOLD}NOTE:${NC} You must also install the ${BOLD}Termux:API${NC} app from F-Droid"
        echo -e "      for microphone access.\n"
    fi

    # Verify
    echo -e "\n${BOLD}Verifying installation...${NC}"
    local failed=0
    for dep in "${all_deps[@]}"; do
        if check_dep "$dep"; then
            log_ok "$dep"
        else
            log_err "$dep still missing!"
            failed=1
        fi
    done

    if [ $failed -eq 0 ]; then
        echo -e "\n${GREEN}${BOLD}All dependencies installed successfully!${NC}"
        # Record only packages this script actually added (not pre-existing ones).
        # Uninstall reads this file — it only touches what is listed here.
        mkdir -p "$DATA_DIR" 2>/dev/null || true
        if [ -w "$DATA_DIR" ]; then
            local _new_pkgs=() _skipped=()
            for _pkg in $(pm_pkglist); do
                if [[ " $_pre_existing " == *" $_pkg "* ]]; then
                    _skipped+=("$_pkg")   # was already on the system — don't record
                else
                    _new_pkgs+=("$_pkg")  # newly added by this script
                fi
            done
            if [ ${#_skipped[@]} -gt 0 ]; then
                log_info "Pre-existing (will not be removed on uninstall): ${_skipped[*]}"
            fi
            if [ ${#_new_pkgs[@]} -gt 0 ]; then
                printf '%s\n' "${_new_pkgs[@]}" >> "$DATA_DIR/installed_packages"
                sort -u "$DATA_DIR/installed_packages" -o "$DATA_DIR/installed_packages" 2>/dev/null || true
                log_info "Recorded as removable on uninstall: ${_new_pkgs[*]}"
            else
                log_info "No new packages added — all were already installed"
            fi
        else
            log_warn "Install record not saved — data dir not writable."
            log_warn "Fix: sudo chown -R $(id -un):$(id -gn) \"$DATA_DIR\""
        fi
    else
        echo -e "\n${RED}Some dependencies could not be installed.${NC}"
        return 1
    fi

    # Second of the two exits that must cover RNS (see the early return above).
    echo ""
    install_rns || return 1
}

#=============================================================================
# UNINSTALLER
#=============================================================================

uninstall_all() {
    header "Uninstaller" "$RED"
    echo -e "  ${YELLOW}This will remove partyline data and optionally uninstall packages.${NC}"
    echo -e "  ${YELLOW}Your Reticulum identity lives in the data directory — removing it is permanent.${NC}\n"

    local remove_data=0 remove_pkgs=0 remove_docker=0

    # ── Data directory ────────────────────────────────────────────────────────
    if [ -d "$DATA_DIR" ]; then
        local data_size; data_size=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1) || data_size="unknown"
        echo -e "  ${BOLD}Data directory:${NC} ${WHITE}$DATA_DIR${NC}  ${DIM}($data_size)${NC}"
        echo -e "  ${DIM}Contains: config, shared secret, Reticulum identity (destination hash), logs,${NC}"
        echo -e "  ${DIM}          and the private Python venv holding RNS${NC}"
        confirm_no "\n  Remove data directory? [y/N]: " && remove_data=1
    else
        echo -e "  ${DIM}Data directory not found — nothing to remove.${NC}"
    fi

    # ── Installed packages ────────────────────────────────────────────────────
    if [ $DOCKER_MODE -eq 0 ]; then
        echo ""
        local pkg_list=()
        if [ -f "$DATA_DIR/installed_packages" ]; then
            while IFS= read -r _p; do
                [ -n "$_p" ] && pkg_list+=("$_p")
            done < "$DATA_DIR/installed_packages"
            if [ ${#pkg_list[@]} -gt 0 ]; then
                echo -e "  ${BOLD}Packages installed by this script (not pre-existing):${NC}"
                for _p in "${pkg_list[@]}"; do
                    echo -e "    ${DIM}•${NC} $_p"
                done
                confirm_no "\n  Remove these packages? [y/N]: " && remove_pkgs=1
            else
                echo -e "  ${DIM}Install record is empty — all dependencies were already present before install.${NC}"
                echo -e "  ${DIM}Nothing to remove.${NC}"
            fi
        else
            echo -e "  ${DIM}No install record found.${NC}"
            echo -e "  ${DIM}Package removal skipped — cannot tell what was pre-existing vs. installed by this script.${NC}"
            echo -e "  ${DIM}To remove manually if needed: opus-tools socat openssl alsa-utils pulseaudio-utils${NC}"
        fi
    fi

    # ── Docker cleanup ────────────────────────────────────────────────────────
    if check_dep docker && { [ -f "$BASE_DIR/docker-compose.yml" ] || [ -f "$BASE_DIR/docker-compose.yaml" ] || [ -f "$BASE_DIR/compose.yml" ] || [ -f "$BASE_DIR/compose.yaml" ]; }; then
        echo ""
        echo -e "  ${BOLD}Docker:${NC} compose file found"
        echo -e "  ${DIM}Will run: docker compose down  (stops containers) + removes ./data/docker/ bind-mount directory${NC}"
        confirm_no "\n  Remove Docker containers and volumes? [y/N]: " && remove_docker=1
    fi

    # ── Nothing selected ─────────────────────────────────────────────────────
    if [ $remove_data -eq 0 ] && [ $remove_pkgs -eq 0 ] && [ $remove_docker -eq 0 ]; then
        echo -e "\n  ${DIM}Nothing selected. Uninstall cancelled.${NC}\n"
        return 0
    fi

    # ── Final confirmation ────────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}${RED}Summary of what will be removed:${NC}"
    [ $remove_data   -eq 1 ] && echo -e "    ${RED}✗${NC} Data directory: $DATA_DIR"
    [ $remove_pkgs   -eq 1 ] && echo -e "    ${RED}✗${NC} Packages: ${pkg_list[*]}"
    [ $remove_docker -eq 1 ] && echo -e "    ${RED}✗${NC} Docker containers + data/docker/ directory"
    echo ""
    echo -ne "  ${BOLD}${RED}Type 'yes' to confirm: ${NC}"
    read -r _confirm
    if [ "$_confirm" != "yes" ]; then
        echo -e "\n  ${YELLOW}Uninstall cancelled.${NC}\n"
        return 0
    fi

    # ── Execute ───────────────────────────────────────────────────────────────
    echo ""

    if [ $remove_docker -eq 1 ]; then
        log_info "Stopping Docker containers..."
        (cd "$BASE_DIR" && docker compose down) && log_ok "Docker containers stopped" || log_err "docker compose down failed"
        if [ -d "$BASE_DIR/data/docker" ]; then
            log_info "Removing ./data/docker/ ..."
            rm -rf "$BASE_DIR/data/docker"
            log_ok "data/docker directory removed"
        fi
    fi

    if [ $remove_pkgs -eq 1 ] && [ ${#pkg_list[@]} -gt 0 ]; then
        log_info "Removing packages: ${pkg_list[*]}"
        _pm_init
        if [ -z "$PM" ]; then
            log_err "No supported package manager — remove packages manually: ${pkg_list[*]}"
        else
            pm_remove "${pkg_list[@]}"
            log_ok "Package removal done"
        fi
    fi

    if [ $remove_data -eq 1 ] && [ -d "$DATA_DIR" ]; then
        log_info "Removing $DATA_DIR ..."
        rm -rf "$DATA_DIR"
        log_ok "Data directory removed"
    fi

    echo -e "\n${GREEN}${BOLD}Uninstall complete.${NC}"
    echo -e "  ${DIM}The script itself (rns-party-line.sh) and the project directory were not touched.${NC}\n"
}

#=============================================================================
# RETICULUM STUBS  (was TOR HIDDEN SERVICE, PLAN.md §11.6 removed)
#=============================================================================
# The old Tor bootstrap and hidden-service machinery lived here. In the
# Reticulum port the transport is spun up by rns_bridge.py from relay_mode
# and _dial_remote directly (see write_rns_bridge above), so nothing else
# needs a Tor lifecycle. These no-op stubs stay only to keep any late-bound
# callers (menu handlers, cleanup traps) from tripping over unbound function
# names until the port has fully settled.

start_tor()      { :; }
wait_for_tor()   { :; }

# get_onion still returns the destination hash rns_bridge.py publishes into
# $ONION_FILE via --dest-hash-out. Same signature as before, different bytes
# in the file. Task 11 renames this to get_address in a later polish pass.
get_onion() { cat "$ONION_FILE" 2>/dev/null || true; }

# Derive and publish the destination hash without bringing up any interface.
# The hash is a pure function of the persistent identity, so there is no reason
# to make the user start a listener or a relay before they can see (or share)
# their own address. Creates the identity on first run. Silent no-op if the
# address file is already populated, unless -f forces a rewrite.
ensure_address() {
    local force=0
    [ "${1:-}" = "-f" ] && force=1
    if [ $force -eq 0 ] && [ -s "$ONION_FILE" ]; then return 0; fi
    write_rns_bridge || return 1
    "$BRIDGE_PYTHON" -u "$BRIDGE_PY" address \
        --config-dir "$RNS_CONFIG_DIR" \
        --identity "$RNS_IDENTITY_FILE" \
        --dest-hash-out "$ONION_FILE" \
        >"$RUNTIME_DIR/run/bridge_address_$$.stdout" 2>"$RUNTIME_DIR/run/bridge_address_$$.stderr" || return 1
    [ -s "$ONION_FILE" ]
}

# Best-effort LAN IP, for telling a caller what to enter for REFLECTOR_HOST.
# This is the address the RNS TCPClientInterface needs to reach this box's
# listener — separate from the destination hash, which only identifies the
# node once a connection exists. Best-effort only: behind NAT/VPN this may
# not be what a remote caller can actually reach; port-forwarding or the
# public IP may be needed instead.
_local_ip() {
    local ip=""
    if [ $IS_MACOS -eq 1 ]; then
        ip=$(ipconfig getifaddr en0 2>/dev/null)
        [ -z "$ip" ] && ip=$(ipconfig getifaddr en1 2>/dev/null)
    else
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        if [ -z "$ip" ]; then
            ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')
        fi
    fi
    printf '%s' "$ip"
}

# Rotate the persistent RNS identity (PLAN §20.2). Delete the file; the next
# reflector start will generate a fresh one and publish a new destination
# hash. The old address stops resolving as soon as this node stops
# announcing it, and any peers holding it in their path table will fail
# over on retry.
rotate_identity() {
    header "Rotate Identity"
    local old_addr
    old_addr=$(get_onion)
    if [ -n "$old_addr" ]; then
        echo -e "  ${DIM}Current: ${old_addr}${NC}"
    fi
    echo -e "  ${YELLOW}This will generate a new Reticulum identity.${NC}"
    echo -e "  ${YELLOW}The old address will stop working; share the new one${NC}"
    echo -e "  ${YELLOW}with your callers.${NC}\n"
    if ! confirm_no "  ${BOLD}Continue? [y/N]: ${NC}"; then
        log_info "Cancelled"
        return
    fi
    overwrite_rm "$RNS_IDENTITY_FILE"
    overwrite_rm "$ONION_FILE"
    # A running auto-listener still holds the old identity in memory; restart
    # it so it announces the new destination.
    start_auto_listener
    if ensure_address -f; then
        log_ok "New address: $(get_onion)"
        echo -e "  ${DIM}Share it with your callers; the old one is dead.${NC}"
    else
        log_warn "Identity deleted, but the new address could not be derived."
        log_warn "It will be published the next time you listen or host."
    fi
}

# Backwards-compat alias so any menu handler that still calls rotate_onion
# by its old name keeps working through the polish pass.
rotate_onion() { rotate_identity "$@"; }

#=============================================================================
# ENCRYPTION
#=============================================================================

set_shared_secret() {
    header "Set Shared Secret"
    echo -e "${DIM}Both parties must use the same secret for the call to work.${NC}"
    echo -e "${DIM}Share this secret securely (in person, via encrypted message, etc.)${NC}\n"

    if [ -n "$SHARED_SECRET" ]; then
        echo -e "Current secret: ${DIM}(set)${NC}"
    else
        echo -e "Current secret: ${DIM}(none)${NC}"
    fi

    echo -ne "\n${BOLD}Enter shared secret: ${NC}"
    read -r new_secret

    if [ -z "$new_secret" ]; then
        log_warn "Secret not changed"
        return
    fi

    SHARED_SECRET="$new_secret"
    mkdir -p "$DATA_DIR"

    if confirm_yes "\n  ${BOLD}Protect with a passphrase? [Y/n]: ${NC}"; then
        echo -ne "  ${BOLD}Choose a passphrase: ${NC}"
        read -rs _pass
        echo ""
        if [ -n "$_pass" ]; then
            echo -ne "  ${BOLD}Confirm passphrase: ${NC}"
            read -rs _pass2
            echo ""
            if [ "$_pass" = "$_pass2" ]; then
                echo -n "$SHARED_SECRET" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
                    -pass "fd:3" -out "$SECRET_FILE" 3<<< "${_pass}" 2>/dev/null
                chmod 600 "$SECRET_FILE"
                log_ok "Shared secret saved (encrypted with passphrase)"
                return
            else
                log_warn "Passphrases don't match"
            fi
        else
            log_warn "Empty passphrase"
        fi
        log_info "Falling back to plaintext storage"
    fi

    # Plaintext fallback
    echo -n "$SHARED_SECRET" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    log_ok "Shared secret saved"
}


# Echo the cipher currently in effect — the mid-call runtime override the in-call
# settings menu may have written, else the configured CIPHER.
_active_cipher() {
    if [ -f "$CIPHER_RUNTIME_FILE" ]; then
        printf '%s' "$(<"$CIPHER_RUNTIME_FILE")"
    else
        printf '%s' "$CIPHER"
    fi
}

# Update one absolute terminal row in place on the call UI (stderr): save the
# cursor, jump to the row and clear it, print, then restore the cursor. Args
# after the row are passed straight to printf, so a "fmt" plus values work.
status_at() {
    local row="$1"; shift
    printf '\0337' >&2
    printf '\033[%d;1H\033[K' "$row" >&2
    printf "$@" >&2
    printf '\0338' >&2
}

# Redraw the in-call status bar to the "Ready" state (called after T/S to restore
# the bar when returning from cooked-mode input or the settings menu).
_restore_ready_bar() {
    local _bar
    if ptt_toggle_mode; then
        _bar='  \033[1;32m Ready \033[0m \033[2m[SPACE]=Talk [T]=Chat [S]=Settings [Q]=Hang up\033[0m   '
    else
        _bar='  \033[1;32m Ready \033[0m \033[2m[SPACE]=Hold to Talk [T]=Chat [S]=Settings [Q]=Hang up\033[0m   '
    fi
    status_at "$STATUS_ROW" "$_bar"
}

# Every recorder (ffmpeg/AVFoundation, arecord, parecord, termux) needs a moment
# to open the audio device before it captures its first samples. Audio spoken in
# that ~300-500ms window is lost. So we show a yellow "◌ Standby..." bar the instant
# PTT is pressed, then flip to the red "● Recording" bar the moment the recorder
# actually produces audio (accurate per machine/backend), with a ~700ms safety cap.
# Runs in the background so the PTT loop keeps its timing; $1 is the recording bar.
_flip_to_recording_when_ready() {
    local _rec_bar="$1"
    (
        local _n=0
        # REC_FILE grows once the device is live. termux writes an m4a it only
        # finalizes on stop, so there the cap (below) does the flip instead.
        while [ $_n -lt 14 ]; do            # 14 × 50ms ≈ 700ms cap
            [ -s "$REC_FILE" ] && break
            sleep 0.05
            _n=$((_n + 1))
        done
        # Only flip if we're still recording (not released or hung up meanwhile).
        [ -f "$PTT_FLAG" ] && status_at "$STATUS_ROW" "$_rec_bar"
    ) &
}

# Echo a byte count in human-readable form: B, KB, or X.YMB.
_format_bytes() {
    if   [ "$1" -ge 1048576 ]; then printf '%d.%dMB' $(( $1 / 1048576 )) $(( $1 % 1048576 / 104858 ))
    elif [ "$1" -ge 1024 ];    then printf '%dKB' $(( $1 / 1024 ))
    else                            printf '%dB' "$1"
    fi
}

# Echo a byte count as "X.YKB" — one decimal place, fixed-point arithmetic.
# Used in both the send path (stop_and_send) and the receive path (in_call_session).
_format_kb() { local k=$(( $1 * 10 / 1024 )); printf '%d.%d' $(( k / 10 )) $(( k % 10 )); }

# Portable `timeout`: prefer a real timeout, then coreutils' gtimeout, then a
# perl alarm fallback. macOS ships no `timeout`, and without this a missing binary
# would make decrypt_file fail silently (its stderr goes to /dev/null) — which is
# the "encrypt/decrypt mismatch" seen in the loopback test. perl is always present
# on macOS. Exit codes mirror timeout's: 124 on timeout, 127 if exec fails.
# Portable advisory lock keyed on a path (replaces Linux-only `flock`, absent on
# macOS). `mkdir` is atomic on every POSIX filesystem, so a successful mkdir means
# exclusive ownership. Bounded spin (~5s) so a holder killed with -9 can never
# deadlock the others — they proceed best-effort, exactly as flock's absence would.
# Used to serialize concurrent writers to a FIFO (large AUDIO: lines exceed PIPE_BUF
# and would otherwise splice/corrupt).
_lock() {
    local d="$1.lockd" n=0
    while ! mkdir "$d" 2>/dev/null; do
        n=$((n + 1))
        [ "$n" -ge 250 ] && return 0
        sleep 0.02
    done
}
_unlock() { rmdir "$1.lockd" 2>/dev/null; }

_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        command timeout "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        command gtimeout "$@"
    else
        # Pure-shell fallback (macOS ships no `timeout`): run the command in the
        # background and a sleeping killer alongside it. Background jobs inherit the
        # caller's fds, so a here-string on fd 3 (the openssl passphrase) still
        # reaches the command. Returns the command's exit status (non-zero if killed).
        local d="$1"; shift
        "$@" &
        local _c=$!
        ( sleep "$d"; kill -TERM "$_c" 2>/dev/null ) &
        local _k=$!
        wait "$_c" 2>/dev/null
        local _rc=$?
        kill -TERM "$_k" 2>/dev/null
        wait "$_k" 2>/dev/null
        return "$_rc"
    fi
}

# Encrypt a file.
# The passphrase is fed via fd 3 (a bash here-string) rather than the environment
# (visible in /proc/*/environ to other processes) or stdin (which carries audio data).
# fd 3 is process-local and disappears when the subshell closes.
encrypt_file() {
    local infile="$1" outfile="$2"
    local c; c=$(_active_cipher)
    openssl enc -"${c}" -pbkdf2 -iter 10000 -pass "fd:3" \
        -in "$infile" -out "$outfile" 3<<< "${SHARED_SECRET}" 2>/dev/null
}

# Decrypt a file
decrypt_file() {
    local infile="$1" outfile="$2"
    local c; c=$(_active_cipher)
    _timeout "${DECRYPT_TIMEOUT}" openssl enc -d -"${c}" -pbkdf2 -iter 10000 -pass "fd:3" \
        -in "$infile" -out "$outfile" 3<<< "${SHARED_SECRET}" 2>/dev/null
}

#=============================================================================
# PROTOCOL SEND / VERIFY (HMAC)
#=============================================================================

# Echo 1/0 — whether HMAC signing is active: the mid-call runtime override if the
# settings menu wrote one (empty file falls back to HMAC_AUTH), else off.
_active_hmac() {
    local h=0
    if [ -f "$HMAC_RUNTIME_FILE" ]; then h=$(<"$HMAC_RUNTIME_FILE"); h="${h//[[:space:]]/}"; fi
    [ -z "$h" ] && h="$HMAC_AUTH"
    printf '%s' "$h"
}

# Send a protocol message, optionally HMAC-signed with random nonce.
# fd 3 (read) and fd 4 (write) are opened by in_call_session against the
# recv/send FIFOs — this function writes to fd 4; the recv loop reads fd 3.
proto_send() {
    local msg="$1"
    local _hmac; _hmac=$(_active_hmac)
    # Serialize all writes to fd 4. The background heartbeat (PING) is a second
    # concurrent writer; large AUDIO: lines exceed the FIFO atomic-write size
    # (PIPE_BUF), so without this lock a PING could splice into the middle of an
    # audio packet and corrupt it. _lock makes every send atomic w.r.t. the others.
    local _sl="$RUNTIME_DIR/run/send_lock_$$"
    _lock "$_sl"
    local _out
    if [ "$_hmac" -eq 1 ]; then
        local nonce sig signed_msg
        nonce=$(od -An -N8 -tx1 /dev/urandom); nonce="${nonce//[[:space:]]/}"
        signed_msg="${nonce}:${msg}"
        sig=$(printf '%s' "$signed_msg" | openssl dgst -sha256 -hmac "$SHARED_SECRET" -r 2>/dev/null)
        sig="${sig%% *}"
        _out="${signed_msg}|${sig}"
    else
        _out="$msg"
    fi
    # Bounded like every other blocking I/O point in the app (decrypt_file,
    # the relay's own fan-out writes): fd 4 can be open but stalled (a dead
    # transport whose local socket hasn't closed yet), and an unbounded write
    # here would hold _sl forever, freezing every future send (PTT, heartbeat)
    # behind it with no recovery path.
    _timeout 10 sh -c 'printf "%s\n" "$1" >&4' - "$_out" 2>/dev/null || true
    _unlock "$_sl"
}

# Verify HMAC on a received message
# Outputs the raw message (without nonce) on stdout; returns 1 on failure
proto_verify() {
    local line="$1"
    local _hmac; _hmac=$(_active_hmac)
    if [ "$_hmac" -ne 1 ]; then
        echo "$line"
        return 0
    fi
    # Must contain | separator for HMAC
    if [[ "$line" != *"|"* ]]; then
        return 1
    fi
    local signed_msg="${line%|*}"
    local received_sig="${line##*|}"
    local expected_sig
    expected_sig=$(printf '%s' "$signed_msg" | openssl dgst -sha256 -hmac "$SHARED_SECRET" -r 2>/dev/null)
    expected_sig="${expected_sig%% *}"
    if [ "$received_sig" = "$expected_sig" ]; then
        # Reject replayed nonces. The log file is per-call (per-$$ path) and
        # cleaned up by cleanup_call, so it's bounded by session length.
        local nonce="${signed_msg%%:*}"
        if grep -qF "$nonce" "$NONCE_LOG_FILE" 2>/dev/null; then
            return 1
        fi
        # If we can't log the nonce (disk full, etc.) reject rather than risk replay
        echo "$nonce" >> "$NONCE_LOG_FILE" 2>/dev/null || return 1
        # Strip nonce prefix (nonce:message → message)
        echo "${signed_msg#*:}"
        return 0
    fi
    return 1
}

#=============================================================================
# AUDIO PIPELINE
#=============================================================================

# Backend-aware command builders (Linux). One definition each so every call
# site records/plays through the active backend (pulse | alsa). All work in raw
# signed-16-bit little-endian mono. Assume detect_audio_backend has already run.

# Record a fixed number of seconds to a file (foreground; used by the test).
# For the pulse backend, --latency-msec keeps parecord flushing its file output
# ~20×/sec, so `timeout` (SIGTERM after $duration) leaves a complete recording.
# arecord exits cleanly via -d.
# Percentage of a raw S16LE capture that is zero bytes. A dead capture device
# writes pure zeros, so the file is the right SIZE but carries no signal, and
# every step downstream succeeds on that silence. Speech sits around 10-40%
# zero bytes (the high byte of a quiet sample is 0); 100% means nothing was
# captured at all. Used by both the loopback test and the live send path.
_raw_silence_pct() {
    local f="$1" total nz
    total=$(file_size "$f")
    [ "$total" -gt 0 ] 2>/dev/null || { echo 100; return 0; }
    nz=$(tr -d '\0' < "$f" | wc -c)
    echo $(( 100 - (nz * 100 / total) ))
}

_record_raw() {
    local outfile="$1" duration="$2"
    case "$AUDIO_BACKEND" in
        pulse)
            timeout -k 0.3 "$duration" parecord --latency-msec=50 \
                --rate="$SAMPLE_RATE" --channels=1 --format=s16le --raw \
                ${PULSE_SOURCE:+-d "$PULSE_SOURCE"} "$outfile" 2>/dev/null || true ;;
        *)  # alsa
            local _dev_args=()
            [ -n "${ALSA_DEVICE:-}" ] && _dev_args=(-D "$ALSA_DEVICE")
            arecord "${_dev_args[@]}" -f S16_LE -r "$SAMPLE_RATE" -c 1 -t raw -d "$duration" -q "$outfile" 2>/dev/null ;;
    esac
}

# Start continuous recording to a file in the background. Sets REC_PID to the
# actual recorder PID so stop_and_send can kill it. --latency-msec keeps
# parecord flushing the file ~20×/sec, so the SIGTERM at end-of-talk preserves
# everything captured. arecord on a plughw device flushes incrementally too.
_start_record_bg() {
    local outfile="$1"
    # MAX_PTT_SECONDS caps a single transmission: the recorder self-terminates after
    # that long even if the talk key is still held, so a stuck/held PTT can't produce
    # an unbounded blob. parecord is wrapped in `timeout` (it has no native limit);
    # arecord self-limits via -d. stop_and_send's later kill/wait is then a no-op.
    case "$AUDIO_BACKEND" in
        pulse)
            timeout -k 0.3 "$MAX_PTT_SECONDS" parecord --latency-msec=50 --rate="$SAMPLE_RATE" --channels=1 --format=s16le --raw \
                ${PULSE_SOURCE:+-d "$PULSE_SOURCE"} "$outfile" 2>/dev/null &
            REC_PID=$! ;;
        *)
            local _dev_args=()
            [ -n "${ALSA_DEVICE:-}" ] && _dev_args=(-D "$ALSA_DEVICE")
            arecord "${_dev_args[@]}" -f S16_LE -r "$SAMPLE_RATE" -c 1 -t raw -d "$MAX_PTT_SECONDS" -q "$outfile" 2>/dev/null &
            REC_PID=$! ;;
    esac
}

# Play raw S16LE mono from stdin using a specific player + device. One place
# that knows the per-tool flags. Player stderr → ${PLAY_ERRLOG:-/dev/null}.
#   pw-play : PipeWire direct (present on PipeWire desktops without pulseaudio-utils)
#   paplay  : PulseAudio / pipewire-pulse
#   aplay   : ALSA (dev "default"/"pulse" route to the server; plughw is raw HW)
_play_with() {
    local player="$1" dev="$2" rate="${3:-48000}" err="${PLAY_ERRLOG:-/dev/null}"
    case "$player" in
        pw-play) pw-play --raw --format=s16 --rate="$rate" --channels=1 ${dev:+--target "$dev"} - 2>"$err" ;;
        paplay)  paplay --raw --format=s16le --rate="$rate" --channels=1 ${dev:+-d "$dev"} 2>"$err" ;;
        *)       aplay -D "${dev:-default}" -f S16_LE -r "$rate" -c 1 -q 2>"$err" ;;
    esac
}

# Resolve the playback route the user EXPLICITLY configured, if any, with no
# probing and no side effects. Echoes "player|device" (device may be empty) and
# returns 0 when an explicit pick is honored; returns 1 when nothing is
# configured (the caller should probe instead).
#
# An explicit pick is AUTHORITATIVE. A device the user actually heard in 'Test
# all outputs' and selected is used verbatim for live calls — we never override
# it by probing other candidates that merely "open" (exit 0). "Opens" is not
# "audible": paplay/pw-play/aplay all succeed on a disconnected HDMI jack, a
# muted sink, or the wrong default sink, so probe-and-pick-first silently routes
# audio somewhere the user can't hear. Honoring the pick is the whole fix.
_resolve_play_route() {
    # Server sink chosen in the picker → play through the server tools.
    if [ -n "${PULSE_SINK:-}" ]; then
        check_dep pw-play && { echo "pw-play|$PULSE_SINK"; return 0; }
        check_dep paplay  && { echo "paplay|$PULSE_SINK";  return 0; }
    fi
    # ALSA hardware/route chosen in the picker → play through aplay.
    if [ -n "${ALSA_PLAY_DEVICE:-}" ] && check_dep aplay; then
        echo "aplay|$ALSA_PLAY_DEVICE"; return 0
    fi
    return 1
}

# Probe playback ONCE and cache the first method that actually opens an output.
# Plays 0.05s of silence (inaudible) to each candidate; the winner is whatever
# the machine accepts. Order prefers routes that reach the desktop's default
# device and avoids raw plughw (which gets EBUSY when a sound server owns the
# card — the classic "recording OK, playback FAILED" case). Sets PLAY_PLAYER/
# PLAY_DEV. Linux only (macOS uses afplay; Termux uses termux-media-player).
#
# An explicit pick (PULSE_SINK/ALSA_PLAY_DEVICE) short-circuits the probe and is
# used verbatim — see _resolve_play_route. The probe only runs when nothing is
# configured (the zero-config laptop case), preserving plug-and-play there.
_detect_play_method() {
    [ -n "${PLAY_PLAYER:-}" ] && return 0
    [ $IS_TERMUX -eq 1 ] && return 1
    [ $IS_MACOS -eq 1 ] && return 1

    # Honor an explicit pick — but verify it actually OPENS first. We trust the
    # user's ear on audibility (so we never probe *past* a working pick), yet a
    # device that returns EBUSY can't play at all: on a PipeWire box the server
    # owns the active sink, so a raw `aplay -D plughw:X,Y` to it fails with
    # "Device or resource busy". When that happens we must NOT go silent — fall
    # through to the candidate probe (whose server-default entry routes correctly
    # through PipeWire). The open-probe uses its own 0.05s of silence, so the real
    # audio stream is never consumed by a failed attempt.
    local _route _rp _rd
    if _route=$(_resolve_play_route); then
        _rp="${_route%%|*}"; _rd="${_route#*|}"
        # 4800 bytes = 50 ms at 48 kHz S16LE — enough to confirm the device opens,
        # inaudible, and fast enough not to stall call setup.
        if head -c 4800 /dev/zero | PLAY_ERRLOG=/dev/null _play_with "$_rp" "$_rd" 48000; then
            PLAY_PLAYER="$_rp"; PLAY_DEV="$_rd"
            return 0
        fi
    fi

    local cands=() c player dev
    # 1) An explicitly chosen server sink (from the picker).
    if [ -n "${PULSE_SINK:-}" ]; then
        check_dep pw-play && cands+=("pw-play|$PULSE_SINK")
        check_dep paplay  && cands+=("paplay|$PULSE_SINK")
    fi
    # 2) Server default sink — what the user hears from everything else.
    check_dep pw-play && cands+=("pw-play|")
    check_dep paplay  && cands+=("paplay|")
    # 3) ALSA routes: "default"/"pulse" hand off to the server; sysdefault too.
    if check_dep aplay; then
        cands+=("aplay|default" "aplay|pulse" "aplay|sysdefault")
        # 4) An explicitly chosen ALSA device.
        [ -n "${ALSA_PLAY_DEVICE:-}" ] && cands+=("aplay|$ALSA_PLAY_DEVICE")
        # 5) Last resort: every hardware output device directly.
        while IFS= read -r line; do
            [[ "$line" =~ ^card[[:space:]]([0-9]+):.*device[[:space:]]([0-9]+): ]] || continue
            cands+=("aplay|plughw:${BASH_REMATCH[1]},${BASH_REMATCH[2]}")
        done < <(aplay -l 2>/dev/null | grep "^card")
    fi

    for c in "${cands[@]}"; do
        player="${c%%|*}"; dev="${c#*|}"
        # Same 50 ms silence probe as above — confirms the candidate opens.
        if head -c 4800 /dev/zero | PLAY_ERRLOG=/dev/null _play_with "$player" "$dev" 48000; then
            PLAY_PLAYER="$player"; PLAY_DEV="$dev"
            return 0
        fi
    done
    return 1
}

# Play raw S16LE mono from stdin at the given rate (default 48000), using the
# probed-working method. Player stderr → ${PLAY_ERRLOG:-/dev/null}.
_play_raw() {
    local rate="${1:-48000}"
    if _detect_play_method; then
        _play_with "$PLAY_PLAYER" "$PLAY_DEV" "$rate"
    else
        # Nothing probed clean — prefer server tools over aplay -D default, which
        # reliably gets EBUSY on PipeWire desktops where the server owns the HDMI sink.
        # Routes through _play_with so the per-tool flag spelling lives in one place.
        if check_dep paplay; then
            _play_with paplay "" "$rate"
        elif check_dep pw-play; then
            _play_with pw-play "" "$rate"
        else
            _play_with aplay default "$rate"
        fi
    fi
}

# Record a timed chunk of raw audio (used by audio test)
audio_record() {
    local outfile="$1"
    local duration="${2:-$CHUNK_DURATION}"

    if [ $IS_TERMUX -eq 1 ]; then
        local tmp_rec="$AUDIO_DIR/tmrec_$(uid).tmp"
        overwrite_rm "$tmp_rec"
        termux-microphone-record -l "$((duration + 1))" -f "$tmp_rec" </dev/null &>/dev/null
        sleep "$duration"
        termux-microphone-record -q &>/dev/null || true
        sleep 0.5
        if [ -s "$tmp_rec" ]; then
            ffmpeg -y -i "$tmp_rec" -f s16le -ar "$SAMPLE_RATE" -ac 1 \
                "$outfile" &>/dev/null || log_warn "ffmpeg conversion failed"
        fi
        overwrite_rm "$tmp_rec"
    elif [ $IS_MACOS -eq 1 ]; then
        ffmpeg -y -f avfoundation -i ":${MACOS_AUDIO_INDEX}" -t "$duration" \
            -f s16le -ar "$SAMPLE_RATE" -ac 1 "$outfile" 2>/dev/null
    else
        detect_audio_backend
        _record_raw "$outfile" "$duration"
    fi
}

# Start continuous recording in background (returns immediately)
# Sets REC_PID and REC_FILE globals
start_recording() {
    local _id; _id=$(uid)
    REC_FILE="$AUDIO_DIR/msg_${_id}.tmp"
    overwrite_rm "$REC_FILE"

    # MAX_PTT_SECONDS caps a single transmission on every backend (see _start_record_bg).
    if [ $IS_TERMUX -eq 1 ]; then
        termux-microphone-record -l "$MAX_PTT_SECONDS" -f "$REC_FILE" </dev/null &>/dev/null &
        REC_PID=$!
    elif [ $IS_MACOS -eq 1 ]; then
        ffmpeg -y -f avfoundation -i ":${MACOS_AUDIO_INDEX}" -t "$MAX_PTT_SECONDS" \
            -f s16le -ar "$SAMPLE_RATE" -ac 1 "$REC_FILE" 2>/dev/null &
        REC_PID=$!
    else
        detect_audio_backend
        _start_record_bg "$REC_FILE"
    fi
}


# Stop recording and send the message
# Encodes, encrypts, base64-encodes, and writes to fd 4.
# Audio is split into PTT_CHUNK_SECONDS-second pieces before encoding so that
# each AUDIO: line is small enough to pass through the relay's RELAY_WRITE_TIMEOUT
# and the receiver's CLIENT_TIMEOUT even on a slow link.  Without chunking,
# a 40-60 s recording (~100-160 KB base64) can stall the relay's forward past its
# 10-second budget; the relay then kills the write mid-line, and the heartbeat
# PING that arrives next gets concatenated onto the truncated bytes in the TCP
# stream — the receiver reads a garbled combined "line", proto_verify discards it,
# and the connection appears lost.
stop_and_send() {
    local _id; _id=$(uid)
    local raw_file="$AUDIO_DIR/tx_${_id}.tmp"

    # Stop the recording
    if [ $IS_TERMUX -eq 1 ]; then
        termux-microphone-record -q &>/dev/null || true
        kill "$REC_PID" 2>/dev/null || true
        wait "$REC_PID" 2>/dev/null || true
        sleep 0.3  # let file flush
        # Convert m4a → raw PCM
        if [ -s "$REC_FILE" ]; then
            ffmpeg -y -i "$REC_FILE" -f s16le -ar "$SAMPLE_RATE" -ac 1 \
                "$raw_file" &>/dev/null || true
        fi
        overwrite_rm "$REC_FILE"
    else
        kill "$REC_PID" 2>/dev/null || true
        wait "$REC_PID" 2>/dev/null || true
        raw_file="$REC_FILE"  # parecord/arecord write raw S16LE directly — no ffmpeg needed
                              # (termux-microphone-record saves AAC/m4a, hence the conversion above)
    fi

    REC_PID=""
    REC_FILE=""

    # A dead capture device fills the file with zeros, so every check below
    # passes: opusenc encodes the silence, the cipher encrypts it, and the relay
    # fans it out. The talker sees a normal "Last sent: 4.2KB" and only the
    # listeners know anything is wrong, which is the worst place to find out.
    # Report it on the sender's own status row instead, and skip the send:
    # there is no signal in the clip to transmit. Same 99% threshold as the
    # loopback test (real speech measures far below it; a muted or wrong input
    # measures 100).
    if [ -s "$raw_file" ] && [ "$(_raw_silence_pct "$raw_file")" -ge 99 ]; then
        LAST_SENT_INFO="SILENT (no mic)"
        overwrite_rm "$raw_file"
        return 0
    fi

    # Encode → encrypt → send in PTT_CHUNK_SECONDS-second chunks
    if [ -s "$raw_file" ]; then
        local _chunk_bytes=$(( SAMPLE_RATE * 2 * PTT_CHUNK_SECONDS ))
        local _chunk_prefix="$AUDIO_DIR/tx_c_${_id}_"
        split -b "$_chunk_bytes" "$raw_file" "$_chunk_prefix" 2>/dev/null || true

        local _total_enc=0
        for _chunk_raw in "${_chunk_prefix}"*; do
            [ -e "$_chunk_raw" ] || continue   # no-match guard (unset glob)
            [ -s "$_chunk_raw" ] || { overwrite_rm "$_chunk_raw"; continue; }
            local _cid; _cid=$(uid)
            local _opus="$AUDIO_DIR/tx_o_${_cid}.tmp"
            local _enc="$AUDIO_DIR/tx_e_${_cid}.tmp"

            opusenc --raw --raw-rate "$SAMPLE_RATE" --raw-chan 1 \
                --bitrate "$OPUS_BITRATE" --framesize "$OPUS_FRAMESIZE" \
                --speech --quiet "$_chunk_raw" "$_opus" 2>/dev/null
            overwrite_rm "$_chunk_raw"

            if [ -s "$_opus" ]; then
                encrypt_file "$_opus" "$_enc" 2>/dev/null
                overwrite_rm "$_opus"
                if [ -s "$_enc" ]; then
                    local b64
                    b64=$(base64 < "$_enc" | tr -d '\n')
                    if [ "${#b64}" -gt "$MAX_AUDIO_B64" ]; then
                        # Bitrate-robust backstop: chunk is still over the relay line cap
                        LAST_SENT_INFO="too long"
                    else
                        proto_send "AUDIO:${b64}"
                        _total_enc=$(( _total_enc + $(file_size "$_enc") ))
                    fi
                    overwrite_rm "$_enc"
                fi
            fi
        done
        [ "$_total_enc" -gt 0 ] && LAST_SENT_INFO="$(_format_kb "$_total_enc")KB"
    fi
    overwrite_rm "$raw_file"
}

# True when PTT should behave as press-to-start / press-again-to-stop.
# Termux is always toggle (its keyboard fires on release); desktop opts in via PTT_TOGGLE_MODE.
# Defined as a function (not cached) so the in-call settings menu can flip it mid-call.
ptt_toggle_mode() {
    [ $IS_TERMUX -eq 1 ] || [ "${PTT_TOGGLE_MODE:-0}" -eq 1 ]
}

ensure_pcm_rms() {
    command -v pcm_rms >/dev/null 2>&1 && return 0
    command -v gcc >/dev/null 2>&1 || return 1
    local _bin="$DATA_DIR/bin"
    mkdir -p "$_bin" 2>/dev/null || return 1
    local _src="$_bin/pcm_rms.c"
    cat > "$_src" << 'PCM_RMS_C_EOF'
#include <stdio.h>
#include <math.h>
#include <stdint.h>

int main(void) {
    int16_t buf[4096];
    double sum = 0.0;
    long count = 0;
    size_t n;
    while ((n = fread(buf, sizeof(int16_t), 4096, stdin)) > 0) {
        for (size_t i = 0; i < n; i++) {
            double s = (double)buf[i];
            sum += s * s;
        }
        count += n;
    }
    if (count == 0) { printf("-91.0\n"); return 0; }
    double rms = sqrt(sum / count);
    double dbfs = 20.0 * log10(rms / 32768.0);
    printf("%.1f\n", dbfs);
    return 0;
}
PCM_RMS_C_EOF
    gcc -O2 -o "$_bin/pcm_rms" "$_src" -lm 2>/dev/null || { rm -f "$_src"; return 1; }
    rm -f "$_src"
    export PATH="$_bin:$PATH"
    return 0
}

# Play an opus file
play_chunk() {
    local opus_file="$1"

    local _norm_gain=""
    if [ "${NORMALIZE_PLAYBACK:-0}" -eq 1 ] && command -v pcm_rms >/dev/null 2>&1; then
        local _rms
        _rms=$(opusdec --quiet --rate 48000 "$opus_file" - 2>/dev/null | pcm_rms)
        if [ -n "$_rms" ]; then
            _norm_gain=$(awk -v r="$_rms" \
                'BEGIN{g=-24-r; if(g>40)g=40; if(g<-40)g=-40;
                       printf "%d",(g>0?g+0.5:g-0.5)}')
        fi
    fi

    if [ $IS_TERMUX -eq 1 ]; then
        local _tmp_wav; _tmp_wav="${AUDIO_DIR}/play_$(uid).wav"
        if [ -n "$_norm_gain" ]; then
            opusdec --quiet --rate 48000 --gain "$_norm_gain" "$opus_file" "$_tmp_wav" 2>/dev/null || true
        else
            opusdec --quiet --rate 48000 "$opus_file" "$_tmp_wav" 2>/dev/null || true
        fi
        if [ -s "$_tmp_wav" ]; then
            termux-media-player play "$_tmp_wav" >/dev/null 2>&1 || true
            local _wav_size; _wav_size=$(file_size "$_tmp_wav"); [ "$_wav_size" -gt 0 ] 2>/dev/null || _wav_size=44
            local _wav_secs=$(( (_wav_size - 44) / 96000 + 1 ))
            local _max_polls=$(( (_wav_secs + 15) * 2 ))
            local _startup_polls=6
            local _tw=0 _playing=0
            while [ $_tw -lt $_max_polls ]; do
                sleep 0.5; _tw=$((_tw + 1))
                if termux-media-player info 2>/dev/null | grep -qi 'playing'; then
                    _playing=1
                elif [ $_playing -eq 1 ]; then
                    break   # transitioned playing → stopped
                elif [ $_tw -ge $_startup_polls ]; then
                    break   # never started within 3 s startup window
                fi
            done
        fi
        overwrite_rm "$_tmp_wav"
    elif [ $IS_MACOS -eq 1 ]; then
        local _wav="$AUDIO_DIR/play_$(uid).wav"
        if [ -n "$_norm_gain" ]; then
            opusdec --quiet --rate 48000 --gain "$_norm_gain" "$opus_file" "$_wav" 2>/dev/null || true
        else
            opusdec --quiet --rate 48000 "$opus_file" "$_wav" 2>/dev/null || true
        fi
        [ -s "$_wav" ] && afplay "$_wav" 2>/dev/null || true
        overwrite_rm "$_wav"
    else
        detect_audio_backend
        if [ -n "$_norm_gain" ]; then
            opusdec --quiet --rate 48000 --gain "$_norm_gain" "$opus_file" - \
                2>/dev/null | _play_raw 48000 || true
        else
            opusdec --quiet --rate 48000 "$opus_file" - 2>/dev/null | \
                _play_raw 48000 || true
        fi
    fi
}

# PLAN §20.4: promoted from the Termux-only pattern to all platforms.
# One background worker plays queued clips one at a time so the receive loop
# never blocks on playback. Serialised playback (PLAN §16.5) is preserved
# because there is a single consumer.
#
# The queue holds opus file paths; the worker calls play_chunk on each. All
# per-platform decoding (opus → wav → speaker) lives inside play_chunk and
# was already synchronous everywhere, so no per-platform branching is needed
# here.
start_play_worker() {
    local _q="$RUNTIME_DIR/run/play_queue_$$.fifo"
    PLAY_QUEUE_FIFO="$_q"
    mkfifo "$_q" 2>/dev/null || { PLAY_QUEUE_FIFO=""; return 1; }
    # O_RDWR on the FIFO keeps a writer open so the worker's read never
    # sees EOF when there is nothing queued.
    exec 7<>"$_q"
    PLAY_QUEUE_FD=7
    (
        while IFS= read -r _pw_file <&7; do
            [ -s "$_pw_file" ] || { overwrite_rm "$_pw_file" 2>/dev/null; continue; }
            play_chunk "$_pw_file" 2>/dev/null || true
            overwrite_rm "$_pw_file"
        done
    ) &
    PLAY_WORKER_PID=$!
}


#=============================================================================
# CALL CLEANUP — RESET EVERYTHING TO FRESH STATE
#=============================================================================

cleanup_call() {
    # Release the call wakelock (no-op off Termux)
    wakelock_release

    # Restore terminal to sane state
    if [ -n "$ORIGINAL_STTY" ]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || true
    fi
    stty sane 2>/dev/null || true
    ORIGINAL_STTY=""

    # Stop Termux play worker and clean up its queue FIFO
    if [ -n "${PLAY_WORKER_PID:-}" ]; then
        kill "$PLAY_WORKER_PID" 2>/dev/null || true
        PLAY_WORKER_PID=""
    fi
    { exec 7>&-; } 2>/dev/null || true
    PLAY_QUEUE_FD=0
    if [ -n "${PLAY_QUEUE_FIFO:-}" ]; then
        rm -f "$PLAY_QUEUE_FIFO"
        PLAY_QUEUE_FIFO=""
    fi

    # Close pipe file descriptors to unblock any blocking reads
    # NOTE: must use { } group so 2>/dev/null doesn't permanently redirect stderr
    { exec 3<&-; } 2>/dev/null || true
    { exec 4>&-; } 2>/dev/null || true

    # Kill all call-related processes by PID files.
    # SIGTERM first; escalate to SIGKILL only if the process is still alive after
    # a brief grace period. We wait after each kill so the FIFOs are fully released
    # before we unlink them below — avoids a race on the next call setup.
    for pidfile in "$PID_DIR"/socat.pid "$PID_DIR"/socat_call.pid "$PID_DIR"/recv_loop.pid; do
        if [ -f "$pidfile" ]; then
            local pid
            pid=$(cat "$pidfile" 2>/dev/null)
            kill_pid "$pid"
            overwrite_rm "$pidfile"
        fi
    done

    # Kill recording process if active
    kill_pid "$REC_PID"

    # Brief pause for any remaining kernel cleanup
    sleep 0.1

    # Kill volume monitor if active
    kill_pid "$VOL_MON_PID"
    VOL_MON_PID=""

    # Remove all runtime files for this PID
    overwrite_rm "$PTT_FLAG" "$CONNECTED_FLAG"
    overwrite_rm "$RECV_PIPE" "$SEND_PIPE"
    overwrite_rm "$CIPHER_RUNTIME_FILE"
    overwrite_rm "$HMAC_RUNTIME_FILE"
    overwrite_rm "$NONCE_LOG_FILE"
    overwrite_rm "$RUNTIME_DIR/run/remote_id_$$"
    overwrite_rm "$RUNTIME_DIR/run/remote_cipher_$$"
    overwrite_rm "$RUNTIME_DIR/run/relay_mode_$$"
    overwrite_rm "$RUNTIME_DIR/run/group_count_$$"
    overwrite_rm "$RUNTIME_DIR/run/incoming_$$"
    overwrite_rm "$RUNTIME_DIR/run/call_connected_$$"
    overwrite_rm "$RUNTIME_DIR/run/vol_ptt_trigger_$$"
    overwrite_rm "$RUNTIME_DIR/run/send_lock_$$"

    # Kill heartbeat sender if active
    if [ -n "${HEARTBEAT_PID:-}" ]; then
        kill "$HEARTBEAT_PID" 2>/dev/null || true
        HEARTBEAT_PID=""
    fi

    # Clean temp audio files
    overwrite_rm "$AUDIO_DIR"/*.tmp

    # Reset state variables
    CALL_ACTIVE=0
    REC_PID=""
}
#=============================================================================
# AUTO-LISTEN (BACKGROUND LISTENER)
#=============================================================================

start_auto_listener() {
    # Only start if auto-listen is enabled and a secret is set. No transport
    # readiness gate needed: write_rns_bridge brings up its own RNS instance,
    # it doesn't depend on anything else having run first.
    if [ "$AUTO_LISTEN" -ne 1 ]; then return 0; fi
    if [ -z "$SHARED_SECRET" ]; then return 0; fi

    # Stop any existing listener first
    stop_auto_listener

    mkdir -p "$AUDIO_DIR" "$RUNTIME_DIR/run"
    overwrite_rm "$RECV_PIPE" "$SEND_PIPE" "$AUTO_LISTEN_FLAG"
    mkfifo "$RECV_PIPE" "$SEND_PIPE"

    # PLAN §11.2: direct listen goes over Reticulum via rns_bridge.py, same as
    # relay_mode and _dial_remote. The handler is the minimal two-way pipe
    # bridge the old socat SYSTEM one-liner used to be.
    write_rns_bridge || return 0
    overwrite_rm "$ONION_FILE" 2>/dev/null
    "$BRIDGE_PYTHON" -u "$BRIDGE_PY" listen \
        --config-dir "$RNS_CONFIG_DIR" \
        --identity "$RNS_IDENTITY_FILE" \
        --tcp-listen "${RNS_LISTEN_HOST}:${REFLECTOR_PORT}" \
        --hubs "$RNS_HUBS" \
        --autoconnect "$RNS_AUTOCONNECT" \
        --dest-hash-out "$ONION_FILE" \
        --max-line-bytes "$MAX_LINE_BYTES" \
        -- bash -c 'touch "$1"; cat "$2" & cat > "$3"' _ \
             "$AUTO_LISTEN_FLAG" "$SEND_PIPE" "$RECV_PIPE" \
        >"$RUNTIME_DIR/run/bridge_auto_$$.stdout" 2>"$RUNTIME_DIR/run/bridge_auto_$$.stderr" &
    AUTO_LISTEN_PID=$!
    save_pid "socat" "$AUTO_LISTEN_PID"
}

stop_auto_listener() {
    kill_pid "$AUTO_LISTEN_PID"
    AUTO_LISTEN_PID=""
    overwrite_rm "$AUTO_LISTEN_FLAG" "$RECV_PIPE" "$SEND_PIPE"
}

#=============================================================================
# TERMUX WAKELOCK (keep CPU awake during a call so the screen-lock doesn't
# freeze the heartbeat / receive loop). No-op off Termux or if termux-api
# isn't installed. Held only for the duration of a call/relay session.
#=============================================================================

wakelock_acquire() {
    [ "$IS_TERMUX" -ne 1 ] && return 0
    command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null || true
}

wakelock_release() {
    [ "$IS_TERMUX" -ne 1 ] && return 0
    command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null || true
}

#=============================================================================
# VOLUME-DOWN DOUBLE-TAP PTT MONITOR (Termux only, experimental)
#=============================================================================

start_vol_monitor() {
    local trigger_file="${1:-$RUNTIME_DIR/run/vol_ptt_trigger_$$}"
    [ "$VOL_PTT" -ne 1 ] && return
    [ "$IS_TERMUX" -ne 1 ] && return
    if ! check_dep jq; then
        log_warn "jq not found — Volume PTT disabled"
        return
    fi
    if ! check_dep termux-volume; then
        log_warn "termux-volume not found — Volume PTT disabled"
        return
    fi

    overwrite_rm "$trigger_file"

    (
        local last_vol=""
        local last_tap=0
        local restore_vol=""

        while [ -f "$CONNECTED_FLAG" ]; do
            local cur_vol
            cur_vol=$(termux-volume 2>/dev/null \
                | jq -r '.[] | select(.stream=="music") | .volume' 2>/dev/null \
                || echo "")

            # Remember the initial volume so we can restore after detection
            if [ -n "$cur_vol" ] && [ -z "$restore_vol" ]; then
                restore_vol="$cur_vol"
            fi

            if [ -n "$cur_vol" ] && [ -n "$last_vol" ]; then
                local drop=$(( last_vol - cur_vol ))

                if [ "$drop" -ge 2 ] 2>/dev/null; then
                    # Rapid double-tap: both presses landed in one poll cycle
                    touch "$trigger_file"
                    last_tap=0
                    # Restore volume for next use
                    if [ -n "$restore_vol" ]; then
                        termux-volume music "$restore_vol" 2>/dev/null || true
                        last_vol="$restore_vol"
                        sleep 0.5
                        continue
                    fi
                elif [ "$drop" -ge 1 ] 2>/dev/null; then
                    # Single press — check if second press follows within 1s
                    local now; now=$(date +%s)
                    if [ "$last_tap" -gt 0 ] && [ $((now - last_tap)) -le 1 ]; then
                        touch "$trigger_file"
                        last_tap=0
                        if [ -n "$restore_vol" ]; then
                            termux-volume music "$restore_vol" 2>/dev/null || true
                            last_vol="$restore_vol"
                            sleep 0.5
                            continue
                        fi
                    else
                        last_tap=$now
                    fi
                fi
            fi
            last_vol="$cur_vol"
            sleep 0.4
        done
    ) &
    VOL_MON_PID=$!
}

# Check if an incoming call arrived on the background listener
check_auto_listen() {
    if [ -f "$AUTO_LISTEN_FLAG" ]; then
        overwrite_rm "$AUTO_LISTEN_FLAG"
        touch "$CONNECTED_FLAG"
        echo -e "\n  ${GREEN}${BOLD}Incoming call detected!${NC}" >&2
        sleep 0.5
        in_call_session "$RECV_PIPE" "$SEND_PIPE" ""
        cleanup_call
        # Restart listener for next call
        start_auto_listener
        return 0
    fi
    return 1
}

# Start listening for incoming calls (manual, blocking)
listen_for_call() {
    if [ -z "$SHARED_SECRET" ]; then
        log_err "No shared secret set! Use option 1 first."
        return 1
    fi

    if [ $DOCKER_MODE -eq 1 ]; then
        wait_for_tor
    else
        start_tor || return 1
    fi

    # Stop auto-listener if running (we'll do manual listen)
    stop_auto_listener

    header "Listening for Calls"

    mkdir -p "$AUDIO_DIR"
    log_info "Bringing up Reticulum listener..."

    overwrite_rm "$RECV_PIPE" "$SEND_PIPE"
    mkfifo "$RECV_PIPE" "$SEND_PIPE"

    local incoming_flag="$RUNTIME_DIR/run/incoming_$$"
    overwrite_rm "$incoming_flag"

    # PLAN §11.2: direct listen goes over Reticulum via rns_bridge.py, same as
    # relay_mode and _dial_remote. The handler is the minimal two-way pipe
    # bridge the old socat SYSTEM one-liner used to be.
    write_rns_bridge || return 1
    overwrite_rm "$ONION_FILE" 2>/dev/null
    "$BRIDGE_PYTHON" -u "$BRIDGE_PY" listen \
        --config-dir "$RNS_CONFIG_DIR" \
        --identity "$RNS_IDENTITY_FILE" \
        --tcp-listen "${RNS_LISTEN_HOST}:${REFLECTOR_PORT}" \
        --hubs "$RNS_HUBS" \
        --autoconnect "$RNS_AUTOCONNECT" \
        --dest-hash-out "$ONION_FILE" \
        --max-line-bytes "$MAX_LINE_BYTES" \
        -- bash -c 'touch "$1"; cat "$2" & cat > "$3"' _ \
             "$incoming_flag" "$SEND_PIPE" "$RECV_PIPE" \
        >"$RUNTIME_DIR/run/bridge_listen_$$.stdout" 2>"$RUNTIME_DIR/run/bridge_listen_$$.stderr" &
    local socat_pid=$!
    save_pid "socat" "$socat_pid"

    local address
    if ! address=$(wait_dest_hash "$ONION_FILE" 30); then
        log_err "rns_bridge did not publish a destination in 30s"
        _bridge_stderr_hint "$RUNTIME_DIR/run/bridge_listen_$$.stderr"
        kill "$socat_pid" 2>/dev/null || true
        overwrite_rm "$RECV_PIPE" "$SEND_PIPE" "$incoming_flag"
        ensure_address || true
        start_auto_listener
        return 1
    fi

    echo -e "  ${GREEN}Your address:${NC} ${BOLD}${WHITE}$address${NC}"
    if [ -n "$RNS_HUBS" ]; then
        echo -e "\n  ${DIM}Give the caller this address. That's all they need: you are${NC}"
        echo -e "  ${DIM}reachable over the Reticulum backbone, so no port has to be${NC}"
        echo -e "  ${DIM}open and your IP never has to be shared.${NC}"
    else
        local _my_ip; _my_ip=$(_local_ip)
        if [ -n "$_my_ip" ]; then
            echo -e "  ${GREEN}Your host:${NC}    ${BOLD}${WHITE}${_my_ip}:${REFLECTOR_PORT}${NC}"
            echo -e "\n  ${DIM}Direct mode (RNS_HUBS empty): give the caller BOTH your host${NC}"
            echo -e "  ${DIM}and your address, and open ${REFLECTOR_PORT}/tcp to them.${NC}"
        else
            echo -e "  ${YELLOW}Couldn't detect your LAN IP: find it yourself (ip addr / ifconfig)${NC}"
            echo -e "  ${DIM}and give the caller <your-ip>:${REFLECTOR_PORT} plus the address above.${NC}"
        fi
    fi
    echo -e "  ${DIM}[Q] Stop listening  [B] Listen in background${NC}\n"
    log_info "Waiting for incoming connection..."

    while [ ! -f "$incoming_flag" ]; do
        if ! kill -0 "$socat_pid" 2>/dev/null; then
            log_err "Listener stopped unexpectedly"
            overwrite_rm "$RECV_PIPE" "$SEND_PIPE" "$incoming_flag"
            # Restart auto-listener if enabled
            start_auto_listener
            return 1
        fi
        # Read user input with 1-second timeout. Guard against closed stdin
        # (headless container): read hits EOF and returns instantly there,
        # which would spin this loop at full speed instead of pacing it.
        local user_input=""
        if [ ! -t 0 ]; then
            sleep 1
        elif read -r -t 1 user_input 2>/dev/null; then
            case "$user_input" in
                q|Q)
                    # Stop all listening (manual + auto), return to menu
                    kill "$socat_pid" 2>/dev/null || true
                    wait "$socat_pid" 2>/dev/null || true
                    overwrite_rm "$RECV_PIPE" "$SEND_PIPE" "$incoming_flag"
                    stop_auto_listener
                    AUTO_LISTEN=0
                    save_config
                    log_info "Stopped listening."
                    return 0
                    ;;
                b|B)
                    # Move to background: kill manual socat, enable auto-listen
                    kill "$socat_pid" 2>/dev/null || true
                    wait "$socat_pid" 2>/dev/null || true
                    overwrite_rm "$RECV_PIPE" "$SEND_PIPE" "$incoming_flag"
                    AUTO_LISTEN=1
                    save_config
                    start_auto_listener
                    log_ok "Listening in background. Returning to menu."
                    sleep 1
                    return 0
                    ;;
            esac
        fi
    done

    touch "$CONNECTED_FLAG"
    log_ok "Call connected!"
    in_call_session "$RECV_PIPE" "$SEND_PIPE" ""
    cleanup_call

    # Restart auto-listener if enabled
    start_auto_listener
}

# Call a remote Reticulum destination.
# Dial $remote_address over Reticulum and wait for the link to establish.
# Sets DIAL_RESULT to ok|cancelled|timeout|refused. On "ok" rns_bridge.py is left
# running (pid saved as socat_call) with the FIFOs created; the caller must then
# open the pipes and run in_call_session. Reused for both the initial dial and
# reconnects.
DIAL_RESULT=""
_dial_remote() {
    overwrite_rm "$RECV_PIPE" "$SEND_PIPE"
    mkfifo "$RECV_PIPE" "$SEND_PIPE"

    # PLAN §11.3: rns_bridge.py touches --ready-file from its
    # link_established callback, which fires on real Reticulum link
    # establishment rather than on socat setup. Strictly more correct.
    local call_connected_flag="$RUNTIME_DIR/run/call_connected_$$"
    overwrite_rm "$call_connected_flag"

    write_rns_bridge || { DIAL_RESULT="refused"; return; }

    # PLAN §11.2: `socat SOCKS4A … SYSTEM:touch …; cat SEND & cat > RECV`
    # becomes rns_bridge.py connect. The bridge itself does the FIFO
    # plumbing that the SYSTEM shell one-liner used to do.
    # Two ways to reach the relay, and REFLECTOR_HOST decides which. Set, it
    # forces a direct dial at that host: the LAN / airgapped case, where the
    # relay is reachable and no backbone is wanted. Unset, we go over the
    # public backbone via RNS_HUBS, which needs no open port on either end.
    local _transport_args=()
    if [ -n "$REFLECTOR_HOST" ]; then
        _transport_args=(--tcp-connect "${REFLECTOR_HOST}:${REFLECTOR_PORT}")
    elif [ -n "$RNS_HUBS" ]; then
        _transport_args=(--hubs "$RNS_HUBS" --autoconnect "$RNS_AUTOCONNECT")
    else
        log_err "No REFLECTOR_HOST and no RNS_HUBS; nowhere to dial"
        DIAL_RESULT="refused"
        return
    fi
    "$BRIDGE_PYTHON" -u "$BRIDGE_PY" connect \
        --config-dir "$RNS_CONFIG_DIR" \
        --identity "$RNS_IDENTITY_FILE" \
        "${_transport_args[@]}" \
        --destination "$remote_address" \
        --send-pipe "$SEND_PIPE" \
        --recv-pipe "$RECV_PIPE" \
        --ready-file "$call_connected_flag" \
        --path-timeout 30 \
        --link-timeout 20 \
        --max-line-bytes "$MAX_LINE_BYTES" \
        >"$RUNTIME_DIR/run/bridge_dial_$$.stdout" 2>"$RUNTIME_DIR/run/bridge_dial_$$.stderr" &
    local socat_pid=$!
    save_pid "socat_call" "$socat_pid"

    # Wait for the RNS link to establish (up to DIAL_TIMEOUT s), with [Q] cancel.
    local connect_start; connect_start=$(date +%s)
    DIAL_RESULT="timeout"

    while true; do
        if ! kill -0 "$socat_pid" 2>/dev/null; then
            DIAL_RESULT="refused"
            break
        fi
        if [ -f "$call_connected_flag" ]; then
            DIAL_RESULT="ok"
            break
        fi
        local elapsed=$(( $(date +%s) - connect_start ))
        if [ $elapsed -ge "$DIAL_TIMEOUT" ]; then
            DIAL_RESULT="timeout"
            break
        fi
        # Progress: "Connecting... 23s (1/3)"
        local _attempt_label=""
        [ -n "${_DIAL_ATTEMPT_LABEL:-}" ] && _attempt_label=" $_DIAL_ATTEMPT_LABEL"
        echo -ne "\r  ${CYAN}${BOLD}Connecting...${NC} ${DIM}${elapsed}s${_attempt_label}${NC}   " >&2
        local _key=""
        if read -r -t 1 _key 2>/dev/null; then
            case "$_key" in
                q|Q)
                    DIAL_RESULT="cancelled"
                    kill "$socat_pid" 2>/dev/null || true
                    wait "$socat_pid" 2>/dev/null || true
                    break
                    ;;
            esac
        fi
    done

    case "$DIAL_RESULT" in
        ok)       echo -ne "\r  ${GREEN}Connected.${NC}                                  \r" >&2 ;;
        timeout)  echo -e  "\r  ${RED}Timed out after ${DIAL_TIMEOUT}s${NC}                       " >&2 ;;
        refused)  echo -e  "\r  ${RED}Connection refused${NC}                             " >&2 ;;
        *)        echo -ne "\r                                            \r" >&2 ;;
    esac
    overwrite_rm "$call_connected_flag"

    if [ "$DIAL_RESULT" != "ok" ]; then
        kill "$socat_pid" 2>/dev/null || true
        wait "$socat_pid" 2>/dev/null || true
    fi
}

call_remote() {
    if [ -z "$SHARED_SECRET" ]; then
        log_err "No shared secret set! Use option 1 first."
        return 1
    fi

    header "Make a Call"
    if [ -z "${remote_address:-}" ]; then
        echo -ne "  ${BOLD}Enter relay address (32-char hex): ${NC}"
        read -r remote_address
    else
        echo -e "  ${DIM}Calling:${NC} ${remote_address}"
    fi

    if [ -z "$remote_address" ]; then
        log_warn "No address entered"
        return 1
    fi

    # Normalize: strip whitespace, angle brackets (RNS.prettyhexrep format),
    # and any accidental scheme prefix a QR scanner may prepend. Reticulum
    # destination hashes are exactly 32 hex chars -- no suffix like .onion.
    remote_address="${remote_address#http://}"
    remote_address="${remote_address#https://}"
    remote_address="${remote_address//[<>[:space:]]/}"
    remote_address="$(printf '%s' "$remote_address" | tr 'A-F' 'a-f')"

    if [[ ! "$remote_address" =~ ^[0-9a-f]{32}$ ]]; then
        log_err "Invalid relay address: expected 32 hex characters, got '${remote_address}'"
        return 1
    fi

    # Over the backbone the address above is the whole story: RNS_HUBS routes
    # to it wherever it is, so there is no host to ask for. Only the direct
    # LAN fallback needs one, and only when RNS_HUBS has been emptied. Port
    # isn't asked for: it's always REFLECTOR_PORT (4242 by default), same on
    # both ends, and nothing in the menu lets a listener bind to a different
    # one, so there's nothing for the caller to customize either.
    if [ -z "$REFLECTOR_HOST" ] && [ -z "$RNS_HUBS" ]; then
        echo -ne "  ${BOLD}Enter their host (IP or hostname): ${NC}"
        read -r REFLECTOR_HOST
        if [ -z "$REFLECTOR_HOST" ]; then
            log_warn "No host entered"
            return 1
        fi
    fi

    if [ -n "$REFLECTOR_HOST" ]; then
        echo -e "\n  ${DIM}Connecting to ${remote_address} direct via ${REFLECTOR_HOST}:${REFLECTOR_PORT}...${NC}"
    else
        echo -e "\n  ${DIM}Connecting to ${remote_address} over the Reticulum backbone...${NC}"
    fi
    echo -e "  ${DIM}[Q] Cancel${NC}\n"

    mkdir -p "$AUDIO_DIR"

    # Initial dial with retry. Reticulum path discovery can fail when the
    # selected route is degraded; killing the bridge and re-launching forces
    # a fresh path resolution.
    local _dial_attempt=0
    while [ "$_dial_attempt" -lt "$DIAL_ATTEMPTS" ]; do
        _dial_attempt=$((_dial_attempt + 1))
        _DIAL_ATTEMPT_LABEL="(${_dial_attempt}/${DIAL_ATTEMPTS})"
        _dial_remote
        unset _DIAL_ATTEMPT_LABEL

        case "$DIAL_RESULT" in
            ok)        break ;;
            cancelled) break ;;
            timeout|refused)
                cleanup_call
                if [ "$_dial_attempt" -lt "$DIAL_ATTEMPTS" ]; then
                    local _reason="Timed out"
                    [ "$DIAL_RESULT" = "refused" ] && _reason="Refused"
                    echo -e "  ${YELLOW}${_reason}, retrying with fresh route... ($((_dial_attempt + 1))/${DIAL_ATTEMPTS})${NC}" >&2
                    sleep 3
                fi
                ;;
        esac
    done

    if [ "$DIAL_RESULT" != "ok" ]; then
        case "$DIAL_RESULT" in
            cancelled) log_info "Connection cancelled." ;;
            timeout)
                log_err "Could not reach this destination after ${DIAL_ATTEMPTS} attempt(s)."
                log_err "Reticulum path may not be available or the peer may be offline."
                ;;
            refused)
                log_err "Connection refused. Check the destination hash and ensure the"
                log_err "remote is running and listening."
                ;;
        esac
        [ "$DIAL_RESULT" = "cancelled" ] || \
            _bridge_stderr_hint "$RUNTIME_DIR/run/bridge_dial_$$.stderr"
        cleanup_call
        return 1
    fi

    # Connected — run the call. On a detected drop ("lost") re-dial up to
    # RECONNECT_ATTEMPTS times to ride out link hiccups; a deliberate
    # hangup (local [Q] or remote HANGUP) ends cleanly to the menu.
    local reconnects=0
    while true; do
        touch "$CONNECTED_FLAG"
        overwrite_rm "$DROP_REASON_FILE"
        in_call_session "$RECV_PIPE" "$SEND_PIPE" "$remote_address"

        # Why did the session end? Missing marker = unexpected death → treat as lost.
        local reason="lost"
        [ -f "$DROP_REASON_FILE" ] && reason=$(cat "$DROP_REASON_FILE" 2>/dev/null)

        # Tear down this call's transport (kills socat_call, recv_loop; removes pipes;
        # releases the wakelock). The next attempt re-acquires everything cleanly.
        cleanup_call

        if [ "$reason" = "hangup" ]; then
            break
        fi

        # Connection dropped — try to re-establish, counting each dial as one attempt.
        local reconnect_state="exhausted"
        while [ "$reconnects" -lt "$RECONNECT_ATTEMPTS" ]; do
            reconnects=$((reconnects + 1))
            echo -e "\n  ${YELLOW}${BOLD}Reconnecting (${reconnects}/${RECONNECT_ATTEMPTS})...${NC}"
            echo -e "  ${DIM}[Q] Cancel${NC}\n"
            if [ $DOCKER_MODE -eq 0 ] && ! start_tor; then
                log_err "Transport unavailable, cannot reconnect."
                reconnect_state="exhausted"
                break
            fi
            _dial_remote
            case "$DIAL_RESULT" in
                ok)        reconnect_state="ok"; break ;;
                cancelled) cleanup_call; reconnect_state="cancelled"; break ;;
                *)         cleanup_call; echo -e "  ${DIM}Re-dial failed, retrying...${NC}" ;;
            esac
        done

        case "$reconnect_state" in
            ok)        continue ;;  # socat live + pipes ready → re-enter in_call_session
            cancelled) log_info "Reconnect cancelled."; break ;;
            *)
                if [ "$RECONNECT_ATTEMPTS" -gt 0 ]; then
                    log_err "Connection lost — gave up after ${RECONNECT_ATTEMPTS} reconnect attempt(s)."
                else
                    log_err "Connection lost."
                fi
                break
                ;;
        esac
    done

    overwrite_rm "$DROP_REASON_FILE"
}

#=============================================================================
# RELAY MODE — N-CALLER GROUP BRIDGE
#=============================================================================

relay_mode() {
    clear
    header "Relay Mode (Group Bridge)"
    echo -e "  ${DIM}Your device acts as a dumb relay that bridges multiple${NC}"
    echo -e "  ${DIM}callers together. It never decrypts anything — all${NC}"
    echo -e "  ${DIM}callers share a secret between themselves.${NC}"
    echo ""
    echo -e "  ${BOLD}${WHITE}How it works:${NC}"
    echo -e "  ${DIM}• You share your relay address with all participants${NC}"
    echo -e "  ${DIM}• Each caller dials your address (option 5 on their end)${NC}"
    echo -e "  ${DIM}• When anyone sends a message, it is forwarded to all others${NC}"
    echo -e "  ${DIM}• Works naturally with PTT — one person talks at a time${NC}"
    echo ""
    echo -e "  ${BOLD}${WHITE}Confidentiality vs anonymity:${NC}"
    echo -e "  ${DIM}• Reticulum authenticates callers cryptographically${NC}"
    echo -e "  ${DIM}• Reticulum encrypts the client↔relay link${NC}"
    echo -e "  ${DIM}• The shared secret keeps the relay itself deaf to payloads${NC}"
    echo -e "  ${DIM}  (relay forwards ciphertext for which it has no key)${NC}"
    echo ""
    echo -e "  ${YELLOW}Reticulum is NOT onion routing.${NC}"
    echo -e "  ${YELLOW}You (the relay) see each caller's IP address, and the RNS${NC}"
    echo -e "  ${YELLOW}destination hash is announced across the network. If you${NC}"
    echo -e "  ${YELLOW}need caller anonymity, use tor-party-line instead.${NC}"
    echo ""
    echo -e "  ${YELLOW}All callers must use the same shared secret.${NC}"
    echo -e "  ${YELLOW}The relay operator does NOT need a shared secret.${NC}"
    echo ""
    # Skip the confirmation when launched headlessly as `rns-party-line.sh relay`
    # (CLI subcommand); the menu path leaves CMD empty and still confirms.
    if [ "$CMD" != "relay" ]; then
        if ! confirm_yes "  ${BOLD}Start relay? [Y/n]: ${NC}"; then
            return
        fi
    fi

    # PLAN §11.1: Tor bring-up replaced by rns_bridge deployment. The bridge
    # writes DEST_HASH to $ONION_FILE; get_onion() picks it up.
    write_rns_bridge || return 1

    local relay_dir="$RUNTIME_DIR/relay"
    mkdir -p "$relay_dir"
    overwrite_rm "$relay_dir"/* 2>/dev/null

    # Write per-connection handler script
    cat > "$relay_dir/handler.sh" << 'RELAY_HANDLER_EOF'
#!/bin/bash
RELAY_DIR="$1"
IDLE_TIMEOUT="${2:-240}"
MAX_LINE_BYTES="${3:-524288}"
RELAY_WRITE_TIMEOUT="${4:-30}"
RELAY_MAX_MSG_PER_SEC="${5:-15}"
RELAY_MAX_INFLIGHT="${6:-64}"
ID="$$"
OUTFIFO="$RELAY_DIR/out_${ID}.fifo"

mkfifo "$OUTFIFO" 2>/dev/null || exit 1
touch "$RELAY_DIR/client_${ID}"

printf 'RELAY:1\n'

_lock()   { local d="$1.lockd" n=0; while ! mkdir "$d" 2>/dev/null; do n=$((n + 1)); [ "$n" -ge 250 ] && return 0; sleep 0.02; done; }
_unlock() { rmdir "$1.lockd" 2>/dev/null; }
_timeout() {
    if command -v timeout >/dev/null 2>&1; then command timeout "$@"; return; fi
    if command -v gtimeout >/dev/null 2>&1; then command gtimeout "$@"; return; fi
    local d="$1"; shift
    "$@" & local _c=$!
    ( sleep "$d"; kill -TERM "$_c" 2>/dev/null ) & local _k=$!
    wait "$_c" 2>/dev/null; local _rc=$?
    kill -TERM "$_k" 2>/dev/null; wait "$_k" 2>/dev/null
    return "$_rc"
}

declare -A DST_FDS DST_PIDS
_next_fd=10

_ensure_writer() {
    local dest="$1"
    if [ -n "${DST_FDS[$dest]:-}" ] && kill -0 "${DST_PIDS[$dest]:-0}" 2>/dev/null; then
        return 0
    fi
    [ -p "$dest" ] || return 1
    local fd=$_next_fd
    _next_fd=$((_next_fd + 1))
    local pipeR="$RELAY_DIR/fwd_${ID}_$(basename "$dest" .fifo).pipe"
    rm -f "$pipeR"
    mkfifo "$pipeR" 2>/dev/null || return 1
    (
        trap 'exit 0' PIPE TERM
        while IFS= read -r _fw_msg; do
            _lock "${dest%.fifo}.lock"
            _timeout "${RELAY_WRITE_TIMEOUT}" sh -c \
                'printf "%s\n" "$1" > "$2"' - "$_fw_msg" "$dest" 2>/dev/null
            _unlock "${dest%.fifo}.lock"
        done < "$pipeR"
    ) &
    DST_PIDS["$dest"]=$!
    eval "exec ${fd}>\"$pipeR\""
    DST_FDS["$dest"]=$fd
}

_write_to() {
    local dest="$1" msg="$2"
    _ensure_writer "$dest" || return 1
    local fd="${DST_FDS[$dest]}"
    printf '%s\n' "$msg" >&"$fd" 2>/dev/null
}

_close_writers() {
    for _cw_dest in "${!DST_FDS[@]}"; do
        eval "exec ${DST_FDS[$_cw_dest]}>&-" 2>/dev/null
        kill "${DST_PIDS[$_cw_dest]}" 2>/dev/null
        wait "${DST_PIDS[$_cw_dest]}" 2>/dev/null
    done
    rm -f "$RELAY_DIR"/fwd_${ID}_*.pipe
    DST_FDS=()
    DST_PIDS=()
}

broadcast_count() {
    local count=0
    for cf in "$RELAY_DIR"/client_*; do
        [ -f "$cf" ] && count=$((count + 1))
    done
    for f in "$RELAY_DIR"/out_*.fifo; do
        [ -p "$f" ] || continue
        ( _lock "${f%.fifo}.lock"; _timeout "${RELAY_WRITE_TIMEOUT}" sh -c 'printf "GROUP:%s\n" "$1" > "$2"' - "$count" "$f"; _unlock "${f%.fifo}.lock" ) 2>/dev/null &
    done
}

cleanup_handler() {
    exec 3>&- 2>/dev/null
    kill $WR_PID 2>/dev/null
    wait $WR_PID 2>/dev/null
    _close_writers
    if [ -f "$RELAY_DIR/stats_${ID}" ]; then
        read -r _fi _fo < "$RELAY_DIR/stats_${ID}" 2>/dev/null || { _fi=0; _fo=0; }
        (
            _lock "$RELAY_DIR/.stats_lock"
            _ti=0; _to=0
            [ -f "$RELAY_DIR/stats_total" ] && read -r _ti _to < "$RELAY_DIR/stats_total" 2>/dev/null
            echo "$((_ti + ${_fi:-0})) $((_to + ${_fo:-0}))" > "$RELAY_DIR/stats_total"
            _unlock "$RELAY_DIR/.stats_lock"
        )
    fi
    rm -f "$OUTFIFO" "${OUTFIFO%.fifo}.lock" "$RELAY_DIR/client_${ID}" \
          "$RELAY_DIR/stats_${ID}" "$RELAY_DIR"/fwd_${ID}_*.pipe
    broadcast_count
}
trap cleanup_handler EXIT

while IFS= read -r msg; do
    printf '%s\n' "$msg"
done < "$OUTFIFO" &
WR_PID=$!

exec 3>"$OUTFIFO"

sleep 0.3
broadcast_count

BYTES_IN=0
BYTES_OUT=0
RATE_WIN=$SECONDS
RATE_COUNT=0
FWD_PIDS=()
GOT_FIRST_MSG=0
ACTIVE_TIMEOUT="$IDLE_TIMEOUT"

while IFS= read -r -t "$ACTIVE_TIMEOUT" line; do
    BYTES_IN=$((BYTES_IN + ${#line}))
    [ "${#line}" -gt "${MAX_LINE_BYTES}" ] && continue
    local_payload="$line"
    case "$line" in *"|"*) local_payload="${line%|*}"; local_payload="${local_payload#*:}" ;; esac
    case "$local_payload" in
        AUDIO:*|FDAUDIO:*|MSG:*|PING|GROUP:*) ;;
        *) continue ;;
    esac
    if [ "$GOT_FIRST_MSG" -eq 0 ]; then
        GOT_FIRST_MSG=1
        ACTIVE_TIMEOUT=60
    fi
    case "$local_payload" in FDAUDIO:*) ;; *)
        if [ "$SECONDS" -ne "$RATE_WIN" ]; then RATE_WIN=$SECONDS; RATE_COUNT=0; fi
        RATE_COUNT=$((RATE_COUNT + 1))
        [ "$RATE_COUNT" -gt "$RELAY_MAX_MSG_PER_SEC" ] && continue
    ;; esac
    for f in "$RELAY_DIR"/out_*.fifo; do
        [ "$f" = "$OUTFIFO" ] && continue
        [ -p "$f" ] || continue
        _write_to "$f" "$line"
        BYTES_OUT=$((BYTES_OUT + ${#line}))
    done
    echo "$BYTES_IN $BYTES_OUT" > "$RELAY_DIR/stats_${ID}"
done
RELAY_HANDLER_EOF
    chmod +x "$relay_dir/handler.sh"

    # PLAN §11.2 / §17: rns_bridge.py listen bridges RNS Links to
    # handler.sh. Same handler, same argv as the socat-based transports,
    # but routed over Reticulum. --dest-hash-out lets the shell learn our
    # destination hash without parsing bridge stdout.
    overwrite_rm "$ONION_FILE" 2>/dev/null
    "$BRIDGE_PYTHON" -u "$BRIDGE_PY" listen \
        --config-dir "$RNS_CONFIG_DIR" \
        --identity "$RNS_IDENTITY_FILE" \
        --tcp-listen "${RNS_LISTEN_HOST}:${REFLECTOR_PORT}" \
        --hubs "$RNS_HUBS" \
        --autoconnect "$RNS_AUTOCONNECT" \
        --dest-hash-out "$ONION_FILE" \
        --max-line-bytes "$MAX_LINE_BYTES" \
        -- bash "$relay_dir/handler.sh" "$relay_dir" \
             "$RELAY_IDLE_TIMEOUT" "$MAX_LINE_BYTES" \
             "$RELAY_WRITE_TIMEOUT" "$RELAY_MAX_MSG_PER_SEC" "$RELAY_MAX_INFLIGHT" \
        >"$relay_dir/bridge.stdout" 2>"$relay_dir/bridge.stderr" &
    local socat_pid=$!

    # Wait for the bridge to publish its destination hash.
    local address
    if ! address=$(wait_dest_hash "$ONION_FILE" 30); then
        log_err "rns_bridge did not publish a destination in 30s"
        _bridge_stderr_hint "$relay_dir/bridge.stderr"
        kill "$socat_pid" 2>/dev/null || true
        ensure_address || true
        return 1
    fi
    echo ""
    echo -e "  ${GREEN}Relay address:${NC} ${BOLD}${WHITE}$address${NC}"
    echo -e "  ${DIM}Share this address with all callers.${NC}"
    echo ""

    # Keep a phone-hosted relay awake through a locked screen (no-op off Termux)
    wakelock_acquire

    log_ok "Relay active — waiting for callers..."
    echo -e "  ${DIM}[Q] Stop relay${NC}\n"

    local start_time; start_time=$(date +%s)

    local _bc_tick=0
    while kill -0 "$socat_pid" 2>/dev/null; do
        local count=0
        for _cf in "$relay_dir"/client_*; do
            [ -f "$_cf" ] && count=$((count + 1))
        done
        local uptime; uptime=$(( $(date +%s) - start_time ))
        local mins=$(( uptime / 60 ))
        local secs=$(( uptime % 60 ))
        # Sum data stats from all handlers + accumulated totals from disconnected callers
        local total_in=0 total_out=0
        for _sf in "$relay_dir"/stats_*; do
            [ -f "$_sf" ] || continue
            local _si _so
            read -r _si _so < "$_sf" 2>/dev/null || continue
            total_in=$((total_in + ${_si:-0}))
            total_out=$((total_out + ${_so:-0}))
        done
        local in_display out_display
        in_display="$(_format_bytes "$total_in")"
        out_display="$(_format_bytes "$total_out")"
        printf "\r  ${BOLD}Callers:${NC} ${GREEN}%-3s${NC} ${DIM}Uptime: %dm %02ds${NC}  ${DIM}In:${NC} ${WHITE}%-8s${NC} ${DIM}Out:${NC} ${WHITE}%-8s${NC}   " \
            "$count" "$mins" "$secs" "$in_display" "$out_display" 2>/dev/null

        # Periodic GROUP:N broadcast to all clients (~every 10 seconds)
        _bc_tick=$((_bc_tick + 1))
        if [ $((_bc_tick % 5)) -eq 0 ] && [ "$count" -gt 0 ]; then
            for _bf in "$relay_dir"/out_*.fifo; do
                [ -p "$_bf" ] || continue
                printf 'GROUP:%s\n' "$count" > "$_bf" 2>/dev/null &
            done
        fi

        # read -t only paces the loop when stdin is a live TTY. Under
        # `docker compose up -d` (stdin_open: false) stdin is closed, so
        # read hits EOF and returns instantly instead of waiting — without
        # this guard that spins the loop at full speed (100%+ CPU, log spam).
        local input=""
        if [ -t 0 ]; then
            if read -r -t 2 input 2>/dev/null; then
                case "$input" in
                    q|Q) break ;;
                esac
            fi
        else
            sleep 2
        fi
    done

    # Cleanup
    echo ""
    log_info "Stopping relay..."
    kill "$socat_pid" 2>/dev/null
    # Kill forked handler processes
    pkill -P "$socat_pid" 2>/dev/null
    wait "$socat_pid" 2>/dev/null
    # Remove any remaining FIFOs and markers
    overwrite_rm -r "$relay_dir"
    wakelock_release
    log_ok "Relay stopped"
    sleep 1
}

#=============================================================================
# IN-CALL SESSION — PTT VOICE LOOP
#=============================================================================

# Draw the call header (reusable for redraw after settings)
# All output in this function (and the PTT loop) goes to >&2 (stderr).
# Stdout is reserved for function return values captured by $(...); writing
# display output there would corrupt those captures. The PTT loop reads
# keystrokes via dd from stdin, so neither stdin nor stdout are free for display.
draw_call_header() {
    local _remote="${1:-}"
    local _rcipher="${2:-}"
    clear >&2
    # Row counter for ANSI cursor positioning (clear sets cursor to row 1)
    local _r=1

    if [ -n "$_remote" ]; then
        echo -e "\n${BOLD}${BG_GREEN}${WHITE} CALL CONNECTED ${NC} ${CYAN}${_remote}${NC}\n" >&2
    else
        echo -e "\n${BOLD}${BG_GREEN}${WHITE} CALL CONNECTED ${NC}\n" >&2
    fi
    _r=4  # \n(row1) + header(row2) + \n(row3) + echo-newline → cursor at row 4

    # Cipher info
    CIPHER_ROW=$_r
    local cipher_upper rcipher_upper
    cipher_upper="$(to_upper "$CIPHER")"
    if [ -f "$RUNTIME_DIR/run/relay_mode_$$" ]; then
        # Relay mode — no remote cipher, show relay indicator
        echo -e "  ${GREEN}●${NC} Local cipher:  ${WHITE}${cipher_upper}${NC}" >&2
        echo -e "  ${CYAN}●${NC} Mode:          ${BOLD}${WHITE}RELAY${NC} ${DIM}(group call)${NC}" >&2
    elif [ -n "$_rcipher" ]; then
        rcipher_upper="$(to_upper "$_rcipher")"
        if [ "$_rcipher" = "$CIPHER" ]; then
            echo -e "  ${GREEN}●${NC} Local cipher:  ${WHITE}${cipher_upper}${NC}" >&2
            echo -e "  ${GREEN}●${NC} Remote cipher: ${WHITE}${rcipher_upper}${NC}" >&2
        else
            echo -e "  ${RED}●${NC} Local cipher:  ${WHITE}${cipher_upper}${NC}" >&2
            echo -e "  ${RED}●${NC} Remote cipher: ${WHITE}${rcipher_upper}${NC}" >&2
        fi
    else
        echo -e "  ${GREEN}●${NC} Local cipher:  ${WHITE}${cipher_upper}${NC}" >&2
        echo -e "  ${DIM}●${NC} Remote cipher: ${DIM}waiting...${NC}" >&2
    fi
    _r=$((_r + 2))

    echo "" >&2; _r=$((_r + 1))

    # Static placeholders — updated in-place via ANSI positioning
    echo -e "  ${DIM}Last sent:  --${NC}" >&2
    SENT_INFO_ROW=$_r
    _r=$((_r + 1))

    echo -e "  ${DIM}Last recv:  --${NC}" >&2
    RECV_INFO_ROW=$_r
    _r=$((_r + 1))

    if [ -f "$RUNTIME_DIR/run/relay_mode_$$" ]; then
        local _cached_gc=""
        [ -f "$RUNTIME_DIR/run/group_count_$$" ] && _cached_gc="$(<"$RUNTIME_DIR/run/group_count_$$")"
        if [ -n "$_cached_gc" ]; then
            echo -e "  ${DIM}Group:      ${NC}${WHITE}${_cached_gc} callers${NC}" >&2
        else
            echo -e "  ${DIM}Group:      ${NC}${WHITE}connecting...${NC}" >&2
        fi
    else
        echo -e "  ${DIM}Remote:     ${NC}${GREEN}Idle${NC}" >&2
    fi
    REMOTE_STATUS_ROW=$_r
    _r=$((_r + 1))

    echo "" >&2; _r=$((_r + 1))

    # Static status bar
    if ptt_toggle_mode; then
        echo -ne "  ${GREEN}${BOLD} Ready ${NC} ${DIM}[SPACE]=Talk [T]=Chat [S]=Settings [Q]=Hang up${NC}   " >&2
    else
        echo -ne "  ${GREEN}${BOLD} Ready ${NC} ${DIM}[SPACE]=Hold to Talk [T]=Chat [S]=Settings [Q]=Hang up${NC}   " >&2
    fi
    STATUS_ROW=$_r

    echo "" >&2
    echo "" >&2
}

# Full-duplex call session. Launched from in_call_session when FULL_DUPLEX=1.
# Reads local variables from the calling scope (bash dynamic scoping):
#   recv_pipe, send_pipe, known_remote, relay_flag_file,
#   remote_id_file, remote_cipher_file, vol_trigger_file
_fullduplex_session() {
    local fd_ctrl="$RUNTIME_DIR/run/fd_ctrl_$$"
    rm -f "$fd_ctrl"; mkfifo "$fd_ctrl"
    exec 8<> "$fd_ctrl"

    local _fd_stderr="$RUNTIME_DIR/run/fd_engine_$$.stderr"
    exec 3<&-  # drop shell's write-ref so engine sees EOF on remote disconnect
    FD_SECRET="$SHARED_SECRET" \
    python3 "$FD_ENGINE_PY" "$recv_pipe" "$send_pipe" \
        "$SAMPLE_RATE" "$((OPUS_BITRATE * 1000))" \
        "$START_MUTED" \
        > "$fd_ctrl" 2>"$_fd_stderr" &
    local fd_engine_pid=$!
    save_pid "fd_engine" "$fd_engine_pid"

    # Background: read protocol lines forwarded by the engine (everything
    # except FDAUDIO: which the engine handles internally).
    (
        trap 'rm -f "$CONNECTED_FLAG"' EXIT
        while IFS= read -r -t "$CLIENT_TIMEOUT" line <&8; do
            if [[ "$line" == GROUP:* ]]; then
                if [ ! -f "$relay_flag_file" ]; then touch "$relay_flag_file"; fi
                local _gcount="${line#GROUP:}"
                echo "$_gcount" > "$RUNTIME_DIR/run/group_count_$$" 2>/dev/null || true
                [ -f "$MENU_FLAG" ] || status_at "$REMOTE_STATUS_ROW" \
                    '  \033[2mGroup:      \033[0m\033[1;37m%s callers\033[0m' "$_gcount"
                continue
            fi
            [[ "$line" == RELAY:* ]] && { [ ! -f "$relay_flag_file" ] && touch "$relay_flag_file"; continue; }

            line=$(proto_verify "$line") || continue
            case "$line" in
                PING|PTT_START|PTT_STOP) ;;
                ID:*)    echo "${line#ID:}" > "$remote_id_file" 2>/dev/null || true ;;
                CIPHER:*) echo "${line#CIPHER:}" > "$remote_cipher_file" 2>/dev/null || true ;;
                MODE:*)  echo "${line#MODE:}" > "$RUNTIME_DIR/run/remote_mode_$$" 2>/dev/null || true ;;
                MSG:*)
                    local msg_b64="${line#MSG:}"
                    [ "${#msg_b64}" -gt "${MAX_MSG_B64}" ] && continue
                    local _mid; _mid=$(uid)
                    local msg_enc="$AUDIO_DIR/msg_enc_${_mid}.tmp"
                    local msg_dec="$AUDIO_DIR/msg_dec_${_mid}.tmp"
                    base64 -d <<< "$msg_b64" > "$msg_enc" 2>/dev/null || true
                    if [ -s "$msg_enc" ] && decrypt_file "$msg_enc" "$msg_dec" 2>/dev/null; then
                        local msg_text; msg_text=$(<"$msg_dec")
                        printf '\r\n  %b%b[MSG]%b %b%s%b\r\n' \
                            "$MAGENTA" "$BOLD" "$NC" "$WHITE" "$msg_text" "$NC" >&2
                    fi
                    overwrite_rm "$msg_enc" "$msg_dec"
                    ;;
                AUDIO:*)
                    local b64_data="${line#AUDIO:}"
                    [ "${#b64_data}" -gt "${MAX_AUDIO_B64}" ] && continue
                    local _rid; _rid=$(uid)
                    local enc_file="$AUDIO_DIR/recv_enc_${_rid}.tmp"
                    local dec_file="$AUDIO_DIR/recv_dec_${_rid}.tmp"
                    base64 -d <<< "$b64_data" > "$enc_file" 2>/dev/null || true
                    if [ -s "$enc_file" ] && decrypt_file "$enc_file" "$dec_file" 2>/dev/null; then
                        if [ "${PLAY_QUEUE_FD:-0}" -ne 0 ]; then
                            local _pq_file="$AUDIO_DIR/play_$(uid).opus"
                            mv "$dec_file" "$_pq_file" 2>/dev/null && \
                                printf '%s\n' "$_pq_file" >&7 || \
                                overwrite_rm "$_pq_file"
                            dec_file=""
                        else
                            play_chunk "$dec_file" 2>/dev/null || true
                        fi
                    fi
                    overwrite_rm "$enc_file" "$dec_file"
                    ;;
                HANGUP)
                    if [ -f "$relay_flag_file" ]; then continue; fi
                    echo -e "\r\n\r\n  ${YELLOW}${BOLD}Remote party hung up.${NC}" >&2
                    echo "hangup" > "$DROP_REASON_FILE" 2>/dev/null || true
                    rm -f "$CONNECTED_FLAG"
                    break
                    ;;
            esac
        done
    ) &
    local recv_pid=$!
    save_pid "recv_loop" "$recv_pid"

    # Status bar
    ORIGINAL_STTY=$(stty -g)
    stty raw -echo -icanon min 0 time 1
    local _fd_mute_flag="$RUNTIME_DIR/run/fd_muted_$$"
    rm -f "$_fd_mute_flag"

    printf '\0337\033[%d;1H\033[K' "$STATUS_ROW" >&2
    if [ "$START_MUTED" -eq 1 ]; then
        touch "$_fd_mute_flag"
        printf '  \033[1;33m● MUTED \033[0m \033[2m[M]=Unmute [T]=Chat [S]=Settings [Q]=Hang up\033[0m   ' >&2
    else
        printf '  \033[1;32m● LIVE \033[0m \033[2m[M]=Mute [T]=Chat [S]=Settings [Q]=Hang up\033[0m   ' >&2
    fi
    printf '\0338' >&2

    while [ -f "$CONNECTED_FLAG" ]; do
        local key=""
        if [ -f "$vol_trigger_file" ]; then
            overwrite_rm "$vol_trigger_file"
            key="m"
        else
            key=$(dd bs=1 count=1 2>/dev/null) || true
        fi

        case "$key" in
            q|Q)
                echo -e "\r\n${YELLOW}Hanging up...${NC}" >&2
                proto_send "HANGUP"
                echo "hangup" > "$DROP_REASON_FILE" 2>/dev/null || true
                overwrite_rm "$CONNECTED_FLAG"
                break
                ;;
            m|M)
                kill -USR1 "$fd_engine_pid" 2>/dev/null || true
                if [ -f "$_fd_mute_flag" ]; then
                    rm -f "$_fd_mute_flag"
                    printf '\0337\033[%d;1H\033[K' "$STATUS_ROW" >&2
                    printf '  \033[1;32m● LIVE \033[0m \033[2m[M]=Mute [T]=Chat [S]=Settings [Q]=Hang up\033[0m   ' >&2
                    printf '\0338' >&2
                else
                    touch "$_fd_mute_flag"
                    printf '\0337\033[%d;1H\033[K' "$STATUS_ROW" >&2
                    printf '  \033[1;33m● MUTED \033[0m \033[2m[M]=Unmute [T]=Chat [S]=Settings [Q]=Hang up\033[0m   ' >&2
                    printf '\0338' >&2
                fi
                ;;
            t|T)
                touch "$MENU_FLAG"
                stty "$ORIGINAL_STTY" 2>/dev/null || stty sane
                echo "" >&2
                echo -ne "  ${CYAN}${BOLD}MSG>${NC} " >&2
                local chat_msg="" _chat_max=$(( MAX_MSG_B64 / 2 ))
                [ "$_chat_max" -ge 1 ] || _chat_max=1
                read -r -e -n "$_chat_max" chat_msg
                if [ -n "$chat_msg" ]; then
                    local _cid; _cid=$(uid)
                    local chat_plain="$AUDIO_DIR/chat_${_cid}.tmp"
                    local chat_enc="$AUDIO_DIR/chat_enc_${_cid}.tmp"
                    echo -n "$chat_msg" > "$chat_plain"
                    encrypt_file "$chat_plain" "$chat_enc" 2>/dev/null
                    if [ -s "$chat_enc" ]; then
                        local chat_b64
                        chat_b64=$(base64 < "$chat_enc" | tr -d '\n')
                        proto_send "MSG:${chat_b64}"
                        echo -e "  ${DIM}[you] ${chat_msg}${NC}" >&2
                    fi
                    overwrite_rm "$chat_plain" "$chat_enc"
                fi
                stty raw -echo -icanon min 0 time 1
                read -r -t 0.1 -n 100000 _ 2>/dev/null || true
                rm -f "$MENU_FLAG"
                printf '\0337\033[%d;1H\033[K' "$STATUS_ROW" >&2
                printf '  \033[1;32m● LIVE \033[0m \033[2m[M]=Mute [T]=Chat [S]=Settings [Q]=Hang up\033[0m   ' >&2
                printf '\0338' >&2
                ;;
            s|S)
                touch "$MENU_FLAG"
                stty "$ORIGINAL_STTY" 2>/dev/null || stty sane
                read -r -t 0.1 -n 10000 2>/dev/null || true
                settings_menu
                local _rd="" _rc=""
                [ -f "$remote_id_file" ] && _rd="$(<"$remote_id_file")"
                [ -z "$_rd" ] && _rd="$known_remote"
                [ -f "$remote_cipher_file" ] && _rc="$(<"$remote_cipher_file")"
                draw_call_header "$_rd" "$_rc"
                rm -f "$MENU_FLAG"
                stty raw -echo -icanon min 0 time 1
                printf '\0337\033[%d;1H\033[K' "$STATUS_ROW" >&2
                printf '  \033[1;32m● LIVE \033[0m \033[2m[M]=Mute [T]=Chat [S]=Settings [Q]=Hang up\033[0m   ' >&2
                printf '\0338' >&2
                ;;
        esac
    done

    kill "$fd_engine_pid" 2>/dev/null || true
    wait "$fd_engine_pid" 2>/dev/null || true
    exec 8<&-
    rm -f "$fd_ctrl" "$_fd_mute_flag" "$_fd_stderr"
}

in_call_session() {
    local recv_pipe="$1"
    local send_pipe="$2"
    local known_remote="${3:-}"

    CALL_ACTIVE=1
    overwrite_rm "$PTT_FLAG"
    mkdir -p "$AUDIO_DIR"

    # Hold a partial wakelock so a locked Android screen can't deep-sleep the CPU
    # and freeze the heartbeat / receive loop. Released in cleanup_call.
    wakelock_acquire

    # Start volume-down double-tap monitor (Termux only)
    VOL_MON_PID=""
    local vol_trigger_file="$RUNTIME_DIR/run/vol_ptt_trigger_$$"
    overwrite_rm "$vol_trigger_file"
    start_vol_monitor "$vol_trigger_file"

    # Write cipher to runtime file so subshells can track changes
    echo "$CIPHER" > "$CIPHER_RUNTIME_FILE"
    echo "$HMAC_AUTH" > "$HMAC_RUNTIME_FILE"
    : > "$NONCE_LOG_FILE"

    # Open persistent file descriptors for the pipes.
    # Use <> (read-write) on the recv pipe so the open never blocks waiting for a
    # writer — on Linux a FIFO opened O_RDONLY blocks until a writer appears, which
    # would hang indefinitely if socat died between touching the connect flag and
    # opening its own write-end. Read-write mode opens immediately; we still only
    # read from fd 3 in practice.
    exec 3<> "$recv_pipe"  # fd 3 = read from remote
    exec 4>  "$send_pipe"  # fd 4 = write to remote

    # Termux play worker — must be started before the receive loop subshell is
    # spawned so fd 7 is inherited.
    PLAY_WORKER_PID=""
    PLAY_QUEUE_FD=0
    PLAY_QUEUE_FIFO=""
    start_play_worker

    # Send our address and cipher for handshake
    local my_address
    my_address=$(get_onion)
    if [ -n "$my_address" ]; then
        proto_send "ID:${my_address}"
    fi
    proto_send "CIPHER:${CIPHER}"
    [ "$FULL_DUPLEX" -eq 1 ] && proto_send "MODE:fullduplex"

    # Heartbeat: send a PING every HEARTBEAT_INTERVAL seconds so the relay knows we
    # are still alive even during long silences. Without this, a relay handler can't
    # tell a quiet-but-connected caller from one that roamed/dropped, and stale callers
    # keep inflating the count and receiving the conversation. The relay forwards PING
    # and receivers ignore it silently. Torn down in cleanup_call.
    HEARTBEAT_PID=""
    (
        while [ -f "$CONNECTED_FLAG" ]; do
            sleep "$HEARTBEAT_INTERVAL"
            [ -f "$CONNECTED_FLAG" ] || break
            [ -f "$PTT_FLAG" ] && continue
            proto_send "PING"
        done
    ) &
    HEARTBEAT_PID=$!

    # Remote address and cipher (populated by handshake / receive loop)
    local remote_id_file="$RUNTIME_DIR/run/remote_id_$$"
    local remote_cipher_file="$RUNTIME_DIR/run/remote_cipher_$$"
    local relay_flag_file="$RUNTIME_DIR/run/relay_mode_$$"
    overwrite_rm "$remote_id_file" "$remote_cipher_file" "$relay_flag_file"

    # If we don't know the remote address yet (listener), wait briefly for handshake
    local remote_display="$known_remote"
    local remote_cipher=""
    if [ -z "$remote_display" ]; then
        # Read first line — could be RELAY:, ID:, or CIPHER:
        local first_line=""
        if read -r -t 3 first_line <&3 2>/dev/null; then
            # Check raw line for relay greeting (not HMAC-signed)
            if [[ "$first_line" == RELAY:* ]]; then
                touch "$relay_flag_file"
                remote_display="RELAY (group)"
                echo "$remote_display" > "$remote_id_file"
            else
                first_line=$(proto_verify "$first_line") || first_line=""
                if [[ "$first_line" == ID:* ]]; then
                    remote_display="${first_line#ID:}"
                    echo "$remote_display" > "$remote_id_file"
                elif [[ "$first_line" == CIPHER:* ]]; then
                    remote_cipher="${first_line#CIPHER:}"
                fi
            fi
        fi
    else
        # We know the remote (caller side) — check for RELAY: greeting
        local peek_line=""
        if read -r -t 2 peek_line <&3 2>/dev/null; then
            # Check raw line for relay greeting (not HMAC-signed)
            if [[ "$peek_line" == RELAY:* ]]; then
                touch "$relay_flag_file"
                remote_display="RELAY (group)"
            else
                peek_line=$(proto_verify "$peek_line") || peek_line=""
                if [[ "$peek_line" == CIPHER:* ]]; then
                    remote_cipher="${peek_line#CIPHER:}"
                fi
            fi
        fi
    fi

    # Try to read CIPHER: line (skip in relay mode — no cipher exchange)
    if [ -z "$remote_cipher" ] && [ ! -f "$relay_flag_file" ]; then
        local cline=""
        if read -r -t 1 cline <&3 2>/dev/null; then
            cline=$(proto_verify "$cline") || cline=""
            if [[ "$cline" == CIPHER:* ]]; then
                remote_cipher="${cline#CIPHER:}"
            fi
        fi
    fi

    # Save remote cipher for later redraws
    if [ -n "$remote_cipher" ]; then
        echo "$remote_cipher" > "$remote_cipher_file"
    fi

    # Draw call header
    draw_call_header "$remote_display" "$remote_cipher"

    # Full-duplex: launch the Python audio engine instead of the PTT loop.
    # The engine reads recv_pipe (FDAUDIO: frames) and forwards non-audio
    # protocol lines to bash via a control pipe.
    if [ "$FULL_DUPLEX" -eq 1 ]; then
        if ! command -v python3 >/dev/null 2>&1; then
            echo -e "\n${RED}${BOLD}  Full-duplex requires python3.${NC}"
            echo -e "  ${DIM}Install it with the 'Install dependencies' menu option.${NC}\n"
            return
        fi
        if write_fullduplex_engine; then
            _fullduplex_session
            rm -f "$MENU_FLAG"
            echo -e "\n${BOLD}${RED} CALL ENDED ${NC}\n"
            return
        else
            log_err "Could not prepare full-duplex engine; falling back to PTT."
        fi
    fi

    # Start receive handler in background
    # Protocol: ID:<address>, PTT_START, PTT_STOP, PING,
    #           or "AUDIO:<base64_encoded_encrypted_opus>"
    (
        # If this subshell dies for any reason (SIGPIPE from a closed PTY,
        # set -e triggered by a failed write, etc.) remove CONNECTED_FLAG so
        # the PTT loop in the parent shell knows the call is over.
        trap 'rm -f "$CONNECTED_FLAG"' EXIT
        while [ -f "$CONNECTED_FLAG" ]; do
            local line=""
            # Timed read: a live connection always feeds us something well within
            # CLIENT_TIMEOUT — the relay beacons GROUP:N every ~10s and forwards peer
            # PINGs; a direct peer PINGs every HEARTBEAT_INTERVAL. If nothing arrives in
            # CLIENT_TIMEOUT seconds the relay/peer dropped us (or socat closed) and the
            # read returns non-zero, falling through to the "Connection lost" branch.
            if read -r -t "$CLIENT_TIMEOUT" line <&3 2>/dev/null; then
                # Handle relay protocol messages BEFORE proto_verify — the relay
                # operator never sets a shared secret, so these are always unsigned.
                if [[ "$line" == GROUP:* ]]; then
                    if [ ! -f "$relay_flag_file" ]; then
                        touch "$relay_flag_file"
                    fi
                    local _gcount="${line#GROUP:}"
                    # Cache count for header redraws (e.g., after mid-call settings)
                    echo "$_gcount" > "$RUNTIME_DIR/run/group_count_$$" || true
                    # Skip the in-place row update while a mid-call menu/input owns the
                    # screen — draw_call_header redraws it (from the cache above) on return.
                    [ -f "$MENU_FLAG" ] || status_at "$REMOTE_STATUS_ROW" '  \033[2mGroup:      \033[0m\033[1;37m%s callers\033[0m' "$_gcount"
                    continue
                fi
                if [[ "$line" == RELAY:* ]]; then  # same — unsigned relay greeting
                    [ ! -f "$relay_flag_file" ] && touch "$relay_flag_file"
                    continue
                fi
                line=$(proto_verify "$line") || continue
                case "$line" in
                    PTT_START)
                        [ -f "$MENU_FLAG" ] || status_at "$REMOTE_STATUS_ROW" '  \033[2mRemote:     \033[0m\033[1;31m● Recording\033[0m'

                        ;;
                    PTT_STOP)
                        [ -f "$MENU_FLAG" ] || status_at "$REMOTE_STATUS_ROW" '  \033[2mRemote:     \033[0m\033[1;32mIdle\033[0m'
                        ;;
                    PING)
                        # silent — no display update
                        ;;
                    ID:*)
                        # Caller ID received (save but don't print — already in header)
                        local remote_addr="${line#ID:}"
                        echo "$remote_addr" > "$remote_id_file" || true
                        ;;
                    CIPHER:*)
                        # Remote side sent/changed their cipher — save and update display
                        local rc="${line#CIPHER:}"
                        echo "$rc" > "$remote_cipher_file" 2>/dev/null || true
                        # Read current local cipher (runtime override or config)
                        local _cur_cipher; _cur_cipher=$(_active_cipher)
                        local _cu="$(to_upper "$_cur_cipher")"
                        local _ru="$(to_upper "$rc")"
                        # Update cipher lines in-place using ANSI cursor positioning (rows 4-5)
                        local _dot_color
                        if [ "$rc" = "$_cur_cipher" ]; then
                            _dot_color="$GREEN"
                        else
                            _dot_color="$RED"
                        fi
                        # Skip the in-place cipher-row update while a menu owns the screen;
                        # the saved remote_cipher_file drives the redraw on return.
                        if [ ! -f "$MENU_FLAG" ]; then
                            printf '\0337' >&2
                            printf '\033[%d;1H\033[K' "$CIPHER_ROW" >&2
                            printf '  %b●%b Local cipher:  %b%s%b\r\n' "$_dot_color" "$NC" "$WHITE" "$_cu" "$NC" >&2
                            printf '\033[K' >&2
                            printf '  %b●%b Remote cipher: %b%s%b' "$_dot_color" "$NC" "$WHITE" "$_ru" "$NC" >&2
                            printf '\0338' >&2
                        fi
                        ;;
                    MSG:*)
                        # Encrypted text message received
                        local msg_b64="${line#MSG:}"
                        [ "${#msg_b64}" -gt "${MAX_MSG_B64}" ] && continue
                        local _mid; _mid=$(uid)
                        local msg_enc="$AUDIO_DIR/msg_enc_${_mid}.tmp"
                        local msg_dec="$AUDIO_DIR/msg_dec_${_mid}.tmp"
                        base64 -d <<< "$msg_b64" > "$msg_enc" 2>/dev/null || true
                        if [ -s "$msg_enc" ]; then
                            if decrypt_file "$msg_enc" "$msg_dec" 2>/dev/null; then
                                local msg_text
                                msg_text=$(<"$msg_dec")
                                printf '\r\n  %b%b[MSG]%b %b%s%b\r\n' "$MAGENTA" "$BOLD" "$NC" "$WHITE" "$msg_text" "$NC" >&2
                            fi
                        fi
                        overwrite_rm "$msg_enc" "$msg_dec"
                        ;;
                    AUDIO:*)
                        # Extract base64 data, decode, decrypt, play
                        local b64_data="${line#AUDIO:}"
                        [ "${#b64_data}" -gt "${MAX_AUDIO_B64}" ] && continue
                        local _rid; _rid=$(uid)
                        local enc_file="$AUDIO_DIR/recv_enc_${_rid}.tmp"
                        local dec_file="$AUDIO_DIR/recv_dec_${_rid}.tmp"

                        base64 -d <<< "$b64_data" > "$enc_file" 2>/dev/null || true
                        if [ -s "$enc_file" ]; then
                            if decrypt_file "$enc_file" "$dec_file" 2>/dev/null; then
                                local _recv_info; _recv_info="$(_format_kb "$(file_size "$enc_file")")KB"
                                # Update static "Last recv" row via ANSI positioning
                                # (skipped while a mid-call menu/input owns the screen).
                                if [ ! -f "$MENU_FLAG" ]; then
                                    printf '\0337' >&2
                                    printf '\033[%d;1H\033[K' "$RECV_INFO_ROW" >&2
                                    printf '  \033[2mLast recv:  \033[0m\033[1;37m%s\033[0m' "$_recv_info" >&2
                                    printf '\033[%d;1H\033[K' "$REMOTE_STATUS_ROW" >&2
                                    printf '  \033[2mRemote:     \033[0m\033[1;32mIdle\033[0m' >&2
                                    printf '\0338' >&2
                                fi

                                # PLAN §20.4: hand the decrypted opus off to
                                # the play worker (queue on fd 7). Ownership
                                # of dec_file transfers to the worker, which
                                # calls play_chunk then overwrite_rm's it.
                                # Fallback to synchronous play only if the
                                # queue never started (start_play_worker
                                # failed to mkfifo).
                                if [ "${PLAY_QUEUE_FD:-0}" -ne 0 ]; then
                                    local _pq_file="$AUDIO_DIR/play_$(uid).opus"
                                    mv "$dec_file" "$_pq_file" 2>/dev/null && \
                                        printf '%s\n' "$_pq_file" >&7 || \
                                        overwrite_rm "$_pq_file"
                                    dec_file=""  # worker owns it now
                                else
                                    play_chunk "$dec_file" 2>/dev/null || true
                                fi
                            fi
                        fi
                        overwrite_rm "$enc_file" "$dec_file"
                        ;;
                    FDAUDIO:*)
                        # Full-duplex frame from a peer in FD mode. In PTT
                        # receive mode, each frame is a tiny opus packet
                        # encrypted with per-frame crypto (not openssl enc).
                        # Decode inline via the same Python engine. Graceful
                        # degradation: no jitter buffer, each frame plays
                        # individually.
                        local _fdb64="${line#FDAUDIO:}"
                        local _fdraw
                        _fdraw=$(base64 -d <<< "$_fdb64" 2>/dev/null) || continue
                        # Per-frame crypto uses Python; for mixed-mode PTT
                        # receive, skip (cannot decrypt without the engine).
                        # The user hears silence for FD frames; AUDIO: chunks
                        # from PTT peers still work normally.
                        ;;
                    MODE:*)
                        local _rmode="${line#MODE:}"
                        echo "$_rmode" > "$RUNTIME_DIR/run/remote_mode_$$" 2>/dev/null || true
                        ;;
                    HANGUP)
                        # In relay mode, ignore HANGUP (others may still be connected)
                        if [ -f "$relay_flag_file" ]; then
                            continue
                        fi
                        # Direct call — remote party hung up deliberately: don't reconnect
                        echo -e "\r\n\r\n  ${YELLOW}${BOLD}Remote party hung up.${NC}" >&2
                        echo "hangup" > "$DROP_REASON_FILE" 2>/dev/null || true
                        rm -f "$CONNECTED_FLAG"
                        break
                        ;;
                esac
            else
                # Timed read expired or pipe closed — relay/peer stopped feeding us.
                # Mark "lost" so the dialing side can auto-reconnect.
                echo -e "\r\n\r\n  ${RED}${BOLD}Connection lost.${NC}" >&2
                echo "lost" > "$DROP_REASON_FILE" 2>/dev/null || true
                rm -f "$CONNECTED_FLAG"
                break
            fi
        done
    ) &
    local recv_pid=$!
    save_pid "recv_loop" "$recv_pid"

    # Main PTT input loop
    ORIGINAL_STTY=$(stty -g)
    stty raw -echo -icanon min 0 time 1

    REC_PID=""
    REC_FILE=""
    LAST_SENT_INFO=""
    local ptt_active=0
    local ptt_got_repeat=0

    # Status bar is already drawn by draw_call_header

    while [ -f "$CONNECTED_FLAG" ]; do
        local key=""
        # Check volume-down double-tap trigger
        if [ -f "$vol_trigger_file" ]; then
            overwrite_rm "$vol_trigger_file"
            key="$PTT_KEY"  # simulate PTT key press
        else
            key=$(dd bs=1 count=1 2>/dev/null) || true
        fi

        if [ "$key" = "$PTT_KEY" ]; then
            if ptt_toggle_mode; then
                # Toggle mode (always on Termux; desktop opt-in via PTT_TOGGLE_MODE)
                if [ $ptt_active -eq 0 ]; then
                    ptt_active=1
                    # Yellow "Standby" while the mic device opens, then flip to red "Recording".
                    status_at "$STATUS_ROW" '  \033[43;30m ◌ Standby... \033[0m \033[2m[SPACE]=Send\033[0m        '
                    proto_send "PTT_START"
                    touch "$PTT_FLAG"
                    start_recording
                    _flip_to_recording_when_ready '  \033[41;1;37m ● RECORDING \033[0m \033[2m[SPACE]=Send\033[0m        '
                    stty raw -echo -icanon min 0 time 1 2>/dev/null || true
                else
                    ptt_active=0
                    stop_and_send
                    overwrite_rm "$PTT_FLAG"
                    proto_send "PTT_STOP"
                    # Update Last sent + status bar
                    printf '\0337' >&2
                    printf '\033[%d;1H\033[K' "$SENT_INFO_ROW" >&2
                    printf '  \033[2mLast sent:  \033[0m\033[1;37m%s\033[0m' "$LAST_SENT_INFO" >&2
                    printf '\033[%d;1H\033[K' "$STATUS_ROW" >&2
                    printf '  \033[1;32m Sent! \033[0m \033[2m[SPACE]=Talk [T]=Chat [S]=Settings [Q]=Hang up\033[0m   ' >&2
                    printf '\0338' >&2
                fi
            else
                # Hold-to-talk: bash raw mode has no keyup event, so we can't detect
                # "key released" directly. Instead we exploit keyboard autorepeat.
                #
                # The OS fires: one keydown immediately, then repeats ~650 ms later at
                # ~30 Hz. We set stty `time` (inter-byte timeout in 0.1s units) to 0.8s
                # on first press — long enough to survive the repeat-delay gap. The
                # instant the first repeat arrives we know the key is still held; we
                # shorten the timeout to 0.2s so dd detects the release quickly.
                # If no repeat ever comes within 0.8s the key was just tapped, not held.
                if [ $ptt_active -eq 0 ]; then
                    ptt_active=1
                    ptt_got_repeat=0
                    # Yellow "Standby" while the mic device opens, then flip to red "Recording".
                    status_at "$STATUS_ROW" '  \033[43;30;5m ◌ Standby... \033[0m                '
                    stty time 8  # extended onset window covers keyboard repeat delay <= 750ms
                    proto_send "PTT_START"
                    touch "$PTT_FLAG"
                    start_recording
                    _flip_to_recording_when_ready '  \033[41;1;37;5m ● RECORDING \033[0m                '
                elif [ $ptt_got_repeat -eq 0 ]; then
                    # First keyboard repeat confirmed, switch to short timeout for responsive release
                    ptt_got_repeat=1
                    stty time 2
                fi
            fi

        elif [ "$key" = "q" ] || [ "$key" = "Q" ]; then
            # If recording, cancel it
            if [ $ptt_active -eq 1 ] && [ -n "${REC_PID:-}" ]; then
                if [ $IS_TERMUX -eq 1 ]; then
                    termux-microphone-record -q &>/dev/null || true
                fi
                kill "$REC_PID" 2>/dev/null || true
                wait "$REC_PID" 2>/dev/null || true
                overwrite_rm "${REC_FILE:-}"
                REC_PID=""
                REC_FILE=""
            fi
            echo -e "\r\n${YELLOW}Hanging up...${NC}" >&2
            proto_send "HANGUP"
            echo "hangup" > "$DROP_REASON_FILE" 2>/dev/null || true
            overwrite_rm "$PTT_FLAG" "$CONNECTED_FLAG"
            break

        elif [ -z "$key" ]; then
            # No key pressed (timeout) — in hold-to-talk, release = stop and send.
            # In toggle mode we ignore timeouts so recording survives losing focus (alt+tab).
            if ! ptt_toggle_mode && [ $ptt_active -eq 1 ]; then
                stty time 1  # restore fast timeout for key detection
                ptt_active=0
                ptt_got_repeat=0
                stop_and_send
                overwrite_rm "$PTT_FLAG"
                proto_send "PTT_STOP"
                # Update Last sent + status bar
                printf '\0337' >&2
                printf '\033[%d;1H\033[K' "$SENT_INFO_ROW" >&2
                printf '  \033[2mLast sent:  \033[0m\033[1;37m%s\033[0m' "$LAST_SENT_INFO" >&2
                printf '\033[%d;1H\033[K' "$STATUS_ROW" >&2
                printf '  \033[1;32m Sent! \033[0m \033[2m[SPACE]=Hold to Talk [T]=Chat [S]=Settings [Q]=Hang up\033[0m   ' >&2
                printf '\0338' >&2
            fi

        elif [ "$key" = "t" ] || [ "$key" = "T" ]; then
            # Text chat mode
            # Hold off the background recv loop's absolute-row status writes while we
            # own the screen for cooked-mode input, so a GROUP:N beacon can't jump the
            # cursor mid-typing (the fixed status rows are wrong on macOS otherwise).
            touch "$MENU_FLAG"
            # Switch to cooked mode for text input
            stty "$ORIGINAL_STTY" 2>/dev/null || stty sane
            echo "" >&2
            echo -ne "  ${CYAN}${BOLD}MSG>${NC} " >&2
            # Bound the read: -n stops at the cap or Enter (whichever comes first), so a
            # huge paste can't OOM the sender or build a line the relay/receiver would
            # only drop. The cap derives from the receive-side base64 limit (MAX_MSG_B64),
            # halved as a conservative plaintext budget (encryption + base64 inflate it).
            local chat_msg="" _chat_max=$(( MAX_MSG_B64 / 2 ))
            [ "$_chat_max" -ge 1 ] || _chat_max=1
            read -r -e -n "$_chat_max" chat_msg
            if [ -n "$chat_msg" ]; then
                # Encrypt and send
                local _cid; _cid=$(uid)
                local chat_plain="$AUDIO_DIR/chat_${_cid}.tmp"
                local chat_enc="$AUDIO_DIR/chat_enc_${_cid}.tmp"
                echo -n "$chat_msg" > "$chat_plain"
                encrypt_file "$chat_plain" "$chat_enc" 2>/dev/null
                if [ -s "$chat_enc" ]; then
                    local chat_b64
                    chat_b64=$(base64 < "$chat_enc" | tr -d '\n')
                    proto_send "MSG:${chat_b64}"
                    echo -e "  ${DIM}[you] ${chat_msg}${NC}" >&2
                fi
                overwrite_rm "$chat_plain" "$chat_enc"
            fi
            # Switch back to raw mode for PTT and restore the status bar
            stty raw -echo -icanon min 0 time 1
            # Drain any input left over from an over-length paste so the surplus isn't
            # replayed as PTT/menu keystrokes (e.g. a stray 'q' hanging up the call).
            read -r -t 0.1 -n 100000 _ 2>/dev/null || true
            rm -f "$MENU_FLAG"
            _restore_ready_bar

        elif [ "$key" = "s" ] || [ "$key" = "S" ]; then
            # Mid-call settings — suppress the recv loop's absolute status writes so a
            # GROUP:N beacon can't stamp "Group: N callers" over the settings menu.
            touch "$MENU_FLAG"
            stty "$ORIGINAL_STTY" 2>/dev/null || stty sane
            # Flush any leftover raw mode input
            read -r -t 0.1 -n 10000 2>/dev/null || true
            settings_menu
            # Redraw call header, switch back to raw mode, restore status bar
            local _rd="" _rc=""
            [ -f "$remote_id_file" ] && _rd="$(<"$remote_id_file")"
            [ -z "$_rd" ] && _rd="$known_remote"
            [ -f "$remote_cipher_file" ] && _rc="$(<"$remote_cipher_file")"
            draw_call_header "$_rd" "$_rc"
            # Header is fully redrawn from cache/files above; let the recv loop update
            # the live rows again.
            rm -f "$MENU_FLAG"
            stty raw -echo -icanon min 0 time 1
            _restore_ready_bar
        fi
    done

    # If the recv subshell died mid-recording (its EXIT trap drops CONNECTED_FLAG,
    # the PTT loop exits without going through the Q branch), kill the dangling recorder.
    if [ -n "${REC_PID:-}" ]; then
        if [ $IS_TERMUX -eq 1 ]; then
            termux-microphone-record -q &>/dev/null || true
        fi
        kill "$REC_PID" 2>/dev/null || true
        wait "$REC_PID" 2>/dev/null || true
        overwrite_rm "${REC_FILE:-}"
        REC_PID=""; REC_FILE=""
    fi

    # Clear any stale menu-suppression flag so it can't carry into the next call.
    rm -f "$MENU_FLAG"

    echo -e "\n${BOLD}${RED} CALL ENDED ${NC}\n"
}

#=============================================================================
# AUDIO TEST (LOOPBACK)
#=============================================================================

# Name the capture device in play, so a silent recording points at the thing
# that produced it rather than leaving the user guessing.
_capture_device_desc() {
    case "$AUDIO_BACKEND" in
        pulse)
            if [ -n "${PULSE_SOURCE:-}" ]; then
                printf '%s' "$PULSE_SOURCE"
            else
                printf 'system default (%s)' \
                    "$(pactl get-default-source 2>/dev/null || echo unknown)"
            fi ;;
        *)  printf '%s' "${ALSA_DEVICE:-default}" ;;
    esac
}

test_audio() {
    header "Audio Loopback Test"

    # Check dependencies first
    local missing=0
    local audio_deps=(opusenc opusdec)
    if [ $IS_TERMUX -eq 1 ]; then
        audio_deps+=(termux-microphone-record ffmpeg termux-media-player)
    elif [ $IS_MACOS -eq 1 ]; then
        # ffmpeg captures via avfoundation; playback uses native afplay (always present).
        audio_deps+=(ffmpeg afplay)
    else
        # Linux: detect backend and require the right tools
        detect_audio_backend
        case "$AUDIO_BACKEND" in
            pulse) audio_deps+=(parecord paplay) ;;
            alsa)  audio_deps+=(arecord aplay) ;;
            *)
                log_err "No working audio backend found."
                log_err "Install pulseaudio-utils (or alsa-utils + /dev/snd)."
                log_err "Or set ALSA_DEVICE=plughw:X,Y in .env (run 'arecord -l' to find your card)."
                missing=1 ;;
        esac
    fi
    for dep in "${audio_deps[@]}"; do
        if ! check_dep "$dep"; then
            log_err "$dep not found — run option 9 to install dependencies first"
            missing=1
        fi
    done
    if [ $missing -eq 1 ]; then
        return 1
    fi

    echo -e "  ${DIM}This will record 3 seconds of audio, encode it with Opus,${NC}"
    echo -e "  ${DIM}and play it back to verify your audio pipeline works.${NC}\n"

    if [ -d "$DATA_DIR" ] && [ ! -w "$DATA_DIR" ]; then
        log_err "Data directory not writable: $DATA_DIR"
        log_err "Fix: sudo chown -R $(id -un):$(id -gn) \"$DATA_DIR\""
        return 1
    fi
    mkdir -p "$AUDIO_DIR"

    # Step 1: Record
    echo -ne "  ${YELLOW}● Recording for 3 seconds... speak now!${NC} "
    local _tid; _tid=$(uid)
    local raw_file="$AUDIO_DIR/test_${_tid}_raw.tmp"
    local opus_file="$AUDIO_DIR/test_${_tid}.opus"
    local dec_file="$AUDIO_DIR/test_${_tid}_dec.tmp"
    audio_record "$raw_file" 3
    echo -e "${GREEN}done${NC}"

    if [ ! -s "$raw_file" ]; then
        log_err "Recording failed — no audio captured from microphone"
        return 1
    fi

    local raw_size
    raw_size=$(file_size "$raw_file")
    echo -e "  ${DIM}Recorded $raw_size bytes of raw audio${NC}"

    # A capture device that produces nothing still fills the file with zeros,
    # so the size check above passes and every later step succeeds on silence.
    # The test then plays silence and reports success, which is indistinguishable
    # from "playback is broken" and sends you hunting the wrong end of the
    # pipeline. Catch it here and name the input device instead.
    local _sil_pct; _sil_pct=$(_raw_silence_pct "$raw_file")
    if [ "$_sil_pct" -ge 99 ]; then
        echo -e "  ${RED}${BOLD}FAILED${NC}"
        log_err "Captured $raw_size bytes, but every one of them is silence."
        log_err "Input device: $(_capture_device_desc)"
        log_err "Playback is not the problem here: there is no signal to play."
        echo -e "\n  ${YELLOW}Check, in order:${NC}"
        echo -e "  ${DIM}1. The mic is unmuted and its level is up in your desktop sound settings.${NC}"
        echo -e "  ${DIM}2. The right input is selected: Settings → 9 → Audio devices → Pick microphone.${NC}"
        if [ $DOCKER_MODE -eq 1 ]; then
            echo -e "  ${DIM}3. Docker: the container is on the HOST sound server, not a null sink.${NC}"
            echo -e "  ${DIM}   'pactl info' should name your desktop's server and 'pactl list short${NC}"
            echo -e "  ${DIM}   sources' should list your real mic. If you see only *_null.monitor,${NC}"
            echo -e "  ${DIM}   the image predates the audio fix and needs a rebuild: docker compose build.${NC}"
        fi
        echo ""
        overwrite_rm "$raw_file"
        return 1
    fi

    # Step 2: Encode with Opus (note: distinct filenames — same path truncates input)
    echo -ne "  ${YELLOW}● Encoding with Opus at ${OPUS_BITRATE}kbps...${NC} "
    local enc_err; enc_err=$(mktemp /tmp/pl_enc_err.XXXXXX)
    opusenc --raw --raw-rate "$SAMPLE_RATE" --raw-chan 1 \
        --bitrate "$OPUS_BITRATE" --framesize "$OPUS_FRAMESIZE" \
        --speech --quiet \
        "$raw_file" "$opus_file" 2>"$enc_err"
    if [ -s "$opus_file" ]; then
        echo -e "${GREEN}done${NC}"
        local opus_size
        opus_size=$(file_size "$opus_file")
        echo -e "  ${DIM}Opus size: $opus_size bytes (ratio: $((raw_size / opus_size))x)${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        log_err "opusenc failed: $(cat "$enc_err" 2>/dev/null || echo "no output")"
        overwrite_rm "$raw_file" "$opus_file" "$enc_err"
        return 1
    fi
    rm -f "$enc_err"

    # Step 3: Encrypt + Decrypt round-trip (if secret is set)
    if [ -n "$SHARED_SECRET" ]; then
        echo -ne "  ${YELLOW}● Encrypting and decrypting...${NC} "
        local enc_file="$AUDIO_DIR/test_enc_${_tid}.tmp"
        encrypt_file "$opus_file" "$enc_file"
        decrypt_file "$enc_file" "$dec_file"
        if cmp -s "$opus_file" "$dec_file"; then
            echo -e "${GREEN}round-trip OK${NC}"
            opus_file="$dec_file"
        else
            echo -e "${RED}FAILED${NC}"
            log_err "Encrypt/decrypt mismatch — check shared secret"
            overwrite_rm "$raw_file" "$enc_file" "$dec_file" "$opus_file"
            return 1
        fi
        overwrite_rm "$enc_file"
    else
        echo -e "  ${DIM}Encryption step skipped (no shared secret — set one via main menu → 1)${NC}"
    fi

    # Step 4: decode and play back (same path as live calls).
    local _play_ok=0
    if [ $IS_TERMUX -eq 1 ]; then
        echo -ne "  ${YELLOW}● Playing back via termux-media-player...${NC} "
        play_chunk "$opus_file" 2>/dev/null && _play_ok=1 || true
        if [ "$_play_ok" -eq 1 ]; then
            echo -e "${GREEN}done${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            log_err "Playback failed — ensure Termux:API app is installed and termux-media-player works."
            overwrite_rm "$raw_file" "$opus_file"
            return 1
        fi
    elif [ $IS_MACOS -eq 1 ]; then
        # macOS: decode to WAV and play via native afplay (same path as live calls).
        # afplay stderr is shown so a real failure (e.g. no output device) is visible.
        echo -ne "  ${YELLOW}● Playing back via afplay...${NC} "
        local _pwav="$AUDIO_DIR/test_play_${_tid}.wav"
        local _perr; _perr=$(mktemp /tmp/pl_audio_err.XXXXXX)
        opusdec --quiet --rate 48000 "$opus_file" "$_pwav" 2>/dev/null || true
        if [ -s "$_pwav" ] && afplay "$_pwav" 2>"$_perr"; then
            _play_ok=1
            echo -e "${GREEN}done${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            local _emsg; _emsg=$(cat "$_perr" 2>/dev/null | head -3)
            [ -n "$_emsg" ] && log_err "$_emsg"
            log_err "afplay could not play the clip - check System Settings → Sound → Output, and that the volume is up."
            overwrite_rm "$raw_file" "$opus_file" "$_pwav" "$_perr"
            return 1
        fi
        overwrite_rm "$_pwav"
        rm -f "$_perr"
    else
        # Linux: probe a working playback route. PLAY_ERRLOG surfaces the
        # real player error if it still fails.
        _detect_play_method || true
        local _pdesc="${PLAY_PLAYER:-none}${PLAY_DEV:+ → $PLAY_DEV}"
        echo -ne "  ${YELLOW}● Playing back via ${_pdesc}...${NC} "
        local _perr; _perr=$(mktemp /tmp/pl_audio_err.XXXXXX)
        (set -o pipefail
         opusdec --quiet --rate 48000 "$opus_file" - 2>/dev/null | \
             PLAY_ERRLOG="$_perr" _play_raw 48000
        ) && _play_ok=1
        if [ "$_play_ok" -eq 1 ]; then
            echo -e "${GREEN}done${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            local _emsg; _emsg=$(cat "$_perr" 2>/dev/null | head -3)
            [ -n "$_emsg" ] && log_err "$_emsg"
            log_err "No playback route worked — run option 4 (Test all outputs) to find a speaker you can hear, then 'Pick speakers'."
            overwrite_rm "$raw_file" "$opus_file" "$_perr"
            return 1
        fi
        rm -f "$_perr"
    fi

    overwrite_rm "$raw_file" "$opus_file"

    echo -e "\n  ${GREEN}${BOLD}Audio test complete!${NC}"
    echo -e "  ${DIM}If you heard your voice, the full encode→encrypt→decode→play pipeline works.${NC}\n"
}

#=============================================================================
# SHOW STATUS
#=============================================================================

show_status() {
    header "Status"

    # Reticulum status. Same signal main_menu uses: a destination hash is
    # published once a listener/relay has run at least once this session.
    local address; address=$(get_onion)
    if [ -n "$address" ]; then
        echo -e "  ${GREEN}●${NC} Reticulum destination published"
        echo -e "  ${BOLD}${WHITE}  Address: ${address}${NC}"
    else
        echo -e "  ${YELLOW}●${NC} No destination yet — listen or host a party line to publish one"
    fi

    # Secret
    if [ -n "$SHARED_SECRET" ]; then
        echo -e "  ${GREEN}●${NC} Shared secret set"
    else
        echo -e "  ${RED}●${NC} No shared secret (set one before calling)"
    fi

    # Audio
    detect_audio_backend
    if [ "$AUDIO_BACKEND" = "none" ]; then
        echo -e "  ${RED}●${NC} No audio device found"
        echo -e "  ${DIM}  Run 'arecord -l' on the host and set ALSA_DEVICE=plughw:X,Y in .env${NC}"
    else
        local _audio_dev=""
        case "$AUDIO_BACKEND" in
            pulse)    _audio_dev="PulseAudio/PipeWire ${PULSE_SOURCE:-default}${PULSE_SINK:+ → ${PULSE_SINK}}" ;;
            alsa)   _audio_dev="ALSA ${ALSA_DEVICE:-default}${ALSA_PLAY_DEVICE:+ → ${ALSA_PLAY_DEVICE}}" ;;
            ffmpeg) _audio_dev="ffmpeg (macOS)" ;;
            termux) _audio_dev="Termux mic" ;;
        esac
        if check_dep opusenc; then
            echo -e "  ${GREEN}●${NC} Audio pipeline ready  ${DIM}(${_audio_dev})${NC}"
        else
            echo -e "  ${YELLOW}●${NC} Audio device found but opusenc missing"
        fi
    fi

    # Reticulum transport info
    if [ -n "$REFLECTOR_HOST" ]; then
        echo -e "  ${GREEN}●${NC} Direct: ${REFLECTOR_HOST}:${REFLECTOR_PORT} ${DIM}(backbone bypassed)${NC}"
    elif [ -n "$RNS_HUBS" ]; then
        local _hub_n; _hub_n=$(awk -F, '{print NF}' <<< "$RNS_HUBS")
        echo -e "  ${GREEN}●${NC} Backbone: ${_hub_n} hub(s) seeded, +${RNS_AUTOCONNECT} discovered ${DIM}(no open ports needed)${NC}"
    else
        echo -e "  ${YELLOW}●${NC} No transport: RNS_HUBS empty and no REFLECTOR_HOST"
    fi

    # Config
    echo -e "\n  ${DIM}Hubs:         ${RNS_HUBS:-(none)}${NC}"
    echo -e "  ${DIM}Direct host:  ${REFLECTOR_HOST:-(unset)}:${REFLECTOR_PORT}${NC}"
    echo -e "  ${DIM}Cipher:       $CIPHER${NC}"
    echo -e "  ${DIM}Opus bitrate: ${OPUS_BITRATE}kbps${NC}"
    echo -e "  ${DIM}Opus frame:   ${OPUS_FRAMESIZE}ms${NC}"
    echo -e "  ${DIM}Dial:         ${DIAL_ATTEMPTS} attempts x ${DIAL_TIMEOUT}s${NC}"
    local _status_ptt="SPACE"
    [ "$PTT_KEY" != " " ] && _status_ptt="$PTT_KEY"
    echo -e "  ${DIM}PTT key:      [${_status_ptt}]${NC}"
    echo ""
}


#=============================================================================
# AUDIO DEVICE SETUP
#=============================================================================

# Internal: interactive device picker (Linux only). Lists PipeWire/PulseAudio
# devices (by friendly name) when the sound server is the active backend, or
# raw ALSA plughw devices when running on bare ALSA. "System default" lets the
# server route to the user's chosen device — the recommended option.
# Usage: _pick_audio_device capture|playback
_pick_audio_device() {
    local mode="$1"
    detect_audio_backend

    local label
    [ "$mode" = "capture" ] && label="Microphone (capture)" || label="Speakers (playback)"
    header "Select $label Device"

    local devs=() names=() cur_val=""
    local _server=0
    [ "$AUDIO_BACKEND" = "pulse" ] && _server=1

    if [ "$_server" -eq 1 ] && check_dep pactl; then
        # ── Sound-server devices (PipeWire / PulseAudio) ──
        local _kind _id _name _rest _desc
        if [ "$mode" = "capture" ]; then _kind="sources"; cur_val="${PULSE_SOURCE:-}"
        else _kind="sinks"; cur_val="${PULSE_SINK:-}"; fi
        while IFS=$'\t' read -r _id _name _rest; do
            [ -z "$_name" ] && continue
            # Skip monitor sources (output loopbacks) when choosing a mic
            [ "$mode" = "capture" ] && [[ "$_name" == *.monitor ]] && continue
            _desc=$(pactl list "$_kind" 2>/dev/null | awk -v n="$_name" '
                $1=="Name:" && $2==n {f=1}
                f && $1=="Description:"{ $1=""; sub(/^ /,""); print; exit }')
            devs+=("$_name")
            names+=("${_desc:-$_name}")
        done < <(pactl list short "$_kind" 2>/dev/null)
    else
        # ── Bare-ALSA hardware devices ──
        local cmd card cname dev dname
        if [ "$mode" = "capture" ]; then cmd="arecord"; cur_val="${ALSA_DEVICE:-}"
        else cmd="aplay"; cur_val="${ALSA_PLAY_DEVICE:-}"; fi
        while IFS= read -r line; do
            [[ "$line" =~ ^card[[:space:]]([0-9]+):[^[]*\[([^]]+)\],[[:space:]]*device[[:space:]]([0-9]+):[[:space:]]*([^[]+) ]] || continue
            card="${BASH_REMATCH[1]}"; cname="${BASH_REMATCH[2]}"
            dev="${BASH_REMATCH[3]}";  dname="${BASH_REMATCH[4]%% }"
            devs+=("plughw:${card},${dev}")
            names+=("[${cname}] ${dname}")
        done < <("$cmd" -l 2>/dev/null | grep "^card")
    fi

    local i
    for i in "${!devs[@]}"; do
        local marker="" hdmi_flag=""
        [ "${devs[$i]}" = "$cur_val" ] && marker="  ${GREEN}← current${NC}"
        [[ "$(_lc "${names[$i]}")" =~ hdmi|displayport ]] && hdmi_flag=" ${DIM}[HDMI]${NC}"
        printf "  ${BOLD}${WHITE}%d${NC} ${CYAN}│${NC} %-22s %s%b%b\n" \
            "$((i+1))" "${devs[$i]}" "${names[$i]}" "$hdmi_flag" "$marker"
    done
    local n=${#devs[@]}

    local _sys_marker=""
    [ -z "${cur_val}" ] && _sys_marker="  ${GREEN}← current${NC}"
    echo -e "  ${BOLD}${WHITE}D${NC} ${CYAN}│${NC} System default ${DIM}(use the desktop's selected device — recommended)${NC}${_sys_marker}"
    echo -e "  ${BOLD}${WHITE}A${NC} ${CYAN}│${NC} Auto-detect ${DIM}(re-scan audio backends)${NC}"
    echo -e "  ${BOLD}${WHITE}0${NC} ${CYAN}│${NC} Cancel"
    echo ""
    echo -ne "  ${BOLD}Select: ${NC}"
    read -r dchoice

    local _what
    [ "$mode" = "capture" ] && _what="Microphone" || _what="Speakers"
    case "$(_lc "$dchoice")" in
        0|q) return 0 ;;
        d)
            # System default within the current backend: clear this mode's device
            if [ "$mode" = "capture" ]; then PULSE_SOURCE=""; ALSA_DEVICE=""
            else PULSE_SINK=""; ALSA_PLAY_DEVICE=""; PLAY_PLAYER=""; PLAY_DEV=""; fi
            save_config; log_ok "$_what: system default"; sleep 1 ;;
        a)
            # Full re-detect: clear this mode's device and re-run backend selection
            if [ "$mode" = "capture" ]; then PULSE_SOURCE=""; ALSA_DEVICE=""
            else PULSE_SINK=""; ALSA_PLAY_DEVICE=""; PLAY_PLAYER=""; PLAY_DEV=""; fi
            AUDIO_BACKEND=""; save_config; log_ok "Set to auto-detect"; sleep 1 ;;
        *)
            if [[ "$dchoice" =~ ^[0-9]+$ ]] && [ "$dchoice" -ge 1 ] && [ "$dchoice" -le "$n" ]; then
                local chosen="${devs[$((dchoice-1))]}"
                if [ "$_server" -eq 1 ]; then
                    [ "$mode" = "capture" ] && PULSE_SOURCE="$chosen" || PULSE_SINK="$chosen"
                else
                    if [ "$mode" = "capture" ]; then ALSA_DEVICE="$chosen"; AUDIO_BACKEND=""
                    else ALSA_PLAY_DEVICE="$chosen"; fi
                fi
                # Force playback re-probe so the new device takes effect immediately
                [ "$mode" = "playback" ] && { PLAY_PLAYER=""; PLAY_DEV=""; }
                save_config; log_ok "$_what set to: $chosen"; sleep 1
            else
                menu_invalid
            fi ;;
    esac
}

# Android-specific audio settings (Termux backend).
_settings_audio_android() {
    while true; do
        clear
        header "Audio Setup (Android / Termux)"
        echo -e "  ${DIM}Backend: termux-microphone-record + termux-media-player${NC}"
        echo -e "  ${DIM}Android routes mic/speaker automatically — no manual device selection needed.${NC}"
        echo ""

        # Dependency status
        if check_dep termux-microphone-record; then
            echo -e "  ${GREEN}●${NC} termux-microphone-record  ${DIM}OK${NC}"
        else
            echo -e "  ${RED}●${NC} termux-microphone-record  ${YELLOW}missing${NC}"
            echo -e "    ${DIM}Install the Termux:API app from F-Droid, then: pkg install termux-api${NC}"
        fi
        if check_dep termux-media-player; then
            echo -e "  ${GREEN}●${NC} termux-media-player  ${DIM}OK${NC}"
        else
            echo -e "  ${RED}●${NC} termux-media-player  ${YELLOW}missing${NC}  ${DIM}(install Termux:API from F-Droid, then: pkg install termux-api)${NC}"
        fi

        # Volume levels
        if check_dep termux-volume && check_dep jq; then
            echo ""
            local _vj
            _vj=$(termux-volume 2>/dev/null) || _vj=""
            if [ -n "$_vj" ]; then
                echo -e "  ${DIM}Volume levels:${NC}"
                echo "$_vj" | jq -r '.[] | select(.stream | test("MUSIC|RING|ALARM")) |
                    "    \(.stream | ltrimstr("STREAM_") | ascii_downcase): \(.volume)/\(.max_volume)"' \
                    2>/dev/null || true
            fi
        fi

        echo ""
        echo -e "  ${BOLD}${WHITE}1${NC} ${CYAN}│${NC} Test microphone and playback"
        check_dep termux-volume && \
            echo -e "  ${BOLD}${WHITE}2${NC} ${CYAN}│${NC} Adjust media volume"
        echo -e "  ${BOLD}${WHITE}3${NC} ${CYAN}│${NC} Bluetooth audio guide"
        echo -e "  ${BOLD}${WHITE}0${NC} ${CYAN}│${NC} ${DIM}Back${NC}"
        echo ""
        echo -ne "  ${BOLD}Select: ${NC}"
        read -r achoice

        case "$achoice" in
            1) test_audio || true; pause ;;
            2)
                if check_dep termux-volume; then
                    echo -ne "\n  ${BOLD}Media volume (0-15): ${NC}"
                    read -r _vol
                    if [[ "$_vol" =~ ^([0-9]|1[0-5])$ ]]; then
                        termux-volume music "$_vol" 2>/dev/null \
                            && log_ok "Media volume set to $_vol" \
                            || log_err "Failed — ensure Termux:API app is installed"
                    else
                        log_warn "Enter a number 0-15"
                    fi
                    sleep 1
                fi ;;
            3)
                clear
                echo -e "\n${BOLD}${CYAN}Bluetooth Audio on Android${NC}\n"
                echo -e "  Android routes audio automatically once a Bluetooth device is paired."
                echo -e "  Reticulum Party Line uses whatever Android selects — nothing to configure here.\n"
                echo -e "  ${BOLD}To use a Bluetooth headset or speaker:${NC}"
                echo -e "  ${DIM}  1. Android Settings → Connected devices → Pair new device${NC}"
                echo -e "  ${DIM}  2. Once paired, Android routes audio through it automatically${NC}"
                echo -e "  ${DIM}  3. For headset mic: tap the device → enable Phone audio / Headset (HFP) profile${NC}"
                echo -e "  ${DIM}  4. Start a call — mic and audio route through Bluetooth automatically${NC}\n"
                echo -e "  ${BOLD}Troubleshooting:${NC}"
                echo -e "  ${DIM}  • No mic from Bluetooth: ensure HFP profile is active (not just A2DP)${NC}"
                echo -e "  ${DIM}  • Audio stuck on phone speaker: disconnect and reconnect the BT device${NC}"
                echo -e "  ${DIM}  • Termux:API app (F-Droid) must be installed alongside Termux for mic access${NC}"
                echo ""
                pause ;;
            0|q|Q) return ;;
            *) menu_invalid ;;
        esac
    done
}



# Internal: emit raw S16LE mono white noise to stdout for <secs> seconds.
# Uses sox at a comfortable volume when available; otherwise full-scale random
# bytes from /dev/urandom (louder, harsher — callers warn the user).
_gen_noise() {
    local rate="$1" secs="$2"
    if check_dep sox; then
        sox -n -t raw -r "$rate" -e signed -b 16 -c 1 - synth "$secs" whitenoise vol 0.2 2>/dev/null
    else
        head -c "$(( rate * 2 * secs ))" /dev/urandom
    fi
}

# Internal: play a burst of white noise to every playback device in turn so the
# user can hear which output actually works (helps when a specific card/sink is
# the only audible one). Uses the sound server's sinks when reachable, else the
# raw ALSA hardware devices.
_test_all_outputs() {
    clear
    header "Test All Outputs (white noise)"
    echo -e "  ${DIM}Plays ~2s of white noise to each device. Note the number you HEAR —${NC}"
    echo -e "  ${DIM}you'll set it as your speaker at the end (a device can 'play' here and${NC}"
    echo -e "  ${DIM}still be silent — only your ears decide which one is real).${NC}"
    check_dep sox || echo -e "  ${YELLOW}Note: sox not installed — noise will be loud static. Lower your volume.${NC}"
    echo ""
    echo -ne "  ${BOLD}Press Enter to start (Ctrl-C to cancel)...${NC}"; read -r _

    # 48000 Hz matches the live path (opusdec --rate 48000 | _play_raw 48000), so
    # a device that's audible here is audible in a real call — same rate, same
    # player, same device string.
    local rate=48000 secs=2 played=0 idx=0
    # Parallel arrays, one entry per numbered device: kind = pulse|alsa,
    # id = the exact identifier _resolve_play_route consumes (sink name or
    # plughw:/route), label = human description for the prompt.
    local _opt_kind=() _opt_id=() _opt_label=()

    # Pick the best server playback tool (pw-play exists on PipeWire desktops
    # even without pulseaudio-utils; paplay covers PulseAudio).
    local splayer=""
    check_dep pw-play && splayer="pw-play"
    [ -z "$splayer" ] && check_dep paplay && splayer="paplay"

    if [ -n "$splayer" ]; then
        echo -e "\n  ${DIM}Sound server (via $splayer):${NC}"
        # ── Default sink FIRST — the safe, reliable pick on any PipeWire/Pulse box.
        # It routes through the server to your desktop's selected output, so it
        # avoids the raw-ALSA EBUSY trap (where the connected device is "busy" and
        # only disconnected ports open silently). pw-play talks to PipeWire even
        # when pactl/pipewire-pulse can't enumerate sinks, so this plays even in the
        # degraded state that funnelled users into raw ALSA before.
        idx=$((idx+1))
        _opt_kind+=("pulse-default"); _opt_id+=(""); _opt_label+=("System default output (server)")
        echo -ne "  ${BOLD}${WHITE}${idx}${NC} ${YELLOW}●${NC} System default output ${DIM}(your desktop's selected output)${NC} ... "
        if _gen_noise "$rate" "$secs" | _play_with "$splayer" "" "$rate"; then
            echo -e "${GREEN}played${NC}"; played=$((played+1))
        else
            echo -e "${RED}failed${NC}"
        fi
        sleep 0.3
        # ── Specific sinks (needs a working pactl; harmless/empty otherwise). ──
        if check_dep pactl; then
            local _id _name _rest _desc
            while IFS=$'\t' read -r _id _name _rest; do
                [ -z "$_name" ] && continue
                _desc=$(pactl list sinks 2>/dev/null | awk -v n="$_name" \
                    '$1=="Name:"&&$2==n{f=1} f&&$1=="Description:"{$1="";sub(/^ /,"");print;exit}' || true)
                idx=$((idx+1))
                _opt_kind+=("pulse"); _opt_id+=("$_name"); _opt_label+=("${_desc:-$_name}")
                echo -ne "  ${BOLD}${WHITE}${idx}${NC} ${YELLOW}●${NC} ${_desc:-$_name} ... "
                if _gen_noise "$rate" "$secs" | _play_with "$splayer" "$_name" "$rate"; then
                    echo -e "${GREEN}played${NC}"; played=$((played+1))
                else
                    echo -e "${RED}failed${NC}"
                fi
                sleep 0.3
            done < <(pactl list short sinks 2>/dev/null)
        fi
    fi

    # Raw ALSA hardware is offered ONLY when nothing on the server side played —
    # on a PipeWire box `aplay -D plughw:X,Y` EBUSYs the active sink and "plays"
    # silently to disconnected ports, so it's the last resort, not the default.
    if [ "$played" -eq 0 ] && check_dep aplay; then
        echo -e "\n  ${DIM}ALSA devices (direct — no working sound server):${NC}"
        # 'default' first — it routes through the server / dmix and is usually
        # the one that works when raw plughw is busy.
        idx=$((idx+1))
        _opt_kind+=("alsa"); _opt_id+=("default"); _opt_label+=("default (system default route)")
        echo -ne "  ${BOLD}${WHITE}${idx}${NC} ${YELLOW}●${NC} default ${DIM}(system default route)${NC} ... "
        if _gen_noise "$rate" "$secs" | _play_with aplay default "$rate"; then
            echo -e "${GREEN}played${NC}"; played=$((played+1))
        else
            echo -e "${RED}failed${NC}"
        fi
        local card cname dev dname
        while IFS= read -r line; do
            [[ "$line" =~ ^card[[:space:]]([0-9]+):[^[]*\[([^]]+)\],[[:space:]]*device[[:space:]]([0-9]+):[[:space:]]*([^[]+) ]] || continue
            card="${BASH_REMATCH[1]}"; cname="${BASH_REMATCH[2]}"
            dev="${BASH_REMATCH[3]}";  dname="${BASH_REMATCH[4]%% }"
            idx=$((idx+1))
            _opt_kind+=("alsa"); _opt_id+=("plughw:${card},${dev}")
            _opt_label+=("plughw:${card},${dev}  [${cname}] ${dname}")
            echo -ne "  ${BOLD}${WHITE}${idx}${NC} ${YELLOW}●${NC} plughw:${card},${dev}  [${cname}] ${dname} ... "
            if _gen_noise "$rate" "$secs" | _play_with aplay "plughw:${card},${dev}" "$rate"; then
                echo -e "${GREEN}played${NC}"; played=$((played+1))
            else
                echo -e "${RED}failed${NC}"
            fi
            sleep 0.3
        done < <(aplay -l 2>/dev/null | grep "^card")
    fi

    if [ -z "$splayer" ] && ! check_dep aplay; then
        log_err "No playback tools found (need pw-play, paplay, or aplay)."
        return 1
    fi

    echo ""
    if [ "$played" -eq 0 ]; then
        log_warn "No device accepted playback. Check that audio isn't muted, or install pulseaudio-utils / pipewire-utils."
        return 0
    fi

    # ── Set the device the user actually HEARD, inline (same identifiers the
    # live-call resolver uses, so what you heard is exactly what calls play). ──
    local n=${#_opt_id[@]}
    echo -ne "  ${BOLD}Enter the number you heard to set it as your speaker (Enter to skip): ${NC}"
    read -r _heard
    if [[ "$_heard" =~ ^[0-9]+$ ]] && [ "$_heard" -ge 1 ] && [ "$_heard" -le "$n" ]; then
        local _k="${_opt_kind[$((_heard-1))]}" _v="${_opt_id[$((_heard-1))]}"
        case "$_k" in
            pulse-default)
                # "System default output" — pin it to the server's real default
                # sink name so it's authoritative and shown. If pactl can't report
                # it, leave both cleared: the probe still routes pw-play→server
                # default (its #2 candidate), which is exactly this output.
                local _dsink=""
                check_dep pactl && _dsink=$(pactl get-default-sink 2>/dev/null || true)
                PULSE_SINK="$_dsink"; ALSA_PLAY_DEVICE="" ;;
            pulse)
                PULSE_SINK="$_v"; ALSA_PLAY_DEVICE="" ;;
            *)
                ALSA_PLAY_DEVICE="$_v"; PULSE_SINK="" ;;
        esac
        # Force a re-resolve so the new choice takes effect immediately.
        PLAY_PLAYER=""; PLAY_DEV=""
        save_config
        log_ok "Speakers set to: ${_opt_label[$((_heard-1))]}"
        echo -e "  ${DIM}Verify with 'Test audio pipeline' — it now uses this output.${NC}"
    elif [ -n "$_heard" ]; then
        echo -e "  ${YELLOW}Skipped — '$_heard' is not a listed number.${NC}"
    fi
}

# Internal: print the REAL audio state so playback problems are visible instead
# of silently mis-routed. Read-only (no probe side effects). Reuses
# detect_audio_backend / _server_available / _resolve_play_route. The headline
# line is "what live calls will actually play through" — the thing that was
# silently drifting before.
_audio_diagnostics() {
    clear
    header "Audio Diagnostics"
    detect_audio_backend

    echo -e "  ${BOLD}Backend:${NC} ${WHITE}${AUDIO_BACKEND:-none}${NC}"
    if _server_available; then
        echo -e "  ${DIM}Sound server: reachable (pactl info / socket OK)${NC}"
    else
        echo -e "  ${DIM}Sound server: not reachable — ALSA-direct path${NC}"
    fi

    echo ""
    echo -e "  ${BOLD}Configured pick:${NC}"
    echo -e "    PULSE_SINK        = ${WHITE}${PULSE_SINK:-$(echo -e "${DIM}(unset)${NC}")}${NC}"
    echo -e "    ALSA_PLAY_DEVICE  = ${WHITE}${ALSA_PLAY_DEVICE:-$(echo -e "${DIM}(unset)${NC}")}${NC}"

    # The decisive line: what a live call resolves to RIGHT NOW.
    local _route _rplayer _rdev
    if _route=$(_resolve_play_route); then
        _rplayer="${_route%%|*}"; _rdev="${_route#*|}"
        echo -e "  ${BOLD}Calls will play via:${NC} ${GREEN}${_rplayer}${_rdev:+ → $_rdev}${NC} ${DIM}(your explicit pick — authoritative)${NC}"
    else
        echo -e "  ${BOLD}Calls will play via:${NC} ${YELLOW}auto-probe${NC} ${DIM}(no device picked; first that 'opens' wins — may be inaudible)${NC}"
        echo -e "    ${DIM}Run the white-noise sweep below and pick the one you HEAR to lock this down.${NC}"
    fi

    # Mute / volume — the usual "command succeeds but nothing audible" cause.
    echo ""
    echo -e "  ${BOLD}Mute / volume:${NC}"
    # NOTE: every command substitution below ends in `|| true`. The app runs under
    # `set -euo pipefail`, so a pipeline whose last stage exits non-zero (grep with
    # no match, a missing sink/control) would otherwise fail the bare assignment
    # and abort the whole program. `|| true` keeps diagnostics read-only-safe.
    if check_dep pactl && _server_available; then
        local _def; _def=$(pactl get-default-sink 2>/dev/null || true)
        echo -e "    Default sink: ${WHITE}${_def:-?}${NC}"
        local _s _seen=""
        for _s in "$_def" "${PULSE_SINK:-}"; do
            [ -z "$_s" ] && continue
            [[ "$_seen" == *"|$_s|"* ]] && continue
            _seen="${_seen}|$_s|"
            local _m _vol
            _m=$(pactl get-sink-mute "$_s" 2>/dev/null | awk '{print $2}' || true)
            _vol=$(pactl get-sink-volume "$_s" 2>/dev/null | grep -o '[0-9]*%' | head -1 || true)
            if [ "$_m" = "yes" ]; then
                echo -e "    ${RED}● $_s — MUTED${NC} ${DIM}(vol ${_vol:-?})${NC}"
            else
                echo -e "    ${GREEN}● $_s — unmuted${NC} ${DIM}(vol ${_vol:-?})${NC}"
            fi
        done
    fi
    if check_dep amixer; then
        local _ctl _state
        for _ctl in Master PCM Speaker Headphone; do
            _state=$(amixer sget "$_ctl" 2>/dev/null | grep -o '\[on\]\|\[off\]' | head -1 || true)
            [ -z "$_state" ] && continue
            if [ "$_state" = "[off]" ]; then
                echo -e "    ${RED}● ALSA $_ctl — OFF (muted)${NC}"
            else
                echo -e "    ${GREEN}● ALSA $_ctl — on${NC}"
            fi
        done
    fi

    echo ""
    echo -e "  ${DIM}Remember: a device that 'plays' in the test can still be silent —${NC}"
    echo -e "  ${DIM}only your ears decide. Pick the one you hear, then verify the pipeline.${NC}"
    echo ""
    echo -e "  ${BOLD}${WHITE}1${NC} ${CYAN}│${NC} Run white-noise sweep + set the one you hear"
    echo -e "  ${BOLD}${WHITE}2${NC} ${CYAN}│${NC} Verify with audio pipeline test"
    echo -e "  ${BOLD}${WHITE}0${NC} ${CYAN}│${NC} ${DIM}Back${NC}"
    echo ""
    echo -ne "  ${BOLD}Select: ${NC}"
    read -r _dchoice
    case "$_dchoice" in
        1) _test_all_outputs || true; pause ;;
        2) test_audio || true; pause ;;
        *) return 0 ;;
    esac
}

# macOS audio setup: capture goes through ffmpeg/AVFoundation (device index is
# selectable here), playback through the native afplay. Output device is chosen in
# System Settings → Sound → Output; only the input index is app-configurable.
_settings_audio_macos() {
    while true; do
        clear
        header "Audio Setup (macOS)"
        echo -e "  ${DIM}Capture:  ffmpeg (AVFoundation)   Playback: afplay (system default output)${NC}"
        echo -e "  ${DIM}Input device index: ${NC}${WHITE}${MACOS_AUDIO_INDEX}${NC}   ${DIM}(:${MACOS_AUDIO_INDEX} - pick below)${NC}"
        echo ""

        # Dependency status
        if check_dep ffmpeg; then
            echo -e "  ${GREEN}●${NC} ffmpeg  ${DIM}OK${NC}"
        else
            echo -e "  ${RED}●${NC} ffmpeg  ${YELLOW}missing${NC}  ${DIM}(install: brew install ffmpeg opus-tools)${NC}"
        fi
        if check_dep afplay; then
            echo -e "  ${GREEN}●${NC} afplay  ${DIM}OK (built in)${NC}"
        else
            echo -e "  ${RED}●${NC} afplay  ${YELLOW}missing${NC}  ${DIM}(unexpected - afplay ships with macOS)${NC}"
        fi
        echo ""
        echo -e "  ${DIM}Output device (speakers/headphones) is chosen in${NC}"
        echo -e "  ${DIM}  System Settings → Sound → Output.${NC}"
        echo -e "  ${DIM}First run: allow Terminal in System Settings → Privacy & Security → Microphone.${NC}"
        echo ""
        echo -e "  ${BOLD}${WHITE}1${NC} ${CYAN}│${NC} List audio input devices"
        echo -e "  ${BOLD}${WHITE}2${NC} ${CYAN}│${NC} Pick microphone    ${DIM}(set input device index)${NC}"
        echo -e "  ${BOLD}${WHITE}3${NC} ${CYAN}│${NC} Test audio pipeline ${DIM}(record + play back your voice)${NC}"
        echo -e "  ${BOLD}${WHITE}4${NC} ${CYAN}│${NC} Diagnostics        ${DIM}(verbose - why is nothing audible?)${NC}"
        echo -e "  ${BOLD}${WHITE}0${NC} ${CYAN}│${NC} ${DIM}Back${NC}"
        echo ""
        echo -ne "  ${BOLD}Select: ${NC}"
        read -r _mchoice
        case "$_mchoice" in
            1)
                echo ""
                echo -e "  ${DIM}AVFoundation devices (use the number in [brackets] under 'audio devices'):${NC}"
                echo ""
                # ffmpeg prints the device table to stderr and exits non-zero by design.
                ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
                    | sed -E 's/^\[[^]]*\] //' | grep -iE 'devices|\[[0-9]+\]' || \
                    log_err "Could not list devices - is ffmpeg installed?"
                pause ;;
            2)
                echo ""
                echo -ne "  ${BOLD}Input device index (0, 1, 2 ...): ${NC}"
                read -r _idx
                if [[ "$_idx" =~ ^[0-9]+$ ]]; then
                    MACOS_AUDIO_INDEX="$_idx"
                    save_config
                    log_ok "Microphone set to AVFoundation index :$MACOS_AUDIO_INDEX"
                else
                    log_warn "Enter a whole number (see 'List audio input devices')."
                fi
                sleep 1 ;;
            3) test_audio || true; pause ;;
            4) _macos_audio_diagnostics; pause ;;
            0|q|Q) return ;;
            *) menu_invalid ;;
        esac
    done
}

# Verbose macOS capture+playback probe. Unlike the normal paths it shows the real
# ffmpeg/afplay stderr and the captured byte count, so a denied mic permission,
# a wrong device index, or a dead output device is actually visible.
_macos_audio_diagnostics() {
    clear
    header "macOS Audio Diagnostics"
    mkdir -p "$AUDIO_DIR"
    local _id; _id=$(uid)
    local _raw="$AUDIO_DIR/diag_${_id}.raw"
    local _wav="$AUDIO_DIR/diag_${_id}.wav"

    echo -e "  ${DIM}Capture command:${NC}"
    echo -e "  ${WHITE}ffmpeg -f avfoundation -i \":${MACOS_AUDIO_INDEX}\" -t 2 -f s16le -ar ${SAMPLE_RATE} -ac 1 ...${NC}"
    echo ""
    echo -e "  ${YELLOW}● Recording 2 seconds - speak now...${NC}"
    echo -e "  ${DIM}────── ffmpeg output ──────${NC}"
    ffmpeg -hide_banner -y -f avfoundation -i ":${MACOS_AUDIO_INDEX}" -t 2 \
        -f s16le -ar "$SAMPLE_RATE" -ac 1 "$_raw" || true
    echo -e "  ${DIM}───────────────────────────${NC}"

    local _bytes=0; [ -f "$_raw" ] && _bytes=$(file_size "$_raw")
    if [ "$_bytes" -gt 0 ]; then
        log_ok "Captured $_bytes bytes from AVFoundation index :$MACOS_AUDIO_INDEX"
    else
        log_err "Captured 0 bytes - the mic did not produce audio."
        echo -e "  ${DIM}Likely causes:${NC}"
        echo -e "  ${DIM}  • Terminal not allowed under System Settings → Privacy & Security → Microphone${NC}"
        echo -e "  ${DIM}  • Wrong input index - run 'List audio input devices' and 'Pick microphone'${NC}"
        overwrite_rm "$_raw"
        return 1
    fi

    echo ""
    echo -e "  ${YELLOW}● Playing it back via afplay...${NC}"
    echo -e "  ${DIM}────── afplay output ──────${NC}"
    ffmpeg -hide_banner -y -f s16le -ar "$SAMPLE_RATE" -ac 1 -i "$_raw" "$_wav" 2>/dev/null || true
    if [ -s "$_wav" ] && afplay "$_wav"; then
        log_ok "afplay finished. If you heard yourself, capture + playback both work."
    else
        log_err "afplay failed - check System Settings → Sound → Output and the volume."
    fi
    overwrite_rm "$_raw" "$_wav"
    return 0
}

audio_menu() {
    # Android / Termux: ALSA doesn't exist — hand off to Android-specific flow
    if [ $IS_TERMUX -eq 1 ]; then
        _settings_audio_android; return
    fi

    # macOS: capture via ffmpeg/AVFoundation, playback via native afplay
    if [ $IS_MACOS -eq 1 ]; then
        _settings_audio_macos; return
    fi

    # Linux: full device picker (sound server preferred, ALSA fallback)
    while true; do
        clear
        header "Audio Device Setup"

        detect_audio_backend
        local _cap _cap_backend
        case "$AUDIO_BACKEND" in
            pulse)    _cap_backend="PulseAudio/PipeWire"; _cap="${PULSE_SOURCE:-}" ;;
            alsa)     _cap_backend="ALSA direct"; _cap="${ALSA_DEVICE:-}" ;;
            *)        _cap_backend="none"; _cap="" ;;
        esac
        # Show the AUTHORITATIVE route — what live calls will actually use. An
        # explicit pick wins verbatim; only when nothing is picked do we fall to
        # the probe (and say so), so the display never drifts from reality.
        local _play_disp _route
        if _route=$(_resolve_play_route); then
            _play_disp="${_route%%|*} → ${_route#*|} ${DIM}(your pick)${NC}"
        elif [ -n "${PLAY_PLAYER:-}" ]; then
            _play_disp="${PLAY_PLAYER}${PLAY_DEV:+ → $PLAY_DEV} ${DIM}(auto-probed)${NC}"
        else
            _play_disp="${DIM}auto (probed on test/call)${NC}"
        fi

        echo -e "  ${DIM}Capture (mic):    ${NC}${WHITE}${_cap_backend}${NC}  ${WHITE}${_cap:-${DIM}system default${NC}}${NC}"
        echo -e "  ${DIM}Playback (spkr):  ${NC}${WHITE}${_play_disp}${NC}"
        echo ""
        echo -e "  ${DIM}Tip: 'System default' uses the device selected in your desktop sound settings.${NC}"
        echo ""
        echo -e "  ${BOLD}${WHITE}1${NC} ${CYAN}│${NC} Pick microphone    ${DIM}(capture device)${NC}"
        echo -e "  ${BOLD}${WHITE}2${NC} ${CYAN}│${NC} Pick speakers      ${DIM}(playback device)${NC}"
        echo -e "  ${BOLD}${WHITE}3${NC} ${CYAN}│${NC} Test audio pipeline"
        echo -e "  ${BOLD}${WHITE}4${NC} ${CYAN}│${NC} Test all outputs   ${DIM}(white noise to each speaker)${NC}"
        echo -e "  ${BOLD}${WHITE}5${NC} ${CYAN}│${NC} Reset to auto-detect"
        echo -e "  ${BOLD}${WHITE}6${NC} ${CYAN}│${NC} Audio diagnostics  ${DIM}(why is nothing audible?)${NC}"
        echo -e "  ${BOLD}${WHITE}0${NC} ${CYAN}│${NC} ${DIM}Back${NC}"
        echo ""
        echo -ne "  ${BOLD}Select: ${NC}"
        read -r achoice

        case "$achoice" in
            1) _pick_audio_device capture ;;
            2) _pick_audio_device playback ;;
            3) test_audio || true; pause ;;
            4) _test_all_outputs || true; pause ;;
            5)
                ALSA_DEVICE=""; ALSA_PLAY_DEVICE=""; PULSE_SOURCE=""; PULSE_SINK=""
                AUDIO_BACKEND=""; PLAY_PLAYER=""; PLAY_DEV=""
                save_config; log_ok "Audio devices reset to auto-detect"; sleep 1 ;;
            6) _audio_diagnostics || true ;;
            0|q|Q) return ;;
            *) menu_invalid ;;
        esac
    done
}

#=============================================================================
# SETTINGS MENU
#=============================================================================

settings_menu() {
    while true; do
        clear
        header "Settings"
        echo -e "  ${DIM}Current Opus bitrate: ${NC}${WHITE}${OPUS_BITRATE} kbps${NC}"
        echo -e "  ${DIM}Current Opus frame:   ${NC}${WHITE}${OPUS_FRAMESIZE} ms${NC}"

        local al_label="$(onoff_label "$AUTO_LISTEN")"
        echo -e "  ${DIM}Auto-listen:          ${NC}${al_label}"

        local ptt_display="SPACE"
        [ "$PTT_KEY" != " " ] && ptt_display="$PTT_KEY"
        echo -e "  ${DIM}PTT key:              ${NC}${WHITE}${ptt_display}${NC}"

        if [ $IS_TERMUX -eq 0 ]; then
            local ptm_label="${RED}hold-to-talk${NC}"
            [ "$PTT_TOGGLE_MODE" -eq 1 ] && ptm_label="${GREEN}toggle (press to start/stop)${NC}"
            echo -e "  ${DIM}PTT mode:             ${NC}${ptm_label}"
        fi

        if [ $IS_TERMUX -eq 1 ]; then
            local vp_label="$(onoff_label "$VOL_PTT")"
            echo -e "  ${DIM}Volume PTT:            ${NC}${vp_label}  ${DIM}(experimental)${NC}"
        fi

        local hmac_label="$(onoff_label "$HMAC_AUTH")"
        echo -e "  ${DIM}HMAC auth:            ${NC}${hmac_label}"

        local norm_label="$(onoff_label "$NORMALIZE_PLAYBACK")"
        echo -e "  ${DIM}Normalize playback:   ${NC}${norm_label}"

        local fd_label="$(onoff_label "$FULL_DUPLEX")"
        echo -e "  ${DIM}Full-duplex audio:    ${NC}${fd_label}  ${DIM}(TCP backbone only)${NC}"

        if [ "$FULL_DUPLEX" -eq 1 ]; then
            local sm_label="$(onoff_label "$START_MUTED")"
            echo -e "  ${DIM}Start muted:          ${NC}${sm_label}"
        fi

        local audio_label
        if [ $IS_TERMUX -eq 1 ]; then
            audio_label="${WHITE}Termux${NC}"
        elif [ $IS_MACOS -eq 1 ]; then
            audio_label="${WHITE}ffmpeg (macOS)${NC}"
        elif [ -n "${ALSA_DEVICE:-}" ]; then
            audio_label="${WHITE}${ALSA_DEVICE}${ALSA_PLAY_DEVICE:+ → ${ALSA_PLAY_DEVICE}}${NC}"
        else
            audio_label="${DIM}auto-detect${NC}"
        fi
        echo -e "  ${DIM}Audio device:         ${NC}${audio_label}"
        echo ""

        echo -e "  ${BOLD}${WHITE}1${NC} ${CYAN}│${NC} Change Opus encoding quality"
        echo -e "  ${BOLD}${WHITE}2${NC} ${CYAN}│${NC} Auto-listen (listen for calls automatically at startup)"
        echo -e "  ${BOLD}${WHITE}3${NC} ${CYAN}│${NC} Change PTT (push-to-talk) key"
        if [ $IS_TERMUX -eq 1 ]; then
            echo -e "  ${BOLD}${WHITE}4${NC} ${CYAN}│${NC} Volume PTT ${DIM}(double-tap Vol Down to talk, experimental)${NC}"
        else
            echo -e "  ${BOLD}${WHITE}4${NC} ${CYAN}│${NC} PTT mode ${DIM}(hold-to-talk vs press-to-start/stop toggle)${NC}"
        fi
        echo -e "  ${BOLD}${WHITE}5${NC} ${CYAN}│${NC} Security"
        echo -e "  ${BOLD}${WHITE}6${NC} ${CYAN}│${NC} Normalize playback  ${DIM}(level all callers to the same volume)${NC}"
        echo -e "  ${BOLD}${WHITE}7${NC} ${CYAN}│${NC} Full-duplex audio  ${DIM}(live bidirectional, TCP backbone only)${NC}"
        if [ "$FULL_DUPLEX" -eq 1 ]; then
            echo -e "  ${BOLD}${WHITE}f${NC} ${CYAN}│${NC} Start muted  ${DIM}(begin full-duplex calls with mic muted)${NC}"
        fi
        echo -e "  ${BOLD}${WHITE}8${NC} ${CYAN}│${NC} Audio devices  ${DIM}(microphone, speakers, Bluetooth)${NC}"
        echo -e "  ${BOLD}${WHITE}0${NC} ${CYAN}│${NC} ${DIM}Back to main menu${NC}"
        echo ""
        echo -ne "  ${BOLD}Select: ${NC}"
        read -r schoice

        case "$schoice" in
            1) settings_opus ;;
            2)
                if [ "$AUTO_LISTEN" -eq 1 ]; then
                    AUTO_LISTEN=0
                    stop_auto_listener
                    log_ok "Auto-listen disabled"
                else
                    AUTO_LISTEN=1
                    log_ok "Auto-listen enabled"
                    start_auto_listener
                fi
                save_config
                sleep 1
                ;;
            3)
                local _pd="SPACE"
                [ "$PTT_KEY" != " " ] && _pd="$PTT_KEY"
                echo -e "\n  ${DIM}Current PTT key: ${NC}${WHITE}${_pd}${NC}"
                echo -ne "  ${BOLD}Press the key you want to use for PTT: ${NC}"
                # Read a single character in raw mode
                local _old_stty
                _old_stty=$(stty -g)
                stty raw -echo
                local _newkey
                _newkey=$(dd bs=1 count=1 2>/dev/null) || true
                stty "$_old_stty"
                if [ -n "$_newkey" ]; then
                    PTT_KEY="$_newkey"
                    save_config
                    local _nd="SPACE"
                    [ "$PTT_KEY" != " " ] && _nd="$PTT_KEY"
                    log_ok "PTT key set to: ${_nd}"
                fi
                sleep 1
                ;;
            4)
                if [ $IS_TERMUX -eq 1 ]; then
                    if [ "$VOL_PTT" -eq 1 ]; then
                        VOL_PTT=0
                        log_ok "Volume PTT disabled"
                    else
                        if ! check_dep jq; then
                            echo ""
                            if confirm_yes "  ${BOLD}jq is required for Volume PTT. Install now? [Y/n]: ${NC}"; then
                                pkg install -y jq 2>/dev/null || true
                                if ! check_dep jq; then
                                    log_err "jq installation failed — Volume PTT not enabled"
                                    sleep 2
                                    continue
                                fi
                            else
                                echo -e "\n  ${YELLOW}Volume PTT not enabled (jq not installed)${NC}"
                                sleep 2
                                continue
                            fi
                        fi
                        VOL_PTT=1
                        log_ok "Volume PTT enabled (double-tap Vol Down to toggle recording)"
                        echo -e "  ${DIM}Note: Each press will lower your device volume.${NC}"
                        echo -e "  ${DIM}You may want to start with volume at max.${NC}"
                    fi
                    save_config
                    sleep 2
                else
                    # Desktop: toggle between hold-to-talk and press-to-start/stop
                    local _pk="SPACE"
                    [ "$PTT_KEY" != " " ] && _pk="$PTT_KEY"
                    if [ "$PTT_TOGGLE_MODE" -eq 1 ]; then
                        PTT_TOGGLE_MODE=0
                        log_ok "PTT mode: hold-to-talk (hold ${_pk} to record)"
                    else
                        PTT_TOGGLE_MODE=1
                        log_ok "PTT mode: toggle (press ${_pk} to start, press again to stop)"
                    fi
                    save_config
                    sleep 1
                fi
                ;;
            5) settings_security ;;
            6)
                if [ "$NORMALIZE_PLAYBACK" -eq 1 ]; then
                    NORMALIZE_PLAYBACK=0
                    log_ok "Playback normalization disabled"
                else
                    ensure_pcm_rms
                    NORMALIZE_PLAYBACK=1
                    if command -v pcm_rms >/dev/null 2>&1; then
                        log_ok "Playback normalization enabled"
                    else
                        log_ok "Playback normalization enabled (pcm_rms unavailable, will skip)"
                    fi
                fi
                save_config; sleep 1
                ;;
            7)
                if [ "$FULL_DUPLEX" -eq 1 ]; then
                    FULL_DUPLEX=0
                    log_ok "Full-duplex disabled (PTT mode)"
                else
                    FULL_DUPLEX=1
                    log_ok "Full-duplex enabled (live bidirectional audio)"
                    echo -e "  ${YELLOW}Requires TCP-class transport (backbone hubs or LAN).${NC}"
                    echo -e "  ${YELLOW}LoRa and packet radio cannot sustain the bandwidth.${NC}"
                fi
                save_config; sleep 1
                ;;
            f|F)
                if [ "$FULL_DUPLEX" -ne 1 ]; then
                    echo -e "\n  ${RED}Enable full-duplex first (option 7).${NC}"
                    sleep 2
                    continue
                fi
                if [ "$START_MUTED" -eq 1 ]; then
                    START_MUTED=0
                    log_ok "Start muted disabled (mic will be live on join)"
                else
                    START_MUTED=1
                    log_ok "Start muted enabled (mic muted on join)"
                fi
                save_config; sleep 1
                ;;
            8) audio_menu ;;
            0|q|Q) return ;;
            *)
                menu_invalid
                ;;
        esac
    done
}

settings_cipher() {
    header "Select Encryption Cipher"
    echo -e "  ${DIM}Current: ${NC}${GREEN}${CIPHER}${NC}\n"

    # Curated cipher list ranked from strongest to adequate
    # Only includes ciphers verified to work with openssl enc -pbkdf2
    # Excludes: ECB modes (pattern leakage), DES/RC2/RC4/Blowfish (weak), aliases
    local ciphers=(
        # ── 256-bit (Strongest) ──
        "aes-256-ctr"
        "aes-256-cbc"
        "aes-256-cfb"
        "aes-256-ofb"
        "chacha20"
        "camellia-256-ctr"
        "camellia-256-cbc"
        "aria-256-ctr"
        "aria-256-cbc"
        # ── 192-bit (Strong) ──
        "aes-192-ctr"
        "aes-192-cbc"
        "camellia-192-ctr"
        "camellia-192-cbc"
        "aria-192-ctr"
        "aria-192-cbc"
        # ── 128-bit (Adequate) ──
        "aes-128-ctr"
        "aes-128-cbc"
        "camellia-128-ctr"
        "camellia-128-cbc"
        "aria-128-ctr"
        "aria-128-cbc"
    )

    local total=${#ciphers[@]}

    while true; do
        clear
        echo -e "\n${BOLD}${CYAN}═══ Available Ciphers ═══${NC}"
        echo -e "  ${DIM}Current: ${NC}${GREEN}${CIPHER}${NC}"
        echo -e "  ${DIM}${total} ciphers, ranked strongest → adequate${NC}\n"

        for ((i = 0; i < total; i++)); do
            local num=$((i + 1))
            local c="${ciphers[$i]}"

            # Print tier headers
            if [ $i -eq 0 ]; then
                echo -e "  ${GREEN}${BOLD}── 256-bit (Strongest) ──${NC}"
            elif [ $i -eq 9 ]; then
                echo -e "  ${YELLOW}${BOLD}── 192-bit (Strong) ──${NC}"
            elif [ $i -eq 15 ]; then
                echo -e "  ${WHITE}${BOLD}── 128-bit (Adequate) ──${NC}"
            fi

            if [ "$c" = "$CIPHER" ]; then
                printf "  ${GREEN}${BOLD}%4d${NC} ${CYAN}│${NC} ${GREEN}%-30s ◄ current${NC}\n" "$num" "$c"
            else
                printf "  ${WHITE}${BOLD}%4d${NC} ${CYAN}│${NC} %-30s\n" "$num" "$c"
            fi
        done

        echo ""
        echo -e "  ${DIM}[0] cancel${NC}"
        echo -ne "  ${BOLD}Enter cipher number: ${NC}"
        read -r cinput

        case "$cinput" in
            0|q|Q)
                return
                ;;
            '')
                ;;
            *)
                if [[ "$cinput" =~ ^[0-9]+$ ]] && [ "$cinput" -ge 1 ] && [ "$cinput" -le "$total" ]; then
                    local selected="${ciphers[$((cinput - 1))]}"
                    # Validate that openssl can actually use this cipher
                    if echo "test" | openssl enc -"${selected}" -pbkdf2 -pass pass:test 2>/dev/null | openssl enc -d -"${selected}" -pbkdf2 -pass pass:test &>/dev/null; then
                        CIPHER="$selected"
                        save_config
                        # Update runtime file for live mid-call sync
                        [ -f "$CIPHER_RUNTIME_FILE" ] && echo "$CIPHER" > "$CIPHER_RUNTIME_FILE"
                        # Notify remote side if in a call
                        if [ "$CALL_ACTIVE" -eq 1 ]; then
                            proto_send "CIPHER:${CIPHER}"
                        fi
                        echo -e "\n  ${GREEN}${BOLD}✓${NC} Cipher set to ${WHITE}${BOLD}${CIPHER}${NC}"
                    else
                        echo -e "\n  ${RED}${BOLD}✗${NC} Cipher '${selected}' failed validation — not compatible with stream encryption"
                    fi
                    pause
                    return
                else
                    echo -e "\n  ${RED}Invalid number${NC}"
                    sleep 1
                fi
                ;;
        esac
    done
}

settings_opus() {
    header "Opus Encoding Quality"
    echo -e "  ${DIM}Current bitrate: ${NC}${GREEN}${OPUS_BITRATE} kbps${NC}\n"

    local -a presets=(6 8 12 16 24 32 48 64)
    local -a labels=(
        "6 kbps  — Minimum (very low bandwidth)"
        "8 kbps  — Low (narrowband voice)"
        "12 kbps — Medium-Low (clear voice)"
        "16 kbps — Medium (recommended)"
        "24 kbps — Medium-High (good quality)"
        "32 kbps — High (wideband voice)"
        "48 kbps — Very High (near-studio)"
        "64 kbps — Maximum (best quality)"
    )

    for ((i = 0; i < ${#presets[@]}; i++)); do
        local num=$((i + 1))
        if [ "${presets[$i]}" = "$OPUS_BITRATE" ]; then
            echo -e "  ${GREEN}${BOLD}${num}${NC} ${CYAN}│${NC} ${GREEN}${labels[$i]} ◄ current${NC}"
        else
            echo -e "  ${BOLD}${WHITE}${num}${NC} ${CYAN}│${NC} ${labels[$i]}"
        fi
    done

    echo -e "  ${BOLD}${WHITE}9${NC} ${CYAN}│${NC} Custom bitrate"
    echo -e "  ${BOLD}${WHITE}0${NC} ${CYAN}│${NC} ${DIM}Cancel${NC}"
    echo ""
    echo -ne "  ${BOLD}Select: ${NC}"
    read -r oinput

    case "$oinput" in
        [1-8])
            OPUS_BITRATE=${presets[$((oinput - 1))]}
            save_config
            echo -e "\n  ${GREEN}${BOLD}✓${NC} Opus bitrate set to ${WHITE}${BOLD}${OPUS_BITRATE} kbps${NC}"
            ;;
        9)
            echo -ne "\n  ${BOLD}Enter bitrate (6-510 kbps): ${NC}"
            read -r custom_br
            if [[ "$custom_br" =~ ^[0-9]+$ ]] && [ "$custom_br" -ge 6 ] && [ "$custom_br" -le 510 ]; then
                OPUS_BITRATE=$custom_br
                save_config
                echo -e "\n  ${GREEN}${BOLD}✓${NC} Opus bitrate set to ${WHITE}${BOLD}${OPUS_BITRATE} kbps${NC}"
            else
                echo -e "\n  ${RED}Invalid bitrate. Must be 6–510.${NC}"
            fi
            ;;
        0|q|Q)
            return
            ;;
        *)
            echo -e "\n  ${RED}Invalid choice${NC}"
            ;;
    esac
    pause
}

toggle_setting_menu() {
    local var="$1" title="$2" noun="$3" on_log="$4" off_log="$5"
    local body_fn="$6" sleep_secs="$7" label_color="$8" after_fn="${9:-}"
    local _choice
    while true; do
        clear
        header "$title"

        echo -e "  ${DIM}Status:${NC} $(onoff_label "${!var}" "$label_color")"
        echo ""

        "$body_fn"

        echo -e "  ${BOLD}${WHITE}1${NC} ${CYAN}│${NC} Turn on"
        echo -e "  ${BOLD}${WHITE}2${NC} ${CYAN}│${NC} Turn off"
        echo -e "  ${BOLD}${WHITE}0${NC} ${CYAN}│${NC} ${DIM}Back${NC}"
        echo ""
        echo -ne "  ${BOLD}Select: ${NC}"
        read -r _choice

        case "$_choice" in
            1)
                if [ "${!var}" -eq 1 ]; then
                    log_info "$noun is already enabled"
                else
                    printf -v "$var" 1
                    save_config
                    log_ok "$on_log"
                    [ -n "$after_fn" ] && "$after_fn" 1
                fi
                sleep "$sleep_secs"
                ;;
            2)
                if [ "${!var}" -eq 0 ]; then
                    log_info "$noun is already disabled"
                else
                    printf -v "$var" 0
                    save_config
                    log_ok "$off_log"
                    [ -n "$after_fn" ] && "$after_fn" 0
                fi
                sleep "$sleep_secs"
                ;;
            0|q|Q) return ;;
            *)
                menu_invalid
                ;;
        esac
    done
}

_hmac_body() {
    echo -e "  ${DIM}When enabled, every message sent during a call (voice,${NC}"
    echo -e "  ${DIM}text, hangup, and all control signals) is signed with${NC}"
    echo -e "  ${DIM}HMAC-SHA256 derived from your shared secret.${NC}"
    echo ""
    echo -e "  ${DIM}A random nonce is included with each message so that${NC}"
    echo -e "  ${DIM}identical commands produce a unique signature every time.${NC}"
    echo -e "  ${DIM}This prevents replay attacks — a captured message cannot${NC}"
    echo -e "  ${DIM}be re-sent to disrupt future calls.${NC}"
    echo ""
    echo -e "  ${DIM}On the receiving end, any message with an invalid or${NC}"
    echo -e "  ${DIM}missing signature is silently dropped. An attacker who${NC}"
    echo -e "  ${DIM}compromises the relay but does not have the shared${NC}"
    echo -e "  ${DIM}secret cannot inject commands like HANGUP to disconnect${NC}"
    echo -e "  ${DIM}your call or forge audio and text messages.${NC}"
    echo ""
    echo -e "  ${YELLOW}Both ends must have HMAC set to the same value for calls to work.${NC}"
    echo ""
}

_hmac_after() {
    if [ "$CALL_ACTIVE" -eq 1 ]; then
        echo -e "  ${YELLOW}Takes effect on the next call.${NC}"
    fi
}

_owd_body() {
    echo -e "  ${DIM}When enabled, every temporary file (voice recordings,${NC}"
    echo -e "  ${DIM}Opus chunks, encrypted payloads, nonce logs) is overwritten${NC}"
    echo -e "  ${DIM}with random bytes from /dev/urandom before deletion.${NC}"
    echo ""
    echo -e "  ${YELLOW}Note: On SSDs with wear-leveling, overwriting does not${NC}"
    echo -e "  ${YELLOW}guarantee erasure of the original data blocks. Full-disk${NC}"
    echo -e "  ${YELLOW}encryption (LUKS, FileVault) is the only reliable defense.${NC}"
    echo ""
}

settings_security() {
    while true; do
        clear
        header "Security"

        local hmac_label="$(onoff_label "$HMAC_AUTH")"
        local owd_label="$(onoff_label "$OVERWRITE_DELETE")"
        local cipher_upper="$(to_upper "$CIPHER")"
        echo -e "  ${DIM}Cipher:            ${NC}${WHITE}${cipher_upper}${NC}"
        echo -e "  ${DIM}HMAC auth:         ${NC}${hmac_label}"
        echo -e "  ${DIM}Overwrite delete:  ${NC}${owd_label}"
        echo ""

        echo -e "  ${BOLD}${WHITE}1${NC} ${CYAN}│${NC} Change encryption cipher"
        echo -e "  ${BOLD}${WHITE}2${NC} ${CYAN}│${NC} HMAC authentication"
        echo -e "  ${BOLD}${WHITE}3${NC} ${CYAN}│${NC} Overwrite before delete"
        echo -e "  ${BOLD}${WHITE}0${NC} ${CYAN}│${NC} ${DIM}Back${NC}"
        echo ""
        echo -ne "  ${BOLD}Select: ${NC}"
        read -r _sec_choice

        case "$_sec_choice" in
            1) settings_cipher ;;
            2) settings_hmac ;;
            3) settings_overwrite_delete ;;
            0|q|Q) return ;;
            *)
                menu_invalid
                ;;
        esac
    done
}

settings_hmac() {
    toggle_setting_menu HMAC_AUTH "HMAC Authentication" "HMAC authentication" \
        "HMAC authentication enabled" "HMAC authentication disabled" \
        _hmac_body 1 "$GREEN" _hmac_after
}

settings_overwrite_delete() {
    toggle_setting_menu OVERWRITE_DELETE "Overwrite Before Delete" "Overwrite before delete" \
        "Overwrite before delete enabled" "Overwrite before delete disabled" \
        _owd_body 1 "$GREEN"
}

#=============================================================================
# MAIN MENU
#=============================================================================

show_banner() {
    clear
    echo ""
    echo -e "${BOLD}${RNS_PURPLE}  ╦═╗╔╗╔╔═╗  ╔═╗┌─┐┬─┐┌┬┐┬ ┬  ╦  ┬┌┐┌┌─┐${NC}"
    echo -e "${BOLD}${RNS_PURPLE}  ╠╦╝║║║╚═╗  ╠═╝├─┤├┬┘ │ └┬┘  ║  ││││├┤ ${NC}"
    echo -e "${BOLD}${RNS_PURPLE}  ╩╚═╝╚╝╚═╝  ╩  ┴ ┴┴└─ ┴  ┴   ╩═╝┴┘└┘└─┘${NC}"
    echo -e "  ${DIM}        Reticulum Network Stack${NC}"
    echo ""
    echo -e "  ${RNS_PURPLE}───────────────────────────────────────────${NC}"
    local cipher_display
    cipher_display="$(to_upper "$CIPHER")"
    echo -e "  ${DIM}v${VERSION} | Push-to-Talk | End-to-End ${cipher_display}${NC}\n"
    # Persistent root warning: PipeWire is user-session-only; running as root
    # means no sound server, so audio falls back to ALSA direct and hits EBUSY.
    if [ $DOCKER_MODE -eq 0 ] && [ "${EUID:-$(id -u)}" -eq 0 ]; then
        echo -e "  ${YELLOW}${BOLD}⚠  WARNING: running as root — audio will fail ('Device or resource busy')${NC}"
        echo -e "  ${YELLOW}   Fix: run without sudo  →  ./rns-party-line.sh${NC}"
        echo -e "  ${YELLOW}   (Option 9 installs packages — it handles sudo internally.)${NC}"
        echo ""
    fi
}

main_menu() {
    # Publish the address up front so the menu shows it on a cold start,
    # instead of "pending" until the user happens to pick listen or host.
    ensure_address || true
    while true; do
        show_banner

        # ── Status line ───────────────────────────────────────────────────────
        local rns_status secret_status al_status _ptt_d

        # Reticulum status: green if a destination hash is published (reflector
        # ran at least once), yellow otherwise. There is no persistent "up"
        # signal because the transport comes up on demand per role.
        if [ -f "$ONION_FILE" ]; then
            rns_status="${GREEN}●${NC}"
        else
            rns_status="${YELLOW}●${NC}"
        fi

        [ -n "$SHARED_SECRET" ] && secret_status="${GREEN}●${NC}" || secret_status="${RED}●${NC}"
        [ "$AUTO_LISTEN" -eq 1 ]       && al_status="${GREEN}●${NC}" || al_status="${RED}●${NC}"
        [ "$PTT_KEY" != " " ] && _ptt_d="$PTT_KEY" || _ptt_d="SPACE"

        # Show current Reticulum destination hash (pending until the first
        # reflector start writes it).
        local _addr; _addr=$(get_onion)
        if [ -n "$_addr" ]; then
            echo -e "  ${DIM}Address:${NC} ${WHITE}${_addr}${NC}"
        else
            echo -e "  ${DIM}Address:${NC} ${YELLOW}pending (start the relay to publish)${NC}"
        fi
        echo -e "  ${DIM}Secret:${NC} $secret_status  ${DIM}RNS:${NC} $rns_status  ${DIM}Auto-listen:${NC} $al_status  ${DIM}PTT:${NC} ${GREEN}[${_ptt_d}]${NC}"

        # ── Next-step hint: point new users at the one thing blocking a call ──
        if [ -z "$SHARED_SECRET" ]; then
            echo -e "  ${YELLOW}▸ Next step:${NC} press ${BOLD}${WHITE}1${NC} to set the shared secret ${DIM}(required before any call)${NC}"
        elif [ -z "$_addr" ]; then
            echo -e "  ${DIM}▸ Start the relay to publish your address (option 6).${NC}"
        else
            echo -e "  ${GREEN}▸ Ready.${NC} ${DIM}Press 4 to listen, or 5 to call.${NC}"
        fi
        echo ""

        # ── Menu options (ordered by the Secret → Audio → Connect dependency) ──
        echo -e "  ${BOLD}${CYAN}═══ SETUP ═══${NC}"
        if [ -z "$SHARED_SECRET" ]; then
            echo -e "  ${BOLD}${WHITE}1${NC} ${CYAN}│${NC} ${YELLOW}${BOLD}Set shared secret${NC}  ${YELLOW}← start here (required)${NC}"
        else
            echo -e "  ${BOLD}${WHITE}1${NC} ${CYAN}│${NC} Set shared secret  ${DIM}(both ends need the same secret)${NC}"
        fi
        echo -e "  ${BOLD}${WHITE}2${NC} ${CYAN}│${NC} Audio setup & test  ${DIM}(mic, speakers, diagnostics)${NC}"
        echo -e "  ${BOLD}${WHITE}3${NC} ${CYAN}│${NC} Share my address  ${DIM}(QR code)${NC}"
        echo -e "  ${DIM}  ─────────────────────────────────────${NC}"
        echo -e "  ${BOLD}${CYAN}═══ CALL ═══${NC}"
        echo -e "  ${BOLD}${WHITE}4${NC} ${CYAN}│${NC} Listen for calls"
        echo -e "  ${BOLD}${WHITE}5${NC} ${CYAN}│${NC} Call an address"
        echo -e "  ${BOLD}${WHITE}6${NC} ${CYAN}│${NC} Host party line  ${DIM}(relay / group bridge)${NC}"
        echo -e "  ${DIM}  ─────────────────────────────────────${NC}"
        echo -e "  ${BOLD}${CYAN}═══ SYSTEM ═══${NC}"
        echo -e "  ${BOLD}${WHITE}7${NC} ${CYAN}│${NC} Settings"
        echo -e "  ${BOLD}${WHITE}8${NC} ${CYAN}│${NC} Status"
        echo -e "  ${BOLD}${WHITE}n${NC} ${CYAN}│${NC} New identity  ${DIM}(rotate)${NC}"
        if [ $DOCKER_MODE -eq 0 ]; then
            echo -e "  ${DIM}  ─────────────────────────────────────${NC}"
            echo -e "  ${BOLD}${WHITE}9${NC} ${CYAN}│${NC} Install dependencies"
            echo -e "  ${BOLD}${WHITE}u${NC} ${CYAN}│${NC} Uninstall  ${DIM}(remove all data & packages)${NC}"
        fi
        echo -e "  ${DIM}  ─────────────────────────────────────${NC}"
        echo -e "  ${BOLD}${WHITE}0${NC} ${CYAN}│${NC} ${RED}Exit${NC}"
        echo ""

        # ── Input (polling so menu auto-redraws when address becomes ready) ────
        local choice=""
        local _was_ready=0
        [ -f "$ONION_FILE" ] && _was_ready=1

        if [ "$AUTO_LISTEN" -eq 1 ] && [ -n "$AUTO_LISTEN_PID" ]; then
            echo -ne "  ${BOLD}Select:${NC} ${DIM}[Auto-listening...]${NC} "
        else
            echo -ne "  ${BOLD}Select:${NC} "
        fi

        while true; do
            if [ "$AUTO_LISTEN" -eq 1 ] && [ -n "$AUTO_LISTEN_PID" ]; then
                if check_auto_listen; then
                    choice=""
                    break
                fi
            fi
            local _now_ready=0
            [ -f "$ONION_FILE" ] && _now_ready=1
            if [ "$_now_ready" -ne "$_was_ready" ]; then
                break
            fi
            if read -r -t 1 choice 2>/dev/null; then
                break
            fi
        done

        [ -z "$choice" ] && continue

        case "$choice" in
            4) listen_for_call ;;
            5) call_remote ;;
            6)
                relay_mode
                pause
                ;;
            1) set_shared_secret ;;
            7) settings_menu ;;
            3)
                # Show address and QR code
                local address; address=$(get_onion)
                if [ -n "$address" ]; then
                    echo -e "\n  ${BOLD}${GREEN}Your address:${NC} ${WHITE}${BOLD}${address}${NC}"
                    if [ -n "$RNS_HUBS" ]; then
                        echo -e "  ${DIM}Reachable over the Reticulum backbone: the address is all${NC}"
                        echo -e "  ${DIM}a caller needs.${NC}\n"
                    else
                        local _my_ip; _my_ip=$(_local_ip)
                        if [ -n "$_my_ip" ]; then
                            echo -e "  ${BOLD}${GREEN}Your host:${NC}    ${WHITE}${BOLD}${_my_ip}:${REFLECTOR_PORT}${NC}"
                            echo -e "  ${DIM}A direct caller needs BOTH.${NC}\n"
                        else
                            echo ""
                        fi
                    fi
                    if check_dep qrencode; then
                        if confirm_yes "  ${BOLD}Show QR code? [Y/n]: ${NC}"; then
                            tput smcup 2>/dev/null || true
                            clear
                            echo -e "\n  ${BOLD}${GREEN}Your address:${NC} ${WHITE}${BOLD}${address}${NC}\n"
                            qrencode -t ANSIUTF8 "$address"
                            echo ""
                            echo -e "  ${DIM}Note: Some QR scanners auto-prepend http:// — stripped when dialing.${NC}"
                            echo -ne "  ${DIM}Press Enter to dismiss...${NC}"
                            read -r
                            tput rmcup 2>/dev/null || true
                        fi
                    else
                        if [ $DOCKER_MODE -eq 0 ]; then
                            # Script mode: offer to install qrencode
                            if confirm_yes "  ${BOLD}Install qrencode to show QR? [Y/n]: ${NC}"; then
                                _pm_init
                                # Termux names it libqrencode; everyone else qrencode.
                                if [ -z "$PM" ]; then
                                    log_err "No supported package manager. Install qrencode manually."
                                elif [ "$PM" = "termux" ]; then
                                    pm_install libqrencode 2>/dev/null
                                else
                                    pm_install qrencode 2>/dev/null
                                fi
                                if check_dep qrencode; then
                                    log_ok "qrencode installed!"
                                    mkdir -p "$DATA_DIR"
                                    echo "qrencode" >> "$DATA_DIR/installed_packages"
                                    sort -u "$DATA_DIR/installed_packages" -o "$DATA_DIR/installed_packages" 2>/dev/null || true
                                    sleep 1
                                    tput smcup 2>/dev/null || true
                                    clear
                                    echo -e "\n  ${BOLD}${GREEN}Your address:${NC} ${WHITE}${BOLD}${address}${NC}\n"
                                    qrencode -t ANSIUTF8 "$address"
                                    echo ""
                                    echo -ne "  ${DIM}Press Enter to dismiss...${NC}"
                                    read -r
                                    tput rmcup 2>/dev/null || true
                                fi
                            fi
                        else
                            log_warn "qrencode not found — should be pre-installed in Docker image"
                        fi
                    fi
                else
                    echo -e "\n  ${YELLOW}No address yet — listen or host a party line first (option 4 or 6).${NC}\n"
                fi
                pause
                ;;
            2) audio_menu ;;
            8)
                show_status
                pause
                ;;
            9)
                if [ $DOCKER_MODE -eq 0 ]; then
                    install_deps
                    start_auto_listener
                fi
                pause
                ;;
            n|N)
                rotate_identity
                pause
                ;;
            u|U)
                if [ $DOCKER_MODE -eq 0 ]; then
                    uninstall_all
                    pause
                fi
                ;;
            0|q|Q)
                echo -e "\n${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                menu_invalid
                ;;
        esac
    done
}

#=============================================================================
# COMMAND-LINE INTERFACE
#=============================================================================
#
# The whole app is driveable from the command line — no menu required. A
# subcommand selects the action; flags (short -x and GNU long --xxx) override
# critical options. CLI flags win over both the built-in defaults and the saved
# config file, so they are stashed in _cli_* temporaries here and applied
# *after* load_config (which sources CONFIG_FILE and would otherwise clobber
# them). See apply_cli_overrides below.

# CLI state (globals consumed by the entry point)
CMD=""                  # subcommand: menu|listen|call|relay|status|test|install|uninstall|config
remote_address=""         # call target (also settable via -a/--address); call_remote normalizes it
CLI_SECRET=""
CLI_SECRET_SET=0
CLI_SAVE_SECRET=0
CLI_SAVE_CONFIG=0
# Option overrides — empty string means "not supplied on the command line"
_cli_cipher=""
_cli_bitrate=""
_cli_hmac=""
_cli_auto_listen=""

_cli_normalize=""
_cli_fullduplex=""
_cli_start_muted=""
_cli_dial_attempts=""
_cli_dial_timeout=""

print_cli_help() {
    cat <<EOF
$(echo -e "${BOLD}${APP_NAME} v${VERSION}${NC}") — Encrypted push-to-talk voice over Reticulum

$(echo -e "${BOLD}Usage:${NC}") $(basename "$0") [command] [options]

$(echo -e "${BOLD}Commands:${NC}")
  (none)        Launch the interactive menu (default)
  listen        Listen for an incoming call
  call [ADDR]   Call an address (ADDR also settable via -a; prompts if omitted)
  relay         Start a party line (group relay/bridge)
  status        Show address / transport / config status and exit
  test          Run the audio loopback test and exit
  config        Apply the given options, save them, print a summary, and exit
  install       Install dependencies (script mode only)
  uninstall     Remove all data & optionally uninstall packages
  help          Show this help

$(echo -e "${BOLD}Options:${NC}") $(echo -e "${DIM}(defaults in [brackets]; precedence: defaults < .env < saved config < flags)${NC}")
  -s, --secret S        Shared secret to use this run (must match all parties)
      --save-secret     Persist the --secret value to disk (plaintext, chmod 600)
  -a, --address ADDR    Relay address (32-char hex) to call
  -c, --cipher NAME     OpenSSL cipher (e.g. aes-256-cbc, chacha20)  [aes-256-cbc]
  -b, --bitrate N       Opus bitrate in kbps                    [16]
      --hmac            Sign all protocol messages with HMAC  (--no-hmac)        [on]
      --auto-listen     Auto-listen after startup             (--no-auto-listen) [off]

      --normalize      Level all callers to the same volume    (--no-normalize)[off]
      --full-duplex    Live bidirectional audio (TCP only)     (--no-full-duplex)[off]
      --start-muted    Begin full-duplex calls muted     (--no-start-muted)[on]
      --dial-attempts N Retry initial dial N times             [3]
      --dial-timeout N  Per-attempt connect timeout in seconds [60]
      --save            Persist all supplied options to the config file
  -h, --help            Show this help and exit
  -V, --version         Print version and exit

$(echo -e "${BOLD}Examples:${NC}")
  $(basename "$0") config --secret 'shhhsecretshere' --hmac --save
  $(basename "$0") relay  --secret 'shhhsecretshere'
  $(basename "$0") listen --secret 'shhhsecretshere'
  $(basename "$0") call 0123456789abcdef0123456789abcdef --secret 'shhhsecretshere'
  $(basename "$0") call --address 0123456789abcdef0123456789abcdef --secret 'shhhsecretshere'

$(echo -e "${BOLD}Docker:${NC}")
  docker compose run --rm partyline relay --secret 'shhhsecretshere'
  docker compose run --rm partyline listen --secret 'shhhsecretshere'
  docker compose up -d                       # persistent relay daemon
EOF
}

# Parse the command line into CMD + _cli_* / CLI_* globals.
# Supports: subcommands; --opt=value, --opt value, and -o value forms;
# --flag / --no-flag booleans. Exits for --help/--version and on usage errors.
parse_args() {
    while [ $# -gt 0 ]; do
        local arg="$1" val="" has_val=0
        # Split --opt=value form so the value travels with the option.
        case "$arg" in
            --*=*) val="${arg#*=}"; arg="${arg%%=*}"; has_val=1 ;;
        esac

        case "$arg" in
            menu|listen|call|relay|status|test|install|uninstall|config)
                if [ -z "$CMD" ]; then
                    CMD="$arg"
                elif [ "$CMD" = "call" ] && [ -z "$remote_address" ]; then
                    # Bare positional after `call` is the relay address.
                    remote_address="$arg"
                else
                    echo "Unexpected argument: $arg" >&2; exit 2
                fi
                ;;
            help|-h|--help)    print_cli_help; exit 0 ;;
            -V|--version)      echo -e "${APP_NAME} v${VERSION}"; exit 0 ;;

            # ── Options that take a value ──────────────────────────────────
            -s|--secret)       _cli_val "$arg" "$has_val" "$val" "$#" "${2:-}"; CLI_SECRET="$_cli_v"; CLI_SECRET_SET=1; [ "$has_val" = 1 ] || shift ;;
            -a|--address|--onion) _cli_val "$arg" "$has_val" "$val" "$#" "${2:-}"; remote_address="$_cli_v"; [ "$has_val" = 1 ] || shift ;;
            -c|--cipher)       _cli_val "$arg" "$has_val" "$val" "$#" "${2:-}"; _cli_cipher="$_cli_v"; [ "$has_val" = 1 ] || shift ;;
            -b|--bitrate)      _cli_val "$arg" "$has_val" "$val" "$#" "${2:-}"; _cli_bitrate="$_cli_v"; [ "$has_val" = 1 ] || shift ;;
            --dial-attempts)   _cli_val "$arg" "$has_val" "$val" "$#" "${2:-}"; _cli_dial_attempts="$_cli_v"; [ "$has_val" = 1 ] || shift ;;
            --dial-timeout)    _cli_val "$arg" "$has_val" "$val" "$#" "${2:-}"; _cli_dial_timeout="$_cli_v"; [ "$has_val" = 1 ] || shift ;;

            # ── Boolean flags (and their --no- negations) ─────────────────
            --save-secret)     CLI_SAVE_SECRET=1 ;;
            --save)            CLI_SAVE_CONFIG=1 ;;
            --hmac)            _cli_hmac=1 ;;        --no-hmac)         _cli_hmac=0 ;;
            --auto-listen)     _cli_auto_listen=1 ;;--no-auto-listen)  _cli_auto_listen=0 ;;

            --normalize)       _cli_normalize=1 ;; --no-normalize) _cli_normalize=0 ;;
            --full-duplex)     _cli_fullduplex=1 ;; --no-full-duplex) _cli_fullduplex=0 ;;
            --start-muted)     _cli_start_muted=1 ;; --no-start-muted) _cli_start_muted=0 ;;

            --) shift; break ;;
            -*) echo "Unknown option: $arg" >&2
                echo "Try '$(basename "$0") --help' for usage." >&2; exit 2 ;;
            *)  if [ "$CMD" = "call" ] && [ -z "$remote_address" ]; then
                    remote_address="$arg"
                else
                    echo "Unexpected argument: $arg" >&2; exit 2
                fi ;;
        esac
        shift
    done
}

# Resolve the value for a value-taking option into $_cli_v. With --opt=value the
# value is already split out ($has_val=1, no extra shift); otherwise it is the
# next argument and the caller shifts it (every value-taking arm ends with
# `[ "$has_val" = 1 ] || shift`). Errors out if no value is supplied.
_cli_v=""
_cli_val() {
    local opt="$1" has_val="$2" inline="$3" remaining="$4" next="$5"
    if [ "$has_val" = 1 ]; then
        _cli_v="$inline"                    # value came from --opt=value
    elif [ "$remaining" -ge 2 ]; then
        _cli_v="$next"                      # value is the next argument
    else
        echo "Option '$opt' requires a value." >&2
        echo "Try '$(basename "$0") --help' for usage." >&2
        exit 2
    fi
}

# Apply CLI option overrides on top of whatever load_config loaded.
apply_cli_overrides() {
    [ -n "$_cli_cipher" ]       && CIPHER="$_cli_cipher"
    [ -n "$_cli_bitrate" ]      && OPUS_BITRATE="$_cli_bitrate"
    [ -n "$_cli_hmac" ]         && HMAC_AUTH="$_cli_hmac"
    [ -n "$_cli_auto_listen" ]  && AUTO_LISTEN="$_cli_auto_listen"

    [ -n "$_cli_normalize" ]    && NORMALIZE_PLAYBACK="$_cli_normalize"
    [ -n "$_cli_fullduplex" ]   && FULL_DUPLEX="$_cli_fullduplex"
    [ -n "$_cli_start_muted" ]  && START_MUTED="$_cli_start_muted"
    [ -n "$_cli_dial_attempts" ] && DIAL_ATTEMPTS="$_cli_dial_attempts"
    [ -n "$_cli_dial_timeout" ]  && DIAL_TIMEOUT="$_cli_dial_timeout"
    if [ "$CLI_SECRET_SET" -eq 1 ]; then
        SHARED_SECRET="$CLI_SECRET"
    fi
    return 0
}

#=============================================================================
# ENTRY POINT
#=============================================================================

# Allow sourcing from test suite without executing main entry point.
# When sourced (e.g. source /rns-party-line.sh in tests), return 0 here so the
# trap, load_config, and main_menu below are never reached.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] || return 0

# Parse the command line first. --help / --version / usage errors exit here,
# before any Tor, dependency, or filesystem machinery runs.
parse_args "$@"

trap cleanup EXIT INT TERM

# Auto-fix root-owned data directories (Docker creates ./data/ as root when it
# bind-mounts ./data/docker/... volumes before the script has ever run).
_fix_owner() {
    local _d="$1"
    log_warn "Fixing root-owned directory: $_d"
    if sudo chown "$(id -u):$(id -g)" "$_d" 2>/dev/null; then
        log_ok "Fixed: $_d"
    else
        log_err "Could not fix: $_d — run: sudo chown $(id -un):$(id -gn) \"$_d\""
        exit 1
    fi
}
_data_parent="$(dirname "$DATA_DIR")"
[ -d "$_data_parent" ] && [ ! -w "$_data_parent" ] && _fix_owner "$_data_parent"
[ -d "$DATA_DIR"     ] && [ ! -w "$DATA_DIR"     ] && _fix_owner "$DATA_DIR"

# Create the persistent DATA_DIR and the ephemeral RUNTIME_DIR (PLAN §20.6).
# RUNTIME_DIR lives on tmpfs and is fresh each launch, so no cleanup of a
# previous session's run files is needed.
mkdir -p "$DATA_DIR" "$RUNTIME_DIR" "$AUDIO_DIR" "$PID_DIR" "$RUNTIME_DIR/run" "$RUNTIME_DIR/relay"

# A CLI-provided secret means we must not block on the interactive passphrase
# prompt inside load_config — the CLI value overrides the stored one anyway.
[ "$CLI_SECRET_SET" -eq 1 ] && SKIP_SECRET_PROMPT=1

# Load saved config, then let CLI flags win over it.
load_config
apply_cli_overrides

[ "$NORMALIZE_PLAYBACK" -eq 1 ] && ensure_pcm_rms

# Persist the secret if requested (or implicitly by the `config` command).
if { [ "$CLI_SAVE_SECRET" -eq 1 ] || [ "$CMD" = "config" ]; } && [ "$CLI_SECRET_SET" -eq 1 ]; then
    mkdir -p "$DATA_DIR"
    printf '%s' "$SHARED_SECRET" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    log_ok "Shared secret saved"
fi

# Persist config options if requested (or implicitly by the `config` command).
if [ "$CLI_SAVE_CONFIG" -eq 1 ] || [ "$CMD" = "config" ]; then
    save_config
    log_ok "Configuration saved"
fi

# `config` only mutates settings — print a summary and exit before audio.
if [ "$CMD" = "config" ]; then
    echo -e "\n${BOLD}${CYAN}═══ Current configuration ═══${NC}"
    echo -e "  Shared secret  : $([ -n "$SHARED_SECRET" ] && echo set || echo '(none)')"
    echo -e "  Backbone hubs  : ${RNS_HUBS:-(none)}"
    echo -e "  Autoconnect    : ${RNS_AUTOCONNECT}"
    echo -e "  Reflector host : ${REFLECTOR_HOST:-(unset)}"
    echo -e "  Reflector port : ${REFLECTOR_PORT}"
    echo -e "  Cipher         : $CIPHER"
    echo -e "  Opus bitrate   : ${OPUS_BITRATE} kbps"
    echo -e "  HMAC auth      : $HMAC_AUTH"
    echo -e "  Auto-listen    : $AUTO_LISTEN"

    echo -e "  Normalize      : $NORMALIZE_PLAYBACK"
    echo -e "  Full-duplex    : $FULL_DUPLEX"
    echo -e "  Start muted    : $START_MUTED"
    echo ""
    exit 0
fi

# First-run: if any critical dep is missing, offer to install before continuing.
if [ $DOCKER_MODE -eq 0 ]; then
    _missing_critical=0
    for _d in opusenc opusdec socat openssl python3; do
        check_dep "$_d" || { _missing_critical=1; break; }
    done
    # Probe the interpreter the bridge will actually launch, not a hardcoded
    # python3: once install_rns has built the venv, RNS is importable there and
    # nowhere else, and checking python3 would re-prompt forever.
    if ! "$BRIDGE_PYTHON" -c 'import RNS' 2>/dev/null; then
        _missing_critical=1
    fi
    if [ $_missing_critical -eq 1 ]; then
        echo -e "\n${YELLOW}${BOLD}First run — some dependencies are missing.${NC}"
        echo -e "${DIM}Required: opus-tools, socat, openssl, python3, RNS${NC}"
        echo -e "${DIM}RNS is installed into a private venv at ${PL_VENV}${NC}"
        echo -e "${DIM}Optional: lxmf, enables backbone peer discovery${NC}\n"
        if confirm_yes "${BOLD}Install dependencies now? [Y/n]: ${NC}"; then
            install_deps
        fi
    fi
fi

# start_auto_listener no-ops unless AUTO_LISTEN=1. It used to require Tor to
# be up; in Reticulum mode we just call it and let it decide.
start_auto_listener

# Dispatch the selected command.
case "$CMD" in
    install)
        [ $DOCKER_MODE -eq 0 ] && install_deps || echo "Deps pre-installed in Docker image."
        ;;
    uninstall) uninstall_all ;;
    test)      test_audio ;;
    status)    show_status ;;
    listen)    listen_for_call ;;
    call)      call_remote ;;   # call_remote prompts for / normalizes the address
    relay)     relay_mode ;;
    menu)      main_menu ;;
    "")
        # In Docker mode, no TTY means we're running detached (docker compose up -d) → relay.
        # docker compose run --rm partyline (interactive) auto-allocates a TTY, so [ -t 0 ] is true there.
        if [ "$DOCKER_MODE" -eq 1 ] && [ ! -t 0 ]; then
            CMD="relay"
            relay_mode
        else
            main_menu
        fi
        ;;
    *)         main_menu ;;
esac
