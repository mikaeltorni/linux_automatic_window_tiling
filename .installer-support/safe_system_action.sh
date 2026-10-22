#!/usr/bin/env bash
# Guard reboot and poweroff behind an audible, abortable ten-second countdown.
#
# Usage: safe_system_action.sh reboot|poweroff
# Ctrl+C or SIGTERM during the countdown exits without invoking the action.

set -euo pipefail

action="${1:-}"
case "$action" in
  reboot) action_command=(systemctl reboot); action_label="Rebooting" ;;
  poweroff) action_command=(systemctl poweroff); action_label="Powering off" ;;
  *) printf 'Usage: %s reboot|poweroff\n' "$0" >&2; exit 2 ;;
esac

find_beep_file() {
  local script_dir candidate
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for candidate in \
    "${SAFE_SYSTEM_ACTION_BEEP_FILE:-}" \
    "$script_dir/../phrase_automation/sounds/command.mp3" \
    "${HOME:-}/projects/phrase_automation/sounds/command.mp3"; do
    [[ -n "$candidate" && -f "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# find_audio_user - resolve the desktop user whose audio session should play
# the beep when this script runs as root.
#
# Root has no PipeWire/PulseAudio session of its own, so ffplay run directly
# as root fails silently and the countdown becomes mute. Prefer the explicit
# TARGET_USER the framework already uses, then the sudo invoker, then the
# owner of the first live /run/user/<uid> runtime directory.
#
# Outputs:
#   0; prints "<user>:<uid>" on stdout, or returns 1 when none is found.
find_audio_user() {
  local candidate uid runtime_dir
  for candidate in "${TARGET_USER:-}" "${SUDO_USER:-}"; do
    [[ -n "$candidate" && "$candidate" != "root" ]] || continue
    uid="$(id -u "$candidate" 2>/dev/null)" || continue
    [[ -d "/run/user/$uid" ]] || continue
    printf '%s:%s' "$candidate" "$uid"
    return 0
  done
  for runtime_dir in /run/user/*; do
    [[ -d "$runtime_dir" ]] || continue
    uid="${runtime_dir##*/}"
    [[ "$uid" =~ ^[0-9]+$ && "$uid" -ne 0 ]] || continue
    candidate="$(id -un "$uid" 2>/dev/null)" || continue
    printf '%s:%s' "$candidate" "$uid"
    return 0
  done
  return 1
}

beep_file="$(find_beep_file || true)"
beep_pid=""
audio_user=""
audio_uid=""
if [[ "$(id -u)" -eq 0 ]]; then
  if audio_spec="$(find_audio_user)"; then
    audio_user="${audio_spec%%:*}"
    audio_uid="${audio_spec##*:}"
  fi
fi

play_beep() {
  if [[ -n "$beep_file" ]] && command -v ffplay >/dev/null 2>&1; then
    if [[ -n "$audio_user" ]]; then
      # Run the player inside the desktop user's audio session; root itself
      # has no PipeWire/PulseAudio server, so playing directly would be mute.
      sudo -u "$audio_user" \
        XDG_RUNTIME_DIR="/run/user/$audio_uid" \
        PULSE_SERVER="unix:/run/user/$audio_uid/pulse/native" \
        ffplay -nodisp -autoexit -loglevel quiet "$beep_file" \
        </dev/null >/dev/null 2>&1 &
      beep_pid=$!
    else
      ffplay -nodisp -autoexit -loglevel quiet "$beep_file" </dev/null >/dev/null 2>&1 &
      beep_pid=$!
    fi
  else
    printf '\a' >&2
  fi
}

cancel_action() {
  [[ -n "$beep_pid" ]] && kill "$beep_pid" 2>/dev/null || true
  printf '\n%s cancelled; no system action was requested.\n' "$action_label" >&2
  exit 130
}
trap 'cancel_action' INT TERM

printf '%s in 10 seconds. Press Ctrl+C to cancel.\n' "$action_label"
for second in {10..1}; do
  printf '%s\n' "$second"
  play_beep
  sleep 1
done

printf "0 %s\n" "$action_label"
for _ in 1 2 3 4; do
  play_beep
  sleep 0.16
done

trap - INT TERM
exec "${action_command[@]}"
