--[[
Sync logic: reads KOReader annotations for a book and pushes new highlights
to a Zotero child note, creating the Zotero book item if needed.

Settings structure (stored under G_reader_settings key "zotero"):
{
    api_key = "...",
    user_id = "...",
    auto_sync = true,
    books = {
        ["/path/to/book.epub"] = {
            zotero_item_key = "ABC123",   -- parent book item in Zotero
            note_key        = "DEF456",   -- highlights note item in Zotero
            synced_datetimes = {"2024-01-15 14:30:00", ...},
        }
    }
}
--]]

local DocSettings = require("docsettings")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local http  = require("socket.http")
local https = require("ssl.https")
local logger = require("logger")

local ZoteroSync = {}
ZoteroSync.__index = ZoteroSync

-- ── HTML helpers ──────────────────────────────────────────────────────────────

local function esc(s)
    if not s then return "" end
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    return s
end


-- Render a list of annotation objects into an HTML fragment, grouped by chapter.
local function renderHTML(annotations)
    -- Group into ordered chapter buckets
    local buckets = {}      -- ordered list of {chapter, items}
    local seen = {}         -- key -> bucket index
    for _, ann in ipairs(annotations) do
        local ch = (ann.chapter and ann.chapter ~= "") and ann.chapter or false
        local key = ch or "__none__"
        if not seen[key] then
            seen[key] = #buckets + 1
            table.insert(buckets, { chapter = ch, items = {} })
        end
        table.insert(buckets[seen[key]].items, ann)
    end

    local parts = {}
    for _, bucket in ipairs(buckets) do
        if bucket.chapter then
            table.insert(parts, "<h3>" .. esc(bucket.chapter) .. "</h3>")
        end
        for _, ann in ipairs(bucket.items) do
            if ann.text and ann.text ~= "" then
                table.insert(parts, "<blockquote>" .. esc(ann.text) .. "</blockquote>")

                if ann.note and ann.note ~= "" then
                    table.insert(parts, "<p><em>" .. esc(ann.note) .. "</em></p>")
                end
            end
        end
    end
    return table.concat(parts, "\n")
end

-- ── ZoteroSync ────────────────────────────────────────────────────────────────

function ZoteroSync:new(api, get_settings, save_settings)
    return setmetatable({
        api          = api,
        getSettings  = get_settings,
        saveSettings = save_settings,
    }, self)
end

-- Read annotations and metadata for a book by file path.
-- Returns a book_data table, or nil if the book has no sidecar / no annotations.
function ZoteroSync:getBookData(file_path)
    if not DocSettings:hasSidecarFile(file_path) then return nil end

    local doc_settings = DocSettings:open(file_path)
    if not doc_settings then return nil end

    local annotations = doc_settings:readSetting("annotations")
    if not annotations then
        -- Legacy (pre-annotations API) format is not supported; skip silently.
        logger.info("ZoteroSync: skipping legacy highlight format for", file_path)
        return nil
    end

    if #annotations == 0 then return nil end

    local props = doc_settings:readSetting("doc_props") or {}

    local title = (props.title ~= nil and props.title ~= "") and props.title or nil
    if not title then
        local fname = file_path:match("([^/]+)$") or file_path
        title = fname:gsub("%.[^.]+$", "")
    end

    local author = (props.authors ~= nil and props.authors ~= "") and props.authors or nil

    local isbn = nil
    if type(props.identifiers) == "table" then
        isbn = props.identifiers.isbn or props.identifiers.ISBN
    end

    return {
        file_path  = file_path,
        title      = title or "Unknown Title",
        author     = author or "Unknown Author",
        isbn       = isbn,
        annotations = annotations,
    }
end

-- Shared HTTP GET for Calibre's JSON API. Returns decoded table + err string.
function ZoteroSync:_calibreGet(url)
    local sink = {}
    local requester = url:sub(1, 5) == "https" and https or http
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code = requester.request{ url = url, sink = ltn12.sink.table(sink) }
    socketutil:reset_timeout()
    local body = table.concat(sink)
    if not ok then
        return nil, "connection failed: " .. tostring(code)
    end
    if code ~= 200 then
        return nil, string.format("HTTP %d — %s", code, body:sub(1, 120))
    end
    local data, err = rapidjson.decode(body)
    if not data then
        return nil, "JSON decode failed: " .. tostring(err) .. " body: " .. body:sub(1, 120)
    end
    return data, nil
end

-- Normalise the saved URL: strip trailing slash and /opds suffix.
-- Returns base_url, lib_id (raw string or "").
-- Callers build URLs as needed:
--   search: base .. "/ajax/search/" .. lib_id .. "?..."  (lib_id in path)
--   books:  base .. "/ajax/books/" .. id .. "?library_id=" .. lib_id  (lib_id as query param)
function ZoteroSync:_calibreBaseURL()
    local settings = self.getSettings()
    local url = settings.calibre_url
    if not url or url == "" then return nil end
    local base = url:gsub("/+$", ""):gsub("/opds$", "")
    local lib_id = settings.calibre_library_id or ""
    return base, lib_id
end

local function calibreSearchURL(base, lib_id, query, num)
    local path = lib_id ~= "" and ("/ajax/search/" .. lib_id) or "/ajax/search"
    return base .. path .. "?query=" .. socket.url.escape(query) .. "&num=" .. tostring(num)
end

local function calibreBooksURL(base, lib_id, book_id)
    if lib_id ~= "" then
        return base .. "/ajax/books/" .. lib_id .. "?ids=" .. tostring(book_id)
    end
    return base .. "/ajax/books/" .. tostring(book_id)
end

-- Probe the Zotero API and return a human-readable status string.
function ZoteroSync:testZoteroConnection()
    local data, headers, err = self.api:_request("GET", "/items?limit=1")
    if err then
        return "Failed to connect to Zotero.\n\nError: " .. err
    end
    local total   = headers and headers["total-results"]        or "?"
    local version = headers and headers["last-modified-version"] or "?"
    return string.format(
        "Connected to Zotero.\nLibrary version: %s\nTotal items: %s",
        tostring(version), tostring(total))
end

-- Probe the Calibre server and return a human-readable status string.
function ZoteroSync:testCalibreConnection()
    local base, lib = self:_calibreBaseURL()
    if not base then return "No Calibre URL configured." end

    local data, err = self:_calibreGet(calibreSearchURL(base, lib, "*", 1))
    if err then
        return "Failed to reach Calibre at " .. base .. "\n\nError: " .. err
    end
    local total = data.num_books_without_search or data.total_num or "?"
    return string.format("Connected to Calibre at %s\n%s book(s) in library.", base, tostring(total))
end

-- Query the Calibre content server for richer book metadata.
-- Returns (meta_table, err_string). On success err is nil; on failure meta is nil.
function ZoteroSync:_fetchCalibreMetadata(title)
    local base, lib = self:_calibreBaseURL()
    if not base then return nil, "no Calibre URL" end

    -- Strip subtitle (everything after first colon or em-dash) for the search
    -- query, since Calibre uses colon as field separator and it breaks parsing.
    local short_title = title:match("^(.-)%s*[:%—–]") or title

    local search, err
    for _, q in ipairs({
        'title:"' .. short_title .. '"',
        'title:"' .. title .. '"',
        "title:" .. short_title,
    }) do
        search, err = self:_calibreGet(calibreSearchURL(base, lib, q, 5))
        if not err and search and search.book_ids and #search.book_ids > 0 then break end
    end
    if not search or not search.book_ids or #search.book_ids == 0 then
        return nil, string.format("no results (tried short title %q, full title %q)", short_title, title)
    end

    -- Fetch metadata for the first result
    local book_id = tostring(search.book_ids[1])
    local books, books_err = self:_calibreGet(calibreBooksURL(base, lib, book_id))
    if books_err then return nil, "books request failed: " .. books_err end
    if not books[book_id] then
        return nil, "book id " .. book_id .. " missing from response"
    end

    local m = books[book_id]
    local ids = type(m.identifiers) == "table" and m.identifiers or {}
    local isbn = ids.isbn or ids.ISBN or ids.isbn13 or ids.isbn10
    return {
        authors     = m.authors,
        isbn        = isbn,
        publisher   = m.publisher,
        date        = m.pubdate and m.pubdate:match("(%d%d%d%d)"),
        identifiers = ids,
        -- keep raw fields for diagnostics
        _raw_title  = m.title,
        _raw_ids    = ids,
    }, nil
end

-- Search Calibre for a title and return a diagnostic string showing what was found.
function ZoteroSync:diagnoseCalibreSearch(title)
    local base, lib = self:_calibreBaseURL()
    if not base then return "No Calibre URL configured." end

    local short_title = title:match("^(.-)%s*[:%—–]") or title
    local search, err
    local tried = {}
    for _, q in ipairs({
        'title:"' .. short_title .. '"',
        'title:"' .. title .. '"',
        "title:" .. short_title,
    }) do
        table.insert(tried, q)
        search, err = self:_calibreGet(calibreSearchURL(base, lib, q, 5))
        if not err and search and search.book_ids and #search.book_ids > 0 then break end
    end
    if not search or not search.book_ids or #search.book_ids == 0 then
        return "No results found.\nTried:\n" .. table.concat(tried, "\n")
    end

    local book_id = tostring(search.book_ids[1])
    local books, books_err = self:_calibreGet(calibreBooksURL(base, lib, book_id))
    if books_err then return "Books fetch failed: " .. books_err end
    if not books[book_id] then return "Book " .. book_id .. " missing from response" end

    local m = books[book_id]
    local ids = type(m.identifiers) == "table" and m.identifiers or {}

    local id_parts = {}
    for k, v in pairs(ids) do
        table.insert(id_parts, k .. "=" .. tostring(v))
    end

    return string.format(
        "Found: %s\nIdentifiers: %s\nPublisher: %s\nDate: %s",
        tostring(m.title),
        #id_parts > 0 and table.concat(id_parts, ", ") or "(none)",
        tostring(m.publisher or ""),
        tostring(m.pubdate or ""))
end

-- Search Zotero for a book item matching title. Returns key or nil.
function ZoteroSync:_findZoteroItem(title)
    local results, _, err = self.api:searchItems(title, "book")
    if err then
        logger.warn("ZoteroSync: search error:", err)
        return nil, err
    end
    if not results or #results == 0 then return nil, nil end

    local title_lower = title:lower()
    -- Prefer exact title match
    for _, item in ipairs(results) do
        local d = item.data or {}
        if type(d.title) == "string" and d.title:lower() == title_lower then
            return d.key, nil
        end
    end
    -- Fall back to first result
    local d = results[1].data or {}
    return d.key, nil
end

-- Create a new Zotero book item. Returns key or nil + err.
function ZoteroSync:_createZoteroItem(book_data)
    local creators = {}
    if book_data.author ~= "Unknown Author" then
        for name in book_data.author:gmatch("[^\n]+") do
            name = name:match("^%s*(.-)%s*$")
            if name ~= "" then
                table.insert(creators, { creatorType = "author", name = name })
            end
        end
    end

    local item = {
        itemType = "book",
        title    = book_data.title,
        extra    = "Added by koreader2zotero",
    }
    -- Only include creators if non-empty; rapidjson encodes {} as object not array
    if #creators > 0 then
        item.creators = creators
    end
    if book_data.isbn      then item.ISBN      = book_data.isbn      end
    if book_data.publisher then item.publisher = book_data.publisher end
    if book_data.date      then item.date      = book_data.date      end

    local resp, _, err = self.api:createItems({item})
    if err then return nil, err end

    local created = resp.success and resp.success["0"]
    if not created then
        local failed = resp.failed and resp.failed["0"]
        return nil, "Create failed: " .. (failed and tostring(failed.message) or "unknown")
    end
    return created, nil
end

-- Main entry point. Syncs new highlights for the given book_data table.
-- Returns ok (bool), message (string).
function ZoteroSync:syncBook(book_data)
    local settings  = self.getSettings()
    local books     = settings.books or {}
    local info      = books[book_data.file_path] or {}

    -- 1. Resolve Zotero item key
    local zotero_key = info.zotero_item_key
    if not zotero_key then
        local found, err = self:_findZoteroItem(book_data.title)
        if err then return false, "Search error: " .. err end

        if found then
            zotero_key = found
        else
            -- Enrich metadata from Calibre before creating the item
            local cal, cal_err = self:_fetchCalibreMetadata(book_data.title)
            if cal_err then logger.info("ZoteroSync: Calibre lookup skipped:", cal_err) end
            if cal then
                if cal.isbn      then book_data.isbn      = cal.isbn      end
                if cal.publisher then book_data.publisher = cal.publisher end
                if cal.date      then book_data.date      = cal.date      end
                -- Use Calibre's author list if we only have a fallback
                if book_data.author == "Unknown Author"
                        and cal.authors and #cal.authors > 0 then
                    book_data.author = table.concat(cal.authors, "\n")
                end
            end
            local new_key, create_err = self:_createZoteroItem(book_data)
            if create_err then return false, "Could not create Zotero item: " .. create_err end
            zotero_key = new_key
        end
        info.zotero_item_key = zotero_key
    end

    -- 2. Filter to unseen annotations
    local synced_set = {}
    for _, dt in ipairs(info.synced_datetimes or {}) do
        synced_set[dt] = true
    end

    local new_anns = {}
    for _, ann in ipairs(book_data.annotations) do
        if ann.text and ann.text ~= "" and not synced_set[ann.datetime] then
            table.insert(new_anns, ann)
        end
    end

    if #new_anns == 0 then
        return true, "No new highlights"
    end

    -- 3. Render HTML for new highlights
    local html_fragment = renderHTML(new_anns)

    -- 4. Append to existing note or create new one
    local note_key = info.note_key
    local append_ok = false

    if note_key then
        local note, _, err = self.api:getItem(note_key)
        if not err and note and note.data then
            local version  = note.data.version
            local existing = note.data.note or ""
            local separator = string.format(
                "\n<hr/>\n<p><small><em>Synced from KOReader — %s</em></small></p>\n",
                os.date("%Y-%m-%d"))
            local _, _, patch_err = self.api:patchNote(
                note_key, existing .. separator .. html_fragment, version)
            if not patch_err then
                append_ok = true
            else
                logger.warn("ZoteroSync: patch failed, will recreate note:", patch_err)
                note_key = nil
            end
        else
            note_key = nil  -- note was deleted; create fresh
        end
    end

    if not append_ok then
        local header = string.format(
            "<h1>%s</h1>\n<p>by %s</p>\n<hr/>\n",
            esc(book_data.title), esc(book_data.author))
        local resp, _, err = self.api:createNote(zotero_key, header .. html_fragment)
        if err then return false, "Could not create note: " .. err end

        local created = resp.success and resp.success["0"]
        if not created then
            return false, "Zotero did not confirm note creation"
        end
        note_key = created
        info.note_key = note_key
    end

    -- 5. Persist state
    local synced = info.synced_datetimes or {}
    for _, ann in ipairs(new_anns) do
        if ann.datetime then
            table.insert(synced, ann.datetime)
        end
    end
    info.synced_datetimes = synced
    info.note_key         = note_key
    info.zotero_item_key  = zotero_key

    books[book_data.file_path] = info
    settings.books = books
    self.saveSettings(settings)

    return true, string.format("Synced %d highlight(s)", #new_anns)
end

-- For each previously synced book that is missing ISBN in Zotero, fetch
-- metadata from Calibre and PATCH the Zotero item. Skips items that already
-- have an ISBN. Requires calibre_url to be configured.
-- Returns ok (bool), message (string).
function ZoteroSync:backfillMetadata()
    local settings = self.getSettings()
    if not settings.calibre_url or settings.calibre_url == "" then
        return false, "No Calibre server URL configured (Tools > Zotero > Settings)"
    end

    local books = settings.books or {}
    local n_updated, n_has_isbn, n_no_match = 0, 0, 0
    local errors = {}

    for _, info in pairs(books) do
        local zotero_key = info.zotero_item_key
        if not zotero_key then goto continue end

        local item, _, err = self.api:getItem(zotero_key)
        if err or not item or not item.data then
            table.insert(errors, zotero_key .. ": " .. tostring(err))
            goto continue
        end

        local data = item.data

        -- Skip if ISBN is already present
        if data.ISBN and data.ISBN ~= "" then
            n_has_isbn = n_has_isbn + 1
            goto continue
        end

        local cal, cal_err = self:_fetchCalibreMetadata(data.title or "")
        if not cal then
            n_no_match = n_no_match + 1
            table.insert(errors, (data.title or zotero_key) .. ": " .. (cal_err or "no match"))
            goto continue
        end

        local patch = { itemType = data.itemType }
        if cal.isbn      then patch.ISBN      = cal.isbn      end
        if cal.publisher then patch.publisher = cal.publisher end
        if cal.date      then patch.date      = cal.date      end

        if not cal.isbn and not cal.publisher and not cal.date then
            n_no_match = n_no_match + 1
            table.insert(errors, (data.title or zotero_key) .. ": Calibre returned no metadata")
            goto continue
        end

        local _, _, patch_err = self.api:patchItem(zotero_key, patch, data.version)
        if patch_err then
            table.insert(errors, (data.title or zotero_key) .. ": " .. patch_err)
        else
            n_updated = n_updated + 1
        end

        ::continue::
    end

    local msg = string.format("Updated %d, skipped %d (already had ISBN), no Calibre match: %d",
        n_updated, n_has_isbn, n_no_match)
    if #errors > 0 then
        msg = msg .. "\n" .. table.concat(errors, "\n"):sub(1, 400)
    end
    return true, msg
end

return ZoteroSync
