# Dad Joke Greeter v3 — Modular Runtime, micpipe, ElevenLabs

**Date:** 2026-07-10
**Status:** Approved (design), pending implementation
**Branch:** `dad-joke-greeter-v3` off `main` on `markarranz/community-triggers` (origin). Upstream PR to `tupleapp/community-triggers` later.

## Context

Three versions of the trigger exist:

1. **v1.0 — repo `main`** (`triggers/dad-joke-greeter`): monolithic `room-joined`/`room-left`, `say`-only TTS, jq dependency, state at `~/.tuple/.state/dad-joke-greeter`, room filter at `~/.tuple/tracked-rooms`, disable file `~/.tuple/.dad-jokes-disabled`, aggregate-device ("BH + Mic Input") setup docs.
2. **v2 — local branch `dad-joke-greeter-shared-runtime`** (commit `3cd8d19`, never pushed; `origin/dad-joke-greeter-shared-runtime` is stale at `f067fdd`): modular rewrite — shared `run-trigger.sh`, event shims, token-based debounce worker, trigger-local state/config, jq dropped, TAP test suite.
3. **v3.0 — live install** (`~/.tuple/triggers/dad-joke-greeter`): v2 + `stash@{0}` (TTS backends: `say|elevenlabs|api|http`, Keychain key lookup) + ungitted delta (`call-ended` handler, room-left behavior change, 11 tests total, `config.env`). **This tree is the source of truth** — tested, with a month of runtime logs.

**Room-left behavior change (defined):** on a self `room-left`, v3 clears `my-room`/pending state even when the event's room name mismatches the tracked room (v2 kept state on mismatch); any self-leave is treated as leaving the tracked room. Covered by `test_mismatched_room_left_clears_state`.

**Approach (decided):** fresh branch off current `main`; import the v3 tree (excluding personal files); adapt for public use. Old branches/stash become redundant and are deleted after diff-verification. (Rejected: rebasing branch+stash — three-way reconciliation to reach the same tree; grafting onto v1 — contradicts the modular-codebase goal.)

**micpipe** (github.com/markarranz/micpipe, Mark's crate): macOS CoreAudio router piping one mic into "BlackHole 2ch" as a launchd service — replaces the aggregate device. crates.io max version is **0.1.0** (launchd plist indentation bug; no demand gating; does not react to default-input device changes while running). The local repo is **0.2.0** with those fixed, unpublished. This machine already runs a local path-install of 0.2.0 (`~/.cargo/bin/micpipe`). Channel mapping (verified in `src/audio.rs` `convert_frame`, unit test `duplicates_mono_to_stereo`): mono mic audio is duplicated into **both** BlackHole channels, so mic and joke audio share both channels Tuple transmits.

**Prerequisite (decided, separate task in the micpipe repo):** publish micpipe 0.2.0 to crates.io, then replace the local path-install with the published build (`cargo install micpipe --force` + `micpipe uninstall && micpipe install`) so live verification runs against what users will get.

## Goals

- Adopt the v3 modular codebase in the public repo.
- Recommend micpipe (≥0.2.0) as the primary audio-routing path; aggregate device becomes a manual-alternative appendix, still validated by setup.sh.
- Optional ElevenLabs TTS via user-supplied API key (voice id optional); default remains `say` with zero config.

## Non-goals

- No changes to `announce-participant-left` (local-only trigger; its gate on `~/.tuple/.state/my-room` — a pre-v1 path; shipped v1 writes `~/.tuple/.state/dad-joke-greeter/my-room` — is dead under both shipped v1 and v3; noted, out of scope).
- No code-level compatibility fallbacks to v1 paths (docs carry the migration).
- No changes to other triggers, `util/` validation, or CI.

## 1. File layout (branch target)

```
triggers/dad-joke-greeter/
├── run-trigger.sh            # shared runtime: event dispatch, debounce worker, state, TTS, keychain
├── room-joined               # 5-line exec shim → run-trigger.sh room-joined
├── room-left                 # shim
├── call-ended                # shim
├── setup.sh                  # rewritten: branches micpipe path / aggregate path (§4)
├── test-dad-joke-greeter.sh  # TAP suite, all 11 tests ported (+ new, see §6)
├── README.md                 # rewritten per §4 scope
├── config.env.example        # NEW, committed template
├── .gitignore                # NEW: config.env, tracked-rooms.txt, .state/, .disabled
├── config.json               # keep repo main's copy (live install's shorter description is a personal edit; do not import)
└── assets/icon.png           # unchanged
```

Personal files (`config.env`, `tracked-rooms.txt`, `.state/`, `.disabled`) never enter git. The live install's `.gitignore` misses `config.env` — the repo `.gitignore` must include it (leak hazard: voice id + keychain service name).

**Directory-install caveat (README note):** updating/reinstalling from the Tuple Triggers Directory replaces the trigger folder, clobbering `config.env`, `tracked-rooms.txt`, `.disabled`, `.state/`. README warns: back up `config.env` and `tracked-rooms.txt` before reinstalling (state is disposable; `DAD_JOKE_GREETER_STATE_DIR` can relocate it).

## 2. Config & secrets

- Default TTS backend = `say`. Trigger works with zero configuration.
- `config.env` in the trigger directory, auto-sourced by `run-trigger.sh` with `set -a; . config.env; set +a`. setup.sh warns (non-fatal, never increments the error count) if the file exists with any group/other permission bits (mode not 600/400), printing the exact `chmod 600` command.
- ElevenLabs key resolution order (as in v3): `ELEVENLABS_API_KEY` env var (settable via `config.env` or `launchctl setenv`) → macOS Keychain: `security find-generic-password -a "$USER" -s "$ELEVENLABS_KEYCHAIN_SERVICE" -w` (service default `elevenlabs-api-key`).
- README documents the Keychain write one-liner (with `-U` so re-running it rotates the key instead of failing):
  `security add-generic-password -U -a "$USER" -s elevenlabs-api-key -w '<key>'`
- **Voice id is optional** (v3 behavior kept): `ELEVENLABS_VOICE_ID` defaults to `CwhRBWXzGAHq8TQ4Fs17` ("Roger", a premade ElevenLabs voice). README table documents it as `default: Roger`. README's ElevenLabs section links where to get a key and voice id (elevenlabs.io → profile → API key; Voice Library for voice ids), states `brew install ffmpeg` up front, says to re-run `setup.sh` after configuring a backend, and names the fallback-diagnostics log location (`.state/` logs).
- Misconfiguration/failure behavior (v3, kept): missing/unresolvable API key, missing required tool (ffmpeg/afplay), or any API failure → logged error, fallback to `say`. Never crash the greeting.
- `config.env.example` (committed) content:

  ```sh
  # DAD_JOKE_TTS_BACKEND=elevenlabs        # say (default) | elevenlabs | api | http
  # ELEVENLABS_VOICE_ID=CwhRBWXzGAHq8TQ4Fs17   # optional; defaults to "Roger" (premade voice)
  # ELEVENLABS_KEYCHAIN_SERVICE=elevenlabs-api-key
  # ELEVENLABS_API_KEY=                    # optional; prefer the Keychain
  # DAD_JOKE_TTS_API_URL=                  # api/http backends only
  # DAD_JOKE_TTS_API_AUTH_HEADER='Authorization: Bearer <token>'   # api/http backends only
  ```

- All runtime knobs remain env vars, carried forward verbatim from the v3 README table (source of truth: `~/.tuple/triggers/dad-joke-greeter/README.md`): `DAD_JOKE_API_URL`, `DAD_JOKE_DEBOUNCE_SECONDS`, `DAD_JOKE_TTS_BACKEND`, `DAD_JOKE_TTS_TIMEOUT`, `DAD_JOKE_TTS_API_URL`, `DAD_JOKE_TTS_API_AUTH_HEADER`, `DAD_JOKE_GREETER_STATE_DIR`, `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `ELEVENLABS_KEYCHAIN_SERVICE`, `ELEVENLABS_MODEL_ID` (default `eleven_multilingual_v2`), `ELEVENLABS_OUTPUT_FORMAT` (default `mp3_44100_128`), `BLACKHOLE_DEVICE`, `BLACKHOLE_AUDIO_DEVICE_INDEX`.

## 3. TTS pipeline (adopt v3 verbatim)

- `speak_to_default_and_blackhole()` dispatches on `DAD_JOKE_TTS_BACKEND`: `say | elevenlabs | api | http`.
- `say` path: two parallel `say` invocations — system default output + `say -a "$BLACKHOLE_DEVICE"` (default `BlackHole 2ch`).
- ElevenLabs path: `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format=$ELEVENLABS_OUTPUT_FORMAT`, model `$ELEVENLABS_MODEL_ID`, `xi-api-key` header; playout = `afplay` (local) + `ffmpeg -f audiotoolbox -audio_device_index N` (BlackHole leg; index auto-resolved by parsing `ffmpeg -list_devices`, override `BLACKHOLE_AUDIO_DEVICE_INDEX`).
- ffmpeg is a prerequisite **for API backends only** (`brew install ffmpeg`); `afplay` cannot target a specific output device. Missing tool or any API failure → logged fallback to `say` (existing v3 behavior, kept).

## 4. Audio routing — micpipe primary

**Quick Setup (README):**

1. `brew install blackhole-2ch` — if BlackHole 2ch does not appear in Sound settings afterward, restart before continuing.
2. `cargo install micpipe` (≥0.2.0). Rust 1.88+ required — install via rustup.rs; builds from source (a few minutes). **No Rust? Use the aggregate-device appendix instead — setup.sh supports both paths.**
3. Foreground mic-permission test: run `micpipe run`, grant the macOS microphone permission when prompted, confirm the `Mic -> BlackHole 2ch` line, Ctrl-C. (A launchd-spawned service may never surface the TCC prompt; granting it in the foreground first avoids a "running but silently not capturing" service.)
4. `micpipe install` (launchd service; follows the system default input; `micpipe install --input "<mic>"` to pin).
5. Tuple → Preferences → Audio → Input Device = **BlackHole 2ch** (directly; no aggregate device — micpipe routes mic→BlackHole; BlackHole mixes mic + joke audio on both channels).

**Demand-gating / pre-call verification (README):** micpipe streams the mic into BlackHole only while some app is reading BlackHole as an input (Tuple in a call, or a recording app). The joke leg writes to BlackHole regardless and `say -a` exits 0 even with no consumer — inaudible outside a call simply because nothing is listening. To verify end-to-end before a call: QuickTime → New Audio Recording → input = BlackHole 2ch → record → run the setup.sh test-speak → the recording must contain both your voice and the joke.

**setup.sh (rewritten) — validation flow:**

1. Source `config.env` exactly as the runtime does (`set -a; . config.env; set +a` when present), so checks see the user's real config.
2. Required commands: `bash`, `curl`, `sleep`, `say`.
3. BlackHole present (`system_profiler SPAudioDataType`), honoring `${BLACKHOLE_DEVICE:-BlackHole 2ch}`.
4. **Routing branch:**
   - micpipe on PATH → validate the micpipe path: version ≥0.2.0 (parse second field of `micpipe --version`, compare with `sort -V`; unparseable → warning). `<0.2.0` → fail with `cargo install micpipe --force` (note the 0.1.0 plist bug). `micpipe status` not running → offer to run `micpipe install` (interactive Y/n); if BlackHole was just installed, suggest `micpipe restart`. Warn (echo hazard: doubled mic audio) if a "BH + Mic Input" aggregate device still exists while micpipe runs.
   - micpipe absent, aggregate device present → validate the aggregate path: keep v3's mono-mic-first / clock-source / 3-channel checks (moved behind this branch, not deleted).
   - neither → fail, pointing at Quick Setup step 2 and the appendix (aggregate = the no-Rust alternative; `rustup` pointer if `cargo` missing).
5. Launcher exec-bit repair: `run-trigger.sh`, `room-joined`, `room-left`, **and `call-ended`** exist and are executable (v3's script omits call-ended — fix during port; matters for Directory zips that strip exec bits).
6. If `${DAD_JOKE_TTS_BACKEND:-say}` is `elevenlabs|api|http`: check `ffmpeg` and `afplay`, absence = failure (user explicitly opted into an API backend). Backend `say`: print an informational skip.
7. `config.env` permissions warning (§2).
8. Joke API live test, then a **test-speak** through the configured backend, printing that the BlackHole leg is only audible to a BlackHole consumer (see pre-call verification above).
9. Prompt to set Tuple's input device (BlackHole 2ch on the micpipe path; "BH + Mic Input" on the aggregate path).

**README rewrite scope:** the live v3 README with only the audio-routing material replaced — "Manual audio setup" → micpipe Quick Setup; aggregate instructions + mono-mic guidance → appendix "Alternative: aggregate device (manual, no extra install)"; Known-limitation "Switching microphones" rewritten (micpipe ≥0.2.0 follows default-input changes; the aggregate variant of the limitation moves to the appendix). All other sections retained: How it works, Configuration env-var table, Configure API TTS, Limiting to specific rooms (tracked-rooms.txt semantics: absent/empty/comment-only → all rooms; case-sensitive exact match after trimming), Disabling temporarily, Stale state, plus new Upgrading-from-1.x (§5) and Directory-reinstall caveat (§1).

## 5. Migration & compat

README "Upgrading from 1.x" section, docs-only (no code fallbacks):

- **Step 0 — audio first (ordering matters):** if you used the v1 aggregate device: switch Tuple's input off "BH + Mic Input", delete it in Audio MIDI Setup, then follow Quick Setup steps 2–5. Keeping the aggregate selected while micpipe runs feeds your mic twice (direct + BlackHole copy) → echo/comb-filtering for remote participants. (setup.sh also warns — §4.4.)
- `mv ~/.tuple/tracked-rooms ~/.tuple/triggers/dad-joke-greeter/tracked-rooms.txt` (if present). **Semantics change:** v3 treats an empty or comment-only file as *no filter* (jokes in ALL rooms), where v1's empty file matched nothing (effective mute). If your v1 file was emptied as a mute, use `touch .disabled` instead. Lines starting with `#` are now comments; surrounding whitespace is trimmed.
- Disable flag: `~/.tuple/.dad-jokes-disabled` → `touch ~/.tuple/triggers/dad-joke-greeter/.disabled`.
- Stale state at `~/.tuple/.state/dad-joke-greeter` may be deleted; v3 state lives in the trigger dir's `.state/` (override: `DAD_JOKE_GREETER_STATE_DIR`).

## 6. Testing & verification

- Port the 11-test TAP suite (hermetic tmp contexts; PATH-injected stubs for curl/say/afplay/ffmpeg/security). Add: **missing-API-key → say fallback** (ELEVENLABS_API_KEY empty + `security` stub exiting 1) if not already covered; **config.env sourcing honored** (a config.env in the test context changes runtime behavior).
- `shellcheck` clean on `run-trigger.sh`, `setup.sh`, the three shims, and `test-dad-joke-greeter.sh`.
- Repo CI is structural only. Run it locally before pushing:
  `cd util && pnpm install && node -e 'require("./validate-triggers.js")({core:{setFailed:(m)=>{console.error(m);process.exitCode=1}}})'`
- Live verification on this machine (after the micpipe 0.2.0 publish prerequisite):
  - full test suite green;
  - **dual-writer check** (the untested core assumption): micpipe streaming the mic into BlackHole while the joke leg plays into BlackHole simultaneously; record BlackHole in QuickTime/Audacity (creates demand for the gating) and confirm both voice and joke are present, mixed;
  - `bash setup.sh` end-to-end on both branches of §4.4 (micpipe present; micpipe hidden from PATH with the aggregate device present).

## 7. Delivery

**Prerequisite (separate task, micpipe repo):** publish micpipe 0.2.0 to crates.io; then `cargo install micpipe --force` (replace the local path-build with the published artifact) and `micpipe uninstall && micpipe install`.

Branch `dad-joke-greeter-v3`, **two commits** (the v3 tree is one blended artifact; splitting runtime from TTS would require intermediate states that exist in no tree — rejected as the same three-way surgery the Context section rejected):

1. `dad-joke-greeter: adopt v3 shared runtime, TTS backends, and test suite` — run-trigger.sh, shims (incl. call-ended), tests, `.gitignore`, `config.env.example`; README/setup.sh carried from live tree as-is.
2. `dad-joke-greeter: recommend micpipe; aggregate device to appendix` — README rewrite, setup.sh rewrite (§4), migration docs (§5), new tests (§6) and any deltas they need.

Intermediate commit trees need not match the live install; only the final tree is verified.

**Verification gate before cleanup:** diff branch tree vs `~/.tuple/triggers/dad-joke-greeter` (excluding personal/state files). Expected deltas only: `.gitignore` (adds config.env), `config.env.example` (new), `README.md` + `setup.sh` (rewrites), `test-dad-joke-greeter.sh` (new tests), `config.json` (repo main's copy kept). `run-trigger.sh` must be byte-identical.

**Cleanup after the branch lands on origin:** delete local+origin `dad-joke-greeter-shared-runtime`, local `add-dad-joke-greeter`, local+origin `dad-joke-greeter-tracked-rooms-config`; drop `stash@{0}`; re-sync `~/.tuple/triggers/dad-joke-greeter` from the branch so install matches repo (back up `config.env`/`tracked-rooms.txt` per §1 caveat).

## Open questions (tracked, non-blocking)

- Whether upstream (tuple.app submission docs) has policy on third-party tool recommendations — surfaces at PR time; fork branch unaffected.
