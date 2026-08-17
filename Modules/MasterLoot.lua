-- Raid Master Suite -- Master Loot Helper
-- When you are master looter and open a corpse, pops a window with every drop
-- at or above the loot threshold set for the dungeon. Click an item to see all
-- eligible candidates with their +1 count and BiS / Soft Res / Hard Res tags,
-- call a /roll, then hand the item out with one click.

local RMS = RaidMasterSuite
local M = RMS:RegisterModule("masterloot", { title = "Master Loot", order = 4 })

-- ---------- state ----------
M.state = { history = {} }   -- persisted award log (newest first)

M._items      = {}    -- current drops: {slot,id,link,name,q,icon}
M._selected   = nil   -- selected loot slot number
M._candidates = {}    -- [playerName] = master loot candidate index
M._lootOpen   = false
M._testMode   = false
M._roll       = nil   -- { id, link, expires, done, rolls = {[player]=value} }
M._pending    = nil   -- { slot, id, link, player } award waiting for confirm

local function persist() RMS.db.masterlootState = M.state end
local function restore()
    if RMS.db.masterlootState then
        for k, v in pairs(RMS.db.masterlootState) do M.state[k] = v end
    end
end

local function cfg() return RMS.db.masterloot or {} end

local function rollTime()
    local t = tonumber(cfg().rollTime) or 8
    if t < 3 then t = 3 elseif t > 60 then t = 60 end
    return t
end

-- ---------- helpers ----------
local function CLASS_COLOR(token)
    local c = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if c then return ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) end
    return "|cffffffff"
end

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

local function qualityName(q)
    return _G["ITEM_QUALITY"..tostring(q).."_DESC"] or ("q"..tostring(q))
end

-- Which quality counts as "distributable": the loot threshold the leader set
-- for the dungeon (default), or a fixed override from settings.
local function effectiveThreshold()
    if cfg().useLootThreshold ~= false then
        return (GetLootThreshold and GetLootThreshold()) or 2
    end
    return cfg().minQuality or 4
end

-- In a raid, everything goes to raid warning (/rw) when we're allowed to;
-- falls back to /raid for a non-assist ML, /party in parties.
local function announce(msg)
    if not RMS:InGroup() then RMS:Print(msg) return end
    local chan = "PARTY"
    if RMS:InRaid() then
        chan = RMS:IsAssist() and "RAID_WARNING" or "RAID"
    end
    SendChatMessage(msg, chan)
end

-- ---------- loot scanning ----------
local function scanCandidates()
    local out = {}
    for ci = 1, 40 do
        local name = GetMasterLootCandidate(ci)
        if name then out[name] = ci end
    end
    return out
end

local function scanLoot()
    local items = {}
    local threshold = effectiveThreshold()
    local n = (GetNumLootItems and GetNumLootItems()) or 0
    for slot = 1, n do
        -- coins have no item link, so the id check filters them even if
        -- LootSlotIsItem is unavailable
        if (not LootSlotIsItem) or LootSlotIsItem(slot) then
            local icon, name, quantity, quality = GetLootSlotInfo(slot)
            local link = GetLootSlotLink(slot)
            local id   = link and tonumber(link:match("item:(%d+)"))
            if id and (quality or 0) >= threshold then
                items[#items+1] = { slot = slot, id = id, link = link,
                                    name = name, q = quality, icon = icon,
                                    count = quantity or 1 }
            end
        end
    end
    return items
end

-- ---------- award flow ----------
local function pushHistory(msg)
    table.insert(M.state.history, 1, ("[%s] %s"):format(date("%m/%d %H:%M"), msg))
    if #M.state.history > 50 then M.state.history[#M.state.history] = nil end
    persist()
end

local function finalizeAward(p)
    local linkText = p.link or ("item:"..tostring(p.id))
    pushHistory(("%s -> %s"):format(linkText, p.player))
    RMS:Print("%s awarded to %s.", linkText, p.player)
    if cfg().announceAwards then
        announce(("%s awarded to %s"):format(linkText, p.player))
    end
    if cfg().autoPlusOne then
        local po = RMS:GetModule("plusone")
        if po and po.GrantPlusOne then po:GrantPlusOne(p.player, p.link) end
    end
    if M._ui then M:Refresh() end
end

function M:Give(item, playerName)
    if self._testMode then
        -- preview only: no announce, no history, no +1
        RMS:Print("(preview) would give %s to %s", item.link or item.name, playerName)
        return
    end
    if not self._lootOpen then
        RMS:Print("Loot window is closed -- open the corpse again to award.")
        return
    end
    -- re-resolve the candidate index right before giving (list can shift)
    local ci
    for i = 1, 40 do
        if GetMasterLootCandidate(i) == playerName then ci = i break end
    end
    if not ci then
        RMS:Print("%s is not an eligible candidate right now (out of range?).", playerName)
        return
    end
    self._pending = { slot = item.slot, id = item.id, link = item.link, player = playerName }
    GiveMasterLoot(item.slot, ci)
end

-- ---------- roll flow ----------
local ROLL_GRACE   = 1.5  -- keep accepting lag-delayed rolls this long after the timer
local PREROLL_LIFE = 5    -- rolls typed up to this long before Call Roll still count

function M:CallRoll(item)
    if not item then return end
    -- self-heal stale candidate lists without needing to reopen the corpse
    if self._lootOpen then self._candidates = scanCandidates() end
    local t = rollTime()
    -- seed with pre-rolls: raiders who rolled in the gap since the last
    -- session ended (they won't roll again -- they think they already did)
    local rolls = {}
    for player, e in pairs(self._preRolls or {}) do
        if (GetTime() - e.at) <= PREROLL_LIFE then rolls[player] = e.value end
    end
    self._preRolls = nil
    self._roll = { id = item.id, link = item.link, done = false,
                   expires = GetTime() + t, rolls = rolls,
                   -- countdown announcements start at 5s remaining (or less
                   -- for short timers); nil = countdown disabled
                   countdownNext = (cfg().countdown ~= false) and math.min(5, t - 1) or nil }
    announce(("Roll for %s now! (/roll, %ds)"):format(item.link or item.name, t))
    self:RefreshWindow()
end

local function finishRoll()
    local r = M._roll
    if not r or r.done then return end
    r.done = true
    local best, bestVal
    for player, val in pairs(r.rolls) do
        if not bestVal or val > bestVal then best, bestVal = player, val end
    end
    if best then
        if cfg().announceRolls ~= false then
            announce(("Roll ended for %s: %s wins with %d"):format(r.link, best, bestVal))
        end
    else
        RMS:Print("Roll ended for %s: nobody rolled.", r.link)
    end
    M:RefreshWindow()
end

local rollPoll = CreateFrame("Frame")
rollPoll:SetScript("OnUpdate", function()
    local r = M._roll
    if not r or r.done then return end
    local remaining = r.expires - GetTime()
    -- "5... 4... 3... 2... 1..." from the ML as the window closes
    if r.countdownNext and r.countdownNext >= 1 and remaining <= r.countdownNext then
        if r.countdownNext == math.min(5, rollTime() - 1) then
            announce(("Rolls close in %d..."):format(r.countdownNext))
        else
            announce(r.countdownNext.."...")
        end
        r.countdownNext = r.countdownNext - 1
    end
    -- grace period: chat lag can deliver a "1-second" roll after the deadline
    if remaining <= -ROLL_GRACE then finishRoll() end
end)

local function onSystemMsg(msg)
    local player, val, lo, hi = msg:match("^(%S+) rolls (%d+) %((%d+)%-(%d+)%)")
    if not player then return end
    if tonumber(lo) ~= 1 or tonumber(hi) ~= 100 then return end
    val = tonumber(val)
    local r = M._roll
    if r and not r.done then
        if r.rolls[player] then return end  -- first roll counts
        r.rolls[player] = val
        M:RefreshWindow()
    else
        -- no session running: remember it as a pre-roll for the next Call Roll
        M._preRolls = M._preRolls or {}
        if not M._preRolls[player] then
            M._preRolls[player] = { value = val, at = GetTime() }
        end
    end
end

-- ---------- events ----------
M.events = {
    PLAYER_LOGIN = function(self)
        restore()
        if self._ui then self:Refresh() end
    end,
    LOOT_OPENED  = function(self)
        if not RMS:IsMasterLooter() then return end
        self._testMode   = false
        self._lootOpen   = true
        self._items      = scanLoot()
        self._candidates = scanCandidates()
        if not self._selectValid() then self._selected = self._items[1] and self._items[1].slot end
        if #self._items > 0 and cfg().autoOpen ~= false then
            self:ShowWindow()
        else
            self:RefreshWindow()
        end
    end,
    LOOT_SLOT_CLEARED = function(self, _, slot)
        if self._pending and self._pending.slot == slot then
            finalizeAward(self._pending)
            self._pending = nil
        end
        for i = #self._items, 1, -1 do
            if self._items[i].slot == slot then table.remove(self._items, i) end
        end
        if not self._selectValid() then self._selected = self._items[1] and self._items[1].slot end
        self:RefreshWindow()
    end,
    LOOT_CLOSED = function(self)
        self._lootOpen = false
        self._pending  = nil
        self:RefreshWindow()
    end,
    CHAT_MSG_SYSTEM = function(self, _, msg) onSystemMsg(msg) end,
    PARTY_LOOT_METHOD_CHANGED = function(self) if self._ui then self:Refresh() end end,
    RAID_ROSTER_UPDATE        = function(self) if self._ui then self:Refresh() end end,
}

function M._selectValid()
    if not M._selected then return false end
    for _, it in ipairs(M._items) do
        if it.slot == M._selected then return true end
    end
    return false
end

local function selectedItem()
    for _, it in ipairs(M._items) do
        if it.slot == M._selected then return it end
    end
    return nil
end

-- ---------- candidate rows ----------
local function buildCandidateRows(item)
    if not item then return {} end
    local bis = RMS:GetModule("bis")
    local needSet = {}
    if bis and bis.NeedersFor then
        for _, n in ipairs(bis:NeedersFor(item.id)) do
            needSet[n.player] = { slot = n.slot, rank = n.rank or 1 }
        end
    end
    local srSet = {}
    local sr = RMS:GetModule("softres")
    if sr and sr.state and sr.state.reserves then
        for player, items in pairs(sr.state.reserves) do
            if items[item.id] then srSet[player] = true end
        end
    end
    local hrSet = {}
    local hr = RMS:GetModule("hardres")
    if hr and hr.state and hr.state.assignments then
        for _, a in ipairs(hr.state.assignments) do
            if tonumber(a.id) == item.id then hrSet[a.player] = true end
        end
    end
    local po = RMS:GetModule("plusone")
    local classes = rosterClassMap()

    local rows = {}
    for name in pairs(M._candidates) do
        rows[#rows+1] = {
            player  = name,
            class   = classes[name],
            plus    = (po and po.GetCount) and po:GetCount(name) or 0,
            bisNeed = needSet[name],
            sr      = srSet[name] or false,
            hr      = hrSet[name] or false,
            roll    = (M._roll and M._roll.id == item.id) and M._roll.rolls[name] or nil,
        }
    end
    -- HR assignee first; then rolled (highest first); then fewest +1; then name
    table.sort(rows, function(a, b)
        if a.hr ~= b.hr then return a.hr end
        if (a.roll ~= nil) ~= (b.roll ~= nil) then return a.roll ~= nil end
        if a.roll and b.roll and a.roll ~= b.roll then return a.roll > b.roll end
        if a.plus ~= b.plus then return a.plus < b.plus end
        return a.player < b.player
    end)
    return rows
end

-- ---------- window ----------
function M:BuildWindow()
    if self.win then return self.win end
    local Skin = RMS.Skin
    local C    = Skin.COLOR

    local f = CreateFrame("Frame", "RaidMasterSuiteMLFrame", UIParent)
    f:SetSize(760, 440)
    f:SetPoint("CENTER", 0, 60)
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true); f:SetMovable(true); f:SetClampedToScreen(true)
    Skin:SetBackdrop(f, C.bgMain, C.borderHi)
    f:Hide()
    tinsert(UISpecialFrames, "RaidMasterSuiteMLFrame")
    self.win = Skin:ManagedWindow(f)

    local title = CreateFrame("Frame", nil, f)
    title:SetPoint("TOPLEFT"); title:SetPoint("TOPRIGHT"); title:SetHeight(30)
    Skin:SetBackdrop(title, C.bgHeader, C.border)
    title:EnableMouse(true)
    title:RegisterForDrag("LeftButton")
    title:SetScript("OnDragStart", function() f:StartMoving() end)
    title:SetScript("OnDragStop",  function() f:StopMovingOrSizing() end)

    local titleFs = title:CreateFontString(nil, "OVERLAY")
    Skin:Font(titleFs, 14, true)
    titleFs:SetTextColor(unpack(C.accent))
    titleFs:SetPoint("LEFT", 12, 0)
    titleFs:SetText("MASTER LOOT")

    local status = title:CreateFontString(nil, "OVERLAY")
    Skin:Font(status, 10, false)
    status:SetTextColor(unpack(C.textDim))
    status:SetPoint("LEFT", titleFs, "RIGHT", 12, -1)
    f.status = status

    local close = Skin:CloseButton(title)
    close:SetPoint("RIGHT", -6, 0)
    close:SetScript("OnClick", function() f:Hide() end)

    -- left: drops
    local itemCol = Skin:Panel(f); itemCol:SetWidth(280)
    itemCol:SetPoint("TOPLEFT", 8, -38)
    itemCol:SetPoint("BOTTOMLEFT", 8, 8)

    local itemHdr = itemCol:CreateFontString(nil, "OVERLAY")
    Skin:Font(itemHdr, 11, true)
    itemHdr:SetTextColor(unpack(C.accent))
    itemHdr:SetPoint("TOPLEFT", 6, -4)
    itemHdr:SetText("Drops")
    f.itemHdr = itemHdr

    local function buildItemRow(parent)
        local r = CreateFrame("Button", nil, parent)
        r:SetHeight(24)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
        local hl = r:CreateTexture(nil, "BORDER"); hl:SetAllPoints(); hl:SetTexture(Skin.TEX_WHITE)
        hl:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.18); hl:Hide(); r.hl = hl
        local fs = r:CreateFontString(nil, "OVERLAY")
        Skin:Font(fs, 12, false)
        fs:SetPoint("LEFT", 6, 0); fs:SetPoint("RIGHT", -6, 0)
        fs:SetJustifyH("LEFT"); fs:SetWordWrap(false); fs:SetNonSpaceWrap(false)
        r.fs = fs
        r:SetScript("OnEnter", function(s)
            if not s._id then return end
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:"..s._id)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return r
    end
    local function updItemRow(r, item, idx, alt)
        if not item then return end
        r._id = item.id
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        r.fs:SetText(item.link or item.name)
        if M._selected == item.slot then r.hl:Show() else r.hl:Hide() end
        r:SetScript("OnClick", function()
            M._selected = item.slot
            M:RefreshWindow()
        end)
    end
    local itemList = Skin:ScrollList(itemCol, 24, buildItemRow, updItemRow)
    itemList:SetPoint("TOPLEFT", 0, -22); itemList:SetPoint("BOTTOMRIGHT", 0, 0)
    f.itemList = itemList

    -- right: candidates
    local candCol = Skin:Panel(f)
    candCol:SetPoint("TOPLEFT", itemCol, "TOPRIGHT", 6, 0)
    candCol:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 8)

    local candHdr = candCol:CreateFontString(nil, "OVERLAY")
    Skin:Font(candHdr, 11, true)
    candHdr:SetTextColor(unpack(C.accent))
    candHdr:SetPoint("TOPLEFT", 6, -4)
    candHdr:SetText("Candidates")
    f.candHdr = candHdr

    local rollBtn = Skin:Button(candCol, ("Call Roll (%ds)"):format(rollTime()), 110, 20)
    rollBtn:SetPoint("TOPRIGHT", -4, -2)
    rollBtn:SetScript("OnMouseUp", function() M:CallRoll(selectedItem()) end)
    f.rollBtn = rollBtn

    -- GDKP: auction the selected item (shown only when GDKP mode is on)
    local bidBtn = Skin:Button(candCol, "Start Bid", 80, 20)
    bidBtn:SetPoint("RIGHT", rollBtn, "LEFT", -4, 0)
    bidBtn:SetScript("OnMouseUp", function()
        local it = selectedItem()
        if not it then return end
        local gb = RMS:GetModule("goldbid")
        if gb and gb.OpenStartDialog then gb:OpenStartDialog(it.link, it.count) end
    end)
    f.bidBtn = bidBtn

    local function buildCandRow(parent)
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(24)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg

        local give = Skin:Button(r, "Give", 54, 20)
        give:SetPoint("RIGHT", -4, 0); r.give = give

        local roll = r:CreateFontString(nil, "OVERLAY"); Skin:Font(roll, 12, true)
        roll:SetPoint("RIGHT", give, "LEFT", -8, 0); roll:SetWidth(34)
        roll:SetJustifyH("RIGHT"); r.roll = roll

        local plus = r:CreateFontString(nil, "OVERLAY"); Skin:Font(plus, 12, true)
        plus:SetPoint("RIGHT", roll, "LEFT", -8, 0); plus:SetWidth(34)
        plus:SetJustifyH("RIGHT"); r.plus = plus

        local who = r:CreateFontString(nil, "OVERLAY"); Skin:Font(who, 12, true)
        who:SetPoint("LEFT", 6, 0); who:SetWidth(130); who:SetJustifyH("LEFT")
        who:SetWordWrap(false); who:SetNonSpaceWrap(false); r.who = who

        local tags = r:CreateFontString(nil, "OVERLAY"); Skin:Font(tags, 10, false)
        tags:SetPoint("LEFT", who, "RIGHT", 6, 0); tags:SetPoint("RIGHT", plus, "LEFT", -6, 0)
        tags:SetJustifyH("LEFT"); tags:SetWordWrap(false); tags:SetNonSpaceWrap(false); r.tags = tags
        return r
    end
    local function updCandRow(r, item, idx, alt)
        if not item then return end
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        r.who:SetText(("%s%s|r"):format(CLASS_COLOR(item.class), item.player))

        local tags = {}
        if item.hr then tags[#tags+1] = "|cffff5050HardRes|r" end
        if item.sr then tags[#tags+1] = "|cff60ff60SoftRes|r" end
        if item.bisNeed then
            if (item.bisNeed.rank or 1) <= 1 then
                tags[#tags+1] = ("|cffffd070BiS:%s|r"):format(item.bisNeed.slot)
            else
                tags[#tags+1] = ("|cffb09050Alt%d:%s|r"):format(item.bisNeed.rank - 1, item.bisNeed.slot)
            end
        end
        r.tags:SetText(table.concat(tags, "  "))

        if item.plus > 0 then
            r.plus:SetText(("|cffffd070+%d|r"):format(item.plus))
        else
            r.plus:SetText("|cff5599550|r")
        end
        r.roll:SetText(item.roll and tostring(item.roll) or "")

        r.give:SetScript("OnMouseUp", function()
            local it = selectedItem()
            if it then M:Give(it, item.player) end
        end)
    end
    local candList = Skin:ScrollList(candCol, 24, buildCandRow, updCandRow)
    candList:SetPoint("TOPLEFT", 0, -26); candList:SetPoint("BOTTOMRIGHT", 0, 0)
    f.candList = candList

    return f
end

function M:ShowWindow()
    self:BuildWindow()
    self.win:Show()
    self:RefreshWindow()
end

function M:RefreshWindow()
    if not self.win or not self.win:IsShown() then return end
    local f = self.win

    local bits = {}
    if self._testMode then
        bits[#bits+1] = "|cffffd070PREVIEW|r"
    elseif not self._lootOpen then
        bits[#bits+1] = "|cffff5050loot window closed -- reopen corpse to award|r"
    end
    bits[#bits+1] = ("threshold: %s+"):format(qualityName(effectiveThreshold()))
    f.status:SetText(table.concat(bits, "   "))

    f.itemHdr:SetText(("Drops (%d)"):format(#self._items))
    f.itemList:SetData(self._items)

    local item = selectedItem()
    if item then
        f.candHdr:SetText(("Candidates -- %s"):format(item.name or item.link or ""))
    else
        f.candHdr:SetText("Candidates")
    end
    f.candList:SetData(buildCandidateRows(item))

    if self._roll and not self._roll.done then
        f.rollBtn:SetText("Rolling...")
    else
        f.rollBtn:SetText(("Call Roll (%ds)"):format(rollTime()))
    end

    if RMS.db.goldbid and RMS.db.goldbid.gdkpMode then
        f.bidBtn:Show()
    else
        f.bidBtn:Hide()
    end
end

-- ---------- preview (works without loot open) ----------
-- Warm the client item cache; returns true if the item is still missing.
local function warmItem(id)
    if not id or GetItemInfo(id) then return false end
    if not RMS._itemQueryTip then
        RMS._itemQueryTip = CreateFrame("GameTooltip", "RMSItemQueryTip", UIParent, "GameTooltipTemplate")
    end
    RMS._itemQueryTip:SetOwner(UIParent, "ANCHOR_NONE")
    RMS._itemQueryTip:SetHyperlink("item:"..id)
    return true
end

-- Shadowmourne (legendary), Royal Scepter (epic), Shadowfrost Shard, staff
local SAMPLE_ITEMS = { 49623, 50734, 50274, 51939 }

function M:Preview()
    if self._lootOpen and #self._items > 0 then
        self:ShowWindow()
        return
    end
    self._testMode = true
    self._items = {}
    local anyMissing = false
    for i, id in ipairs(SAMPLE_ITEMS) do
        -- real GetItemInfo link so each item shows its true rarity color
        local name, link, q = GetItemInfo(id)
        if not link and warmItem(id) then anyMissing = true end
        self._items[#self._items+1] = {
            slot = i, id = id, q = q or 4,
            name = name or ("item "..id),
            link = link or ("|cffa335ee|Hitem:%d:0:0:0:0:0:0:0|h[item %d]|h|r"):format(id, id),
        }
    end
    self._selected = 1
    self._candidates = {}
    for _, name in ipairs(RMS:GetRosterNames()) do
        self._candidates[name] = 0
    end
    self:ShowWindow()

    -- uncached items resolve shortly after the warm query; rebuild once ready
    if anyMissing and (self._previewRetries or 0) < 6 then
        self._previewRetries = (self._previewRetries or 0) + 1
        local fr = CreateFrame("Frame"); local t = 0
        fr:SetScript("OnUpdate", function(s, dt)
            t = t + dt
            if t > 0.6 then
                s:SetScript("OnUpdate", nil)
                if self._testMode and self.win and self.win:IsShown() then self:Preview() end
            end
        end)
    elseif not anyMissing then
        self._previewRetries = nil
    end
end

-- ---------- main tab ----------
function M:BuildUI(parent)
    local Skin = RMS.Skin
    local C    = Skin.COLOR
    local panel = CreateFrame("Frame", nil, parent)

    local header = Skin:Header(panel, "Master Loot Helper")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)

    local statusFs = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(statusFs, 12, false)
    statusFs:SetTextColor(unpack(C.text))
    statusFs:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 4, -8)

    local openBtn = Skin:Button(panel, "Open Loot Window", 140, 24)
    openBtn:SetPoint("TOPLEFT", statusFs, "BOTTOMLEFT", 0, -8)
    openBtn:SetScript("OnMouseUp", function() self:Preview() end)
    Skin:AttachTooltip(openBtn, "Open Loot Window",
        { "Shows the loot distribution window. With no corpse open you get a preview with sample items." })

    -- options
    local y = openBtn
    local refreshers = {}
    local function addCheck(label, key, tooltip, default)
        local cb = Skin:CheckBox(panel, label)
        cb:SetPoint("TOPLEFT", y, "BOTTOMLEFT", 0, -10)
        local function current()
            local cur = cfg()[key]
            if cur == nil then cur = default end
            return cur
        end
        cb:SetChecked(current())
        cb.OnValueChanged = function(_, v) RMS.db.masterloot[key] = v end
        if tooltip then Skin:AttachTooltip(cb.box, label, {tooltip}) end
        refreshers[#refreshers+1] = function() cb:SetChecked(current()) end
        y = cb
        return cb
    end

    addCheck("Auto-open when looting as ML", "autoOpen",
        "Pop the loot window automatically when you open a corpse as master looter.", true)
    addCheck("Use the dungeon's loot threshold", "useLootThreshold",
        "Only list items at or above the loot threshold set for the group (e.g. Epic). Untick to use a fixed quality below.", true)
    addCheck("Announce awards to raid", "announceAwards",
        "Post '[item] awarded to player' in raid chat after handing out loot.", true)
    addCheck("Announce roll winners", "announceRolls",
        "Post the winner in raid chat when a called roll ends.", true)
    addCheck("Auto +1 on award", "autoPlusOne",
        "Mark the receiving player +1 in the +1 Loot tracker when you hand out an item.", true)
    addCheck("Countdown last 5 seconds of rolls", "countdown",
        "Announce 5... 4... 3... 2... 1... in raid chat as the roll window closes.", true)

    local rtLabel = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(rtLabel, 12, false)
    rtLabel:SetTextColor(unpack(C.text))
    rtLabel:SetPoint("TOPLEFT", y, "BOTTOMLEFT", 0, -12)
    rtLabel:SetText("Roll timer (seconds):")

    local rtEdit = Skin:EditBox(panel, 50, 20)
    rtEdit:SetPoint("LEFT", rtLabel, "RIGHT", 8, -1)
    rtEdit:SetNumeric(true)
    rtEdit:SetText(tostring(rollTime()))
    rtEdit:SetScript("OnEditFocusLost", function(s)
        local v = tonumber(s:GetText()) or 8
        if v < 3 then v = 3 elseif v > 60 then v = 60 end
        RMS.db.masterloot.rollTime = v
        s:SetText(tostring(v))
        s:SetBackdropBorderColor(unpack(C.border))
        if M.win and M.win:IsShown() then M:RefreshWindow() end
    end)
    -- tooltip goes on the edit box: FontStrings can't take mouse scripts
    Skin:AttachTooltip(rtEdit, "Roll timer",
        { "How long Call Roll collects /rolls (3-60 seconds)." })
    refreshers[#refreshers+1] = function()
        if not rtEdit:HasFocus() then rtEdit:SetText(tostring(rollTime())) end
    end
    y = rtLabel

    local qualBtn = Skin:Button(panel, "", 170, 20)
    qualBtn:SetPoint("TOPLEFT", y, "BOTTOMLEFT", 0, -14)
    local function refreshQualBtn()
        qualBtn:SetText("Fixed min quality: "..qualityName(cfg().minQuality or 4))
    end
    qualBtn:SetScript("OnMouseUp", function()
        local q = (cfg().minQuality or 4) + 1
        if q > 5 then q = 2 end
        RMS.db.masterloot.minQuality = q
        refreshQualBtn()
    end)
    Skin:AttachTooltip(qualBtn, "Fixed min quality",
        { "Used only when 'Use the dungeon's loot threshold' is unticked." })
    refreshQualBtn()

    -- re-read config on show so changes made in the Settings tab appear here
    panel:SetScript("OnShow", function()
        for _, fn in ipairs(refreshers) do fn() end
        refreshQualBtn()
        self:Refresh()
    end)

    -- history
    local histHdr = Skin:Header(panel, "Award History")
    histHdr:SetPoint("TOPLEFT", statusFs, "BOTTOMLEFT", 360, -8)
    histHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

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
    local histList = Skin:ScrollList(panel, 18, buildLogRow, updLogRow)
    histList:SetPoint("TOPLEFT", histHdr, "BOTTOMLEFT", 0, -2)
    histList:SetPoint("BOTTOM", panel, "BOTTOM", 0, 8)
    histList:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    self._ui = { panel = panel, status = statusFs, hist = histList }
    self:Refresh()
    return panel
end

function M:Refresh()
    if not self._ui then return end
    local method = GetLootMethod and GetLootMethod() or "?"
    local isML = RMS:IsMasterLooter()
    local line = ("Loot method: |cffffd070%s|r   Threshold: |cffffd070%s+|r   You are %s"):format(
        method, qualityName(effectiveThreshold()),
        isML and "|cff60ff60the master looter|r" or "|cff999999not the master looter|r")
    self._ui.status:SetText(line)
    self._ui.hist:SetData(self.state.history or {})
    if self.win and self.win:IsShown() then self:RefreshWindow() end
end

-- ---------- slash ----------
function M:OnSlash(arg)
    arg = arg or ""
    if arg == "show" or arg == "window" then return self:Preview() end
    RMS.UI:Show("masterloot")
end
