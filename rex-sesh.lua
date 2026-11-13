-- Entry point: Rex supplies the Lua runtime, JSON codec, and process API.
local source = debug.getinfo(1, "S").source:gsub("^@", "")
local root = assert(source:match("^(.*)/"), "Run this script by path")
local sesh = dofile(root .. "/lua/rex_sesh.lua")
local args = rex.args or {}
local function option(name, environment, default)
  local value = os.getenv(environment)
  if value ~= nil then return value end
  if args[name] ~= nil then return args[name] end
  return default
end

local ok, err = pcall(function()
  local command = option("command", "REX_SESH_COMMAND", "pick")
  if command == "open" then
    local floating = dofile(root .. "/lua/floating_picker.lua")
    return floating.open(rex, {
      session = rex.session_id,
      client = assert(args.client, "Opening a floating picker requires a client"),
      executable = args.executable or "rex",
      picker = source,
    })
  end
  local picker = sesh.new(rex, {
    client = option("client", "REX_SESH_CLIENT", os.getenv("REX_CLIENT")),
  })
  if command == "connect" then
    local target = option("target", "REX_SESH_TARGET")
    assert(target ~= nil and tostring(target) ~= "", "connect requires target=PATH_OR_SESSION_ID")
    print(picker:connect(tostring(target)))
  elseif command == "list" then
    local entries = picker:entries()
    local json = option("json", "REX_SESH_JSON", false)
    if json == true or json == "true" then
      if #entries == 0 then print("[]")
      else print(assert(rex.json.encode(entries, { indent = true }))) end
    else
      for _, entry in ipairs(entries) do print(sesh.row(entry)) end
    end
  elseif command == "pick" then
    local entry = picker:pick(function(emit) picker:entries(emit) end,
      tostring(option("query", "REX_SESH_QUERY", "")))
    if entry then picker:connect(entry.target) end
  else
    error("Unknown command: " .. tostring(command), 0)
  end
end)
if not ok then
  io.stderr:write("rex-sesh: " .. tostring(err) .. "\n")
  rex.stop(1)
end
