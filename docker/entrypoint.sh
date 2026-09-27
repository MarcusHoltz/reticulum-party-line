#!/bin/bash
# Audio bring-up for containers.
#
# A container has no sound hardware. There are exactly two ways for it to make
# a sound you can hear, and both come from the host:
#   1. the host's PulseAudio / pipewire-pulse socket, bind-mounted by compose
#      at $XDG_RUNTIME_DIR/pulse and selected via PULSE_SERVER, or
#   2. /dev/snd passed through for bare-ALSA hosts (commented out in compose).
# Anything a container starts for itself can only reach a null sink, which is
# inaudible by construction. So: if a host server is reachable, use it verbatim
# and touch nothing.

# Fix bind-mount ownership on first run (Docker creates host dirs as root),
# then drop to the unprivileged partyline user for everything that follows.
if [ "$(id -u)" = "0" ]; then
    chown partyline:partyline /app/data 2>/dev/null || true
    exec setpriv --reuid=partyline --regid=partyline \
         --init-groups "$0" "$@"
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true

if pactl info >/dev/null 2>&1; then
    # Talking to the host's server. Do NOT load a null sink or call
    # set-default-sink here: those commands would run against the HOST server
    # and repoint the user's desktop audio at a black hole.
    exec "$@"
fi

# No server reachable: no socket mounted, or the host runs bare ALSA. Fall back
# to a throwaway local PulseAudio with a null sink so rns-party-line.sh's backend
# detection (detect_audio_backend) finds something to talk to instead of
# aborting with "no working audio backend found". Nothing played through this
# is audible - it exists so headless runs (CI, relay-only) don't error out.
unset PULSE_SERVER

pulseaudio --start --exit-idle-time=-1 --disallow-exit=1 \
    --log-target=stderr >/tmp/pulseaudio.log 2>&1 || true

for _ in $(seq 1 50); do
    pactl info >/dev/null 2>&1 && break
    sleep 0.1
done

pactl load-module module-null-sink sink_name=partyline_null \
    sink_properties=device.description=PartylineVirtual >/dev/null 2>&1 || true
pactl set-default-sink partyline_null >/dev/null 2>&1 || true
pactl set-default-source partyline_null.monitor >/dev/null 2>&1 || true

exec "$@"
