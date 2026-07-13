-- Raid Master Suite -- +1 Loot Tracker
-- Guild "+1" system: when a player wins a loot roll they get marked +1.
-- Players with fewer +1s have priority on later drops. Counts persist across
-- sessions until the leader resets them. Full raid sync.
--
-- Sources of +1:
--   * auto: group-loot roll wins ("X won: [item]") -- every client sees the
--     same chat line, so everyone applies it locally (no comm needed)
--   * auto: Soft Res /roll session winners (hook from SoftRes)
--   * auto: Master Loot awards (hook from MasterLoot; ML broadcasts)
--   * manual: leader/assist +/- buttons (broadcast)

local RMS = RaidMasterSuite
local M = RMS:RegisterModule("plusone", { title = "+1 Loot", order = 3 })

-- ---------- state ----------
M.state = {
    counts = {},   -- [playerName] = number of +1s
    log    = {},   -- recent events (newest first)
}

local function persist() RMS.db.plusoneState = M.state end
local function restore()
    if RMS.db.plusoneState then
        for k, v in pairs(RMS.db.plusoneState) do M.state[k] = v end
    end
end

local function cfg() return RMS.db.plusone or {} end

local function pushLog(msg)
    table.insert(M.state.log, 1, ("[%s] %s"):format(date("%H:%M"), msg))
    if #M.state.log > 30 then M.state.log[#M.state.log] = nil end
end

-- ---------- permissions ----------
-- In a raid only leader/assist may adjust; solo/party is open (testing).
local function canAdjust()
    return (not RMS:InRaid()) or RMS:IsAssist() or RMS:IsMasterLooter()
end

-- The current master looter may be a rank-0 raider; their +1 broadcasts
-- (from Master Loot awards) must still be accepted.
local function senderIsMasterLooter(sender)
    local method, _, raidId = GetLootMethod()
    if method ~= "master" then return false end
    if raidId and raidId > 0 then
        return UnitName("raid"..raidId) == sender
    end
    return false
end

local function senderIsOfficer(sender)
    if sender == RMS:PlayerName() then return canAdjust() end
    if senderIsMasterLooter(sender) then return true end
    local n = GetNumRaidMembers()
    if n == 0 then return true end  -- party: trust members
    for i = 1, n do
        local name, rank = GetRaidRosterInfo(i)
        if name == sender then return (rank or 0) >= 1 end
    end
    return false
end

-- ---------- quality helpers ----------
local HEX_TO_QUALITY = {
    ["ff9d9d9d"] = 0, ["ffffffff"] = 1, ["ff1eff00"] = 2,
    ["ff0070dd"] = 3, ["ffa335ee"] = 4, ["ffff8000"] = 5,
}

local function linkQuality(link)
    local id = tonumber(link and link:match("item:(%d+)"))
    if id then
        local q = select(3, GetItemInfo(id))
        if q then return q end
    end
    local hex = link and link:match("^|c(%x%x%x%x%x%x%x%x)")
    return hex and HEX_TO_QUALITY[hex:lower()] or nil
end

local function qualityName(q)
    local name = _G["ITEM_QUALITY"..tostring(q).."_DESC"]
    return name or ("q"..tostring(q))
end

-- ---------- core apply ----------
-- Recent-award guard: the same player+item can reach us via several paths
-- (roll win + ML award). Ignore repeats within the window.
local recentGrants = {}
local DUP_WINDOW = 120

local function isDuplicate(player, link)
    local id = link and link:match("item:(%d+)") or tostring(link)
    local key = player.."\1"..tostring(id)
    local now = GetTime()
    if recentGrants[key] and (now - recentGrants[key]) < DUP_WINDOW then
        return true
    end
    recentGrants[key] = now
    return false
end

-- Set a player's count outright (comm-driven and manual adjust).
function M:SetCount(player, count, why)
    if not player or player == "" then return end
    count = math.max(0, tonumber(count) or 0)
    if count == 0 then
        self.state.counts[player] = nil
    else
        self.state.counts[player] = count
    end
    if why then pushLog(("%s -> +%d (%s)"):format(player, count, why)) end
    persist()
    self:Refresh()
end

function M:GetCount(player)
    return self.state.counts[player] or 0
end

-- Local +1 from an auto-detected win. No broadcast: every client saw the
-- same chat line / roll session, so each applies it independently.
function M:OnRollWin(player, itemLink)
    if not cfg().autoRollWins then return end
    if not RMS:InGroup() then return end
    local q = linkQuality(itemLink)
    if q and q < (cfg().minQuality or 4) then return end
    if isDuplicate(player, itemLink) then return end
    local newCount = self:GetCount(player) + 1
    self:SetCount(player, newCount, "won "..(itemLink or "roll"))
    if cfg().announce and RMS:IsRaidLeader() then
        SendChatMessage(("%s is now +%d (won %s)"):format(player, newCount, itemLink or "a roll"),
            RMS:InRaid() and "RAID" or "PARTY")
    end
end

-- +1 granted by the master looter (MasterLoot module). Broadcasts, since
-- only the ML's client knows about the award decision.
function M:GrantPlusOne(player, itemLink)
    if not canAdjust() then RMS:Print("Only leader/assist can grant +1.") return end
    if isDuplicate(player, itemLink) then return end
    local newCount = self:GetCount(player) + 1
    self:SetCount(player, newCount, "awarded "..(itemLink or "item"))
    RMS.Comm:Send("plusone", "set", { player = player, count = newCount, why = "award" })
    if cfg().announce then
        SendChatMessage(("%s is now +%d (%s)"):format(player, newCount, itemLink or "loot"),
            RMS:InRaid() and "RAID" or "PARTY")
    end
end

-- Manual +/- from the UI (leader/assist only). Broadcasts.
function M:Adjust(player, delta)
    if not canAdjust() then RMS:Print("Only leader/assist can adjust +1 counts.") return end
    if not player or player == "" then return end
    local newCount = math.max(0, self:GetCount(player) + delta)
    self:SetCount(player, newCount, delta > 0 and "manual +1" or "manual -1")
    RMS.Comm:Send("plusone", "set", { player = player, count = newCount, why = "manual" })
end

function M:ResetAll()
    if not canAdjust() then RMS:Print("Only leader/assist can reset +1 counts.") return end
    self.state.counts = {}
    pushLog("counts reset")
    persist()
    RMS.Comm:Send("plusone", "reset", {})
    RMS:Print("+1 counts reset.")
    self:Refresh()
end

-- ---------- comm ----------
RMS.Comm:On("plusone", "set", function(p, sender)
    if sender == RMS:PlayerName() then return end
    if not senderIsOfficer(sender) then return end
    if not p.player then return end
    M:SetCount(p.player, tonumber(p.count) or 0,
        (p.why == "award" and "awarded by "..sender) or ("set by "..sender))
end)

RMS.Comm:On("plusone", "reset", function(_, sender)
    if sender == RMS:PlayerName() then return end
    if not senderIsOfficer(sender) then return end
    M.state.counts = {}
    pushLog("counts reset by "..sender)
    persist()
    M:Refresh()
    RMS:Print("+1 counts reset by %s.", sender)
end)

-- Late joiners ask the raid; leader (or ML) answers with the full table.
function M:RequestSync()
    if not RMS:InGroup() then return end
    RMS.Comm:Send("plusone", "syncreq", {})
end

RMS.Comm:On("plusone", "syncreq", function(_, sender)
    if sender == RMS:PlayerName() then return end
    if not (RMS:IsRaidLeader() or RMS:IsMasterLooter()) then return end
    local payload = {}
    local any = false
    for player, count in pairs(M.state.counts) do
        payload[player] = count; any = true
    end
    if any then RMS.Comm:SendWhisper("plusone", "sync", payload, sender) end
end)

RMS.Comm:On("plusone", "sync", function(p, sender)
    if sender == RMS:PlayerName() then return end
    if not senderIsOfficer(sender) then return end
    M.state.counts = {}
    for player, count in pairs(p) do
        M.state.counts[player] = tonumber(count) or 0
    end
    pushLog("synced from "..sender)
    persist()
    M:Refresh()
end)

-- ---------- auto-detect group-loot roll wins ----------
-- enUS: LOOT_ROLL_WON = "%s won: %s" / LOOT_ROLL_YOU_WON = "You won: %s"
local function onLootMsg(msg)
    local player, link = msg:match("^(%S+) won: (|c%x+|Hitem:.-|h.-|h|r)")
    if not player then
        link = msg:match("^You won: (|c%x+|Hitem:.-|h.-|h|r)")
        if link then player = RMS:PlayerName() end
    end
    if player and link then M:OnRollWin(player, link) end
end

M.events = {
    CHAT_MSG_LOOT = function(self, _, msg) onLootMsg(msg) end,
    PLAYER_LOGIN  = function(self)
        restore()
        -- the tab may have been built before restore ran; repaint it
        self:Refresh()
        self._wasInGroup = RMS:InGroup()
        if self._wasInGroup then
            local d = CreateFrame("Frame"); local elapsed = 0
            d:SetScript("OnUpdate", function(s, dt)
                elapsed = elapsed + dt
                if elapsed > 3 then s:SetScript("OnUpdate", nil); self:RequestSync() end
            end)
        end
    end,
    RAID_ROSTER_UPDATE    = function(self) self:OnGroupChange() end,
    PARTY_MEMBERS_CHANGED = function(self) self:OnGroupChange() end,
}

function M:OnGroupChange()
    local nowIn = RMS:InGroup()
    if nowIn and not self._wasInGroup then self:RequestSync() end
    self._wasInGroup = nowIn
    self:Refresh()
end

-- ---------- helpers for other modules / UI ----------
local function CLASS_COLOR(token)
    local c = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if c then return ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) end
    return "|cffffffff"
end

-- name -> class token for everyone currently grouped
local function rosterClassMap()
    local map = {}
    local n = GetNumRaidMembers()
    if n > 0 then
        for i = 1, n do
            local name, _, _, _, _, classToken = GetRaidRosterInfo(i)
            if name then map[name] = classToken end
        end
        return map
    end
    local _, myTok = UnitClass("player")
    map[RMS:PlayerName()] = myTok
    for i = 1, GetNumPartyMembers() do
        local nm = UnitName("party"..i)
        if nm then
            local _, tok = UnitClass("party"..i)
            map[nm] = tok
        end
    end
    return map
end

-- ---------- UI ----------
function M:BuildUI(parent)
    local Skin = RMS.Skin
    local C    = Skin.COLOR
    local panel = CreateFrame("Frame", nil, parent)

    local header = Skin:Header(panel, "+1 Loot Tracker")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)

    local hint = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(hint, 11, false)
    hint:SetTextColor(unpack(C.textDim))
    hint:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 4, -6)
    hint:SetText("Winners get marked +1. Fewer +1s = higher loot priority. Counts sync across the raid.")

    -- options row
    local autoCb = Skin:CheckBox(panel, "Auto +1 on roll wins")
    autoCb:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
    autoCb:SetChecked(cfg().autoRollWins)
    autoCb.OnValueChanged = function(_, v) RMS.db.plusone.autoRollWins = v end
    Skin:AttachTooltip(autoCb.box, "Auto +1 on roll wins",
        { "Automatically mark +1 when someone wins a group-loot roll or a Soft Res /roll session (at or above the minimum quality)." })

    local annCb = Skin:CheckBox(panel, "Announce +1 changes")
    annCb:SetPoint("LEFT", autoCb, "RIGHT", 20, 0)
    annCb:SetChecked(cfg().announce)
    annCb.OnValueChanged = function(_, v) RMS.db.plusone.announce = v end
    Skin:AttachTooltip(annCb.box, "Announce +1 changes",
        { "Post +1 updates to raid chat (leader/assist only)." })

    local qualBtn = Skin:Button(panel, "", 150, 20)
    qualBtn:SetPoint("LEFT", annCb, "RIGHT", 20, 0)
    local function refreshQualBtn()
        local q = cfg().minQuality or 4
        qualBtn:SetText("Min quality: "..qualityName(q))
    end
    qualBtn:SetScript("OnMouseUp", function()
        local q = (cfg().minQuality or 4) + 1
        if q > 5 then q = 2 end
        RMS.db.plusone.minQuality = q
        refreshQualBtn()
    end)
    refreshQualBtn()

    -- controls row
    local resetBtn = Skin:Button(panel, "Reset All", 90, 24)
    resetBtn:SetPoint("TOPLEFT", autoCb, "BOTTOMLEFT", 0, -10)
    resetBtn:SetScript("OnMouseUp", function() self:ResetAll() end)

    local syncBtn = Skin:Button(panel, "Request Sync", 100, 24)
    syncBtn:SetPoint("LEFT", resetBtn, "RIGHT", 6, 0)
    syncBtn:SetScript("OnMouseUp", function()
        self:RequestSync()
        RMS:Print("Requested +1 sync from the raid.")
    end)

    local nameEdit = Skin:EditBox(panel, 140, 22)
    nameEdit:SetPoint("LEFT", syncBtn, "RIGHT", 20, 0)

    local addBtn = Skin:Button(panel, "+1", 34, 22)
    addBtn:SetPoint("LEFT", nameEdit, "RIGHT", 4, 0)
    addBtn:SetScript("OnMouseUp", function()
        local nm = (nameEdit:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if nm ~= "" then self:Adjust(nm, 1); nameEdit:SetText("") end
    end)

    local subBtn = Skin:Button(panel, "-1", 34, 22)
    subBtn:SetPoint("LEFT", addBtn, "RIGHT", 4, 0)
    subBtn:SetScript("OnMouseUp", function()
        local nm = (nameEdit:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if nm ~= "" then self:Adjust(nm, -1); nameEdit:SetText("") end
    end)

    local nameHint = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(nameHint, 10, false)
    nameHint:SetTextColor(unpack(C.textDim))
    nameHint:SetPoint("BOTTOMLEFT", nameEdit, "TOPLEFT", 2, 2)
    nameHint:SetText("Adjust by name (any player):")

    -- left: player counts
    local playersHdr = Skin:Header(panel, "Players")
    playersHdr:SetPoint("TOPLEFT", resetBtn, "BOTTOMLEFT", 0, -12)
    playersHdr:SetWidth(360)

    local logHdr = Skin:Header(panel, "Recent +1 Events")
    logHdr:SetPoint("LEFT", playersHdr, "RIGHT", 8, 0)
    logHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    local function buildRow(parent)
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(22)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
        local who = r:CreateFontString(nil, "OVERLAY"); Skin:Font(who, 12, true)
        who:SetPoint("LEFT", 6, 0); r.who = who
        local plus = Skin:Button(r, "+", 20, 18)
        plus:SetPoint("RIGHT", -4, 0); r.plus = plus
        local minus = Skin:Button(r, "-", 20, 18)
        minus:SetPoint("RIGHT", plus, "LEFT", -4, 0); r.minus = minus
        local count = r:CreateFontString(nil, "OVERLAY"); Skin:Font(count, 13, true)
        count:SetPoint("RIGHT", minus, "LEFT", -12, 0); r.count = count
        return r
    end
    local function updRow(r, item, idx, alt)
        if not item then return end
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        local grouped = item.inGroup and "" or " |cff777777(not in group)|r"
        r.who:SetText(("%s%s|r%s"):format(CLASS_COLOR(item.class), item.player, grouped))
        if item.count > 0 then
            r.count:SetText(("|cffffd070+%d|r"):format(item.count))
        else
            r.count:SetText("|cff6666660|r")
        end
        r.plus:SetScript("OnMouseUp",  function() M:Adjust(item.player,  1) end)
        r.minus:SetScript("OnMouseUp", function() M:Adjust(item.player, -1) end)
    end
    local playersList = Skin:ScrollList(panel, 22, buildRow, updRow)
    playersList:SetPoint("TOPLEFT", playersHdr, "BOTTOMLEFT", 0, -2)
    playersList:SetPoint("BOTTOM", panel, "BOTTOM", 0, 8)
    playersList:SetWidth(360)

    local function buildLogRow(parent)
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(18)
        local fs = r:CreateFontString(nil, "OVERLAY")
        Skin:Font(fs, 11, false)
        fs:SetPoint("LEFT", 4, 0); fs:SetPoint("RIGHT", -4, 0)
        fs:SetJustifyH("LEFT"); fs:SetWordWrap(false); fs:SetNonSpaceWrap(false)
        r.text = fs
        return r
    end
    local function updLogRow(r, text)
        r.text:SetText(text or "")
    end
    local logList = Skin:ScrollList(panel, 18, buildLogRow, updLogRow)
    logList:SetPoint("TOPLEFT", logHdr, "BOTTOMLEFT", 0, -2)
    logList:SetPoint("BOTTOM", panel, "BOTTOM", 0, 8)
    logList:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    -- re-read config on show so changes made in the Settings tab appear here
    panel:SetScript("OnShow", function()
        autoCb:SetChecked(cfg().autoRollWins)
        annCb:SetChecked(cfg().announce)
        refreshQualBtn()
        self:Refresh()
    end)

    self._ui = { panel = panel, players = playersList, log = logList }
    self:Refresh()
    return panel
end

function M:Refresh()
    if not self._ui then return end

    -- current group members first (alphabetical), then anyone else with a count
    local classes = rosterClassMap()
    local rows, seen = {}, {}
    for _, name in ipairs(RMS:GetRosterNames()) do
        rows[#rows+1] = { player = name, class = classes[name],
                          count = self:GetCount(name), inGroup = true }
        seen[name] = true
    end
    table.sort(rows, function(a, b) return a.player < b.player end)

    local extra = {}
    for name in pairs(self.state.counts) do
        if not seen[name] then
            extra[#extra+1] = { player = name, class = classes[name],
                                count = self:GetCount(name), inGroup = false }
        end
    end
    table.sort(extra, function(a, b) return a.player < b.player end)
    for _, e in ipairs(extra) do rows[#rows+1] = e end

    self._ui.players:SetData(rows)
    self._ui.log:SetData(self.state.log or {})
end

-- ---------- slash ----------
function M:OnSlash(arg)
    arg = arg or ""
    if arg == "reset" then return self:ResetAll() end
    local who, delta = arg:match("^(%S+)%s+([%+%-]?%d+)$")
    if who then return self:Adjust(who, tonumber(delta)) end
    RMS.UI:Show("plusone")
end
