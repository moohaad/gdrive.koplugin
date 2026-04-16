--- GDrive sync service: handles download, 3-way merge, upload via Google Drive.
--- Mirrors SyncService's 3-file protocol but uses GDrive as the backend.

local M = {}

--- Perform a full 3-way sync cycle for a JSON annotations file via GDrive.
---
--- Protocol (same as SyncService):
---   local_file   = the current annotations JSON
---   cached_file  = local_file .. ".sync"  (snapshot from last upload)
---   income_file  = local_file .. ".temp"  (downloaded from GDrive, deleted after merge)
---
--- @param network      the network module (already required)
--- @param token        GDrive access token
--- @param local_file   path to the local JSON annotations file
--- @param remote_name  filename on GDrive (e.g., "{hash}.json")
--- @param folder_id    GDrive folder ID for annotations
--- @param sync_cb      function(local_file, cached_file, income_file) → true on success
--- @return boolean success
function M.sync(network, token, local_file, remote_name, folder_id, sync_cb)
    local cached_file = local_file .. ".sync"
    local income_file = local_file .. ".temp"

    os.remove(income_file)
    local remote_file = network.findFile(token, remote_name, folder_id)
    if remote_file then
        network.downloadFileSync(token, remote_file.id, income_file)
    end

    local ok, err = pcall(sync_cb, local_file, cached_file, income_file)
    if not ok then
        os.remove(income_file)
        return false
    end

    local upload_ok
    if remote_file then
        upload_ok = network.updateFile(token, remote_file.id, local_file)
    else
        upload_ok = network.uploadFile(token, local_file, remote_name, folder_id)
    end

    os.remove(income_file)
    if upload_ok then
        local src = io.open(local_file, "r")
        if src then
            local content = src:read("*a")
            src:close()
            local dst = io.open(cached_file, "w")
            if dst then
                dst:write(content)
                dst:close()
            end
        end
        return true
    end
    return false
end

return M
