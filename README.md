# rex-sesh

A project and session picker for [Rex](https://www.superlogical.com/rex).
Search running sessions, Sesh templates, and zoxide directories. Open a project
or return to its existing session. Built with Rex's embedded Lua runtime.

## Requirements

- A local Rex server with Lua scripting and **Remote Control** enabled.
- [fzf](https://github.com/junegunn/fzf) and [zoxide](https://github.com/ajeetdsouza/zoxide).
- A POSIX shell and `shasum` or `sha256sum`.

On macOS: `brew install fzf zoxide`. Initialize zoxide in your shell.

## Usage

Run from the checkout inside Rex:

```sh
./bin/rex-sesh                          # open the picker
./bin/rex-sesh list                     # list sessions and projects
./bin/rex-sesh connect ~/dev/my-project # create or reuse a session
```

Type to search, Enter to open, Escape to cancel.
Use `--client ID` before the command if multiple Rex apps are connected.

Templates come from `~/.config/sesh/sesh.toml` (or `REX_SESH_CONFIG`).
Supports `[[session]]` with `name`, `path`, and optional `startup_command`;
other Sesh options are unsupported. Startup commands run only on creation.

## Floating picker shortcut

Clone the repository anywhere, then add its absolute path to `~/.config/rex/init.lua`:

```lua
dofile("/absolute/path/to/rex-sesh/rex-config.lua")
```

Replace the example path with your checkout location.
Run `rex config check` and `rex config reload`, then press **Shift-Cmd-K**.

The default native opening mode preserves iPad hardware-keyboard focus.
To retest the faster direct mode: `rex -C CLIENT do -s SESSION project_picker mode=direct`.
Set `REX_SESH_REX` to an absolute Rex CLI path if discovery fails.

## Development

See [AGENTS.md](AGENTS.md) for architecture and validation commands.

## Credits

Inspired by [sesh](https://github.com/joshmedeski/sesh), created by
[Josh Medeski](https://github.com/joshmedeski).
