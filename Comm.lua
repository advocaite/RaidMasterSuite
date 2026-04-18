-- Raid Master Suite -- Comm
-- Addon channel sync. Single prefix "RMS"; messages are <module>:<cmd>:<payload>.
-- Payload is a flat string-encoded table (key=val;key=val) for portability with no Ace deps.

local RMS = RaidMasterSuite
local Comm = {}
RMS.Comm = Comm

Comm.PREFIX = "RMS"

-- ---------- (de)serialize ----------
local function escape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub(";", "\\s"):gsub("=", "\\e"):gsub(":", "\\c")
    return s
end
local function unescape(s)
    s = s:gsub("\\c", ":"):gsub("\\e", "="):gsub("\\s", ";"):gsub("\\\\", "\\")
    return s
end

function Comm:Encode(tbl)
    if type(tbl) ~= "table" then return tostring(tbl) end
    local parts = {}
    for k, v in pairs(tbl) do parts[#parts+1] = escape(k).."="..escape(v) end
    return table.concat(parts, ";")
end

function Comm:Decode(str)
    local t = {}
    if not str or str == "" then return t end
    for kv in str:gmatch("[^;]+") do
        local k, v = kv:match("^(.-)=(.*)$")
        if k then t[unescape(k)] = unescape(v) end
    end
    return t
end

-- ---------- handlers ----------
Comm.handlers = {}
function Comm:On(module, cmd, fn)
    self.handlers[module] = self.handlers[module] or {}
    self.handlers[module][cmd] = fn
end

-- ---------- channel selection ----------
local function PickChannel()
    if GetNumRaidMembers() > 0 then return "RAID" end
    if GetNumPartyMembers() > 0 then return "PARTY" end
    return nil
end

function Comm:Send(module, cmd, payload, channel, target)
    local body = type(payload) == "table" and self:Encode(payload) or tostring(payload or "")
    local msg  = module..":"..cmd..":"..body
    channel = channel or PickChannel()
    if not channel then return end
    if channel == "WHISPER" then
        if not target then return end
        SendAddonMessage(self.PREFIX, msg, "WHISPER", target)
    else
        SendAddonMessage(self.PREFIX, msg, channel)
    end
    RMS:Debug("send[%s]>%s %s:%s", channel, target or "", module, cmd)
end

function Comm:SendWhisper(module, cmd, payload, target)
    self:Send(module, cmd, payload, "WHISPER", target)
end

-- ---------- receive ----------
local function OnAddonMsg(_, prefix, message, channel, sender)
    if prefix ~= Comm.PREFIX then return end
    local module, cmd, body = message:match("^([^:]+):([^:]+):(.*)$")
    if not module then return end
    local mh = Comm.handlers[module]
    if not mh or not mh[cmd] then return end
    local payload = Comm:Decode(body)
    local ok, err = pcall(mh[cmd], payload, sender, channel)
    if not ok then RMS:Print("|cffff5050comm err|r %s:%s %s", module, cmd, tostring(err)) end
end

function Comm:OnInit()
    RMS:RegisterEvent("CHAT_MSG_ADDON", OnAddonMsg)
    RMS:Debug("Comm initialized prefix=%s", self.PREFIX)
end
