#!/usr/bin/env bash
# shellcheck disable=SC2059  # ANSI colour vars in printf format strings are intentional
# Dad Joke Greeter setup helper
#
# Validates prerequisites and walks you through the one-time audio setup
# so remote Tuple participants can hear the jokes.
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

pass() { printf "${GREEN}  ✓ %s${RESET}\n" "$1"; }
fail() { printf "${RED}  ✗ %s${RESET}\n" "$1"; }
warn() { printf "${YELLOW}  ! %s${RESET}\n" "$1"; }
step() { printf "\n${BOLD}%s${RESET}\n" "$1"; }

errors=0

# ── Prerequisites ──────────────────────────────────────────────────────

step "Checking prerequisites..."

# macOS command-line tools used at runtime.
for cmd in bash curl sleep say; do
  if command -v "$cmd" &>/dev/null; then
    pass "$cmd found ($(command -v "$cmd"))"
  else
    fail "$cmd not found"
    errors=$((errors + 1))
  fi
done

# Snapshot the audio device list once; system_profiler is slow (several
# seconds per call). Re-queried only after the user creates a new device.
audio_data="$(system_profiler SPAudioDataType 2>/dev/null)"

# BlackHole 2ch
if grep -q "BlackHole 2ch" <<<"$audio_data"; then
  pass "BlackHole 2ch installed"
else
  fail "BlackHole 2ch not found. Install with: brew install blackhole-2ch"
  errors=$((errors + 1))
  warn "If you just installed BlackHole, you may need to restart your Mac (or log out"
  warn "and back in) before it appears as an audio device. Then re-run this script."
fi

if [[ "$errors" -gt 0 ]]; then
  printf "\n${RED}Fix the issues above and re-run this script.${RESET}\n"
  exit 1
fi

# ── Trigger launchers ──────────────────────────────────────────────────
# The room-joined/room-left scripts are bash launchers. Make sure they are
# executable in case the exec bit was lost in transit (e.g. an unzip or a copy
# across filesystems).

step "Checking trigger launchers..."

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for launcher in run-trigger.sh room-joined room-left; do
  target="$script_dir/$launcher"
  if [[ -f "$target" ]]; then
    chmod +x "$target"
    pass "$launcher is executable"
  else
    fail "$launcher is missing"
    errors=$((errors + 1))
  fi
done

if [[ "$errors" -gt 0 ]]; then
  printf "\n${RED}Fix the issues above and re-run this script.${RESET}\n"
  exit 1
fi

# ── Aggregate audio device ─────────────────────────────────────────────

step "Checking for aggregate audio device..."

DEVICE_NAME="BH + Mic Input"

if grep -qi "$DEVICE_NAME" <<<"$audio_data"; then
  pass "\"$DEVICE_NAME\" aggregate device exists"
else
  warn "\"$DEVICE_NAME\" not found. Let's create it"

  # List available microphones with channel counts. This trigger needs a MONO
  # mic: in the aggregate, a 1-channel mic puts BlackHole on channel 2 (which
  # Tuple transmits), while a stereo mic pushes it to channels 3-4 (which Tuple
  # ignores). See the README's "Use a mono microphone" note.
  printf "\n${BOLD}Available microphones${RESET} (this trigger needs a ${GREEN}mono${RESET} mic):\n"
  mics=()
  mic_channels=()
  while IFS=$'\t' read -r mic ch; do
    # Skip BlackHole, aggregate, and Zoom virtual devices
    case "$mic" in
      *BlackHole*|*"$DEVICE_NAME"*|*"Dad Joke Input"*|*ZoomAudio*) continue ;;
    esac
    mics+=("$mic")
    mic_channels+=("$ch")
    if [[ "$ch" == "1" ]]; then
      printf "  ${GREEN}%d)${RESET} %s ${GREEN}(mono - recommended)${RESET}\n" "${#mics[@]}" "$mic"
    else
      printf "  ${YELLOW}%d)${RESET} %s ${YELLOW}(%s-channel - not supported)${RESET}\n" "${#mics[@]}" "$mic" "$ch"
    fi
  done < <(
    printf '%s\n' "$audio_data" | awk '
      /^        [^ ].*:$/ { name = $0; gsub(/^ +| +$/, "", name); sub(/:$/, "", name); next }
      /^          Input Channels:/ { print name "\t" $NF }
    '
  )

  if [[ ${#mics[@]} -eq 0 ]]; then
    fail "No microphones found"
    errors=$((errors + 1))
  else
    printf "\n"
    mic_choice=""
    mic_choice_channels=""
    while [[ -z "$mic_choice" ]]; do
      read -rp "Select your microphone [1-${#mics[@]}]: " pick
      if [[ "$pick" =~ ^[0-9]+$ ]] && [[ "$pick" -ge 1 ]] && [[ "$pick" -le ${#mics[@]} ]]; then
        candidate="${mics[$((pick - 1))]}"
        read -rp "Use \"$candidate\"? [Y/n] " confirm
        if [[ -z "$confirm" || "$confirm" =~ ^[Yy] ]]; then
          mic_choice="$candidate"
          mic_choice_channels="${mic_channels[$((pick - 1))]}"
        fi
      else
        printf "  ${RED}Invalid choice. Enter a number between 1 and %d.${RESET}\n" "${#mics[@]}"
      fi
    done
    pass "Using microphone: \"$mic_choice\""
    if [[ "$mic_choice_channels" != "1" ]]; then
      warn "\"$mic_choice\" is ${mic_choice_channels}-channel, not mono. The joke audio will land"
      warn "on channels Tuple does not transmit, so the room won't hear it. A mono mic (e.g."
      warn "the built-in MacBook microphone) is recommended. Continuing, but expect silence."
    fi
  fi

  read -rp "Press Enter to open Audio MIDI Setup (instructions will follow)..."
  open -a "Audio MIDI Setup"

  printf "\n${BOLD}Follow these steps in Audio MIDI Setup:${RESET}\n"
  printf "\n"
  printf "  1. Click the ${BOLD}+${RESET} button (bottom-left) → ${BOLD}Create Aggregate Device${RESET}\n"
  printf "  2. Rename it to ${BOLD}\"$DEVICE_NAME\"${RESET}\n"
  printf "  3. Check ${BOLD}\"%s\" FIRST${RESET} (must be a ${BOLD}mono${RESET} mic)\n" "${mic_choice:-the built-in MacBook microphone}"
  printf "  4. Check ${BOLD}\"BlackHole 2ch\" SECOND${RESET}\n"
  printf "  5. Enable ${BOLD}Drift Correction${RESET} on the BlackHole 2ch row\n"
  printf "  6. Set ${BOLD}Clock Source${RESET} to ${BOLD}\"%s\"${RESET}\n" "${mic_choice:-your built-in microphone}"
  printf "\n"
  printf "  ${YELLOW}Order matters!${RESET} The mic must be added first and used as the\n"
  printf "  clock source. BlackHole needs drift correction enabled because\n"
  printf "  it runs on a virtual clock that can drift from the hardware mic.\n"
  printf "\n"

  read -rp "Press Enter once you've created the device..."

  # The device list changed (user just created one), so re-query.
  audio_data="$(system_profiler SPAudioDataType 2>/dev/null)"
  if grep -qi "$DEVICE_NAME" <<<"$audio_data"; then
    pass "\"$DEVICE_NAME\" created successfully"

    # Verify the channel layout. A mono mic (1ch) + BlackHole 2ch = 3 input
    # channels, putting the joke on channel 2 - inside the pair Tuple sends. A
    # stereo mic yields 4+ channels and the joke never reaches the room.
    agg_channels="$(
      printf '%s\n' "$audio_data" | awk -v target="        ${DEVICE_NAME}:" '
        $0 == target { in_device = 1; next }
        in_device && /^          Input Channels:/ { print $NF; exit }
        in_device && /^        [^ ]/ { in_device = 0 }
      '
    )"
    if [[ "$agg_channels" =~ ^[0-9]+$ ]] && [[ "$agg_channels" -ne 3 ]]; then
      warn "\"$DEVICE_NAME\" has $agg_channels input channels; a working setup has 3 (a mono"
      warn "mic + BlackHole 2ch). Your mic is likely stereo, so the joke lands on channels"
      warn "Tuple doesn't transmit. Rebuild the aggregate with a mono mic (e.g. the built-in"
      warn "MacBook microphone) - see the README's \"Use a mono microphone\" note."
    elif [[ "$agg_channels" == "3" ]]; then
      pass "Channel layout looks right (mono mic + BlackHole) - the room will hear jokes"
    fi
  else
    fail "The device \"$DEVICE_NAME\" was not found."
    warn "Make sure you: (1) created it in Audio MIDI Setup, (2) named it exactly"
    warn "\"$DEVICE_NAME\", (3) clicked Done and closed the dialog."
    errors=$((errors + 1))
  fi
fi

# ── Tuple audio input ──────────────────────────────────────────────────

step "Tuple configuration..."

printf "\n  Set Tuple's audio input to the aggregate device:\n"
printf "  ${BOLD}Tuple → Preferences → Audio → Input Device → \"$DEVICE_NAME\"${RESET}\n\n"
read -rp "Press Enter once configured (or if already done)..."

# ── API test ───────────────────────────────────────────────────────────

step "Testing joke API..."

joke="$(
  curl -fsS --max-time 5 \
    -H "Accept: text/plain" \
    -H "User-Agent: TupleDadJokeGreeter/3.0" \
    "https://icanhazdadjoke.com/" \
    | tr '\r\n' '  ' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
)"

if [[ -n "$joke" ]]; then
  pass "API working"
  printf "  ${BOLD}Sample joke:${RESET} %s\n" "$joke"
else
  fail "Could not fetch a joke. Check your internet connection"
  errors=$((errors + 1))
fi

# ── Summary ────────────────────────────────────────────────────────────

step "Setup summary"

if [[ "$errors" -gt 0 ]]; then
  printf "\n${RED}Setup incomplete. Fix the issues above and re-run.${RESET}\n"
  exit 1
else
  printf "\n${GREEN}All good! Dad jokes are ready to roll.${RESET}\n"
  printf "  Join a tracked Tuple room. A dad joke will play after 5 quiet seconds.\n"
fi
