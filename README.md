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
./scripts/build-app.sh --install
```

That builds it, copies it to `/Applications` and launches it. Without `--install` it stays in
`build/`. To start it with your Mac, right-click the menu bar icon and tick **Open at login**.

Open the panel and press **Install hooks**. That writes the hook entries into
`~/.claude/settings.json`, backing up the old file alongside it and leaving your existing hooks
alone. Right-click the menu bar icon to remove them. Running sessions are picked up without
restarting.

## Using it

**Waiting on you** shows one request at a time, with Claude's last message for context and the
command or question itself. The buttons mirror the numbered menu Claude is actually showing, so you
never see an option that doesn't exist. Others queue behind it as `2 of 3`; click any session marked
*needs you* to bring its request up.

Below that, every live session:

| State | Meaning |
| :-- | :-- |
| **needs you** | orange — Claude is blocked on a decision; answer it here |
| **working** | blue — running now |
| **finished its turn** | green — done and waiting for you; goes quiet after 10 minutes |
| **waiting for your prompt** | grey — quiet |
| **not reporting yet** | faint — a live `claude` we found, but no hooks have arrived, so it can't be answered from here |

Hover a row for the same thing in full, plus what a click does.

| Button | Effect |
| :-- | :-- |
| Claude's own options | Answers the prompt with that choice |
| **Say why…** | Cancels the prompt and sends Claude your message instead |
| **Terminal** | Jumps to that pane; the card stays until the prompt is settled |

A question that takes several answers draws a tick box on each option. Clicking one ticks it and
leaves the card up, because that prompt only closes on Return — **Submit** sends it.

Answering never pulls a session to the front — that's the point. Focus moves only via **Terminal**,
the card's header, or clicking a session with no pending request.

Every answer has a key. `⌘1` to `⌘9` pick the numbered options, `⌘↩` allows and `⌘D` denies on a
card with no menu yet, and `⌘K` opens the message field. Command digits rather than plain ones, so
typing into that field still works. With several decisions waiting, the header becomes one chip per
project; click one or use `⌘[` / `⌘]` to switch.

**Always allow \<tool\>** appears only where Claude offers no "don't ask again" of its own — that is,
on gated cards that aren't questions. Claude's version is scoped to the command and is already in the
mirrored menu; ours covers every call of that tool in the project, so it stays out of the way.
It's kept in `~/Library/Application Support/ClaudeMenuBar/always-allow.json` rather than your Claude
permission rules, and clears from the `⋯` menu.

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

For a gated question the app shows Claude's own options, read from the tool's arguments. Picking one
denies the call with your choice as the reason, since the hook has no way to hand back an answer —
Claude reads it and carries on, but it does see a denied tool call rather than an answered question.

Jumping to a gated session opens VS Code at that folder via its URL handler, when the session
reported itself as VS Code.

A new request plays a short sound. Right-click the menu bar icon → **Sound** to pick another; it
plays as you select so you can hear it first, and **None** turns it off.

## Configuration

`CLAUDE_MENUBAR_PORT` (default `7788`) sets the loopback port; change it and reinstall the hooks.
`CLAUDE_MENUBAR_STALE_MINUTES` (default `30`) drops sessions quiet for that long.

State lives in `~/Library/Application Support/ClaudeMenuBar/`, including a trace of every request,
decision and keystroke in `trace.log`.

## Limits

- Jumping to a session is iTerm2-only, as is the keystroke path. Porting means two calls in
  `TerminalFocus.swift`: address a pane, and write a string to it.
- Gated sessions see the options a tool declares, but not the ones Claude Code appends to its own
  menu, since there is no rendered menu to read. "Chat about this" is offered explicitly; "Type
  something" and notes are not.
- Headless `claude -p` runs have no prompt to intercept.
- Sessions on another machine can't reach your loopback.

## Licence

MIT
