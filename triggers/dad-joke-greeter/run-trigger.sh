#!/usr/bin/env bash
# Shared runtime for the dad-joke-greeter Tuple triggers.
#
# Tuple runs trigger scripts from the macOS GUI, where shell PATH and language
# runtimes can be surprising. Keep this trigger shell-only and use macOS tools:
# bash, curl, sleep, and say. Optional API TTS backends also use afplay and ffmpeg.
set -uo pipefail

event="${1:?usage: run-trigger.sh <room-joined|room-left|call-ended|worker> [args...]}"
shift

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_env_file="${script_dir}/config.env"

if [ -f "$config_env_file" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$config_env_file"
  set +a
fi

trigger_default_path="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [ -n "${PATH:-}" ]; then
  PATH="${PATH}:${trigger_default_path}"
else
  PATH="$trigger_default_path"
fi
export PATH

state_dir="${DAD_JOKE_GREETER_STATE_DIR:-${script_dir}/.state}"
my_room_file="${state_dir}/my-room"
pending_file="${state_dir}/pending-joke"
legacy_pending_json_file="${state_dir}/pending-joke.json"
worker_log_file="${state_dir}/debounced-worker.log"
say_errors_file="${state_dir}/say-errors.log"
tracked_rooms_file="${script_dir}/tracked-rooms.txt"
disabled_file="${script_dir}/.disabled"

api_url="${DAD_JOKE_API_URL:-https://icanhazdadjoke.com/}"
blackhole_device="${BLACKHOLE_DEVICE:-BlackHole 2ch}"
tts_backend="${DAD_JOKE_TTS_BACKEND:-say}"
tts_timeout="${DAD_JOKE_TTS_TIMEOUT:-30}"
elevenlabs_voice_id="${ELEVENLABS_VOICE_ID:-CwhRBWXzGAHq8TQ4Fs17}"
elevenlabs_model_id="${ELEVENLABS_MODEL_ID:-eleven_multilingual_v2}"
elevenlabs_output_format="${ELEVENLABS_OUTPUT_FORMAT:-mp3_44100_128}"
elevenlabs_keychain_service="${ELEVENLABS_KEYCHAIN_SERVICE:-elevenlabs-api-key}"
default_debounce_seconds="5"

pending_token=""
pending_room=""
pending_joiner=""
pending_source=""

timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

log() {
  printf '%s [dad-joke-greeter] %s\n' "$(timestamp)" "$*"
}

log_err() {
  printf '%s [dad-joke-greeter] %s\n' "$(timestamp)" "$*" >&2
}

ensure_state_dir() {
  mkdir -p "$state_dir"
}

sanitize_text() {
  local value="${1:-}"
  value="$(printf '%s' "$value" | tr -cd '[:print:]')"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "someone"
  fi
}

trim_line() {
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

write_text_atomic() {
  local path="$1"
  local text="$2"
  local tmp
  mkdir -p "$(dirname "$path")" || return 1
  tmp="${path}.$$.$(uuidgen 2>/dev/null || printf '%s' "$RANDOM").tmp"
  printf '%s' "$text" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$path"
}

room_is_tracked() {
  local room="$1"
  local line name
  local saw_room=0

  [ -f "$tracked_rooms_file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    name="$(printf '%s' "$line" | trim_line)"
    [ -n "$name" ] || continue
    case "$name" in
      \#*) continue ;;
    esac
    saw_room=1
    [ "$name" = "$room" ] && return 0
  done <"$tracked_rooms_file"

  [ "$saw_room" -eq 0 ]
}

new_token() {
  printf '%s-%s-%s' "$(date +%s%N)" "$$" "$(uuidgen 2>/dev/null || printf '%s' "$RANDOM")"
}

write_pending_joke() {
  local token="$1"
  local room="$2"
  local joiner="$3"
  local source="$4"
  local tmp

  ensure_state_dir || return 1
  tmp="${pending_file}.$$.$(uuidgen 2>/dev/null || printf '%s' "$RANDOM").tmp"
  {
    printf '%s\n' "$token"
    printf '%s\n' "$room"
    printf '%s\n' "$joiner"
    printf '%s\n' "$source"
    printf '%s\n' "$(date +%s)"
  } >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$pending_file"
}

read_pending_joke() {
  [ -f "$pending_file" ] || return 1

  {
    IFS= read -r pending_token
    IFS= read -r pending_room
    IFS= read -r pending_joiner
    IFS= read -r pending_source
  } <"$pending_file" || {
    log_err "Ignoring invalid pending joke state"
    return 1
  }

  if [ -z "$pending_token" ] || [ -z "$pending_room" ] || [ -z "$pending_joiner" ] || [ -z "$pending_source" ]; then
    log_err "Ignoring invalid pending joke state"
    return 1
  fi

  return 0
}

clear_pending_joke_if_current() {
  local room="$1"
  local token="$2"
  read_pending_joke || return 0
  if [ "$pending_room" = "$room" ] && [ "$pending_token" = "$token" ]; then
    rm -f "$pending_file" "$legacy_pending_json_file"
  fi
}

clear_room_state() {
  rm -f "$my_room_file" "$pending_file" "$legacy_pending_json_file"
}

parse_debounce_seconds() {
  local raw="${DAD_JOKE_DEBOUNCE_SECONDS:-$default_debounce_seconds}"
  case "$raw" in
    -*)
      log_err "Negative DAD_JOKE_DEBOUNCE_SECONDS=${raw}; clamping to 0"
      printf '%s' "0"
      ;;
    ""|*[!0123456789.]*|*.*.*)
      log_err "Invalid DAD_JOKE_DEBOUNCE_SECONDS=${raw}; using default ${default_debounce_seconds}"
      printf '%s' "$default_debounce_seconds"
      ;;
    *)
      printf '%s' "$raw"
      ;;
  esac
}

spawn_worker() {
  local room="$1"
  local token="$2"

  ensure_state_dir || return 1
  nohup "$script_dir/run-trigger.sh" worker --room "$room" --token "$token" >>"$worker_log_file" 2>&1 &
}

schedule_debounced_joke() {
  local room="$1"
  local joiner="$2"
  local source="$3"
  local token

  token="$(new_token)"
  write_pending_joke "$token" "$room" "$joiner" "$source" || return 1
  log "Scheduled debounced joke for ${joiner} in ${room}"
  spawn_worker "$room" "$token"
}

fetch_joke() {
  local response joke

  response="$(
    curl -fsS --max-time 5 \
      -H "Accept: text/plain" \
      -H "User-Agent: TupleDadJokeGreeter/3.0 (https://github.com/tupleapp/community-triggers)" \
      "$api_url"
  )" || return 1

  joke="$(printf '%s' "$response" | tr '\r\n' '  ' | trim_line)"
  [ -n "$joke" ] || return 1
  printf '%s' "$joke"
}

json_escape() {
  sed 's/\\/\\\\/g;s/"/\\"/g'
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    log_err "Missing required command for ${tts_backend} TTS backend: ${command_name}"
    return 1
  fi
}

audiotoolbox_device_index() {
  local device_name="$1"
  local ffmpeg_output

  ffmpeg_output="$(
    ffmpeg -hide_banner -nostdin \
      -f lavfi -i anullsrc=r=44100:cl=mono \
      -t 0.01 \
      -f audiotoolbox -list_devices true - 2>&1 || true
  )"

  printf '%s\n' "$ffmpeg_output" |
    awk -v device_name="$device_name" '
      match($0, /\[[0-9]+\] /) {
        device_idx = substr($0, RSTART + 1, RLENGTH - 3)
        name = substr($0, RSTART + RLENGTH)
        sub(/^[[:space:]]+/, "", name)
        sub(/,.*/, "", name)
        if (name == device_name) {
          print device_idx
          exit
        }
      }
    '
}

play_audio_file_to_default_and_blackhole() {
  local audio_file="$1"
  local local_pid blackhole_pid local_status blackhole_status device_index

  require_command afplay || return 1
  require_command ffmpeg || return 1

  afplay "$audio_file" 2>>"$say_errors_file" &
  local_pid=$!

  device_index="${BLACKHOLE_AUDIO_DEVICE_INDEX:-}"
  if [ -z "$device_index" ]; then
    device_index="$(audiotoolbox_device_index "$blackhole_device")"
  fi

  if [ -n "$device_index" ]; then
    ffmpeg -hide_banner -nostdin -loglevel error \
      -i "$audio_file" \
      -vn \
      -f audiotoolbox \
      -audio_device_index "$device_index" \
      - >>"$say_errors_file" 2>&1 &
    blackhole_pid=$!
  else
    log_err "Could not resolve BlackHole output device '${blackhole_device}' for API TTS backend"
    blackhole_pid=""
  fi

  wait "$local_pid"
  local_status=$?

  blackhole_status=0
  if [ -n "$blackhole_pid" ]; then
    wait "$blackhole_pid"
    blackhole_status=$?
  else
    blackhole_status=1
  fi

  if [ "$blackhole_status" -ne 0 ]; then
    log_err "Joke played locally but the BlackHole leg failed (device '${blackhole_device}'); remote participants may not have heard it. See ${say_errors_file} for details"
  fi

  return "$local_status"
}

curl_tts_audio() {
  local url="$1"
  local payload="$2"
  local output_file="$3"
  local auth_header="${4:-}"
  local http_status

  if [ -n "$auth_header" ]; then
    http_status="$(
      curl -sS --max-time "$tts_timeout" \
        -X POST "$url" \
        -H "Accept: audio/mpeg" \
        -H "Content-Type: application/json" \
        -H "$auth_header" \
        --data "$payload" \
        -o "$output_file" \
        -w "%{http_code}" \
        2>>"$say_errors_file" || true
    )"
  else
    http_status="$(
      curl -sS --max-time "$tts_timeout" \
        -X POST "$url" \
        -H "Accept: audio/mpeg" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        -o "$output_file" \
        -w "%{http_code}" \
        2>>"$say_errors_file" || true
    )"
  fi

  case "$http_status" in
    2*) ;;
    *)
      log_err "TTS API request failed with HTTP ${http_status}"
      return 1
      ;;
  esac

  [ -s "$output_file" ] || {
    log_err "TTS API returned an empty audio response"
    return 1
  }
}

synthesize_with_elevenlabs() {
  local text="$1"
  local output_file="$2"
  local api_key="${ELEVENLABS_API_KEY:-}"
  local escaped_text escaped_model payload url

  if [ -z "$api_key" ] && command -v security >/dev/null 2>&1; then
    api_key="$(security find-generic-password -a "$USER" -s "$elevenlabs_keychain_service" -w 2>/dev/null || true)"
  fi

  if [ -z "$api_key" ]; then
    log_err "ElevenLabs TTS backend requested but ELEVENLABS_API_KEY is missing"
    return 1
  fi

  escaped_text="$(printf '%s' "$text" | json_escape)"
  escaped_model="$(printf '%s' "$elevenlabs_model_id" | json_escape)"
  payload="{\"text\":\"${escaped_text}\",\"model_id\":\"${escaped_model}\"}"
  url="https://api.elevenlabs.io/v1/text-to-speech/${elevenlabs_voice_id}?output_format=${elevenlabs_output_format}"

  curl_tts_audio "$url" "$payload" "$output_file" "xi-api-key: ${api_key}"
}

synthesize_with_custom_api() {
  local text="$1"
  local output_file="$2"
  local url="${DAD_JOKE_TTS_API_URL:-}"
  local auth_header="${DAD_JOKE_TTS_API_AUTH_HEADER:-}"
  local escaped_text payload

  if [ -z "$url" ]; then
    log_err "API TTS backend requested but DAD_JOKE_TTS_API_URL is missing"
    return 1
  fi

  escaped_text="$(printf '%s' "$text" | json_escape)"
  payload="{\"text\":\"${escaped_text}\"}"

  curl_tts_audio "$url" "$payload" "$output_file" "$auth_header"
}

speak_with_api_backend() {
  local text="$1"
  local tmp_dir audio_file synth_status play_status

  require_command curl || return 1
  require_command afplay || return 1
  require_command ffmpeg || return 1
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dad-joke-tts.XXXXXX")" || return 1
  audio_file="${tmp_dir}/dad-joke-tts.mp3"

  case "$tts_backend" in
    elevenlabs)
      synthesize_with_elevenlabs "$text" "$audio_file"
      synth_status=$?
      ;;
    api|http)
      synthesize_with_custom_api "$text" "$audio_file"
      synth_status=$?
      ;;
    *)
      log_err "Unknown API TTS backend: ${tts_backend}"
      synth_status=1
      ;;
  esac

  if [ "$synth_status" -ne 0 ]; then
    rm -rf "$tmp_dir"
    return "$synth_status"
  fi

  play_audio_file_to_default_and_blackhole "$audio_file"
  play_status=$?
  rm -rf "$tmp_dir"
  return "$play_status"
}

speak_with_say() {
  local text="$1"
  local local_pid blackhole_pid local_status blackhole_status

  require_command say || return 1
  ensure_state_dir || return 1
  say -- "$text" 2>>"$say_errors_file" &
  local_pid=$!
  say -a "$blackhole_device" -- "$text" 2>>"$say_errors_file" &
  blackhole_pid=$!

  wait "$local_pid"
  local_status=$?
  wait "$blackhole_pid"
  blackhole_status=$?

  if [ "$blackhole_status" -ne 0 ]; then
    log_err "Joke played locally but the BlackHole leg failed (device '${blackhole_device}'); remote participants may not have heard it. See ${say_errors_file} for details"
  fi

  return "$local_status"
}

speak_to_default_and_blackhole() {
  local text="$1"

  ensure_state_dir || return 1
  case "$tts_backend" in
    say|"")
      speak_with_say "$text"
      ;;
    elevenlabs|api|http)
      if speak_with_api_backend "$text"; then
        return 0
      fi
      log_err "Falling back to say after ${tts_backend} TTS backend failed"
      speak_with_say "$text"
      ;;
    *)
      log_err "Unknown DAD_JOKE_TTS_BACKEND=${tts_backend}; falling back to say"
      speak_with_say "$text"
      ;;
  esac
}

handle_room_joined() {
  local is_self="${TUPLE_TRIGGER_IS_SELF:-false}"
  local room="${TUPLE_TRIGGER_ROOM_NAME:-}"
  local full_name
  local my_room

  [ -f "$disabled_file" ] && return 0

  if [ -z "$room" ]; then
    log "Skipping room-joined: no room name"
    return 0
  fi

  if ! room_is_tracked "$room"; then
    log "Skipping untracked room: ${room}"
    return 0
  fi

  ensure_state_dir || return 1
  full_name="$(sanitize_text "${TUPLE_TRIGGER_FULL_NAME:-someone}")"

  if [ "$(printf '%s' "$is_self" | tr '[:upper:]' '[:lower:]')" = "true" ]; then
    write_text_atomic "$my_room_file" "$room" || return 1
    log "Tracking self in room: ${room}"
    schedule_debounced_joke "$room" "$full_name" "self-joined-tracked-room"
    return $?
  fi

  if [ ! -f "$my_room_file" ]; then
    log "Skipping room-joined for ${room}: no self room state"
    return 0
  fi

  my_room="$(cat "$my_room_file")"
  if [ "$my_room" != "$room" ]; then
    log "Skipping room-joined for ${room}: currently tracking ${my_room}"
    return 0
  fi

  schedule_debounced_joke "$room" "$full_name" "room-joined"
}

handle_room_left() {
  local is_self="${TUPLE_TRIGGER_IS_SELF:-false}"
  local room="${TUPLE_TRIGGER_ROOM_NAME:-}"
  local my_room

  [ "$(printf '%s' "$is_self" | tr '[:upper:]' '[:lower:]')" = "true" ] || return 0
  [ -f "$my_room_file" ] || return 0

  my_room="$(cat "$my_room_file")"
  if [ -z "$room" ] || [ "$my_room" = "$room" ]; then
    clear_room_state
    log "Cleared self room state: ${my_room}"
  else
    clear_room_state
    log "Cleared self room state ${my_room}; ignored mismatched leave for ${room}"
  fi
}

handle_call_ended() {
  ensure_state_dir || return 1
  clear_room_state
  log "Cleared self room state on call-ended"
}

run_worker() {
  local room=""
  local token=""
  local debounce_seconds
  local my_room
  local joke
  local text
  local status

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --room)
        shift
        room="${1:-}"
        ;;
      --token)
        shift
        token="${1:-}"
        ;;
      *)
        log_err "Unknown worker argument: $1"
        return 1
        ;;
    esac
    shift || break
  done

  if [ -z "$room" ] || [ -z "$token" ]; then
    log_err "Debounce worker missing room or token"
    return 1
  fi

  debounce_seconds="$(parse_debounce_seconds)"
  sleep "$debounce_seconds"

  read_pending_joke || return 0
  if [ "$pending_token" != "$token" ] || [ "$pending_room" != "$room" ]; then
    log "Debounced join superseded for ${room}"
    return 0
  fi

  if [ ! -f "$my_room_file" ]; then
    log "Skipping debounced joke for ${room}: no self room state"
    clear_pending_joke_if_current "$room" "$token"
    return 0
  fi

  my_room="$(cat "$my_room_file")"
  if [ "$my_room" != "$room" ]; then
    log "Skipping debounced joke for ${room}: currently tracking ${my_room}"
    clear_pending_joke_if_current "$room" "$token"
    return 0
  fi

  if [ -f "$disabled_file" ]; then
    log "Skipping debounced joke for ${room}: trigger disabled"
    clear_pending_joke_if_current "$room" "$token"
    return 0
  fi

  joke="$(fetch_joke)" || {
    log_err "Failed to fetch joke"
    clear_pending_joke_if_current "$room" "$token"
    return 1
  }

  read_pending_joke || return 0
  if [ "$pending_token" != "$token" ] || [ "$pending_room" != "$room" ]; then
    log "Debounced join superseded during joke fetch for ${room}"
    return 0
  fi

  text="${pending_joiner} just joined. Here is a dad joke. ${joke}"
  speak_to_default_and_blackhole "$text"
  status=$?
  if [ "$status" -eq 0 ]; then
    log "Told joke for ${pending_source} to ${pending_joiner}: ${joke}"
  else
    log_err "Failed to speak joke for ${pending_source} to ${pending_joiner}"
  fi
  clear_pending_joke_if_current "$room" "$token"
  return "$status"
}

case "$event" in
  room-joined)
    handle_room_joined "$@"
    ;;
  room-left)
    handle_room_left "$@"
    ;;
  call-ended)
    handle_call_ended "$@"
    ;;
  worker)
    run_worker "$@"
    ;;
  *)
    log_err "Unknown event: ${event}"
    exit 1
    ;;
esac
