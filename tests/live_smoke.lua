-- Creates disposable sessions, switches the app, then restores the starting
-- session and removes only sessions registered by this test.
-- Run from Rex: rex do ./tests/live_smoke.lua
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/"))
local sesh = dofile(root .. "/lua/rex_sesh.lua")
local function call(method, args) return assert(rex.call(method, args)) end
local function run(argv, opts)
  local result, err = rex.exec(argv, opts)
  assert(result and result.ok, err or (result and result.stderr))
  return result.stdout
end
local original = assert(rex.session_id, "Run with -s SESSION or from a Rex terminal")
local temporary = run({ "mktemp", "-d", "/tmp/rex-sesh-live.XXXXXX" }):gsub("\n$", "")
local picker = sesh.new(rex, { state_home = temporary .. "/state", config = temporary .. "/sesh.toml", client = os.getenv("REX_CLIENT") })
local client = picker:app_client()
local before = {}
for _, session in ipairs(picker:sessions()) do before[session.session_id] = true end
local handles = {}

local ok, err = pcall(function()
  local project = temporary .. "/space ' $() project"
  run({ "mkdir", project })
  local id = picker:connect(project)
  assert(picker:connect(project) == id, "Repeat connect created a duplicate")
  local view = call("session.view", { session_id = id })
  assert(#view.windows == 1, "Expected one shell tab")
  local block = view.windows[1].focused_block_id
  call("session.attach", { session_id = id })
  local process = assert(rex.block.call("com.superlogical.terminal", "process", { session_id = id, block_id = block }))
  -- The shell may still be starting; the registry/reuse assertion is independent.
  if process.foreground and process.foreground.cwd then
    assert(picker:canonical(process.foreground.cwd) == picker:canonical(project), "Wrong working directory")
  end
  print("ok - native Lua creation, quoted directory, session reuse, one shell tab")

  local templated = temporary .. "/templated"
  run({ "mkdir", templated })
  local config = assert(io.open(picker.config, "w"))
  config:write('[[session]]\nname = "⭐ live template"\npath = ' .. assert(rex.json.encode(templated)) ..
    '\nstartup_command = "printf started >> startup-marker"\n')
  config:close()
  local template_id = picker:connect("⭐ live template")
  local marker
  for _ = 1, 50 do
    marker = io.open(templated .. "/startup-marker", "r")
    if marker then break end
    rex.sleep(0.1)
  end
  assert(marker, "Template startup command did not run in its configured directory")
  assert(marker:read("*a") == "started"); marker:close()
  assert(picker:connect("⭐ live template") == template_id)
  rex.sleep(0.2)
  marker = assert(io.open(templated .. "/startup-marker", "r"))
  assert(marker:read("*a") == "started", "Startup command ran again"); marker:close()
  print("ok - live template startup in configured cwd, reuse without rerunning command")

  local concurrent = temporary .. "/parallel project"
  run({ "mkdir", concurrent })
  for _ = 1, 2 do
    handles[#handles + 1] = assert(rex.exec.start({ root .. "/bin/rex-sesh", "--client", client, "connect", concurrent }, {
      env = { XDG_STATE_HOME = temporary .. "/state", REX_SESH_CONFIG = picker.config },
    }))
  end
  local first = assert(handles[1]:wait(20))
  local second = assert(handles[2]:wait(20))
  assert(first.ok, first.stderr)
  assert(second.ok, second.stderr)
  assert(first.stdout == second.stdout, "Concurrent connects created duplicates")
  print("ok - concurrent launcher calls reuse one session")
end)

for _, handle in ipairs(handles) do if handle:running() then handle:kill() end end
local restored, restore_err = pcall(call, "client.perform", { client_id = client, action = "session.select", args = { session_id = original } })
for _, id in pairs(picker:read()) do
  if not before[id] then call("session.destroy", { session_id = id }) end
end
run({ "rm", "-rf", temporary })
if not ok then error(err, 0) end
if not restored then error(restore_err, 0) end
print("Live smoke passed; original session restored and disposable sessions removed")
