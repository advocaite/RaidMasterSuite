-- Raid Master Suite -- Hard Res
-- Items pre-assigned by the raid leader to specific players.
-- The item is GUARANTEED to that player when it drops -- no roll, no bid.
-- Full raid sync; on LOOT_OPENED the host gets a reminder of who gets what.

local RMS = RaidMasterSuite
local M = RMS:RegisterModule("hardres", { title = "Hard Res", order = 2 })

-- ---------- state ----------
M.state = {
    active      = false,    -- session open?
    leader      = nil,      -- host name
    assignments = {},       -- list of {id=itemID, link=link, name=name, player=playerName}
    log         = {},       -- recent events
}

local function persist() RMS.db.hardresState = M.state end
local function restore()
    if RMS.db.hardresState then
        for k, v in pairs(RMS.db.hardresState) do M.state[k] = v end
    end
end

local function canHostSession()
    return (not RMS:InRaid()) or RMS:IsRaidLeader()
end

local function isHost()
    return M.state.active and M.state.leader == RMS:PlayerName()
end

local function getItemFromLink(link)
    if not link then return nil end
    local id = tonumber(link:match("item:(%d+)"))
    local name = link:match("%[(.-)%]") or "?"
    return id, name
end

local function pushLog(msg)
    table.insert(M.state.log, 1, msg)
    if #M.state.log > 30 then M.state.log[#M.state.log] = nil end
end

-- ---------- session lifecycle ----------
function M:Open()
    if not canHostSession() then RMS:Print("Only the raid leader can open a Hard Res session.") return end
    self.state.active      = true
    self.state.leader      = RMS:PlayerName()
    self.state.assignments = {}
    self.state.log         = {}
    persist()
    RMS.Comm:Send("hardres", "open", { leader = self.state.leader })
    RMS:Print("Hard Res session OPEN.")
    self:Refresh()
end

function M:Close()
    if not canHostSession() then RMS:Print("Only the raid leader can close a Hard Res session.") return end
    self.state.active = false
    persist()
    RMS.Comm:Send("hardres", "close", {})
    RMS:Print("Hard Res session CLOSED.")
    self:Refresh()
end

function M:Reset()
    if not canHostSession() then RMS:Print("Only the raid leader can reset assignments.") return end
    self.state.assignments = {}
    self.state.log         = {}
    persist()
    RMS.Comm:Send("hardres", "reset", {})
    RMS:Print("Hard Res assignments cleared.")
    self:Refresh()
end

-- ---------- assignment actions (host only) ----------
function M:Assign(player, itemLink)
    if not isHost() then RMS:Print("Only the session host can assign items.") return end
    if not player or player == "" then RMS:Print("Set the assignee first.") return end
    local id, name = getItemFromLink(itemLink)
    if not id then RMS:Print("Invalid item link.") return end

    table.insert(self.state.assignments, { id = id, link = itemLink, name = name, player = player })
    pushLog(("Assigned %s -> %s"):format(itemLink, player))
    persist()
    RMS.Comm:Send("hardres", "assign", { id = id, link = itemLink, name = name, player = player })
    RMS:Print("Hard-assigned %s to %s.", itemLink, player)
    self:Refresh()
end

function M:Unassign(index)
    if not isHost() then RMS:Print("Only the session host can remove assignments.") return end
    local a = self.state.assignments[index]
    if not a then return end
    table.remove(self.state.assignments, index)
    pushLog(("Removed %s -> %s"):format(a.link or a.name or "?", a.player or "?"))
    persist()
    RMS.Comm:Send("hardres", "unassign", { id = a.id, player = a.player })
    self:Refresh()
end

-- ---------- comm handlers (incoming) ----------
RMS.Comm:On("hardres", "open", function(p, sender)
    M.state.active      = true
    M.state.leader      = p.leader or sender
    M.state.assignments = {}
    M.state.log         = {}
    persist()
    M:Refresh()
    RMS:Print("Hard Res opened by %s.", sender)
end)

RMS.Comm:On("hardres", "close", function(_, sender)
    M.state.active = false
    persist()
    M:Refresh()
    RMS:Print("Hard Res closed by %s.", sender)
end)

RMS.Comm:On("hardres", "reset", function(_, sender)
    M.state.assignments = {}
    M.state.log         = {}
    persist()
    M:Refresh()
    RMS:Print("Hard Res reset by %s.", sender)
end)

RMS.Comm:On("hardres", "assign", function(p, sender)
    if not p.id or not p.player then return end
    -- only accept from current host
    if M.state.leader ~= sender then return end
    table.insert(M.state.assignments, {
        id = tonumber(p.id), link = p.link, name = p.name, player = p.player,
    })
    pushLog(("Assigned %s -> %s"):format(p.link or p.name or "?", p.player))
    persist()
    M:Refresh()
end)

RMS.Comm:On("hardres", "unassign", function(p, sender)
    if M.state.leader ~= sender then return end
    if not p.id or not p.player then return end
    local id = tonumber(p.id)
    for i = #M.state.assignments, 1, -1 do
        local a = M.state.assignments[i]
        if a.id == id and a.player == p.player then
            table.remove(M.state.assignments, i)
            break
        end
    end
    persist()
    M:Refresh()
end)

-- ---------- late-join sync ----------
function M:RequestSync()
    if not RMS:InGroup() then return end
    if self.state.active then return end
    RMS.Comm:Send("hardres", "syncreq", { from = RMS:PlayerName() })
end

RMS.Comm:On("hardres", "syncreq", function(_, sender)
    if not isHost() then return end
    if sender == RMS:PlayerName() then return end
    RMS.Comm:SendWhisper("hardres", "open", { leader = M.state.leader }, sender)
    for _, a in ipairs(M.state.assignments) do
        RMS.Comm:SendWhisper("hardres", "assign", {
            id = a.id, link = a.link or "", name = a.name or "", player = a.player,
        }, sender)
    end
end)

-- ---------- loot-drop reminder ----------
-- When loot window opens, remind the host of any assigned items present.
local function onLootOpened()
    if not M.state.active then return end
    if not isHost() then return end
    local matched = {}
    local n = GetNumLootItems and GetNumLootItems() or 0
    for slot = 1, n do
        local link = GetLootSlotLink and GetLootSlotLink(slot) or nil
        local id   = link and tonumber(link:match("item:(%d+)"))
        if id then
            for _, a in ipairs(M.state.assignments) do
                if a.id == id then matched[#matched+1] = a end
            end
        end
    end
    if #matched > 0 then
        for _, a in ipairs(matched) do
            RMS:Print("|cffffd070HR|r %s -> |cffffffff%s|r", a.link or a.name or "?", a.player)
        end
    end
end

-- ---------- events ----------
M.events = {
    LOOT_OPENED = function(self) onLootOpened() end,
    PLAYER_LOGIN = function(self)
        restore()
        self._wasInGroup = RMS:InGroup()
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
    if nowIn and not self._wasInGroup then self:RequestSync() end
    self._wasInGroup = nowIn
end

-- ---------- slash ----------
function M:OnSlash(arg)
    arg = arg or ""
    if arg == "open"  then return self:Open()  end
    if arg == "close" then return self:Close() end
    if arg == "reset" then return self:Reset() end
    RMS.UI:Show("hardres")
end

-- ---------- UI ----------
function M:BuildUI(parent)
    local Skin = RMS.Skin
    local C    = Skin.COLOR
    local panel = CreateFrame("Frame", nil, parent)

    local header = Skin:Header(panel, "Hard Reserve")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)

    local status = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(status, 12, true)
    status:SetPoint("RIGHT", header, "RIGHT", -10, 0)

    -- session controls
    local openBtn  = Skin:Button(panel, "Open Session", 110, 24)
    local closeBtn = Skin:Button(panel, "Close",         70, 24)
    local resetBtn = Skin:Button(panel, "Reset",         70, 24)
    openBtn :SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -8)
    closeBtn:SetPoint("LEFT", openBtn,  "RIGHT", 6, 0)
    resetBtn:SetPoint("LEFT", closeBtn, "RIGHT", 6, 0)
    openBtn :SetScript("OnMouseUp", function() self:Open()  end)
    closeBtn:SetScript("OnMouseUp", function() self:Close() end)
    resetBtn:SetScript("OnMouseUp", function() self:Reset() end)

    -- assignee row
    local label = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(label, 11, false)
    label:SetTextColor(unpack(C.textDim))
    label:SetPoint("TOPLEFT", openBtn, "BOTTOMLEFT", 0, -10)
    label:SetText("Assign to player:")

    local nameEdit = Skin:EditBox(panel, 180, 22)
    nameEdit:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)

    local pickRaidBtn = Skin:Button(panel, "Pick from Raid", 110, 22)
    pickRaidBtn:SetPoint("LEFT", nameEdit, "RIGHT", 6, 0)
    pickRaidBtn:SetScript("OnMouseUp", function() self:_ShowRaidPicker(nameEdit) end)

    -- item entry row
    local label2 = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(label2, 11, false)
    label2:SetTextColor(unpack(C.textDim))
    label2:SetPoint("TOPLEFT", nameEdit, "BOTTOMLEFT", 0, -10)
    label2:SetText("Item (paste link or use Loot DB):")

    local linkEdit = Skin:EditBox(panel, 360, 22)
    linkEdit:SetPoint("TOPLEFT", label2, "BOTTOMLEFT", 0, -4)
    hooksecurefunc("ChatEdit_InsertLink", function(text)
        if linkEdit:HasFocus() then linkEdit:SetText(text); return true end
    end)

    local assignBtn = Skin:Button(panel, "Assign", 80, 22)
    assignBtn:SetPoint("LEFT", linkEdit, "RIGHT", 6, 0)
    assignBtn:SetScript("OnMouseUp", function()
        local link = linkEdit:GetText():match("(|c%x+|Hitem:.-|h.-|h|r)")
        if not link then RMS:Print("Paste a real item link first.") return end
        self:Assign(nameEdit:GetText(), link)
        linkEdit:SetText("")
    end)

    local pickBtn = Skin:Button(panel, "Add from Loot DB", 130, 22)
    pickBtn:SetPoint("LEFT", assignBtn, "RIGHT", 6, 0)
    pickBtn:SetScript("OnMouseUp", function()
        if not RMS.LootPicker then RMS:Print("Loot picker not loaded.") return end
        local who = nameEdit:GetText()
        if not who or who == "" then RMS:Print("Set the assignee first.") return end
        RMS.LootPicker:Open({
            title       = "Hard Assign -> "..who,
            actionLabel = "Assign",
            unpickLabel = "Remove",
            isPicked    = function(id)
                for _, a in ipairs(self.state.assignments) do
                    if a.id == id and a.player == who then return true end
                end
                return false
            end,
            onPick   = function(link) self:Assign(who, link) end,
            onUnpick = function(id)
                for i = #self.state.assignments, 1, -1 do
                    local a = self.state.assignments[i]
                    if a.id == id and a.player == who then self:Unassign(i); return end
                end
            end,
        })
    end)

    -- assignments list
    local listHdr = Skin:Header(panel, "Current Assignments")
    listHdr:SetPoint("TOPLEFT", linkEdit, "BOTTOMLEFT", 0, -14)
    listHdr:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, 0)
    listHdr:ClearAllPoints()
    listHdr:SetPoint("TOPLEFT", linkEdit, "BOTTOMLEFT", 0, -14)
    listHdr:SetWidth(540)

    local function buildAssignRow(parent)
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(22)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg

        -- a hidden Button covers the item-link area to capture mouse for tooltip
        local hover = CreateFrame("Button", nil, r)
        hover:SetPoint("TOPLEFT", 0, 0); hover:SetPoint("BOTTOMRIGHT", -200, 0)
        r.hover = hover

        local item = hover:CreateFontString(nil, "OVERLAY")
        Skin:Font(item, 11, false)
        item:SetPoint("LEFT", 6, 0); item:SetPoint("RIGHT", -4, 0)
        item:SetJustifyH("LEFT"); item:SetWordWrap(false); item:SetNonSpaceWrap(false)
        r.item = item

        local who = r:CreateFontString(nil, "OVERLAY")
        Skin:Font(who, 11, true)
        who:SetPoint("RIGHT", -90, 0); who:SetWidth(120)
        who:SetJustifyH("RIGHT")
        r.who = who

        local rm = Skin:Button(r, "Remove", 70, 18)
        rm:SetPoint("RIGHT", -4, 0)
        r.rm = rm
        return r
    end
    local function updateAssignRow(r, item, idx, alt)
        if not item then return end
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        r.item:SetText(item.link or item.name or ("item:"..item.id))
        local color = M:_PlayerColor(item.player)
        r.who:SetText(("|c%s%s|r"):format(color, item.player or "?"))
        if isHost() then r.rm:Enable() else r.rm:Disable() end
        r.rm:SetScript("OnMouseUp", function()
            for i, a in ipairs(M.state.assignments) do
                if a.id == item.id and a.player == item.player then
                    M:Unassign(i); return
                end
            end
        end)
        -- hover tooltip on the item area
        r.hover:SetScript("OnEnter", function(s)
            if not item.id then return end
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:"..item.id)
            GameTooltip:Show()
        end)
        r.hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    local listScroll = Skin:ScrollList(panel, 22, buildAssignRow, updateAssignRow)
    listScroll:SetPoint("TOPLEFT",  listHdr,  "BOTTOMLEFT", 0, -2)
    listScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 8)

    self._ui = {
        panel = panel, status = status,
        openBtn = openBtn, closeBtn = closeBtn, resetBtn = resetBtn,
        nameEdit = nameEdit, linkEdit = linkEdit,
        assignBtn = assignBtn, pickBtn = pickBtn, pickRaidBtn = pickRaidBtn,
        listScroll = listScroll,
    }
    self:Refresh()
    return panel
end

-- color player name green if currently in group, dim otherwise
function M:_PlayerColor(name)
    if not name then return "ff999999" end
    local me = RMS:PlayerName()
    if name == me then return "ffffd070" end
    local n = GetNumRaidMembers()
    if n > 0 then
        for i = 1, n do
            if GetRaidRosterInfo(i) == name then return "ff60ff60" end
        end
        return "ffff6060"
    end
    n = GetNumPartyMembers()
    for i = 1, n do
        if UnitName("party"..i) == name then return "ff60ff60" end
    end
    return "ff999999"
end

-- raid-name picker popup attached to an editbox.
-- Toggle behavior: clicking the trigger button again closes it.
-- Closes on: row click, X button, ESC (via UISpecialFrames).
function M:_ShowRaidPicker(editbox)
    local Skin = RMS.Skin
    local C    = Skin.COLOR
    local roster = RMS:GetRosterNames()
    if #roster == 0 then RMS:Print("No raid/party members.") return end

    -- toggle: if open, just close
    if self._raidPickerWin and self._raidPickerWin:IsShown() then
        self._raidPickerWin:Hide(); return
    end

    local f = self._raidPickerWin
    if not f then
        f = CreateFrame("Frame", "RaidMasterSuiteRaidPickerPopup", UIParent)
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        Skin:SetBackdrop(f, C.bgMain, C.accent)
        f:EnableMouse(true)
        f._rows = {}
        self._raidPickerWin = f
        -- ESC closes it
        tinsert(UISpecialFrames, "RaidMasterSuiteRaidPickerPopup")

        local close = Skin:Button(f, "x", 18, 18)
        close:SetPoint("TOPRIGHT", -3, -3)
        close.text:SetTextColor(unpack(C.bad))
        close:SetScript("OnMouseUp", function() f:Hide() end)
        f._close = close
    end

    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", editbox, "BOTTOMLEFT", 0, -2)
    f:SetSize(180, 24 + #roster * 22)

    -- rebuild rows for current roster (reuse pooled rows where possible)
    for i = #f._rows + 1, #roster do
        local b = Skin:Button(f, "", 168, 20)
        b:SetPoint("TOPLEFT", 6, -22 - (i - 1) * 22)
        f._rows[i] = b
    end
    for i, b in ipairs(f._rows) do
        if i <= #roster then
            local name = roster[i]
            b:SetText(name)
            b:SetScript("OnMouseUp", function()
                editbox:SetText(name); f:Hide()
            end)
            b:Show()
        else
            b:Hide()
        end
    end
    f:Show()
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

    if canHostSession() then
        self._ui.openBtn:Enable(); self._ui.closeBtn:Enable(); self._ui.resetBtn:Enable()
    else
        self._ui.openBtn:Disable(); self._ui.closeBtn:Disable(); self._ui.resetBtn:Disable()
    end
    if isHost() then
        self._ui.assignBtn:Enable(); self._ui.pickBtn:Enable()
    else
        self._ui.assignBtn:Disable(); self._ui.pickBtn:Disable()
    end

    -- snapshot for the scroll list (we want stable references for click handlers)
    local data = {}
    for i, a in ipairs(self.state.assignments) do
        data[i] = a
    end
    self._ui.listScroll:SetData(data)
end
