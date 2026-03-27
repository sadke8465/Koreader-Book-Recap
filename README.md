# KOReader Book Recap Plugin

A KOReader plugin that uses any OpenAI-compatible AI API to give you spoiler-free recaps while you read. Useful when picking up a book after a break, refreshing your memory on the previous chapter, or looking up what you know about a character so far.

## Features

- **Generate Recap** — Summarizes the story up to your current page with no spoilers past where you are
- **Previous Chapter** — Recaps the chapter you just finished
- **Character** — Tells you everything you should know about a character based on how far you've read
- Configurable API endpoint, model, and key — works with OpenAI, Anthropic, Mistral, Ollama, or any OpenAI-compatible provider

---

## Installation

1. Download or clone this repository.
2. Copy the `recap.koplugin` folder into your KOReader plugins directory:

   | Device | Plugins path |
   |--------|-------------|
   | Kobo | `/.adds/koreader/plugins/` |
   | Kindle | `/koreader/plugins/` |
   | Android | `/sdcard/koreader/plugins/` |
   | Desktop (Linux) | `~/.local/share/koreader/plugins/` |

3. Restart KOReader (or go to **Main Menu → Help → Restart KOReader**).
4. The plugin appears under **Main Menu → Tools → Book Recap**.

---

## Adding Your API Key

### Option A: Config file (recommended for a permanent setup)

Open `recap.koplugin/recap_config.lua` in a text editor and fill in your key:

```lua
return {
    api_key    = "sk-proj-...",          -- paste your key here
    api_url    = "https://api.openai.com/v1/chat/completions",
    model_name = "gpt-4o-mini",
    request_timeout = 30,
}
```

Save the file and restart KOReader.

### Option B: In-app settings

Go to **Book Recap → Settings** while KOReader is running:

- **API Key** — paste your key (displayed as `✓` once saved, never shown in plain text)
- **API URL** — endpoint for your provider (see table below)
- **Model Name** — the model identifier for your provider

In-app settings override the config file and are stored in KOReader's own settings storage.

### Provider reference

| Provider | API URL | Example model |
|----------|---------|---------------|
| OpenAI | `https://api.openai.com/v1/chat/completions` | `gpt-4o-mini` |
| Anthropic (via proxy) | `https://api.anthropic.com/v1/messages` | `claude-3-haiku-20240307` |
| Mistral | `https://api.mistral.ai/v1/chat/completions` | `mistral-small-latest` |
| Ollama (local) | `http://localhost:11434/v1/chat/completions` | `llama3` |
| OpenRouter | `https://openrouter.ai/api/v1/chat/completions` | `mistralai/mistral-7b-instruct` |

Any provider that accepts the OpenAI `/v1/chat/completions` JSON format works.

---

## How Prompts Work

Each menu action loads a **prompt file** from `recap.koplugin/prompts/`. The file returns a Lua string that acts as the system prompt sent to the AI.

Before the request is sent, the plugin replaces `{{variable}}` placeholders in the prompt with real values from the book:

| Placeholder | Value |
|---|---|
| `{{book_title}}` | Title of the open book |
| `{{author_name}}` | Author(s) |
| `{{chapter_name}}` | Current chapter from the table of contents |
| `{{prev_chapter_name}}` | Previous chapter title (Previous Chapter prompt only) |
| `{{current_chapter_name}}` | Current chapter title (Previous Chapter prompt only) |
| `{{character_name}}` | Name typed by the user (Character prompt only) |
| `{{raw_extracted_text}}` | Text scraped from the current and previous pages |

### Editing an existing prompt

Open the prompt file for the action you want to change:

| Action | File |
|--------|------|
| Generate Recap | `recap.koplugin/prompts/recap_current.lua` |
| Previous Chapter | `recap.koplugin/prompts/recap_previous.lua` |
| Character | `recap.koplugin/prompts/character_info.lua` |

Each file returns a plain string. Edit the instructions however you like. Keep the `{{placeholders}}` you want the plugin to fill in — any placeholder you remove simply won't be sent.

Example — making the recap shorter:

```lua
-- recap.koplugin/prompts/recap_current.lua
return [[You are a reading assistant. Summarize the story of {{book_title}} by {{author_name}} up to chapter {{chapter_name}} in 3 bullet points. No spoilers past the current page.

Current page text:
"""
{{raw_extracted_text}}
"""]]
```

Restart KOReader after editing any prompt file.

---

## Adding New Prompts / Actions

To add a new menu action with its own prompt:

### Step 1 — Create the prompt file

Create a new file in `recap.koplugin/prompts/`. It must return a Lua string:

```lua
-- recap.koplugin/prompts/themes.lua
return [[You are a literary analyst. The user is reading {{book_title}} by {{author_name}}, currently in chapter {{chapter_name}}.

List the 3 most prominent themes in this book as understood up to the current chapter. For each theme give one short example from the story. Do not mention anything past the current chapter.

Current page text (for context):
"""
{{raw_extracted_text}}
"""]]
```

Use any combination of the available `{{placeholders}}` listed above.

### Step 2 — Add the menu entry and handler in `main.lua`

Open `recap.koplugin/main.lua`.

**Add the menu item** inside `Recap:addToMainMenu`, in the `sub_item_table` list:

```lua
{
    text      = _("Themes"),
    help_text = _("Key themes in the book up to your current page."),
    callback  = function() self:onThemes() end,
},
```

**Add the handler function** anywhere in the file before `return Recap`:

```lua
function Recap:onThemes()
    if self:cfg("api_key") == "" then
        UIManager:show(InfoMessage:new{ text = _("Please set your API key first."), timeout = 5 })
        return
    end
    if NetworkMgr:isConnected() then self:_startThemesRequest()
    else NetworkMgr:runWhenOnline(function() self:_startThemesRequest() end) end
end

function Recap:_startThemesRequest()
    local ctx, err = self:extractContext()
    if not ctx then
        UIManager:show(InfoMessage:new{ text = err or _("Could not read document."), timeout = 5 })
        return
    end

    local raw_text   = self:_buildRawText(ctx)
    local template   = loadPrompt("themes.lua") or self:cfg("system_prompt")
    local sys_prompt = applyTemplate(template, {
        book_title         = ctx.title,
        author_name        = ctx.author,
        chapter_name       = ctx.chapter,
        raw_extracted_text = raw_text,
    })
    local user_msg = string.format(
        "I am reading '%s' by %s, currently in chapter '%s'. Please list the themes as instructed.",
        ctx.title, ctx.author, ctx.chapter)

    self:_dispatchRequest(sys_prompt, user_msg, _("Themes — ") .. ctx.title, #raw_text)
end
```

### Step 3 — Restart KOReader

The new **Themes** option appears under **Book Recap** in the menu.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| "Please set your API key first." | Add your key in **Book Recap → Settings → API Key** or in `recap_config.lua` |
| "API error: ..." | Check that your API URL and model name are correct for your provider |
| "Network error" | Ensure the device has internet access; for Ollama, confirm the server is running |
| "Required libraries missing" | Your KOReader build may lack `luasocket`/`luasec` — try an official nightly build |
| Recap has wrong chapter | The plugin reads the table of contents; books without a TOC fall back to "Unknown Chapter" |
| Empty or garbled recap text | The raw text scraper works best on reflowable EPUB; scanned PDFs may return little usable text |
