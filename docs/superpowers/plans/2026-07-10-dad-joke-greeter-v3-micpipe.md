# Dad Joke Greeter v3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the v1 dad-joke-greeter in `triggers/dad-joke-greeter` with the v3 modular runtime from `~/.tuple/triggers/dad-joke-greeter`, recommend micpipe (≥0.2.0) over the aggregate device, and document optional ElevenLabs TTS.

**Architecture:** The v3 live install is the source of truth: a single shared `run-trigger.sh` (event dispatch, debounced worker, TTS backend abstraction with `say` fallback) invoked by 5-line event shims, with trigger-local state/config. This plan imports that tree verbatim, then rewrites only `setup.sh` and `README.md` around micpipe, and adds two characterization tests.

**Tech Stack:** bash only (macOS built-ins: `bash`, `curl`, `sleep`, `say`; optional `afplay`/`ffmpeg` for API TTS). TAP-style bash test harness. No jq, no language runtimes.

**Spec:** `docs/superpowers/specs/2026-07-10-dad-joke-greeter-v3-micpipe-design.md` (committed on this branch).

**⚠️ Deviation from spec §7, flagged for review:** the spec says two commits. This plan produces four (import / new tests / setup.sh / README). The spec's two-commit decision existed only to avoid splitting the blended v3 import — which stays one commit here. The new work is additive on a coherent tree, so separate commits are safe and give cleaner review gates.

## Global Constraints

- Branch: `dad-joke-greeter-v3` on `markarranz/community-triggers` (already created; spec committed as `fb7e4f1`).
- `run-trigger.sh` must be **byte-identical** to `~/.tuple/triggers/dad-joke-greeter/run-trigger.sh`. If any check (shellcheck, review) suggests editing it, STOP and surface the conflict — byte-identical wins.
- micpipe minimum version: `0.2.0` (crates.io currently has only 0.1.0 — publishing 0.2.0 is an external prerequisite, Task 0).
- Aggregate device name: `BH + Mic Input`. BlackHole device default: `BlackHole 2ch` (env `BLACKHOLE_DEVICE`).
- Voice id is optional; `ELEVENLABS_VOICE_ID` defaults to `CwhRBWXzGAHq8TQ4Fs17` ("Roger"). Do NOT remove this default.
- Personal files never committed: `config.env`, `tracked-rooms.txt`, `.state/`, `.disabled`.
- `config.json` keeps repo main's copy (the live install's shorter description is a personal edit — do not import it).
- All shell files must pass `shellcheck` (v0.11.0 installed at `~/.local/share/nvim/mason/bin/shellcheck`; live files already pass).
- Commit messages: `dad-joke-greeter: <imperative summary>`. No `Co-Authored-By` lines (repo is outside `~/Code/work/`).
- Working directory for all commands: `/Users/mark/Code/public/community-triggers` unless stated.

---

### Task 0: External prerequisite — publish micpipe 0.2.0 (USER-GATED)

**Not part of this repo.** `cargo install micpipe` currently delivers 0.1.0 (launchd plist bug; doesn't react to default-input changes). The README written in Task 4 tells users to install ≥0.2.0, which must exist on crates.io before the eventual upstream PR — but **not** before Tasks 1–5 of this plan.

- [ ] **Step 1: Confirm with Mark before publishing** — publishing to crates.io is public and irreversible. Suggested flow (in `/Users/mark/Code/public/micpipe`, via the `cargo-crates-release` skill): validate, `cargo publish`, tag `v0.2.0`.
- [ ] **Step 2: After publish, replace the local path-build with the published artifact**

```bash
cargo install micpipe --force   # replaces the local path-install of 0.2.0
micpipe uninstall && micpipe install
micpipe status                  # Expected: running (pid ...)
```

This task only gates the "against published build" half of Task 5's live verification. Everything else proceeds without it.

---

### Task 1: Import the v3 tree + `.gitignore` + `config.env.example`

**Files:**
- Modify: `triggers/dad-joke-greeter/run-trigger.sh` (replace with live copy — 649 lines)
- Modify: `triggers/dad-joke-greeter/room-joined`, `triggers/dad-joke-greeter/room-left` (replace with live shims)
- Create: `triggers/dad-joke-greeter/call-ended` (live shim)
- Create: `triggers/dad-joke-greeter/test-dad-joke-greeter.sh` (live copy — 376 lines, 11 tests)
- Modify: `triggers/dad-joke-greeter/README.md`, `triggers/dad-joke-greeter/setup.sh` (replace with live copies **as-is**; rewritten in Tasks 3–4)
- Create: `triggers/dad-joke-greeter/.gitignore`
- Create: `triggers/dad-joke-greeter/config.env.example`
- Unchanged: `triggers/dad-joke-greeter/config.json`, `triggers/dad-joke-greeter/assets/icon.png`

**Interfaces:**
- Produces: `run-trigger.sh <room-joined|room-left|call-ended|worker> [--room R --token T]`; env knobs `DAD_JOKE_*`, `ELEVENLABS_*`, `BLACKHOLE_*`; state files under `<trigger>/.state/`; `config.env` auto-sourced with `set -a`. Later tasks rely on: `DAD_JOKE_GREETER_STATE_DIR` override, `DAD_JOKE_DEBOUNCE_SECONDS=0`, pending-joke file format (5 lines: token/room/joiner/source/epoch), and the `worker` event — Task 3's test-speak uses exactly these.

- [ ] **Step 1: Verify starting state**

```bash
git branch --show-current   # Expected: dad-joke-greeter-v3
git status --short          # Expected: empty
```

- [ ] **Step 2: Copy the live tree over the repo trigger**

```bash
SRC="$HOME/.tuple/triggers/dad-joke-greeter"
DST="triggers/dad-joke-greeter"
cp "$SRC/run-trigger.sh" "$SRC/room-joined" "$SRC/room-left" "$SRC/call-ended" \
   "$SRC/test-dad-joke-greeter.sh" "$SRC/README.md" "$SRC/setup.sh" "$DST/"
chmod +x "$DST/run-trigger.sh" "$DST/room-joined" "$DST/room-left" "$DST/call-ended" \
   "$DST/test-dad-joke-greeter.sh" "$DST/setup.sh"
rmdir "$DST/.state" 2>/dev/null || true   # stray empty local artifact, untracked
diff "$SRC/run-trigger.sh" "$DST/run-trigger.sh"   # Expected: no output (byte-identical)
diff "$SRC/config.json" "$DST/config.json" || true # Expected: description differs — correct, we keep main's
```

- [ ] **Step 3: Create `triggers/dad-joke-greeter/.gitignore`**

```gitignore
# Personal runtime configuration — never commit (may reference private voice/keychain settings)
config.env

# Personal, user-created room filter — never commit (see README "Limiting to specific rooms")
tracked-rooms.txt

# Local runtime state
.state/
.disabled
```

- [ ] **Step 4: Create `triggers/dad-joke-greeter/config.env.example`**

```sh
# Dad Joke Greeter configuration.
#
# Copy this file to config.env next to run-trigger.sh, then uncomment and edit
# the lines you need. Keep it private: chmod 600 config.env
# The README's Configuration table documents every supported variable.

# DAD_JOKE_TTS_BACKEND=elevenlabs             # say (default) | elevenlabs | api | http
# ELEVENLABS_VOICE_ID=CwhRBWXzGAHq8TQ4Fs17    # optional; defaults to "Roger" (premade ElevenLabs voice)
# ELEVENLABS_KEYCHAIN_SERVICE=elevenlabs-api-key
# ELEVENLABS_API_KEY=                         # optional; prefer the macOS Keychain (see README)
# DAD_JOKE_TTS_API_URL=                       # api/http backends only
# DAD_JOKE_TTS_API_AUTH_HEADER='Authorization: Bearer <token>'   # api/http backends only
```

- [ ] **Step 5: Run the imported test suite**

```bash
bash triggers/dad-joke-greeter/test-dad-joke-greeter.sh
```

Expected: 11 `ok N - ...` lines ending `ok 11 - comment-only tracked rooms file tracks all rooms`, exit 0.

- [ ] **Step 6: shellcheck everything imported**

```bash
shellcheck triggers/dad-joke-greeter/run-trigger.sh triggers/dad-joke-greeter/setup.sh \
  triggers/dad-joke-greeter/room-joined triggers/dad-joke-greeter/room-left \
  triggers/dad-joke-greeter/call-ended triggers/dad-joke-greeter/test-dad-joke-greeter.sh
```

Expected: no output, exit 0. (Live files already pass shellcheck 0.11.0. If findings appear, STOP — do not edit `run-trigger.sh`; surface the conflict.)

- [ ] **Step 7: Commit**

```bash
git add triggers/dad-joke-greeter
git status --short   # MUST NOT list config.env, tracked-rooms.txt, .state, .disabled
git commit -m "dad-joke-greeter: adopt v3 shared runtime, TTS backends, and test suite"
```

---

### Task 2: Characterization tests — missing-API-key fallback, config.env sourcing

**Files:**
- Modify: `triggers/dad-joke-greeter/test-dad-joke-greeter.sh` (append two tests + two registration lines)

**Interfaces:**
- Consumes: harness helpers from the imported suite — `prepare_worker_joke` (context + `my-room` + pending token `tok` for "Example Room"/"Guest User"), `run_event`, `assert_contains`, `assert_not_contains`, `assert_file_not_exists`, `pass`; PATH stubs `curl`/`say`/`afplay`/`ffmpeg`/`security` (the `security` stub exits 1 = no keychain key; `run_event` passes `ELEVENLABS_API_KEY=""` when unset).
- Produces: 13-test suite. These are characterization tests locking in imported behavior (fallback on unresolvable key; `config.env` values overriding empty inherited env vars) — they must pass immediately.

- [ ] **Step 1: Append the two test functions** after `test_comment_only_tracked_rooms_tracks_all()` (before the registration block at the bottom):

```bash
test_missing_api_key_falls_back_to_say() {
  prepare_worker_joke

  DAD_JOKE_TTS_BACKEND=elevenlabs \
  run_event worker --room "Example Room" --token "tok"

  assert_not_contains "$CURL_LOG" "text-to-speech"
  assert_file_not_exists "$AFPLAY_LOG"
  assert_contains "$SAY_LOG" "Guest User just joined. Here is a dad joke. knock knock"
  assert_contains "$SAY_LOG" "-a BlackHole 2ch"
  assert_file_not_exists "${STATE_DIR}/pending-joke"
  pass "missing ElevenLabs API key falls back to say"
}

test_config_env_overrides_environment() {
  prepare_worker_joke
  cat >"${TRIGGER_DIR}/config.env" <<'EOF'
DAD_JOKE_TTS_BACKEND=api
DAD_JOKE_TTS_API_URL=https://tts.example/speak
EOF

  run_event worker --room "Example Room" --token "tok"

  assert_contains "$CURL_LOG" "https://tts.example/speak"
  assert_contains "$AFPLAY_LOG" "dad-joke-tts.mp3"
  assert_file_not_exists "$SAY_LOG"
  assert_file_not_exists "${STATE_DIR}/pending-joke"
  pass "config.env values override empty environment variables"
}
```

Why they work: (test 1) `run_event` exports `ELEVENLABS_API_KEY=""`; the `security` stub exits 1, so `synthesize_with_elevenlabs` logs "ELEVENLABS_API_KEY is missing" and returns 1 before any TTS request — `speak_to_default_and_blackhole` falls back to `say`. `$CURL_LOG` still exists (joke fetch), hence `assert_not_contains` rather than not-exists. (test 2) `run_event` exports `DAD_JOKE_TTS_BACKEND=""`; `run-trigger.sh` sources `${TRIGGER_DIR}/config.env` with `set -a` *after* the environment is established, so the file's `api` value wins; the curl stub treats `*tts.example*` URLs as TTS calls and writes fake audio.

- [ ] **Step 2: Register both tests** at the bottom of the file, after `test_comment_only_tracked_rooms_tracks_all`:

```bash
test_missing_api_key_falls_back_to_say
test_config_env_overrides_environment
```

- [ ] **Step 3: Run the suite**

```bash
bash triggers/dad-joke-greeter/test-dad-joke-greeter.sh
```

Expected: 13 `ok` lines, ending:
```
ok 12 - missing ElevenLabs API key falls back to say
ok 13 - config.env values override empty environment variables
```

- [ ] **Step 4: Prove test 1 bites (mutation check)** — run once with a key supplied; the test must fail:

```bash
ELEVENLABS_API_KEY=test-key bash triggers/dad-joke-greeter/test-dad-joke-greeter.sh 2>&1 | tail -3
```

(The suite's `run_event` forwards an inherited `ELEVENLABS_API_KEY`, so with a key the ElevenLabs path succeeds and `afplay` runs, tripping test 12's `assert_file_not_exists "$AFPLAY_LOG"`.)

Expected: `not ok - expected ... to be absent` (or similar failure) at test 12, because with a key the ElevenLabs path succeeds and `afplay` runs. If the suite passes 13/13 here, the test asserts nothing — STOP and fix. Afterwards re-run Step 3 (unpolluted) and confirm 13/13.

- [ ] **Step 5: shellcheck + commit**

```bash
shellcheck triggers/dad-joke-greeter/test-dad-joke-greeter.sh
git add triggers/dad-joke-greeter/test-dad-joke-greeter.sh
git commit -m "dad-joke-greeter: add fallback and config.env characterization tests"
```

---

### Task 3: Rewrite `setup.sh` — micpipe-first with aggregate fallback

**Files:**
- Modify: `triggers/dad-joke-greeter/setup.sh` (full replacement, content below)

**Interfaces:**
- Consumes: `run-trigger.sh worker --room R --token T` with `DAD_JOKE_GREETER_STATE_DIR` + `DAD_JOKE_DEBOUNCE_SECONDS=0` and the 5-line pending-joke format (Task 1) for the spoken test; `micpipe` CLI (`--version` prints `micpipe X.Y.Z`; `status` prints `running (pid N)` when up; `install` starts the launchd service).
- Produces: interactive validator with two routing branches; Task 4's README references it as "Quick setup" and "spoken test".

- [ ] **Step 1: Replace `triggers/dad-joke-greeter/setup.sh` with exactly this content**

```bash
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
```

- [ ] **Step 2: Syntax + lint**

```bash
bash -n triggers/dad-joke-greeter/setup.sh   # Expected: no output
shellcheck triggers/dad-joke-greeter/setup.sh # Expected: no output
```

- [ ] **Step 3: Interactive smoke run on this machine** (micpipe installed + running here, so the micpipe branch executes; answer `n` to the install prompt if offered, `Y` to the spoken test):

```bash
bash triggers/dad-joke-greeter/setup.sh
```

Expected: all prerequisite checks pass; `micpipe 0.2.0 (>= 0.2.0)`; `micpipe service is running`; launchers incl. `call-ended` pass; TTS-backend section reflects the repo checkout (no `config.env` → backend `say`); a joke is spoken aloud; summary green. (A stale-"BH + Mic Input" warning may appear if the aggregate still exists — that's correct behavior, not a failure.)

- [ ] **Step 4: Commit**

```bash
git add triggers/dad-joke-greeter/setup.sh
git commit -m "dad-joke-greeter: rewrite setup.sh around micpipe with aggregate fallback"
```

---

### Task 4: Rewrite `README.md` — micpipe primary, aggregate appendix, migration docs

**Files:**
- Modify: `triggers/dad-joke-greeter/README.md` (full replacement, content below)

**Interfaces:**
- Consumes: setup.sh behaviors from Task 3 (both routing branches, spoken test); run-trigger.sh env table values from Task 1 (do not change any default in the table).

- [ ] **Step 1: Replace `triggers/dad-joke-greeter/README.md` with exactly this content**

````markdown
# Dad Joke Greeter

Greet participants with a random dad joke when they join your Tuple room, spoken aloud so everyone on the call hears it.

Jokes are fetched from [icanhazdadjoke.com](https://icanhazdadjoke.com/) and played through macOS text-to-speech. By default the trigger uses the built-in `say` program. You can also opt into an API-backed text-to-speech provider, such as ElevenLabs, while keeping `say` as the fallback.

Audio is routed to both your local speakers and a virtual audio device so remote participants hear the joke through Tuple.

## Installation

Copy the trigger into your Tuple triggers directory:

```bash
cp -r triggers/dad-joke-greeter ~/.tuple/triggers/dad-joke-greeter
```

> If you installed this trigger from the [Tuple Triggers Directory](https://tuple.app/triggers), it's already in place. Skip to Quick Setup.

> **Reinstalling or updating from the Triggers Directory replaces this folder.** Back up your personal files first — `config.env`, `tracked-rooms.txt`, and `.disabled` — and restore them after the update. (Runtime state in `.state/` is disposable.)

## How it works

- When **you** join a tracked room, the trigger records which room you're in and schedules a dad joke.
- When **someone else** joins the same room, a dad joke is scheduled.
- If more people join the same room within 5 seconds, the timer restarts. After 5 quiet seconds, one dad joke is fetched and spoken aloud.
- When **you** leave the room, state is cleared and jokes stop.

## Quick setup

Run the included setup script to check prerequisites and validate the audio routing:

```bash
bash ~/.tuple/triggers/dad-joke-greeter/setup.sh
```

The script walks through each step interactively and supports both audio routes below — micpipe (recommended) or a hand-built aggregate device. If you prefer to set things up manually, follow the steps below.

## Prerequisites

- macOS
- No language runtime required; the trigger uses macOS `bash`, `curl`, `sleep`, and `say`
- [BlackHole 2ch](https://existential.audio/blackhole/) (free virtual audio driver)
- [micpipe](https://github.com/markarranz/micpipe) 0.2.0+ (recommended audio router; installing it needs a Rust toolchain) — or a hand-built aggregate device, see [the appendix](#alternative-aggregate-device-manual-no-extra-install)
- Optional API TTS backends also require `afplay` and `ffmpeg`

> **Note:** After installing BlackHole, you may need to restart your Mac (or log out and back in) before it appears as an audio device.

## Audio setup (micpipe)

The key trick is routing the joke audio into Tuple's microphone input so remote participants hear it. The recommended way is [micpipe](https://github.com/markarranz/micpipe), a small background service that streams your microphone into BlackHole. Tuple then uses BlackHole directly as its input device and receives your voice and the joke audio mixed together — both sit on the two channels Tuple transmits.

1. Install BlackHole:

   ```bash
   brew install blackhole-2ch
   ```

   If BlackHole 2ch does not appear in System Settings → Sound afterwards, restart your Mac (or log out and back in) before continuing.

2. Install micpipe — version 0.2.0 or newer (Rust 1.88+ required; get it from [rustup.rs](https://rustup.rs); `cargo install` compiles from source and takes a few minutes):

   ```bash
   cargo install micpipe
   ```

   No Rust toolchain? Use the [aggregate device appendix](#alternative-aggregate-device-manual-no-extra-install) instead.

3. Grant the microphone permission with a foreground test run:

   ```bash
   micpipe run
   ```

   Grant the macOS microphone permission when prompted, wait for the `Mic -> BlackHole 2ch` line, then stop it with `Ctrl-C`. The permission belongs to the binary that starts micpipe; a launchd-spawned service may never surface the permission prompt, leaving a service that runs but captures silence.

4. Install the background service:

   ```bash
   micpipe install
   ```

   micpipe follows the system default input device and restarts when it changes; use `micpipe install --input "<mic name>"` to pin a specific mic instead. Check it with `micpipe status`.

5. In Tuple, go to **Preferences → Audio → Input Device** and select **"BlackHole 2ch"**.

### Verify before a call

micpipe streams your mic into BlackHole only while some app is reading BlackHole as an input (Tuple during a call, or a recording app). The trigger writes joke audio to BlackHole regardless, but nothing is audible from BlackHole until something listens. To check the full path end-to-end without a call:

1. Open QuickTime Player → File → New Audio Recording, click the arrow next to the record button, and select **BlackHole 2ch** as the microphone.
2. Start recording, speak a few words, and run the setup script's spoken test (`bash setup.sh`, answer `Y` at the test prompt).
3. Stop and play the recording: it should contain **both** your voice (via micpipe) and the joke (via the trigger).

### Speaker output

Local speaker output uses the macOS system default. No configuration is needed.

With the default `say` backend, local audio is played by `say` and Tuple audio is played by `say -a "BlackHole 2ch"`. With API TTS backends, local audio is played by `afplay` and Tuple audio is played through BlackHole using ffmpeg's AudioToolbox output.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BLACKHOLE_DEVICE` | `BlackHole 2ch` | Virtual audio device name |
| `BLACKHOLE_AUDIO_DEVICE_INDEX` | auto-detected | Optional ffmpeg AudioToolbox device index for API TTS playback |
| `DAD_JOKE_API_URL` | `https://icanhazdadjoke.com/` | Dad joke API endpoint |
| `DAD_JOKE_DEBOUNCE_SECONDS` | `5` | Quiet window before one debounced joke is spoken |
| `DAD_JOKE_GREETER_STATE_DIR` | `.state` next to the trigger scripts | Local state directory for `my-room` and pending jokes |
| `DAD_JOKE_TTS_BACKEND` | `say` | TTS backend: `say`, `elevenlabs`, `api`, or `http` |
| `DAD_JOKE_TTS_TIMEOUT` | `30` | Timeout in seconds for API TTS requests |
| `ELEVENLABS_API_KEY` | unset | ElevenLabs API key. If unset, the trigger checks the macOS Keychain service below |
| `ELEVENLABS_KEYCHAIN_SERVICE` | `elevenlabs-api-key` | Keychain service name for the ElevenLabs API key |
| `ELEVENLABS_VOICE_ID` | `CwhRBWXzGAHq8TQ4Fs17` | ElevenLabs voice ID; the default is Roger |
| `ELEVENLABS_MODEL_ID` | `eleven_multilingual_v2` | ElevenLabs model ID |
| `ELEVENLABS_OUTPUT_FORMAT` | `mp3_44100_128` | ElevenLabs output format |
| `DAD_JOKE_TTS_API_URL` | unset | Generic API TTS endpoint URL |
| `DAD_JOKE_TTS_API_AUTH_HEADER` | unset | Optional auth header for the generic API backend |

By default, the greeter follows Tuple's trigger state guidance and keeps its local state inside the trigger folder. `DAD_JOKE_GREETER_STATE_DIR` overrides the full path.

The `room-joined` / `room-left` / `call-ended` triggers are small bash launchers that delegate to `run-trigger.sh`. No Python, Ruby, Node, or package installation is needed.

### Configure API TTS

Tuple starts triggers from the macOS app, so environment variables set in your terminal usually will not be visible to the trigger. Put trigger-specific settings in a `config.env` file next to `run-trigger.sh` — start from the committed template:

```bash
cp ~/.tuple/triggers/dad-joke-greeter/config.env.example ~/.tuple/triggers/dad-joke-greeter/config.env
chmod 600 ~/.tuple/triggers/dad-joke-greeter/config.env
```

For ElevenLabs you need an API key (create one at [elevenlabs.io](https://elevenlabs.io) → your profile → API keys) and optionally a voice ID (copy it from the [Voice Library](https://elevenlabs.io/app/voice-library); the default is the premade voice "Roger"). API backends also need ffmpeg:

```bash
brew install ffmpeg
```

Then set the backend in `config.env`:

```bash
cat > ~/.tuple/triggers/dad-joke-greeter/config.env <<'EOF'
DAD_JOKE_TTS_BACKEND=elevenlabs
ELEVENLABS_VOICE_ID=CwhRBWXzGAHq8TQ4Fs17
ELEVENLABS_KEYCHAIN_SERVICE=elevenlabs-api-key
EOF
chmod 600 ~/.tuple/triggers/dad-joke-greeter/config.env
```

Store the ElevenLabs API key in the macOS Keychain:

```bash
security add-generic-password -U -a "$USER" -s elevenlabs-api-key -w
```

The `-w` at the end makes `security` prompt for the key so it never lands in your shell history.

If `DAD_JOKE_TTS_BACKEND=elevenlabs` is set and the API key is missing or the API request fails, the trigger logs the error and falls back to `say`. Diagnostics land in `.state/debounced-worker.log` and `.state/say-errors.log` next to the trigger scripts. After configuring a backend, re-run `bash setup.sh` — it checks ffmpeg and offers a spoken test through the configured backend.

For a generic TTS API, use `api` or `http`:

```bash
cat > ~/.tuple/triggers/dad-joke-greeter/config.env <<'EOF'
DAD_JOKE_TTS_BACKEND=api
DAD_JOKE_TTS_API_URL=https://example.local/tts
DAD_JOKE_TTS_API_AUTH_HEADER='Authorization: Bearer replace-me'
EOF
chmod 600 ~/.tuple/triggers/dad-joke-greeter/config.env
```

The generic backend sends a `POST` request with `Content-Type: application/json` and a body like `{"text":"..."}`. The endpoint should return audio bytes that `afplay` can play.

## Limiting to specific rooms

By default, dad jokes can trigger in any Tuple room you join. If you only want jokes in certain rooms, add a `tracked-rooms.txt` file next to the trigger scripts:

```bash
$EDITOR ~/.tuple/triggers/dad-joke-greeter/tracked-rooms.txt
```

Put one room name on each line:

```
Engineering
Design Crit
Friday Demo
```

When this file exists, only rooms listed in it will trigger jokes. Room names are case-sensitive and must match exactly as they appear in Tuple. Blank lines and lines starting with `#` are ignored, so you can leave comments. A file that is empty or contains only comments behaves the same as no file at all; jokes trigger in every room. Remove the file to go back to all rooms:

```bash
rm ~/.tuple/triggers/dad-joke-greeter/tracked-rooms.txt
```

## Disabling temporarily

The simplest way to pause jokes without removing the trigger is a touch-file. Tuple spawns trigger scripts as subprocesses, so environment variables set in your terminal won't propagate, but a file on disk is always visible:

```bash
# Disable
touch ~/.tuple/triggers/dad-joke-greeter/.disabled

# Re-enable
rm ~/.tuple/triggers/dad-joke-greeter/.disabled
```

Alternatively, remove or rename the trigger files in `~/.tuple/triggers/dad-joke-greeter/`.

## Upgrading from 1.x

Earlier versions of this trigger kept configuration under `~/.tuple/` and routed audio through an aggregate device. To migrate:

1. **Audio first:** if you built the 1.x "BH + Mic Input" aggregate device, switch to micpipe before anything else — see [Migrating from the aggregate device to micpipe](#migrating-from-the-aggregate-device-to-micpipe). Keeping the aggregate selected in Tuple while micpipe runs sends your mic twice (direct + BlackHole copy) and remote participants hear an echo.
2. Room filter: `mv ~/.tuple/tracked-rooms ~/.tuple/triggers/dad-joke-greeter/tracked-rooms.txt`
   **Semantics change:** an empty or comment-only `tracked-rooms.txt` now means *no filter* — jokes in ALL rooms. In 1.x an empty file matched nothing (an effective mute). If you emptied the file to mute jokes, use `touch .disabled` instead. Lines starting with `#` are now comments, and surrounding whitespace is trimmed.
3. Disable flag: if you had `~/.tuple/.dad-jokes-disabled`, replace it: `rm ~/.tuple/.dad-jokes-disabled && touch ~/.tuple/triggers/dad-joke-greeter/.disabled`
4. Old state: `rm -rf ~/.tuple/.state/dad-joke-greeter` — state now lives in `.state/` inside this folder (`DAD_JOKE_GREETER_STATE_DIR` overrides).

## Known limitations

- **Switching microphones:** with micpipe 0.2.0+ this mostly takes care of itself — micpipe follows the macOS default input device and restarts when it changes. If you pinned a mic with `micpipe install --input`, reinstall to change it: `micpipe uninstall && micpipe install --input "<new mic>"`. Aggregate-device users must rebuild the aggregate by hand when switching mics — see the appendix.
- **Stale state after crash:** If Tuple crashes mid-call, the `room-left` trigger never fires and the state file that tracks which room you're in becomes stale. A subsequent join by someone else could trigger a joke even though you're no longer in the room. Rejoining a tracked room overwrites the stale room state automatically.

## Alternative: aggregate device (manual, no extra install)

If you'd rather not install micpipe (no Rust toolchain, or you prefer built-in macOS tools), you can route audio with a hand-built aggregate device instead. This was the primary setup in earlier versions of this trigger. `setup.sh` validates this path automatically when micpipe is not installed.

### 1. Create the aggregate device

Open **Audio MIDI Setup** (Spotlight → "Audio MIDI Setup") and create a new aggregate device:

1. Click the **+** button in the bottom-left → **Create Aggregate Device**
2. Name it **"BH + Mic Input"**
3. Check a **mono (single-channel) microphone first**. The built-in **"MacBook Pro Microphone"** is a good default. It **must** be a 1-channel input (see "Use a mono microphone" below).
4. Check **"BlackHole 2ch" second**
5. Enable **Drift Correction** on the BlackHole 2ch row
6. Set the **Clock Source** to the microphone you selected in step 3

> **Order matters.** Your mic must be added first and used as the clock source. BlackHole needs drift correction enabled because it runs on a virtual clock that can drift from the hardware mic. Getting this wrong can cause audio glitches or silence.

#### Use a mono microphone

This is the part that's easy to get wrong. Tuple transmits the **first two channels** of its input device, and an aggregate device lays its members' channels out back-to-back:

- A **mono** mic takes channel 1, so **BlackHole lands on channels 2-3**. Channel 2 (the joke) is inside the pair Tuple sends, so **both your voice and the joke go out**.
- A **stereo** mic (e.g. a Blue Yeti) takes channels 1-2, pushing **BlackHole out to channels 3-4**, past what Tuple captures. You'll hear the joke locally but **the room never will**.

So pick a 1-channel mic. The built-in MacBook microphone is mono and works well, and calls are mono anyway so you lose nothing. If you only have a stereo/USB mic and want to use it, a plain aggregate can't do this. You'd need a real audio **mixer** (e.g. [LadioCast](https://apps.apple.com/us/app/ladiocast/id411213048), free, or [OBS](https://obsproject.com/), open source) to mix mic + BlackHole into one device, then point Tuple at that.

Unlike micpipe, an aggregate is bound to the specific mic you built it with — if you switch mics (AirPods, headset, ...), rebuild the aggregate in Audio MIDI Setup with the new mic.

### 2. Configure Tuple

In Tuple, go to **Preferences → Audio → Input Device** and select **"BH + Mic Input"**.

Now Tuple receives both your voice (mic on channel 1) and the joke audio (BlackHole on channel 2).

### Migrating from the aggregate device to micpipe

1. In Tuple, switch **Preferences → Audio → Input Device** away from "BH + Mic Input" (pick your real mic for now).
2. Delete "BH + Mic Input" in **Audio MIDI Setup**.
3. Follow [Audio setup (micpipe)](#audio-setup-micpipe) steps 2–5.
````

- [ ] **Step 2: Verify internal anchors resolve** (GitHub slugging):

```bash
grep -o '#[a-z-]*' triggers/dad-joke-greeter/README.md | sort -u | grep -v '^#$'
grep -n '^#\{2,3\} ' triggers/dad-joke-greeter/README.md
```

Check by eye: `#alternative-aggregate-device-manual-no-extra-install`, `#migrating-from-the-aggregate-device-to-micpipe`, `#audio-setup-micpipe` each match a heading.

- [ ] **Step 3: Commit**

```bash
git add triggers/dad-joke-greeter/README.md
git commit -m "dad-joke-greeter: recommend micpipe; move aggregate device to appendix"
```

---

### Task 5: Verification gate (blocks Task 6)

**Files:** none modified. All checks must pass before any cleanup.

- [ ] **Step 1: Full test suite**

```bash
bash triggers/dad-joke-greeter/test-dad-joke-greeter.sh
```

Expected: 13 `ok` lines, exit 0.

- [ ] **Step 2: shellcheck everything**

```bash
shellcheck triggers/dad-joke-greeter/run-trigger.sh triggers/dad-joke-greeter/setup.sh \
  triggers/dad-joke-greeter/room-joined triggers/dad-joke-greeter/room-left \
  triggers/dad-joke-greeter/call-ended triggers/dad-joke-greeter/test-dad-joke-greeter.sh
```

Expected: no output, exit 0.

- [ ] **Step 3: Diff against the live install — intended deltas only**

```bash
diff -rq --exclude=.state --exclude=config.env --exclude=tracked-rooms.txt --exclude=.disabled \
  --exclude=.DS_Store ~/.tuple/triggers/dad-joke-greeter triggers/dad-joke-greeter
```

Expected: EXACTLY these six lines (order may vary; the parenthetical reasons are annotations, not diff output):
- `README.md` differ — rewrite
- `.gitignore` differ — adds config.env
- `config.json` differ — kept main's description
- `setup.sh` differ — rewrite
- `test-dad-joke-greeter.sh` differ — 2 new tests
- `Only in triggers/dad-joke-greeter: config.env.example` — new

`run-trigger.sh`, the three shims, and `assets/icon.png` must NOT appear. Any unexpected line → STOP, investigate.

- [ ] **Step 4: Repo CI validator (structural)**

```bash
cd util && pnpm install && cd .. && node -e 'require("./util/validate-triggers.js")({core:{setFailed:(m)=>{console.error(m);process.exitCode=1}}})'
```

Expected: `All triggers passed validation`, exit 0. (`extractTriggers()` reads `triggers/` relative to `process.cwd()`, so node must run from the repo root — matching real CI's cwd. The CI entry is `util/pull-request-validator.js` via actions/github-script.)

- [ ] **Step 5: setup.sh — micpipe branch, live** (interactive; already done once in Task 3 Step 3 — rerun if anything changed since)

- [ ] **Step 6: setup.sh — non-micpipe branch, live** (hide micpipe from PATH):

```bash
PATH="$(echo "$PATH" | tr ':' '\n' | grep -v '\.cargo/bin' | paste -sd: -)" \
  bash triggers/dad-joke-greeter/setup.sh
```

Expected: routing section either validates an existing "BH + Mic Input" aggregate (if one still exists on this machine) or fails with the `cargo install micpipe` / appendix guidance. Either outcome exercises the branch correctly; confirm the messaging matches Task 3's script.

- [ ] **Step 7: Dual-writer live check (NEEDS HUMAN — spec §6's untested core assumption).** With the micpipe service running: QuickTime → New Audio Recording → mic = BlackHole 2ch → record; speak a few words into the mic; simultaneously run the setup.sh spoken test (or `say -a "BlackHole 2ch" -- "dual writer test"`); stop and play back. Expected: recording contains BOTH the voice and the joke, mixed, no masking/clipping. If the joke is missing or mangled while micpipe streams → STOP; the micpipe recommendation needs rework (surface to Mark).

- [ ] **Step 8: (Post-Task-0 only) repeat Step 7 against the published crates.io 0.2.0 build.**

---

### Task 6: Push, cleanup, re-sync live install (USER-GATED destructive steps)

**Files:** none in-repo; git refs + `~/.tuple` files.

- [ ] **Step 1: Push the branch**

```bash
git push -u origin dad-joke-greeter-v3
```

- [ ] **Step 2: CONFIRM WITH MARK, then delete the superseded refs.** Verify targets first — every one of these is now redundant with the pushed branch (Task 5 Step 3 proved content-equivalence):

```bash
git stash list | head -3    # stash@{0} must be "WIP on dad-joke-greeter-shared-runtime" (58c604d) — if not, STOP
git branch -D add-dad-joke-greeter dad-joke-greeter-shared-runtime dad-joke-greeter-tracked-rooms-config
git push origin --delete dad-joke-greeter-shared-runtime dad-joke-greeter-tracked-rooms-config
git stash drop 'stash@{0}'
```

- [ ] **Step 3: Re-sync the live install from the branch** (personal files untouched — only changed public files copied):

```bash
cp triggers/dad-joke-greeter/README.md triggers/dad-joke-greeter/setup.sh \
   triggers/dad-joke-greeter/test-dad-joke-greeter.sh triggers/dad-joke-greeter/.gitignore \
   triggers/dad-joke-greeter/config.env.example ~/.tuple/triggers/dad-joke-greeter/
diff -rq --exclude=.state --exclude=config.env --exclude=tracked-rooms.txt --exclude=.disabled \
  --exclude=.DS_Store ~/.tuple/triggers/dad-joke-greeter triggers/dad-joke-greeter
```

Expected: only `config.json` differs (live keeps the personal description — acceptable) — or copy that too if Mark prefers.

- [ ] **Step 4: Run the live test suite once more from the install**

```bash
bash ~/.tuple/triggers/dad-joke-greeter/test-dad-joke-greeter.sh
```

Expected: 13 `ok` lines, exit 0.
