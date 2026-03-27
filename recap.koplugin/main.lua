--[[
    recap.koplugin/main.lua
    ========================
    KOReader plugin — "Book Recap"
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local Device          = require("device")
local Screen          = Device.screen
local Geom            = require("ui/geometry")
local DataStorage     = require("datastorage")
local LuaSettings     = require("luasettings")
local NetworkMgr      = require("ui/network/manager")
local Dispatcher      = require("dispatcher")
local InfoMessage     = require("ui/widget/infomessage")
local TextViewer      = require("ui/widget/textviewer")
local InputDialog     = require("ui/widget/inputdialog")
local logger          = require("logger")
local _               = require("gettext")

local json
do
    local ok, mod = pcall(require, "rapidjson")
    if ok then json = mod else
        ok, mod = pcall(require, "json")
        if ok then json = mod else json = nil end
    end
end

local https, http, ltn12
do
    local ok
    ok, https = pcall(require, "ssl.https")
    if not ok then https = nil end
    ok, http  = pcall(require, "socket.http")
    if not ok then http  = nil end
    ok, ltn12 = pcall(require, "ltn12")
    if not ok then ltn12 = nil end
end

local MAX_PAGE_CHARS = 1200
local SETTINGS_PATH  = DataStorage:getSettingsDir() .. "/recap.lua"
local PLUGIN_DIR     = DataStorage:getDataDir() .. "/plugins/recap.koplugin"

local CONFIG = {}
do
    local config_path = PLUGIN_DIR .. "/recap_config.lua"
    local func = loadfile(config_path)
    if func then
        local ok, mod = pcall(func)
        if ok and type(mod) == "table" then CONFIG = mod end
    end
end

local DEFAULTS = {
    api_url         = CONFIG.api_url         or "https://api.openai.com/v1/chat/completions",
    api_key         = CONFIG.api_key         or "",
    model_name      = CONFIG.model_name      or "gemini-2.5-pro",
    request_timeout = CONFIG.request_timeout or 30,
    system_prompt   = "You are a highly knowledgeable reading companion. Your job is to provide brief, spoiler-free recaps of books based on the user's current reading position. Do not spoil anything past the provided chapter.",
}

-- Load a prompt file from the prompts/ subdirectory.
-- Returns the prompt string, or nil if the file cannot be loaded.
local function loadPrompt(filename)
    local path = PLUGIN_DIR .. "/prompts/" .. filename
    local func = loadfile(path)
    if not func then return nil end
    local ok, result = pcall(func)
    if ok and type(result) == "string" then return result end
    return nil
end

-- Replace all {{variable}} placeholders in template with values from vars table.
local function applyTemplate(template, vars)
    return (template:gsub("{{(%w+)}}", function(key)
        return tostring(vars[key] or "")
    end))
end

local Recap = WidgetContainer:extend{
    name        = "recap",
    is_doc_only = false,
}

function Recap:init()
    self.settings = LuaSettings:open(SETTINGS_PATH)
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    pcall(function() self:_registerDispatcherActions() end)
    logger.dbg("Recap: plugin initialised")
end

function Recap:cfg(key)
    local v = self.settings:readSetting(key)
    if v == nil or v == "" then return DEFAULTS[key] end
    return v
end

function Recap:setCfg(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function Recap:addToMainMenu(menu_items)
    menu_items.recap = {
        text         = _("Book Recap"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text      = _("Generate Recap"),
                help_text = _("Spoiler-free recap of the story up to your current page."),
                callback  = function() self:onGenerateRecap() end,
            },
            {
                text      = _("Previous Chapter"),
                help_text = _("Recap of the chapter you just finished."),
                callback  = function() self:onPreviousChapterRecap() end,
            },
            {
                text      = _("Character"),
                help_text = _("What you know about a character so far (no spoilers)."),
                callback  = function() self:onCharacterInfo() end,
                separator = true,
            },
            {
                text           = _("Settings"),
                sub_item_table = self:_buildSettingsMenu(),
            },
        },
    }
end

function Recap:_registerDispatcherActions()
    Dispatcher:registerAction("recap_generate", {
        category = "none",
        event    = "RecapGenerate",
        title    = _("Generate Book Recap"),
        general  = true,
    })
end

function Recap:onRecapGenerate() self:onGenerateRecap() end

function Recap:_buildSettingsMenu()
    local function textItem(label, key, is_secret)
        return {
            text_func = function()
                if is_secret then
                    local v = self.settings:readSetting(key)
                    return label .. ((v and v ~= "") and " ✓" or " (not set)")
                end
                return label
            end,
            callback = function()
                local dlg
                dlg = InputDialog:new{
                    title       = label,
                    input       = is_secret and "" or (self.settings:readSetting(key) or ""),
                    input_hint  = is_secret and _("(hidden — type new value to replace)") or DEFAULTS[key] or "",
                    buttons     = {{
                        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
                        { text = _("Save"), is_enter_default = true, callback = function()
                            local val = dlg:getInputText()
                            if val ~= "" then self:setCfg(key, val) end
                            UIManager:close(dlg)
                        end},
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
    }
end

-- ─── Context extraction ────────────────────────────────────────────────────

function Recap:extractContext()
    local doc = self.ui.document
    if not doc then return nil, _("No document is currently open.") end

    local props  = doc:getProps()
    local title  = (props and props.title  and props.title  ~= "") and props.title  or _("Unknown Title")
    local author = (props and props.authors and props.authors ~= "") and props.authors or _("Unknown Author")
    local current_page = doc:getCurrentPage()
    local chapter = self:_chapterAtPage(current_page)
    local cur_text  = self:_pageText(current_page)

    local prev_pages = {}
    for i = 2, 1, -1 do
        local p = current_page - i
        if p >= 1 then
            prev_pages[#prev_pages + 1] = self:_pageText(p)
        end
    end

    return { title = title, author = author, chapter = chapter, current_text = cur_text, prev_pages = prev_pages }
end

-- Returns info about the chapter immediately before the one containing page_num.
-- Returns { title, first_page, last_page } or nil if no previous chapter exists.
function Recap:_previousChapterInfo(page_num)
    local doc = self.ui.document
    if not doc then return nil end
    local toc
    local ok = pcall(function() toc = doc:getTableOfContent() end)
    if not ok or not toc or #toc == 0 then return nil end

    -- Find the TOC index whose chapter contains page_num (same logic as _chapterAtPage)
    local current_idx = 1
    for i, entry in ipairs(toc) do
        if (entry.page or 0) <= page_num then
            current_idx = i
        else
            break
        end
    end

    local prev_idx = current_idx - 1
    if prev_idx < 1 then return nil end  -- already on the first chapter

    local prev_entry = toc[prev_idx]
    -- The previous chapter ends one page before the current chapter starts
    local current_chapter_start = toc[current_idx].page or (page_num + 1)
    local last_page = current_chapter_start - 1

    -- Cap at total page count
    local total_pages = doc:getPageCount and doc:getPageCount() or last_page
    if last_page > total_pages then last_page = total_pages end

    return {
        title      = prev_entry.title or _("Previous Chapter"),
        first_page = prev_entry.page  or 1,
        last_page  = last_page,
    }
end

-- Build context table for the previous chapter recap.
function Recap:extractPreviousChapterContext()
    local doc = self.ui.document
    if not doc then return nil, _("No document is currently open.") end

    local props  = doc:getProps()
    local title  = (props and props.title  and props.title  ~= "") and props.title  or _("Unknown Title")
    local author = (props and props.authors and props.authors ~= "") and props.authors or _("Unknown Author")

    local current_page    = doc:getCurrentPage()
    local current_chapter = self:_chapterAtPage(current_page)
    local prev_info       = self:_previousChapterInfo(current_page)

    if not prev_info then
        return nil, _("Could not find a previous chapter. You may be on the first chapter.")
    end

    -- Collect text from the previous chapter's pages (capped to avoid huge payloads)
    local MAX_TOTAL_CHARS = 3000
    local pages_text  = {}
    local total_chars = 0
    for p = prev_info.first_page, prev_info.last_page do
        if total_chars >= MAX_TOTAL_CHARS then break end
        local text = self:_pageText(p)
        if text ~= "" then
            local remaining = MAX_TOTAL_CHARS - total_chars
            local chunk = text:sub(1, remaining)
            pages_text[#pages_text + 1] = chunk
            total_chars = total_chars + #chunk
        end
    end

    return {
        title                = title,
        author               = author,
        prev_chapter_name    = prev_info.title,
        current_chapter_name = current_chapter,
        raw_extracted_text   = table.concat(pages_text, "\n---\n"),
    }
end

function Recap:_chapterAtPage(page_num)
    local doc = self.ui.document
    if not doc then return _("Unknown Chapter") end
    local toc
    local ok = pcall(function() toc = doc:getTableOfContent() end)
    if not ok or not toc or #toc == 0 then return _("Unknown Chapter") end

    local found = toc[1].title or _("Chapter 1")
    for _, entry in ipairs(toc) do
        local entry_page = entry.page or 0
        if entry_page <= page_num then found = entry.title or found else break end
    end
    return found
end

function Recap:_pageText(page_num)
    local doc = self.ui.document
    if not doc then return "" end

    -- The "Ghost Highlight" Trick (only works on the currently rendered page)
    if page_num == doc:getCurrentPage() and doc.getTextFromPositions then
        local top_left     = Geom:new{ x = 0, y = 0, w = 0, h = 0 }
        local bottom_right = Geom:new{ x = Screen:getWidth(), y = Screen:getHeight(), w = 0, h = 0 }

        local ok, result = pcall(function()
            return doc:getTextFromPositions(top_left, bottom_right, true)
        end)

        if ok then
            local text = ""
            if type(result) == "table" and type(result.text) == "string" then
                text = result.text
            elseif type(result) == "string" then
                text = result
            end
            if text ~= "" then
                return text:match("^%s*(.-)%s*$") or ""
            end
        end
    end

    if doc.getPageText then
        local ok, result = pcall(function() return doc:getPageText(page_num) end)
        if ok and type(result) == "string" and result ~= "" then
            return result:match("^%s*(.-)%s*$") or ""
        end
    end

    return ""
end

-- Concatenate prev_pages + current_text into a single raw text block.
function Recap:_buildRawText(ctx)
    local parts = {}
    if ctx.prev_pages then
        for _, text in ipairs(ctx.prev_pages) do
            if text ~= "" then
                parts[#parts + 1] = text:sub(1, MAX_PAGE_CHARS)
            end
        end
    end
    if ctx.current_text and ctx.current_text ~= "" then
        parts[#parts + 1] = ctx.current_text:sub(1, MAX_PAGE_CHARS)
    end
    return table.concat(parts, "\n---\n")
end

-- ─── Menu actions ─────────────────────────────────────────────────────────

function Recap:onGenerateRecap()
    if self:cfg("api_key") == "" then
        UIManager:show(InfoMessage:new{ text = _("Please set your API key first."), timeout = 5 })
        return
    end
    if NetworkMgr:isConnected() then self:_startCurrentRecap()
    else NetworkMgr:runWhenOnline(function() self:_startCurrentRecap() end) end
end

function Recap:_startCurrentRecap()
    local ctx, err = self:extractContext()
    if not ctx then
        UIManager:show(InfoMessage:new{ text = err or _("Could not read document."), timeout = 5 })
        return
    end

    local raw_text    = self:_buildRawText(ctx)
    local template    = loadPrompt("recap_current.lua") or self:cfg("system_prompt")
    local sys_prompt  = applyTemplate(template, {
        book_title         = ctx.title,
        author_name        = ctx.author,
        chapter_name       = ctx.chapter,
        raw_extracted_text = raw_text,
    })
    local user_msg    = string.format(
        "I am reading '%s' by %s. I am currently in the chapter titled: %s. Please generate the recap as instructed.",
        ctx.title, ctx.author, ctx.chapter)
    local viewer_title = string.format(_("Recap — %s"), ctx.title)

    self:_dispatchRequest(sys_prompt, user_msg, viewer_title, #raw_text)
end

function Recap:onPreviousChapterRecap()
    if self:cfg("api_key") == "" then
        UIManager:show(InfoMessage:new{ text = _("Please set your API key first."), timeout = 5 })
        return
    end
    if NetworkMgr:isConnected() then self:_startPreviousChapterRecap()
    else NetworkMgr:runWhenOnline(function() self:_startPreviousChapterRecap() end) end
end

function Recap:_startPreviousChapterRecap()
    local ctx, err = self:extractPreviousChapterContext()
    if not ctx then
        UIManager:show(InfoMessage:new{ text = err or _("Could not find previous chapter."), timeout = 5 })
        return
    end

    local template   = loadPrompt("recap_previous.lua") or self:cfg("system_prompt")
    local sys_prompt = applyTemplate(template, {
        book_title           = ctx.title,
        author_name          = ctx.author,
        prev_chapter_name    = ctx.prev_chapter_name,
        current_chapter_name = ctx.current_chapter_name,
        raw_extracted_text   = ctx.raw_extracted_text,
    })
    local user_msg = string.format(
        "I just finished the chapter '%s' in '%s' by %s. Please recap it as instructed.",
        ctx.prev_chapter_name, ctx.title, ctx.author)
    local viewer_title = string.format(_("Previous Chapter — %s"), ctx.prev_chapter_name)

    self:_dispatchRequest(sys_prompt, user_msg, viewer_title, #ctx.raw_extracted_text)
end

function Recap:onCharacterInfo()
    if self:cfg("api_key") == "" then
        UIManager:show(InfoMessage:new{ text = _("Please set your API key first."), timeout = 5 })
        return
    end

    local dlg
    dlg = InputDialog:new{
        title      = _("Character Name"),
        input_hint = _("e.g. Aragorn, Elizabeth Bennet…"),
        buttons    = {{
            { text = _("Cancel"), id = "close",
              callback = function() UIManager:close(dlg) end },
            { text = _("Look Up"), is_enter_default = true,
              callback = function()
                  local name = dlg:getInputText()
                  UIManager:close(dlg)
                  if not name or name:match("^%s*$") then return end
                  if NetworkMgr:isConnected() then self:_startCharacterRequest(name)
                  else NetworkMgr:runWhenOnline(function() self:_startCharacterRequest(name) end) end
              end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function Recap:_startCharacterRequest(character_name)
    local ctx, err = self:extractContext()
    if not ctx then
        UIManager:show(InfoMessage:new{ text = err or _("Could not read document."), timeout = 5 })
        return
    end

    local raw_text   = self:_buildRawText(ctx)
    local template   = loadPrompt("character_info.lua") or self:cfg("system_prompt")
    local sys_prompt = applyTemplate(template, {
        book_title         = ctx.title,
        author_name        = ctx.author,
        chapter_name       = ctx.chapter,
        character_name     = character_name,
        raw_extracted_text = raw_text,
    })
    local user_msg = string.format(
        "I am reading '%s' by %s, currently in chapter '%s'. Tell me about the character: %s.",
        ctx.title, ctx.author, ctx.chapter, character_name)
    local viewer_title = string.format(_("%s — %s"), character_name, ctx.title)

    self:_dispatchRequest(sys_prompt, user_msg, viewer_title, #raw_text)
end

-- ─── API request ──────────────────────────────────────────────────────────

-- Show loading message, then fire the API call.
-- char_count is used only for the loading indicator text.
function Recap:_dispatchRequest(sys_prompt, user_msg, viewer_title, char_count)
    local loading_msg = string.format(
        _("Extracted %d characters.\nGenerating…\nThis may take a few seconds."),
        char_count or 0)

    self._loading = InfoMessage:new{ text = loading_msg, no_refresh_on_show = true }
    UIManager:show(self._loading)
    UIManager:forceRePaint()

    UIManager:scheduleIn(0.5, function()
        self:_performAPIRequest(sys_prompt, user_msg, viewer_title)
    end)
end

function Recap:_performAPIRequest(sys_prompt, user_msg, viewer_title)
    if self._loading then UIManager:close(self._loading); self._loading = nil end
    if not json or not ltn12 then self:_showError(_("Required libraries missing.")); return end

    local api_url = self:cfg("api_url")
    local api_key = self:cfg("api_key")
    local model   = self:cfg("model_name")

    local payload_table = {
        model       = model,
        messages    = {
            { role = "system", content = sys_prompt },
            { role = "user",   content = user_msg   },
        },
        max_tokens  = 800,
        temperature = 0.7,
    }

    local ok_enc, payload_json = pcall(json.encode, payload_table)
    if not ok_enc then self:_showError(_("Failed to encode request.")); return end

    local transport = (api_url:match("^https://") and https) or http
    if not transport then self:_showError(_("No HTTP library.")); return end

    local response_body = {}
    local req_ok, http_status = pcall(function()
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

    if not req_ok then self:_showError(_("Network error:\n") .. tostring(http_status)); return end

    local raw = table.concat(response_body)
    local ok_dec, response = pcall(json.decode, raw)
    if not ok_dec then self:_showError(_("Could not parse API response.")); return end

    if response.error then
        local msg = (type(response.error) == "table" and response.error.message) or tostring(response.error)
        self:_showError(_("API error:\n") .. msg); return
    end

    if response.choices and response.choices[1] and response.choices[1].message then
        self:_showRecap(response.choices[1].message.content, viewer_title)
    else
        self:_showError(_("Unexpected response structure.")); return
    end
end

function Recap:_showRecap(text, viewer_title)
    UIManager:show(TextViewer:new{
        title  = viewer_title,
        text   = text,
        height = math.floor(Screen:getHeight() * 0.78),
    })
end

function Recap:_showError(message)
    logger.err("Recap: " .. tostring(message))
    UIManager:show(InfoMessage:new{ text = message, timeout = 8, icon = "notice-warning" })
end

return Recap
