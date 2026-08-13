# Claude MenuBar

A macOS menu bar app that watches every running Claude Code session. When a session needs a
permission decision, you get a notification and a one-click choice instead of hunting for the right
terminal tab.

Native Swift, no dependencies, no network access beyond `127.0.0.1`.

## Requirements

- **macOS 14** or later, and Swift 6 to build.
- **Claude Code**, with hooks writable in `~/.claude/settings.json`.
- **iTerm2** to answer prompts from the panel. Answering works by typing into the session's pane
  through iTerm2's AppleScript interface, so that part is iTerm2-only.

Sessions in other terminals, or in the VS Code extension, still appear in the list with their status
and their pending requests — the app just can't answer those for you, and it says so rather than
guessing. Porting to another terminal means implementing two calls in `TerminalFocus.swift`: select a
pane, and write a string to it.

## How it works

The obvious design does not work, and it is worth writing down why.

Claude Code fires a `PermissionRequest` hook before prompting, and the hook can answer `allow`, `deny`
or `ask`. So the app should hold that request open until you click, then answer it. **It can't.**
Claude Code waits about **6 seconds** for a `PermissionRequest` hook and then draws its own prompt in
the terminal regardless — measured at 5.99s, 6.00s and 6.00s across separate runs, with the hook's
`timeout` set to 300. Six seconds is not enough for a person, so any decision made in the menu bar
arrived after Claude Code had stopped listening. Clicking a button did nothing.

So the app does not try to answer the hook. It answers the terminal.

```
Claude Code ─PermissionRequest─▶ app records it, replies "ask" at once
            ─(6s)─▶ draws its own prompt, fires Notification
                                  app now knows the prompt is on screen
you click "Yes" ─────────────────▶ app types "1" into that exact pane
```

The hook is used for what it is good at: telling the app what is being asked, with the tool, the
arguments and the transcript. The answer travels by keystroke, because Claude Code's prompt is a
numbered menu and selects on a digit. `Escape` cancels.

Two details make it reliable rather than a guess:

- **Timing.** The keystroke is not sent on a delay. It waits for that session's `Notification` hook,
  which fires exactly when the prompt is drawn, with an 8 second fallback. Click before the prompt
  exists and the key is held until it does.
- **Targeting.** See [Finding the right pane](#finding-the-right-pane). The app never types into a
  pane it has not positively identified.

`Yes, always` still answers through the hook, because that decision is instant and lands well inside
the 6 second window — so the terminal never prompts at all for a remembered tool.

**Failure is safe.** If the app is not running the connection is refused, which Claude Code treats as
a non-blocking error, and everything prompts in the terminal exactly as before.

## Build and run

```sh
./scripts/build-app.sh
open "build/Claude MenuBar.app"
```

Open the menu bar panel and press **Install hooks**. That writes the hook entries into
`~/.claude/settings.json` and backs the old file up to `settings.json.claude-menubar-backup`.
Your existing hooks are left alone. Right-click the menu bar icon to remove them again.

To start it at login, add the app in System Settings ▸ General ▸ Login Items.

Sessions already running when you install the hooks are picked up too — Claude Code reloads its hook
configuration during a session, it does not only read it at startup. An existing session registers its
pane the next time you send it a prompt. Nothing needs restarting.

## The panel

Click the menu bar icon to expand it.

- **Waiting on you** — one request at a time, in a slot that keeps its size. The header reads
  `2 of 3` when others are queued behind it, and the next one fades in when you decide. Long commands
  scroll inside the card rather than stretching it. This is deliberate: with several agents running,
  a list that grows and collapses moves the buttons out from under your pointer.
- Click any session marked **needs you** to bring its request into the slot. The selected session is
  tinted, and a session with more than one queued request shows a count.
- **Sessions** — every live session with its project folder and state. Blue is working, orange needs
  you, grey is idle.

### Keeping the session list clean

Claude Code only fires `SessionEnd` on a clean exit. Close a terminal tab and the session lingers, so
the app prunes the list three ways:

- Sessions with no activity for 30 minutes are dropped automatically, unless they have a pending
  request. Change the window with `CLAUDE_MENUBAR_STALE_MINUTES`.
- Hover any session row and click the **×** to remove it.
- **Clear idle sessions** in the footer menu removes every grey session at once.

Sessions keep the order they first appeared in and never re-sort, so rows do not move under the
pointer while you are reading them.

### Options on a request

| Option | What Claude Code gets |
| :-- | :-- |
The first four match Claude Code's own numbered options in the terminal, so they read the same way.

| Option | Terminal equivalent | What Claude Code gets |
| :-- | :-- | :-- |
| **Yes** | `1. Yes` | `allow` — runs this one call |
| **Yes, always** | `2. Yes, and don't ask again` | `allow`, and this app auto-allows that tool in that project |
| **No** | `3. No` | `deny` with a short reason |
| **No, say why…** | `3. No, and tell Claude what to do differently` | `deny` with whatever you type |
| **Terminal** | — | `ask` — falls through to the prompt, and brings that tab to the front |

"Always" is keyed by project directory and tool, and saved to
`~/Library/Application Support/ClaudeMenuBar/always-allow.json`, so it survives a restart. It is this
app's own list; nothing is written to your Claude Code permission rules. Clear it from the `⋯` menu.

### Answering questions

When Claude calls `AskUserQuestion` with a single question, its options appear as numbered buttons and
clicking one applies that choice in the session.

The hook itself can't carry an answer — it only speaks allow/deny/ask. So the app does it in two
steps: it allows the call, which makes Claude draw its numbered menu in the terminal, then types that
option's number into the session's pane. Claude Code selects on the digit, so the choice lands exactly
as if you had typed it.

The keystroke waits for the session's `Notification` hook, which fires once the menu is on screen, with
a 1.8 second fallback if it never arrives. If the pane can't be identified the app doesn't type
anything; it falls back to denying with your choice written into the reason, which Claude reads and
acts on. For several questions at once, use **Terminal**.

### Focus stays where you put it

Answering never brings the session forward. The keystroke is written straight into the pane with no
`select` and no `activate`, so a background session stays in the background — that is the point of
answering from the menu bar rather than hunting for the tab.

Focus only moves when you ask for it:

- **Terminal** on a card
- clicking the card's header (the tool name and folder)
- clicking a session row that has no pending request

### Finding the right pane

Everything above depends on knowing which pane a session runs in, and the hook payload carries no PID.
So `SessionStart` and `UserPromptSubmit` are installed as **command** hooks rather than HTTP ones. A
command hook runs as a child of `claude` and inherits `ITERM_SESSION_ID`, which it forwards along with
the event. That pins each session id to one exact iTerm2 pane, even with several sessions in the same
directory.

If no pane has been recorded yet — a session started before the hooks were installed — the app falls
back to matching the request's `cwd` against the working directory of each running `claude` process.
That fallback refuses when more than one session shares a directory, rather than typing into whichever
it found first. macOS asks for Automation permission the first time. Other terminals fall back to just
activating the app.

A session shows `pane=-` in the log until it has submitted one prompt since the hooks were installed.
After that it is targeted exactly.

## Notifications

The app requests notification permission on first launch. Notifications carry **Allow** and **Deny**
buttons plus **More options…**, which opens the panel. They only appear when the panel is closed.

If you deny notification permission, the app still badges the menu bar icon and plays a sound.

## Configuration

Both are read from the environment at launch.

| Variable | Default | Meaning |
| :-- | :-- | :-- |
| `CLAUDE_MENUBAR_PORT` | `7788` | Loopback port. Change it and re-install the hooks. |
| `CLAUDE_MENUBAR_TIMEOUT` | `300` | Hook timeout in seconds. The app answers `ask` 15s before it. |
| `CLAUDE_MENUBAR_STALE_MINUTES` | `30` | Drop sessions quiet for this long. |

## Known limits

- Decisions come from the `PermissionRequest` hook. `AskUserQuestion` calls do show up as requests,
  but the hook only accepts allow/deny/ask, so you cannot pick one of Claude's options from here.
  Use **Terminal** on those to answer in the session.
- In headless `claude -p` runs there is no permission prompt to intercept, so the hook never fires.
- Sessions are tracked in memory. Restarting the app empties the list until each session acts again.
