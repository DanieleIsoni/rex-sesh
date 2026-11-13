local M = {}

local function quote(value)
  assert(not value:find("[%z\r\n]"), "Command arguments cannot contain NUL or newlines")
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

function M.open(rex, opts)
  local function call(method, args)
    local result, err = rex.call(method, args)
    assert(result, err)
    return result
  end
  local function view()
    return call("session.view", { session_id = opts.session })
  end
  local before, existing = view(), {}
  for _, window in ipairs(before.windows) do
    for _, layer in ipairs(window.layers) do existing[layer.layer_id] = true end
  end

  -- The native client action also activates iPad hardware-keyboard input.
  call("client.perform", {
    client_id = opts.client, session_id = opts.session,
    action = "pane.new_floating", origin = "cli",
  })
  local candidate
  for _, window in ipairs(view().windows) do
    for _, layer in ipairs(window.layers) do
      if not existing[layer.layer_id] and layer.kind == "floating" then
        assert(not candidate, "Multiple floating panes opened; refusing to send a command")
        assert(#layer.blocks == 1, "Expected one terminal in the new floating pane")
        local block = layer.blocks[1]
        assert(block.creator_name == "com.superlogical.terminal" and
          block.block_id == window.focused_block_id and block.owner == opts.client,
          "The new floating terminal is not focused or owned by the requesting app")
        candidate = { layer = layer.layer_id, block = block.block_id }
      end
    end
  end
  assert(candidate, "The app did not open a floating pane in this session")
  call("session.resize_layer", {
    session_id = opts.session, layer_id = candidate.layer,
    bounds = { 0.1, 0.15, 0.8, 0.7 },
  })
  call("session.set_block_label", {
    session_id = opts.session, block_id = candidate.block, label = "Projects",
  })
  local command = { opts.executable, "--autostart=false", "do", opts.picker,
    "client=" .. opts.client }
  for index, argument in ipairs(command) do command[index] = quote(argument) end
  -- Replace only the fresh native shell, so Escape also closes its pane.
  call("com.superlogical.terminal.write", {
    session_id = opts.session, block_id = candidate.block,
    args = { data = "exec " .. table.concat(command, " ") .. "\n" },
  })
  return candidate
end

return M
