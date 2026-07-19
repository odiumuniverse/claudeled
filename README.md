# claudeled

Blinks the Caps Lock LED on your keyboards while a Claude Code session is waiting
for you. Handles several sessions in several windows at once, and lets you pick
which keyboards light up.

It drives the keyboard's LED element directly. The Caps Lock **modifier** is never
touched, so your typing case is unaffected — verified by sampling both
`IOHIDGetModifierLockState` and the event system's `.maskAlphaShift` flag while the
LEDs were lit: neither was ever asserted.

## Install

```sh
brew tap odiumuniverse/claudeled https://github.com/odiumuniverse/claudeled
brew install --cask claudeled
```

Then launch it once. It installs its Claude Code hooks on first launch and lives in
the menu bar — no Dock icon, no app switcher entry.

### From source

```sh
./build.sh            # -> build/claudeled.app
open build/claudeled.app
```

## Menu

| Item | What it does |
|---|---|
| *N sessions waiting* | how many sessions currently match the mode |
| **Blink while Claude waits for me** | double pulse when Claude hands the turn back to you |
| **Blink while Claude is working** | single discreet pulse while Claude is busy |
| Keyboard list | tick any combination; keyboards without a caps LED are shown but disabled |
| Claude Code hooks installed | tick to install, untick to remove |
| Start at login | registers a login item via `SMAppService` |

The two modes are mutually exclusive: one lamp, one meaning.

## CLI

The app bundle is also the CLI, and the cask puts it on your `PATH`.

```
claudeled devices            list keyboards and which are selected
claudeled devices --names    names only, for scripts
claudeled test <keyboard>    light a keyboard for 3s
claudeled status             show tracked sessions and the current mode
claudeled hooks              print the hook config, if you prefer to install it yourself
```

Zsh completion for `claudeled test` lists your keyboards. The names are read from the
running binary, so a keyboard you just plugged in is completable straight away.

## How it works

Claude Code hooks report *events* — `prompt`, `stop`, `notify`, `end` — into
`~/.config/claudeled/sessions/`, one file per session. The app decides what those
events mean according to the current mode, which is why switching modes in the menu
does not require rewriting `settings.json`.

`SubagentStop` is deliberately not hooked. That is what keeps subagents from blinking
the light on behalf of the main agent.

A session killed with `kill -9`, or a terminal window closed without warning, leaves
its file behind. The app records the owning process id and drops any session whose
process is gone, within a second. A 12 hour TTL is the backstop for the rare case
where the process could not be identified.

## Permissions

macOS may ask for **Input Monitoring** the first time, because opening a keyboard HID
device is gated behind it regardless of intent. You can decline: driving the LED works
without it, tested with the permission revoked.

claudeled contains no input-reading code — no `IOHIDDeviceRegisterInputValueCallback`,
no `IOHIDDeviceRegisterInputReportCallback`, no event tap, no global monitor. It only
registers device arrival and removal callbacks, and writes LED values.

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

Untick "Claude Code hooks installed" in the menu first, then:

```sh
brew uninstall --cask claudeled
brew uninstall --zap --cask claudeled   # also removes ~/.config/claudeled
```

## License

MIT
