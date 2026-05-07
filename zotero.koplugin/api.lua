--[[
Zotero REST API v3 client.
All methods return (data, headers, err). On success, err is nil.
On failure, data is nil and err is a string.
--]]

local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local https = require("ssl.https")

local BASE_URL = "https://api.zotero.org"

local ZoteroAPI = {}
ZoteroAPI.__index = ZoteroAPI

function ZoteroAPI:new(user_id, api_key)
    return setmetatable({
        user_id = user_id,
        api_key = api_key,
    }, self)
end

function ZoteroAPI:_request(method, path, body, extra_headers)
    local url = BASE_URL .. "/users/" .. self.user_id .. path

    local headers = {
        ["Zotero-API-Version"] = "3",
        ["Zotero-API-Key"] = self.api_key,
        ["User-Agent"] = "koreader2zotero/1.0",
    }
    for k, v in pairs(extra_headers or {}) do
        headers[k] = v
    end

    local sink = {}
    local source

    if body ~= nil then
        local body_json, err = rapidjson.encode(body)
        if not body_json then
            return nil, nil, "Failed to encode body: " .. tostring(err)
        end
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = #body_json
        source = ltn12.source.string(body_json)
    end

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, resp_headers, status = https.request{
        url = url,
        method = method,
        headers = headers,
        source = source,
        sink = ltn12.sink.table(sink),
    }
    socketutil:reset_timeout()

    if not ok then
        return nil, nil, "Network error: " .. tostring(code)
    end

    -- 204 = success, no body (PATCH/PUT)
    if code == 204 then
        return {}, resp_headers, nil
    end

    if code ~= 200 and code ~= 201 then
        local body_str = table.concat(sink)
        return nil, resp_headers, string.format("HTTP %d: %s — %s",
            code, tostring(status), body_str:sub(1, 200))
    end

    local body_str = table.concat(sink)
    if body_str == "" then
        return {}, resp_headers, nil
    end

    local data, err = rapidjson.decode(body_str)
    if not data then
        return nil, resp_headers, "Failed to decode response: " .. tostring(err)
    end

    return data, resp_headers, nil
end

-- Search for items. item_type is optional (e.g. "book").
function ZoteroAPI:searchItems(query, item_type)
    local path = "/items?q=" .. socket.url.escape(query) .. "&limit=25"
    if item_type then
        path = path .. "&itemType=" .. item_type
    end
    return self:_request("GET", path)
end

-- Create one or more items. items_array is a Lua array of item objects.
-- Returns response with success/failed tables.
function ZoteroAPI:createItems(items_array)
    return self:_request("POST", "/items", items_array)
end

-- Get a single item by key.
function ZoteroAPI:getItem(item_key)
    return self:_request("GET", "/items/" .. item_key)
end

-- Patch an existing item with partial fields. version from data.version on GET.
function ZoteroAPI:patchItem(item_key, fields, version)
    return self:_request("PATCH", "/items/" .. item_key, fields,
        { ["If-Unmodified-Since-Version"] = tostring(version) })
end

-- Get note children of an item.
function ZoteroAPI:getChildNotes(item_key)
    return self:_request("GET", "/items/" .. item_key .. "/children?itemType=note")
end

-- Create a note as a child of parent_key.
function ZoteroAPI:createNote(parent_key, html_content)
    local items = {
        {
            itemType   = "note",
            parentItem = parent_key,
            note       = html_content,
        }
    }
    return self:_request("POST", "/items", items)
end

-- Append html_content to an existing note. version comes from data.version on GET.
function ZoteroAPI:patchNote(note_key, html_content, version)
    return self:_request("PATCH", "/items/" .. note_key,
        { itemType = "note", note = html_content },
        { ["If-Unmodified-Since-Version"] = tostring(version) })
end

return ZoteroAPI
