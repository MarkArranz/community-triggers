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

## How it works

- When **you** join a tracked room, the trigger records which room you're in and schedules a dad joke.
- When **someone else** joins the same room, a dad joke is scheduled.
- If more people join the same room within 5 seconds, the timer restarts. After 5 quiet seconds, one dad joke is fetched and spoken aloud.
- When **you** leave the room, state is cleared and jokes stop.

## Quick setup

Run the included setup script to check prerequisites, create the audio device, and validate everything:

```bash
bash ~/.tuple/triggers/dad-joke-greeter/setup.sh
```

The script will walk you through each step interactively. If you prefer to set things up manually, follow the steps below.

## Prerequisites

- macOS
- No language runtime required; the trigger uses macOS `bash`, `curl`, `sleep`, and `say`
- [BlackHole 2ch](https://existential.audio/blackhole/) (free virtual audio driver)
- Optional API TTS backends also require `afplay` and `ffmpeg`

> **Note:** After installing BlackHole, you may need to restart your Mac (or log out and back in) before it appears as an audio device.

## Manual audio setup

The key trick is routing the joke audio into Tuple's microphone input so remote participants hear the joke. This requires a virtual audio loopback device.

### 1. Install BlackHole

```bash
brew install blackhole-2ch
```

If you want to use an API TTS backend, install ffmpeg too:

```bash
brew install ffmpeg
```

### 2. Create an aggregate audio device

Open **Audio MIDI Setup** (Spotlight -> "Audio MIDI Setup") and create a new aggregate device:

1. Click the **+** button in the bottom-left -> **Create Aggregate Device**
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

### 3. Configure Tuple

In Tuple, go to **Preferences -> Audio -> Input Device** and select **"BH + Mic Input"**.

Now Tuple receives both your voice (mic on channel 1) and the joke audio (BlackHole on channel 2).

### 4. Speaker output

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

The `room-joined` / `room-left` triggers are small bash launchers that delegate to `run-trigger.sh`. No Python, Ruby, Node, or package installation is needed.

### Configure API TTS

Tuple starts triggers from the macOS app, so environment variables set in your terminal usually will not be visible to the trigger. Put trigger-specific settings in a `config.env` file next to `run-trigger.sh`:

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
security add-generic-password -a "$USER" -s elevenlabs-api-key -w "$ELEVENLABS_API_KEY" -U
```

If `DAD_JOKE_TTS_BACKEND=elevenlabs` is set and the API key is missing or the API request fails, the trigger logs the error and falls back to `say`.

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

## Known limitations

- **Switching microphones:** The aggregate audio device is configured with a specific mic. If you swap between multiple inputs throughout the day (e.g. AirPods, built-in mic, headset), you'll need to update the aggregate device in Audio MIDI Setup to use the new mic. A future version may automate this by detecting the current input and rebuilding the aggregate on the fly.
- **Stale state after crash:** If Tuple crashes mid-call, the `room-left` trigger never fires and the state file that tracks which room you're in becomes stale. A subsequent join by someone else could trigger a joke even though you're no longer in the room. Rejoining a tracked room overwrites the stale room state automatically.
