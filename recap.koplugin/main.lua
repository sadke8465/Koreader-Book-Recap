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
local SETTINGS_PATH = DataStorage:getSettingsDir() .. "/recap.lua"

local CONFIG = {}
do
    local config_path = DataStorage:getDataDir() .. "/plugins/recap.koplugin/recap_config.lua"
    local func = loadfile(config_path)
    if func then
        local ok, mod = pcall(func)
        if ok and type(mod) == "table" then CONFIG = mod end
    end
end

local DEFAULTS = {
    api_url         = CONFIG.api_url         or "https://api.openai.com/v1/chat/completions",
    api_key         = CONFIG.api_key         or "",
    model_name      = CONFIG.model_name      or "gpt-4o-mini",
    request_timeout = CONFIG.request_timeout or 30,
    system_prompt   = "You are a highly knowledgeable reading companion. Your job is to provide brief, spoiler-free recaps of books based on the user's current reading position. Do not spoil anything past the provided chapter.",
}

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
                help_text = _("Send your reading context to an AI and display a spoiler-free recap."),
                callback  = function() self:onGenerateRecap() end,
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

    -- The "Ghost Highlight" Trick
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

function Recap:onGenerateRecap()
    if self:cfg("api_key") == "" then
        UIManager:show(InfoMessage:new{ text = _("Please set your API key first."), timeout = 5 })
        return
    end
    if NetworkMgr:isConnected() then self:_startRecapRequest()
    else NetworkMgr:runWhenOnline(function() self:_startRecapRequest() end) end
end

function Recap:_startRecapRequest()
    local context, err = self:extractContext()
    if not context then
        UIManager:show(InfoMessage:new{ text = _("Could not read document."), timeout = 5 })
        return
    end

    -- Dynamically count the extracted characters across all pages
    local char_count = context.current_text and #context.current_text or 0
    if context.prev_pages then
        for _, text in ipairs(context.prev_pages) do
            char_count = char_count + #text
        end
    end
    local loading_msg = string.format("Extracted %d characters.\nGenerating recap…\nThis may take a few seconds.", char_count)

    self._loading = InfoMessage:new{ text = _(loading_msg), no_refresh_on_show = true }
    UIManager:show(self._loading)
    UIManager:forceRePaint()

    UIManager:scheduleIn(0.5, function() self:_performAPIRequest(context) end)
end

function Recap:_buildUserMessage(ctx, raw_text, prev_texts)
    local msg = string.format("I am currently reading '%s' by %s.\nI am on the chapter titled: %s.\n", ctx.title, ctx.author, ctx.chapter)

    if prev_texts and #prev_texts > 0 then
        local combined = table.concat(prev_texts, "\n")
        if combined ~= "" then
            msg = msg .. string.format("\nFor extra context, here is the text from the previous %d page(s):\n\"\"\"\n%s\n\"\"\"\n", #prev_texts, combined)
        end
    end

    if raw_text and raw_text ~= "" then
        msg = msg .. string.format("\nFor extra context, here is the exact text on my current page:\n\"\"\"\n%s\n\"\"\"\n", raw_text)
    end

    msg = msg .. "\nPlease generate a spoiler-free recap of the story leading up to this exact point so I can remember where I left off."
    return msg
end

function Recap:_performAPIRequest(context)
    if self._loading then UIManager:close(self._loading); self._loading = nil end
    if not json or not ltn12 then self:_showError(_("Required libraries missing.")); return end

    local api_url  = self:cfg("api_url")
    local api_key  = self:cfg("api_key")
    local model    = self:cfg("model_name")
    
    local raw_text = context.current_text and context.current_text:sub(1, MAX_PAGE_CHARS) or ""

    local prev_texts = {}
    if context.prev_pages then
        for _, text in ipairs(context.prev_pages) do
            prev_texts[#prev_texts + 1] = text:sub(1, MAX_PAGE_CHARS)
        end
    end

    local sys_prompt   = self:cfg("system_prompt")
    local user_message = self:_buildUserMessage(context, raw_text, prev_texts)

    local payload_table = {
        model       = model,
        messages    = {
            { role = "system", content = sys_prompt },
            { role = "user",   content = user_message },
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
        self:_showRecap(response.choices[1].message.content, context)
    else
        self:_showError(_("Unexpected response structure.")); return
    end
end

function Recap:_showRecap(text, context)
    UIManager:show(TextViewer:new{
        title  = string.format(_("Recap — %s"), context.title),
        text   = text,
        height = math.floor(Screen:getHeight() * 0.78),
    })
end

function Recap:_showError(message)
    logger.err("Recap: " .. tostring(message))
    UIManager:show(InfoMessage:new{ text = message, timeout = 8, icon = "notice-warning" })
end

return Recap
