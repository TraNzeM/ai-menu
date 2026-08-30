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

-- Localization: en/ru tables + t() by the language setting (default en).
local I18N = {
  en = {
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
  },
  ru = {
    title = "AI Menu",
    ask_hint = "Введите вопрос (Enter — отправить, Esc — назад)",
    ask_placeholder = "Ваш вопрос…",
    working = "Запрос к Hermes…",
    no_selection = "Выделите текст и откройте меню",
    http_transport_error = "HTTP: транспортная ошибка",
    http_rejected = "HTTP: запрос отклонён",
    http_auth_error = "Ошибка авторизации (401/403): API_SERVER_KEY не найден или неверен. Если Hermes в Docker — укажи в env_file путь к compose .env (например ~/hermes-workspace/.env) и задай там API_SERVER_KEY.",
    env_file_error = "Не удалось прочитать env-файл: ",
    empty_response = "пустой ответ модели",
    retry = "Повторить",
    actions = { "Копировать", "Вставить", "Заменить", "Чат" },
  },
}

local function currentLang()
  local lang = noctalia.getConfig("language") or "en"
  if I18N[lang] then return lang end
  return "en"
end

local function t(key)
  local v = I18N[currentLang()][key]
  if v == nil then v = I18N.en[key] end -- fallback to en when the key is missing in the selected language
  return v
end

local phase = PHASE_LIST
local commands = {} -- { name, prompt, ask? }
local inputText = ""
local response = ""
local errorText = ""
local busy = false
local selectedIndex = 1 -- current command (keyboard)
local scrollIdx = 0 -- visibility window: commands scrollIdx+1 .. scrollIdx+visible
local VISIBLE = 8 -- commands visible in the 440px panel (32px row + 6 gap)
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
  local promptTemplate = cmd.displayPrompt or cmd.prompt
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

-- Keyboard: Up/Down through commands, Enter run, Esc close.
function onKey(chord, pressed)
  if not pressed then return end

  if phase == PHASE_LIST then
    if chord == "Up" then
      selectedIndex = selectedIndex - 1
      if selectedIndex < 1 then selectedIndex = #commands end
      -- keep the selector inside the window
      if selectedIndex <= scrollIdx then
        scrollIdx = selectedIndex - 1
      elseif selectedIndex > scrollIdx + VISIBLE then
        scrollIdx = selectedIndex - VISIBLE
      end
      safeRender()
    elseif chord == "Down" then
      selectedIndex = selectedIndex + 1
      if selectedIndex > #commands then selectedIndex = 1 end
      -- keep the selector inside the window
      if selectedIndex <= scrollIdx then
        scrollIdx = selectedIndex - 1
      elseif selectedIndex > scrollIdx + VISIBLE then
        scrollIdx = selectedIndex - VISIBLE
      end
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
  elseif phase == PHASE_WORKING and chord == "Escape" then
    -- do not cancel HTTP, just close the panel; the callback will no-op
    panel.close()
  end
end

render = function()
  if phase == PHASE_ASK then
    -- Free question (ask): input field instead of the command list.
    local cmd = commands[askIndex] or {}
    local cmdName = cmd.displayName or (cmd.name or "")
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

  -- PHASE_LIST
  -- Visibility window: render VISIBLE+1 commands (wheel margin) starting at
  -- scrollIdx. Arrows move selectedIndex and scrollIdx together, so the
  -- selector is always visible.
  local listRows = {}
  local first = math.max(1, scrollIdx + 1)
  local last = math.min(#commands, first + VISIBLE) -- +1 margin: wheel can scroll the last one
  for i = first, last do
    local cmd = commands[i]
    table.insert(listRows, ui.button({
      key = "cmd-" .. i,
      text = cmd.displayName or cmd.name,
      contentAlign = "start",
      selected = (i == selectedIndex),
      onClick = function()
        selectedIndex = i
        if cmd.ask then
          askIndex = i
          askDraft = ""
          phase = PHASE_ASK
          safeRender()
        else
          runCommand(i)
        end
      end,
    }))
  end

  local sub = inputText ~= "" and string.sub(inputText, 1, 60) or t("no_selection")

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch", padding = 16 }, {
    ui.label({ text = t("title"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
    ui.separator({ thickness = 1, color = "outline/0.4", spacing = 4 }),
    ui.label({ text = sub, color = "on_surface_variant", fontSize = 12, maxLines = 1 }),
    -- Mouse wheel: onScroll moves the window manually (ui.scroll has no
    -- programmatic scrollTo)
    ui.scroll({
      flexGrow = 1,
      gap = 6,
      align = "stretch",
      onScroll = function(offsetStr)
        local offset = tonumber(offsetStr) or 0
        if offset > 0 and scrollIdx + VISIBLE < #commands then
          scrollIdx = scrollIdx + 1
          -- keep the selector inside the window
          if selectedIndex <= scrollIdx then selectedIndex = scrollIdx + 1 end
          safeRender()
        elseif offset <= 0 and scrollIdx > 0 then
          scrollIdx = scrollIdx - 1
          safeRender()
        end
      end,
    }, listRows),
  }))
end

-- Built-in commands (fallback when commands_file is unset/unreadable).
-- displayName/displayPrompt are chosen by language; name/prompt — EN variants.
local DEFAULT_COMMANDS = {
  { name = "Ask me anything", ask = true, prompt = 'Answer the following: {input}', name_ru = "Спроси о чём угодно", prompt_ru = 'Ответь на следующий вопрос: {input}' },
  { name = "Explain this", prompt = 'Explain the text in triple quotes below:\n"""\n{input}\n"""\nDo not return anything other than the explanation. Do not wrap responses in quotes.', name_ru = "Объясни это", prompt_ru = 'Объясни текст в тройных кавычках ниже:\n"""\n{input}\n"""\nНе возвращай ничего, кроме объяснения. Не оборачивай ответ в кавычки.' },
  { name = "Fix spelling and grammar", prompt = 'Correct the text in triple quotes below into standard English and fix the grammar. Make your best effort.\n"""\n{input}\n"""\nDo not return anything other than the corrected text. Do not wrap responses in quotes.', name_ru = "Исправить орфографию и грамматику", prompt_ru = 'Исправь текст в тройных кавычках ниже. Сделай всё возможное.\n"""\n{input}\n"""\nНе возвращай ничего, кроме исправленного текста. Не оборачивай ответ в кавычки.' },
  { name = "Improve writing", prompt = 'Improve the text in triple quotes below in your own words. Rephrase the text.\n"""\n{input}\n"""\nDo not return anything other than the rephrased text. Do not wrap responses in quotes.', name_ru = "Улучшить текст", prompt_ru = 'Улучши текст в тройных кавычках ниже своими словами. Перефразируй текст.\n"""\n{input}\n"""\nНе возвращай ничего, кроме перефразированного текста. Не оборачивай ответ в кавычки.' },
  { name = "Expand my writing", prompt = 'The following text in triple quotes below has already been written:\n"""\n{input}\n"""\nExpand the writing. Write at least 3 paragraphs. Do not return anything other than the expanded writing.', name_ru = "Расширить текст", prompt_ru = 'Следующий текст в тройных кавычках уже написан:\n"""\n{input}\n"""\nРасширь текст. Напиши минимум 3 абзаца. Не возвращай ничего, кроме расширенного текста.' },
  { name = "Simplify my writing", prompt = 'The following text in triple quotes below has already been written:\n"""\n{input}\n"""\nSimplify and condense the writing. Do not return anything other than the simplified writing.', name_ru = "Упростить текст", prompt_ru = 'Следующий текст в тройных кавычках уже написан:\n"""\n{input}\n"""\nУпрости и сократи текст. Не возвращай ничего, кроме упрощённого текста.' },
  { name = "List key takeaways", prompt = 'My notes are below in triple quotes:\n"""\n{input}\n"""\nWrite a markdown list (using dashes) of the important points from the notes. Write at least 10 items.', name_ru = "Основные выводы", prompt_ru = 'Мои заметки ниже в тройных кавычках:\n"""\n{input}\n"""\nНапиши markdown-список (через дефисы) важных пунктов из заметок. Напиши минимум 10 пунктов.' },
  { name = "Write a short summary", prompt = 'Summarize the text in triple quotes but keep it concise. Summarize using plain and simple words, preserve the tense:\n"""\n{input}\n"""\nDo not return anything other than the summary.', name_ru = "Краткое резюме", prompt_ru = 'Суммаризируй текст в тройных кавычках кратко. Используй простые слова, сохрани время:\n"""\n{input}\n"""\nНе возвращай ничего, кроме резюме.' },
  { name = "Write a longer summary", prompt = 'Summarize the text in triple quotes below into three long paragraphs. Summarize using plain and simple words, preserve the tense:\n"""\n{input}\n"""\nDo not return anything other than the summary.', name_ru = "Подробное резюме", prompt_ru = 'Суммаризируй текст в тройных кавычках ниже в три длинных абзаца. Используй простые слова, сохрани время:\n"""\n{input}\n"""\nНе возвращай ничего, кроме резюме.' },
  { name = "Translate to Russian", prompt = 'Translate the text in triple quotes below to Russian.\n"""\n{input}\n"""\nDo not return anything other than the translation.', name_ru = "Перевести на русский", prompt_ru = 'Переведи текст в тройных кавычках ниже на русский.\n"""\n{input}\n"""\nНе возвращай ничего, кроме перевода.' },
}

-- Load commands: commands_file (JSON [{name,prompt}]) or built-ins.
-- Supports name_ru/prompt_ru: the ru variant is picked when language=ru.
local function loadCommands()
  local lang = currentLang()
  local path = noctalia.getConfig("commands_file")
  if path ~= nil and path ~= "" then
    local raw, err = noctalia.readFile(noctalia.expandPath(path))
    if raw ~= nil then
      local data, jerr = noctalia.json.decode(raw)
      if data ~= nil and type(data) == "table" then
        local result = {}
        for _, c in ipairs(data) do
          if type(c) == "table" and type(c.name) == "string" and type(c.prompt) == "string" then
            local entry = { name = c.name, prompt = c.prompt, ask = (c.ask == true) }
            if lang == "ru" and type(c.name_ru) == "string" and type(c.prompt_ru) == "string" then
              entry.displayName = c.name_ru
              entry.displayPrompt = c.prompt_ru
            else
              entry.displayName = c.name
              entry.displayPrompt = c.prompt
            end
            table.insert(result, entry)
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
  -- fallback: built-in commands, localized by language
  local result = {}
  for _, c in ipairs(DEFAULT_COMMANDS) do
    local entry = { name = c.name, prompt = c.prompt, ask = (c.ask == true) }
    if lang == "ru" and c.name_ru then
      entry.displayName = c.name_ru
      entry.displayPrompt = c.prompt_ru
    else
      entry.displayName = c.name
      entry.displayPrompt = c.prompt
    end
    table.insert(result, entry)
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
