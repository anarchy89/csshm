# csshm

Cluster SSH for macOS: type once and it goes to many SSH sessions at the same time.

csshm opens one Terminal window per host, tiles them across your monitors
and adds a red master window. Whatever you type in the master goes to every
host. Click a host window and type and it goes only to that host.

It is written in Swift and inspired by [csshX](https://github.com/brockgr/csshx)
and by ClusterSSH on Linux. It takes the same command line as csshX.

I wrote it because csshX is no longer maintained. It relies on Perl libraries
that Apple has stopped maintaining on macOS, which leads to some odd bugs.

Status: early. It works in testing with dozens of windows, but has not yet
had wide use. Please report problems.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Giving hosts](#giving-hosts)
- [Options](#options)
- [Settings file and clusters](#settings-file-and-clusters)
- [Monitors and the grid](#monitors-and-the-grid)
- [The master window and its menu](#the-master-window-and-its-menu)
- [Choosing which hosts receive your typing](#choosing-which-hosts-receive-your-typing)
- [When a session ends](#when-a-session-ends)
- [Keys and passwords](#keys-and-passwords)
- [Security](#security)
- [Coming from csshX](#coming-from-csshx)
- [Troubleshooting](#troubleshooting)
- [How it works](#how-it-works)
- [Development](#development)
- [License](#license)

## Requirements

- macOS 13 or later. Development and testing so far have been on macOS 27.
- Terminal.app. Other terminal applications are not supported.
- To build from source: Xcode or the Swift toolchain.

## Install

    curl -fsSL https://raw.githubusercontent.com/anarchy89/csshm/main/setup.sh | sh

This downloads the latest release, checks that it runs and puts it in
`/usr/local/bin`, asking for your password if that folder needs it. csshm is
one file, for both Apple silicon and Intel Macs, with nothing else to install.

To do the same by hand:

    curl -L -o csshm https://github.com/anarchy89/csshm/releases/latest/download/csshm
    chmod +x csshm
    sudo mkdir -p /usr/local/bin
    sudo mv csshm /usr/local/bin/

The binary is not signed with an Apple developer certificate. Downloaded with
`curl` as above, it runs. Downloaded with a web browser, macOS refuses to
open it until you clear the download mark:

    xattr -d com.apple.quarantine csshm

### Update

    csshm --update

This checks the latest release and replaces the installed csshm if the
release is newer. It asks for your password when the folder needs it.

### Uninstall

    sudo rm /usr/local/bin/csshm
    rm -rf ~/.config/csshm

The second line removes your settings file, if you made one. csshm keeps
nothing else on your Mac.

### Build from source

This needs Xcode or the Swift toolchain.

    git clone https://github.com/anarchy89/csshm
    cd csshm
    swift build -c release
    sudo cp .build/release/csshm /usr/local/bin/

A Homebrew tap is planned.

## Quick start

    csshm web1 web2 web3

Three windows open, tiled, with a red master window along the bottom of the
screen. Type in the red window and all three hosts receive it. Press Ctrl-A
then `x` in the red window to close everything.

A more typical use, with one user and one key for a list of servers:

    csshm --login ubuntu --ssh_args "-i ~/.ssh/key" --addresses servers.txt

where `servers.txt` holds one address per line.

## Giving hosts

### How to write a host

| Form | Example | Meaning |
|---|---|---|
| `host` | `10.0.0.5`, `web1` | The address or name. A name from `~/.ssh/config` works, because csshm runs the real `ssh` |
| `host:port` | `10.0.0.5:2222` | With a port |
| `user@host` | `ubuntu@10.0.0.5` | With a user |
| `user@host:port` | `ubuntu@10.0.0.5:2222` | With both |
| `user,host` | `ubuntu,10.0.0.5` | The same as `user@host` |
| `user,host:port` | `ubuntu,10.0.0.5:2222` | The same as `user@host:port` |
| `user@host,KEY` | `admin@10.0.0.5,~/.ssh/key-b` | With a private key for this host only |
| `user,host,KEY` | `admin,10.0.0.5,~/.ssh/key-b` | The same |
| `,host,KEY` | `,10.0.0.5,~/.ssh/key-b` | A key for this host, with the `--login` user |
| `[ipv6]:port` | `[fe80::1]:2222` | IPv6 with a port. A bare `fe80::1` also works |

The `@` and comma forms can be mixed freely. Rules worth knowing:

- A user written with a host wins over `--login`.
- The user comes first: `ubuntu,10.0.0.5`, not `10.0.0.5,ubuntu`.
- No spaces inside a host: write `ubuntu,10.0.0.5`, not `ubuntu, 10.0.0.5`.
- A key path cannot contain a comma or a space.
- A host name may contain letters, digits, dots, dashes and underscores (plus
  colons and `%` for IPv6). A user may also contain `+`, `@` and `\`.
  Anything else is refused, including control characters.
- If any host is written wrongly, csshm names it and opens nothing.
- The same host listed twice opens two windows.

### Where hosts can come from

As arguments:

    csshm --login ubuntu 10.0.0.1 10.0.0.2 10.0.0.3
    csshm --login ubuntu $(< servers.txt)

From a file, with `--addresses` (or `--hosts`, which means the same):

    csshm --login ubuntu --addresses servers.txt

From standard input:

    cat servers.txt | csshm --login ubuntu
    csshm --login ubuntu < servers.txt

Standard input is read only when no hosts are given as arguments and no file
is named. To combine a file with extra hosts, name the file:
`csshm --addresses servers.txt 10.0.0.9`. `--addresses` may be repeated and
`--addresses -` reads standard input explicitly.

### The file format

One host per line, in any of the forms above.

    # production web servers
    10.0.0.1
    10.0.0.2                      # a comment can follow a host
    admin,10.0.0.3
    root@10.0.0.4:2222
    ubuntu,10.0.0.5,~/.ssh/key-b

    10.0.0.6   tail -f /var/log/syslog

- `#` starts a comment. Blank lines are skipped.
- Text after a host, separated by a space, is a command to run on that host
  in place of a login shell. It overrides `--remote_command` for that host.
- There is no header row and there are no other columns.

## Options

| Option | Meaning |
|---|---|
| `-l`, `--login USER` | User to log in as, for hosts that do not name one |
| `--ssh_args ARGS` | Extra arguments for ssh, given as one quoted string, for example `"-i ~/.ssh/key -o ConnectTimeout=5"`. They apply to every host. Quotes inside the string are respected; `~` is left for ssh to expand |
| `--screen SPEC` | Monitors to use. See [Monitors and the grid](#monitors-and-the-grid) |
| `--hosts FILE`, `--addresses FILE` | Read hosts from a file. `-` means standard input. May be repeated |
| `--remote_command CMD` | Command to run on every host in place of a login shell |
| `--ssh COMMAND` | Program to run instead of `ssh`. It receives the same arguments ssh would |
| `-x`, `--tile_x N` | Fixed number of columns on each monitor |
| `-y`, `--tile_y N` | Fixed number of rows on each monitor. Ignored if `--tile_x` is given |
| `--profile NAME` | Terminal profile for the host windows, for example one with a small font or the bell switched off. `--slave_settings_set` and `--sss` mean the same |
| `--master_profile NAME` | Terminal profile for the master window. `--master_settings_set` and `--mss` mean the same |
| `--font_size N` | Font size for the host windows |
| `--menu_key KEY` | Key that opens the menu, written like `ctrl-b`. The default is Ctrl-A |
| `--config FILE` | Settings file to read instead of `~/.config/csshm/config.toml` |
| `--list_clusters` | Print the names of the clusters in the settings file and exit |
| `--debug` | Show the command each window runs and leave windows open when their session ends |
| `--update` | Replace this csshm with the latest release, if that is newer |
| `-h`, `--help` | Show the built-in help |
| `-v`, `--version` | Show the version |

Options may be written `--name VALUE` or `--name=VALUE`, with one dash or
two and shortened to any unique prefix (`--scr 2`).

Each host's session is started as:

    ssh [-i KEY] [ssh_args] [-l USER] [-p PORT] HOST [COMMAND]

## Settings file and clusters

csshm reads `~/.config/csshm/config.toml` if it exists. Every line is
optional and anything given on the command line wins over the file.

    # Defaults for every run
    login = "ubuntu"
    ssh_args = "-i ~/.ssh/key -o StrictHostKeyChecking=accept-new"
    screen = "2-3"
    remote_command = ""
    ssh = "ssh"
    tile_x = 0                 # 0 means work it out
    tile_y = 0

    # Appearance
    profile = "Basic"          # Terminal profile for the host windows
    master_profile = "Basic"   # and for the master window
    font_size = 10             # host windows
    master_height = 87         # points; Terminal's minimum applies if larger
    menu_key = "ctrl-b"        # instead of Ctrl-A

    [colors]
    master_background = "#940000"
    master_text = "#ffffff"
    disabled_text = "#939393"
    selected_background = "#4689d0"

    [clusters]
    web = ["web1", "web2", "admin@web3:2222"]
    prod = "/Volumes/data/servers.txt"
    all = ["web", "prod"]

The file is [TOML](https://toml.io). Text goes in quotes and numbers do not.
A misspelt setting or a wrong kind of value is reported with the file name
and nothing opens.

### Clusters

A cluster is a name for a group of hosts. Give the name wherever a host is
expected:

    csshm web
    csshm web 10.0.0.9
    csshm --list_clusters

- A cluster written as a list holds hosts in any of the usual forms.
- A cluster written as one piece of text is the path of a hosts file, in the
  same format `--addresses` reads.
- A cluster can name other clusters.
- If a cluster and a real host share a name, the cluster wins.

### Profiles, font size and the menu key

- **Profiles** are the ones listed in Terminal's settings. A profile that
  does not exist is refused, with the list of those that do. The profile is
  applied first; csshm's colours for the master, for disabled hosts and for
  the selection go on top of it.
- **Font size** applies to the host windows. While running, Ctrl-A `f` makes
  the text smaller and Ctrl-A `F` larger and the windows keep their places.
- **The menu key** can be Ctrl plus any letter except H, I, J and M, which
  the terminal uses for Backspace, Tab and Enter. Change it if you need
  Ctrl-A for something on the remote side, such as tmux or screen. The rest
  of this page says Ctrl-A; read it as your key.

## Monitors and the grid

`--screen` chooses the monitors:

| Value | Monitors used |
|---|---|
| `2` | Monitor 2 |
| `2-4` | Monitors 2, 3 and 4 |
| `1,3` | Monitors 1 and 3 |
| `3-1` | Monitors 3, 2 and 1, with the master on 3 |
| not given | Monitor 1 |

- Monitor 1 is the primary display, the one with the menu bar. The others
  follow the order macOS reports them, which is not always left to right on
  your desk. If a number is not the monitor you expected, try the next one.
- Each monitor gets its own grid. No window straddles two monitors.
- Hosts are shared between monitors in proportion to their size, so equal
  monitors get equal numbers and a larger one gets more.
- The master window sits along the bottom of the first monitor listed.
- A monitor number that does not exist is refused and nothing opens.

The number of columns is worked out from the number of windows on each
monitor: the count near the square root that leaves the fewest empty cells.
When two counts tie, a landscape monitor gets more columns and a portrait one
fewer. A last row that is not full is simply left short.

| Windows | Grid on a landscape monitor |
|---|---|
| 3 | 3 side by side |
| 5 | 3 + 2 |
| 7 | 4 + 3 |
| 12 | 4 × 3 |
| 36 | 6 × 6 |
| 40 | 8 × 5 |

The grid is worked out again every time the number of windows changes. To
override it, use `--tile_x` or `--tile_y` or the `g` and `G` menu keys while
running. A `g`/`G` adjustment lasts until the number of windows changes.

If a monitor's resolution changes or a monitor is unplugged while csshm is
running, press Ctrl-A `r` to re-tile.

## The master window and its menu

The red window shows how many hosts your typing is going to. Everything you
type there is sent on, including Ctrl-C, Ctrl-Z, Ctrl-D and the arrow keys.

Press Ctrl-A for the menu. Esc leaves it.

| Key | Action |
|---|---|
| Ctrl-A | Send a real Ctrl-A to the hosts (so Ctrl-A Ctrl-A is "start of line" in a shell) |
| `r` | Re-tile. Also brings back hidden or minimised windows and raises them all |
| `c` | Add a host. Type it in any of the host forms and press Enter |
| `e` | Selection mode. See the next section |
| `n` | Enable all hosts |
| `t` | Toggle all: enabled hosts become disabled and the reverse |
| Space | With exactly one host enabled, disable it and enable the next. With none enabled, enable the first |
| `g` / `G` | One more / one fewer column. These keep the menu open so they can be repeated |
| `f` / `F` | Smaller / larger text in the host windows. Also repeatable |
| `o` | Sort the windows: `h` by hostname, `i` by the order they were given |
| `m` | Minimise the host windows. macOS animates each one, so this is slow with many windows |
| `h` | Hide the host windows. Instant |
| Ctrl-H | Hide the host windows and minimise the master, to put the whole session away |
| `s` | Type a piece of text into every enabled host: `h` its hostname, `c` its host as you wrote it, `i` its window id, `s` its number in the session |
| `v` | Move the session to other monitors. Type a `--screen` value and press Enter |
| `d` | Save every window's scrollback. Type a base name (under your home folder) or press Enter for `Desktop/csshm_scrollback`. Each host gets `<name>.<host>.txt` |
| `x` | End every session, close every window and exit |

In the prompts that ask for text (`c`, `v`, `d`), Backspace deletes, Ctrl-U
clears the line and Esc cancels. A key the menu does not know makes a beep.

## Choosing which hosts receive your typing

For one host, click its window and type there.

For a group, press Ctrl-A `e` in the master. One window turns blue: that is
the selected one.

| Key | Action |
|---|---|
| Arrow keys or `h` `j` `k` `l` | Move the selection, across monitors too |
| `d` | Disable the selected host. Its text turns grey and it stops receiving your typing |
| `e` | Enable it again |
| `t` | Toggle it |
| `o` | Only this one: disable every other host and go back to typing |
| `O` | Only this one and enlarge its window to fill the monitor. Ctrl-A `r` puts it back |
| Esc or Enter | Go back to typing |

Several hosts can be disabled in one visit: move, `d`, move, `d`, Esc.

To pick out a few hosts, disable those few and then press Ctrl-A `t`, which
flips every host. Ctrl-A `n` enables everything again.

## When a session ends

- If the session ends normally (you typed `exit` or the command finished),
  its window closes and the remaining windows re-tile.
- If ssh itself fails, for example the host cannot be reached or the
  connection drops, the window stays open with grey text so you can read the
  error. Press Enter in that window to close it.
- When the last host window has gone, the master window closes too.
- If you close the master window, the host windows stay open and carry on as
  ordinary, separate sessions.

## Keys and passwords

**One key for every host:** put it in `--ssh_args`.

    csshm --login ubuntu --ssh_args "-i ~/.ssh/key" --addresses servers.txt

**Different keys for some hosts:** add the key file as a last comma field on
those hosts. Hosts without one use `--ssh_args`.

    ubuntu,10.0.0.1,~/.ssh/key-a
    admin@10.0.0.3,~/.ssh/key-b
    ,10.0.0.4,~/.ssh/key-c
    10.0.0.5

A host's own key is offered to the server first, then any key from
`--ssh_args`. Settings in `~/.ssh/config` also apply, as they do for ssh.

**Passwords:** csshm does not store or send passwords and there is no
option to give one. If a host asks for a password, type it in that host's
window. If every host shares one password, type it once in the master window.

**New servers:** the first connection to a server asks you to confirm its
host key in each window. Typing `yes` in the master answers them all or
pass `-o StrictHostKeyChecking=accept-new` in `--ssh_args`.

## Security

csshm types for you on many servers at once, so a few habits matter.

- **Treat a hosts file or settings file like a script.** Text after a host is
  a command that runs on that server as you and the settings file can name
  the program that is run in place of ssh. Only use files you wrote or have read.
- **Be careful typing passwords in the master window.** They go to every
  enabled host. A host that is sitting at a shell prompt instead of a
  password prompt will receive your password as a command and may keep it
  in its history. Disable such hosts first or type the password in each window.
- **Keep host key checking on.** `-o StrictHostKeyChecking=no` lets someone
  on the network pose as your server. `accept-new` trusts a server the first
  time and warns if it later changes.
- **Scrollback files can hold secrets.** The files written by Ctrl-A `d` are
  readable only by you; delete them when you are done.
- **The download is not signed.** The installer and `csshm --update` fetch
  the binary from this repository's releases over HTTPS and trust what they
  get. Each release lists the SHA-256 of its binary so you can compare:
  `shasum -a 256 /usr/local/bin/csshm`. If you prefer, build from source.

What csshm does on its side: it starts ssh directly, never through a shell;
it refuses host names and users containing characters a shell or a terminal
would act on; it keeps its socket and session settings in a folder only you
can open; it never stores a password and it will not run under `sudo`.

To report a security problem, open an issue on GitHub.

## Coming from csshX

Replace `csshx` with `csshm` in your command. `--login`, `--screen`,
`--ssh_args`, `--ssh`, `--remote_command`, `--hosts`, `--tile_x`, `--tile_y`
and `--debug` keep their meaning and the Ctrl-A menu keeps its keys.

What is different:

- The grid is worked out again whenever the number of windows changes and
  windows re-tile by themselves when a session ends. csshX kept the first
  column count and left a hole.
- `--screen 2-4` means monitors 2, 3 and 4 (csshX used 2 and 4 only), lists
  such as `1,3` work and each monitor gets its own grid.
- The session can be moved to other monitors while it runs (Ctrl-A `v`).
- For 3, 7 and 8 windows the automatic grid is wider than csshX's.
- `user,host` and a key per host are accepted and hosts can be piped in.
- The font keys change the host windows only and work through Terminal's
  scripting instead of simulated key presses.
- A failed session stays open, greyed, until you dismiss it.
- Large pastes arrive complete.

What is not carried over:

- Spaces, Growl notifications, split panes, clear scrollback and the bounds mode.
- `.csshrc` and `/etc/clusters`. Settings and clusters now live in
  `~/.config/csshm/config.toml`, in a different format. `--config` names a
  file in that new format.
- Host ranges such as `host[1-5]` and subnets. Your shell's own
  `10.0.0.{1..5}` still works.
- These options are accepted so that old scripts run, but do nothing and
  csshm says so: `--space`, `--ping_test`, `--ping_timeout`, `--session_max`,
  `--sorthosts`, `--interleave`, `--no_growl`, `--sock`.

## Troubleshooting

**"macOS did not allow csshm to control Terminal."** csshm drives Terminal
through automation. Started from Terminal itself, it needs no permission.
Started from another application, such as an editor's built-in terminal,
macOS asks once whether that application may control Terminal. If you
declined, allow it in System Settings > Privacy & Security > Automation.

**"must be run as the logged in user, not with sudo."** The windows belong to
your login session. Run csshm without `sudo`.

**"No such screen [N]."** That monitor number is not attached. Monitor 1 is
the primary display.

**The windows land on the wrong monitor.** The numbers follow macOS's order,
not the layout on your desk. Try another number or press Ctrl-A `v` to move
a running session.

**A host window never appears or "the window did not start".** The window's
shell has to start before csshm can run in it. A shell profile that waits
for input or exits, will prevent that.

**Windows overlap when there are very many.** Terminal has a minimum window
size. With more windows than fit at that size, use more monitors or fewer hosts.

**The master is taller than expected.** Terminal's minimum window height is
used when it is larger than csshm's default.

**Nothing happens when I type.** Check the first line of the master window:
it says how many hosts are enabled. Ctrl-A `n` enables them all. Also check
that the master window, not another application, has the keyboard.

**Shell history.** To start each window, csshm types one command into its
shell. It starts with a space and uses `exec`, which keeps it out of history
in zsh and bash as normally configured.

**Seeing what csshm runs.** `--debug` prints the ssh command in each window
and leaves the windows open afterwards.

## How it works

One binary plays three parts. The launcher reads the command line and opens
the master window. The master opens a window per host, reads your typing and
sends it over a local socket to a small process in each host window. That
process starts ssh and feeds the bytes it receives into its own terminal's
input, so ssh reads them as if typed there.

The socket and the session's settings live in a private directory under your
temporary folder, readable only by you and are removed when the session ends.

## Development

    swift build
    swift test

The code is in two parts. `Sources/CsshmCore` is the logic that does not
touch windows: host parsing, options, monitor selection, the grid, the menu
and the protocol between the windows. `Sources/csshm` is the launcher, the
master, the per-host process and the code that drives Terminal.

The unit tests in `Tests/CsshmCoreTests` cover `CsshmCore`. Please run them
before sending a change.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

Assisted by [Claude](https://claude.com).
