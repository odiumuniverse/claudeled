# claudeled

Blinks the Caps Lock LED on your keyboards while a Claude Code session is waiting
for you. Handles several sessions in several windows at once, lets you pick which
keyboards light up and how long they keep blinking, and — since the same hooks
already know when Claude was working and when it was waiting — reports how your time
actually went.

It drives the keyboard's LED element directly. The Caps Lock **modifier** is never
touched, so your typing case is unaffected — verified by sampling both
`IOHIDGetModifierLockState` and the event system's `.maskAlphaShift` flag while the
LEDs were lit: neither was ever asserted.

> This is an unofficial, community-developed project. It is not affiliated with,
> endorsed by, or sponsored by Anthropic or Claude.

## Install

Needs macOS 13 or newer, and Claude Code.

### From source (recommended)

```sh
git clone https://github.com/odiumuniverse/claudeled
cd claudeled
make install
```

That builds the app, puts it in `/Applications`, symlinks the CLI onto your `PATH`,
installs the zsh completion, and launches it. Needs `swiftc` from the Xcode Command
Line Tools — `xcode-select --install` if you do not have them.

Building locally also sidesteps Gatekeeper entirely, because nothing was downloaded.

### From a release

Download the zip from
[Releases](https://github.com/odiumuniverse/claudeled/releases), unzip, and move
`claudeled.app` to `/Applications`.

macOS will refuse to open it: the app is ad-hoc signed, not notarised, and anything
that arrives through a browser carries a quarantine flag. Either strip the flag:

```sh
xattr -dr com.apple.quarantine /Applications/claudeled.app
```

or open it once, let it be blocked, then allow it in
*System Settings → Privacy & Security → Open Anyway*.

Notarising would remove this step, and requires a paid Apple Developer account.

Launch it once either way. It installs its Claude Code hooks on first launch and
lives in the menu bar — no Dock icon, no app switcher entry.

### Rebuilding

An ad-hoc signature is derived from the binary, so every rebuild looks like a
different app to macOS and the Input Monitoring grant stops applying. `make install`
clears the stale grant so the prompt appears again; grant it and the app restarts
itself.

```sh
make            # build into build/
make test       # run the checks
make run        # launch the built copy without installing it
make install    # build, install, relaunch
make uninstall  # remove the app, the CLI and the completion
make release    # zip the bundle for a GitHub release
make clean      # throw away build output
make help       # list the targets
```

## Layout and tests

`Sources/claudeled/Core/` holds everything that can be decided without a keyboard or a
screen — keyboard selection, the blink decision and its timeout, staleness, the event
log, the statistics, the `settings.json` merge. It imports neither AppKit nor IOKit.
`Sources/claudeled/App/` is the shell around it: the menu bar, the HID writes, the CLI.

`make test` compiles `Core/` together with `Tests/main.swift` and runs it. Assert-based
checks, no framework and no fixtures — one binary that prints what it verified and
exits non-zero when something breaks. Because only `Core/` is compiled in, logic that
needs a test has to live there.

## Menu

| Item | What it does |
|---|---|
| *N sessions waiting* | how many sessions are waiting on you right now |
| Keyboard list | tick any combination; keyboards without a caps LED are listed but not selectable |
| Blink for | 5 min, 10 min, 30 min, or Always — how long the lamp keeps blinking |
| Statistics… | opens the stats window; see [Statistics](#statistics) |
| Claude Code hooks installed | tick to install, untick to remove |
| Start at login | registers a login item via `SMAppService` |
| Hide icon | takes the icon out of the menu bar, keeps blinking |
| Visit GitHub | opens this page |

Without Input Monitoring the menu shows none of that. It leads with the missing
permission and a button to the settings pane instead, because every keyboard would
otherwise appear to have no caps LED — see [Permissions](#permissions).

Hiding is not quitting. To bring the icon back, launch claudeled again — a second
launch reopens the running copy rather than starting another — or run `claudeled show`.

The lamp has exactly one meaning: Claude is waiting for you. It stays dark while
Claude works, which is most of the time.

*Blink for* puts a limit on that. The default is *Always*, which is what claudeled has
always done: blink until you answer. Pick a duration instead and the lamp gives up
after it, on the theory that a light you have ignored for half an hour has stopped
being information. The session is not forgotten — the menu and `claudeled status` still
count it as waiting, and the next thing Claude does re-arms the timer.

Unticking the last selected keyboard is refused. "Nothing selected" and "everything
selected" are the same stored value, so allowing it would leave you looking at a menu
full of ticks and a lamp that never lights.

## CLI

The app bundle is also the CLI: one binary, which runs the menu bar app when given no
arguments and answers as a command line tool when given some. `make install` symlinks
it onto your `PATH`.

```
claudeled                    run the menu bar app
claudeled devices            list keyboards and which ones blink
claudeled devices --names    names only, for scripts
claudeled test <keyboard>    light a keyboard for 3s
claudeled status             show tracked sessions
claudeled blink              show how long the lamp blinks for
claudeled blink <duration>   set it: 5m, 30m, 90s, 1h, or always
claudeled stats              time spent, today and over the last 7 days
claudeled show               bring the icon back after hiding it
claudeled hooks              print the hook config, if you prefer to install it yourself
claudeled help               the same list
```

`claudeled hook <event>` also exists and is not for you: it is what the installed hooks
call.

Zsh completion for `claudeled test` lists your keyboards. The names are read from the
running binary, so a keyboard you just plugged in is completable straight away.

`claudeled blink` and the *Blink for* menu write the same setting, and the running app
notices within a second either way — nothing needs restarting. The menu offers four
presets; the CLI takes any duration.

## How it works

Claude Code hooks report *events* — `prompt`, `stop`, `notify`, `end` — into
`~/.config/claudeled/sessions/`, one file per session. The app decides what those
events mean, so the hooks stay dumb and `settings.json` never has to change again.

`stop` and `notify` mean Claude needs you, and light the lamp. `prompt` means work is
in flight. `PostToolUse` also reports `prompt`, which is what stops the lamp blinking
after you approve a permission prompt: a tool running is the evidence that the block
is gone.

Several windows aggregate with OR — any one session waiting is enough to blink.

`SubagentStop` is deliberately not hooked. That is what keeps subagents from blinking
the light on behalf of the main agent.

A session killed with `kill -9`, or a terminal window closed without warning, leaves
its file behind. The app records the owning process id and drops any session whose
process is gone, within a second. A 12 hour TTL is the backstop for the rare case
where the process could not be identified.

Everything claudeled keeps lives under `~/.config/claudeled/`:

| Path | What |
|---|---|
| `config.json` | keyboard selection, blink timeout, idle cap |
| `sessions/` | one file per live session: pid, timestamp, last event |
| `events/YYYY-MM.jsonl` | the append-only event log the statistics read |
| `diagnostics.log` | what the app saw at launch — keyboards, permission state |

`diagnostics.log` is the first thing to read when the lamp does not light: it records
whether Input Monitoring was granted and which keyboards exposed a caps LED.

## Statistics

The same hooks append one line each to `~/.config/claudeled/events/YYYY-MM.jsonl`, one
file per month. `claudeled stats` reads them back:

```
today      worked 1h 12m · waiting on you 34m · blocked 2m
this week  worked 8h 03m · waiting on you 3h 41m

project      worked   waiting
topscan       5h 20m    2h 10m
claudeled     2h 43m    1h 31m

12 sessions this week · 4h 12m skipped as away (gaps over 5m)
```

Every pair of consecutive events brackets a gap, and the earlier event says what was
happening during it: after `prompt` Claude is working, after `stop` it is waiting for
you, after `notify` it is blocked on a permission prompt.

```
claudeled stats week|month|year|all   one window instead of today plus the week
claudeled stats -i                    pick a period and a destination with the arrows
claudeled stats month --md            a markdown table, for pasting
claudeled stats week --json           the same numbers, for scripts
claudeled stats all --card [file]     a PNG card, for sharing
```

The menu has the same thing under *Statistics…*: a segmented control to switch period,
and buttons for *Copy as Markdown* and *Save PNG Card…*.

The picker only appears when both ends are a terminal, so `claudeled stats --json |
jq` is never interrupted by a menu.

A gap longer than five minutes is not counted at all — you went to lunch, or shut the
lid, and no honest number can tell that apart from thinking hard. It is reported on
the last line rather than dropped silently. Change the threshold with
`"idleCapSeconds"` in `~/.config/claudeled/config.json`.

Only the last component of the working directory is stored, never the full path, so
sharing a report does not leak where your work lives.

## Permissions

claudeled **requires Input Monitoring**, in
*System Settings → Privacy & Security → Input Monitoring*. It asks on first launch.

macOS gates opening a keyboard HID device behind that permission whether you mean to
read keystrokes or only write to an LED. Without it the caps LED element is not merely
unwritable, it is invisible — the keyboard looks like it has no LED at all. The menu
says so explicitly and offers to open the settings pane, rather than showing you a
list of keyboards that mysteriously cannot be selected.

The command line tool often works without the grant because it inherits the one held
by your terminal. The app is its own subject in the privacy database and needs its own.

What that permission allows and what claudeled does with it are different things.
There is no input-reading code in this repository: no
`IOHIDDeviceRegisterInputValueCallback`, no `IOHIDDeviceRegisterInputReportCallback`,
no event tap, no global monitor. It registers device arrival and removal callbacks,
and writes LED values. Grep for it before you trust it.

## Tested on

| Keyboard | Transport | Result |
|---|---|---|
| Apple Internal Keyboard (MacBook) | SPI | works |
| Apple Magic Keyboard 2 | Bluetooth | works |

Works with or without a Caps Lock → Control remap; the remap turned out to be
irrelevant to LED writes.

Other keyboards are handled generically: if the keyboard exposes a Caps Lock LED
element it can be driven, and `claudeled test <name>` tells you in three seconds.

## Uninstall

Untick "Claude Code hooks installed" in the menu first — that takes claudeled out of
`~/.claude/settings.json` and leaves your other hooks alone. Then:

```sh
make uninstall          # app, CLI symlink, completion
rm -rf ~/.config/claudeled   # config and session state, if you mean it
```

`make uninstall` deliberately leaves the config alone, so reinstalling does not lose
your keyboard selection.

## License

MIT
