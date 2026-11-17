# Lord of the Claudes

One panel to rule them all. A macOS menu bar app that tracks every Claude Code session open in Ghostty, tells you which ones are waiting for you, lets you prompt them and answer their permission prompts in one place, and brings them all back after a reboot. Its overseer answers "what needs me?" and puts your prompts in the right tab.

<p align="center">
  <img src="docs/panel-dark.png" width="460" alt="The panel: the overseer's box lists three sessions waiting for you, longest first, above three Ghostty windows, one folded away">
</p>

## What it does

- **Has an overseer to ask.** The box at the top of the panel is a chat with it. Ask where things stand, or tell it what a session should do. See [Ask the overseer](#ask-the-overseer).
- **Lists what needs you.** Every session waiting for you, across all windows, longest wait first, with what each is waiting for.
- **Shows every session, grouped by Ghostty window.** Title, last prompt and time since you last spoke to it. Each window gets a header with how many are open and how many are waiting. Two windows in one project are told apart: "shop" and "shop 2".
- **Folds a window away.** The chevron on a group hides its sessions and keeps its counts. Cmd+1 to Cmd+9 jump to a group, Cmd+Down and Cmd+Up to the next or previous one.
- **Names your windows.** Click a group's name to rename it. Leave it empty to go back to the directory name.
- **Replies without switching tabs.** Expand a session, type in "Send a prompt" and press Return. Cmd+R opens the field on the selected session.
- **Prompts a whole window at once.** The megaphone on a group sends one prompt to every session in it. It asks once more, naming the count, before it sends.
- **Answers permission prompts in one window.** Approve, deny, or tell Claude what to do instead.
- **Lets one session direct the rest.** A lord session runs `lotc` to prompt its siblings and read their answers.
- **Flags the ones waiting for you.** A session that finishes work while its tab is out of sight gets a bell. Sessions reopened after a restart come back quiet. The menu bar shows the count as "2/7".
- **Jumps to the tab.** Ctrl+Option+C opens the panel from anywhere. Return jumps to the selected session. Cmd+F filters.
- **Reopens everything after a restart.** Quit Ghostty or reboot, and each session resumes in the tab it was in.
- **Remembers closed sessions.** They stay under "Recently closed" for 14 days with a Reopen button. The last five show, the rest behind "Show all". Sessions in a temporary directory are forgotten once closed.
- **Links to the ticket.** A Jira key or Zendesk ticket number in the session title becomes a button.

<p align="center">
  <img src="docs/panel-reply.png" width="460" alt="A session waiting for you, with a reply typed into its Send a prompt field">
</p>

## Install

Needs macOS 14 or later, [Ghostty](https://ghostty.org) 1.3 or later and the Xcode command line tools.

    brew install jonesybaker/tap/lord-of-the-claudes
    lord-of-the-claudes

Or from source:

    git clone https://github.com/Jonesybaker/lord-of-the-claudes
    cd lord-of-the-claudes
    ./build.sh install

On first run macOS asks to let it control Ghostty. Allow it.

## Using it

| Key | Does |
| --- | --- |
| Ctrl+Option+C | Open or close the panel |
| Type, then Return | Ask the overseer |
| Cmd+F | Filter by title, directory or group |
| Up, Down | Move |
| Cmd+Down, Cmd+Up | Jump to the next or previous group |
| Cmd+1 to Cmd+9 | Jump to that group. Its number is on its header |
| Return, with nothing typed | Jump to the session, or reopen a closed one |
| Right, Left, Tab, with nothing typed | Show or hide its recent prompts |
| Cmd+R | Reply to the selected session |
| Esc | Cancel a proposal, leave a text field, or close |

- The panel opens with the keyboard in the overseer's box. The arrows and the Cmd keys work the list from there.
- In a reply, broadcast, rename or filter field, the arrows and Return edit the text. Esc leaves the field.
- A folded group stays folded until you open it, across restarts. A filter still finds its sessions, and Cmd+N opens it.
- Right-click a session and choose "Make lord of this group". The lord shows a crown.
- Hover a running session for an X that ends it and closes its tab.
- Sessions untouched for over a week get a "Close them" banner.
- "Reopen when Ghostty starts" off: the panel offers "Reopen all" instead.
- `pkill -USR1 -x LordOfTheClaudes` toggles the panel from a script.

## Ask the overseer

<p align="center">
  <img src="docs/panel-overseer.png" width="460" alt="The overseer answers where the passkeys work got to, then proposes a prompt for the invoice session, waiting for Send">
</p>

The overseer is a Claude Code conversation the app runs for you. Type in the box at the top of the panel and press Return.

- **It answers.** "What needs me?", "where did the pricing work get to?", "which tab is the migration in?" It names each session with its group and tab. Click a name to jump to that tab.
- **It routes, and you confirm.** Tell it what a session should do, "tell the checkout one to rebase", and it puts the exact prompt on a card: "Send to Shop, tab 2". Edit it if you like. Return or Send types it into that tab; Esc or Cancel drops it. Nothing reaches a tab without that confirm.
- **It starts new sessions.** When nothing open fits, the card offers a new session instead, in a new tab in the right window, with Claude Code started on your prompt.
- **It asks when unsure.** If two sessions could be meant, the card lists them as buttons.
- **"What needs me" needs no model.** Before you ask anything, and behind the bell button, the box lists every session waiting for you, longest wait first. It is worked out in the app.

What it sees and what it uses:

- It runs `claude -p` on your own Claude Code login, so it counts towards your plan like any other session. An answer takes a few seconds.
- It sees a short briefing with each message, not transcripts: every open session's group, tab, title, directory, status and digest, or its last prompt when there is no digest. It has no tools, hooks, MCP servers or CLAUDE.md (`--safe-mode`), so it cannot read a file or run anything.
- The chat is kept in `overseer.json` beside `state.json`, up to 60 messages. New chat starts a fresh conversation.
- To change the model, edit `~/Library/Application Support/LordOfTheClaudes/overseer-settings.json`:

      {"effort": "low", "model": "sonnet"}

  `model` takes any alias or model name Claude Code does, `effort` any of its `--effort` levels. If the app cannot find `claude`, add `"claude": "/path/to/claude"`.

## Answer permission prompts in one place

    lotc hooks install

When Claude Code would ask permission, a window comes to the front. It shows which session is asking, its directory and exactly what it wants to run or change. If several sessions ask at once, it shows them one at a time.

| Key | Does |
| --- | --- |
| Cmd+Return | Approve |
| Cmd+D | Deny. Claude stops, as with "No" in the terminal |
| Type, then Return | Deny and tell Claude what to do instead |
| Esc | Answer in the terminal and go to the tab |

Plain Return never approves: the window takes focus while you may be typing somewhere else. Answer in the terminal and the question leaves the window by itself.

If Lord of the Claudes is not running, Claude Code asks in the terminal as usual. `lotc hooks install` edits `~/.claude/settings.json`, leaves the rest of it as it was and keeps a backup beside it. `lotc hooks uninstall` takes the hook out again.

## Let sessions work together: `lotc`

`lotc` lets a Claude Code session talk to the other sessions in its Ghostty window. Claude runs it through Bash, so one session can be the lord of its window: hand work to its siblings, wait, and read what they said.

| Command | Does |
| --- | --- |
| `lotc list` | The sessions in this window: tab, working or idle, waiting for you, lord, title. `--json` for scripts |
| `lotc send 2 "run the tests"` | Types a prompt into tab 2 and submits it. A tab is its number or part of its title |
| `lotc broadcast "pull main"` | Sends a prompt to every other tab in the window |
| `lotc wait 2` | Waits until tab 2 has finished what it was last sent, then prints its answer |
| `lotc last 2` | Prints tab 2's last answer now |
| `lotc lord` | Makes this session the lord of its window |

`wait` gives up after 110 seconds, inside Claude Code's two-minute Bash limit. Run it again to keep waiting, or pass `--timeout`. A prompt of `-` is read from stdin. Lord of the Claudes must be running.

A lord cannot answer its siblings' permission prompts. Those come to you, in the permission window.

## Ticket links

Links pasted into a session are picked up by themselves. To turn a Jira key or ticket number in a session title into a link, name your sites in `~/Library/Application Support/LordOfTheClaudes/tickets.json`:

    {"zendesk": "https://example.zendesk.com/agent/tickets/", "jira": "https://example.atlassian.net/browse/"}

## How it works

- Every 5 seconds it reads `~/.claude/sessions/*.json`, Claude Code's registry of running processes, and keeps the ones alive under Ghostty.
- Titles come from the session transcript. Prompts come from `~/.claude/history.jsonl`.
- It drives Ghostty through AppleScript. Tabs are matched to sessions by title. A new session's tab reads "Claude Code" until Claude names it, so it is matched by directory instead, when it is the only such session and tab there. It never guesses: a session it cannot place shows under "Other".
- Replies and broadcasts are typed into the tab through AppleScript, as if you had typed them.
- `lotc` talks to the app over a Unix socket only you can open: `~/Library/Application Support/LordOfTheClaudes/lotc.sock`. It finds its session by walking up its parent processes to one listed in `~/.claude/sessions`.
- It only reads Claude's files, except that `lotc hooks install` adds one hook to `~/.claude/settings.json`. Its own state is `~/Library/Application Support/LordOfTheClaudes/state.json`, with `overseer.json` and `overseer-settings.json` beside it.
- The overseer's conversation is an ordinary Claude Code session in `~/Library/Application Support/LordOfTheClaudes/overseer`. It is never listed in the panel, and runs with `LOTC_OBSERVER=1` so `lotc`'s own hooks leave it alone.
- The app has no network code. What you ask the overseer goes to Anthropic through `claude -p`, with the briefing. Nothing else leaves your Mac.

## Expect breakage

Claude Code's session files are undocumented and can change in any release. Tested with Claude Code 2.1.322, Ghostty 1.3.1 and macOS 26. The overseer was tested with Claude Code 2.1.326 and needs its `--safe-mode`. If a new version breaks it, open an issue.

## Development

- `./build.sh test` runs the tests.
- `LOTC_WINDOW_TESTS=1 ./build.sh test` also opens the permission window.
- To try `lotc` beside an installed copy, run the build with `LOTC_SANDBOX=1 LOTC_SOCKET=<path>`. That turns off the hotkey and state.json, and keeps the overseer's files in a temporary folder. Set the same `LOTC_SOCKET` for `lotc`.

## Screenshots

The screenshots show made-up sessions. Regenerate them with:

    swift build -c release && .build/release/LordOfTheClaudes --screenshots docs

## Licence

MIT. An independent project, not affiliated with or endorsed by Anthropic. Claude is a trade mark of Anthropic.
