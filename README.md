# tremind

Reminders that survive a reboot, shown as desktop notifications. This repository holds `tremind`, a
single bash script, and the tests that cover it. The `remind` plugin for
[tote](https://github.com/totecli/tote) will drive it from the interface; `tremind` is also a tool
of its own.

```
$ tremind add -t 30m Call the bank
Reminder 2704150831-k3x on 2027-04-15 08:31

$ tremind add --at "2027-04-15 09:30" --line "Renew the domain" --line "Pay the invoice"
Reminder 2704150930-q7d on 2027-04-15 09:30

$ tremind list
ID             WHEN             MESSAGE
2704150831-k3x 2027-04-15 08:31 Call the bank
2704150930-q7d 2027-04-15 09:30 - Renew the domain  [+1 lines]
```

## Requirements

- Linux with a systemd user session (`systemctl --user`) and a notification daemon.
- bash 4 or later, GNU `date`, `flock` (util-linux), `iconv`, and `notify-send` (package
  `libnotify-bin` on Debian and Ubuntu).

macOS is not supported. The design leaves room for it (a launchd job that runs `tremind tick` every
minute), but nothing was written or tested there.

## Install

From a release: download `tremind` and `tremind.sha256` from the
[releases page](https://github.com/20syldev/tremind/releases), check the file and put it on your
`PATH`:

```
sha256sum -c tremind.sha256
install -m 755 tremind ~/.local/bin/tremind
```

The checksum proves that the file is the one published here, not who published it. From a checkout
of the repository, `tools/package.sh` builds the same two files in `dist/`, or you can copy the
script yourself:

```
install -m 755 tremind ~/.local/bin/tremind
```

There is nothing else to set up: the first `tremind add` writes and starts the timer. Run
`tremind test` to check the setup; it shows a notification.

If you move the script, run `tremind install` once more (any `add` does it too): the timer points to
the path of the script.

## Usage

```
tremind add -t DELAY TEXT...      remind in DELAY
tremind add --at WHEN ...         WHEN is a delay or an exact local time
       --body TEXT                the message, up to 16 lines and 1000 bytes
       --line TEXT                one line of a list, repeatable
tremind list                      pending reminders, soonest first
tremind ids                       the ids, one per line
tremind presets                   suggestions for WHEN, one per line
tremind cancel ID                 cancel one reminder
tremind cancel --all              cancel all of them
tremind test                      check the setup and show a notification
tremind install | uninstall       write and start, or stop and remove, the timer
```

- **A delay** is made of numbers followed by `w`, `d`, `h` or `m`: `30m`, `1h30m`, `4d`, `1w`. There
  are no seconds: the resolution is one minute.
- **An exact time** is `YYYY-MM-DD HH:MM` in local time. It must exist (no 30 February, no hour that
  a clock change skips), must not be in the past and must be less than ten years ahead. In the hour
  that the clock repeats in autumn, the later of the two (winter time) is meant.
- **A reminder is an instant**, fixed when you add it. A delay that spans the clock change of
  autumn, or a change of time zone while the reminder is pending, does not move it; `list` shows
  the time in the zone of the moment you added it.
- **The message** is `--body` or the words after the options. It may hold several lines. `--line`
  adds the lines of a list after it; with two or more lines each one gets a `- `, with a single line
  it stays plain text. Accents, emoji and any script are fine, joined emoji and Persian text
  included. Control characters (a tab too) and invisible characters that can disguise text (the
  bidirectional controls, the zero-width space, the line and paragraph separators, the word joiner,
  the byte order mark) are refused.
- A word of the message that starts with `-` is read as an option, wherever it is. Put `--` before
  the words, or use `--body`: `tremind add -t 1h -- Call - now`, `tremind add -t 1h --body "-dash"`.
- Backslashes are shown as typed (`C:\new` stays `C:\new`).

The exit status is 0 on success, 1 when the call was refused or failed, and 2 for a usage error.

## How it works

- Each reminder is a small file in `$XDG_STATE_HOME/tremind/` (default `~/.local/state/tremind/`):
  the line `due=YYYY-MM-DD HH:MM` (for display), the line `epoch=SECONDS` (the instant, which is what
  `tick` compares), a blank line, the message. The file name is the id, which starts with the due
  time (`2704150930-q7d`), so ids sort in the order they fire. The folder is private (mode 700).
- One user timer, `tremind.timer`, runs `tremind tick` every minute. `tick` shows every reminder
  that is due and removes it. The message is never written in a unit file and never goes through a
  shell: it reaches `notify-send` as one argument after `--`. The unit runs `bash` on the script by
  the path it had at install, so the script needs no execute bit.
- The timer reads one state folder, the `XDG_STATE_HOME` of the run that installed it. If you run
  `tremind` later with another `XDG_STATE_HOME` (or none) while reminders wait in the folder the
  timer reads, `add` refuses and says so, because those reminders would never fire. Use the same
  value everywhere, or cancel them first.
- The timer is persistent. A reminder that came due while the machine was off, or while you were
  logged out, is shown at your next login (a user timer runs only during a session; `loginctl
  enable-linger` would change that, and a notification then has no screen to show on).
- When no reminder is left the timer disables itself, and the next `add` enables it again: nothing
  wakes up while you have no reminder.
- A reminder is shown once. `tick` takes the file before it shows it, and two ticks at the same time
  cannot both take it. If the notification cannot be shown (no notification daemon, for example) the
  reminder is put back and the next tick tries again. A tick that is killed in the instant after it
  showed a reminder can show it again at the next tick; a reminder is never lost.
- The notification is sent with no timeout. KDE Plasma and dunst keep it until you close it; GNOME
  shows a banner, then keeps it in the notification list, and Do Not Disturb hides the banner.
  There is no Copy button: `notify-send` would have to wait for the click, and one reminder would
  block the next.

## Limits

- A reminder fires within a minute after its time: `in 30 minutes` is 30 to 31 minutes, because a
  delay is rounded up to the next minute.
- Removing the `remind` plugin does not cancel the reminders: they belong to `tremind` and to your
  systemd user manager. `tremind cancel --all` cancels them.
- Do not delete or move the script while reminders wait: the timer would fail every minute and
  show nothing. Run `tremind cancel --all` and `tremind uninstall` first, or run `tremind add` or
  `tremind install` from the new place, which points the timer to it.
- `tremind uninstall` stops the timer and removes its units. The reminders stay in the state folder
  and `tremind list` still shows them, but nothing shows them until the next `add` or `install`
  starts the timer again; the ones that came due meanwhile are then shown together.

## Environment

| Variable            | Effect                                                                           |
| ------------------- | -------------------------------------------------------------------------------- |
| `XDG_STATE_HOME`    | Where the state folder is. Kept in the service unit when it is set at install.   |
| `XDG_CONFIG_HOME`   | Where the user units are written (`systemd/user/`).                              |
| `TREMIND_TITLE`     | Title of the notifications. Default: `Rappel` under a French locale, else `Reminder`. The timer runs `tick` with the environment of the systemd user manager, not with yours: set it there (`systemctl --user set-environment TREMIND_TITLE=...`). |
| `TREMIND_NOW_EPOCH` | A fixed "now", in seconds since the epoch. For the tests.                        |

## Tests

```
tests/run.sh            all of them
tests/run.sh cancel     those whose name contains "cancel"
```

The tests use a fake `systemctl` and a fake `notify-send`, a fixed clock, and a temporary folder for
HOME, the state and the units: they never touch your session or your real reminders. The temporary
folder is deleted file by file at the end.

## License

MIT. See [LICENSE](LICENSE).
