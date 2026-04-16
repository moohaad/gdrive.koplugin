--- Reading progress push/pull for GDrive plugin.
--- Separate from annotation sync — uses its own JSON file on GDrive.
--- Follows KOSync patterns: push current position, pull & navigate.

local json = require("json")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")

local M = {}

function M.get_current_progress(ui)
    if not ui or not ui.document then return nil end
    local progress_val, percent_val
    if ui.document.info.has_pages then
        if ui.paging then
            progress_val = ui.paging:getLastProgress()
            percent_val = ui.paging:getLastPercent()
        end
    else
        if ui.rolling then
            progress_val = ui.rolling:getLastProgress()
            percent_val = ui.rolling:getLastPercent()
        end
    end
    if not progress_val then return nil end
    return {
        progress = progress_val,
        percentage = percent_val or 0,
        timestamp = os.time(),
    }
end

--- Navigate to a given progress position (mirrors KOSync:syncToProgress).
function M.sync_to_progress(ui, prog)
    if not ui or not ui.document or not prog or not prog.progress then return end
    logger.dbg("GDrive: syncing progress to", prog.progress, "pct:", prog.percentage)
    if ui.document.info.has_pages then
        ui:handleEvent(Event:new("GotoPage", tonumber(prog.progress)))
    else
        ui:handleEvent(Event:new("GotoXPointer", prog.progress))
    end
end

--- Push current reading progress to GDrive.
--- Uploads a small JSON file: {progress, percentage, timestamp}
--- File name: <book_hash>_progress.json in the "progress" subfolder.
function M.push(widget, network, token, folder_id, book_hash, interactive)
    local prog = M.get_current_progress(widget.ui)
    if not prog then
        if interactive then
            UIManager:show(require("ui/widget/infomessage"):new{ text = "No progress to push.", timeout = 3 })
        end
        return false
    end

    -- Find or create progress subfolder
    local prog_folder = network.findFile(token, "progress", folder_id)
    local prog_folder_id
    if prog_folder then
        prog_folder_id = prog_folder.id
    else
        prog_folder_id = network.createFolder(token, "progress", folder_id)
    end
    if not prog_folder_id then
        logger.dbg("GDrive: cannot access progress folder")
        return false
    end

    -- Write progress to temp file
    local DataStorage = require("datastorage")
    local tmp_path = DataStorage:getDataDir() .. "/gdrive_progress_tmp.json"
    local f = io.open(tmp_path, "w")
    if not f then return false end
    f:write(json.encode(prog))
    f:close()

    -- Upload or update
    local remote_name = book_hash .. "_progress.json"
    local remote_file = network.findFile(token, remote_name, prog_folder_id)
    local ok
    if remote_file then
        ok = network.updateFile(token, remote_file.id, tmp_path)
    else
        ok = network.uploadFile(token, tmp_path, remote_name, prog_folder_id)
    end
    os.remove(tmp_path)

    logger.dbg("GDrive: push progress", prog.percentage * 100, "% =>", ok)
    return ok
end

--- Pull reading progress from GDrive and navigate if newer.
function M.pull(widget, network, token, folder_id, book_hash, interactive)
    local prog_folder = network.findFile(token, "progress", folder_id)
    if not prog_folder then
        if interactive then
            UIManager:show(require("ui/widget/infomessage"):new{ text = "No progress found.", timeout = 3 })
        end
        return false
    end

    local remote_name = book_hash .. "_progress.json"
    local remote_file = network.findFile(token, remote_name, prog_folder.id)
    if not remote_file then
        if interactive then
            UIManager:show(require("ui/widget/infomessage"):new{ text = "No progress found for this book.", timeout = 3 })
        end
        return false
    end

    -- Download to temp file
    local DataStorage = require("datastorage")
    local tmp_path = DataStorage:getDataDir() .. "/gdrive_progress_tmp.json"
    local dl_ok = network.downloadFileSync(token, remote_file.id, tmp_path)
    if not dl_ok then
        os.remove(tmp_path)
        return false
    end

    local f = io.open(tmp_path, "r")
    if not f then return false end
    local content = f:read("*a")
    f:close()
    os.remove(tmp_path)

    local decode_ok, remote_prog = pcall(json.decode, content)
    if not decode_ok or not remote_prog or not remote_prog.progress then
        return false
    end

    -- Compare with local — if position differs, apply remote
    local local_prog = M.get_current_progress(widget.ui)
    if local_prog and remote_prog.progress == local_prog.progress then
        if interactive then
            UIManager:show(require("ui/widget/infomessage"):new{ text = "Progress already synced.", timeout = 3 })
        end
        return true
    end

    M.sync_to_progress(widget.ui, remote_prog)
    logger.dbg("GDrive: pulled progress to", (remote_prog.percentage or 0) * 100, "%")
    return true
end

return M
