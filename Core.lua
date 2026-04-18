-- Raid Master Suite -- Core
-- Namespace, event router, module registry, slash command.

local ADDON_NAME, ns = ...

RaidMasterSuite = ns
local RMS = ns

RMS.NAME    = "Raid Master Suite"
RMS.SHORT   = "RMS"
RMS.VERSION = "0.1.0"
RMS.AUTHOR  = "rodneywowwow"

-- Module registry. Modules call RMS:RegisterModule(id, tbl).
RMS.modules     = {}
RMS.moduleOrder = {}

function RMS:RegisterModule(id, mod)
    if self.modules[id] then return self.modules[id] end
    mod.id     = id
    mod.title  = mod.title or id
    mod.events = mod.events or {}
    self.modules[id] = mod
    table.insert(self.moduleOrder, id)
    return mod
end

function RMS:GetModule(id) return self.modules[id] end

-- ---------- Logging ----------
function RMS:Print(msg, ...)
    if select("#", ...) > 0 then msg = msg:format(...) end
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd070["..self.SHORT.."]|r "..tostring(msg))
end

function RMS:Debug(msg, ...)
    if not (self.db and self.db.debug) then return end
    if select("#", ...) > 0 then msg = msg:format(...) end
    DEFAULT_CHAT_FRAME:AddMessage("|cff7fa0ff["..self.SHORT..":dbg]|r "..tostring(msg))
end

-- ---------- Event router ----------
local frame = CreateFrame("Frame", "RaidMasterSuiteEventFrame")
RMS.eventFrame = frame
local handlers = {}
RMS.handlers   = handlers

function RMS:RegisterEvent(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        frame:RegisterEvent(event)
    end
    table.insert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(self, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], event, ...)
        if not ok then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff5050[RMS error]|r "..tostring(err))
        end
    end
end)

-- ---------- Player / raid helpers ----------
function RMS:PlayerName()
    local n = UnitName("player")
    return n
end

function RMS:PlayerFullName()
    local name, realm = UnitName("player"), GetRealmName()
    return name.."-"..(realm or "")
end

function RMS:InRaid() return GetNumRaidMembers() > 0 end
function RMS:InGroup() return GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0 end

function RMS:IsRaidLeader()
    if not self:InRaid() then return false end
    return IsRaidLeader() == 1 or IsRaidLeader() == true
end

function RMS:IsAssist()
    if not self:InRaid() then return false end
    if self:IsRaidLeader() then return true end
    return IsRaidOfficer() == 1 or IsRaidOfficer() == true
end

function RMS:IsMasterLooter()
    local method, partyId, raidId = GetLootMethod()
    if method ~= "master" then return false end
    if raidId and raidId > 0 then
        return UnitName("raid"..raidId) == self:PlayerName()
    elseif partyId == 0 then
        return true
    end
    return false
end

-- Returns table of raid member names (or {playerName} if solo).
function RMS:GetRosterNames()
    local out, n = {}, GetNumRaidMembers()
    if n > 0 then
        for i = 1, n do
            local nm = GetRaidRosterInfo(i)
            if nm then out[#out+1] = nm end
        end
        return out
    end
    n = GetNumPartyMembers()
    out[#out+1] = self:PlayerName()
    for i = 1, n do
        local nm = UnitName("party"..i)
        if nm then out[#out+1] = nm end
    end
    return out
end

-- ---------- Boot ----------
local booted = false
local function Boot()
    if booted then return end
    booted = true

    -- DB init
    RaidMasterSuiteDB     = RaidMasterSuiteDB     or {}
    RaidMasterSuiteCharDB = RaidMasterSuiteCharDB or {}
    RMS.db     = RaidMasterSuiteDB
    RMS.charDB = RaidMasterSuiteCharDB

    if RMS.Config and RMS.Config.ApplyDefaults then RMS.Config:ApplyDefaults() end

    -- Boot modules
    for _, id in ipairs(RMS.moduleOrder) do
        local mod = RMS.modules[id]
        if mod.OnInit then
            local ok, err = pcall(mod.OnInit, mod)
            if not ok then RMS:Print("|cffff5050module %s init failed:|r %s", id, err) end
        end
        for ev, fn in pairs(mod.events) do
            RMS:RegisterEvent(ev, function(...) fn(mod, ...) end)
        end
    end

    -- Comm init
    if RMS.Comm and RMS.Comm.OnInit then RMS.Comm:OnInit() end

    -- Build UI
    if RMS.UI and RMS.UI.Build then RMS.UI:Build() end

    -- Optional: auto-open main window on login if the user enabled it.
    if RMS.db.ui and RMS.db.ui.openOnLogin and RMS.UI and RMS.UI.Show then
        RMS.UI:Show()
    end

    RMS:Print("v%s loaded. /rms to open.", RMS.VERSION)
end

RMS:RegisterEvent("PLAYER_LOGIN", Boot)
RMS:RegisterEvent("ADDON_LOADED", function(_, name)
    if name == ADDON_NAME then Boot() end
end)

-- ---------- Slash command ----------
SLASH_RAIDMASTERSUITE1 = "/rms"
SLASH_RAIDMASTERSUITE2 = "/raidmaster"
SlashCmdList["RAIDMASTERSUITE"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+",""):gsub("%s+$","")
    if msg == "" or msg == "show" or msg == "toggle" then
        if RMS.UI and RMS.UI.Toggle then RMS.UI:Toggle() end
        return
    end
    if msg == "config" or msg == "options" or msg == "settings" then
        if RMS.UI and RMS.UI.Show then RMS.UI:Show("settings") end
        return
    end
    if msg == "debug" then
        RMS.db.debug = not RMS.db.debug
        RMS:Print("debug = %s", tostring(RMS.db.debug))
        return
    end
    -- module-specific
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    if cmd then
        local mod = RMS:GetModule(cmd)
        if mod and mod.OnSlash then return mod:OnSlash(arg) end
        if RMS.UI and RMS.UI.Show then RMS.UI:Show(cmd) end
        return
    end
    RMS:Print("commands: show | config | debug | <module> [args]")
end
