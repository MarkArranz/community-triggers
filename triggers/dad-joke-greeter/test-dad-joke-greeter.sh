#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d /tmp/dad-joke-greeter-test.XXXXXX)"
ORIGINAL_PATH="$PATH"
tests_run=0

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  tests_run=$((tests_run + 1))
  printf 'ok %d - %s\n' "$tests_run" "$*"
}

assert_file_exists() {
  [ -f "$1" ] || fail "expected file to exist: $1"
}

assert_file_not_exists() {
  [ ! -f "$1" ] || fail "expected file to be absent: $1"
}

assert_file_equals() {
  local path="$1"
  local expected="$2"
  local actual
  assert_file_exists "$path"
  actual="$(cat "$path")"
  [ "$actual" = "$expected" ] || fail "expected $path to be '$expected', got '$actual'"
}

assert_contains() {
  local path="$1"
  local needle="$2"
  assert_file_exists "$path"
  grep -Fq -- "$needle" "$path" || {
    printf '--- %s ---\n' "$path" >&2
    cat "$path" >&2
    fail "expected $path to contain: $needle"
  }
}

assert_not_contains() {
  local path="$1"
  local needle="$2"
  if [ -f "$path" ] && grep -Fq -- "$needle" "$path"; then
    printf '--- %s ---\n' "$path" >&2
    cat "$path" >&2
    fail "expected $path not to contain: $needle"
  fi
}

wait_until() {
  local check="$1"
  local attempts=80
  while [ "$attempts" -gt 0 ]; do
    if eval "$check"; then
      return 0
    fi
    attempts=$((attempts - 1))
    sleep 0.05
  done
  return 1
}

make_context() {
  CTX="$(mktemp -d "${TMP_ROOT}/case.XXXXXX")"
  TRIGGER_DIR="${CTX}/dad-joke-greeter"
  STATE_DIR="${CTX}/state"
  BIN_DIR="${CTX}/bin"
  SAY_LOG="${CTX}/say.log"
  CURL_LOG="${CTX}/curl.log"
  AFPLAY_LOG="${CTX}/afplay.log"
  FFMPEG_LOG="${CTX}/ffmpeg.log"
  mkdir -p "$TRIGGER_DIR" "$STATE_DIR" "$BIN_DIR"
  cp "$ROOT/run-trigger.sh" "$ROOT/room-joined" "$ROOT/room-left" "$ROOT/call-ended" "$TRIGGER_DIR/"
  chmod +x "$TRIGGER_DIR/run-trigger.sh" "$TRIGGER_DIR/room-joined" "$TRIGGER_DIR/room-left" "$TRIGGER_DIR/call-ended"

  cat >"${BIN_DIR}/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "curl $*" >>"${DAD_JOKE_TEST_CURL_LOG}"
output_file=""
is_tts=false
for arg in "$@"; do
  case "$arg" in
    *text-to-speech*|*tts.example*)
      is_tts=true
      ;;
  esac
done
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      shift
      output_file="${1:-}"
      ;;
  esac
  shift || break
done
if [ "$is_tts" = "true" ]; then
  if [ -n "$output_file" ]; then
    printf '%s' "fake audio" >"$output_file"
  fi
  printf '%s' "${DAD_JOKE_TEST_TTS_STATUS:-200}"
else
  printf '%s\n' "${DAD_JOKE_TEST_RESPONSE:-knock knock}"
fi
STUB
  chmod +x "${BIN_DIR}/curl"

  cat >"${BIN_DIR}/say" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DAD_JOKE_TEST_SAY_LOG}"
exit "${DAD_JOKE_TEST_SAY_STATUS:-0}"
STUB
  chmod +x "${BIN_DIR}/say"

  cat >"${BIN_DIR}/afplay" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DAD_JOKE_TEST_AFPLAY_LOG}"
exit "${DAD_JOKE_TEST_AFPLAY_STATUS:-0}"
STUB
  chmod +x "${BIN_DIR}/afplay"

  cat >"${BIN_DIR}/ffmpeg" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DAD_JOKE_TEST_FFMPEG_LOG}"
for arg in "$@"; do
  if [ "$arg" = "-list_devices" ]; then
    printf '%s\n' "[6]                  BlackHole 2ch, BlackHole2ch_UID" >&2
    exit 0
  fi
done
exit "${DAD_JOKE_TEST_FFMPEG_STATUS:-0}"
STUB
  chmod +x "${BIN_DIR}/ffmpeg"

  cat >"${BIN_DIR}/security" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "${BIN_DIR}/security"
}

run_event() {
  env \
    PATH="${BIN_DIR}:${ORIGINAL_PATH}" \
    DAD_JOKE_GREETER_STATE_DIR="$STATE_DIR" \
    DAD_JOKE_DEBOUNCE_SECONDS="${DAD_JOKE_DEBOUNCE_SECONDS:-0}" \
    DAD_JOKE_TTS_BACKEND="${DAD_JOKE_TTS_BACKEND:-}" \
    DAD_JOKE_TTS_API_URL="${DAD_JOKE_TTS_API_URL:-}" \
    DAD_JOKE_TTS_API_AUTH_HEADER="${DAD_JOKE_TTS_API_AUTH_HEADER:-}" \
    ELEVENLABS_API_KEY="${ELEVENLABS_API_KEY:-}" \
    ELEVENLABS_VOICE_ID="${ELEVENLABS_VOICE_ID:-}" \
    ELEVENLABS_MODEL_ID="${ELEVENLABS_MODEL_ID:-}" \
    ELEVENLABS_OUTPUT_FORMAT="${ELEVENLABS_OUTPUT_FORMAT:-}" \
    DAD_JOKE_TEST_SAY_LOG="$SAY_LOG" \
    DAD_JOKE_TEST_CURL_LOG="$CURL_LOG" \
    DAD_JOKE_TEST_AFPLAY_LOG="$AFPLAY_LOG" \
    DAD_JOKE_TEST_FFMPEG_LOG="$FFMPEG_LOG" \
    DAD_JOKE_TEST_RESPONSE="${DAD_JOKE_TEST_RESPONSE:-knock knock}" \
    DAD_JOKE_TEST_TTS_STATUS="${DAD_JOKE_TEST_TTS_STATUS:-200}" \
    "$TRIGGER_DIR/run-trigger.sh" "$@"
}

write_pending() {
  local token="$1"
  local room="$2"
  local joiner="$3"
  local source="$4"
  mkdir -p "$STATE_DIR"
  {
    printf '%s\n' "$token"
    printf '%s\n' "$room"
    printf '%s\n' "$joiner"
    printf '%s\n' "$source"
    printf '%s\n' "0"
  } >"${STATE_DIR}/pending-joke"
}

prepare_worker_joke() {
  make_context
  printf '%s' "Example Room" >"${STATE_DIR}/my-room"
  write_pending "tok" "Example Room" "Guest User" "room-joined"
}

test_self_join_schedules_and_speaks() {
  make_context
  printf '%s\n' "Example Room" >"${TRIGGER_DIR}/tracked-rooms.txt"

  TUPLE_TRIGGER_IS_SELF=true \
  TUPLE_TRIGGER_ROOM_NAME="Example Room" \
  TUPLE_TRIGGER_FULL_NAME="Current User" \
  run_event room-joined

  assert_file_equals "${STATE_DIR}/my-room" "Example Room"
  wait_until "[ -f '$SAY_LOG' ] && grep -Fq 'Current User just joined. Here is a dad joke. knock knock' '$SAY_LOG'" \
    || fail "worker did not speak self-join joke"
  assert_contains "$CURL_LOG" "Accept: text/plain"
  assert_file_not_exists "${STATE_DIR}/pending-joke"
  pass "self join schedules and speaks one joke"
}

test_non_self_join_without_self_room_skips() {
  make_context
  printf '%s\n' "Example Room" >"${TRIGGER_DIR}/tracked-rooms.txt"

  TUPLE_TRIGGER_IS_SELF=false \
  TUPLE_TRIGGER_ROOM_NAME="Example Room" \
  TUPLE_TRIGGER_FULL_NAME="Guest User" \
  run_event room-joined

  assert_file_not_exists "${STATE_DIR}/pending-joke"
  assert_file_not_exists "$SAY_LOG"
  pass "non-self join skips without self room state"
}

test_worker_supersede_and_happy_path() {
  make_context
  printf '%s' "Example Room" >"${STATE_DIR}/my-room"
  write_pending "old" "Example Room" "Earlier Guest" "room-joined"
  write_pending "new" "Example Room" "Guest User" "room-joined"

  run_event worker --room "Example Room" --token "old"
  assert_not_contains "$SAY_LOG" "Earlier Guest just joined"
  assert_file_exists "${STATE_DIR}/pending-joke"

  run_event worker --room "Example Room" --token "new"
  assert_contains "$SAY_LOG" "Guest User just joined. Here is a dad joke. knock knock"
  assert_file_not_exists "${STATE_DIR}/pending-joke"
  pass "worker supersedes stale token and speaks current token"
}

test_worker_disabled_clears_without_fetch() {
  make_context
  printf '%s' "Example Room" >"${STATE_DIR}/my-room"
  touch "${TRIGGER_DIR}/.disabled"
  write_pending "tok" "Example Room" "Guest User" "room-joined"

  run_event worker --room "Example Room" --token "tok"

  assert_file_not_exists "$CURL_LOG"
  assert_file_not_exists "$SAY_LOG"
  assert_file_not_exists "${STATE_DIR}/pending-joke"
  pass "disabled worker clears pending joke without fetching"
}

test_room_left_clears_state() {
  make_context
  printf '%s' "Example Room" >"${STATE_DIR}/my-room"
  write_pending "tok" "Example Room" "Guest User" "room-joined"

  TUPLE_TRIGGER_IS_SELF=true \
  TUPLE_TRIGGER_ROOM_NAME="Example Room" \
  TUPLE_TRIGGER_FULL_NAME="Current User" \
  run_event room-left

  assert_file_not_exists "${STATE_DIR}/my-room"
  assert_file_not_exists "${STATE_DIR}/pending-joke"
  pass "room-left clears current self room and pending joke"
}

test_mismatched_room_left_clears_state() {
  make_context
  printf '%s' "Example Room" >"${STATE_DIR}/my-room"
  write_pending "tok" "Example Room" "Guest User" "room-joined"

  TUPLE_TRIGGER_IS_SELF=true \
  TUPLE_TRIGGER_ROOM_NAME="Other Room" \
  TUPLE_TRIGGER_FULL_NAME="Current User" \
  run_event room-left

  assert_file_not_exists "${STATE_DIR}/my-room"
  assert_file_not_exists "${STATE_DIR}/pending-joke"
  pass "mismatched room-left clears stale self room state"
}

test_call_ended_clears_state() {
  make_context
  printf '%s' "Example Room" >"${STATE_DIR}/my-room"
  write_pending "tok" "Example Room" "Guest User" "room-joined"

  run_event call-ended

  assert_file_not_exists "${STATE_DIR}/my-room"
  assert_file_not_exists "${STATE_DIR}/pending-joke"
  pass "call-ended clears self room and pending joke"
}

test_elevenlabs_backend_uses_api_audio_players() {
  prepare_worker_joke

  DAD_JOKE_TTS_BACKEND=elevenlabs \
  ELEVENLABS_API_KEY=test-key \
  ELEVENLABS_VOICE_ID=test-voice \
  run_event worker --room "Example Room" --token "tok"

  assert_contains "$CURL_LOG" "text-to-speech/test-voice?output_format=mp3_44100_128"
  assert_contains "$CURL_LOG" "xi-api-key: test-key"
  assert_contains "$AFPLAY_LOG" "dad-joke-tts.mp3"
  assert_contains "$FFMPEG_LOG" "-audio_device_index 6"
  assert_file_not_exists "$SAY_LOG"
  assert_file_not_exists "${STATE_DIR}/pending-joke"
  pass "ElevenLabs backend posts joke text and plays API audio"
}

test_custom_api_backend_posts_text_and_plays_audio() {
  prepare_worker_joke

  DAD_JOKE_TTS_BACKEND=api \
  DAD_JOKE_TTS_API_URL="https://tts.example/speak" \
  DAD_JOKE_TTS_API_AUTH_HEADER="Authorization: Bearer token" \
  run_event worker --room "Example Room" --token "tok"

  assert_contains "$CURL_LOG" "https://tts.example/speak"
  assert_contains "$CURL_LOG" "Authorization: Bearer token"
  assert_contains "$CURL_LOG" "Content-Type: application/json"
  assert_contains "$AFPLAY_LOG" "dad-joke-tts.mp3"
  assert_contains "$FFMPEG_LOG" "-audio_device_index 6"
  assert_file_not_exists "$SAY_LOG"
  assert_file_not_exists "${STATE_DIR}/pending-joke"
  pass "custom API backend posts joke text and plays API audio"
}

test_api_backend_failure_falls_back_to_say() {
  prepare_worker_joke

  DAD_JOKE_TTS_BACKEND=elevenlabs \
  DAD_JOKE_TEST_TTS_STATUS=500 \
  ELEVENLABS_API_KEY=test-key \
  ELEVENLABS_VOICE_ID=test-voice \
  run_event worker --room "Example Room" --token "tok"

  assert_contains "$CURL_LOG" "text-to-speech/test-voice"
  assert_file_not_exists "$AFPLAY_LOG"
  assert_contains "$SAY_LOG" "Guest User just joined. Here is a dad joke. knock knock"
  assert_contains "$SAY_LOG" "-a BlackHole 2ch"
  assert_file_not_exists "${STATE_DIR}/pending-joke"
  pass "API backend failure falls back to say"
}

test_comment_only_tracked_rooms_tracks_all() {
  make_context
  printf '%s\n\n' "# comments only" >"${TRIGGER_DIR}/tracked-rooms.txt"

  TUPLE_TRIGGER_IS_SELF=true \
  TUPLE_TRIGGER_ROOM_NAME="Any Room" \
  TUPLE_TRIGGER_FULL_NAME="Current User" \
  run_event room-joined

  wait_until "[ -f '$SAY_LOG' ] && grep -Fq 'Current User just joined. Here is a dad joke. knock knock' '$SAY_LOG'" \
    || fail "comment-only tracked rooms did not track all"
  pass "comment-only tracked rooms file tracks all rooms"
}

test_self_join_schedules_and_speaks
test_non_self_join_without_self_room_skips
test_worker_supersede_and_happy_path
test_worker_disabled_clears_without_fetch
test_room_left_clears_state
test_mismatched_room_left_clears_state
test_call_ended_clears_state
test_elevenlabs_backend_uses_api_audio_players
test_custom_api_backend_posts_text_and_plays_audio
test_api_backend_failure_falls_back_to_say
test_comment_only_tracked_rooms_tracks_all
