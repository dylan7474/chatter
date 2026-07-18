# Chatter (VoxScribe Pro)

Chatter is a single-page, browser-based conversational voice interface.
It captures speech from your microphone, sends conversation context to an AI backend, and reads responses aloud while showing a live transcript in the UI.

## What this application is

- **Single-page web app** built as a lightweight `index.html` frontend plus an optional container-hosted API proxy.
- **Speech-driven chat experience** using browser speech recognition + speech synthesis.
- **Hybrid AI backend support** for:
  - **Gemini (cloud)** via a server-side/container API key proxy.
  - **Ollama models** discovered through the container-hosted Ollama proxy or, when opened as a plain static file/site, directly from your browser.

## Build / run instructions

No compile step is required.

1. Clone the repository.
2. Start a local static web server from the repo root (recommended):
   ```bash
   python3 -m http.server 8000
   ```
3. Open `http://localhost:8000` in a modern browser.
4. For Gemini cloud access, run the container deployment and set `GEMINI_API_KEY`, `GEMINI_API_KEY_PRIMARY`, or `GEMINI_API_KEY_SECONDARY` on the hosting server/container. Browser-entered Gemini keys are no longer used.

> You can also open `index.html` directly, but a local server is recommended for consistent browser behavior.

### Container deploy

`deploy.sh` builds a small container that serves the app from `index.html`, exposes a local `/api/tts` endpoint backed by `espeak-ng`, Piper, and Kokoro, and exposes `/api/gemini` so Gemini API access happens from the hosting container instead of each user browser. The image bundles a default UK English local Piper voice so both local TTS choices work without a separate server.

```bash
GEMINI_API_KEY=your_key_here ./deploy.sh 3014
```

- Arg 1: exposed port (default `3014`)
- Open `http://localhost:<port>/` or `http://localhost:<port>/index.html`.
- The bundled Gemini proxy is available at `http://localhost:<port>/api/gemini`. Set `GEMINI_API_KEY` for one key, or `GEMINI_API_KEY_PRIMARY` and `GEMINI_API_KEY_SECONDARY` for two selectable server-side keys. Optionally set `GEMINI_MODEL` to override the default Gemini model.
- The bundled Ollama proxy is available at `http://localhost:<port>/api/ollama`. It lets phone/tablet browsers use Ollama servers reachable from the container/host network instead of requiring the browser device to reach Ollama directly. The default local Ollama address is `http://host.docker.internal:11434`; override it with `OLLAMA_ENDPOINT=http://192.168.1.20:11434 ./deploy.sh 3014` if needed.
- The bundled local TTS endpoint is available at `http://localhost:<port>/api/tts` and is used when **TTS: Local eSpeak**, **TTS: Local Piper**, or **TTS: Local Kokoro-82M** is selected in the app.
- **TTS: Local Piper** uses the same endpoint with `engine=piper`. The container includes a default `en_GB-southern_english_female-low` Piper voice. To use a custom Piper voice, set `PIPER_MODEL` to a host `.onnx` file path before running `deploy.sh`; the script mounts that file's directory read-only at `/custom_voice` and points the container at the mounted model. For example: `PIPER_MODEL=/home/me/voices/my_voice.onnx ./deploy.sh 3014`. Keep the matching `.onnx.json` config file beside the model file. As shortcuts, placing `my_voice.onnx` and `my_voice.onnx.json` in the repo root, or placing them under `custom_voice/`, automatically mounts the voice and sets `PIPER_MODEL=/custom_voice/my_voice.onnx`; do not hard-code `-e PIPER_MODEL=/custom_voice/my_voice.onnx` unless you also mount the directory.
- **TTS: Local Kokoro-82M** uses the same endpoint with `engine=kokoro`. The container downloads Kokoro ONNX model files during build; set `KOKORO_MODEL`, `KOKORO_VOICES`, or `KOKORO_VOICE` to use mounted Kokoro files or a different voice.
- Local Piper and Kokoro responses are synthesized with in-memory request de-duplication and an LRU audio cache (default `TTS_CACHE_ENTRIES=128`) so repeated chunks return immediately and concurrent identical requests share one synthesis job.

## Basic controls

- **Start Conversation**: begins microphone capture and starts a voice session.
- **End Session**: stops the active voice/chat session.
- **Language selector**: sets speech recognition language.
- **AI Backend selector**: choose a local Ollama model, a saved remote Ollama model, plus Gemini cloud when at least one Gemini API key is configured on the hosting server/container.
- **Gemini key selector**: choose which server-configured Gemini API key slot Gemini cloud requests use. Key slot names can be customised in **Settings** (for example, “Billing” or “Free”); if the selected server slot is unavailable, the app falls back to the other configured server key.
- **Stream tokens**: optionally render AI responses token-by-token as they arrive. With **TTS: Local eSpeak**, **TTS: Local Piper**, or **TTS: Local Kokoro-82M**, speech is queued in sentence or short phrase chunks as text streams in, so playback can start before the AI response is complete. Browser TTS still waits for the full response because browser speech synthesis does not accept incremental audio input.
- **TTS selector**: choose browser speech synthesis, the deployed local eSpeak service, the deployed local Piper service, or the deployed local Kokoro-82M service. The local options require running the app through `deploy.sh`; the container bundles eSpeak, a default UK English Piper voice, and Kokoro-82M model files.
- **Settings (gear icon)**: name the two server-configured Gemini key slots, choose the active Gemini key slot, add/update/remove named remote Ollama servers, and set optional prompt behaviour/personality instructions. Saved prompt instructions override the default friendly British chat style; leave the field blank to use the default. When deployed with `deploy.sh`, remote Ollama addresses are reached by the hosting container through `/api/ollama`, so phone browsers can use host/container addresses such as `http://host.docker.internal:11434` or LAN addresses such as `http://192.168.1.20:11434`.
- **Transcript panel**: shows conversation turns and current output.
- **Text input box**: type a message and press **Send** (or Enter) as an alternative to speaking; use Shift+Enter for a new line.

## Troubleshooting

- **Speech recognition does not start on Chrome for Android**:
  update to the latest Chrome, use an HTTPS URL, and make sure Chrome has Android microphone permission. The app avoids holding a separate visualizer microphone stream on Android Chrome because that can prevent the browser speech recognizer from starting; if recognition still fails, close other apps or tabs that may be using the microphone and check that the phone has internet access.

- **Microphone access blocked on a hostname (for example `http://ebg.dylanjones.org:3014`)**:
  browsers require a **secure context** for mic capture. Use HTTPS on your hostname
  (for example `https://ebg.dylanjones.org:3014` if you are still using that port), or run
  locally via `http://localhost:<port>`.

- **Ollama is unreachable when deployed with `deploy.sh`**:
  confirm the address is reachable from the container/host network. For Ollama running on the Docker host, use the default `http://host.docker.internal:11434` or set `OLLAMA_ENDPOINT` before running `deploy.sh`. For another LAN server, save its address in Settings, for example `http://192.168.1.20:11434`. The remote Ollama service may need `OLLAMA_HOST=0.0.0.0:11434`.

- **Remote Ollama is unreachable from a plain static server**:
  if you are not using `deploy.sh`, the browser still contacts Ollama directly. Confirm the address is reachable from the device running the browser and that Ollama allows browser origins with an appropriate `OLLAMA_ORIGINS` setting.

## Roadmap (short)

- Add keyboard accessibility shortcuts for all primary actions.
- Add transcript export options (TXT/JSON).
- Add basic automated checks (lint/format) and CI workflow.
