-- Raid Master Suite -- UI
-- Main window: title bar, vertical tab bar, content area. Hosts module panels.

local RMS = RaidMasterSuite
local UI = {}
RMS.UI = UI

local TAB_ORDER = { "softres", "hardres", "dkp", "goldbid", "bis", "advertising", "settings", "donate" }

function UI:Build()
    if self.frame then return self.frame end
    local Skin = RMS.Skin
    local C = Skin.COLOR

    local f = CreateFrame("Frame", "RaidMasterSuiteFrame", UIParent)
    f:SetSize(820, 540)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true); f:EnableMouse(true)
    f:Hide()
    Skin:SetBackdrop(f, C.bgMain, C.borderHi)
    self.frame = f

    -- title bar (drag handle)
    local title = CreateFrame("Frame", nil, f)
    title:SetPoint("TOPLEFT", 0, 0); title:SetPoint("TOPRIGHT", 0, 0)
    title:SetHeight(32)
    Skin:SetBackdrop(title, C.bgHeader, C.border)
    title:EnableMouse(true)
    title:RegisterForDrag("LeftButton")
    title:SetScript("OnDragStart", function() if not RMS.db.ui.locked then f:StartMoving() end end)
    title:SetScript("OnDragStop",  function() f:StopMovingOrSizing() end)

    local logo = title:CreateFontString(nil, "OVERLAY")
    Skin:Font(logo, 16, true)
    logo:SetTextColor(unpack(C.accent))
    logo:SetPoint("LEFT", 12, 0)
    logo:SetText("RAID MASTER SUITE")

    local sub = title:CreateFontString(nil, "OVERLAY")
    Skin:Font(sub, 10, false)
    sub:SetTextColor(unpack(C.textDim))
    sub:SetPoint("LEFT", logo, "RIGHT", 8, -1)
    sub:SetText("v"..RMS.VERSION)

    local close = Skin:CloseButton(title)
    close:SetPoint("RIGHT", -6, 0)
    close:SetScript("OnClick", function() f:Hide() end)

    local lock = Skin:Button(title, "Lock", 50, 22)
    lock:SetPoint("RIGHT", close, "LEFT", -4, 0)
    local function refreshLock()
        lock.text:SetText(RMS.db.ui.locked and "Unlock" or "Lock")
    end
    lock:SetScript("OnMouseUp", function(s)
        s:SetBackdropColor(unpack(C.bgHover))
        RMS.db.ui.locked = not RMS.db.ui.locked
        refreshLock()
    end)
    f:SetScript("OnShow", refreshLock)

    -- vertical tab bar
    local tabbar = CreateFrame("Frame", nil, f)
    tabbar:SetPoint("TOPLEFT", 6, -38)
    tabbar:SetPoint("BOTTOMLEFT", 6, 6)
    tabbar:SetWidth(150)
    Skin:SetBackdrop(tabbar, C.bgPanel, C.border)
    self.tabbar = tabbar

    -- content area
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", tabbar, "TOPRIGHT", 6, 0)
    content:SetPoint("BOTTOMRIGHT", -6, 6)
    Skin:SetBackdrop(content, C.bgPanel, C.border)
    self.content = content

    self.tabs   = {}
    self.panels = {}

    local y = -8
    for _, id in ipairs(TAB_ORDER) do
        local mod = RMS:GetModule(id)
        if mod then
            local b = Skin:TabButton(tabbar, mod.title, 138, 28)
            b:SetPoint("TOPLEFT", 6, y)
            b:SetScript("OnClick", function() UI:Show(id) end)
            self.tabs[id] = b
            y = y - 32
        end
    end

    -- Status bar at bottom of title
    local status = title:CreateFontString(nil, "OVERLAY")
    Skin:Font(status, 10, false)
    status:SetTextColor(unpack(C.textDim))
    status:SetPoint("RIGHT", lock, "LEFT", -10, 0)
    self.status = status
    self:UpdateStatus()

    -- prep first tab WITHOUT showing the window (auto-show is opt-in via Settings)
    self:_SelectTab(TAB_ORDER[1])

    return f
end

function UI:_SelectTab(id)
    if id and self.tabs and self.tabs[id] then
        for tid, btn in pairs(self.tabs) do btn:SetSelected(tid == id) end
        for pid, panel in pairs(self.panels) do if pid ~= id then panel:Hide() end end
        local p = self:GetOrBuildPanel(id)
        if p then p:Show() end
        self.activeTab = id
    end
end

function UI:UpdateStatus()
    if not self.status then return end
    local role = RMS:IsRaidLeader() and "Leader"
              or RMS:IsAssist()    and "Assist"
              or RMS:InRaid()      and "Raid"
              or RMS:InGroup()     and "Party"
              or "Solo"
    local ml   = RMS:IsMasterLooter() and " | ML" or ""
    self.status:SetText(role..ml)
end

function UI:GetOrBuildPanel(id)
    if self.panels[id] then return self.panels[id] end
    local mod = RMS:GetModule(id)
    if not mod or not mod.BuildUI then return nil end
    local p = mod:BuildUI(self.content)
    p:SetAllPoints(self.content)
    p:Hide()
    self.panels[id] = p
    return p
end

function UI:Show(id)
    self:Build()
    self:_SelectTab(id)
    self:UpdateStatus()
    self.frame:Show()
end

function UI:Hide() if self.frame then self.frame:Hide() end end
function UI:Toggle()
    self:Build()
    if self.frame:IsShown() then self.frame:Hide() else self:Show(self.activeTab or TAB_ORDER[1]) end
end

-- Refresh status when group state changes
RMS:RegisterEvent("RAID_ROSTER_UPDATE",  function() UI:UpdateStatus() end)
RMS:RegisterEvent("PARTY_MEMBERS_CHANGED", function() UI:UpdateStatus() end)
RMS:RegisterEvent("PARTY_LEADER_CHANGED", function() UI:UpdateStatus() end)
