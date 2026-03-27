--[[
    recap.koplugin/config.lua
    =========================
    Static configuration for the Book Recap plugin.

    *** HOW TO SET YOUR API KEY ***
    Find the line that says  api_key = ""  below and paste your key inside
    the quotes, e.g.  api_key = "sk-abc123..."

    These values are used as defaults.  You can also override any setting
    at runtime inside KOReader:
        Menu → Book Recap → Settings
--]]

return {

    -- ------------------------------------------------------------------
    --  API KEY  ← ENTER YOUR KEY HERE
    -- ------------------------------------------------------------------
    api_key = "",      -- e.g. "sk-proj-..."

    -- ------------------------------------------------------------------
    --  API endpoint  (OpenAI-compatible)
    -- ------------------------------------------------------------------
    api_url = "https://api.anthropic.com/v1/chat/completions",

    -- ------------------------------------------------------------------
    --  Model
    -- ------------------------------------------------------------------
    model_name = "claude-sonnet-4-6",

    -- ------------------------------------------------------------------
    --  How many seconds to wait for a response before giving up
    -- ------------------------------------------------------------------
    request_timeout = 30,

}
