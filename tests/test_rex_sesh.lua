-- Run with: rex do ./tests/test_rex_sesh.lua
-- Uses Rex's real Lua/JSON/process runtime, with fake session/client APIs.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/tests/"))
local sesh = dofile(root .. "/lua/rex_sesh.lua")
local native = rex
local counts = { passed = 0, failed = 0 }

local function run(argv)
  local result, err = native.exec(argv)
  assert(result and result.ok, err or (result and result.stderr))
  return result.stdout
end
local function equal(actual, expected)
  assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function raises(pattern, fn)
  local ok, err = pcall(fn)
  assert(not ok and tostring(err):find(pattern), "expected error matching " .. pattern .. ", got " .. tostring(err))
end

local function fixture()
  local temporary = run({ "mktemp", "-d", "/tmp/rex-sesh-unit.XXXXXX" }):gsub("\n$", "")
  temporary = run({ "sh", "-c", 'cd "$1" && pwd -P', "test", temporary }):gsub("\n$", "")
  local state = { active = {}, created = {}, selected = {}, paths = {} }
  local runtime = { exec = native.exec, json = native.json, layout = native.layout, sleep = native.sleep, block = {} }
  runtime.call = function(method, args)
    if method == "server.whoami" then return { account = "test", principal = { transport = state.transport or "unix" } } end
    if method == "server.status" then return { host_id = state.host or "test-host" } end
    if method == "session.list" then return { sessions = state.active } end
    if method == "target.resolve" then
      if state.ambiguous then return { results = { { status = "ambiguous" } } } end
      state.client_query = args.queries[1]
      return { results = { { status = "resolved", target = { client_id = "client:test" } } } }
    end
    if method == "session.create" then
      state.created[#state.created + 1] = args
      local id = "session:" .. #state.created
      state.active[#state.active + 1] = { session_id = id, label = args.label }
      return { session_id = id }
    end
    if method == "client.perform" then
      if state.fail_select then return nil, "Remote Control disabled" end
      state.selected[#state.selected + 1] = args
      return { performed_by = args.client_id }
    end
    error("Unexpected API call: " .. method)
  end
  local picker = sesh.new(runtime, { state_home = temporary, config = temporary .. "/sesh.toml" })
  picker.paths = function(_, session) return state.paths[session.session_id] or {} end
  state.project = temporary .. "/space ' $() project"
  run({ "mkdir", state.project })
  return { picker = picker, state = state, runtime = runtime, root = temporary }
end

local function test(name, fn)
  local f = fixture()
  local ok, err = pcall(fn, f.picker, f.state, f)
  run({ "rm", "-rf", f.root })
  if ok then counts.passed = counts.passed + 1; print("ok - " .. name)
  else counts.failed = counts.failed + 1; print("FAIL - " .. name .. ": " .. tostring(err)) end
end

test("create once and reuse after cd or rename", function(p, s)
  local first = p:connect(s.project)
  s.active[1].label = "renamed"
  equal(p:connect(s.project), first)
  equal(#s.created, 1)
  equal(s.created[1].initial_windows[1].layout.block.options.cwd, s.project)
end)
test("symlinks reuse canonical directory", function(p, s, f)
  run({ "ln", "-s", s.project, f.root .. "/alias" })
  equal(p:connect(f.root .. "/alias"), p:connect(s.project))
  equal(#s.created, 1)
end)
test("adopt existing session by cwd rather than name", function(p, s)
  s.active = { { session_id = "session:old", label = "different" } }
  s.paths["session:old"] = { [s.project] = true }
  equal(p:connect(s.project), "session:old")
  equal(#s.created, 0)
end)
test("distinct labels for same basename", function(p, s, f)
  local other = f.root .. "/other/space ' $() project"
  run({ "mkdir", "-p", other })
  assert(p:connect(s.project) ~= p:connect(other))
  assert(s.created[1].label ~= s.created[2].label)
end)
test("leading dash and Unicode directory names", function(p, s, f)
  local path = f.root .. "/--é中文"
  run({ "mkdir", path })
  p:connect(path)
  equal(s.created[1].label, "project--é中文")
end)
test("failed selection preserves registry and releases lock", function(p, s)
  s.fail_select = true
  raises("Remote Control", function() p:connect(s.project) end)
  s.fail_select = false
  equal(p:connect(s.project), "session:1")
  equal(#s.created, 1)
end)
test("closed sessions are recreated", function(p, s)
  p:connect(s.project)
  s.active = {}
  equal(p:connect(s.project), "session:2")
end)
test("ambiguous directory does not create", function(p, s)
  s.active = { { session_id = "session:a" }, { session_id = "session:b" } }
  s.paths = { ["session:a"] = { [s.project] = true }, ["session:b"] = { [s.project] = true } }
  raises("Multiple sessions", function() p:connect(s.project) end)
  equal(#s.created, 0)
end)
test("missing path and ambiguous client do not create", function(p, s, f)
  raises("Not a directory", function() p:connect(f.root .. "/missing") end)
  s.ambiguous = true
  raises("Choose one", function() p:connect(s.project) end)
  equal(#s.created, 0)
end)
test("direct ID requires a live session", function(p, s)
  s.active = { { session_id = "session:old" } }
  equal(p:connect("session:old"), "session:old")
  raises("no longer exists", function() p:connect("session:closed") end)
  equal(s.selected[1].client_id, "client:test")
  equal(s.selected[1].args.session_id, "session:old")
end)
test("mapped project is merged into session entry", function(p, s, f)
  p:connect(s.project)
  p.projects = function() return { s.project, f.root } end
  local entries = p:entries()
  equal(#entries, 2)
  equal(entries[1].path, s.project)
  equal(entries[2].kind, "directory")
end)
test("original JSON registry is reused", function(p, s)
  s.active = { { session_id = "session:legacy" } }
  run({ "mkdir", "-p", p.directory })
  local file = assert(io.open(p.registry, "w"))
  file:write(assert(native.json.encode({ [s.project] = "session:legacy" })))
  file:close()
  equal(p:connect(s.project), "session:legacy")
  equal(#s.created, 0)
end)
test("corrupt registries fail before creating", function(p, s)
  run({ "mkdir", "-p", p.directory })
  for _, content in ipairs({ "[]", "{", '{"path":4}', '{"path":null}' }) do
    local file = assert(io.open(p.registry, "w")); file:write(content); file:close()
    raises("Cannot read session registry", function() p:connect(s.project) end)
  end
  equal(#s.created, 0)
end)
test("registry stays scoped per server", function(p, s, f)
  s.host = "different-host"
  assert(sesh.new(f.runtime, { state_home = f.root }).registry ~= p.registry)
end)
test("remote servers rejected", function(_, s, f)
  s.transport = "tailscale"
  raises("Only local", function() sesh.new(f.runtime, { state_home = f.root }) end)
end)
test("picker selection uses hidden index and sanitizes labels", function(p, _, f)
  local entries = { { kind = "session", label = "same\n\27", path = "", target = "session:1" },
    { kind = "directory", label = "same", path = "/a path", target = "/a path" } }
  f.runtime.exec = function(argv, opts)
    equal(argv[1], "fzf")
    assert(not opts.stdin:find("\27", 1, true))
    assert(not opts.stdin:find("\n", 1, true))
    equal(opts.env.FZF_DEFAULT_OPTS, "")
    equal(opts.timeout, nil)
    return { ok = true, code = 0, stdout = "2\tdirectory same\0", stderr = "" }
  end
  equal(p:pick(entries, "a path"), entries[2])
  for _, code in ipairs({ 1, 130 }) do
    f.runtime.exec = function() return { code = code } end
    equal(p:pick(entries, ""), nil)
  end
end)
test("invalid picker selection and picker failure reported", function(p, _, f)
  local entries = { { kind = "session", label = "a", path = "", target = "session:a" } }
  f.runtime.exec = function() return { ok = true, code = 0, stdout = "0\tbad", stderr = "" } end
  raises("invalid selection", function() p:pick(entries, "") end)
  f.runtime.exec = function() return { ok = false, code = 2, stderr = "fzf failure" } end
  raises("fzf failure", function() p:pick(entries, "") end)
end)
test("optional zoxide and installed zoxide failure", function(p, _, f)
  f.runtime.exec = function() return nil, 'exec: "zoxide": executable file not found in $PATH' end
  equal(#p:projects(), 0)
  f.runtime.exec = function() return { ok = false, stderr = "database error" } end
  raises("database error", function() p:projects() end)
end)
test("zoxide ignores vanished directories and duplicate symlinks", function(p, s, f)
  run({ "ln", "-s", s.project, f.root .. "/alias" })
  f.runtime.exec = function(argv, opts)
    if argv[1] == "zoxide" then
      return { ok = true, stdout = s.project .. "\n" .. f.root .. "/alias\n" .. f.root .. "/gone\n" }
    end
    return native.exec(argv, opts)
  end
  local paths = p:projects()
  equal(#paths, 1)
  equal(paths[1], s.project)
end)

test("terminal directory lookup attaches before block methods", function(p, s, f)
  local attached = {}
  f.runtime.call = function(method, args)
    if method == "session.attach" then attached[args.session_id] = true; return {} end
    if method == "session.list_blocks" then
      return { blocks = { { block_id = "block:test", creator_name = "com.superlogical.terminal" } } }
    end
    error(method)
  end
  f.runtime.block.call = function(creator, method, args)
    assert(attached[args.session_id])
    equal(creator, "com.superlogical.terminal")
    equal(method, "process")
    return { foreground = { cwd = s.project } }
  end
  local actual = getmetatable(p).paths(p, { session_id = "session:test" })
  assert(actual[s.project])
end)

local function config(f, content)
  local file = assert(io.open(f.picker.config, "w")); file:write(content); file:close()
end

test("Sesh templates preserve names and start commands only on creation", function(p, s, f)
  config(f, '[[session]]\nname = "📥 downloads"\npath = ' .. assert(native.json.encode(s.project)) .. '\nstartup_command = "nvim"\n')
  p:connect("📥 downloads")
  equal(s.created[1].label, "📥 downloads")
  local options = s.created[1].initial_windows[1].layout.block.options
  equal(options.cwd, s.project)
  equal(options.command[2], "-lic")
  equal(options.command[3], 'nvim\nexec "$SHELL" -l')
  p:connect(s.project)
  equal(#s.created, 1)
end)
test("templates precede directories and stay visible after opening or renaming", function(p, s, f)
  config(f, '[[session]]\nname = "project"\npath = ' .. assert(native.json.encode(s.project)) .. '\n')
  p.projects = function() return { s.project, f.root } end
  local entries = p:entries()
  equal(#entries, 2); equal(entries[1].kind, "template"); equal(entries[2].kind, "directory")
  p:connect("project")
  s.active[1].label = "renamed"
  entries = p:entries()
  equal(#entries, 3); equal(entries[1].kind, "session")
  equal(entries[1].label, "renamed")
  equal(entries[2].kind, "template"); equal(entries[2].label, "project")
  equal(entries[3].kind, "directory")
  equal(p:connect(entries[2].target), "session:1"); equal(#s.created, 1)
  equal(s.created[1].initial_windows[1].layout.block.options.command, nil)
end)
test("opening an existing template directory does not rerun startup", function(p, s, f)
  config(f, '[[session]]\nname = "project"\npath = ' .. assert(native.json.encode(s.project)) .. '\nstartup_command = "nvim"\n')
  s.active = { { session_id = "session:old", label = "existing" } }
  s.paths["session:old"] = { [s.project] = true }
  equal(p:connect("project"), "session:old"); equal(#s.created, 0)
end)
test("Sesh parser supports comments literal strings and escaped quotes", function()
  local entries = sesh.parse_config([=[# comment
[[session]] # template
name = '📁 home # literal'
path = "~" # comment
startup_command = "echo \"hi\""
]=], native.json)
  equal(entries[1].name, "📁 home # literal")
  equal(entries[1].startup_command, 'echo "hi"')
end)
test("unsupported malformed and duplicate Sesh config fails clearly", function(p, s, f)
  for _, content in ipairs({ '[default_session]\nstartup_command = "nvim"',
    '[[session]]\nname = "a"', '[[session]]\nname = "a"\nname = "b"',
    '[[session]]\nname = "a" junk', '[[session]]\nwindows = []' }) do
    local ok = pcall(sesh.parse_config, content, native.json); equal(ok, false)
  end
  local entry = '[[session]]\nname = "a"\npath = ' .. assert(native.json.encode(s.project)) .. '\n'
  config(f, entry .. entry:gsub('name = "a"', 'name = "b"'))
  raises("Multiple Sesh templates", function() p:connect(s.project) end)
  equal(#s.created, 0)
end)
test("missing template paths do not block the picker", function(p, s, f)
  config(f, '[[session]]\nname = "missing"\npath = ' .. assert(native.json.encode(f.root .. "/gone/")) .. '\n')
  p.projects = function() return { s.project } end
  local entries = p:entries()
  equal(#entries, 2); equal(entries[1].label, "missing (missing)")
  raises("Not a directory", function() p:connect("missing") end)
  equal(#s.created, 0)
end)
test("row icons and home abbreviation distinguish sources", function(p)
  equal(p:short_path(p.home .. "/dev"), "~/dev")
  equal(p:short_path(p.home .. "other"), p.home .. "other")
  for kind, icon in pairs({ session = "🖥️", directory = "📁", template = "⭐" }) do
    assert(sesh.row({ kind = kind, label = "a", path = "/tmp", target = "/tmp" }):find(icon, 1, true))
  end
end)

test("streaming picker starts before loading and preserves row identity", function(p, _, f)
  local started, closed, rows = false, false, {}
  local entry = { kind = "directory", label = "first", path = "/first", target = "/first" }
  f.runtime.exec = { start = function(argv, opts)
    equal(argv[1], "fzf"); equal(opts.stdin, true)
    equal(opts.env.FZF_DEFAULT_OPTS, "")
    started = true
    return {
      write = function(_, data) rows[#rows + 1] = data; return true end,
      close_stdin = function() closed = true end,
      wait = function()
        assert(closed); equal(#rows, 2)
        assert(rows[1]:match("^1\t")); assert(rows[2]:match("^2\t"))
        return { ok = true, code = 0, stdout = "1\tfirst\0" }
      end,
    }
  end }
  equal(p:pick(function(emit)
    assert(started)
    emit(entry)
    equal(#rows, 1)
    emit({ kind = "directory", label = "second", path = "/second", target = "/second" })
  end, ""), entry)
end)

test("streaming cancellation tolerates closed input and loading errors stop fzf", function(p, _, f)
  local state = { killed = false, waited = false }
  f.runtime.exec = { start = function()
    return {
      write = function() return nil, "broken pipe" end,
      close_stdin = function() end,
      kill = function() state.killed = true end,
      wait = function() state.waited = true; return { code = 130 } end,
    }
  end }
  equal(p:pick(function(emit)
    emit({ kind = "directory", label = "a", path = "/a", target = "/a" })
  end), nil)
  assert(not state.killed and state.waited)
  state.waited = false
  raises("source failed", function()
    p:pick(function() error("source failed") end)
  end)
  assert(state.killed and state.waited)
end)

test("session rows arrive before directory discovery completes", function(p, s)
  s.active = { { session_id = "session:a", label = "live" } }
  local emitted = {}
  p.projects = function()
    equal(#emitted, 1); equal(emitted[1].kind, "session")
    return { s.project }
  end
  local entries = p:entries(function(entry) emitted[#emitted + 1] = entry end)
  equal(#entries, 2); equal(entries[2], emitted[2])
end)

test("real fzf consumes streamed NUL-delimited rows", function(p, _, f)
  f.runtime.exec = { start = function(argv, opts)
    argv[#argv + 1] = "--filter=stream-entry"
    return native.exec.start(argv, opts)
  end }
  local entry = { kind = "directory", label = "stream-entry", path = "/stream", target = "/stream" }
  equal(p:pick(function(emit) emit(entry) end), entry)
end)

print(string.format("%d passed; %d failed", counts.passed, counts.failed))
if counts.failed > 0 then native.stop(1) end
