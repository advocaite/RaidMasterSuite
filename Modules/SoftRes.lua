-- Raid Master Suite -- Soft Res module
-- Players reserve item(s) by id. On a roll, SR holders win over non-SR.
-- Full raid sync: every member sees the same SR list.

local RMS = RaidMasterSuite
local M = RMS:RegisterModule("softres", { title = "Soft Res", order = 1 })

-- ---------- State (in-memory; mirrors RMS.db.softresState) ----------
M.state = {
    active   = false,    -- SR session open?
    leader   = nil,      -- name of session host (raid leader)
    reserves = {},       -- [playerName] = { itemID = true, ... }
    items    = {},       -- [itemID] = { name = "Item Name", link = "..." }
    log      = {},       -- recent rolls
}

local function persist()
    RMS.db.softresState = M.state
end
local function restore()
    if RMS.db.softresState then
        for k, v in pairs(RMS.db.softresState) do M.state[k] = v end
    end
end

-- ---------- helpers ----------
local function getItemFromLink(link)
    if not link then return nil end
    local id = tonumber(link:match("item:(%d+)"))
    local name = link:match("%[(.-)%]") or "?"
    return id, name
end

local function reservesForItem(itemID)
    local list = {}
    for player, items in pairs(M.state.reserves) do
        if items[itemID] then list[#list+1] = player end
    end
    table.sort(list)
    return list
end

local function playerHasReserves(player)
    local r = M.state.reserves[player]
    if not r then return 0 end
    local n = 0
    for _ in pairs(r) do n = n + 1 end
    return n
end

-- ---------- session control (leader only -- solo & party also allowed for testing) ----------
local function canHostSession()
    -- Solo or party = always allowed; in a raid only leader may host.
    return (not RMS:InRaid()) or RMS:IsRaidLeader()
end

function M:Open()
    if not canHostSession() then RMS:Print("Only the raid leader can open a Soft Res session.") return end
    -- Re-opening (e.g. to let a late joiner reserve) KEEPS existing reserves;
    -- only Reset wipes them. (GitHub issue: reopen used to reset the list.)
    local hasExisting = false
    for _, items in pairs(self.state.reserves) do
        if next(items) then hasExisting = true; break end
    end
    self.state.active = true
    self.state.leader = RMS:PlayerName()
    if not hasExisting then
        self.state.reserves = {}
        self.state.items    = {}
        self.state.log      = {}
    end
    persist()
    RMS.Comm:Send("softres", "open", { leader = self.state.leader, keep = hasExisting and 1 or 0 })
    if hasExisting then
        -- re-push every reserve so all clients (any addon version) line up
        for player, items in pairs(self.state.reserves) do
            for itemID in pairs(items) do
                local info = self.state.items[itemID]
                RMS.Comm:Send("softres", "add", {
                    player = player, item = itemID,
                    name = info and info.name or "",
                    link = info and info.link or "",
                })
            end
        end
        RMS:Print("Soft Res session RE-OPENED -- existing reserves kept (use Reset for a fresh list).")
    else
        RMS:Print("Soft Res session OPEN.")
    end
    self:Refresh()
end

function M:Close()
    if not canHostSession() then RMS:Print("Only the raid leader can close a Soft Res session.") return end
    self.state.active = false
    persist()
    RMS.Comm:Send("softres", "close", {})
    RMS:Print("Soft Res session CLOSED.")
    self:Refresh()
end

function M:Reset()
    if not canHostSession() then RMS:Print("Only the raid leader can reset reserves.") return end
    self.state.reserves = {}
    self.state.items    = {}
    self.state.log      = {}
    persist()
    RMS.Comm:Send("softres", "reset", {})
    RMS:Print("Soft Res reserves cleared.")
    self:Refresh()
end

-- ---------- player actions ----------
function M:Reserve(itemLink)
    if not self.state.active then RMS:Print("No Soft Res session is open.") return end
    local id, name = getItemFromLink(itemLink)
    if not id then RMS:Print("Invalid item link.") return end

    local me = RMS:PlayerName()
    self.state.reserves[me] = self.state.reserves[me] or {}

    -- Multi-item is the default. Only enforce one-per-player when toggled on.
    if RMS.db.softres.oneItemPerPlayer then
        if playerHasReserves(me) >= 1 and not self.state.reserves[me][id] then
            RMS:Print("You already have a reservation (one-per-player mode). Unreserve it first.")
            return
        end
    end

    if self.state.reserves[me][id] then
        RMS:Print("You already reserved %s.", itemLink)
        return
    end

    self.state.reserves[me][id] = true
    self.state.items[id] = self.state.items[id] or { name = name, link = itemLink }
    persist()
    RMS.Comm:Send("softres", "add", { player = me, item = id, name = name, link = itemLink })
    RMS:Print("Reserved %s.", itemLink)
    self:Refresh()
end

function M:Unreserve(itemID)
    local me = RMS:PlayerName()
    if not self.state.reserves[me] then return end
    self.state.reserves[me][itemID] = nil
    persist()
    RMS.Comm:Send("softres", "del", { player = me, item = itemID })
    self:Refresh()
end

-- ---------- comm handlers (incoming) ----------
RMS.Comm:On("softres", "open", function(p, sender)
    M.state.active   = true
    M.state.leader   = p.leader or sender
    -- keep=1 means the host re-opened an existing session; don't wipe
    if tostring(p.keep) ~= "1" then
        M.state.reserves = {}
        M.state.items    = {}
    end
    persist()
    M:Refresh()
    RMS:Print("Soft Res opened by %s.", sender)
end)

RMS.Comm:On("softres", "close", function(_, sender)
    M.state.active = false
    persist()
    M:Refresh()
    RMS:Print("Soft Res closed by %s.", sender)
end)

RMS.Comm:On("softres", "reset", function(_, sender)
    M.state.reserves = {}
    M.state.items    = {}
    persist()
    M:Refresh()
    RMS:Print("Soft Res reset by %s.", sender)
end)

RMS.Comm:On("softres", "add", function(p, sender)
    if not p.player or not p.item then return end
    local id = tonumber(p.item)
    M.state.reserves[p.player] = M.state.reserves[p.player] or {}
    M.state.reserves[p.player][id] = true
    M.state.items[id] = M.state.items[id] or { name = p.name, link = p.link }
    persist()
    M:Refresh()
end)

RMS.Comm:On("softres", "del", function(p)
    if not p.player or not p.item then return end
    if M.state.reserves[p.player] then
        M.state.reserves[p.player][tonumber(p.item)] = nil
    end
    persist()
    M:Refresh()
end)

-- ---------- late-join sync ----------
-- A client that just joined an existing group asks the raid for current SR state.
-- The session host responds via WHISPER with `open` + an `add` per reserved item.
function M:RequestSync()
    if not RMS:InGroup() then return end
    if self.state.active then return end  -- we already have something
    RMS.Comm:Send("softres", "syncreq", { from = RMS:PlayerName() })
    RMS:Debug("SR: sent syncreq")
end

RMS.Comm:On("softres", "syncreq", function(_, sender)
    if not M.state.active then return end
    if M.state.leader ~= RMS:PlayerName() then return end  -- host only
    if sender == RMS:PlayerName() then return end           -- not to ourselves
    RMS.Comm:SendWhisper("softres", "open", { leader = M.state.leader }, sender)
    for player, items in pairs(M.state.reserves) do
        for itemID in pairs(items) do
            local info = M.state.items[itemID]
            if info then
                RMS.Comm:SendWhisper("softres", "add", {
                    player = player,
                    item   = itemID,
                    name   = info.name or "",
                    link   = info.link or "",
                }, sender)
            end
        end
    end
    RMS:Debug("SR: synced state to %s", sender)
end)

-- ---------- softres.it CSV import ----------
-- One CSV field-splitter that survives quoted fields with commas inside
-- ("Havoc's Call, Blade of Lordaeron Kings") and doubled "" escapes.
local function parseCSVLine(line)
    local fields, pos = {}, 1
    while true do
        if line:sub(pos, pos) == '"' then
            local val, p = "", pos + 1
            while true do
                local ch = line:sub(p, p)
                if ch == "" then break end
                if ch == '"' then
                    if line:sub(p + 1, p + 1) == '"' then
                        val = val..'"'; p = p + 2
                    else
                        p = p + 1; break
                    end
                else
                    val = val..ch; p = p + 1
                end
            end
            fields[#fields+1] = val
            if line:sub(p, p) == "," then pos = p + 1 else break end
        else
            local comma = line:find(",", pos, true)
            if comma then
                fields[#fields+1] = line:sub(pos, comma - 1)
                pos = comma + 1
            else
                fields[#fields+1] = line:sub(pos)
                break
            end
        end
    end
    return fields
end

-- Columns: Item Name, Item ID, From, Raider Name, Class, Spec, Note, Extra, Date
function M:ImportCSV(text)
    if not canHostSession() then
        RMS:Print("Only the raid leader can import Soft Res data.")
        return false
    end
    local newReserves, newItems = {}, {}
    local count, playersSet = 0, {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local f = parseCSVLine(line)
        local itemName = f[1]
        local id       = tonumber(f[2])
        local player   = f[4]
        -- header and malformed lines fail the numeric-id test and are skipped
        if id and player and player ~= "" then
            player = player:sub(1, 1):upper()..player:sub(2)
            newReserves[player] = newReserves[player] or {}
            if not newReserves[player][id] then
                newReserves[player][id] = true
                count = count + 1
            end
            if not newItems[id] then
                local _, link = GetItemInfo(id)
                newItems[id] = { name = itemName, link = link }
            end
            playersSet[player] = true
        end
    end
    if count == 0 then
        RMS:Print("No reserves found -- paste the CSV exported from softres.it (header line included is fine).")
        return false
    end

    -- fresh session with the imported list, synced to the whole raid
    self.state.active   = true
    self.state.leader   = RMS:PlayerName()
    self.state.reserves = newReserves
    self.state.items    = newItems
    self.state.log      = {}
    persist()
    RMS.Comm:Send("softres", "open", { leader = self.state.leader, keep = 0 })
    for player, items in pairs(newReserves) do
        for itemID in pairs(items) do
            local info = newItems[itemID]
            RMS.Comm:Send("softres", "add", {
                player = player, item = itemID,
                name = (info and info.name) or "",
                link = (info and info.link) or "",
            })
        end
    end
    local np = 0
    for _ in pairs(playersSet) do np = np + 1 end
    RMS:Print("Imported %d soft reserves for %d raiders from softres.it.", count, np)
    self:Refresh()
    return true
end

function M:OpenImportDialog()
    local Skin = RMS.Skin
    local C    = Skin.COLOR
    local f = self._importWin
    if not f then
        f = CreateFrame("Frame", "RaidMasterSuiteSRImport", UIParent)
        f:SetSize(470, 360)
        f:SetPoint("CENTER")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:EnableMouse(true); f:SetMovable(true); f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop",  f.StopMovingOrSizing)
        Skin:SetBackdrop(f, C.bgMain, C.accent)
        tinsert(UISpecialFrames, "RaidMasterSuiteSRImport")

        local title = f:CreateFontString(nil, "OVERLAY"); Skin:Font(title, 14, true)
        title:SetTextColor(unpack(C.accent))
        title:SetPoint("TOP", 0, -8); title:SetText("IMPORT SOFT RES  (softres.it)")

        local close = Skin:CloseButton(f); close:SetPoint("TOPRIGHT", -4, -4)
        close:SetScript("OnClick", function() f:Hide() end)

        local desc = f:CreateFontString(nil, "OVERLAY"); Skin:Font(desc, 10, false)
        desc:SetTextColor(unpack(C.text))
        desc:SetPoint("TOPLEFT", 12, -30)
        desc:SetPoint("RIGHT", -12, 0)
        desc:SetJustifyH("LEFT"); desc:SetWordWrap(true)
        desc:SetText("On softres.it open your raid and export it as CSV. Copy everything (the header line is fine), click the box below, paste with |cffffd070Ctrl+V|r, then hit Import. This opens a FRESH Soft Res session with the imported reserves and syncs it to the raid.")

        local box = Skin:Panel(f)
        box:SetPoint("TOPLEFT", 12, -92)
        box:SetPoint("BOTTOMRIGHT", -12, 44)

        local scroll = CreateFrame("ScrollFrame", "RaidMasterSuiteSRImportScroll", box, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 6, -6)
        scroll:SetPoint("BOTTOMRIGHT", -28, 6)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFont(Skin.FONT, 11, "")
        edit:SetTextColor(unpack(C.text))
        edit:SetWidth(400)
        edit:SetMaxLetters(0)
        edit:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        scroll:SetScrollChild(edit)
        f.edit = edit

        -- clicking anywhere in the box focuses the edit for pasting
        box:EnableMouse(true)
        box:SetScript("OnMouseDown", function() edit:SetFocus() end)

        local importBtn = Skin:Button(f, "Import", 100, 24)
        importBtn:SetPoint("BOTTOMLEFT", 12, 10)
        importBtn:SetScript("OnMouseUp", function()
            if M:ImportCSV(f.edit:GetText() or "") then
                f.edit:SetText("")
                f:Hide()
            end
        end)

        local cancel = Skin:Button(f, "Cancel", 80, 24)
        cancel:SetPoint("LEFT", importBtn, "RIGHT", 8, 0)
        cancel:SetScript("OnMouseUp", function() f:Hide() end)

        self._importWin = Skin:ManagedWindow(f)
    end
    f.edit:SetText("")
    f:Show()
    f.edit:SetFocus()
end

-- ---------- roll detection ----------
-- Expand existing /sr-aware roll: when raid leader links an item then players /roll,
-- we collect for ROLL_DURATION and announce the SR-weighted winner.
local rollSession = nil
local ROLL_WINDOW = 8  -- seconds

local function startRollSession(itemID, itemLink)
    rollSession = { itemID = itemID, itemLink = itemLink, expires = GetTime() + ROLL_WINDOW, rolls = {} }
end
local function finishRollSession()
    if not rollSession then return end
    local res = reservesForItem(rollSession.itemID)
    local resSet = {}
    for _, p in ipairs(res) do resSet[p] = true end

    local rolls = rollSession.rolls
    if #rolls == 0 then rollSession = nil; return end

    -- SR-only first; fallback to all if no SR rolled
    local pool = {}
    for _, r in ipairs(rolls) do if resSet[r.player] then pool[#pool+1] = r end end
    if #pool == 0 then pool = rolls end

    table.sort(pool, function(a, b) return a.value > b.value end)
    local winner = pool[1]
    local lineKind = (#pool == #rolls) and "OPEN" or "SR"
    local msg = ("[%s] Winner of %s: %s with %d"):format(lineKind, rollSession.itemLink, winner.player, winner.value)
    if RMS.db.softres.announceRolls and RMS:IsRaidLeader() then
        SendChatMessage(msg, RMS:InRaid() and "RAID_WARNING" or "PARTY")
    end
    table.insert(M.state.log, 1, msg)
    if #M.state.log > 30 then M.state.log[#M.state.log] = nil end
    persist()
    M:Refresh()

    -- +1 tracker hook: every client resolves the same winner locally
    local po = RMS:GetModule("plusone")
    if po and po.OnRollWin then po:OnRollWin(winner.player, rollSession.itemLink) end

    rollSession = nil
end

M.events = {
    CHAT_MSG_SYSTEM = function(self, _, msg)
        local p, val, lo, hi = msg:match("([^%s]+) rolls (%d+) %((%d+)%-(%d+)%)")
        if not p or not rollSession then return end
        if tonumber(lo) ~= 1 or tonumber(hi) ~= 100 then return end
        table.insert(rollSession.rolls, { player = p, value = tonumber(val) })
        if rollSession.expires <= GetTime() then finishRollSession() end
    end,
    CHAT_MSG_RAID_WARNING = function(self, _, msg)
        local link = msg:match("(|c%x+|Hitem:.-|h.-|h|r)")
        local id   = link and tonumber(link:match("item:(%d+)"))
        if not id then return end
        -- the Master Loot window runs its own roll session for this item;
        -- don't start a duplicate SR session on top of it
        local ml = RMS:GetModule("masterloot")
        if ml and ml._roll and not ml._roll.done and tonumber(ml._roll.id) == id then return end
        if M.state.items[id] and msg:lower():find("roll") then
            startRollSession(id, link)
        end
    end,
    PLAYER_LOGIN = function(self)
        restore()
        -- the tab may have been built before restore ran; repaint it
        self:Refresh()
        self._wasInGroup = RMS:InGroup()
        -- defer ~3s so other clients have finished loading before we ask
        if self._wasInGroup then
            local d = CreateFrame("Frame"); local elapsed = 0
            d:SetScript("OnUpdate", function(s, dt)
                elapsed = elapsed + dt
                if elapsed > 3 then s:SetScript("OnUpdate", nil); self:RequestSync() end
            end)
        end
    end,
    RAID_ROSTER_UPDATE     = function(self) self:OnGroupChange() end,
    PARTY_MEMBERS_CHANGED  = function(self) self:OnGroupChange() end,
}

function M:OnGroupChange()
    local nowIn = RMS:InGroup()
    if nowIn and not self._wasInGroup then
        -- transitioned solo -> grouped; ask host for current state
        self:RequestSync()
    end
    self._wasInGroup = nowIn
end

-- Polling timer to expire roll sessions
local poll = CreateFrame("Frame")
poll:SetScript("OnUpdate", function()
    if rollSession and rollSession.expires <= GetTime() then finishRollSession() end
end)

-- ---------- slash ----------
function M:OnSlash(arg)
    arg = arg or ""
    if arg == "open"  then return self:Open()  end
    if arg == "close" then return self:Close() end
    if arg == "reset" then return self:Reset() end
    -- treat as itemlink
    local link = arg:match("(|c%x+|Hitem:.-|h.-|h|r)")
    if link then return self:Reserve(link) end
    RMS.UI:Show("softres")
end

-- ---------- UI ----------
function M:BuildUI(parent)
    local Skin = RMS.Skin
    local C    = Skin.COLOR
    local panel = CreateFrame("Frame", nil, parent)

    local header = Skin:Header(panel, "Soft Reserve")
    header:SetPoint("TOPLEFT", 8, -8)
    header:SetPoint("TOPRIGHT", -8, -8)

    -- status pill
    local status = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(status, 12, true)
    status:SetPoint("RIGHT", header, "RIGHT", -10, 0)

    -- leader controls
    local openBtn  = Skin:Button(panel, "Open Session", 110, 24)
    local closeBtn = Skin:Button(panel, "Close",         70, 24)
    local resetBtn = Skin:Button(panel, "Reset",         70, 24)
    openBtn:SetPoint ("TOPLEFT", header, "BOTTOMLEFT", 0, -8)
    closeBtn:SetPoint("LEFT", openBtn,  "RIGHT", 6, 0)
    resetBtn:SetPoint("LEFT", closeBtn, "RIGHT", 6, 0)
    openBtn :SetScript("OnMouseUp", function() self:Open()  end)
    closeBtn:SetScript("OnMouseUp", function() self:Close() end)
    resetBtn:SetScript("OnMouseUp", function() self:Reset() end)

    -- reserve box for any player
    local resLabel = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(resLabel, 11, false)
    resLabel:SetTextColor(unpack(C.textDim))
    resLabel:SetPoint("TOPLEFT", openBtn, "BOTTOMLEFT", 0, -10)
    resLabel:SetText("Shift-click an item link into the box, then Reserve:")

    local edit = Skin:EditBox(panel, 380, 22)
    edit:SetPoint("TOPLEFT", resLabel, "BOTTOMLEFT", 0, -4)
    edit:SetScript("OnReceiveDrag", function(s)
        local _, _, link = GetCursorInfo()
        if link then s:SetText(link) end
        ClearCursor()
    end)
    -- Hyperlink injection: allow shift-click to insert
    hooksecurefunc("ChatEdit_InsertLink", function(text)
        if edit:HasFocus() then edit:SetText(text); return true end
    end)

    local rsvBtn = Skin:Button(panel, "Reserve", 80, 22)
    rsvBtn:SetPoint("LEFT", edit, "RIGHT", 6, 0)
    rsvBtn:SetScript("OnMouseUp", function()
        local link = edit:GetText():match("(|c%x+|Hitem:.-|h.-|h|r)")
        if not link then RMS:Print("Paste a real item link first.") return end
        self:Reserve(link); edit:SetText("")
    end)

    local importBtn = Skin:Button(panel, "Import CSV", 90, 22)
    importBtn:SetPoint("LEFT", rsvBtn, "RIGHT", 6, 0)
    importBtn:SetScript("OnMouseUp", function() self:OpenImportDialog() end)
    Skin:AttachTooltip(importBtn, "Import from softres.it",
        {"Paste the CSV export from softres.it to load a whole raid's soft reserves in one go (leader only)."})

    local pickBtn = Skin:Button(panel, "Add from Loot DB", 130, 22)
    pickBtn:SetPoint("LEFT", importBtn, "RIGHT", 6, 0)
    pickBtn:SetScript("OnMouseUp", function()
        if not RMS.LootPicker then RMS:Print("Loot picker not loaded.") return end
        local me = RMS:PlayerName()
        RMS.LootPicker:Open({
            title        = "Soft Reserve",
            actionLabel  = "Reserve",
            unpickLabel  = "Unreserve",
            isPicked     = function(id)
                local r = self.state.reserves[me]
                return r and r[id] == true
            end,
            onPick   = function(link) self:Reserve(link) end,
            onUnpick = function(id)   self:Unreserve(id) end,
        })
    end)

    -- two columns: items list, log
    local itemsHdr = Skin:Header(panel, "Reserved Items")
    itemsHdr:SetPoint("TOPLEFT", edit, "BOTTOMLEFT", 0, -12)
    itemsHdr:SetWidth(380)

    local logHdr = Skin:Header(panel, "Recent Rolls")
    logHdr:SetPoint("LEFT", itemsHdr, "RIGHT", 8, 0)
    logHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    local function buildItemRow(parent)
        local r = CreateFrame("Button", nil, parent)
        r:SetHeight(20)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
        local nameFs = r:CreateFontString(nil, "OVERLAY")
        Skin:Font(nameFs, 12, false)
        nameFs:SetPoint("LEFT", 6, 0)
        r.name = nameFs
        local players = r:CreateFontString(nil, "OVERLAY")
        Skin:Font(players, 11, false)
        players:SetTextColor(unpack(C.accent))
        players:SetPoint("RIGHT", -6, 0)
        r.players = players
        r:SetScript("OnEnter", function(s)
            if not s.itemID then return end
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:"..s.itemID)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return r
    end
    local function updateItemRow(r, item, idx, alt)
        if not item then return end
        r.itemID = item.id
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        r.name:SetText(item.link or item.name or ("item:"..item.id))
        r.players:SetText(table.concat(item.players, ", "))
    end

    local itemsList = Skin:ScrollList(panel, 22, buildItemRow, updateItemRow)
    itemsList:SetPoint("TOPLEFT", itemsHdr, "BOTTOMLEFT", 0, -2)
    itemsList:SetPoint("BOTTOM", panel, "BOTTOM", 0, 8)
    itemsList:SetWidth(380)

    local function buildLogRow(parent)
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(18)
        local fs = r:CreateFontString(nil, "OVERLAY")
        Skin:Font(fs, 11, false)
        fs:SetPoint("LEFT", 4, 0); fs:SetPoint("RIGHT", -4, 0)
        fs:SetJustifyH("LEFT")
        r.text = fs
        return r
    end
    local function updateLogRow(r, text)
        r.text:SetText(text or "")
    end
    local logList = Skin:ScrollList(panel, 18, buildLogRow, updateLogRow)
    logList:SetPoint("TOPLEFT",  logHdr, "BOTTOMLEFT", 0, -2)
    logList:SetPoint("BOTTOM", panel, "BOTTOM", 0, 8)
    logList:SetPoint("RIGHT",  panel, "RIGHT",  -8, 0)

    -- expose for refresh
    self._ui = {
        panel = panel, status = status, items = itemsList, log = logList,
        openBtn = openBtn, closeBtn = closeBtn, resetBtn = resetBtn,
    }
    self:Refresh()
    return panel
end

function M:Refresh()
    if not self._ui then return end
    local C = RMS.Skin.COLOR

    if self.state.active then
        self._ui.status:SetText("OPEN -- host: "..(self.state.leader or "?"))
        self._ui.status:SetTextColor(unpack(C.good))
    else
        self._ui.status:SetText("CLOSED")
        self._ui.status:SetTextColor(unpack(C.textDim))
    end

    -- enable/disable leader buttons
    if RMS:IsRaidLeader() or not RMS:InRaid() then
        self._ui.openBtn:Enable(); self._ui.closeBtn:Enable(); self._ui.resetBtn:Enable()
    else
        self._ui.openBtn:Disable(); self._ui.closeBtn:Disable(); self._ui.resetBtn:Disable()
    end

    -- collect items
    local items = {}
    for id, info in pairs(self.state.items) do
        local players = reservesForItem(id)
        if #players > 0 then
            items[#items+1] = { id = id, name = info.name, link = info.link, players = players }
        end
    end
    table.sort(items, function(a, b) return (a.name or "") < (b.name or "") end)
    self._ui.items:SetData(items)
    self._ui.log:SetData(self.state.log or {})
end
