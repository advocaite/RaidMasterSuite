-- Raid Master Suite -- Minimap button
-- Round draggable button on the minimap rim. Left-click toggles the main
-- window, right-click opens Settings, drag slides it around the minimap.
-- Position (angle) and visibility persist in RMS.db.minimap.

local RMS = RaidMasterSuite

local btn

local function conf()
    RMS.db.minimap = RMS.db.minimap or {}
    return RMS.db.minimap
end

local function updatePosition()
    if not btn then return end
    local angle  = math.rad(conf().angle or 215)
    local radius = (Minimap:GetWidth() / 2) + 5
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * radius, math.sin(angle) * radius)
end

local MinimapButton = {}
RMS.MinimapButton = MinimapButton

function MinimapButton:UpdateShown()
    if not btn then return end
    if conf().hide then btn:Hide() else btn:Show() end
end

local function build()
    if btn then updatePosition(); MinimapButton:UpdateShown(); return end

    btn = CreateFrame("Button", "RaidMasterSuiteMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- standard round minimap-button dressing
    local overlay = btn:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetTexture("Interface\\Icons\\INV_Crown_01")
    if not icon:GetTexture() then
        -- crown icon missing on this client; fall back to the LFG eye
        icon:SetTexture("Interface\\Icons\\INV_Misc_GroupLooking")
    end
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -5)
    btn.icon = icon

    btn:SetScript("OnClick", function(_, mouseBtn)
        if not RMS.UI then return end
        if mouseBtn == "RightButton" then
            RMS.UI:Show("settings")
        else
            RMS.UI:Toggle()
        end
    end)

    btn:SetScript("OnDragStart", function(s)
        s._dragging = true
        GameTooltip:Hide()
        s:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            conf().angle = math.deg(math.atan2(cy - my, cx - mx))
            updatePosition()
        end)
    end)
    btn:SetScript("OnDragStop", function(s)
        s._dragging = false
        s:SetScript("OnUpdate", nil)
    end)

    btn:SetScript("OnEnter", function(s)
        if s._dragging then return end
        GameTooltip:SetOwner(s, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Raid Master Suite", 1, 0.85, 0.5)
        GameTooltip:AddLine("Left-click: toggle window", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("Right-click: settings", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("Drag: move around the minimap", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    updatePosition()
    MinimapButton:UpdateShown()
end

-- RMS.db is bound during Boot (ADDON_LOADED), which runs before PLAYER_LOGIN
RMS:RegisterEvent("PLAYER_LOGIN", function() build() end)
