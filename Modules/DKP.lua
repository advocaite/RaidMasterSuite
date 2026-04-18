-- Raid Master Suite -- DKP
-- Per-guild DKP standings. Officers (rank index <= configured threshold) can
-- award/deduct points. Sync over the GUILD addon channel so every guild member
-- with the addon sees the same standings. Late-join sync from any officer.

local RMS = RaidMasterSuite
local M = RMS:RegisterModule("dkp", { title = "DKP", order = 3 })

-- ---------- per-guild state ----------
M.state    = nil   -- bound to RMS.db.dkp[<guild>] in OnInit / guild change
M.selected = {}    -- [playerName] = true (UI multi-select)

local function emptyState()
    return { standings = {}, log = {} }
end

local function currentGuild()
    if not GetGuildInfo then return nil end
    local g = GetGuildInfo("player")
    if g and g ~= "" then return g end
    return nil
end

function M:LoadGuildState()
    local g = currentGuild()
    if not g then self.state = nil; self.guild = nil; return end
    RMS.db.dkp = RMS.db.dkp or {}
    RMS.db.dkp[g] = RMS.db.dkp[g] or emptyState()
    self.state = RMS.db.dkp[g]
    self.guild = g
end

local function pushLog(entry)
    if not M.state then return end
    table.insert(M.state.log, 1, entry)
    if #M.state.log > 500 then table.remove(M.state.log) end
end

-- ---------- officer detection ----------
function M:OfficerThreshold()
    if RMS.db.dkp_officerRank ~= nil then return RMS.db.dkp_officerRank end
    return 2  -- default: GM(0), Officer(1), Raid Leader(2) = officer-tier
end

function M:_RankIndexOf(playerName)
    if not GetNumGuildMembers then return nil end
    if GuildRoster then GuildRoster() end  -- request fresh data
    local n = GetNumGuildMembers() or 0
    for i = 1, n do
        local name, _, rankIndex = GetGuildRosterInfo(i)
        if name == playerName then return rankIndex end
    end
    return nil
end

function M:IsOfficer(playerName)
    playerName = playerName or RMS:PlayerName()
    local r = self:_RankIndexOf(playerName)
    if not r then return false end
    return r <= self:OfficerThreshold()
end

-- ---------- guild roster snapshot ----------
function M:GuildMembers()
    if not GetNumGuildMembers then return {} end
    if GuildRoster then GuildRoster() end
    local n = GetNumGuildMembers() or 0
    local out = {}
    for i = 1, n do
        local name, _, rankIndex, _, classDisplay, _, _, _, online, _, classFile = GetGuildRosterInfo(i)
        if name then
            out[#out+1] = { name = name, class = classFile or classDisplay,
                            rank = rankIndex, online = online }
        end
    end
    return out
end

-- ---------- core actions (officer only) ----------
local function ensureStanding(name, class)
    M.state.standings[name] = M.state.standings[name] or {
        balance = 0, earned = 0, spent = 0, class = class,
    }
    if class and not M.state.standings[name].class then
        M.state.standings[name].class = class
    end
    return M.state.standings[name]
end

local function applyDelta(name, delta, class)
    local s = ensureStanding(name, class)
    s.balance = (s.balance or 0) + delta
    if delta > 0 then s.earned = (s.earned or 0) + delta
    else              s.spent  = (s.spent  or 0) - delta end  -- delta is negative
end

function M:Award(players, delta, reason)
    if not self.state then RMS:Print("Not in a guild.") return end
    if not self:IsOfficer() then RMS:Print("Only officers can change DKP.") return end
    if not players or #players == 0 then RMS:Print("No players selected.") return end
    delta = tonumber(delta); if not delta or delta == 0 then RMS:Print("Bad amount.") return end

    -- apply locally
    local roster = self:GuildMembers()
    local classMap = {}
    for _, m in ipairs(roster) do classMap[m.name] = m.class end

    local actionId = RMS:PlayerName()..":"..tostring(math.floor(GetTime()*1000))
    for _, name in ipairs(players) do
        applyDelta(name, delta, classMap[name])
    end
    pushLog({
        id = actionId, time = time(), by = RMS:PlayerName(),
        delta = delta, reason = reason or "",
        players = table.concat(players, ","),
    })

    RMS.Comm:Send("dkp", "delta", {
        id = actionId, by = RMS:PlayerName(),
        d = delta, r = reason or "",
        p = table.concat(players, ","),
    }, "GUILD")
    RMS:Print("DKP %s%d to %d player(s) (%s)",
        delta >= 0 and "+" or "", delta, #players, reason or "no reason")
    self:Refresh()
end

function M:Reset()
    if not self.state then return end
    if not self:IsOfficer() then RMS:Print("Only officers can reset DKP.") return end
    self.state.standings = {}
    pushLog({ time = time(), by = RMS:PlayerName(), delta = 0, reason = "RESET ALL", players = "*" })
    RMS.Comm:Send("dkp", "reset", { by = RMS:PlayerName() }, "GUILD")
    RMS:Print("DKP standings reset.")
    self:Refresh()
end

-- ---------- comm ----------
RMS.Comm:On("dkp", "delta", function(p, sender)
    if not M.state then return end
    if not M:IsOfficer(sender) then return end
    if sender == RMS:PlayerName() then return end  -- already applied locally
    local delta = tonumber(p.d); if not delta then return end
    local players = {}
    for nm in (p.p or ""):gmatch("[^,]+") do players[#players+1] = nm end
    local roster = M:GuildMembers()
    local classMap = {}
    for _, m in ipairs(roster) do classMap[m.name] = m.class end
    for _, name in ipairs(players) do applyDelta(name, delta, classMap[name]) end
    pushLog({
        id = p.id, time = time(), by = sender,
        delta = delta, reason = p.r or "", players = p.p or "",
    })
    M:Refresh()
end)

RMS.Comm:On("dkp", "reset", function(_, sender)
    if not M.state then return end
    if not M:IsOfficer(sender) then return end
    M.state.standings = {}
    pushLog({ time = time(), by = sender, delta = 0, reason = "RESET ALL", players = "*" })
    M:Refresh()
end)

-- ---------- late-join sync ----------
function M:RequestSync()
    if not self.state then return end
    RMS.Comm:Send("dkp", "syncreq", { from = RMS:PlayerName(), have = #self.state.log }, "GUILD")
end

RMS.Comm:On("dkp", "syncreq", function(p, sender)
    if not M.state then return end
    if not M:IsOfficer() then return end          -- only officers respond
    if sender == RMS:PlayerName() then return end
    local theirs = tonumber(p.have) or 0
    if theirs >= #M.state.log then return end     -- they already have at least as much
    M:_WhisperFullState(sender)
end)

function M:_WhisperFullState(target)
    -- Snapshot the state into compact pages (one per ~30 entries, simple format).
    -- Then the receiver applies as a "full overwrite".
    local players = {}
    for name, s in pairs(self.state.standings) do
        players[#players+1] = ("%s/%d/%d/%d/%s"):format(
            name, s.balance or 0, s.earned or 0, s.spent or 0, s.class or "?"
        )
    end
    -- Fits comfortably in addon channel: chunk every ~10 entries to be safe
    local chunk_size = 10
    local total_pages = math.ceil(math.max(1, #players) / chunk_size)
    for page = 1, total_pages do
        local lo = (page - 1) * chunk_size + 1
        local hi = math.min(lo + chunk_size - 1, #players)
        local sub = {}
        for i = lo, hi do sub[#sub+1] = players[i] end
        RMS.Comm:SendWhisper("dkp", "syncpage", {
            page = page, total = total_pages,
            data = table.concat(sub, "|"),
        }, target)
    end
end

RMS.Comm:On("dkp", "syncpage", function(p, sender)
    if not M.state then return end
    if not M:IsOfficer(sender) then return end
    -- on first page, clear standings
    local page = tonumber(p.page) or 1
    if page == 1 then
        M.state.standings = {}
        M._syncReceiving = true
    end
    for entry in (p.data or ""):gmatch("[^|]+") do
        local name, bal, earn, spent, cls = entry:match("([^/]+)/(%-?%d+)/(%-?%d+)/(%-?%d+)/(.*)")
        if name then
            M.state.standings[name] = {
                balance = tonumber(bal) or 0,
                earned  = tonumber(earn) or 0,
                spent   = tonumber(spent) or 0,
                class   = (cls and cls ~= "?") and cls or nil,
            }
        end
    end
    if page == (tonumber(p.total) or 1) then
        M._syncReceiving = false
        pushLog({ time = time(), by = sender, delta = 0,
                  reason = "SYNCED FROM "..sender, players = "*" })
        M:Refresh()
        RMS:Print("DKP synced from %s.", sender)
    end
end)

-- ---------- events ----------
M.events = {
    PLAYER_LOGIN = function(self)
        self:LoadGuildState()
        local d = CreateFrame("Frame"); local t = 0
        d:SetScript("OnUpdate", function(s, dt)
            t = t + dt
            if t > 4 then s:SetScript("OnUpdate", nil); self:RequestSync() end
        end)
    end,
    PLAYER_GUILD_UPDATE  = function(self) self:LoadGuildState(); if self._ui then self:Refresh() end end,
    GUILD_ROSTER_UPDATE  = function(self) if self._ui then self:Refresh() end end,
}

-- ---------- slash ----------
function M:OnSlash(arg)
    arg = (arg or ""):gsub("^%s+",""):gsub("%s+$","")
    if arg == "sync"  then return self:RequestSync() end
    if arg == "reset" then return self:Reset()       end
    RMS.UI:Show("dkp")
end

-- =============================================================
-- UI
-- =============================================================

local function CLASS_HEX(token)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if c then return ("ff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) end
    return "ffffffff"
end

function M:BuildUI(parent)
    local Skin = RMS.Skin
    local C    = Skin.COLOR
    local panel = CreateFrame("Frame", nil, parent)

    local header = Skin:Header(panel, "DKP Standings")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)

    -- status below the header so it doesn't get clipped
    local status = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(status, 11, true)
    status:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 4, -4)
    status:SetPoint("RIGHT", header, "RIGHT", -10, 0)
    status:SetJustifyH("LEFT")

    -- ===== left column: standings list with checkboxes =====
    local LIST_W = 340
    local listHdr = Skin:Header(panel, "Roster")
    listHdr:SetPoint("TOPLEFT", status, "BOTTOMLEFT", -4, -6)
    listHdr:SetWidth(LIST_W)

    local function buildRow(parent)
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(20)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg

        local box = CreateFrame("Button", nil, r)
        box:SetSize(14, 14); box:SetPoint("LEFT", 4, 0)
        Skin:SetBackdrop(box, C.bgRow, C.border)
        local check = box:CreateTexture(nil, "OVERLAY")
        check:SetTexture(Skin.TEX_WHITE); check:SetVertexColor(unpack(C.accent))
        check:SetPoint("TOPLEFT", 3, -3); check:SetPoint("BOTTOMRIGHT", -3, 3); check:Hide()
        box._check = check
        r.box = box

        local who = r:CreateFontString(nil, "OVERLAY"); Skin:Font(who, 11, true)
        who:SetPoint("LEFT", box, "RIGHT", 6, 0); who:SetWidth(110)
        who:SetJustifyH("LEFT"); who:SetWordWrap(false); who:SetNonSpaceWrap(false)
        r.who = who

        local bal = r:CreateFontString(nil, "OVERLAY"); Skin:Font(bal, 11, true)
        bal:SetPoint("LEFT", who, "RIGHT", 4, 0); bal:SetWidth(48)
        bal:SetJustifyH("RIGHT"); bal:SetTextColor(unpack(C.accent)); r.bal = bal

        local earn = r:CreateFontString(nil, "OVERLAY"); Skin:Font(earn, 10, false)
        earn:SetPoint("LEFT", bal, "RIGHT", 4, 0); earn:SetWidth(46)
        earn:SetJustifyH("RIGHT"); earn:SetTextColor(unpack(C.textDim)); r.earn = earn

        local spent = r:CreateFontString(nil, "OVERLAY"); Skin:Font(spent, 10, false)
        spent:SetPoint("LEFT", earn, "RIGHT", 4, 0); spent:SetWidth(46)
        spent:SetJustifyH("RIGHT"); spent:SetTextColor(unpack(C.textDim)); r.spent = spent

        local online = r:CreateFontString(nil, "OVERLAY"); Skin:Font(online, 9, false)
        online:SetPoint("RIGHT", -6, 0); online:SetWidth(28)
        online:SetJustifyH("RIGHT"); r.online = online
        return r
    end
    local function updateRow(r, item, idx, alt)
        if not item then return end
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        r.who:SetText(("|c%s%s|r"):format(CLASS_HEX(item.class), item.name))
        r.bal:SetText(tostring(item.balance or 0))
        r.earn:SetText("+"..(item.earned or 0))
        r.spent:SetText("-"..(item.spent or 0))
        r.online:SetText(item.online and "|cff60ff60on|r" or "|cff666666off|r")
        if M.selected[item.name] then r.box._check:Show() else r.box._check:Hide() end
        r.box:SetScript("OnClick", function()
            M.selected[item.name] = not M.selected[item.name] or nil
            M:Refresh()
        end)
    end
    local listScroll = Skin:ScrollList(panel, 20, buildRow, updateRow)
    listScroll:SetPoint("TOPLEFT",  listHdr, "BOTTOMLEFT", 0, -2)
    listScroll:SetPoint("BOTTOMLEFT", listHdr, "BOTTOMLEFT", 0, -180)  -- placeholder; fixed below
    listScroll:SetWidth(LIST_W)
    -- (will reset bottom anchor after log header is created)

    -- ===== right column: action panel + log =====
    local actHdr = Skin:Header(panel, "Award / Deduct")
    actHdr:SetPoint("TOPLEFT", listHdr, "TOPRIGHT", 8, 0)
    actHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    local actBody = Skin:Panel(panel)
    actBody:SetPoint("TOPLEFT", actHdr, "BOTTOMLEFT", 0, -2)
    actBody:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    actBody:SetHeight(240)

    local selFs = actBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(selFs, 11, false); selFs:SetTextColor(unpack(C.text))
    selFs:SetPoint("TOPLEFT", 8, -6); selFs:SetPoint("RIGHT", -8, 0)
    selFs:SetJustifyH("LEFT"); selFs:SetWordWrap(false); selFs:SetNonSpaceWrap(false)

    -- Reason on its own row (full width)
    local rsnLabel = actBody:CreateFontString(nil, "OVERLAY"); Skin:Font(rsnLabel, 10, false)
    rsnLabel:SetTextColor(unpack(C.textDim))
    rsnLabel:SetPoint("TOPLEFT", selFs, "BOTTOMLEFT", 0, -8); rsnLabel:SetWidth(50)
    rsnLabel:SetText("Reason:")
    local rsnEdit = Skin:EditBox(actBody, 1, 22)
    rsnEdit:SetPoint("LEFT", rsnLabel, "RIGHT", 4, 0)
    rsnEdit:SetPoint("RIGHT", actBody, "RIGHT", -8, 0)

    -- Amount + Award + Deduct row
    local amtLabel = actBody:CreateFontString(nil, "OVERLAY"); Skin:Font(amtLabel, 10, false)
    amtLabel:SetTextColor(unpack(C.textDim))
    amtLabel:SetPoint("TOPLEFT", rsnLabel, "BOTTOMLEFT", 0, -10); amtLabel:SetWidth(50)
    amtLabel:SetText("Amount:")
    local amtEdit = Skin:EditBox(actBody, 50, 22)
    amtEdit:SetPoint("LEFT", amtLabel, "RIGHT", 4, 0)
    amtEdit:SetNumeric(true); amtEdit:SetText("10")

    local function selectedNames()
        local out = {}
        for nm in pairs(M.selected) do out[#out+1] = nm end
        table.sort(out); return out
    end

    local awardBtn = Skin:Button(actBody, "Award (+)", 80, 22)
    awardBtn:SetPoint("LEFT", amtEdit, "RIGHT", 6, 0)
    awardBtn:SetScript("OnMouseUp", function()
        local v = tonumber(amtEdit:GetText() or "")
        if not v or v <= 0 then RMS:Print("Bad amount.") return end
        self:Award(selectedNames(), v, rsnEdit:GetText())
    end)
    local dedBtn = Skin:Button(actBody, "Deduct (-)", 80, 22)
    dedBtn:SetPoint("LEFT", awardBtn, "RIGHT", 4, 0)
    dedBtn:SetScript("OnMouseUp", function()
        local v = tonumber(amtEdit:GetText() or "")
        if not v or v <= 0 then RMS:Print("Bad amount.") return end
        self:Award(selectedNames(), -v, rsnEdit:GetText())
    end)

    -- Presets row (own line, narrower buttons)
    local presetLbl = actBody:CreateFontString(nil, "OVERLAY"); Skin:Font(presetLbl, 10, false)
    presetLbl:SetTextColor(unpack(C.textDim))
    presetLbl:SetPoint("TOPLEFT", amtLabel, "BOTTOMLEFT", 0, -14); presetLbl:SetWidth(50)
    presetLbl:SetText("Presets:")

    local p1 = Skin:Button(actBody, "+10 Boss",  78, 22)
    p1:SetPoint("LEFT", presetLbl, "RIGHT", 4, 0)
    p1:SetScript("OnMouseUp", function() self:Award(selectedNames(), 10, "Boss kill") end)
    local p2 = Skin:Button(actBody, "+5 Attend", 78, 22)
    p2:SetPoint("LEFT", p1, "RIGHT", 4, 0)
    p2:SetScript("OnMouseUp", function() self:Award(selectedNames(), 5, "Attendance") end)
    local p3 = Skin:Button(actBody, "-2 Wipe",   60, 22)
    p3:SetPoint("LEFT", p2, "RIGHT", 4, 0)
    p3:SetScript("OnMouseUp", function() self:Award(selectedNames(), -2, "Wipe") end)

    -- Bulk select row
    local bulkLbl = actBody:CreateFontString(nil, "OVERLAY"); Skin:Font(bulkLbl, 10, false)
    bulkLbl:SetTextColor(unpack(C.textDim))
    bulkLbl:SetPoint("TOPLEFT", presetLbl, "BOTTOMLEFT", 0, -14); bulkLbl:SetWidth(50)
    bulkLbl:SetText("Select:")

    local function selectBy(predicate)
        wipe(M.selected)
        for _, m in ipairs(M:GuildMembers()) do
            if predicate(m) then M.selected[m.name] = true end
        end
        self:Refresh()
    end
    local selAll = Skin:Button(actBody, "All Online", 80, 22)
    selAll:SetPoint("LEFT", bulkLbl, "RIGHT", 4, 0)
    selAll:SetScript("OnMouseUp", function() selectBy(function(m) return m.online end) end)
    local selRaid = Skin:Button(actBody, "In Raid", 64, 22)
    selRaid:SetPoint("LEFT", selAll, "RIGHT", 4, 0)
    selRaid:SetScript("OnMouseUp", function()
        local roster = RMS:GetRosterNames()
        wipe(M.selected)
        for _, nm in ipairs(roster) do M.selected[nm] = true end
        self:Refresh()
    end)
    local selNone = Skin:Button(actBody, "Clear", 56, 22)
    selNone:SetPoint("LEFT", selRaid, "RIGHT", 4, 0)
    selNone:SetScript("OnMouseUp", function() wipe(M.selected); self:Refresh() end)

    -- Reset (bottom-right)
    local resetBtn = Skin:Button(actBody, "Reset All", 80, 22)
    resetBtn:SetPoint("BOTTOMRIGHT", -8, 8)
    resetBtn:SetScript("OnMouseUp", function() self:Reset() end)

    -- ===== log =====
    local logHdr = Skin:Header(panel, "Recent Log")
    logHdr:SetPoint("TOPLEFT", actBody, "BOTTOMLEFT", 0, -8)
    logHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    -- now that the log header exists, anchor the roster's bottom above it
    listScroll:ClearAllPoints()
    listScroll:SetPoint("TOPLEFT", listHdr, "BOTTOMLEFT", 0, -2)
    listScroll:SetPoint("BOTTOMLEFT", logHdr, "TOPLEFT", 0, -2)
    listScroll:SetWidth(LIST_W)

    local function buildLogRow(parent)
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(18)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
        local fs = r:CreateFontString(nil, "OVERLAY"); Skin:Font(fs, 10, false)
        fs:SetPoint("LEFT", 6, 0); fs:SetPoint("RIGHT", -6, 0)
        fs:SetJustifyH("LEFT"); fs:SetWordWrap(false); fs:SetNonSpaceWrap(false)
        r.fs = fs
        return r
    end
    local function updateLogRow(r, item, idx, alt)
        if not item then return end
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.5)
        local hhmm = date("%m/%d %H:%M", item.time or 0)
        local delta = item.delta or 0
        local color = (delta > 0 and "|cff60ff60+") or (delta < 0 and "|cffff6060") or "|cffffffff"
        r.fs:SetText(("|cff999999%s|r %s%d|r  %s  |cff666666(%s by %s)|r"):format(
            hhmm, color, delta, item.players or "?", item.reason or "", item.by or "?"))
    end
    local logScroll = Skin:ScrollList(panel, 18, buildLogRow, updateLogRow)
    logScroll:SetPoint("TOPLEFT", logHdr, "BOTTOMLEFT", 0, -2)
    logScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 8)

    self._ui = {
        panel = panel, status = status, selFs = selFs,
        listScroll = listScroll, logScroll = logScroll,
        amtEdit = amtEdit, rsnEdit = rsnEdit,
        awardBtn = awardBtn, dedBtn = dedBtn, resetBtn = resetBtn,
        p1 = p1, p2 = p2, p3 = p3,
    }
    self:Refresh()
    return panel
end

function M:Refresh()
    if not self._ui then return end
    local C = RMS.Skin.COLOR

    -- header status
    if not self.state then
        self._ui.status:SetText("|cffff6060No guild|r")
    else
        local role = self:IsOfficer() and "|cff60ff60Officer|r" or "|cffaaaaaaMember|r"
        self._ui.status:SetText(("Guild: %s | %s"):format(self.guild, role))
    end

    -- selection summary
    local sel = {}
    for nm in pairs(self.selected) do sel[#sel+1] = nm end
    table.sort(sel)
    self._ui.selFs:SetText(("Selected: %d (%s)"):format(#sel,
        #sel == 0 and "none" or table.concat(sel, ", "):sub(1, 100)))

    -- enable/disable officer-only controls
    local canWrite = self.state and self:IsOfficer()
    for _, b in ipairs({ self._ui.awardBtn, self._ui.dedBtn, self._ui.resetBtn,
                         self._ui.p1, self._ui.p2, self._ui.p3 }) do
        if canWrite then b:Enable() else b:Disable() end
    end

    -- merge guild roster + standings into unified list
    local rows = {}
    if self.state then
        local roster = self:GuildMembers()
        local seen = {}
        for _, m in ipairs(roster) do
            local s = self.state.standings[m.name] or {}
            rows[#rows+1] = {
                name = m.name, class = m.class, online = m.online,
                balance = s.balance or 0, earned = s.earned or 0, spent = s.spent or 0,
            }
            seen[m.name] = true
        end
        -- include tracked players who left the guild
        for name, s in pairs(self.state.standings) do
            if not seen[name] then
                rows[#rows+1] = { name = name, class = s.class, online = false,
                                  balance = s.balance or 0, earned = s.earned or 0, spent = s.spent or 0 }
            end
        end
        -- sort: balance desc, then name
        table.sort(rows, function(a, b)
            if (a.balance or 0) ~= (b.balance or 0) then return (a.balance or 0) > (b.balance or 0) end
            return a.name < b.name
        end)
    end
    self._ui.listScroll:SetData(rows)

    -- log
    self._ui.logScroll:SetData(self.state and self.state.log or {})
end
