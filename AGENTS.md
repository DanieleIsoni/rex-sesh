# Working on rex-sesh

## Scope and architecture

rex-sesh is a local project/session picker for Rex. Keep its application logic
in Rex's embedded Lua 5.1 runtime. Do not introduce Python, a standalone Lua
runtime, tmux, or a background service. The shell launcher is a thin adapter.

- `bin/rex-sesh`: POSIX shell launcher; discovers Rex and transports literal CLI
  arguments through environment variables.
- `rex-sesh.lua`: Lua command entry point (`pick`, `list`, `connect`, and internal
  `open`).
- `lua/rex_sesh.lua`: sources, Sesh config parsing, streamed fzf selection,
  directory identity, registry persistence, and session switching.
- `lua/floating_picker.lua`: native client floating-pane opening and launching
  the picker in the newly created terminal.
- `rex-config.lua`: optional Rex action and Shift-Cmd-K binding.
- `tests/test_rex_sesh.lua`: checks using Rex's runtime, mocked APIs, disposable
  filesystem fixtures, and a real fzf streaming check.
- `tests/live_smoke.lua`: optional integration check that creates temporary
  sessions and switches the connected app.

## Implementation conventions

- Use two-space indentation in Lua and preserve the surrounding style.
- Reuse existing helpers and keep responsibilities in the files above.
- Lua 5.1 compatibility matters: avoid syntax and standard-library functions
  introduced in later Lua versions.
- Use `rex.exec` / `rex.exec.start` for processes; `os.execute` and `io.popen`
  are not available. Use argv arrays rather than interpolated shell commands.
- Rex calls return a value and an error. Check failures explicitly. Clean up
  child processes, open input streams, temporary files, and registry locks on
  failure as well as success.
- Keep paths and identifiers separate from display text. Sanitize control
  characters in picker rows and retain stable hidden row indices.
- Quote every argument when writing an `exec` command to the fresh native
  terminal. Never send that command to an existing user terminal.

## Behavior to preserve

- Directory identity is its canonical absolute path. Reopening a directory
  reuses its session, including through symlinks or after a session is renamed.
- Adopt a running session only for a unique exact foreground-directory match.
  Ambiguous matches require explicit session selection.
- Keep the existing JSON directory-to-full-session-ID registry format and its
  host/account scoping. Serialize registry changes with the atomic lock directory
  and replace registry files atomically.
- Call `session.attach` before terminal methods in another session.
- Configured templates remain visible even when their sessions already exist.
  Startup commands run only when creating a session. Missing template paths
  remain visible and are not created automatically.
- The supported Sesh configuration subset is intentional. Unsupported syntax
  must fail clearly instead of silently dropping behavior.
- Start fzf before discovering sources and stream rows in session, template,
  then zoxide order. Preserve cancellation, hidden indices, and source errors.
- Preserve `REX_SESH_REX` and existing CLI/environment options. The GUI server's
  PATH can differ from an interactive shell; keep executable discovery fallbacks.

## iPad keyboard focus

The default `mode=native` opens through the client's `pane.new_floating` action,
then replaces only the new, focused, client-owned shell with the picker. This
preserves iPad hardware-keyboard input focus.

`mode=direct` uses `session.new_layer` with `focus=true`. Keep it available for
retesting Rex fixes, but do not make it the default without device evidence.
Server-reported focus does not establish that the iPad accepts physical keyboard
input. Queuing `client.keyboard.show` alone did not fix the observed issue.

## Validation

Run from the repository root, with Rex and fzf available:

```sh
rex do ./tests/test_rex_sesh.lua
rex config check rex-config.lua --json
sh -n bin/rex-sesh
```

If Rex reports an ambiguous or missing session, inspect `rex ls --json` and pass
an explicit existing session with `rex do -s SESSION ...`. Inherited Rex IDs may
be stale. Check the installed CLI/API documentation rather than guessing methods.

Add focused regression coverage for changed selection, persistence, config, or
process-lifecycle behavior. Avoid tests that only mirror implementation details.
Run the live smoke check only when its temporary sessions and visible app
switching are appropriate; select the intended client when several are connected.
Never close unrelated sessions or send input to the agent's own terminal.

Distinguish automated checks, server layout/capture evidence, and user-confirmed
physical keyboard behavior when reporting results. Do not claim Linux or device
validation from a macOS command-line check.

## Documentation and local configuration

Update `README.md` when changing installation, commands, options, dependencies,
or user-visible behavior. Keep the normal CLI and optional shortcut documented
separately. The repository has no installer or package-manager distribution.

`~/.config/rex/init.lua` belongs to the user, outside this repository. Change it
only when the task authorizes installing or updating the integration, preserve
unrelated actions, then validate and reload it. Do not commit local config files,
session registries, credentials, terminal captures, or temporary test output.
