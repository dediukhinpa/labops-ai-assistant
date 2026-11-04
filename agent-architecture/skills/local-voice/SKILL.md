---
name: local-voice
description: Transcribe an audio or voice file (.ogg/.oga/.mp3/.wav) with the LOCAL voice-transcriber service (faster-whisper on this host). Use when a message carries a voice attachment whose transcript is missing (transcription_status is failed or unavailable) or when the user sends an audio file the channel did not transcribe.
---

# Local Voice Transcription

Voice messages from Telegram are transcribed by the channel plugin automatically: the
transcript arrives in the `<media kind="voice" ... transcript="..." />` tag. This skill is
the manual path for everything else: a voice message whose `transcription_status` is
`failed` / `unavailable` / `skipped` (the service was down or busy), and audio files the
plugin never transcribes (`<media kind="audio" ...>`, audio documents in the inbox).

Everything runs on this host. The audio is sent only to the local `voice-transcriber`
service (`127.0.0.1`); there is no external fallback, and the script refuses any
non-loopback `VOICE_TRANSCRIBER_URL`. Voice can contain personal data: never upload it
to any other transcription service by hand either.

## How to use

1. Get the file path: from the `[media attached: PATH ...]` line, or download the
   attachment with the channel tool first.
2. Run:
```
bash "$AGENT_WORKSPACE/skills/local-voice/transcribe.sh" "/path/to/file.ogg"
```
   Optional second argument: language code (`ru` by default, `en`, ..., or `auto`).
   (`skills/` in the agent workspace is a link to the shared skills directory.)
3. Answer the content of what the user said. Do not mention the transcription process
   unless asked.

## If it fails

- `HTTP 503` — the service is loading the model or is busy; wait ~10 s and retry once.
- `HTTP 413` — the audio is too long (limit is in the service config, 5 minutes by default).
- `HTTP 401` / no token — the token `VOICE_TRANSCRIBER_TOKEN` is not set for this agent;
  tell the operator.
- `000` — the service is not running.
- In every failure case tell the user briefly that you could not process the voice
  message and ask them to send text. Do NOT say "I can't listen to audio" — the service
  can do it when it is up — and do NOT try another transcription service.
