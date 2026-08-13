# Claude MenuBar

A macOS menu bar app for running several Claude Code sessions at once. It lists every live session
and turns permission prompts into one-click choices, so you answer from the menu bar instead of
hunting for the right terminal tab.

Native Swift, no dependencies, nothing leaves `127.0.0.1`.

## Requirements

- macOS 14+, Swift 6 to build
- Claude Code, with hooks writable in `~/.claude/settings.json`
- iTerm2 for the keystroke path. Sessions elsewhere — VS Code, another terminal — are handled by
  gating instead, automatically. See below.

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

## Using it

**Waiting on you** shows one request at a time, with Claude's last message for context and the
command or question itself. The buttons mirror the numbered menu Claude is actually showing, so you
never see an option that doesn't exist. Others queue behind it as `2 of 3`; click any session marked
*needs you* to bring its request up.

Below that, every live session: **needs you**, **working**, **idle**, or **running** for a process
that hasn't reported in yet.

| Button | Effect |
| :-- | :-- |
| Claude's own options | Answers the prompt with that choice |
| **Always allow** | Answers yes, and auto-allows that tool in that project from then on |
| **Say why…** | Cancels the prompt and sends Claude your message instead |
| **Terminal** | Jumps to that pane; the card stays until the prompt is settled |

Answering never pulls a session to the front — that's the point. Focus moves only via **Terminal**,
the card's header, or clicking a session with no pending request.

## How it works

Claude Code fires a `PermissionRequest` hook before prompting, so the app should hold that open until
you click. **It can't:** Claude Code waits about **6 seconds**, then draws its own prompt regardless —
measured at 5.99s, 6.00s and 6.00s with the hook's `timeout` set to 300.

So the app doesn't answer the hook. It answers the terminal.

```
Claude Code ─PermissionRequest─▶ app records it, replies "ask" at once
            ─(6s)─▶ draws its prompt, fires Notification
                                  app reads the real menu from the pane
you click ───────────────────────▶ app types that number into that pane
```

The hook reports the tool, arguments and session; the answer travels by keystroke, because Claude
Code's prompt is a numbered menu that selects on a digit. That's why answering needs iTerm2.

The keystroke waits for the prompt to actually be on screen, and goes only to a pane identified
exactly — via `ITERM_SESSION_ID`, which command hooks inherit from `claude`. With no identified pane
the app types nothing and tells you.

**Failure is safe.** With the app not running the connection is refused, which Claude Code treats as
a non-blocking error, and everything prompts in the terminal as before.

### Sessions with no terminal to type into

A session in VS Code or another terminal has no pane to address, so it's handled the other way round.
`PreToolUse` runs before the permission flow and, unlike `PermissionRequest`, does honour long
timeouts — so for those sessions the app holds the decision there and answers through the hook. No
keystrokes involved.

Which mode a session gets is decided per call, by whether it reported a pane, so nothing to
configure. The cost is that `PreToolUse` fires for every tool call and can't tell how risky one is:
read-only tools pass straight through, and everything else asks. If nothing answers within 280
seconds the app returns no decision and the session prompts as it normally would.

## Configuration

`CLAUDE_MENUBAR_PORT` (default `7788`) sets the loopback port; change it and reinstall the hooks.
`CLAUDE_MENUBAR_STALE_MINUTES` (default `30`) drops sessions quiet for that long.

State lives in `~/Library/Application Support/ClaudeMenuBar/`, including a trace of every request,
decision and keystroke in `trace.log`.

## Limits

- Jumping to a session is iTerm2-only, as is the keystroke path. Porting means two calls in
  `TerminalFocus.swift`: address a pane, and write a string to it.
- Gated sessions can't use **Terminal**, and see Allow/Deny rather than Claude's own option list,
  since there is no on-screen menu to mirror.
- Headless `claude -p` runs have no prompt to intercept.
- Sessions on another machine can't reach your loopback.

## Licence

MIT
