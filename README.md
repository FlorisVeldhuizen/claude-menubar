# Claude MenuBar

A macOS menu bar app for running several Claude Code sessions at once. It lists every live session
and turns permission prompts into one-click choices, so you answer from the menu bar instead of
hunting for the right terminal tab.

Native Swift, no dependencies, nothing leaves `127.0.0.1`.

## Requirements

- macOS 14+, Swift 6 to build
- Claude Code, with hooks writable in `~/.claude/settings.json`
- iTerm2 or Apple Terminal to answer by keystroke. Sessions anywhere else still work, by a slower
  route described in [How it works](#how-it-works).

## Install

```sh
./scripts/build-app.sh --install
```

That builds it, copies it to `/Applications` and launches it. Without `--install` it stays in
`build/`. To start it with your Mac, right-click the menu bar icon and tick **Open at login**.

Then open the panel and press **Install hooks**. That writes the hook entries into
`~/.claude/settings.json`, backing up the old file alongside it and leaving your existing hooks
alone. Running sessions are picked up without restarting. Right-click the menu bar icon to remove
them again, or to see which build you are on.

## Using it

**Waiting on you** shows one request at a time, with Claude's last message for context and the
command or question itself. The buttons mirror the numbered menu Claude is actually showing, so you
never see an option that doesn't exist.

| Button | Effect |
| :-- | :-- |
| Claude's own options | Answers the prompt with that choice |
| **Say why…** | Cancels the prompt and sends Claude your message instead |
| **Terminal** | Jumps to that pane; the card stays until the prompt is settled |

A question that takes several answers draws a tick box on each option. Clicking one ticks it and
leaves the card up, because that prompt only closes on Return — **Submit** sends it.

Answering never pulls a session to the front. Focus moves only via **Terminal**, the card's header,
or clicking a session with no pending request.

Every answer has a key: `⌘1`–`⌘9` pick the numbered options, `⌘↩` allows and `⌘D` denies on a card
with no menu yet, and `⌘K` opens the message field. Command digits rather than plain ones, so typing
into that field still works. With several decisions waiting, the header becomes one chip per project;
click one or use `⌘[` / `⌘]` to switch.

A new request plays a short sound. Right-click the menu bar icon → **Sound** to pick another; it
plays as you select so you can hear it first, and **None** turns it off.

### Sessions

Below the card, every live session, grouped so one that needs you is never buried under quiet ones.
Hover a row for what its state means and what a click does.

| State | Meaning |
| :-- | :-- |
| **needs you** | orange — blocked on a decision; answer it here |
| **working** | blue — running now |
| **finished its turn** | green — done and waiting for you; goes quiet after 10 minutes |
| **waiting for your prompt** | grey — quiet |
| **not reporting yet** | faint — a live `claude` we found, but no hooks have arrived from it yet |

### Always allow

**Always allow `git add`** is scoped the way the prompt is, not by tool: a command gives its program
and subcommand, a file tool gives the directory, a fetch gives the host. A chained command remembers
every part, and a later call passes only if all of its parts are covered. A command that builds
itself with `$( )` or backticks gets no rule at all.

Rules are per project, kept in `~/Library/Application Support/ClaudeMenuBar/always-allow.json`
rather than in your Claude permission rules, and clear from the `⋯` menu. The button appears only
where Claude offers no "don't ask again" of its own, since that one is already in the mirrored menu.

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

The hook reports the tool, arguments and session. The answer travels by keystroke, because the prompt
is a numbered menu that selects on a digit. Keystrokes wait for the prompt to actually be on screen
and go only to a pane identified exactly, via the `ITERM_SESSION_ID` or `TERM_SESSION_ID` that
command hooks inherit from `claude`. With no identified pane the app types nothing and tells you.

The two terminals are addressed differently. iTerm2 exposes a session id on its panes, so the app
matches that and writes with `write text`. Terminal tabs expose only a `tty`, so the app reads the
session id from the `claude` process, takes its tty, and matches the tab on that.

**Failure is safe.** With the app not running the connection is refused, which Claude Code treats as
a non-blocking error, and everything prompts in the terminal as before.

### Sessions with no terminal to type into

A session in VS Code, or in a terminal the app can't address, has no pane to type into, so it is
handled the other way round. `PreToolUse` runs before the permission flow and, unlike
`PermissionRequest`, does honour long timeouts — so there the app holds the decision open and answers
through the hook. No keystrokes involved.

Which route a session gets is decided per call, by whether it reported a pane, so there is nothing to
configure. The cost is that `PreToolUse` fires for every tool call and can't tell how risky one is:
read-only tools pass straight through, everything else asks. If nothing answers within 280 seconds
the app returns no decision and the session prompts as it normally would.

For one of these questions the app shows Claude's own options, read from the tool's arguments.
Picking one denies the call with your choice as the reason, since the hook has no way to hand back an
answer — Claude reads it and carries on, but it does see a denied tool call rather than an answered
question. Jumping to such a session opens VS Code at that folder, when it reported itself as VS Code.

## Configuration

`CLAUDE_MENUBAR_PORT` (default `7788`) sets the loopback port; change it and reinstall the hooks.
`CLAUDE_MENUBAR_STALE_MINUTES` (default `30`) drops sessions quiet for that long.

State lives in `~/Library/Application Support/ClaudeMenuBar/`, including a trace of every request,
decision and keystroke in `trace.log`.

The app icon is drawn by `scripts/make-icon.swift`, not stored as art. `scripts/make-icon.sh`
regenerates `Resources/AppIcon.icns` from it.

## Limits

- Typing an answer and jumping to a session work in iTerm2 and Apple Terminal only. Porting to
  another terminal means two calls in `TerminalFocus.swift`: address a pane, and write to it.
- Tick lists can't be answered from the menu bar on Apple Terminal, because `do script` always
  appends a return and so cannot send a bare arrow key. The card says so; answer that one in the
  terminal.
- Sessions with no pane see the options a tool declares, but not the ones Claude Code appends to its
  own menu, since there is no rendered menu to read. "Chat about this" is offered explicitly; "Type
  something" and notes are not.
- Headless `claude -p` runs have no prompt to intercept.
- Sessions on another machine can't reach your loopback.

## Licence

MIT
