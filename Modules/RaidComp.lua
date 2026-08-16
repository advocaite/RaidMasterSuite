-- Raid Master Suite -- Raid Comp Builder
-- Pick a raid, see the typical composition (tanks/healers/dps + GS bar) and a
-- live buff/debuff coverage checklist evaluated against your current group.
-- Spec-specific buffs use specs detected by the BiS module (RMS raiders
-- broadcast theirs); for raiders without the addon we only know the class.

local RMS = RaidMasterSuite
local M = RMS:RegisterModule("raidcomp", { title = "Raid Comp", order = 7 })

local TEX_OK      = "Interface\\RaidFrame\\ReadyCheck-Ready"
local TEX_MISSING = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local TEX_MAYBE   = "Interface\\RaidFrame\\ReadyCheck-Waiting"

local function CLASS_COLOR(token)
    local c = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if c then return ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) end
    return "|cffffffff"
end

local CLASS_NAMES = {
    DEATHKNIGHT="DK", PALADIN="Paladin", WARRIOR="Warrior", HUNTER="Hunter",
    ROGUE="Rogue", PRIEST="Priest", SHAMAN="Shaman", MAGE="Mage",
    WARLOCK="Warlock", DRUID="Druid",
}

-- ---------- roster ----------
-- {name, class, spec?} for everyone grouped; spec from BiS module peers.
local function rosterMembers()
    local bis   = RMS:GetModule("bis")
    local peers = (bis and bis.peers) or {}
    local out = {}
    local n = GetNumRaidMembers()
    if n > 0 then
        for i = 1, n do
            local name, _, _, _, _, classToken = GetRaidRosterInfo(i)
            if name then
                out[#out+1] = { name = name, class = classToken,
                                spec = peers[name] and peers[name].spec }
            end
        end
        return out
    end
    local me = RMS:PlayerName()
    local _, myTok = UnitClass("player")
    out[#out+1] = { name = me, class = myTok, spec = peers[me] and peers[me].spec }
    for i = 1, GetNumPartyMembers() do
        local nm = UnitName("party"..i)
        if nm then
            local _, tok = UnitClass("party"..i)
            out[#out+1] = { name = nm, class = tok, spec = peers[nm] and peers[nm].spec }
        end
    end
    return out
end

-- ---------- coverage ----------
-- "ok" (someone provides it), "maybe" (right class present but their spec is
-- unknown or wrong for a spec-specific buff), "no" (nobody can bring it)
local function evalBuff(buff, members)
    local maybeWho
    for _, m in ipairs(members) do
        for _, p in ipairs(buff.providers) do
            if m.class == p.class then
                if not p.spec then
                    return "ok", m.name
                elseif m.spec == p.spec then
                    return "ok", m.name
                elseif not m.spec then
                    maybeWho = maybeWho or m.name
                end
            end
        end
    end
    if maybeWho then return "maybe", maybeWho end
    return "no"
end

local function providersText(buff)
    local parts = {}
    for _, p in ipairs(buff.providers) do
        local label = CLASS_NAMES[p.class] or p.class
        if p.spec then label = p.spec:gsub("_", " ").." "..label end
        parts[#parts+1] = CLASS_COLOR(p.class)..label.."|r"
    end
    return table.concat(parts, ", ")
end

-- ---------- selection ----------
local function raidByKey(key)
    for _, r in ipairs(RMS.RaidComps or {}) do
        if r.key == key then return r end
    end
    return nil
end

function M:SelectedRaid()
    return raidByKey(self._selected) or (RMS.RaidComps or {})[1]
end

-- default: biggest raid of the current BiS phase
local function defaultRaidKey()
    local bis = RMS:GetModule("bis")
    local phase = bis and bis.GetPhase and bis:GetPhase()
    if not phase or phase < 1 then return "icc25" end
    local best
    for _, r in ipairs(RMS.RaidComps or {}) do
        if r.phase == phase and (not best or r.size > best.size) then best = r end
    end
    return best and best.key or "icc25"
end

-- ---------- UI ----------
function M:BuildUI(parent)
    local Skin = RMS.Skin
    local C    = Skin.COLOR
    local panel = CreateFrame("Frame", nil, parent)

    local header = Skin:Header(panel, "Raid Comp Builder")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)

    -- left: raid list
    local raidCol = Skin:Panel(panel); raidCol:SetWidth(210)
    raidCol:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -8)
    raidCol:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 8)

    local raidHdr = raidCol:CreateFontString(nil, "OVERLAY")
    Skin:Font(raidHdr, 11, true)
    raidHdr:SetTextColor(unpack(C.accent))
    raidHdr:SetPoint("TOPLEFT", 6, -4)
    raidHdr:SetText("Raid")

    local function buildRaidRow(parent)
        local r = CreateFrame("Button", nil, parent)
        r:SetHeight(22)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
        local hl = r:CreateTexture(nil, "BORDER"); hl:SetAllPoints(); hl:SetTexture(Skin.TEX_WHITE)
        hl:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.18); hl:Hide(); r.hl = hl
        local fs = r:CreateFontString(nil, "OVERLAY"); Skin:Font(fs, 11, false)
        fs:SetPoint("LEFT", 6, 0); fs:SetPoint("RIGHT", -6, 0)
        fs:SetJustifyH("LEFT"); fs:SetWordWrap(false); fs:SetNonSpaceWrap(false)
        r.fs = fs
        return r
    end
    local function updRaidRow(r, item, idx, alt)
        if not item then return end
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        r.fs:SetText(("|cff888888P%d|r  %s |cffffd070%d|r"):format(item.phase, item.name, item.size))
        if M._selected == item.key then r.hl:Show() else r.hl:Hide() end
        r:SetScript("OnClick", function()
            M._selected = item.key
            M:Refresh()
        end)
    end
    local raidList = Skin:ScrollList(raidCol, 22, buildRaidRow, updRaidRow)
    raidList:SetPoint("TOPLEFT", 0, -22); raidList:SetPoint("BOTTOMRIGHT", 0, 0)

    -- right top: comp summary
    local infoBody = Skin:Panel(panel)
    infoBody:SetPoint("TOPLEFT", raidCol, "TOPRIGHT", 6, 0)
    infoBody:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    infoBody:SetHeight(96)

    local infoName = infoBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(infoName, 14, true)
    infoName:SetTextColor(unpack(C.textHead))
    infoName:SetPoint("TOPLEFT", 10, -8)

    local infoGS = infoBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(infoGS, 13, true)
    infoGS:SetTextColor(unpack(C.accent))
    infoGS:SetPoint("TOPRIGHT", -10, -8)

    local infoComp = infoBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(infoComp, 12, false)
    infoComp:SetTextColor(unpack(C.text))
    infoComp:SetPoint("TOPLEFT", infoName, "BOTTOMLEFT", 0, -6)

    local infoNotes = infoBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(infoNotes, 10, false)
    infoNotes:SetTextColor(unpack(C.textDim))
    infoNotes:SetPoint("TOPLEFT", infoComp, "BOTTOMLEFT", 0, -6)
    infoNotes:SetPoint("RIGHT", infoBody, "RIGHT", -10, 0)
    infoNotes:SetJustifyH("LEFT"); infoNotes:SetWordWrap(true)

    -- right: coverage list
    local covHdr = Skin:Header(panel, "Buff & Debuff Coverage")
    covHdr:SetPoint("TOPLEFT", infoBody, "BOTTOMLEFT", 0, -8)
    covHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    local refreshBtn = Skin:Button(covHdr, "Refresh", 70, 20)
    refreshBtn:SetPoint("RIGHT", -6, 0)
    refreshBtn:SetScript("OnMouseUp", function()
        local bis = RMS:GetModule("bis")
        if bis and RMS:InGroup() then RMS.Comm:Send("bis", "specreq", {}) end
        M:Refresh()
    end)

    local covStatus = covHdr:CreateFontString(nil, "OVERLAY")
    Skin:Font(covStatus, 10, false)
    covStatus:SetTextColor(unpack(C.textDim))
    covStatus:SetPoint("RIGHT", refreshBtn, "LEFT", -10, 0)

    local function buildCovRow(parent)
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(20)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
        local icon = r:CreateTexture(nil, "OVERLAY")
        icon:SetSize(14, 14); icon:SetPoint("LEFT", 5, 0); r.icon = icon
        local name = r:CreateFontString(nil, "OVERLAY"); Skin:Font(name, 11, false)
        name:SetPoint("LEFT", 24, 0); name:SetWidth(290)
        name:SetJustifyH("LEFT"); name:SetWordWrap(false); name:SetNonSpaceWrap(false)
        r.name = name
        local who = r:CreateFontString(nil, "OVERLAY"); Skin:Font(who, 10, false)
        who:SetPoint("LEFT", name, "RIGHT", 6, 0); who:SetPoint("RIGHT", -6, 0)
        who:SetJustifyH("RIGHT"); who:SetWordWrap(false); who:SetNonSpaceWrap(false)
        r.who = who
        return r
    end
    local function updCovRow(r, item, idx, alt)
        if not item then return end
        if item.section then
            r.bg:SetVertexColor(0.14, 0.14, 0.16, 0.9)
            r.icon:Hide()
            r.name:SetText(("|cffffd070-- %s --|r"):format(item.section))
            r.who:SetText("")
            return
        end
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        r.icon:Show()
        r.name:SetText(item.buff.name)
        if item.status == "ok" then
            r.icon:SetTexture(TEX_OK)
            r.who:SetText(("|cff60ff60%s|r"):format(item.who or ""))
        elseif item.status == "maybe" then
            r.icon:SetTexture(TEX_MAYBE)
            r.who:SetText(("|cffffd070%s?|r  |cff888888(spec unknown)|r"):format(item.who or ""))
        else
            r.icon:SetTexture(TEX_MISSING)
            r.who:SetText("|cffff5050missing:|r "..providersText(item.buff))
        end
    end
    local covList = Skin:ScrollList(panel, 20, buildCovRow, updCovRow)
    covList:SetPoint("TOPLEFT", covHdr, "BOTTOMLEFT", 0, -2)
    covList:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 24)

    local hint = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(hint, 9, false)
    hint:SetTextColor(unpack(C.textDim))
    hint:SetPoint("BOTTOMLEFT", covList, "BOTTOMLEFT", 2, -14)
    hint:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("Spec-specific buffs need raiders running RMS (specs auto-broadcast). GS values are typical pug asks -- edit Data\\RaidCompData.lua to taste.")

    self._selected = self._selected or defaultRaidKey()
    self._ui = {
        panel = panel, raidList = raidList, covList = covList,
        infoName = infoName, infoGS = infoGS, infoComp = infoComp,
        infoNotes = infoNotes, covStatus = covStatus,
    }
    self:Refresh()
    return panel
end

function M:Refresh()
    if not self._ui then return end

    self._ui.raidList:SetData(RMS.RaidComps or {})

    local raid = self:SelectedRaid()
    if not raid then return end

    self._ui.infoName:SetText(("%s |cff888888(%d-man, P%d)|r"):format(raid.name, raid.size, raid.phase))
    self._ui.infoGS:SetText(("GS %d+"):format(raid.minGS))
    local dps = raid.size - raid.tanks - raid.healers
    self._ui.infoComp:SetText(("|cffffd070%d|r Tank%s   |cff60ff60%d|r Healer%s   |cffff8080%d|r DPS"):format(
        raid.tanks, raid.tanks == 1 and "" or "s",
        raid.healers, raid.healers == 1 and "" or "s", dps))
    self._ui.infoNotes:SetText(raid.notes or "")

    -- coverage vs current group
    local members = rosterMembers()
    local okCount, total = 0, 0
    local rows, lastCat = {}, nil
    for _, buff in ipairs(RMS.RaidBuffs or {}) do
        if buff.cat ~= lastCat then
            rows[#rows+1] = { section = buff.cat }
            lastCat = buff.cat
        end
        local status, who = evalBuff(buff, members)
        total = total + 1
        if status == "ok" then okCount = okCount + 1 end
        rows[#rows+1] = { buff = buff, status = status, who = who }
    end
    self._ui.covList:SetData(rows)

    local label = RMS:InRaid() and "raid" or (RMS:InGroup() and "party" or "solo")
    self._ui.covStatus:SetText(("%d/%d covered by your %s (%d members)"):format(
        okCount, total, label, #members))
end

M.events = {
    RAID_ROSTER_UPDATE    = function(self) if self._ui then self:Refresh() end end,
    PARTY_MEMBERS_CHANGED = function(self) if self._ui then self:Refresh() end end,
}

function M:OnSlash(arg)
    RMS.UI:Show("raidcomp")
end
