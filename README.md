# Chatter (VoxScribe Pro)

Chatter is a single-page, browser-based conversational voice interface.
It captures speech from your microphone, sends conversation context to an AI backend, and reads responses aloud while showing a live transcript in the UI.

## What this application is

- **Frontend-only web app** built as a single `index.html` file.
- **Speech-driven chat experience** using browser speech recognition + speech synthesis.
- **Hybrid AI backend support** for:
  - **Gemini (cloud)** via an API key.
  - **Ollama models** discovered from your local machine or saved remote Ollama servers.

## Build / run instructions

No compile step is required.

1. Clone the repository.
2. Start a local static web server from the repo root (recommended):
   ```bash
   python3 -m http.server 8000
   ```
3. Open `http://localhost:8000` in a modern browser.
4. (Optional) Add one or two Gemini API keys from **Settings** in the app, then choose the active key.

> You can also open `index.html` directly, but a local server is recommended for consistent browser behavior.

### Container deploy

`deploy.sh` builds a small container that serves the app from `index.html` and exposes a local `/api/tts` endpoint backed by `espeak-ng` and Piper. The image bundles a default local Piper voice so both local TTS choices work without a separate server.

```bash
./deploy.sh 3014
```

- Arg 1: exposed port (default `3014`)
- Open `http://localhost:<port>/` or `http://localhost:<port>/index.html`.
- The bundled local TTS endpoint is available at `http://localhost:<port>/api/tts` and is used when **TTS: Local eSpeak**, **TTS: Local Piper**, or **TTS: Local Kokoro-82M** is selected in the app.
- **TTS: Local Piper** uses the same endpoint with `engine=piper`. The container includes a default `en_US-lessac-low` Piper voice; set `PIPER_MODEL` to a mounted Piper `.onnx` voice model path if you want to override it.
- **TTS: Local Kokoro-82M** uses the same endpoint with `engine=kokoro`. The container downloads Kokoro ONNX model files during build; set `KOKORO_MODEL`, `KOKORO_VOICES`, or `KOKORO_VOICE` to use mounted Kokoro files or a different voice.

## Basic controls

- **Start Conversation**: begins microphone capture and starts a voice session.
- **End Session**: stops the active voice/chat session.
- **Language selector**: sets speech recognition language.
- **AI Backend selector**: choose a local Ollama model, a saved remote Ollama model, plus Gemini cloud when at least one Gemini API key is saved in **Settings**.
- **Gemini key selector**: choose which saved Gemini API key Gemini cloud requests use. Saved keys can be named in **Settings** (for example, “Billing” or “Free”); if the selected slot is empty, the app falls back to the other saved key.
- **Stream tokens**: optionally render AI responses token-by-token as they arrive. With **TTS: Local eSpeak**, **TTS: Local Piper**, or **TTS: Local Kokoro-82M**, speech is queued in sentence or short phrase chunks as text streams in, so playback can start before the AI response is complete. Browser TTS still waits for the full response because browser speech synthesis does not accept incremental audio input.
- **TTS selector**: choose browser speech synthesis, the deployed local eSpeak service, the deployed local Piper service, or the deployed local Kokoro-82M service. The local options require running the app through `deploy.sh`; the container bundles eSpeak, a default Piper voice, and Kokoro-82M model files.
- **Settings (gear icon)**: name and save/update two Gemini API key slots, choose the active Gemini key, add/update/remove named remote Ollama servers, and set optional prompt behaviour/personality instructions. Saved prompt instructions override the default friendly British chat style; leave the field blank to use the default. Remote Ollama addresses must include the protocol and port, such as `http://192.168.1.20:11434`.
- **Transcript panel**: shows conversation turns and current output.
- **Text input box**: type a message and press **Send** (or Enter) as an alternative to speaking; use Shift+Enter for a new line.

## Troubleshooting

- **Microphone access blocked on a hostname (for example `http://ebg.dylanjones.org:3014`)**:
  browsers require a **secure context** for mic capture. Use HTTPS on your hostname
  (for example `https://ebg.dylanjones.org:3014` if you are still using that port), or run
  locally via `http://localhost:<port>`.

- **Remote Ollama is unreachable from the browser**:
  confirm the address is reachable from the device running the browser and that the remote Ollama service allows browser origins. Ollama may need `OLLAMA_HOST=0.0.0.0:11434` and an appropriate `OLLAMA_ORIGINS` setting on the remote computer.

## Roadmap (short)

- Add keyboard accessibility shortcuts for all primary actions.
- Add transcript export options (TXT/JSON).
- Add basic automated checks (lint/format) and CI workflow.
