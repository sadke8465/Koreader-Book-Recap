--[[
    recap.koplugin/_meta.lua
    Plugin metadata — loaded by KOReader's plugin manager before main.lua
    to display info in the plugin list without fully loading the plugin.
--]]

return {
    name        = "recap",
    fullname    = _("Book Recap"),
    description = _([[Generate a spoiler-free AI recap of your current reading position.

Extracts the book title, author, current chapter, and recent page text,
then sends that context to an OpenAI-compatible API and displays the
resulting summary in a scrollable viewer.]]),
    is_doc_only = false,
}
