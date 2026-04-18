-- Raid Master Suite -- BiS Scan
-- Tracks each raider's class+spec, knows their BiS list (seeded + per-character
-- overrides), and on loot drop shows a popup of who needs the dropped items.

local RMS = RaidMasterSuite
local M = RMS:RegisterModule("bis", { title = "BiS Scan", order = 5 })

-- ---------- state ----------
M.peers = {}  -- [playerName] = { class = "PALADIN", spec = "Holy" }

local SLOTS = {
    "Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands",
    "Belt", "Legs", "Feet", "Ring1", "Ring2", "Trinket1", "Trinket2",
    "MainHand", "OffHand", "Ranged", "Relic",
}

-- Green checkmark glyph (UTF-8 U+2713)
local OWNED_MARK = "|cff60ff60\226\156\147|r "

-- True if the player owns this item (in bags OR equipped).
local function playerHasItem(id)
    if not id then return false end
    if GetItemCount and (GetItemCount(id) or 0) > 0 then return true end
    for slot = 0, 19 do
        if GetInventoryItemID("player", slot) == id then return true end
    end
    return false
end

-- Warm the WoW client cache for an item id by hovering it in a hidden tooltip.
-- Call repeatedly; once GetItemInfo returns data, no further work is needed.
local function warmItem(id)
    if not id or GetItemInfo(id) then return false end
    if not RMS._itemQueryTip then
        RMS._itemQueryTip = CreateFrame("GameTooltip", "RMSItemQueryTip", UIParent, "GameTooltipTemplate")
    end
    RMS._itemQueryTip:SetOwner(UIParent, "ANCHOR_NONE")
    RMS._itemQueryTip:SetHyperlink("item:"..id)
    return true  -- still missing
end

-- ---------- spec detection ----------
local function detectSpec()
    if not GetTalentTabInfo then return nil end
    local best, bestPts = nil, -1
    for tab = 1, 3 do
        local name, _, points = GetTalentTabInfo(tab)
        if name and (points or 0) > bestPts then
            best, bestPts = name, points or 0
        end
    end
    -- Normalize: e.g. "Feral Combat" -> "Feral_Combat" (matches our seed keys)
    return best and best:gsub("%s+", "_") or nil
end

local function myClass()
    local _, token = UnitClass("player")
    return token
end

-- ---------- BiS lookup ----------
-- merged list = seeded[class][spec] + charDB.bis.overrides
function M:GetBiSFor(class, spec)
    local out = {}
    local seed = RMS.BiSSeed and RMS.BiSSeed[class] and RMS.BiSSeed[class][spec]
    if seed then
        for slot, ids in pairs(seed) do
            out[slot] = {}
            for _, id in ipairs(ids) do out[slot][id] = true end
        end
    end
    -- only the local player has overrides
    local me = RMS:PlayerName()
    local mc = self.peers[me]
    if mc and mc.class == class and mc.spec == spec and RMS.charDB.bis then
        for slot, id in pairs(RMS.charDB.bis.overrides or {}) do
            out[slot] = out[slot] or {}
            out[slot][tonumber(id) or id] = true
        end
    end
    return out
end

-- Quick "is this itemID BiS for any slot of this class+spec"
function M:IsBiS(itemID, class, spec)
    local list = self:GetBiSFor(class, spec)
    for _, ids in pairs(list) do
        if ids[itemID] then return true end
    end
    return false
end

-- For loot scan: find every peer whose BiS contains itemID. Returns
-- list of {player, class, spec, slot}
function M:NeedersFor(itemID)
    itemID = tonumber(itemID); if not itemID then return {} end
    local needers = {}
    for player, info in pairs(self.peers) do
        if info.class and info.spec then
            local list = self:GetBiSFor(info.class, info.spec)
            for slot, ids in pairs(list) do
                if ids[itemID] then
                    needers[#needers+1] = {
                        player = player, class = info.class,
                        spec = info.spec, slot = slot,
                    }
                    break
                end
            end
        end
    end
    table.sort(needers, function(a, b) return a.player < b.player end)
    return needers
end

-- ---------- comm ----------
function M:BroadcastMySpec()
    local class, spec = myClass(), detectSpec()
    if not class or not spec then return end
    self.peers[RMS:PlayerName()] = { class = class, spec = spec }
    if RMS:InGroup() then
        RMS.Comm:Send("bis", "spec", { class = class, spec = spec })
    end
    if self._ui then self:Refresh() end
end

RMS.Comm:On("bis", "spec", function(p, sender)
    if not p.class or not p.spec then return end
    M.peers[sender] = { class = p.class, spec = p.spec }
    if M._ui then M:Refresh() end
end)

-- new player joined -> send our spec; they will broadcast theirs too
RMS.Comm:On("bis", "specreq", function(_, sender)
    if sender == RMS:PlayerName() then return end
    M:BroadcastMySpec()
end)

-- ---------- loot scan ----------
local function getLootIDs()
    local out = {}
    local n = (GetNumLootItems and GetNumLootItems()) or 0
    for slot = 1, n do
        local link = GetLootSlotLink and GetLootSlotLink(slot)
        local id   = link and tonumber(link:match("item:(%d+)"))
        if id then out[#out+1] = { id = id, link = link } end
    end
    return out
end

local function CLASS_COLOR(token)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if c then
        return ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255)
    end
    return "|cffffffff"
end

local function classDisplay(token)
    local map = {
        DEATHKNIGHT="Death Knight", PALADIN="Paladin", WARRIOR="Warrior",
        HUNTER="Hunter", ROGUE="Rogue", PRIEST="Priest", SHAMAN="Shaman",
        MAGE="Mage", WARLOCK="Warlock", DRUID="Druid",
    }
    return map[token] or token
end

local function onLootOpened()
    local items = getLootIDs()
    local rows = {}
    for _, it in ipairs(items) do
        local needers = M:NeedersFor(it.id)
        if #needers > 0 then
            rows[#rows+1] = { link = it.link, id = it.id, needers = needers }
        end
    end
    if #rows > 0 then M:ShowNeedersPopup(rows) end
end

M.events = {
    LOOT_OPENED            = function(self) onLootOpened() end,
    PLAYER_LOGIN           = function(self)
        RMS.charDB.bis = RMS.charDB.bis or { overrides = {} }
        local d = CreateFrame("Frame"); local t = 0
        d:SetScript("OnUpdate", function(s, dt)
            t = t + dt
            if t > 2 then
                s:SetScript("OnUpdate", nil)
                self:BroadcastMySpec()
                if RMS:InGroup() then
                    RMS.Comm:Send("bis", "specreq", {})  -- ask others to broadcast
                end
            end
        end)
    end,
    RAID_ROSTER_UPDATE     = function(self)
        if RMS:InGroup() then RMS.Comm:Send("bis", "specreq", {}) end
    end,
    PARTY_MEMBERS_CHANGED  = function(self)
        if RMS:InGroup() then RMS.Comm:Send("bis", "specreq", {}) end
    end,
    PLAYER_TALENT_UPDATE   = function(self) self:BroadcastMySpec() end,
    CHARACTER_POINTS_CHANGED = function(self) self:BroadcastMySpec() end,
    BAG_UPDATE             = function(self) if self._ui then self:Refresh() end end,
    UNIT_INVENTORY_CHANGED = function(self, _, unit) if unit == "player" and self._ui then self:Refresh() end end,
}

-- ---------- needers popup ----------
function M:ShowNeedersPopup(rows)
    local Skin = RMS.Skin
    local C    = Skin.COLOR

    if not self.popup then
        local f = CreateFrame("Frame", "RaidMasterSuiteBiSPopup", UIParent)
        f:SetSize(400, 320); f:SetPoint("TOP", 0, -180)
        f:SetFrameStrata("DIALOG")
        f:EnableMouse(true); f:SetMovable(true); f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop",  f.StopMovingOrSizing)
        Skin:SetBackdrop(f, C.bgMain, C.accent)
        f:Hide()

        local title = f:CreateFontString(nil, "OVERLAY")
        Skin:Font(title, 14, true)
        title:SetTextColor(unpack(C.accent))
        title:SetPoint("TOP", 0, -8)
        title:SetText("BiS NEEDERS")

        local close = Skin:CloseButton(f)
        close:SetPoint("TOPRIGHT", -4, -4)
        close:SetScript("OnClick", function() f:Hide() end)

        local function buildRow(parent)
            local r = CreateFrame("Frame", nil, parent)
            r:SetHeight(34)
            local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
            local item = r:CreateFontString(nil, "OVERLAY")
            Skin:Font(item, 12, true); item:SetPoint("TOPLEFT", 6, -3); item:SetPoint("RIGHT", -6, 0)
            item:SetJustifyH("LEFT"); item:SetWordWrap(false); item:SetNonSpaceWrap(false)
            r.item = item
            local needers = r:CreateFontString(nil, "OVERLAY")
            Skin:Font(needers, 11, false)
            needers:SetPoint("TOPLEFT", item, "BOTTOMLEFT", 0, -2); needers:SetPoint("RIGHT", -6, 0)
            needers:SetJustifyH("LEFT"); needers:SetWordWrap(false); needers:SetNonSpaceWrap(false)
            r.needers = needers
            return r
        end
        local function updRow(r, item, idx, alt)
            if not item then return end
            r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
            r.item:SetText(item.link or ("item:"..item.id))
            local parts = {}
            for _, n in ipairs(item.needers) do
                parts[#parts+1] = ("%s%s|r (%s)"):format(CLASS_COLOR(n.class), n.player, n.slot)
            end
            r.needers:SetText(table.concat(parts, "  "))
        end
        local list = Skin:ScrollList(f, 36, buildRow, updRow)
        list:SetPoint("TOPLEFT", 8, -32); list:SetPoint("BOTTOMRIGHT", -8, 8)
        f.list = list
        self.popup = f
    end
    self.popup.list:SetData(rows)
    self.popup:Show()
end

-- ---------- alternates popup (per-slot BiS list with tooltips + owned ticks) ----------
function M:_ShowAltsPopup(anchor, slot, ids)
    local Skin = RMS.Skin
    local C    = Skin.COLOR

    -- toggle close
    if self._altsPopup and self._altsPopup:IsShown() then
        self._altsPopup:Hide(); return
    end

    local f = self._altsPopup
    if not f then
        f = CreateFrame("Frame", "RaidMasterSuiteBiSAltsPopup", UIParent)
        f:SetFrameStrata("DIALOG")
        Skin:SetBackdrop(f, C.bgMain, C.accent)
        f:EnableMouse(true); f:SetMovable(true); f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop",  f.StopMovingOrSizing)
        tinsert(UISpecialFrames, "RaidMasterSuiteBiSAltsPopup")
        f._rows = {}

        local title = f:CreateFontString(nil, "OVERLAY")
        Skin:Font(title, 12, true)
        title:SetTextColor(unpack(C.accent))
        title:SetPoint("TOPLEFT", 8, -6)
        f.title = title

        local close = Skin:CloseButton(f)
        close:SetSize(16, 16)
        close:SetPoint("TOPRIGHT", -3, -3)
        close:SetScript("OnClick", function() f:Hide() end)
        self._altsPopup = f
    end

    f:ClearAllPoints()
    f:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
    f:SetSize(380, 26 + #ids * 22)
    f.title:SetText(("BiS for %s -- %d option%s"):format(slot, #ids, #ids == 1 and "" or "s"))

    -- build/reuse rows
    for i = #f._rows + 1, #ids do
        local r = CreateFrame("Frame", nil, f)
        r:SetSize(364, 20)
        r:EnableMouse(true)
        r._bg = r:CreateTexture(nil, "BACKGROUND")
        r._bg:SetAllPoints(); r._bg:SetTexture(Skin.TEX_WHITE)
        local rank = r:CreateFontString(nil, "OVERLAY"); Skin:Font(rank, 10, false)
        rank:SetPoint("LEFT", 6, 0); rank:SetWidth(28); rank:SetTextColor(unpack(C.textDim)); r.rank = rank
        local name = r:CreateFontString(nil, "OVERLAY"); Skin:Font(name, 11, false)
        name:SetPoint("LEFT", rank, "RIGHT", 4, 0); name:SetPoint("RIGHT", -8, 0)
        name:SetJustifyH("LEFT"); name:SetWordWrap(false); name:SetNonSpaceWrap(false)
        r.name = name
        r:SetScript("OnEnter", function(s)
            if not s._id then return end
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:"..s._id)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f._rows[i] = r
    end

    for i, r in ipairs(f._rows) do
        if i <= #ids then
            local id = ids[i]
            r._id = id
            warmItem(id)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 8, -22 - (i - 1) * 22)
            r:SetWidth(364)
            r._bg:SetVertexColor(i % 2 == 0 and 0.10 or 0.13, 0.10, 0.13, 0.5)
            r.rank:SetText((i == 1) and "|cffffd070BiS|r" or ("alt"..(i - 1)))
            local _, link = GetItemInfo(id)
            local prefix = playerHasItem(id) and OWNED_MARK or ""
            r.name:SetText(prefix..(link or ("|cffaaaaaaitem:"..id.."|r")))
            r:Show()
        else
            r:Hide()
        end
    end

    f:Show()
end

-- ---------- main tab UI ----------
function M:BuildUI(parent)
    local Skin = RMS.Skin
    local C    = Skin.COLOR
    local panel = CreateFrame("Frame", nil, parent)

    local header = Skin:Header(panel, "BiS Scan")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)

    local meLabel = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(meLabel, 12, true)
    meLabel:SetTextColor(unpack(C.text))
    meLabel:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 4, -8)

    local rebroadcastBtn = Skin:Button(panel, "Re-detect & Broadcast", 180, 22)
    rebroadcastBtn:SetPoint("LEFT", meLabel, "RIGHT", 12, 0)
    rebroadcastBtn:SetScript("OnMouseUp", function() self:BroadcastMySpec() end)

    -- left: my BiS list (per-slot)
    local mineHdr = Skin:Header(panel, "Your BiS List")
    mineHdr:SetPoint("TOPLEFT", meLabel, "BOTTOMLEFT", 0, -10)
    mineHdr:SetWidth(360)

    local function buildSlotRow(parent)
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(20)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
        local slot = r:CreateFontString(nil, "OVERLAY"); Skin:Font(slot, 11, true); slot:SetPoint("LEFT", 6, 0); slot:SetWidth(70); r.slot = slot

        -- alt button (clickable +N alt indicator)
        local altsBtn = CreateFrame("Button", nil, r)
        altsBtn:SetSize(60, 18)
        altsBtn:SetPoint("RIGHT", -4, 0)
        local altsFs = altsBtn:CreateFontString(nil, "OVERLAY"); Skin:Font(altsFs, 10, false)
        altsFs:SetTextColor(unpack(C.accent))
        altsFs:SetAllPoints(); altsFs:SetJustifyH("RIGHT")
        altsBtn.text = altsFs
        altsBtn:Hide()
        r.altsBtn = altsBtn

        -- hover area for the preferred item's tooltip
        local hover = CreateFrame("Button", nil, r)
        hover:SetPoint("TOPLEFT", slot, "TOPRIGHT", 4, 0)
        hover:SetPoint("BOTTOMRIGHT", altsBtn, "BOTTOMLEFT", -4, 0)
        r.hover = hover

        local item = hover:CreateFontString(nil, "OVERLAY"); Skin:Font(item, 11, false)
        item:SetPoint("LEFT", 0, 0); item:SetPoint("RIGHT", 0, 0)
        item:SetJustifyH("LEFT"); item:SetWordWrap(false); item:SetNonSpaceWrap(false)
        r.item = item

        hover:SetScript("OnEnter", function(s)
            if not s._id then return end
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:"..s._id)
            GameTooltip:Show()
        end)
        hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return r
    end
    local function updSlotRow(r, item, idx, alt)
        if not item then return end
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        r.slot:SetText(item.slot)
        if item.ids and #item.ids > 0 then
            local id = item.ids[1]
            r.hover._id = id
            local _, link = GetItemInfo(id)
            local prefix = playerHasItem(id) and OWNED_MARK or ""
            r.item:SetText(prefix..(link or ("|cffaaaaaaitem:"..id.."|r")))
            if #item.ids > 1 then
                r.altsBtn:Show()
                r.altsBtn.text:SetText("+"..(#item.ids - 1).." alt")
                r.altsBtn:SetScript("OnMouseUp", function(s)
                    M:_ShowAltsPopup(s, item.slot, item.ids)
                end)
            else
                r.altsBtn:Hide()
            end
        else
            r.hover._id = nil
            r.item:SetText("|cff666666(none)|r")
            r.altsBtn:Hide()
        end
    end
    local mineList = Skin:ScrollList(panel, 20, buildSlotRow, updSlotRow)
    mineList:SetPoint("TOPLEFT", mineHdr, "BOTTOMLEFT", 0, -2)
    mineList:SetPoint("BOTTOM", panel, "BOTTOM", 0, 8)
    mineList:SetWidth(360)

    -- right: peer roster with their detected specs
    local peersHdr = Skin:Header(panel, "Raid Roster (detected specs)")
    peersHdr:SetPoint("TOPLEFT", mineHdr, "TOPRIGHT", 8, 0)
    peersHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    local function buildPeerRow(parent)
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(20)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
        local who = r:CreateFontString(nil, "OVERLAY"); Skin:Font(who, 11, true); who:SetPoint("LEFT", 6, 0); r.who = who
        local sp  = r:CreateFontString(nil, "OVERLAY"); Skin:Font(sp,  11, false); sp:SetPoint("RIGHT", -6, 0); sp:SetTextColor(unpack(C.textDim)); r.sp = sp
        return r
    end
    local function updPeerRow(r, item, idx, alt)
        if not item then return end
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        r.who:SetText(("%s%s|r"):format(CLASS_COLOR(item.class), item.player))
        r.sp:SetText(item.spec.."  "..classDisplay(item.class))
    end
    local peersList = Skin:ScrollList(panel, 20, buildPeerRow, updPeerRow)
    peersList:SetPoint("TOPLEFT", peersHdr, "BOTTOMLEFT", 0, -2)
    peersList:SetPoint("BOTTOM", panel, "BOTTOM", 0, 8)
    peersList:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    self._ui = {
        panel = panel, meLabel = meLabel,
        mineList = mineList, peersList = peersList,
    }
    self:Refresh()
    return panel
end

-- (helpers moved earlier in the file so closures inside BuildUI can see them)

function M:Refresh()
    if not self._ui then return end
    local me = RMS:PlayerName()
    local mine = self.peers[me] or {}
    local cls, spec = mine.class, mine.spec
    if cls and spec then
        self._ui.meLabel:SetText(("Your spec: %s%s|r %s"):format(CLASS_COLOR(cls), classDisplay(cls), spec))
    else
        self._ui.meLabel:SetText("Your spec: |cff999999(detecting...)|r")
    end

    -- my BiS list (and warm cache for any unknown items)
    local rows, anyMissing = {}, false
    if cls and spec then
        local list = self:GetBiSFor(cls, spec)
        for _, slot in ipairs(SLOTS) do
            local set = list[slot]
            local ids
            if set then
                ids = {}
                for id in pairs(set) do
                    ids[#ids+1] = id
                    if warmItem(id) then anyMissing = true end
                end
            end
            rows[#rows+1] = { slot = slot, ids = ids }
        end
    end
    self._ui.mineList:SetData(rows)

    -- peers list
    local peers = {}
    for player, info in pairs(self.peers) do
        peers[#peers+1] = { player = player, class = info.class, spec = info.spec }
    end
    table.sort(peers, function(a, b) return a.player < b.player end)
    self._ui.peersList:SetData(peers)

    -- if any items are still loading, retry refresh in ~0.5s (capped retries)
    if anyMissing and (self._retries or 0) < 6 then
        self._retries = (self._retries or 0) + 1
        local f = CreateFrame("Frame"); local elapsed = 0
        f:SetScript("OnUpdate", function(s, dt)
            elapsed = elapsed + dt
            if elapsed > 0.5 then
                s:SetScript("OnUpdate", nil)
                self:Refresh()
            end
        end)
    elseif not anyMissing then
        self._retries = nil
    end
end

-- ---------- slash ----------
function M:OnSlash(arg)
    arg = arg or ""
    if arg == "broadcast" then return self:BroadcastMySpec() end
    if arg == "test" then
        -- pop a sample popup using whatever is in our local roster
        local sample = {}
        for player, info in pairs(self.peers) do
            sample[#sample+1] = { id = 50734, link = "[Heaven's Fall, Kryss]",
                needers = {{ player = player, class = info.class, spec = info.spec, slot = "MainHand" }}}
            break
        end
        if #sample > 0 then self:ShowNeedersPopup(sample)
        else RMS:Print("No peers detected; try /rms bis broadcast first.") end
        return
    end
    RMS.UI:Show("bis")
end
