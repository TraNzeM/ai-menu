--!nonstrict
-- ai-menu service: deferred paste of the response into the application.
--
-- The panel (panel.luau) closes first and publishes a request to the state
-- channel ("paste"). This service waits ~800 ms — until the panel layer
-- disappears and focus returns to the app — then emulates Ctrl+V via wtype
-- (pasting over the active selection). For Insert it additionally restores
-- the previous clipboard after ~1 s.

local pending = nil -- { mode, restore } | nil
local wtypeDone = false
local restoreAt = 0
local restoreDone = false

local PASTE_DELAY_MS = 800 -- wait for focus to return to the app
local RESTORE_DELAY_MS = 1000 -- pause after wtype before restoring the clipboard
local TICK_MS = 50

local function idle()
  noctalia.setUpdateInterval(5000)
end

noctalia.state.watch("paste", function(v)
  if type(v) ~= "table" or v.mode == nil then return end
  pending = v
  wtypeDone = false
  restoreDone = (v.restore == nil)
  restoreAt = 0
  noctalia.setUpdateInterval(TICK_MS)
  noctalia.log("ai-menu paste: " .. tostring(v.mode))
end)

function update()
  if pending == nil then
    idle()
    return
  end

  local now = noctalia.nowMs()
  local startedAt = pending._startedAt or 0
  if startedAt == 0 then
    pending._startedAt = now
    return
  end

  if not wtypeDone and now - startedAt >= PASTE_DELAY_MS then
    wtypeDone = true
    -- Ctrl+V pastes over the active selection (replaces the fragment)
    noctalia.runAsync({ "wtype", "-M", "ctrl", "v" })
    if pending.restore ~= nil then
      restoreAt = now
    end
  end

  if wtypeDone and not restoreDone and pending.restore ~= nil and now - restoreAt >= RESTORE_DELAY_MS then
    restoreDone = true
    noctalia.copyToClipboard(pending.restore, "text/plain")
  end

  if wtypeDone and restoreDone then
    pending = nil
    idle()
  end
end
