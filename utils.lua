local json = require("json")
local logger = require("logger")

local M = {}

function M.read_json(path)
    local f = io.open(path, "r")
    if not f then
        return {}
    end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then
        return {}
    end

    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then
        return data
    end
    return {}
end

return M
