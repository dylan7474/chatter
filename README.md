# Chatter (VoxScribe Pro)

Chatter is a single-page, browser-based conversational voice interface.
It captures speech from your microphone, sends conversation context to an AI backend, and reads responses aloud while showing a live transcript in the UI.

## What this application is

- **Frontend-only web app** built as a single `index.html` file.
- **Speech-driven chat experience** using browser speech recognition + speech synthesis.
- **Hybrid AI backend support** for:
  - **Gemini (cloud)** via an API key.
  - **Local Ollama models** discovered from your local machine.

## Build / run instructions

No compile step is required.

1. Clone the repository.
2. Start a local static web server from the repo root (recommended):
   ```bash
   python3 -m http.server 8000
   ```
3. Open `http://localhost:8000` in a modern browser.
4. (Optional) Add your Gemini API key from **Settings** in the app.

> You can also open `index.html` directly, but a local server is recommended for consistent browser behavior.

## Basic controls

- **Start Conversation**: begins microphone capture and starts a voice session.
- **End Session**: stops the active voice/chat session.
- **Language selector**: sets speech recognition language.
- **AI Backend selector**: choose Gemini cloud or a local Ollama model.
- **Settings (gear icon)**: save/update Gemini API key.
- **Transcript panel**: shows conversation turns and current output.

## Troubleshooting

- **Microphone access blocked on a hostname (for example `http://ebg.dylanjones.org:3014`)**:
  browsers require a **secure context** for mic capture. Use HTTPS on your hostname
  (for example `https://ebg.dylanjones.org`) or run locally via `http://localhost:<port>`.

## Roadmap (short)

- Add keyboard accessibility shortcuts for all primary actions.
- Add transcript export options (TXT/JSON).
- Add optional streaming token-by-token response rendering.
- Add basic automated checks (lint/format) and CI workflow.
