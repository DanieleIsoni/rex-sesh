-- Lua 5.1 compatible. Rex is the only Lua runtime required.
local M = {}
local Picker = {}
Picker.__index = Picker

local function checked(value, err)
  if err ~= nil or value == nil then error(tostring(err or "Rex returned no result"), 0) end
  return value
end

local function display(value)
  return (value:gsub("[%z\1-\31\127]", "?"):gsub("\194[\128-\159]", "?"))
end

function M.row(entry)
  local icons = { session = "🖥️", template = "⭐", directory = "📁" }
  return string.format("%s  %s  ·  %s", icons[entry.kind] or "", display(entry.label), display(entry.display_path or (entry.path ~= "" and entry.path or entry.target)))
end

function Picker:exec(argv, opts)
  local result, err = self.rex.exec(argv, opts or { timeout = 30 })
  return checked(result, err)
end

function Picker:run(argv, opts)
  local result = self:exec(argv, opts)
  if not result.ok then
    if result.timed_out then
      error(argv[1] .. " timed out. Inspect Rex before retrying; creation may have succeeded.", 0)
    end
    error(result.stderr ~= "" and result.stderr or (argv[1] .. " exited with status " .. result.code), 0)
  end
  return result.stdout
end

function Picker:call(method, args)
  return checked(self.rex.call(method, args or {}))
end

function Picker:canonical(path, optional)
  if path:find("[%z\r\n]") then error("Directory names containing NUL or newlines are unsupported", 0) end
  if path == "~" then path = self.home
  elseif path:sub(1, 2) == "~/" then path = self.home .. path:sub(2) end
  -- Static shell program; the directory is an argument, never shell code.
  local result = self:exec({ "sh", "-c", 'CDPATH= cd -P -- "$1" && pwd -P', "rex-sesh", path })
  if not result.ok then
    if optional then return nil end
    error("Not a directory: " .. path, 0)
  end
  return (result.stdout:gsub("\n$", ""))
end

function Picker:digest(text)
  for _, argv in ipairs({ { "shasum", "-a", "256" }, { "sha256sum" } }) do
    local result = self.rex.exec(argv, { stdin = text, timeout = 10 })
    if result and result.ok then
      local hash = result.stdout:match("^(%x+)")
      if hash and #hash == 64 then return hash end
    end
  end
  error("A system SHA-256 utility is required (shasum on macOS, sha256sum on Linux)", 0)
end

function M.new(runtime, opts)
  opts = opts or {}
  local self = setmetatable({ rex = runtime, client = opts.client }, Picker)
  self.home = assert(os.getenv("HOME"), "HOME is not set")
  self.config = opts.config or os.getenv("REX_SESH_CONFIG") or
    ((os.getenv("XDG_CONFIG_HOME") or (self.home .. "/.config")) .. "/sesh/sesh.toml")
  local identity = self:call("server.whoami")
  if (identity.principal or {}).transport ~= "unix" then
    error("Only local Unix-socket servers are supported; unset REX_SERVER for local projects", 0)
  end
  local status = self:call("server.status")
  local base = opts.state_home or os.getenv("XDG_STATE_HOME") or (self.home .. "/.local/state")
  self.directory = base .. "/rex-sesh"
  -- Same filename and JSON format as the original implementation.
  self.registry = self.directory .. "/" .. self:digest(status.host_id .. ":" .. identity.account) .. ".json"
  return self
end

function Picker:read()
  local file, err, code = io.open(self.registry, "r")
  if not file then
    -- Rex's Lua 5.1 io.open omits the numeric errno returned by newer Lua.
    if code == 2 or tostring(err):match(": [Nn]o such file or directory$") then return {} end
    error("Cannot read session registry " .. self.registry .. ": " .. tostring(err), 0)
  end
  local text = file:read("*a")
  file:close()
  local data, decode_err = self.rex.json.decode(text)
  -- Empty JSON arrays also decode to empty Lua tables; check the JSON root.
  if not text:match("^%s*{") or type(data) ~= "table" then
    error("Cannot read session registry " .. self.registry .. ": " .. tostring(decode_err or "expected an object"), 0)
  end
  -- Rex drops JSON null fields while decoding. Validate value tokens as well,
  -- so a corrupt null-valued mapping cannot silently turn into an empty table.
  local quoted, escaped, value = false, false, false
  for index = 1, #text do
    local char = text:sub(index, index)
    if quoted then
      if escaped then escaped = false
      elseif char == "\\" then escaped = true
      elseif char == '"' then quoted = false end
    elseif value and not char:match("%s") then
      if char ~= '"' then error("Cannot read session registry " .. self.registry .. ": expected string values", 0) end
      quoted, value = true, false
    elseif char == '"' then quoted = true
    elseif char == ":" then value = true end
  end
  for path, id in pairs(data) do
    if type(path) ~= "string" or type(id) ~= "string" then
      error("Cannot read session registry " .. self.registry .. ": expected directory-to-session strings", 0)
    end
  end
  return data
end

function Picker:write(data)
  -- Called under the lock; rename prevents readers seeing a partial registry.
  local temporary = self.registry .. ".tmp"
  local file = checked(io.open(temporary, "w"))
  local ok, err = file:write(checked(self.rex.json.encode(data)))
  local closed, close_err = file:close()
  if not ok or not closed then
    os.remove(temporary)
    error(tostring(err or close_err), 0)
  end
  local renamed, rename_err = os.rename(temporary, self.registry)
  if not renamed then os.remove(temporary); error(rename_err, 0) end
end

function Picker:locked(callback)
  self:run({ "mkdir", "-p", "-m", "700", self.directory })
  local lock = self.registry .. ".lockdir"
  local acquired = false
  for _ = 1, 50 do
    if self:exec({ "mkdir", "-m", "700", lock }).ok then acquired = true; break end
    self.rex.sleep(0.1)
  end
  if not acquired then
    error("Session registry is busy. If no rex-sesh connect process is running, remove the stale lock directory: " .. lock, 0)
  end
  local ok, result = pcall(callback)
  local removed, remove_err = os.remove(lock)
  if not ok then error(result, 0) end
  if not removed then error("Cannot release registry lock: " .. tostring(remove_err), 0) end
  return result
end

function Picker:sessions()
  return self:call("session.list").sessions or {}
end

function Picker:app_client()
  local result = (self:call("target.resolve", { kinds = { "client" }, queries = { self.client or "" } }).results or {})[1]
  if not result or result.status ~= "resolved" then
    error("Choose one connected Rex app with --client ID (see rex client ls)", 0)
  end
  return result.target.client_id
end

function Picker:paths(session)
  local paths = {}
  -- Terminal methods require this Lua connection to attach to their session.
  self:call("session.attach", { session_id = session.session_id })
  local blocks = self:call("session.list_blocks", { session_id = session.session_id }).blocks or {}
  for _, block in ipairs(blocks) do
    if block.creator_name == "com.superlogical.terminal" then
      local process = checked(self.rex.block.call("com.superlogical.terminal", "process", {
        session_id = session.session_id, block_id = block.block_id,
      }))
      local cwd = (process.foreground or {}).cwd
      if cwd then
        local path = self:canonical(cwd, true)
        if path then paths[path] = true end
      end
    end
  end
  return paths
end

function Picker:projects()
  local result, err = self.rex.exec({ "zoxide", "query", "--list" }, { timeout = 10 })
  if not result then
    if tostring(err):find("not found", 1, true) or tostring(err):find("no such file", 1, true) then return {} end
    error(err, 0)
  end
  if not result.ok then error(result.stderr, 0) end
  local paths, seen = {}, {}
  for line in result.stdout:gmatch("[^\n]+") do
    local path = self:canonical(line, true)
    if path and not seen[path] then paths[#paths + 1] = path; seen[path] = true end
  end
  return paths
end

-- Intentionally limited to the single-line string fields used by our Sesh config.
-- Unknown sections/keys fail explicitly instead of silently dropping behavior.
function M.parse_config(text, json)
  local sessions, current = {}, nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    if not line:match("^%s*$") and not line:match("^%s*#") then
      if line:match("^%s*%[%[session%]%]%s*$") or line:match("^%s*%[%[session%]%]%s*#") then
        current = {}; sessions[#sessions + 1] = current
      else
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if not current or (key ~= "name" and key ~= "path" and key ~= "startup_command") then
          error("Unsupported Sesh configuration: " .. line, 0)
        end
        if current[key] ~= nil then error("Duplicate Sesh field: " .. key, 0) end
        local quote = value:sub(1, 1)
        local finish, escaped
        for index = 2, #value do
          local char = value:sub(index, index)
          if escaped then escaped = false
          elseif quote == '"' and char == "\\" then escaped = true
          elseif char == quote then finish = index; break end
        end
        if (quote ~= '"' and quote ~= "'") or not finish or
          (value:sub(finish + 1):match("%S") and not value:sub(finish + 1):match("^%s*#")) then
          error("Expected a single-line Sesh string: " .. key, 0)
        end
        if quote == "'" then current[key] = value:sub(2, finish - 1)
        else
          local decoded, err = json.decode(value:sub(1, finish))
          if type(decoded) ~= "string" then error("Invalid Sesh string: " .. tostring(err), 0) end
          current[key] = decoded
        end
      end
    end
  end
  local names = {}
  for _, session in ipairs(sessions) do
    if not session.name or session.name == "" or not session.path or session.path == "" then
      error("Each Sesh session requires a name and path", 0)
    end
    if names[session.name] then error("Duplicate Sesh session name: " .. session.name, 0) end
    names[session.name] = true
  end
  return sessions
end

function Picker:templates()
  local file, err = io.open(self.config, "r")
  if not file then
    if tostring(err):match(": [Nn]o such file or directory$") then return {} end
    error("Cannot read Sesh config: " .. tostring(err), 0)
  end
  local text = file:read("*a"); file:close()
  local templates = M.parse_config(text, self.rex.json)
  local paths = {}
  for _, template in ipairs(templates) do
    local resolved = self:canonical(template.path, true)
    template.missing = resolved == nil
    if not resolved then
      local path = template.path
      if path == "~" then path = self.home
      elseif path:sub(1, 2) == "~/" then path = self.home .. path:sub(2) end
      if path:sub(1, 1) ~= "/" then error("Sesh template paths must be absolute or start with ~/: " .. path, 0) end
      resolved = path:gsub("/+$", "")
      if resolved == "" then resolved = "/" end
    end
    template.path = resolved
    if paths[template.path] then error("Multiple Sesh templates for directory: " .. template.path, 0) end
    paths[template.path] = true
  end
  return templates
end

function Picker:short_path(path)
  if path == self.home then return "~" end
  if path:sub(1, #self.home + 1) == self.home .. "/" then return "~" .. path:sub(#self.home + 1) end
  return path
end

function Picker:entries(on_entry)
  local sessions, known = self:sessions(), self:read()
  local live, paths, entries = {}, {}, {}
  local function append(entry)
    entry.display_path = self:short_path(entry.path ~= "" and entry.path or entry.target)
    entries[#entries + 1] = entry
    if on_entry then on_entry(entry) end
  end
  for _, session in ipairs(sessions) do live[session.session_id] = true end
  for path, id in pairs(known) do if live[id] then paths[id] = path end end
  for _, session in ipairs(sessions) do
    append({
      kind = "session", label = session.label or session.session_id,
      target = session.session_id, path = paths[session.session_id] or "",
    })
  end
  local configured = {}
  for _, template in ipairs(self:templates()) do
    configured[template.path] = true
    append({ kind = "template", label = template.name .. (template.missing and " (missing)" or ""), target = template.path, path = template.path })
  end
  for _, path in ipairs(self:projects()) do
    if not live[known[path]] and not configured[path] then
      append({ kind = "directory", label = path:match("([^/]+)$") or path, target = path, path = path })
    end
  end
  return entries
end

function Picker:pick(entries, query)
  local argv = { "fzf", "--read0", "--print0", "--delimiter=\t", "--with-nth=2..",
    "--no-multi", "--layout=reverse", "--border=rounded", "--info=inline", "--prompt=Search › ",
    "--header=🖥️ Sessions   ⭐ Templates   📁 Directories · Enter: open · Esc: cancel", "--query", query or "" }
  local opts = { env = { FZF_DEFAULT_OPTS = "", FZF_DEFAULT_OPTS_FILE = "" } }
  local result
  if type(entries) == "function" then
    local load = entries
    entries = {}
    opts.stdin = true
    local process = checked(self.rex.exec.start(argv, opts))
    local write_error
    local ok, err = pcall(function()
      load(function(entry)
        entries[#entries + 1] = entry
        if not write_error then
          local written, why = process:write(#entries .. "\t" .. M.row(entry) .. "\0")
          if not written then write_error = why or "Cannot send rows to fzf" end
        end
      end)
      if #entries == 0 then error("No sessions or zoxide directories. Try rex-sesh connect PATH", 0) end
    end)
    process:close_stdin()
    if not ok then
      process:kill()
      process:wait()
      error(err, 0)
    end
    result = checked(process:wait())
    -- A broken pipe is expected if the user cancels while rows are loading.
  else
    if #entries == 0 then error("No sessions or zoxide directories. Try rex-sesh connect PATH", 0) end
    local rows = {}
    for index, entry in ipairs(entries) do rows[#rows + 1] = index .. "\t" .. M.row(entry) end
    opts.stdin = table.concat(rows, "\0") .. "\0"
    result = self:exec(argv, opts)
  end
  if result.code == 1 or result.code == 130 then return nil end
  if not result.ok then error(result.stderr ~= "" and result.stderr or "fzf failed", 0) end
  local index = tonumber(result.stdout:match("^(%d+)\t"))
  if not index or not entries[index] then error("fzf returned an invalid selection", 0) end
  return entries[index]
end

local function basename(path)
  local name = path:match("([^/]+)$") or "root"
  local chars = {}
  for char in name:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    chars[#chars + 1] = char
    if #chars == 96 then break end
  end
  name = table.concat(chars)
  if name:sub(1, 1) == "-" then name = "project" .. name end
  return name
end

function Picker:connect(target)
  local client = self:app_client()
  local id = self:locked(function()
    local sessions, live = self:sessions(), {}
    for _, session in ipairs(sessions) do live[session.session_id] = true end
    if target:sub(1, 8) == "session:" then
      if not live[target] then error("Session no longer exists: " .. target, 0) end
      return target
    end
    local templates, template = self:templates(), nil
    for _, candidate in ipairs(templates) do
      if target == candidate.name then template = candidate; target = candidate.path; break end
    end
    local path, known = self:canonical(target), self:read()
    for _, candidate in ipairs(templates) do if candidate.path == path then template = candidate end end
    for directory, sid in pairs(known) do if not live[sid] then known[directory] = nil end end
    local session_id = known[path]
    if not session_id then
      for _, session in ipairs(sessions) do
        if self:paths(session)[path] then
          if session_id then error("Multiple sessions are in this directory. Select the session directly", 0) end
          session_id = session.session_id
        end
      end
      if not session_id then
        local label = template and template.name or basename(path)
        local options = { cwd = path }
        if template and template.startup_command and template.startup_command ~= "" then
          -- The command is explicitly configured shell code. A login interactive
          -- shell loads aliases/functions (such as y); return to a shell afterward.
          local shell = os.getenv("SHELL") or "/bin/sh"
          options.command = { shell, "-lic", template.startup_command .. '\nexec "$SHELL" -l' }
        end
        for _, session in ipairs(sessions) do
          if (session.label or ""):lower() == label:lower() then
            label = label .. "-" .. self:digest(path):sub(1, 8)
            break
          end
        end
        session_id = self:call("session.create", {
          label = label,
          initial_windows = { {
            window_label = "Terminal",
            layout = self.rex.layout.block{ flavor = "com.superlogical.terminal.shell", options = options },
          } },
        }).session_id
      end
      known[path] = session_id
      self:write(known)
    end
    return session_id
  end)
  local _, err = self.rex.call("client.perform", {
    client_id = client, action = "session.select", args = { session_id = id }, origin = "cli",
  })
  if err then
    error("Session " .. id .. " is available, but switching failed: " .. err ..
      "\nEnable Remote Control in Rex Settings > Server. Retry to reuse the session", 0)
  end
  return id
end

return M
