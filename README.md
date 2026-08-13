# Claude MenuBar

A macOS menu bar app for running several Claude Code sessions at once. It lists every live session
and turns permission prompts into one-click choices, so you answer from the menu bar instead of
hunting for the right terminal tab.

Native Swift, no dependencies, nothing leaves `127.0.0.1`.

## Requirements

- macOS 14+, Swift 6 to build
- Claude Code, with hooks writable in `~/.claude/settings.json`
- iTerm2 **to answer prompts**. Sessions elsewhere still appear with their status and requests; the
  app just can't answer those and says so rather than guessing.

## Install

```sh
./scripts/build-app.sh
open "build/Claude MenuBar.app"
```

Open the panel and press **Install hooks**. That writes the hook entries into
`~/.claude/settings.json`, backing up the old file alongside it and leaving your existing hooks
alone. Right-click the menu bar icon to remove them. Running sessions are picked up without
restarting.

For login startup, add the app in System Settings ▸ General ▸ Login Items.

## The panel

**Waiting on you** shows one request at a time in a slot that keeps its size, with Claude's last
message for context and the command or question itself. The buttons mirror the numbered menu Claude
is actually showing, so you never see an option that doesn't exist. Others queue behind it as
`2 of 3`; click any session marked *needs you* to bring its request up.

Below that, every live session with its state: **needs you**, **working**, **idle**, or **running**
for a process that hasn't reported in yet.

| Button | Effect |
| :-- | :-- |
| Claude's own options | Answers the prompt with that choice |
| **Always allow** | Answers yes, and auto-allows that tool in that project from then on |
| **Say why…** | Cancels the prompt and sends Claude your message instead |
| **Terminal** | Jumps to that pane; the card stays until the prompt is settled |

Answering never pulls a session to the front — that's the point. Focus moves only via **Terminal**,
the card's header, or clicking a session with no pending request.

`Always allow` is stored by project and tool in
`~/Library/Application Support/ClaudeMenuBar/always-allow.json`, not in your Claude permission rules.
Clear it from the `⋯` menu.

## How it works

The obvious design doesn't work, and that shaped everything else.

Claude Code fires a `PermissionRequest` hook before prompting, and the hook can answer `allow`,
`deny` or `ask`. So the app should hold that open until you click. **It can't:** Claude Code waits
about **6 seconds**, then draws its own prompt regardless — measured at 5.99s, 6.00s and 6.00s, with
the hook's `timeout` set to 300. Six seconds is not enough for a person.

So the app doesn't answer the hook. It answers the terminal.

```
Claude Code ─PermissionRequest─▶ app records it, replies "ask" at once
            ─(6s)─▶ draws its prompt, fires Notification
                                  app reads the real menu from the pane
you click ───────────────────────▶ app types that number into that pane
```

The hook does what it's good at — reporting the tool, arguments, transcript and session. The answer
travels by keystroke, because Claude Code's prompt is a numbered menu that selects on a digit.

Three things keep this from being guesswork:

- **Timing.** The keystroke waits for the session's `Notification` hook, which fires when the prompt
  is drawn, with an 8s fallback. Click early and the key is held until the prompt exists.
- **Targeting.** `SessionStart`, `UserPromptSubmit` and `PermissionRequest` are installed as
  *command* hooks, which run as children of `claude` and so inherit `ITERM_SESSION_ID`. Every request
  arrives knowing its exact pane. The map is cached in `panes.json`.
- **Honesty.** With no identified pane the app types nothing, restores the card and tells you. The
  directory fallback refuses when two sessions share a directory rather than picking the first.

`Always allow` answers through the hook instead, since that decision is instant and fits inside the
6s window — so a remembered tool never prompts at all.

**Failure is safe.** With the app not running the connection is refused, which Claude Code treats as
a non-blocking error, and everything prompts in the terminal as before.

### Keeping the list honest

Sessions come from two places: the hooks, and a scan of running `claude` processes every 10s, so
sessions that predate the app still appear. They're deduplicated by pane.

A card is removed only when something actually settled the prompt — `PostToolUse`, `PermissionDenied`,
`Stop`, or the prompt leaving the screen, which is checked every 3s. Answering in the terminal clears
it here too.

A session's name comes from its transcript path, not its working directory, which follows the agent
into scratchpads. Claude encodes that path with both `/` and `.` as `-`, so it's decoded against real
directory entries — otherwise `claude-menubar` is indistinguishable from a separator. Sessions idle
for 30 minutes are dropped; hover any row to remove it by hand.

## Configuration

| Variable | Default | Meaning |
| :-- | :-- | :-- |
| `CLAUDE_MENUBAR_PORT` | `7788` | Loopback port. Change it and reinstall the hooks. |
| `CLAUDE_MENUBAR_STALE_MINUTES` | `30` | Drop sessions quiet for this long. |

A trace of every request, decision and keystroke is written to
`~/Library/Application Support/ClaudeMenuBar/trace.log`.

## Limits

- Answering and jumping are iTerm2-only. Porting means two calls in `TerminalFocus.swift`: address a
  pane, and write a string to it.
- Headless `claude -p` runs have no prompt to intercept.
- Sessions on another machine can't reach your loopback.

## Licence

MIT
