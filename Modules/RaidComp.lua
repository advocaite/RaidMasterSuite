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
    local raidCol = Skin:Panel(panel); raidCol:SetWidth(170)
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

    -- right: coverage list (helper column sits to its right)
    local covHdr = Skin:Header(panel, "Buff & Debuff Coverage")
    covHdr:SetPoint("TOPLEFT", infoBody, "BOTTOMLEFT", 0, -8)
    covHdr:SetPoint("RIGHT", panel, "RIGHT", -252, 0)

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
        name:SetPoint("LEFT", 24, 0); name:SetWidth(165)
        name:SetJustifyH("LEFT"); name:SetWordWrap(false); name:SetNonSpaceWrap(false)
        r.name = name
        local who = r:CreateFontString(nil, "OVERLAY"); Skin:Font(who, 10, false)
        who:SetPoint("LEFT", name, "RIGHT", 6, 0); who:SetPoint("RIGHT", -6, 0)
        who:SetJustifyH("RIGHT"); who:SetWordWrap(false); who:SetNonSpaceWrap(false)
        r.who = who

        -- the column truncates long buff names; hover shows everything
        r:EnableMouse(true)
        r:SetScript("OnEnter", function(s)
            local item = s._item
            if not item or item.section then return end
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            GameTooltip:AddLine(item.buff.name, 1, 0.85, 0.5, true)
            if item.status == "ok" then
                GameTooltip:AddLine("Covered by "..(item.who or "?"), 0.4, 1, 0.4, true)
            elseif item.status == "maybe" then
                GameTooltip:AddLine((item.who or "?").." is the right class, but their spec is unknown (not running RMS).", 1, 0.82, 0.3, true)
            else
                GameTooltip:AddLine("Nobody in the group can provide this.", 1, 0.35, 0.35, true)
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Provided by:", 0.92, 0.92, 0.94)
            for _, p in ipairs(item.buff.providers) do
                local label = CLASS_NAMES[p.class] or p.class
                if p.spec then label = p.spec:gsub("_", " ").." "..label end
                local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[p.class]
                GameTooltip:AddLine("  "..label,
                    c and c.r or 1, c and c.g or 1, c and c.b or 1)
            end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return r
    end
    local function updCovRow(r, item, idx, alt)
        if not item then return end
        r._item = item
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
    covList:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -252, 24)

    -- ============ Raid Helper column ============
    local helpHdr = Skin:Header(panel, "Raid Helper")
    helpHdr:SetPoint("TOPLEFT", covHdr, "TOPRIGHT", 6, 0)
    helpHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    local helpBody = Skin:Panel(panel)
    helpBody:SetPoint("TOPLEFT", helpHdr, "BOTTOMLEFT", 0, -2)
    helpBody:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 8)

    local rosterFs = helpBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(rosterFs, 11, true)
    rosterFs:SetTextColor(unpack(C.text))
    rosterFs:SetPoint("TOPLEFT", 8, -8)
    rosterFs:SetPoint("RIGHT", -8, 0)
    rosterFs:SetJustifyH("LEFT")

    local needFs = helpBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(needFs, 10, false)
    needFs:SetTextColor(unpack(C.textDim))
    needFs:SetPoint("TOPLEFT", rosterFs, "BOTTOMLEFT", 0, -6)
    needFs:SetPoint("RIGHT", -8, 0)
    needFs:SetJustifyH("LEFT"); needFs:SetWordWrap(true)
    needFs:SetHeight(56)

    local advertBtn = Skin:Button(helpBody, "Prefill Advert & Go", 150, 22)
    advertBtn:SetPoint("TOPLEFT", needFs, "BOTTOMLEFT", 0, -4)
    advertBtn:SetScript("OnMouseUp", function() self:PrefillAdvert() end)
    Skin:AttachTooltip(advertBtn, "Prefill Advert",
        { "Fills the Advertising tab with this raid's name, GS ask and the roles/classes you're missing, then takes you there." })

    -- prospect tracker
    local prosLbl = helpBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(prosLbl, 11, true)
    prosLbl:SetTextColor(unpack(C.accent))
    prosLbl:SetPoint("TOPLEFT", advertBtn, "BOTTOMLEFT", 0, -10)
    prosLbl:SetText("Prospects")

    local prosEdit = Skin:EditBox(helpBody, 110, 20)
    prosEdit:SetPoint("TOPLEFT", prosLbl, "BOTTOMLEFT", 0, -4)
    prosEdit:SetFrameLevel(helpBody:GetFrameLevel() + 5)
    prosEdit:SetScript("OnMouseDown", function(s) s:SetFocus() end)

    local prosAdd = Skin:Button(helpBody, "Add", 40, 20)
    prosAdd:SetPoint("LEFT", prosEdit, "RIGHT", 4, 0)
    local function addProspect()
        local nm = (prosEdit:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if nm == "" then return end
        nm = nm:sub(1, 1):upper()..nm:sub(2)
        self:AddProspect(nm)
        prosEdit:SetText("")
    end
    prosAdd:SetScript("OnMouseUp", addProspect)
    prosEdit:SetScript("OnEnterPressed", function(s) addProspect(); s:ClearFocus() end)

    local function buildProsRow(parent)
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(20)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
        local del = Skin:Button(r, "x", 16, 16)
        del:SetPoint("RIGHT", -2, 0); r.del = del
        local inv = Skin:Button(r, "Inv", 34, 16)
        inv:SetPoint("RIGHT", del, "LEFT", -3, 0); r.inv = inv
        local st = r:CreateFontString(nil, "OVERLAY"); Skin:Font(st, 10, true)
        st:SetPoint("RIGHT", inv, "LEFT", -4, 0); r.st = st
        local nm = r:CreateFontString(nil, "OVERLAY"); Skin:Font(nm, 11, false)
        nm:SetPoint("LEFT", 4, 0); nm:SetPoint("RIGHT", st, "LEFT", -4, 0)
        nm:SetJustifyH("LEFT"); nm:SetWordWrap(false); nm:SetNonSpaceWrap(false)
        r.nm = nm
        return r
    end
    local function updProsRow(r, item, idx, alt)
        if not item then return end
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        r.nm:SetText(item.name)
        if item.status == "IN" then
            r.st:SetText("|cff60ff60IN|r"); r.inv:Hide()
        elseif item.status == "GONE" then
            r.st:SetText("|cffff5050GONE|r"); r.inv:Show()
        else
            r.st:SetText("|cffffd070WAIT|r"); r.inv:Show()
        end
        r.inv:SetScript("OnMouseUp", function()
            if InviteUnit then InviteUnit(item.name) end
        end)
        r.del:SetScript("OnMouseUp", function() M:RemoveProspect(item.name) end)
    end
    local prosList = Skin:ScrollList(helpBody, 20, buildProsRow, updProsRow)
    prosList:SetPoint("TOPLEFT", prosEdit, "BOTTOMLEFT", -4, -4)
    prosList:SetPoint("BOTTOMRIGHT", helpBody, "BOTTOMRIGHT", 0, 2)

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
        rosterFs = rosterFs, needFs = needFs, prosList = prosList,
    }
    self:Refresh()
    return panel
end

-- ---------- roles / recruiting ----------
-- 3.3.5 conventions: Prot warr/pala and Blood DK tank; Holy/Disc/Resto heal
local function roleOf(m)
    local s = m.spec
    if not s then return "unknown" end
    if s == "Protection" then return "tank" end
    if m.class == "DEATHKNIGHT" and s == "Blood" then return "tank" end
    if s == "Holy" or s == "Discipline" or s == "Restoration" then return "healer" end
    return "dps"
end

local SHORT_NAMES = {
    naxx = "Naxx", os = "OS", eoe = "EoE", voa = "VoA", uld = "Ulduar",
    toc = "ToC", togc = "ToGC", ony = "Ony", icc = "ICC", rs = "RS",
}

-- ---------- prospects ----------
local function prospects()
    RMS.db.raidcomp = RMS.db.raidcomp or { prospects = {} }
    RMS.db.raidcomp.prospects = RMS.db.raidcomp.prospects or {}
    return RMS.db.raidcomp.prospects
end

function M:AddProspect(name)
    for _, p in ipairs(prospects()) do
        if p.name == name then return end
    end
    table.insert(prospects(), { name = name })
    self:Refresh()
end

function M:RemoveProspect(name)
    local pros = prospects()
    for i = #pros, 1, -1 do
        if pros[i].name == name then table.remove(pros, i) end
    end
    self:Refresh()
end

-- ---------- advert prefill ----------
function M:PrefillAdvert()
    local raid = self:SelectedRaid()
    local cfg = RMS.db.advertising
    if not raid or not cfg then return end

    local short = SHORT_NAMES[raid.key:match("^(%a+)")] or raid.name
    cfg.raidName = ("%s %d"):format(short, raid.size)
    cfg.minGS = raid.minGS

    -- compute what's still needed LIVE at click time (no cached state):
    -- raid comp targets minus whoever is already in the group
    local members = rosterMembers()
    local counts = { tank = 0, healer = 0, dps = 0, unknown = 0 }
    for _, m in ipairs(members) do
        local r = roleOf(m)
        counts[r] = counts[r] + 1
    end
    local dpsTarget = raid.size - raid.tanks - raid.healers
    local nt = math.max(0, raid.tanks   - counts.tank)
    local nh = math.max(0, raid.healers - counts.healer)
    -- unknown-spec members most likely fill dps slots; don't over-ask
    local nd = math.max(0, dpsTarget - counts.dps - counts.unknown)

    cfg.needTanks   = nt
    cfg.needHealers = nh
    cfg.needRanged  = math.ceil(nd / 2)
    cfg.needMelee   = math.floor(nd / 2)

    -- tick the classes that would plug the most missing raid buffs
    local missingByClass = {}
    for _, buff in ipairs(RMS.RaidBuffs or {}) do
        if evalBuff(buff, members) == "no" then
            for _, p in ipairs(buff.providers) do
                missingByClass[p.class] = (missingByClass[p.class] or 0) + 1
            end
        end
    end
    local classRank = {}
    for cls, cnt in pairs(missingByClass) do
        classRank[#classRank+1] = { cls = cls, n = cnt }
    end
    table.sort(classRank, function(a, b) return a.n > b.n end)
    cfg.needClasses = {}
    for i = 1, math.min(3, #classRank) do
        cfg.needClasses[classRank[i].cls] = true
    end

    -- repaint the Advertising UI if it has been built already
    local adv = RMS:GetModule("advertising")
    if adv and adv._ui then
        adv._ui.raidEdit:SetText(cfg.raidName)
        adv._ui.gsEdit:SetText(tostring(cfg.minGS))
        local np = adv._needPopup
        if np and np._roleEdits then
            np._roleEdits.needTanks:SetText(tostring(cfg.needTanks))
            np._roleEdits.needHealers:SetText(tostring(cfg.needHealers))
            np._roleEdits.needMelee:SetText(tostring(cfg.needMelee))
            np._roleEdits.needRanged:SetText(tostring(cfg.needRanged))
            for key, cb in pairs(np._cbs or {}) do
                cb:SetChecked(cfg.needClasses[key] == true)
            end
        end
        if adv._RefreshPreview then adv:_RefreshPreview() end
    end
    RMS.UI:Show("advertising")
    RMS:Print("Advert prefilled for %s %d -- tweak it and hit Send Now / Start Auto.", short, raid.size)
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

    -- ===== Raid Helper =====
    if self._ui.rosterFs then
        local counts = { tank = 0, healer = 0, dps = 0, unknown = 0 }
        for _, m in ipairs(members) do
            local r = roleOf(m)
            counts[r] = counts[r] + 1
        end
        local dpsTarget = raid.size - raid.tanks - raid.healers
        self._ui.rosterFs:SetText(("Roster %d/%d:  |cffffd070%d/%dT|r |cff60ff60%d/%dH|r |cffff8080%d/%dD|r%s"):format(
            #members, raid.size,
            counts.tank, raid.tanks, counts.healer, raid.healers, counts.dps, dpsTarget,
            counts.unknown > 0 and (" |cff888888+%d?|r"):format(counts.unknown) or ""))

        -- role deficits + which classes would plug the most missing buffs
        local nt = raid.tanks   - counts.tank
        local nh = raid.healers - counts.healer
        local nd = dpsTarget    - counts.dps
        local needParts = {}
        if nt > 0 then needParts[#needParts+1] = nt.." tank"..(nt > 1 and "s" or "") end
        if nh > 0 then needParts[#needParts+1] = nh.." healer"..(nh > 1 and "s" or "") end
        if nd > 0 then needParts[#needParts+1] = nd.." dps" end

        local missingByClass = {}
        for _, row in ipairs(rows) do
            if row.buff and row.status == "no" then
                for _, p in ipairs(row.buff.providers) do
                    missingByClass[p.class] = (missingByClass[p.class] or 0) + 1
                end
            end
        end
        local classRank = {}
        for cls, cnt in pairs(missingByClass) do
            classRank[#classRank+1] = { cls = cls, n = cnt }
        end
        table.sort(classRank, function(a, b) return a.n > b.n end)
        local sugg = {}
        for i = 1, math.min(3, #classRank) do
            local e = classRank[i]
            sugg[#sugg+1] = ("%s%s|r (%d)"):format(
                CLASS_COLOR(e.cls), CLASS_NAMES[e.cls] or e.cls, e.n)
        end

        local txt = (#needParts > 0)
            and ("Need "..table.concat(needParts, ", ")..".")
            or "Comp roles filled."
        if #sugg > 0 then
            txt = txt.."  Best buff pickups: "..table.concat(sugg, ", ")
        end
        self._ui.needFs:SetText(txt)
        self._needCache = { nt = math.max(0, nt), nh = math.max(0, nh),
                            nd = math.max(0, nd), classRank = classRank }

        -- prospects: joined once -> IN; left afterwards -> GONE
        local inRoster = {}
        for _, m in ipairs(members) do inRoster[m.name] = true end
        local prosRows = {}
        for _, p in ipairs(prospects()) do
            if inRoster[p.name] then
                p.joined = true
                p.status = "IN"
            elseif p.joined then
                p.status = "GONE"
            else
                p.status = "WAIT"
            end
            prosRows[#prosRows+1] = p
        end
        self._ui.prosList:SetData(prosRows)
    end
end

M.events = {
    RAID_ROSTER_UPDATE    = function(self) if self._ui then self:Refresh() end end,
    PARTY_MEMBERS_CHANGED = function(self) if self._ui then self:Refresh() end end,
}

function M:OnSlash(arg)
    RMS.UI:Show("raidcomp")
end
