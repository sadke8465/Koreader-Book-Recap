--[[
    recap.koplugin/main.lua
    ========================
    KOReader plugin — "Book Recap"

    Workflow
    --------
    1. User opens menu → "Book Recap" → "Generate Recap"
    2. Plugin checks Wi-Fi / connectivity via NetworkMgr.
    3. Reading context is extracted synchronously (fast):
         • Book title & author  (document:getProps())
         • Current chapter      (TOC scan)
         • Current + previous page text
    4. An InfoMessage "Generating recap…" is shown immediately.
    5. UIManager:scheduleIn() defers the blocking HTTP call by ~0.5 s so
       the e-ink display can refresh and show that message first.
    6. The HTTPS POST is made to an OpenAI-compatible endpoint.
    7. The JSON response is parsed and the recap text is displayed in a
       scrollable TextViewer.
    8. Errors at every stage are surfaced via dismissible InfoMessages.

    Configuration (persisted to <settingsdir>/recap.lua):
         api_url       — OpenAI-compatible endpoint
         api_key       — Bearer token
         model_name    — e.g. "gpt-4o-mini"
         system_prompt — Instruction given to the model
--]]

-- ============================================================
-- § 1  MODULE IMPORTS
-- ============================================================

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local Screen          = require("device/screen")
local Device          = require("device")
local DataStorage     = require("datastorage")
local LuaSettings     = require("luasettings")
local NetworkMgr      = require("ui/network/manager")
local Dispatcher      = require("dispatcher")
local InfoMessage     = require("ui/widget/infomessage")
local TextViewer      = require("ui/widget/textviewer")
local InputDialog     = require("ui/widget/inputdialog")
local logger          = require("logger")
local util            = require("util")
local _               = require("gettext")

-- JSON: KOReader ships rapidjson; fall back to the legacy "json" module
local json
do
    local ok, mod = pcall(require, "rapidjson")
    if ok then
        json = mod
    else
        ok, mod = pcall(require, "json")
        if ok then
            json = mod
        else
            -- Last-resort: tiny inline encoder/decoder (covers our simple use-case)
            json = nil
        end
    end
end

-- HTTP transport: prefer HTTPS, fall back to plain HTTP
local https, http, ltn12
do
    local ok
    ok, https = pcall(require, "ssl.https")
    if not ok then https = nil end
    ok, http  = pcall(require, "socket.http")
    if not ok then http  = nil end
    ltn12 = require("ltn12")
end

-- ============================================================
-- § 2  PLUGIN SKELETON & CONFIGURATION
-- ============================================================

--- Maximum characters taken from each page when building the prompt.
--- Keeps token usage predictable on e-ink devices with slow connections.
local MAX_PAGE_CHARS = 900

--- Path to the plugin's own settings file.
local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/recap.lua"

--- Load static config (api_key, api_url, model_name, request_timeout).
--- recap_config.lua is the recommended place to paste your API key.
local CONFIG = {}
do
    local ok, mod = pcall(require, "recap_config")
    if ok and type(mod) == "table" then CONFIG = mod end
end

--- Load the master system prompt template from recap_prompt.lua.
local DEFAULT_PROMPT
do
    local ok, mod = pcall(require, "recap_prompt")
    if ok and type(mod) == "string" then DEFAULT_PROMPT = mod end
end

--- Factory defaults — used when no user value has been saved yet.
--- Values from config.lua take precedence over the hard-coded fallbacks here.
local DEFAULTS = {
    api_url         = CONFIG.api_url         or "https://api.openai.com/v1/chat/completions",
    api_key         = CONFIG.api_key         or "",
    model_name      = CONFIG.model_name      or "gpt-4o-mini",
    request_timeout = CONFIG.request_timeout or 30,
    -- system_prompt comes from recap_prompt.lua; falls back to a minimal inline string
    system_prompt   = DEFAULT_PROMPT or [[You are a helpful reading companion. Provide a brief, spoiler-free recap of the current reading position based on the context provided.]],
}

local Recap = WidgetContainer:extend{
    name        = "recap",
    is_doc_only = false,  -- visible in both file manager and reader menus
}

-- ----------------------------------------------------------------
-- init  — called by KOReader when the plugin is attached to the UI
-- ----------------------------------------------------------------
function Recap:init()
    -- Open (or create) the persistent settings file
    self.settings = LuaSettings:open(SETTINGS_PATH)

    -- Register this plugin as a main-menu contributor
    self.ui.menu:registerToMainMenu(self)

    -- Register a Dispatcher action so users can bind it to a gesture/key
    self:_registerDispatcherActions()

    logger.dbg("Recap: plugin initialised")
end

-- ----------------------------------------------------------------
-- cfg helpers — thin wrappers around LuaSettings
-- ----------------------------------------------------------------

--- Read a setting, returning the built-in default if no user value exists.
function Recap:cfg(key)
    local v = self.settings:readSetting(key)
    if v == nil or v == "" then
        return DEFAULTS[key]
    end
    return v
end

--- Persist a setting to disk immediately.
function Recap:setCfg(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

-- ============================================================
-- § 3  MENU REGISTRATION
-- ============================================================

function Recap:addToMainMenu(menu_items)
    menu_items.recap = {
        text         = _("Book Recap"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text      = _("Generate Recap"),
                help_text = _("Send your reading context to an AI and display a spoiler-free recap."),
                callback  = function()
                    self:onGenerateRecap()
                end,
                separator = true,
            },
            {
                text           = _("Settings"),
                sub_item_table = self:_buildSettingsMenu(),
            },
        },
    }
end

--- Register a Dispatcher action so the feature can be bound to a
--- gesture or hardware key via KOReader's Gestures/Profiles system.
function Recap:_registerDispatcherActions()
    Dispatcher:registerAction("recap_generate", {
        category = "none",
        event    = "RecapGenerate",
        title    = _("Generate Book Recap"),
        general  = true,
    })
end

--- Dispatcher event handler (mirrors the menu callback)
function Recap:onRecapGenerate()
    self:onGenerateRecap()
end

-- ----------------------------------------------------------------
-- Settings sub-menu — one item per configurable field
-- ----------------------------------------------------------------
function Recap:_buildSettingsMenu()
    -- Helper: create a menu item that opens an InputDialog for a text setting
    local function textItem(label, key, is_secret)
        return {
            text_func = function()
                -- When the field holds a secret, show a checkmark instead of the value
                if is_secret then
                    local v = self.settings:readSetting(key)
                    local suffix = (v and v ~= "") and " ✓" or " (not set)"
                    return label .. suffix
                end
                return label
            end,
            callback = function()
                local dlg
                dlg = InputDialog:new{
                    title       = label,
                    -- Don't pre-fill secret fields
                    input       = is_secret and "" or (self.settings:readSetting(key) or ""),
                    input_hint  = is_secret and _("(hidden — type new value to replace)") or DEFAULTS[key] or "",
                    description = _("Leave blank to use the default value."),
                    buttons     = {{
                        {
                            text     = _("Cancel"),
                            id       = "close",
                            callback = function()
                                UIManager:close(dlg)
                            end,
                        },
                        {
                            text             = _("Save"),
                            is_enter_default = true,
                            callback         = function()
                                local val = dlg:getInputText()
                                if val ~= "" then
                                    self:setCfg(key, val)
                                end
                                UIManager:close(dlg)
                            end,
                        },
                    }},
                }
                UIManager:show(dlg)
                dlg:onShowKeyboard()
            end,
        }
    end

    return {
        textItem(_("API URL"),    "api_url"),
        textItem(_("API Key"),    "api_key",    true),
        textItem(_("Model Name"), "model_name"),
        {
            text     = _("Edit System Prompt"),
            callback = function() self:_editSystemPrompt() end,
        },
    }
end

--- Open a multi-line InputDialog for editing the system prompt.
function Recap:_editSystemPrompt()
    local dlg
    dlg = InputDialog:new{
        title        = _("System Prompt"),
        input        = self:cfg("system_prompt"),
        allow_newline = true,
        description  = _("Instructions sent to the AI as the 'system' role."),
        buttons      = {{
            {
                text     = _("Cancel"),
                id       = "close",
                callback = function() UIManager:close(dlg) end,
            },
            {
                text     = _("Reset to Default"),
                callback = function()
                    -- Clear stored value so cfg() falls back to DEFAULTS
                    self.settings:saveSetting("system_prompt", nil)
                    self.settings:flush()
                    UIManager:close(dlg)
                    UIManager:show(InfoMessage:new{
                        text    = _("System prompt reset to default."),
                        timeout = 2,
                    })
                end,
            },
            {
                text             = _("Save"),
                is_enter_default = false,
                callback         = function()
                    self:setCfg("system_prompt", dlg:getInputText())
                    UIManager:close(dlg)
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- ============================================================
-- § 4  READING CONTEXT EXTRACTION
-- ============================================================

--- Return all relevant reading context as a plain table, or (nil, errmsg).
--- All operations are synchronous and fast (no I/O).
function Recap:extractContext()
    local doc = self.ui.document
    if not doc then
        return nil, _("No document is currently open.")
    end

    -- 4.1  Book metadata ---------------------------------------------------
    local props  = doc:getProps()
    local title  = (props and props.title  and props.title  ~= "") and props.title  or _("Unknown Title")
    local author = (props and props.authors and props.authors ~= "") and props.authors or _("Unknown Author")

    -- 4.2  Current page & total -------------------------------------------
    local current_page = doc:getCurrentPage()
    local total_pages  = doc:getPageCount() or 0

    -- 4.3  Chapter from TOC -----------------------------------------------
    local chapter = self:_chapterAtPage(current_page)

    -- 4.4  Page text (current + previous) ---------------------------------
    local cur_text  = self:_pageText(current_page)
    local prev_text = (current_page > 1) and self:_pageText(current_page - 1) or ""

    logger.dbg(string.format(
        "Recap: context — title=%q  author=%q  chapter=%q  page=%d/%d  cur_chars=%d  prev_chars=%d",
        title, author, chapter, current_page, total_pages, #cur_text, #prev_text))

    return {
        title        = title,
        author       = author,
        chapter      = chapter,
        page_number  = current_page,
        total_pages  = total_pages,
        current_text = cur_text,
        prev_text    = prev_text,
    }
end

--- Find the chapter title for a given page by scanning the TOC backwards.
--- Returns "Unknown Chapter" if the document has no TOC.
function Recap:_chapterAtPage(page_num)
    local doc = self.ui.document
    if not doc then return _("Unknown Chapter") end

    local toc
    local ok = pcall(function()
        toc = doc:getTableOfContent()
    end)

    if not ok or not toc or #toc == 0 then
        return _("Unknown Chapter")
    end

    -- The TOC entries are ordered by page.  Walk forward and keep the last
    -- entry whose page is at or before our current page.
    local found = toc[1].title or _("Chapter 1")
    for _, entry in ipairs(toc) do
        local entry_page = entry.page or 0
        if entry_page <= page_num then
            found = entry.title or found
        else
            break
        end
    end
    return found
end

--- Extract the readable text from a page.
--- Tries getPageText() first (EPUB/CRE), then falls back to assembling
--- text from getPageTextBoxes() (PDF/DJVU/CBZ).
--- Always returns a string (empty on failure).
function Recap:_pageText(page_num)
    -- Strategy 1: CRE documents expose a direct string accessor
    local ok, result = pcall(function()
        return self.ui.document:getPageText(page_num)
    end)
    if ok and type(result) == "string" and result ~= "" then
        return result:match("^%s*(.-)%s*$") or ""
    end

    -- Strategy 2: Raster/kopt documents expose per-word bounding boxes
    ok, result = pcall(function()
        return self.ui.document:getPageTextBoxes(page_num)
    end)
    if ok and type(result) == "table" then
        return self:_textFromBoxes(result)
    end

    logger.warn("Recap: could not extract text from page " .. tostring(page_num))
    return ""
end

--- Flatten a getPageTextBoxes() result (array-of-lines of word-boxes) into
--- a plain multi-line string.
function Recap:_textFromBoxes(boxes)
    if not boxes then return "" end
    local lines = {}
    for _, line in ipairs(boxes) do
        if type(line) == "table" then
            local words = {}
            for _, box in ipairs(line) do
                if type(box) == "table" and type(box.word) == "string" then
                    table.insert(words, box.word)
                end
            end
            if #words > 0 then
                table.insert(lines, table.concat(words, " "))
            end
        end
    end
    return table.concat(lines, "\n")
end

-- ============================================================
-- § 5  NETWORK REQUEST  (async via UIManager:scheduleIn)
-- ============================================================

--- Entry point from the menu / Dispatcher.
--- Validates config, checks connectivity, then hands off to startRecapRequest.
function Recap:onGenerateRecap()
    -- Guard: API key must be set (checks saved setting AND config.lua default)
    if self:cfg("api_key") == "" then
        UIManager:show(InfoMessage:new{
            text    = _("Please set your API key under\nBook Recap → Settings → API Key\nbefore generating a recap."),
            timeout = 5,
        })
        return
    end

    -- Guard: network must be (or become) available
    if NetworkMgr:isConnected() then
        self:_startRecapRequest()
    else
        -- runWhenOnline() shows KOReader's built-in Wi-Fi enable dialog and
        -- calls the callback once a connection is established.
        NetworkMgr:runWhenOnline(function()
            self:_startRecapRequest()
        end)
    end
end

--- Synchronously gather context, show the "loading" message, then schedule
--- the blocking HTTP call so the e-ink display can refresh first.
function Recap:_startRecapRequest()
    local context, err = self:extractContext()
    if not context then
        UIManager:show(InfoMessage:new{
            text    = _("Could not read document:\n") .. (err or _("unknown error")),
            timeout = 5,
        })
        return
    end

    -- Show a persistent loading banner (no auto-dismiss timeout)
    self._loading = InfoMessage:new{
        text             = _("Generating recap…\nThis may take a few seconds."),
        no_refresh_on_show = true,
    }
    UIManager:show(self._loading)
    -- Force the e-ink display to refresh so the user sees the message
    UIManager:forceRePaint()

    -- Defer the blocking HTTP request by ~0.5 s.
    -- This gives the display driver time to finish the refresh before
    -- the Lua VM is occupied with the synchronous socket call.
    UIManager:scheduleIn(0.5, function()
        self:_performAPIRequest(context)
    end)
end

--- Replace {{variable}} placeholders in the system prompt template with
--- the actual reading context values collected at runtime.
function Recap:_fillPromptTemplate(template, ctx, raw_text)
    -- Escape percent signs in substitution strings to avoid gsub pattern issues
    local function esc(s)
        return (s or ""):gsub("%%", "%%%%")
    end
    local result = template
    result = result:gsub("{{book_title}}",        esc(ctx.title))
    result = result:gsub("{{author_name}}",        esc(ctx.author))
    result = result:gsub("{{chapter_name}}",       esc(ctx.chapter))
    result = result:gsub("{{raw_extracted_text}}", esc(raw_text))
    return result
end

--- Build the request payload, POST it, parse the response.
--- All heavy lifting happens here (runs on the main thread but after the
--- initial display refresh, so the user sees "Generating…" first).
function Recap:_performAPIRequest(context)
    -- Dismiss loading banner
    if self._loading then
        UIManager:close(self._loading)
        self._loading = nil
    end

    -- Ensure JSON library is available
    if not json then
        self:_showError(_("JSON library not available — cannot encode request."))
        return
    end

    local api_url  = self:cfg("api_url")
    local api_key  = self:cfg("api_key")
    local model    = self:cfg("model_name")

    -- Build combined raw text (previous page followed by current page)
    local raw_parts = {}
    if context.prev_text and context.prev_text ~= "" then
        table.insert(raw_parts, context.prev_text:sub(1, MAX_PAGE_CHARS))
    end
    if context.current_text and context.current_text ~= "" then
        table.insert(raw_parts, context.current_text:sub(1, MAX_PAGE_CHARS))
    end
    local raw_text = table.concat(raw_parts, "\n\n")

    -- Fill {{variable}} placeholders in the system prompt template
    local sys_prompt   = self:_fillPromptTemplate(self:cfg("system_prompt"), context, raw_text)
    local user_message = self:_buildUserMessage(context)

    -- 5.1  Encode request body --------------------------------------------
    local payload_table = {
        model       = model,
        messages    = {
            { role = "system", content = sys_prompt   },
            { role = "user",   content = user_message },
        },
        max_tokens  = 800,
        temperature = 0.7,
    }

    local ok_enc, payload_json = pcall(json.encode, payload_table)
    if not ok_enc or type(payload_json) ~= "string" then
        self:_showError(_("Failed to encode API request:\n") .. tostring(payload_json))
        return
    end

    logger.dbg("Recap: POST to " .. api_url .. " (" .. #payload_json .. " bytes)")

    -- 5.2  Select transport (HTTPS preferred, HTTP as fallback) ----------
    local transport
    if api_url:match("^https://") and https then
        transport = https
    elseif http then
        transport = http
    else
        self:_showError(_("No HTTP library is available on this device."))
        return
    end

    -- 5.3  Perform the request --------------------------------------------
    local response_body = {}
    local req_ok, http_status, _headers = pcall(function()
        return transport.request{
            url     = api_url,
            method  = "POST",
            headers = {
                ["Content-Type"]   = "application/json",
                ["Authorization"]  = "Bearer " .. api_key,
                ["Content-Length"] = tostring(#payload_json),
                ["User-Agent"]     = "KOReader/recap-plugin",
            },
            source  = ltn12.source.string(payload_json),
            sink    = ltn12.sink.table(response_body),
        }
    end)

    -- pcall succeeded means no Lua exception; req_ok is the first return
    -- value from transport.request (the response-headers table on success
    -- or nil on failure)
    if not req_ok then
        -- pcall itself failed — network exception
        self:_showError(_("Network error:\n") .. tostring(http_status))
        return
    end

    -- transport.request returns (response, status_code, headers)
    -- When called via pcall the values shift: req_ok=response, http_status=code
    local status_code = http_status  -- numeric HTTP status, e.g. 200

    logger.dbg("Recap: HTTP status = " .. tostring(status_code))

    -- 5.4  Parse JSON response -------------------------------------------
    local raw = table.concat(response_body)
    if raw == "" then
        self:_showError(_("Empty response from API server."))
        return
    end

    local ok_dec, response = pcall(json.decode, raw)
    if not ok_dec or type(response) ~= "table" then
        self:_showError(_("Could not parse API response.\n") ..
            (type(raw) == "string" and raw:sub(1, 120) or ""))
        return
    end

    -- 5.5  Surface API-level errors (4xx / 5xx) --------------------------
    if response.error then
        local msg = (type(response.error) == "table" and response.error.message)
                    or tostring(response.error)
        self:_showError(_("API error:\n") .. msg)
        return
    end

    -- 5.6  Extract the assistant's text -----------------------------------
    local recap_text
    if  response.choices
    and response.choices[1]
    and response.choices[1].message
    and type(response.choices[1].message.content) == "string"
    then
        recap_text = response.choices[1].message.content
    else
        self:_showError(_("Unexpected response structure from API."))
        return
    end

    -- 5.7  Show result ----------------------------------------------------
    self:_showRecap(recap_text, context)
end

--- Compose the user-role message sent to the model.
--- The system prompt already contains all context via template substitution,
--- so this is just a short trigger to start the generation.
function Recap:_buildUserMessage(ctx)  -- luacheck: ignore ctx
    return "Please generate the recap now."
end

-- ============================================================
-- § 6  UI PRESENTATION
-- ============================================================

--- Display the recap text in a scrollable TextViewer.
function Recap:_showRecap(text, context)
    UIManager:show(TextViewer:new{
        title     = string.format(_("Recap — %s"), context.title),
        text      = text,
        text_type = "para",
        justified = true,
        height    = math.floor(Screen:getHeight() * 0.78),
    })
end

--- Display a user-friendly error message via a dismissible InfoMessage.
function Recap:_showError(message)
    logger.err("Recap: " .. tostring(message))
    UIManager:show(InfoMessage:new{
        text    = message,
        timeout = 8,
        icon    = "notice-warning",
    })
end

-- ============================================================
-- Return the plugin class to KOReader's plugin loader
-- ============================================================
return Recap
