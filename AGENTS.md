# AGENTS.md

Guidance for AI coding agents working in this repository.

## Project overview

- This project is a lightweight, single-page web app.
- Main implementation lives in `index.html` (HTML, CSS, and JavaScript in one file).
- Keep changes minimal, focused, and easy to review.

## Preferred workflow

1. Read `README.md` for behavior and run instructions.
2. Make the smallest change that solves the request.
3. Verify by running the app locally with a static server.
4. Keep docs in sync when behavior changes.

## Editing guidelines

- Preserve the current UI style and tone unless asked to redesign.
- Avoid adding heavy build tooling unless explicitly requested.
- Do not introduce external dependencies for small fixes.
- Keep browser compatibility in mind for speech APIs.
- If you modify user-facing controls, update the README controls section.

## Validation checklist

- Run a quick syntax sanity check when possible.
- Open the app locally and confirm there are no console errors.
- Confirm core controls still work:
  - Start Conversation
  - End Session
  - Settings modal open/save/close
  - Language and AI model selectors

## PR / commit expectations

- Use clear commit messages with scope prefixes when practical (`docs:`, `fix:`, `feat:`).
- Summarize what changed and why.
- List manual verification steps in the PR description.
