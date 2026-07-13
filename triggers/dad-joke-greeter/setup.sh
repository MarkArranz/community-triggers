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
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Configuration ──────────────────────────────────────────────────────
# Source config.env exactly as run-trigger.sh does, so the checks below see
# the same configuration the trigger runs with.

config_env_file="${script_dir}/config.env"
if [[ -f "$config_env_file" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$config_env_file"
  set +a
fi

blackhole_device="${BLACKHOLE_DEVICE:-BlackHole 2ch}"
tts_backend="${DAD_JOKE_TTS_BACKEND:-say}"
aggregate_device_name="BH + Mic Input"
micpipe_min_version="0.2.0"

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
# seconds per call).
audio_data="$(system_profiler SPAudioDataType 2>/dev/null)"

if grep -q "$blackhole_device" <<<"$audio_data"; then
  pass "$blackhole_device installed"
else
  fail "$blackhole_device not found. Install with: brew install blackhole-2ch"
  errors=$((errors + 1))
  warn "If you just installed BlackHole, you may need to restart your Mac (or log out"
  warn "and back in) before it appears as an audio device. Then re-run this script."
fi

if [[ "$errors" -gt 0 ]]; then
  printf "\n${RED}Fix the issues above and re-run this script.${RESET}\n"
  exit 1
fi

# ── Trigger launchers ──────────────────────────────────────────────────
# The event scripts are bash launchers. Make sure they are executable in case
# the exec bit was lost in transit (e.g. an unzip or a copy across filesystems).

step "Checking trigger launchers..."

for launcher in run-trigger.sh room-joined room-left call-ended; do
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

# ── Audio routing ──────────────────────────────────────────────────────
# Preferred: micpipe (https://github.com/markarranz/micpipe) streams your mic
# into BlackHole so Tuple can use BlackHole directly as its input device.
# Alternative: a hand-built aggregate device (see the README appendix).

step "Checking audio routing..."

tuple_input_device=""

if command -v micpipe &>/dev/null; then
  pass "micpipe found ($(command -v micpipe))"

  micpipe_version="$(micpipe --version 2>/dev/null | awk '{print $2}')"
  if [[ -z "$micpipe_version" ]]; then
    warn "Could not parse 'micpipe --version'; continuing, but ${micpipe_min_version}+ is expected"
  else
    lowest="$(printf '%s\n%s\n' "$micpipe_version" "$micpipe_min_version" | sort -V | head -1)"
    if [[ "$lowest" != "$micpipe_min_version" ]]; then
      fail "micpipe ${micpipe_version} is older than ${micpipe_min_version}. Upgrade with: cargo install micpipe --force"
      warn "(${micpipe_version} has a launchd plist bug and does not follow default-input changes.)"
      errors=$((errors + 1))
    else
      pass "micpipe ${micpipe_version} (>= ${micpipe_min_version})"
    fi
  fi

  if micpipe status 2>/dev/null | grep -q "^running ("; then
    pass "micpipe service is running"
  else
    warn "micpipe service is not running"
    read -rp "Run 'micpipe install' to start it now? [Y/n] " answer
    if [[ -z "$answer" || "$answer" =~ ^[Yy] ]]; then
      micpipe install
      if micpipe status 2>/dev/null | grep -q "^running ("; then
        pass "micpipe service is running"
      else
        fail "micpipe service still not running. If BlackHole was just installed, try: micpipe restart"
        warn "Logs: ~/.local/share/micpipe/out.log and ~/.local/share/micpipe/err.log"
        errors=$((errors + 1))
      fi
    else
      fail "micpipe service not running; start it with: micpipe install"
      errors=$((errors + 1))
    fi
  fi

  if grep -qi "$aggregate_device_name" <<<"$audio_data"; then
    warn "The \"$aggregate_device_name\" aggregate device from an earlier setup still exists."
    warn "If Tuple still uses it as input while micpipe runs, your mic is sent twice"
    warn "(direct + BlackHole copy) and remote participants hear an echo. Delete it in"
    warn "Audio MIDI Setup and set Tuple's input to \"$blackhole_device\" instead."
  fi

  tuple_input_device="$blackhole_device"
elif grep -qi "$aggregate_device_name" <<<"$audio_data"; then
  pass "\"$aggregate_device_name\" aggregate device exists (manual alternative to micpipe)"

  # Verify the channel layout. A mono mic (1ch) + BlackHole 2ch = 3 input
  # channels, putting the joke on channel 2 - inside the pair Tuple sends. A
  # stereo mic yields 4+ channels and the joke never reaches the room.
  agg_channels="$(
    printf '%s\n' "$audio_data" | awk -v target="        ${aggregate_device_name}:" '
      $0 == target { in_device = 1; next }
      in_device && /^          Input Channels:/ { print $NF; exit }
      in_device && /^        [^ ]/ { in_device = 0 }
    '
  )"
  if [[ "$agg_channels" =~ ^[0-9]+$ ]] && [[ "$agg_channels" -ne 3 ]]; then
    warn "\"$aggregate_device_name\" has $agg_channels input channels; a working setup has 3 (a mono"
    warn "mic + BlackHole 2ch). Your mic is likely stereo, so the joke lands on channels"
    warn "Tuple doesn't transmit. Rebuild the aggregate with a mono mic (e.g. the built-in"
    warn "MacBook microphone) - see the README appendix."
  elif [[ "$agg_channels" == "3" ]]; then
    pass "Channel layout looks right (mono mic + BlackHole) - the room will hear jokes"
  else
    warn "Could not determine \"$aggregate_device_name\" channel layout; verify manually that it"
    warn "shows 3 input channels (mono mic + BlackHole 2ch) in Audio MIDI Setup."
  fi

  tuple_input_device="$aggregate_device_name"
else
  fail "No audio route found: micpipe is not installed and no \"$aggregate_device_name\" aggregate device exists."
  if command -v cargo &>/dev/null; then
    warn "Recommended: cargo install micpipe   (then re-run this script)"
  else
    warn "Recommended: install Rust via https://rustup.rs, then: cargo install micpipe"
  fi
  warn "No Rust toolchain? Create the aggregate device by hand instead - see the"
  warn "README appendix \"Alternative: aggregate device\"."
  errors=$((errors + 1))
fi

if [[ "$errors" -gt 0 ]]; then
  printf "\n${RED}Fix the issues above and re-run this script.${RESET}\n"
  exit 1
fi

# ── TTS backend ────────────────────────────────────────────────────────

step "Checking TTS backend (${tts_backend})..."

case "$tts_backend" in
  elevenlabs|api|http)
    for cmd in afplay ffmpeg; do
      if command -v "$cmd" &>/dev/null; then
        pass "$cmd found ($(command -v "$cmd"))"
      else
        fail "$cmd not found; the ${tts_backend} backend needs it. Install with: brew install ffmpeg"
        errors=$((errors + 1))
      fi
    done
    ;;
  *)
    pass "Backend 'say' needs no extra tools (ffmpeg is only needed for API TTS backends)"
    ;;
esac

if [[ -f "$config_env_file" ]]; then
  config_mode="$(stat -f '%Lp' "$config_env_file" 2>/dev/null || printf '')"
  case "$config_mode" in
    600|400)
      pass "config.env permissions are private ($config_mode)"
      ;;
    *)
      warn "config.env is group/world readable (mode ${config_mode:-unknown}). Recommended:"
      warn "  chmod 600 \"$config_env_file\""
      ;;
  esac
fi

# ── Tuple audio input ──────────────────────────────────────────────────

step "Tuple configuration..."

printf "\n  Set Tuple's audio input device:\n"
printf "  ${BOLD}Tuple → Preferences → Audio → Input Device → \"$tuple_input_device\"${RESET}\n\n"
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

# ── Spoken test ────────────────────────────────────────────────────────
# Exercises the real worker path end-to-end (fetch + configured TTS backend)
# against a throwaway state dir, leaving the trigger's own state untouched.

step "Testing text-to-speech..."

if [[ -f "${script_dir}/.disabled" ]]; then
  warn "Trigger is disabled (.disabled exists); skipping the spoken test."
elif [[ "$errors" -gt 0 ]]; then
  warn "Skipping the spoken test until the issues above are fixed."
else
  read -rp "Speak a test joke through the '${tts_backend}' backend now? [Y/n] " answer
  if [[ -z "$answer" || "$answer" =~ ^[Yy] ]]; then
    test_state_dir="$(mktemp -d "${TMPDIR:-/tmp}/dad-joke-setup.XXXXXX")"
    trap 'rm -rf "$test_state_dir"' EXIT
    printf '%s' "Setup Test" >"${test_state_dir}/my-room"
    {
      printf '%s\n' "setup-test-token"
      printf '%s\n' "Setup Test"
      printf '%s\n' "the setup script"
      printf '%s\n' "setup-test"
      printf '%s\n' "$(date +%s)"
    } >"${test_state_dir}/pending-joke"
    if DAD_JOKE_GREETER_STATE_DIR="$test_state_dir" \
      DAD_JOKE_DEBOUNCE_SECONDS=0 \
      "${script_dir}/run-trigger.sh" worker --room "Setup Test" --token "setup-test-token"; then
      pass "Spoke a test joke through the '${tts_backend}' backend"
    else
      fail "Spoken test failed"
      if [[ -s "${test_state_dir}/say-errors.log" ]]; then
        sed 's/^/    /' "${test_state_dir}/say-errors.log"
      fi
      errors=$((errors + 1))
    fi
    rm -rf "$test_state_dir"
    printf "  ${BOLD}Note:${RESET} you heard the local leg. The BlackHole leg is only audible to an app\n"
    printf "  reading \"%s\" as input (Tuple in a call, or QuickTime recording it -\n" "$blackhole_device"
    printf "  see the README's \"Verify before a call\" section).\n"
  fi
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
