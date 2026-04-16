local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Menu = require("ui/widget/menu")
local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local docsettings = require("frontend/docsettings")
local util = require("util")

local annotations = require("annotations")
local gdrive_sync = require("gdrive_sync")
local gdrive_utils = require("utils")
local progress = require("progress")

local GDrive = WidgetContainer:extend{
    name = "gdrive",
    is_doc_only = false,
    settings = nil,
    history = {},
}

GDrive.default_settings = {
    client_id = "",
    client_secret = "",
    refresh_token = "",
    access_token = "",
    token_expiry = 0,
    download_dir = "/mnt/onboard/downloads",
    sync_folder_id = "",
    auto_sync = true,        -- auto sync on book open/close
    sync_progress = true,    -- auto push/pull reading progress
    sync_vocabulary = true,  -- include vocabulary in auto sync
}

function GDrive:init()
    self.ui.menu:registerToMainMenu(self)
    self.settings = G_reader_settings:readSetting("gdrive") or {}
    for k, v in pairs(self.default_settings) do
        if self.settings[k] == nil then
            self.settings[k] = v
        end
    end
end

function GDrive:save()
    G_reader_settings:saveSetting("gdrive", self.settings)
    if G_reader_settings.flush then G_reader_settings:flush() end
end

function GDrive:addToMainMenu(menu_items)
    menu_items.gdrive = {
        text = _("Google Drive"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = _("Browse"), callback = function() self.history = {}; self:browse() end },
            { text = _("Sync"), callback = function() self:sync(true) end },
            { text = _("Push Progress"), callback = function() self:pushProgress(true) end },
            { text = _("Pull Progress"), callback = function() self:pullProgress(true) end },
            { text = _("Sync Vocabulary"), callback = function() self:smartSyncVocabulary(true) end },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Auto-sync on open/close"),
                        checked_func = function() return self.settings.auto_sync end,
                        callback = function()
                            self.settings.auto_sync = not self.settings.auto_sync
                            self:save()
                        end,
                    },
                    {
                        text = _("Auto-sync progress"),
                        checked_func = function() return self.settings.sync_progress end,
                        callback = function()
                            self.settings.sync_progress = not self.settings.sync_progress
                            self:save()
                        end,
                    },
                    {
                        text = _("Auto-sync vocabulary"),
                        checked_func = function() return self.settings.sync_vocabulary end,
                        callback = function()
                            self.settings.sync_vocabulary = not self.settings.sync_vocabulary
                            self:save()
                        end,
                    },
                    { text = _("Load Client ID (JSON)"), callback = function() self:loadClientIDFromJson() end },
                    { text = _("Load Refresh Token (TXT)"), callback = function() self:loadRefreshTokenFromFile() end },
                    { text = _("Set Download Dir"), callback = function() self:setDownloadDir() end },
                    { text = _("Clear Auth"), callback = function() self:clearAuth() end },
                }
            },
        }
    }
end

function GDrive:getDataDir()
    local base = DataStorage:getFullDataDir() or DataStorage:getDataDir()
    local dir = base .. "/gdrive"
    if not lfs.attributes(dir) then
        lfs.mkdir(dir)
    end
    return dir .. "/"
end

function GDrive:getPluginDir()
    local source = debug.getinfo(1).source
    if source:sub(1, 1) == "@" then
        local path = source:sub(2)
        local dir = path:match("(.*[/\\])") or "./"
        -- Resolve relative path to absolute
        if dir:sub(1, 1) ~= "/" then
            local cwd = lfs.currentdir()
            if cwd then
                dir = cwd .. "/" .. dir
            end
        end
        return dir
    end
    return "./"
end

function GDrive:getKoreaderDir()
    local plugin_dir = self:getPluginDir()
    -- plugin lives in <koreader>/plugins/gdrive.koplugin/ — go up two levels
    local koreader_dir = plugin_dir:match("^(.*[/\\])plugins[/\\]")
    return koreader_dir
end

function GDrive:findCredentialFile(filename)
    -- Search order: data dir, koreader root /gdrive/, plugin dir
    local paths = {
        self:getDataDir() .. filename,
        self:getPluginDir() .. filename,
    }
    local ko_dir = self:getKoreaderDir()
    if ko_dir then
        table.insert(paths, 2, ko_dir .. "gdrive/" .. filename)
    end
    for _, path in ipairs(paths) do
        if lfs.attributes(path) then
            return path
        end
    end
    return nil, paths
end

function GDrive:loadClientIDFromJson()
    local found, searched = self:findCredentialFile("client_id.json")
    if not found then
        UIManager:show(InfoMessage:new{ text = _("client_id.json not found in:\n") .. table.concat(searched, "\n"), timeout = 5 })
        return
    end
    local data = gdrive_utils.read_json(found)
    if data and (data.installed or data.web) then
        local info = data.installed or data.web
        self.settings.client_id = info.client_id or ""
        self.settings.client_secret = info.client_secret or ""
        self:save()
        UIManager:show(InfoMessage:new{ text = _("ID Loaded") })
    else
        UIManager:show(InfoMessage:new{ text = _("Invalid client_id.json at:\n") .. found, timeout = 5 })
    end
end

function GDrive:loadRefreshTokenFromFile()
    local found, searched = self:findCredentialFile("refresh_token.txt")
    if not found then
        UIManager:show(InfoMessage:new{ text = _("refresh_token.txt not found in:\n") .. table.concat(searched, "\n"), timeout = 5 })
        return
    end
    local f = io.open(found, "r")
    if f then
        local token = f:read("*a"):gsub("%s+", "")
        f:close()
        self.settings.refresh_token = token
        self:save()
        UIManager:show(InfoMessage:new{ text = _("Token Loaded") })
    end
end

--- Parse Google Drive ISO 8601 timestamp to Unix epoch
function GDrive:parseGDriveTime(time_str)
    if not time_str or time_str == "" then return 0 end
    -- Format: "2024-01-15T10:30:00.000Z"
    local year, month, day, hour, min, sec = time_str:match(
        "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)"
    )
    if not year then return 0 end
    local t = os.time({
        year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec),
    })
    -- Adjust for local timezone offset since os.time assumes local
    local utc = os.date("!*t", t)
    local loc = os.date("*t", t)
    local tz_offset = os.time(loc) - os.time(utc)
    return t - tz_offset
end

--- Auto-sync event: called when a book is opened
function GDrive:onReaderReady()
    if not self.settings.auto_sync then return end
    if self.settings.client_id == "" or self.settings.refresh_token == "" then return end
    UIManager:scheduleIn(3, function()
        self:sync(false)
        if self.settings.sync_progress then
            self:pullProgress(false)
        end
        if self.settings.sync_vocabulary then
            self:smartSyncVocabulary(false)
        end
    end)
end

--- Auto-sync event: called when a book is closed
function GDrive:onCloseDocument()
    if not self.settings.auto_sync then return end
    if self.settings.client_id == "" or self.settings.refresh_token == "" then return end
    self:sync(false)
    if self.settings.sync_progress then
        self:pushProgress(false)
    end
    if self.settings.sync_vocabulary then
        self:smartSyncVocabulary(false)
    end
end

function GDrive:sync(interactive)
    local document = self.ui and self.ui.document
    local file = document and document.file
    if not file then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Please open a book first!") })
        end
        return
    end

    local stored_annotations = self.ui.annotation and self.ui.annotation.annotations or {}
    local book_hash = util.partialMD5(file)
    if not book_hash then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("Failed to hash book file.") })
        end
        return
    end

    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then
        if interactive then UIManager:show(InfoMessage:new{ text = _("Cannot determine sidecar dir.") }) end
        return
    end
    if not lfs.attributes(sdr_dir) then
        lfs.mkdir(sdr_dir)
    end

    local annotation_filename = book_hash .. ".json"
    local json_path = annotations.write_annotations_json(document, stored_annotations, sdr_dir, annotation_filename, self.ui)
    if not json_path then
        if interactive then UIManager:show(InfoMessage:new{ text = _("Failed to write annotations JSON.") }) end
        return
    end

    local widget = self
    self:getAccessToken(function(token)
        self:getSyncFolder(token, function(folder_id)
            local ok_net, network = pcall(require, "network")
            if not ok_net then return end

            -- Find or create annotations subfolder
            local ann_folder = network.findFile(token, "annotations", folder_id)
            local ann_folder_id
            if ann_folder then
                ann_folder_id = ann_folder.id
            else
                ann_folder_id = network.createFolder(token, "annotations", folder_id)
            end
            if not ann_folder_id then
                if interactive then UIManager:show(InfoMessage:new{ text = _("Cannot access annotations folder.") }) end
                return
            end

            local remote_name = annotation_filename
            local ok = gdrive_sync.sync(network, token, json_path, remote_name, ann_folder_id,
                function(local_file, cached_file, income_file)
                    return annotations.sync_callback(widget, local_file, cached_file, income_file)
                end)

            if interactive then
                if ok then
                    UIManager:show(InfoMessage:new{ text = _("Synced."), timeout = 3 })
                else
                    UIManager:show(InfoMessage:new{ text = _("Sync failed."), timeout = 3 })
                end
            end
        end)
    end)
end

--- Push current reading progress to GDrive
function GDrive:pushProgress(interactive)
    local document = self.ui and self.ui.document
    local file = document and document.file
    if not file then return end

    local book_hash = util.partialMD5(file)
    if not book_hash then return end

    local widget = self
    self:getAccessToken(function(token)
        self:getSyncFolder(token, function(folder_id)
            local ok_net, network = pcall(require, "network")
            if not ok_net then return end
            local ok = progress.push(widget, network, token, folder_id, book_hash, interactive)
            if interactive then
                if ok then
                    UIManager:show(InfoMessage:new{ text = _("Progress pushed."), timeout = 3 })
                else
                    UIManager:show(InfoMessage:new{ text = _("Push progress failed."), timeout = 3 })
                end
            end
        end)
    end)
end

--- Pull reading progress from GDrive and navigate
function GDrive:pullProgress(interactive)
    local document = self.ui and self.ui.document
    local file = document and document.file
    if not file then return end

    local book_hash = util.partialMD5(file)
    if not book_hash then return end

    local widget = self
    self:getAccessToken(function(token)
        self:getSyncFolder(token, function(folder_id)
            local ok_net, network = pcall(require, "network")
            if not ok_net then return end
            progress.pull(widget, network, token, folder_id, book_hash, interactive)
        end)
    end)
end

--- Smart 2-way sync for vocabulary
function GDrive:smartSyncVocabulary(interactive)
    local local_path = DataStorage:getDataDir() .. "/settings/vocabulary_builder.sqlite3"
    local has_local = lfs.attributes(local_path)
    local local_mtime = has_local and lfs.attributes(local_path, "modification") or 0

    self:getAccessToken(function(token)
        self:getSyncFolder(token, function(folder_id)
            local ok_net, network = pcall(require, "network")
            if not ok_net then return end

            local remote_file = network.findFile(token, "vocabulary_builder.sqlite3", folder_id)

            if remote_file and has_local then
                local remote_mtime = self:parseGDriveTime(remote_file.modifiedTime)
                local THRESHOLD = 10
                if local_mtime > remote_mtime + THRESHOLD then
                    network.updateFile(token, remote_file.id, local_path)
                    if interactive then UIManager:show(InfoMessage:new{ text = _("Vocabulary uploaded (local newer)"), timeout = 3 }) end
                elseif remote_mtime > local_mtime + THRESHOLD then
                    network.downloadFileSync(token, remote_file.id, local_path)
                    if interactive then UIManager:show(InfoMessage:new{ text = _("Vocabulary downloaded (remote newer)"), timeout = 3 }) end
                else
                    if interactive then UIManager:show(InfoMessage:new{ text = _("Vocabulary in sync."), timeout = 2 }) end
                end
            elseif remote_file and not has_local then
                network.downloadFileSync(token, remote_file.id, local_path)
                if interactive then UIManager:show(InfoMessage:new{ text = _("Vocabulary downloaded."), timeout = 3 }) end
            elseif has_local and not remote_file then
                network.uploadFile(token, local_path, "vocabulary_builder.sqlite3", folder_id)
                if interactive then UIManager:show(InfoMessage:new{ text = _("Vocabulary uploaded."), timeout = 3 }) end
            else
                if interactive then UIManager:show(InfoMessage:new{ text = _("No vocabulary data found."), timeout = 3 }) end
            end
        end)
    end)
end

function GDrive:getAccessToken(callback)
    if self.settings.client_id == "" or self.settings.refresh_token == "" then
        UIManager:show(ConfirmBox:new{ text = "Setup Required" })
        return
    end
    if os.time() < self.settings.token_expiry - 60 then
        callback(self.settings.access_token)
        return
    end
    
    UIManager:scheduleIn(0.1, function()
        local ok, network = pcall(require, "network")
        if not ok then return end
        local res_ok, data = pcall(network.refreshToken, self.settings.client_id, self.settings.client_secret, self.settings.refresh_token)
        if res_ok and data and data.access_token then
            self.settings.access_token = data.access_token
            self.settings.token_expiry = os.time() + (data.expires_in or 3600)
            self:save()
            callback(self.settings.access_token)
        else
            UIManager:show(ConfirmBox:new{ text = "Refresh Fail" })
        end
    end)
end

function GDrive:getSyncFolder(token, callback)
    local ok, network = pcall(require, "network")
    if not ok then return end
    if self.settings.sync_folder_id ~= "" then
        callback(self.settings.sync_folder_id)
        return
    end
    local folder = network.findFile(token, "KOReader_Sync", nil)
    if folder and folder.id then
        self.settings.sync_folder_id = folder.id
        self:save()
        callback(folder.id)
    else
        local folder_id = network.createFolder(token, "KOReader_Sync")
        if folder_id then
            self.settings.sync_folder_id = folder_id
            self:save()
            callback(folder_id)
        else
            UIManager:show(ConfirmBox:new{ text = "Sync Folder Error" })
        end
    end
end

function GDrive:getCurrentBookPath()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok and ReaderUI.instance and ReaderUI.instance.document then
        return ReaderUI.instance.document.file
    end
    if self.ui and self.ui.document then
        return self.ui.document.file
    end
    local last = G_reader_settings:readSetting("last_file")
    if last and last ~= "" then return last end
    return nil
end

function GDrive:setDownloadDir()
    local PathChooser = require("ui/widget/pathchooser")
    local path_chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        path = self.settings.download_dir,
        onConfirm = function(path)
            self.settings.download_dir = path
            self:save()
            UIManager:show(InfoMessage:new{ text = _("Download dir set to:\n") .. path, timeout = 3 })
        end,
    }
    UIManager:show(path_chooser)
end

function GDrive:clearAuth()
    UIManager:show(ConfirmBox:new{
        text = _("Clear all Google Drive auth data?"),
        ok_callback = function()
            self.settings.client_id = ""
            self.settings.client_secret = ""
            self.settings.refresh_token = ""
            self.settings.access_token = ""
            self.settings.token_expiry = 0
            self.settings.sync_folder_id = ""
            self:save()
            UIManager:show(InfoMessage:new{ text = _("Auth cleared."), timeout = 2 })
        end,
    })
end

function GDrive:browse(folder_id, folder_name)
    self:getAccessToken(function(token)
        local ok, network = pcall(require, "network")
        if not ok then return end
        local data = network.listFiles(token, folder_id)
        if not data then return end
        local menu_items = {}
        if #self.history > 0 then
            table.insert(menu_items, {
                text = _(".. [Back]"),
                callback = function()
                    local last = table.remove(self.history)
                    UIManager:close(self.current_menu)
                    self:browse(last.id, last.name)
                end,
            })
        end
        for _, file in ipairs(data.files or {}) do
            local item = {
                text = (file.mimeType == "application/vnd.google-apps.folder" and "[DIR] " or "") .. file.name,
                callback = function()
                    if file.mimeType == "application/vnd.google-apps.folder" then
                        table.insert(self.history, {id = folder_id, name = folder_name})
                        UIManager:close(self.current_menu)
                        self:browse(file.id, file.name)
                    else
                        self:download(file)
                    end
                end,
            }
            table.insert(menu_items, item)
        end
        self.current_menu = Menu:new{ title = folder_name or "GDrive", item_table = menu_items }
        UIManager:show(self.current_menu)
    end)
end

function GDrive:download(file)
    local clean_name = file.name:gsub("[\\/]", "_")
    local dest_path = self.settings.download_dir .. "/" .. clean_name
    local flag_path = dest_path .. ".done"
    UIManager:show(InfoMessage:new{ text = "Downloading...", timeout = 2 })
    self:getAccessToken(function(token)
        local ok, network = pcall(require, "network")
        if not ok then return end
        network.downloadFile(token, file.id, dest_path)
        local poll_count = 0
        local function check_done()
            local f = io.open(flag_path, "r")
            if f then
                f:close()
                os.remove(flag_path)
                UIManager:show(InfoMessage:new{ text = "Finished: " .. file.name, timeout = 5 })
            elseif poll_count < 120 then
                poll_count = poll_count + 1
                UIManager:scheduleIn(5, check_done)
            end
        end
        UIManager:scheduleIn(5, check_done)
    end)
end

return GDrive
