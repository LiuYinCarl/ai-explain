# AGENTS.md

## What this is

`ai-explain.el` is a single-file Emacs Lisp package (no build system, no tests, no CI).
It lets a user select code in Emacs, sends it to an external AI CLI (`kimi`, `pi`, or
`codex`), and streams the reply into a dedicated `*ai-explain*` buffer for follow-up
questions. All logic lives in `ai-explain.el` (~970 lines); `README.md` is the user-facing
doc, written in Chinese.

## Working on the code

- Pure Elisp, loaded via `load-path` or `use-package :vc`. There is no `Makefile`,
  `package.json`, test suite, or CI config. Do not invent one.
- `*.elc` is gitignored, so byte-compilation is expected but not wired to any command.
  To check for warnings: `emacs -Q -batch -f batch-byte-compile ai-explain.el`.
  `-Q` isolates from the user's config, which matters because loading the file runs
  `(require 'markdown-mode nil t)` (optional).
- The file is `lexical-binding: t`. Keep it.
- **Code comments and docstrings are in Chinese.** Match that style. The README is also
  Chinese; keep new user-facing prose consistent.
- Verify changes manually in Emacs with a real CLI on `PATH`; there is no automated test
  harness to fall back on. Use a small selection with `M-x ai-explain-region`.

## Architecture

Single entry points `ai-explain-region` / `ai-explain-ask` build a prompt and call
`ai-explain--send`. `ai-explain--send` checks busy state, resolves the backend plist,
chooses persistent vs one-shot mode, and wires a process filter + sentinel.

Data flow: process stdout -> `ai-explain--filter` (splits on newlines, keeps the trailing
partial line in the process property `pending`) -> the backend's `:handle-line` (parses
one JSON line, inserts text via `ai-explain--insert`, calls `ai-explain--turn-done` at end
of turn) -> text appears in `*ai-explain*`.

User-input blocks (the region explanation heading and the follow-up question block,
which `ai-explain-ask` renders inline as `> **追问**：...`) are tagged with the text
property `ai-explain--input-property` by passing a non-nil `USER-INPUT` arg to `ai-explain--insert`.
`ai-explain-goto-prev-input` / `ai-explain-goto-next-input` (bound to `M-p` / `M-n`) walk
that property via `ai-explain--input-anchors`, so they never land inside an AI reply even
if the reply contains its own markdown headings. If you add another user-authored block
that should be a jump target, pass `t` at its `ai-explain--insert` call site.

Markup display: `ai-explain-hide-markup` (default non-nil) makes `ai-explain-mode` hide
markdown marker characters (`#`, `**`, code fences, ...) while keeping faces, by setting
the markdown-mode variable `markdown-hide-markup` buffer-locally and adding/removing
`markdown-markup` from `buffer-invisibility-spec` (see `ai-explain--apply-markup-hiding`,
called unconditionally from the mode body so it also overrides a global
`markdown-hide-markup`). The same function overrides `markdown-list-item-bullets`
buffer-locally with `ai-explain-list-bullet` (default `•`) so lists don't render with
markdown-mode's large default bullet `●`. The mode body also does
`(face-remap-add-relative 'markdown-blockquote-face 'default)` so quote blocks (which is
how user messages and code are shown) don't inherit the often-too-dark
`font-lock-doc-face`. All are buffer-local, so other markdown buffers
are unaffected. It only exists in the `markdown-mode` branch of the mode definition; the
`special-mode` fallback cannot render, so the option has no effect there.

### Backend abstraction (the key concept)

`ai-explain-backends` is an alist of `(name . plist)`. A backend uses one of three
declaration styles:

1. **ACP** (`:acp t`): generic adapter handles the whole Agent Client Protocol
   handshake. Declare only `:command`, `:arguments`, and optional `:acp-mode`. The
   adapter fills in `:ensure-process`, `:send-prompt`, `:handle-line`. `ai-explain--backend`
   appends defaults *after* user keys so a user can override them (`plist-get` returns the
   first match).
2. **One-shot** (`:build-args` + `:handle-line`): a fresh process per question.
3. **Custom persistent** (`:persistent t` + `:ensure-process` + `:send-prompt` +
   `:handle-line`, optional `:cancel`): a long-lived reused process. The `pi` backend is
   the built-in example.

Built-in backends: `kimi` (ACP), `pi` (rpc persistent), `codex` (one-shot JSONL), plus
`kimi-oneshot` / `pi-oneshot` fallbacks for when the persistent modes misbehave.

### The ACP state machine

`ai-explain--acp-*` implements the protocol: `initialize` -> `session/resume` (if a saved
session id exists and the agent advertised `sessionCapabilities.resume`) or `session/new`
-> optional `session/set_mode` -> ready. State is tracked in process property `acp-state`;
handshake responses are routed by matching `acp-handshake-id`. A 15s watchdog
(`ai-explain--acp-handshake-timeout`) fails the handshake to avoid a stuck `busy` flag.

## Gotchas (read before editing)

- **Process identity is captured at creation, not read from globals.** Backend context
  (`handle-line`, `persistent`, etc.) lives in process properties. Async callbacks must
  use `(process-get proc ...)`, never the global `ai-explain-backend`; this is what keeps
  late callbacks from an old process (after stop / new session / backend switch) from
  corrupting the current turn.
- **`eq` guards discard stale output.** `ai-explain--filter` and `ai-explain--sentinel`
  only act when `(eq ai-explain--process proc)`. Any new async path needs the same guard.
- **State is buffer-local** (`ai-explain--session-id`, `--process`, `--busy`,
  `--pi-saw-text`, spinner vars). `--session-id` persists on the `*ai-explain*` buffer
  across process restarts so the conversation can be resumed. Closing the buffer kills the
  backend process (via `kill-buffer-hook`), so reopening starts fresh.
- **`ai-explain--insert` bypasses `read-only-mode`** with `inhibit-read-only` and stops
  the spinner. Always insert through it, not raw `insert`.
- **`--turn-done` is mandatory** at the end of every turn, including error paths; it
  clears `busy` and appends the `---` separator. Persistent backends call it from their
  `:handle-line`; one-shot backends end when the process exits (sentinel handles it).
- **Filter buffers the trailing partial line.** stdout is chunked arbitrarily; never parse
  a chunk directly, only complete lines are dispatched. `ai-explain--flush-pending` handles
  a leftover line on process exit, but is skipped for user-killed processes.
- **The `pi` backend's `--pi-saw-text` guard** suppresses blank lines from tool-only
  assistant messages; `message_end` only emits a newline if text actually streamed first.
  Preserve that behavior when touching pi event handling.
- **stderr goes to a separate throwaway buffer** (`*ai-explain-stderr*`), surfaced only in
  sentinel error messages. Don't merge it into the main stream.
- `ai-explain-mode` is defined inside an `if` (markdown-mode vs special-mode fallback), so
  it needs the `declare-function` at the top; keep that declaration if you refactor.
- The spinner is a 0.1s repeating timer bound to the buffer; it must be stopped on every
  terminal path (content arrival, turn end, process exit, user stop, buffer kill) or it
  leaks a timer holding the buffer.

## Adding a backend

- ACP agent: `(add-to-list 'ai-explain-backends '(gemini :command "gemini" :acp t :arguments ("--acp")))`.
  No callbacks needed.
- Non-ACP: define `build-args` and `handle-line` functions (see the one-shot section of
  the file header comment for the exact contract) and add a plist. `:build-args` runs with
  the `*ai-explain*` buffer current and may set buffer-local `ai-explain--session-id` for
  session continuation; a backend with no resume support simply ignores the id.

The file header (lines 71-108) documents the backend plist contract in detail; keep it in
sync when changing the abstraction.
