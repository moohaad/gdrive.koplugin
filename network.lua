local json = require("json")
local ltn12 = require("ltn12")

local M = {}

local TOKEN_URL = "https://oauth2.googleapis.com/token"

function M.request(params)
    local ok, https = pcall(require, "ssl.https")
    if not ok then return nil, 0, "SSL module missing" end
    
    local response_body = {}
    local request_params = {
        url = params.url,
        method = params.method or "GET",
        headers = params.headers or {},
        sink = ltn12.sink.table(response_body),
        protocol = "tlsv1_2",
        verify = "none",
    }
    
    request_params.headers["User-Agent"] = "KOReader/GDrive"
    request_params.headers["Accept"] = "application/json"

    if params.body then
        request_params.source = ltn12.source.string(params.body)
        request_params.headers["Content-Length"] = #params.body
    end
    
    local ok_req, res, code, headers, status = pcall(https.request, request_params)
    if not ok_req then return nil, 0, tostring(res) end
    
    return table.concat(response_body), code, status
end

function M.refreshToken(client_id, client_secret, refresh_token)
    local body = string.format(
        "client_id=%s&client_secret=%s&refresh_token=%s&grant_type=refresh_token", 
        client_id, client_secret, refresh_token
    )
    local res_body, code, status = M.request({
        url = TOKEN_URL,
        method = "POST",
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        body = body
    })
    
    if not res_body or res_body == "" then return nil, "Conn Error: " .. tostring(status) end
    local ok, data = pcall(json.decode, res_body)
    if ok and data and data.access_token then return data end
    return nil, "Refresh Failed"
end

function M.findFile(access_token, name, parent_id)
    local q = string.format("name = '%s' and trashed = false", name)
    if parent_id then
        q = q .. string.format(" and '%s' in parents", parent_id)
    end
    local q_enc = q:gsub(" ", "%%20"):gsub("'", "%%27"):gsub("=", "%%3D")
    local url = "https://www.googleapis.com/drive/v3/files?fields=files(id,name,mimeType,modifiedTime)&q=" .. q_enc
    
    local res_body, code = M.request({
        url = url,
        headers = { ["Authorization"] = "Bearer " .. access_token }
    })
    
    local ok, data = pcall(json.decode, res_body or "")
    if ok and data and data.files and #data.files > 0 then
        return data.files[1]
    end
    return nil
end

function M.listFiles(access_token, folder_id)
    local q = folder_id and ("'" .. folder_id .. "' in parents and trashed = false") or "'root' in parents and trashed = false"
    local q_enc = q:gsub(" ", "%%20"):gsub("'", "%%27"):gsub("=", "%%3D")
    local url = "https://www.googleapis.com/drive/v3/files?pageSize=100&fields=files(id,name,mimeType,size)&q=" .. q_enc
    
    local res_body, code = M.request({
        url = url,
        headers = { ["Authorization"] = "Bearer " .. access_token }
    })
    
    if not res_body then return nil, "Network Error" end
    local ok, data = pcall(json.decode, res_body)
    if ok and data and data.files then return data end
    return nil, "Parse Error"
end

function M.uploadFile(access_token, local_path, name, parent_id)
    local f = io.open(local_path, "rb")
    if not f then return false end
    local file_content = f:read("*a")
    f:close()
    if not file_content then return false end

    local metadata = {
        name = name,
        parents = parent_id and {parent_id} or nil
    }
    local meta_json = json.encode(metadata)
    local boundary = "gdrive_boundary_" .. tostring(os.time())
    local body = "--" .. boundary .. "\r\n"
        .. "Content-Type: application/json; charset=UTF-8\r\n\r\n"
        .. meta_json .. "\r\n"
        .. "--" .. boundary .. "\r\n"
        .. "Content-Type: application/octet-stream\r\n\r\n"
        .. file_content .. "\r\n"
        .. "--" .. boundary .. "--"

    local url = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart"
    local res_body, code = M.request({
        url = url,
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. access_token,
            ["Content-Type"] = "multipart/related; boundary=" .. boundary,
        },
        body = body,
    })

    local ok, data = pcall(json.decode, res_body or "")
    return ok and data and data.id ~= nil
end

function M.updateFile(access_token, file_id, local_path)
    local f = io.open(local_path, "rb")
    if not f then return false end
    local file_content = f:read("*a")
    f:close()
    if not file_content then return false end

    local url = string.format("https://www.googleapis.com/upload/drive/v3/files/%s?uploadType=media", file_id)
    local res_body, code = M.request({
        url = url,
        method = "PATCH",
        headers = {
            ["Authorization"] = "Bearer " .. access_token,
            ["Content-Type"] = "application/octet-stream",
        },
        body = file_content,
    })

    local ok, data = pcall(json.decode, res_body or "")
    return ok and data and data.id ~= nil
end

function M.createFolder(access_token, name, parent_id)
    local url = "https://www.googleapis.com/drive/v3/files"
    local metadata = {
        name = name,
        mimeType = "application/vnd.google-apps.folder",
        parents = parent_id and {parent_id} or nil
    }
    
    local res_body, code = M.request({
        url = url,
        method = "POST",
        headers = { 
            ["Authorization"] = "Bearer " .. access_token,
            ["Content-Type"] = "application/json"
        },
        body = json.encode(metadata)
    })
    
    local ok, data = pcall(json.decode, res_body or "")
    if ok and data and data.id then return data.id end
    return nil
end

function M.downloadFileSync(access_token, file_id, dest_path)
    local url = string.format("https://www.googleapis.com/drive/v3/files/%s?alt=media", file_id)
    local res_body, code = M.request({
        url = url,
        headers = { ["Authorization"] = "Bearer " .. access_token }
    })
    if code == 200 and res_body then
        local f = io.open(dest_path, "wb")
        if f then
            f:write(res_body)
            f:close()
            return true
        end
    end
    return false
end

return M
