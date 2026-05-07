--[[
koreader2zotero — KOReader plugin that syncs highlights to Zotero.

Installation: copy the zotero.koplugin directory into KOReader's plugins folder
  (~/.config/koreader/plugins/ on Linux/Android, or wherever koreader.sh lives).

Setup: Tools > Zotero > Settings
  - API key:  https://www.zotero.org/settings/keys  (needs read/write on your library)
  - User ID:  same page, shown above your keys

Auto-sync fires when you close a document. Manual sync is in the Zotero menu.
--]]

local InfoMessage   = require("ui/widget/infomessage")
local InputDialog   = require("ui/widget/inputdialog")
local UIManager     = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger        = require("logger")
local _             = require("gettext")

local ZoteroAPI  = require("api")
local ZoteroSync = require("sync")

local ZoteroPlugin = WidgetContainer:extend{
    name        = "zotero",
    is_doc_only = false,
}

-- ── Settings helpers ──────────────────────────────────────────────────────────

function ZoteroPlugin:getSettings()
    return G_reader_settings:readSetting("zotero") or {}
end

function ZoteroPlugin:saveSettings(s)
    G_reader_settings:saveSetting("zotero", s)
end

function ZoteroPlugin:isConfigured()
    local s = self:getSettings()
    return s.api_key and s.api_key ~= "" and s.user_id and s.user_id ~= ""
end

-- ── Plugin lifecycle ──────────────────────────────────────────────────────────

function ZoteroPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function ZoteroPlugin:addToMainMenu(menu_items)
    menu_items.zotero = {
        text = _("Zotero"),
        sub_item_table = {
            {
                text         = _("Sync current book"),
                enabled_func = function()
                    return self.ui.document ~= nil and self:isConfigured()
                end,
                callback = function()
                    self:syncCurrentBook(false)
                end,
            },
            {
                text         = _("Sync all books"),
                enabled_func = function() return self:isConfigured() end,
                callback     = function() self:syncAllBooks() end,
            },
            {
                text         = _("Backfill metadata from Calibre"),
                enabled_func = function()
                    local s = self:getSettings()
                    return self:isConfigured()
                        and s.calibre_url ~= nil and s.calibre_url ~= ""
                end,
                callback = function()
                    local sync = self:_makeSync()
                    local _, msg = sync:backfillMetadata()
                    UIManager:show(InfoMessage:new{ text = msg })
                end,
            },
            { text = "---", separator = true },
            {
                text         = _("Auto-sync on close"),
                checked_func = function()
                    return self:getSettings().auto_sync ~= false
                end,
                callback = function()
                    local s = self:getSettings()
                    s.auto_sync = not (s.auto_sync ~= false)
                    self:saveSettings(s)
                end,
            },
            {
                text     = _("Settings"),
                callback = function() self:showAPIKeyDialog() end,
            },
        },
    }
end

-- Hook called by KOReader when the current document is about to close.
function ZoteroPlugin:onCloseDocument()
    local s = self:getSettings()
    if s.auto_sync == false then return end
    if not self:isConfigured() then return end
    self:syncCurrentBook(true)  -- silent: no UI message on success
end

-- ── Sync actions ──────────────────────────────────────────────────────────────

function ZoteroPlugin:_makeSync()
    local s = self:getSettings()
    local api = ZoteroAPI:new(s.user_id, s.api_key)
    return ZoteroSync:new(
        api,
        function() return self:getSettings() end,
        function(new_s) self:saveSettings(new_s) end)
end

function ZoteroPlugin:syncCurrentBook(silent)
    if not self.ui.document then return end

    local file_path = self.ui.document.file

    -- Prefer live in-memory annotations over sidecar (not yet flushed to disk).
    local annotations = self.ui.annotation and self.ui.annotation.annotations
    if not annotations or #annotations == 0 then
        if not silent then
            UIManager:show(InfoMessage:new{ text = _("No highlights in this document") })
        end
        return
    end

    local props  = self.ui.doc_props or {}
    local title  = (props.title  ~= nil and props.title  ~= "") and props.title  or nil
    local author = (props.authors ~= nil and props.authors ~= "") and props.authors or nil

    if not title then
        local fname = file_path:match("([^/]+)$") or file_path
        title = fname:gsub("%.[^.]+$", "")
    end

    local book_data = {
        file_path  = file_path,
        title      = title  or "Unknown Title",
        author     = author or "Unknown Author",
        annotations = annotations,
    }

    local sync = self:_makeSync()
    local ok, msg = sync:syncBook(book_data)

    if not silent then
        UIManager:show(InfoMessage:new{ text = ok and msg or (_("Sync failed: ") .. msg) })
    elseif not ok then
        logger.warn("ZoteroPlugin: auto-sync failed:", msg)
    end
end

function ZoteroPlugin:syncAllBooks()
    local history = require("readhistory").hist
    if not history or #history == 0 then
        UIManager:show(InfoMessage:new{ text = _("Reading history is empty") })
        return
    end

    local sync    = self:_makeSync()
    local n_ok    = 0
    local errors  = {}

    for _, item in ipairs(history) do
        if not item.dim and item.file then
            local book_data = sync:getBookData(item.file)
            if book_data then
                local ok, msg = sync:syncBook(book_data)
                if ok then
                    n_ok = n_ok + 1
                else
                    table.insert(errors, (book_data.title or item.file) .. ": " .. msg)
                end
            end
        end
    end

    local summary
    if #errors == 0 then
        summary = string.format(_("Synced %d book(s) to Zotero"), n_ok)
    else
        summary = string.format(_("Synced %d book(s). %d error(s):\n%s"),
            n_ok, #errors, table.concat(errors, "\n"):sub(1, 400))
    end
    UIManager:show(InfoMessage:new{ text = summary })
end

-- ── Settings UI ───────────────────────────────────────────────────────────────

function ZoteroPlugin:showAPIKeyDialog()
    local s = self:getSettings()
    local dlg
    dlg = InputDialog:new{
        title       = _("Zotero API Key"),
        description = _("zotero.org/settings/keys — needs read/write library access"),
        input       = s.api_key or "",
        input_type  = "string",
        buttons     = {{
            {
                text     = _("Cancel"),
                callback = function() UIManager:close(dlg) end,
            },
            {
                text             = _("Next"),
                is_enter_default = true,
                callback         = function()
                    s.api_key = dlg:getInputText()
                    UIManager:close(dlg)
                    self:showUserIDDialog(s)
                end,
            },
        }},
    }
    UIManager:show(dlg)
end

function ZoteroPlugin:showUserIDDialog(s)
    local dlg
    dlg = InputDialog:new{
        title       = _("Zotero User ID"),
        description = _("Numeric ID shown at zotero.org/settings/keys"),
        input       = s.user_id or "",
        input_type  = "string",
        buttons     = {{
            {
                text     = _("Back"),
                callback = function()
                    UIManager:close(dlg)
                    self:showAPIKeyDialog()
                end,
            },
            {
                text             = _("Save"),
                is_enter_default = true,
                callback         = function()
                    s.user_id = dlg:getInputText()
                    UIManager:close(dlg)
                    if s.api_key ~= "" and s.user_id ~= "" then
                        if s.auto_sync == nil then s.auto_sync = true end
                        self:showCalibreURLDialog(s)
                    end
                end,
            },
        }},
    }
    UIManager:show(dlg)
end

function ZoteroPlugin:showCalibreURLDialog(s)
    local dlg
    dlg = InputDialog:new{
        title       = _("Calibre Server URL (optional)"),
        description = _("e.g. http://192.168.1.100:8080 — fetches ISBN and publisher when creating Zotero items. Leave blank to skip."),
        input       = s.calibre_url or "",
        input_type  = "string",
        buttons     = {{
            {
                text     = _("Skip"),
                callback = function()
                    UIManager:close(dlg)
                    self:saveSettings(s)
                    UIManager:show(InfoMessage:new{
                        text = _("Zotero configured. Auto-sync on document close is on.")
                    })
                end,
            },
            {
                text             = _("Save"),
                is_enter_default = true,
                callback         = function()
                    local url = dlg:getInputText():gsub("/+$", "")
                    s.calibre_url = (url ~= "") and url or nil
                    UIManager:close(dlg)
                    self:saveSettings(s)
                    UIManager:show(InfoMessage:new{
                        text = _("Zotero configured. Auto-sync on document close is on.")
                    })
                end,
            },
        }},
    }
    UIManager:show(dlg)
end

return ZoteroPlugin
