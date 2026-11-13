-- Load this file by absolute path from ~/.config/rex/init.lua.
-- The picker opens in a centered floating pane, which closes when it exits.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/"), "Load rex-config.lua by path")
local picker = root .. "/rex-sesh.lua"
local function rex_executable()
  local override = os.getenv("REX_SESH_REX")
  if override and override ~= "" then return override end
  -- The GUI server does not necessarily inherit the terminal's PATH.
  local result, err = rex.exec({ "/bin/sh", "-c", [[
    command -v rex && exit 0
    for app in '/Applications/Rex Beta.app' '/Applications/Rex.app'; do
      candidate="$app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
      if [ -x "$candidate" ]; then printf '%s\n' "$candidate"; exit 0; fi
    done
    exit 1
  ]] })
  if not result or not result.ok then
    error(err or "Rex CLI not found. Set REX_SESH_REX to its absolute path", 0)
  end
  return (result.stdout:gsub("\n$", ""))
end

rex.action{
  name = "project_picker",
  title = "Open Project or Session…",
  description = "Search running sessions and zoxide directories",
  args = { mode = "string?" },
  run = function(ctx, args)
    local mode = args.mode or "native"
    if mode ~= "native" and mode ~= "direct" then
      error("mode must be native or direct", 0)
    end
    local executable = rex_executable()
    if mode == "direct" then
      local command = { executable, "--autostart=false", "do", picker }
      if ctx.client_id then command[#command + 1] = "client=" .. ctx.client_id end
      local result, err = rex.session.new_layer{
        bounds = { 0.1, 0.15, 0.8, 0.7 },
        focus = true,
        layout = rex.layout.block{
          flavor = "com.superlogical.terminal.shell",
          label = "Projects",
          options = { command = command },
        },
      }
      if err ~= nil then error(err, 0) end
      return result
    end
    local command = { executable, "--autostart=false", "do", "-s", ctx.session_id,
      picker, "command=open", "executable=" .. executable }
    if ctx.client_id then
      command[#command + 1] = "client=" .. ctx.client_id
    end
    -- Run after this action returns so the app can handle its native action.
    local result, err = rex.exec.start(command, { detach = true })
    if err ~= nil then error(err, 0) end
  end,
}

rex.bind("shift+cmd+k", "project_picker")
