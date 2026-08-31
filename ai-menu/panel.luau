--!nonstrict
-- ai-menu panel: AI commands over selected text via Hermes API.
--
-- Phases:
--   list    — command selection (mouse or Up/Down + Enter)
--   ask     — free-form question input (for ask commands)
--   working — streaming request to Hermes (partial tokens shown live)
--   done    — response + action bar Copy / Replace / Insert / Chat / Write / Close
--
-- Text capture: primary selection (wl-paste --primary) -> clipboard fallback
-- (wl-paste).
--
-- Actions:
--   Copy    — response to clipboard, close panel
--   Replace — response to clipboard + Ctrl+A+Ctrl+V (replace selection)
--   Insert  — response to clipboard + Ctrl+V, previous buffer restored
--   Chat    — terminal + hermes chat --resume (same persistent session)
--   Write   — like Insert, but buffer is not restored
--   Close   — close
-- Pasting is done by [[service]] (service.luau) via a state channel, because
-- the panel closes first and focus must return to the application.

local PHASE_LIST = "list"
local PHASE_ASK = "ask"
local PHASE_WORKING = "working"
local PHASE_DONE = "done"
local PHASE_EDIT = "edit"

-- UI strings (panel always in English; plugin settings in the Noctalia GUI
-- are localized by Noctalia's own language via translations/<lang>.json).
local I18N = {
  title = "AI Menu",
  ask_hint = "Type your question (Enter to send, Esc to go back)",
  ask_placeholder = "Your question…",
  working = "Requesting Hermes…",
  no_selection = "Select some text and open the menu",
  http_transport_error = "HTTP: transport error",
  http_rejected = "HTTP: request rejected",
  http_auth_error = "Authentication error (401/403): API_SERVER_KEY not found or invalid. If Hermes runs in Docker, set env_file to your compose .env (e.g. ~/hermes-workspace/.env) and set API_SERVER_KEY there.",
  env_file_error = "Cannot read env file: ",
  empty_response = "empty model response",
  retry = "Retry",
  actions = { "Copy", "Insert", "Replace", "Chat" },
}

local function t(key)
  local v = I18N[key]
  if v == nil then return key end -- missing key: fall back to the key itself
  return v
end

local phase = PHASE_LIST
local commands = {} -- { name, prompt, ask? }
local inputText = ""
local response = ""
local errorText = ""
local busy = false
local selectedIndex = 1 -- current command (keyboard)
-- Measured on the live panel (440px logical, scale 1.5): header zone (padding +
-- title + separator + input-preview + gaps) consumes 226 physical px, the
-- ui.scroll viewport is ~409 physical = 272 logical px. Content must stay under
-- that or the scrollbar appears: 5 rows * 40 + 4 * 6 = 224 -> fits with slack.
local VISIBLE = 5 -- commands visible; selected sits exactly in the middle (3rd)
local askIndex = 1 -- which command is in free-question (ask) mode
local askDraft = "" -- typed question

local doneAction = 0
local lastRequest = nil -- { index, askInput } — for Retry
-- Persistent Hermes session: created on first request, reused by all
-- subsequent ones (X-Hermes-Session-Id). When clear_session=true the header
-- is omitted, so each request runs in a fresh session.
local PERSISTENT_SESSION_ID = "ai-menu"

-- Text captured on open (primary selection / clipboard).
local function fetchInput(onDone)
  -- primary selection: fast path
  noctalia.runAsync({ "wl-paste", "--primary", "--no-newline" }, function(r)
    if r.exitCode == 0 and r.stdout ~= "" then
      inputText = r.stdout
      onDone()
      return
    end
    -- fallback: plain clipboard
    noctalia.runAsync({ "wl-paste", "--no-newline" }, function(r2)
      if r2.exitCode == 0 then
        inputText = r2.stdout
      else
        inputText = ""
      end
      onDone()
    end)
  end)
end

-- Forward declaration: render() is called from runCommand() and callbacks,
-- so declare the slot up front (otherwise the upvalue captures nil).
local render
local function safeRender()
  local okR, errR = pcall(render)
  if not okR then
    noctalia.log("ai-menu RENDER FAILED: " .. tostring(errR))
  end
end

-- Request to Hermes: POST {base_url}/v1/chat/completions with stream=true.
-- Streaming via noctalia.httpStream: delta.content chunks accumulate in
-- response and render immediately; hermes.tool.progress events show which
-- tool the model is running (calculator, terminal, etc.).
-- askInput: typed text for free-question (ask) commands; otherwise the
-- captured inputText is used.
local streamHandle = nil -- active stream (to cancel in onClose)
local toolStatus = "" -- current model tool ("🐍 print(12*12)…")

local function runCommand(index, askInput)
  local cmd = commands[index]
  if cmd == nil or busy then return end
  lastRequest = { index = index, askInput = askInput } -- for Retry
  busy = true
  phase = PHASE_WORKING
  response = ""
  errorText = ""
  toolStatus = ""
  render()

  local baseUrl = noctalia.getConfig("base_url") or "http://127.0.0.1:8642"
  local model = noctalia.getConfig("model") or "deepseek-v4-flash"
  local envFile = noctalia.getConfig("env_file") or "~/.hermes/.env"
  local source = askInput or inputText
  local promptTemplate = cmd.prompt
  -- Escape % in the substituted text: in string.gsub replacements % is a
  -- special character (e.g. "50%" would break the prompt).
  -- IMPORTANT: the inner gsub returns (string, count) — parens drop the
  -- count, otherwise it lands in the outer gsub's n parameter and disables
  -- replacements.
  local prompt = string.gsub(promptTemplate, "{input}", (string.gsub(source, "%%", "%%%%")))

  -- API_SERVER_KEY from the env file
  local key = ""
  local envPath = noctalia.expandPath(envFile)
  local ok, err = noctalia.readFile(envPath)
  if ok then
    for line in string.gmatch(ok, "[^\r\n]+") do
      local k, v = string.match(line, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if k == "API_SERVER_KEY" then
        key = v
        break
      end
    end
  else
    -- env file unreadable: no key — the request would fail anyway (401/403),
    -- so show a clear error immediately instead of a pointless request.
    busy = false
    errorText = t("env_file_error") .. tostring(err)
    phase = PHASE_DONE
    safeRender()
    return
  end

  local body = noctalia.json.encode({
    model = model,
    messages = { { role = "user", content = prompt } },
    stream = true,
    max_tokens = 2048,
  })

  -- Hermes session: always send a stable X-Hermes-Session-Id (one ai-menu
  -- session, no api-* proliferation). With clear_session=true the session is
  -- deleted first via DELETE /api/sessions/ai-menu, then the request recreates
  -- it clean.
  local headers = {
    "Authorization: Bearer " .. key,
    "Content-Type: application/json",
    "X-Hermes-Session-Id: " .. PERSISTENT_SESSION_ID,
  }

  -- Stream finalization: errors, empty response, transition to DONE.
  local function finishStream(result)
    streamHandle = nil
    busy = false
    if not result.ok then
      errorText = t("http_transport_error")
    elseif result.status ~= 200 then
      if result.status == 401 or result.status == 403 then
        errorText = t("http_auth_error")
      else
        errorText = "HTTP " .. tostring(result.status)
      end
    elseif response == "" then
      errorText = t("empty_response")
    end
    phase = PHASE_DONE
    safeRender()
  end

  -- Send the request to Hermes (after optional session clear).
  local function sendChat()
    streamHandle = noctalia.httpStream({
      url = baseUrl .. "/v1/chat/completions",
      method = "POST",
      headers = headers,
      body = body,
    }, function(line)
      -- SSE: "data: {json}", "event: hermes.tool.progress", "data: [DONE]"
      if line:sub(1, 6) == "event:" then
        local ev = line:sub(8)
        if ev == "hermes.tool.progress" then
          toolStatus = "" -- reset: next data carries the tool status
        end
        return
      end
      if line:sub(1, 6) ~= "data: " then return end
      local payload = line:sub(7)
      if payload == "[DONE]" then return end
      local chunk, jerr = noctalia.json.decode(payload)
      if chunk == nil then
        noctalia.log("ai-menu: sse parse: " .. tostring(jerr))
        return
      end
      if chunk.tool and chunk.status then
        -- hermes.tool.progress: {tool, emoji, label, status}
        if chunk.status == "running" and chunk.label then
          toolStatus = (chunk.emoji or "🔧") .. " " .. chunk.label
          safeRender()
        end
        return
      end
      local delta = chunk.choices and chunk.choices[1] and chunk.choices[1].delta
      if delta and delta.content then
        response = response .. delta.content
        -- markdown renderer may choke on leading newlines/spaces — trim them
        -- (the response text is unaffected)
        response = noctalia.string.trim(response)
        safeRender()
      end
    end, function(result)
      finishStream(result)
    end)

    if streamHandle == nil then
      -- httpStream returned nil: stream could not start
      busy = false
      errorText = t("http_rejected")
      phase = PHASE_DONE
      safeRender()
    end
  end

  local clearSession = noctalia.getConfig("clear_session") == true
  if clearSession then
    -- Delete the ai-menu session history (if any) synchronously in a chain:
    -- only after the DELETE response do we start the request. DELETE 404 (no
    -- session) is not an error — the request recreates it clean.
    noctalia.http({
      url = baseUrl .. "/api/sessions/" .. PERSISTENT_SESSION_ID,
      method = "DELETE",
      headers = { "Authorization: Bearer " .. key },
    }, function(_resp)
      sendChat()
    end)
  else
    sendChat()
  end
end

-- Prompt editor state (PHASE_EDIT): fields 1=name 2=prompt 3=icon 4=shortcut.
local editIndex = 0
local editField = 1
local editName = ""
local editPrompt = ""
local editIcon = ""
local editShortcut = ""
local editError = ""
-- Bumped on every render: forces ui.input recreation (focus=true only takes
-- effect on a freshly-created input), so the active field always receives
-- keyboard input after Up/Down switching.
local editRenderTick = 0

-- Done-panel actions.
local function doAction(i)
  if phase ~= PHASE_DONE then return end
  if i == 0 then
    -- Copy
    noctalia.copyToClipboard(response, "text/plain")
    panel.close()
  elseif i == 1 then
    -- Insert: paste + restore previous clipboard
    local prev = noctalia.clipboardText() or ""
    noctalia.copyToClipboard(response, "text/plain")
    noctalia.state.set("paste", { mode = "insert", restore = prev })
    panel.close()
  elseif i == 2 then
    -- Replace: overwrite selection (Ctrl+A + Ctrl+V)
    noctalia.copyToClipboard(response, "text/plain")
    noctalia.state.set("paste", { mode = "replace", restore = nil })
    panel.close()
  elseif i == 3 then
    -- Chat: terminal continuing the same session. Command is configurable
    -- (chat_command), {session} is replaced with the session id. Default is
    -- hermes chat --resume; for Docker: docker exec -it hermes-agent hermes chat --resume {session}
    local chatCmd = noctalia.getConfig("chat_command") or "hermes chat --resume {session}"
    chatCmd = string.gsub(chatCmd, "{session}", PERSISTENT_SESSION_ID)
    noctalia.runInTerminal(chatCmd)
    panel.close()
  elseif i == 4 then
    -- Retry: re-send the same request (same command + ask input)
    if lastRequest ~= nil then
      runCommand(lastRequest.index, lastRequest.askInput)
    end
  end
end

-- Prompt editor --------------------------------------------------------------

-- Open the editor for command i (from PHASE_LIST).
local function openEditor(i)
  local cmd = commands[i]
  if cmd == nil then return end
  editIndex = i
  editField = 1
  editName = cmd.name or ""
  editPrompt = cmd.prompt or ""
  editIcon = cmd.icon or ""
  editShortcut = cmd.shortcut or ""
  editError = ""
  phase = PHASE_EDIT
  safeRender()
end

-- Built-in variant of a command by name (for Reset), or nil.
local function defaultFor(name)
  for _, c in ipairs(DEFAULT_COMMANDS) do
    if c.name == name then return c end
  end
  return nil
end

-- Reset the editor to the built-in variant (clears icon/shortcut).
local function resetEditor()
  local def = defaultFor(editName)
  if def then
    editName = def.name
    editPrompt = def.prompt
  end
  editIcon = ""
  editShortcut = ""
  editError = ""
  safeRender()
end

-- Back to the command list without saving.
local function backFromEditor()
  phase = PHASE_LIST
  safeRender()
end

-- Validate + persist the edited command back to commands_file.
local function saveEditor()
  editError = ""
  editName = noctalia.string.trim(editName)
  editPrompt = noctalia.string.trim(editPrompt)
  editShortcut = noctalia.string.trim(editShortcut)
  if editName == "" then editError = "Name is required" safeRender() return end
  if editPrompt == "" then editError = "Prompt is required" safeRender() return end
  if not string.find(editPrompt, "{input}", 1, true) then
    editError = "Prompt must contain the {input} placeholder"
    safeRender()
    return
  end
  if editShortcut ~= "" and not string.match(editShortcut, "^[%w]$") then
    editError = "Shortcut must be a single letter or digit"
    safeRender()
    return
  end
  if editShortcut ~= "" then
    for i, c in ipairs(commands) do
      local cs = noctalia.string.trim(c.shortcut or "")
      if cs ~= "" and string.upper(cs) == string.upper(editShortcut) and i ~= editIndex then
        editError = "Shortcut already used by \"" .. (c.name or "?") .. "\""
        safeRender()
        return
      end
    end
  end
  -- update in-memory copy
  local ask = (commands[editIndex] and commands[editIndex].ask == true)
  commands[editIndex] = {
    name = editName, prompt = editPrompt, ask = ask,
    icon = editIcon, shortcut = editShortcut,
  }
  -- persist to commands_file (create if missing)
  local path = noctalia.getConfig("commands_file")
  if path ~= nil and path ~= "" then
    local saveData = {}
    for _, c in ipairs(commands) do
      local e = { name = c.name, prompt = c.prompt }
      if c.ask then e.ask = true end
      if c.icon and c.icon ~= "" then e.icon = c.icon end
      if c.shortcut and c.shortcut ~= "" then e.shortcut = c.shortcut end
      table.insert(saveData, e)
    end
    local ok, werr = noctalia.writeFile(noctalia.expandPath(path), noctalia.json.encode(saveData))
    if ok then
      noctalia.log("ai-menu: commands saved to " .. tostring(path))
    else
      noctalia.log("ai-menu: failed to save commands: " .. tostring(werr))
      editError = "Failed to save commands file: " .. tostring(werr)
      safeRender()
      return
    end
  end
  backFromEditor()
end

-- Keyboard: Up/Down through commands, Enter run, Esc close.
function onKey(chord, pressed)
  if not pressed then return end
  noctalia.log("ai-menu KEY: [" .. phase .. "] " .. tostring(chord))

  if phase == PHASE_LIST then
    -- Carousel: selectedIndex is the center of the window; Up/Down move the
    -- selection around the ring (1..#commands), the window recenters on it,
    -- so scrolling is infinite in both directions.
    if chord == "Up" then
      selectedIndex = selectedIndex - 1
      if selectedIndex < 1 then selectedIndex = #commands end
      safeRender()
    elseif chord == "Down" then
      selectedIndex = selectedIndex + 1
      if selectedIndex > #commands then selectedIndex = 1 end
      safeRender()
    elseif chord == "Return" then
      if commands[selectedIndex] and commands[selectedIndex].ask then
        -- free question: go to the input field
        askIndex = selectedIndex
        askDraft = ""
        phase = PHASE_ASK
        safeRender()
      else
        runCommand(selectedIndex)
      end
    elseif chord == "E" then
      -- Edit the selected command's prompt
      openEditor(selectedIndex)
    elseif #chord == 1 and string.match(chord, "^[%w]$") then
      -- shortcut letter/digit: run the command that owns it
      for i, c in ipairs(commands) do
        local sc = noctalia.string.trim(c.shortcut or "")
        if sc ~= "" and string.upper(sc) == string.upper(chord) then
          if c.ask then
            askIndex = i
            askDraft = ""
            phase = PHASE_ASK
            safeRender()
          else
            runCommand(i)
          end
          break
        end
      end
    elseif chord == "Escape" then
      panel.close()
    end
  elseif phase == PHASE_ASK then
    -- Enter from the input: send the question (Return is captured by the
    -- panel via capture_keys before the field's onSubmit — so send it here)
    if chord == "Return" then
      if askDraft ~= "" then
        runCommand(askIndex, askDraft)
      end
    elseif chord == "Escape" then
      -- Esc from the input — back to the list (do not close the panel)
      phase = PHASE_LIST
      safeRender()
    end
  elseif phase == PHASE_DONE then
    if chord == "Left" then
      doneAction = doneAction - 1
      if doneAction < 0 then doneAction = #t("actions") end -- 4 text + retry icon
      safeRender()
    elseif chord == "Right" then
      doneAction = doneAction + 1
      if doneAction > #t("actions") then doneAction = 0 end
      safeRender()
    elseif chord == "Return" then
      doAction(doneAction)
    elseif chord == "Escape" then
      panel.close()
    end
  elseif phase == PHASE_EDIT then
    if chord == "Up" then
      editField = editField - 1
      if editField < 1 then editField = 4 end
      editError = ""
      safeRender()
    elseif chord == "Down" then
      editField = editField + 1
      if editField > 4 then editField = 1 end
      editError = ""
      safeRender()
    elseif chord == "Tab" then
      -- Shift+Tab arrives as a separate spec in capture_keys (see manifest);
      -- plain Tab: next field.
      editField = editField < 4 and (editField + 1) or 1
      editError = ""
      safeRender()
    elseif chord == "Return" then
      if editField == 2 then
        -- Multiline prompt field: Return is consumed by the panel capture
        -- before the input sees it, so insert the newline ourselves (at the
        -- end of the value; Ctrl+Enter saves instead).
        editPrompt = editPrompt .. "\n"
        safeRender()
        return
      end
      -- Single-line fields: Enter moves to the next field.
      editField = editField < 4 and (editField + 1) or editField
      editError = ""
      safeRender()
    elseif chord == "Ctrl+Return" then
      -- Ctrl+Enter = save from any field (the multiline prompt field relies
      -- on this chord for saving; the input itself sees Shift+Enter only).
      saveEditor()
    elseif chord == "Escape" then
      backFromEditor()
    end
  elseif phase == PHASE_WORKING and chord == "Escape" then
    -- do not cancel HTTP, just close the panel; the callback will no-op
    panel.close()
  end
end

render = function()
  if phase == PHASE_ASK then
    -- Free question (ask): input field instead of the command list.
    local cmd = commands[askIndex] or {}
    local cmdName = cmd.name or ""
    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch", padding = 16 }, {
      ui.label({ text = t("title") .. " — " .. cmdName, fontSize = 16, fontWeight = "bold", color = "on_surface" }),
      ui.separator({ thickness = 1, color = "outline/0.4", spacing = 4 }),
      ui.label({
        text = t("ask_hint"),
        color = "on_surface_variant",
        fontSize = 12,
      }),
      ui.input({
        key = "ask-input",
        placeholder = t("ask_placeholder"),
        focus = true,
        onChange = function(value)
          askDraft = value
        end,
        onSubmit = function(value)
          askDraft = value
          runCommand(askIndex, value)
        end,
      }),
      ui.spacer({ flexGrow = 1 }),
    }))
    return
  end

  if phase == PHASE_WORKING then
    -- Live streaming: once tokens arrive (response ~= "") show them; before
    -- the first token — the tool status or "Requesting…".
    local bodyText = response
    local showProgress = (response == "")
    if bodyText == "" and toolStatus ~= "" then
      bodyText = toolStatus
    elseif bodyText == "" then
      bodyText = t("working")
    end
    local rows = {
      ui.label({ text = t("title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
      ui.separator({ thickness = 1, color = "outline/0.4", spacing = 4 }),
    }
    if showProgress then
      table.insert(rows, ui.label({ text = bodyText, color = "on_surface_variant", fontSize = 13 }))
      table.insert(rows, ui.progress({ progress = 0.5, fill = "primary", track = "surface_variant", height = 4, radius = 2 }))
    else
      table.insert(rows, ui.label({
        text = bodyText,
        color = "on_surface",
        fontSize = 14,
        maxLines = 50,
      }))
    end
    table.insert(rows, ui.spacer({ flexGrow = 1 }))
    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch", padding = 16 }, rows))
    return
  end

  if phase == PHASE_DONE then
    local labelText = response
    if errorText ~= "" then
      labelText = errorText
    end
    local actionRows = {}
    local actions = t("actions")
    for i, name in ipairs(actions) do
      table.insert(actionRows, ui.button({
        key = "act-" .. i,
        text = name,
        variant = (i == doneAction + 1) and "primary" or "default",
        selected = (i == doneAction + 1),
        controlSize = "sm",
        onClick = function() doAction(i - 1) end,
      }))
    end
    -- Retry as a circular-arrow icon button (4 text buttons + 1 icon).
    table.insert(actionRows, ui.button({
      key = "act-retry",
      glyph = "refresh",
      tooltip = t("retry"),
      variant = (doneAction == 4) and "primary" or "default",
      selected = (doneAction == 4),
      controlSize = "sm",
      onClick = function() doAction(4) end,
    }))
    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch", padding = 16 }, {
      ui.label({ text = t("title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
      ui.separator({ thickness = 1, color = "outline/0.4", spacing = 4 }),
      ui.label({
        text = labelText,
        color = "on_surface",
        fontSize = 14,
        maxLines = 50,
      }),
      -- spacer grows and pushes the buttons to the bottom (as scroll did)
      ui.spacer({ flexGrow = 1 }),
      ui.row({ gap = 4, align = "center" }, actionRows),
    }))
    return
  end

  -- PHASE_EDIT: prompt editor for the selected command.
  if phase == PHASE_EDIT then
    editRenderTick = editRenderTick + 1
    local fieldLabels = {
      "Name",
      "Prompt ({input} required)",
      "Icon (emoji)",
      "Shortcut (single letter)",
    }
    local fieldValues = { editName, editPrompt, editIcon, editShortcut }
    -- The active field gets a dedicated input. The prompt field is multiline
    -- (Enter = newline, Ctrl+Enter = save); single-line fields submit on Enter
    -- (onKey routes Enter from the panel anyway).
    local isPrompt = (editField == 2)
    local rows = {
      ui.label({ text = "Edit command — " .. (editName ~= "" and editName or "…"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
      ui.separator({ thickness = 1, color = "outline/0.4", spacing = 4 }),
      ui.label({
        text = fieldLabels[editField],
        fontSize = 12,
        color = "primary",
      }),
      ui.input({
        key = "ed-f" .. editField .. "-" .. editRenderTick,
        value = fieldValues[editField],
        focus = true,
        multiline = isPrompt,
        height = isPrompt and 110 or nil,
        placeholder = editField == 1 and "Command name"
          or (editField == 2 and "Prompt template with {input}")
          or (editField == 3 and "🚀" or "e.g. s"),
        submitOnEnter = not isPrompt,
        onChange = function(v)
          if editField == 1 then editName = v
          elseif editField == 2 then editPrompt = v
          elseif editField == 3 then editIcon = v
          else editShortcut = v end
        end,
      }),
    }
    -- The other 3 fields are rendered compactly as single lines.
    for i = 1, 4 do
      if i ~= editField then
        local val = fieldValues[i]
        table.insert(rows, ui.label({
          text = fieldLabels[i] .. ":  " .. ((val ~= nil and val ~= "") and val or "—"),
          color = "on_surface_variant",
          fontSize = 12,
          maxLines = 1,
        }))
      end
    end
    if editError ~= "" then
      table.insert(rows, ui.label({ text = editError, fontSize = 12, color = "error" }))
    end
    table.insert(rows, ui.label({
      text = isPrompt
        and "Ctrl+Enter: save · Esc: back · Up/Down: switch field · Enter: newline"
        or "Enter: next field · Ctrl+Enter: save · Esc: back",
      fontSize = 11,
      color = "on_surface_variant",
    }))
    table.insert(rows, ui.spacer({ flexGrow = 1 }))
    table.insert(rows, ui.row({ gap = 4, align = "center" }, {
      ui.button({ key = "ed-save", text = "Save", variant = "primary", onClick = function() saveEditor() end }),
      ui.button({ key = "ed-reset", text = "Reset", onClick = function() resetEditor() end }),
      ui.button({ key = "ed-back", text = "Back", onClick = function() backFromEditor() end }),
    }))
    panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch", padding = 16 }, rows))
    return
  end

  -- PHASE_LIST
  -- Carousel window: the selected command sits in the middle of the window;
  -- rows wrap around the ring, so the list keeps a constant height and never
  -- overflows its area — no scrollbar. Rendered as plain buttons in the
  -- column (no ui.scroll at all).
  local n = #commands
  local listRows = {}
  if n > 0 then
    local selectedRow = math.ceil(VISIBLE / 2) -- selected item's row within the window
    for k = 0, math.min(VISIBLE, n) - 1 do
      local cmdIndex = ((selectedIndex - selectedRow + k) % n) + 1
      local cmd = commands[cmdIndex]
      local label = cmd.name or ""
      if cmd.icon ~= nil and cmd.icon ~= "" then label = cmd.icon .. "  " .. label end
      if cmd.shortcut ~= nil and cmd.shortcut ~= "" then label = label .. "   [" .. cmd.shortcut .. "]" end
      table.insert(listRows, ui.button({
        key = "cmd-" .. cmdIndex,
        text = label,
        contentAlign = "start",
        -- Explicit height: the auto-sized card (57px) made 7 rows overflow the
        -- 440px panel (rows are clipped by the column, not hidden). 7*40+6*6
        -- = 316 logical px fits the ~331px list zone with margin at any theme.
        height = 40,
        selected = (cmdIndex == selectedIndex),
        onClick = function()
          selectedIndex = cmdIndex
          if cmd.ask then
            askIndex = cmdIndex
            askDraft = ""
            phase = PHASE_ASK
            safeRender()
          else
            runCommand(cmdIndex)
          end
        end,
      }))
    end
  end

  local sub = inputText ~= "" and string.sub(inputText, 1, 60) or t("no_selection")

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch", padding = 16 }, {
    ui.label({ text = t("title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
    ui.separator({ thickness = 1, color = "outline/0.4", spacing = 4 }),
    ui.label({ text = sub, color = "on_surface_variant", fontSize = 12, maxLines = 1 }),
    -- ui.scroll acts as a CLIPPING container (a plain column draws children
    -- past the panel edge). The carousel content is sized to fit
    -- (VISIBLE*(40+6) = 316 <= ~331px list zone), so the scrollbar never
    -- appears; if a future theme ever overflows, it degrades to a scrollbar
    -- instead of drawing outside the window.
    ui.scroll({ flexGrow = 1, gap = 6, align = "stretch" }, listRows),
  }))
end

-- Built-in commands (fallback when commands_file is unset/unreadable).
local DEFAULT_COMMANDS = {
  { name = "Ask me anything", ask = true, prompt = 'Answer the following: {input}' },
  { name = "Explain this", prompt = 'Explain the text in triple quotes below:\n"""\n{input}\n"""\nDo not return anything other than the explanation. Do not wrap responses in quotes.' },
  { name = "Fix spelling and grammar", prompt = 'Correct the text in triple quotes below into standard English and fix the grammar. Make your best effort.\n"""\n{input}\n"""\nDo not return anything other than the corrected text. Do not wrap responses in quotes.' },
  { name = "Improve writing", prompt = 'Improve the text in triple quotes below in your own words. Rephrase the text.\n"""\n{input}\n"""\nDo not return anything other than the rephrased text. Do not wrap responses in quotes.' },
  { name = "Expand my writing", prompt = 'The following text in triple quotes below has already been written:\n"""\n{input}\n"""\nExpand the writing. Write at least 3 paragraphs. Do not return anything other than the expanded writing.' },
  { name = "Simplify my writing", prompt = 'The following text in triple quotes below has already been written:\n"""\n{input}\n"""\nSimplify and condense the writing. Do not return anything other than the simplified writing.' },
  { name = "List key takeaways", prompt = 'My notes are below in triple quotes:\n"""\n{input}\n"""\nWrite a markdown list (using dashes) of the important points from the notes. Write at least 10 items.' },
  { name = "Write a short summary", prompt = 'Summarize the text in triple quotes but keep it concise. Summarize using plain and simple words, preserve the tense:\n"""\n{input}\n"""\nDo not return anything other than the summary.' },
  { name = "Write a longer summary", prompt = 'Summarize the text in triple quotes below into three long paragraphs. Summarize using plain and simple words, preserve the tense:\n"""\n{input}\n"""\nDo not return anything other than the summary.' },
  { name = "Translate to Russian", prompt = 'Translate the text in triple quotes below to Russian.\n"""\n{input}\n"""\nDo not return anything other than the translation.' },
}

-- Load commands: commands_file (JSON [{name,prompt}]) or built-ins.
local function loadCommands()
  local path = noctalia.getConfig("commands_file")
  if path ~= nil and path ~= "" then
    local raw, err = noctalia.readFile(noctalia.expandPath(path))
    if raw ~= nil then
      local data, jerr = noctalia.json.decode(raw)
      if data ~= nil and type(data) == "table" then
        local result = {}
        for _, c in ipairs(data) do
          if type(c) == "table" and type(c.name) == "string" and type(c.prompt) == "string" then
            table.insert(result, {
              name = c.name,
              prompt = c.prompt,
              ask = (c.ask == true),
              icon = (type(c.icon) == "string" and c.icon) or nil,
              shortcut = (type(c.shortcut) == "string" and c.shortcut) or nil,
            })
          end
        end
        if #result > 0 then
          return result
        end
        noctalia.log("ai-menu: commands_file empty or invalid, fallback")
      else
        noctalia.log("ai-menu: commands_file parse err: " .. tostring(jerr))
      end
    else
      noctalia.log("ai-menu: commands_file read err: " .. tostring(err))
    end
  end
  -- fallback: built-in commands
  local result = {}
  for _, c in ipairs(DEFAULT_COMMANDS) do
    table.insert(result, {
      name = c.name,
      prompt = c.prompt,
      ask = (c.ask == true),
      icon = (type(c.icon) == "string" and c.icon) or nil,
      shortcut = (type(c.shortcut) == "string" and c.shortcut) or nil,
    })
  end
  return result
end

function onOpen(_context)
  commands = loadCommands()

  phase = PHASE_LIST
  response = ""
  errorText = ""
  inputText = ""
  askDraft = ""
  selectedIndex = 1
  doneAction = 0
  fetchInput(function()
    safeRender()
  end)
  render()
end

function onClose()
  busy = false
  -- Cancel the active stream if the panel was closed mid-response
  -- (Esc in PHASE_WORKING or doAction). Per httpStream docs, the stream's
  -- onClose callback is not invoked after stop().
  if streamHandle ~= nil then
    streamHandle.stop()
    streamHandle = nil
  end
end
