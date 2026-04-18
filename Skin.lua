-- Raid Master Suite -- Skin
-- Visual style mimicking Zygor Remaster (dark + gold accent).
-- Provides small widget factories: backdrops, buttons, edit boxes, scroll, tabs.

local RMS = RaidMasterSuite
local Skin = {}
RMS.Skin = Skin

-- ---------- Palette ----------
local TEX_PATH = "Interface\\AddOns\\RaidMasterSuite\\Skin\\"

Skin.PATH         = TEX_PATH
Skin.TEX_WHITE    = TEX_PATH.."white.tga"
Skin.TEX_BACK     = TEX_PATH.."backdrop-opaque-small.tga"
Skin.TEX_GLOW     = TEX_PATH.."glowborder.tga"
Skin.TEX_ARROWDN  = TEX_PATH.."arrowdown.tga"
Skin.TEX_ARROWUP  = TEX_PATH.."arrowup.tga"
Skin.TEX_SEP      = TEX_PATH.."separator.tga"
Skin.TEX_SEARCH   = TEX_PATH.."search.tga"
Skin.FONT         = TEX_PATH.."segoeui.ttf"
Skin.FONT_BOLD    = TEX_PATH.."segoeuib.ttf"

Skin.COLOR = {
    bgMain    = {0.08, 0.08, 0.10, 0.96},
    bgPanel   = {0.10, 0.10, 0.12, 0.95},
    bgHeader  = {0.14, 0.14, 0.16, 0.98},
    bgRow     = {0.12, 0.12, 0.14, 0.85},
    bgRowAlt  = {0.10, 0.10, 0.12, 0.85},
    bgHover   = {0.18, 0.18, 0.20, 1.00},
    bgActive  = {0.22, 0.22, 0.24, 1.00},
    border    = {0.22, 0.22, 0.25, 0.90},
    borderHi  = {0.40, 0.40, 0.45, 0.95},
    accent    = {0.90, 0.74, 0.40, 1.00},
    accentDim = {0.55, 0.45, 0.25, 0.80},
    text      = {0.92, 0.92, 0.94, 1.00},
    textDim   = {0.65, 0.65, 0.68, 1.00},
    textHead  = {1.00, 0.85, 0.50, 1.00},
    good      = {0.30, 0.85, 0.35, 1.00},
    bad       = {0.95, 0.30, 0.30, 1.00},
    warn      = {0.95, 0.75, 0.20, 1.00},
}

local C   = Skin.COLOR
local SBD = {bgFile=Skin.TEX_WHITE, edgeFile=Skin.TEX_WHITE, tile=false, tileSize=0, edgeSize=1, insets={left=1,right=1,top=1,bottom=1}}

-- ---------- Helpers ----------
function Skin:SetBackdrop(frame, bgColor, borderColor)
    frame:SetBackdrop(SBD)
    frame:SetBackdropColor(unpack(bgColor or C.bgPanel))
    frame:SetBackdropBorderColor(unpack(borderColor or C.border))
end

function Skin:Font(fs, size, bold)
    fs:SetFont(bold and self.FONT_BOLD or self.FONT, size or 12, "")
end

-- ---------- Frame factories ----------
function Skin:Panel(parent, name)
    local f = CreateFrame("Frame", name, parent)
    self:SetBackdrop(f, C.bgPanel, C.border)
    return f
end

function Skin:Header(parent, text)
    local h = CreateFrame("Frame", nil, parent)
    self:SetBackdrop(h, C.bgHeader, C.border)
    h:SetHeight(28)
    local fs = h:CreateFontString(nil, "OVERLAY")
    self:Font(fs, 14, true)
    fs:SetTextColor(unpack(C.textHead))
    fs:SetPoint("LEFT", 10, 0)
    fs:SetText(text or "")
    h.text = fs
    return h
end

function Skin:Separator(parent)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetTexture(self.TEX_SEP)
    t:SetHeight(2)
    return t
end

-- ---------- Buttons ----------
function Skin:Button(parent, label, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 100, h or 22)
    self:SetBackdrop(b, C.bgRow, C.border)

    local fs = b:CreateFontString(nil, "OVERLAY")
    self:Font(fs, 12, true)
    fs:SetTextColor(unpack(C.text))
    fs:SetPoint("CENTER")
    fs:SetText(label or "")
    b.text = fs

    b:SetScript("OnEnter", function(s)
        s:SetBackdropColor(unpack(C.bgHover))
        s:SetBackdropBorderColor(unpack(C.accent))
        s.text:SetTextColor(unpack(C.textHead))
    end)
    b:SetScript("OnLeave", function(s)
        s:SetBackdropColor(unpack(C.bgRow))
        s:SetBackdropBorderColor(unpack(C.border))
        s.text:SetTextColor(unpack(C.text))
    end)
    b:SetScript("OnMouseDown", function(s) s:SetBackdropColor(unpack(C.bgActive)) end)
    b:SetScript("OnMouseUp",   function(s) s:SetBackdropColor(unpack(C.bgHover))  end)

    function b:SetText(t) self.text:SetText(t) end
    function b:Disable()
        self:EnableMouse(false)
        self:SetBackdropColor(0.05,0.05,0.07,0.9)
        self.text:SetTextColor(unpack(C.textDim))
        self.disabled = true
    end
    function b:Enable()
        self:EnableMouse(true)
        self:SetBackdropColor(unpack(C.bgRow))
        self.text:SetTextColor(unpack(C.text))
        self.disabled = false
    end
    return b
end

function Skin:CloseButton(parent)
    local b = self:Button(parent, "X", 22, 22)
    b.text:SetTextColor(unpack(C.bad))
    return b
end

function Skin:TabButton(parent, label, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 130, h or 28)
    self:SetBackdrop(b, C.bgRowAlt, C.border)

    local fs = b:CreateFontString(nil, "OVERLAY")
    self:Font(fs, 12, true)
    fs:SetTextColor(unpack(C.text))
    fs:SetPoint("LEFT", 10, 0)
    fs:SetText(label or "")
    b.text = fs

    function b:SetSelected(on)
        self.selected = on
        if on then
            self:SetBackdropColor(unpack(C.bgActive))
            self:SetBackdropBorderColor(unpack(C.accent))
            self.text:SetTextColor(unpack(C.textHead))
        else
            self:SetBackdropColor(unpack(C.bgRowAlt))
            self:SetBackdropBorderColor(unpack(C.border))
            self.text:SetTextColor(unpack(C.text))
        end
    end
    b:SetScript("OnEnter", function(s) if not s.selected then s:SetBackdropColor(unpack(C.bgHover)) end end)
    b:SetScript("OnLeave", function(s) if not s.selected then s:SetBackdropColor(unpack(C.bgRowAlt)) end end)
    return b
end

-- ---------- EditBox ----------
function Skin:EditBox(parent, w, h)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetSize(w or 140, h or 22)
    self:SetBackdrop(e, C.bgRow, C.border)
    e:SetAutoFocus(false)
    e:SetTextInsets(6, 6, 0, 0)
    e:SetFont(self.FONT, 12, "")
    e:SetTextColor(unpack(C.text))
    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnEnterPressed",  e.ClearFocus)
    e:SetScript("OnEditFocusGained", function(s) s:SetBackdropBorderColor(unpack(C.accent)) end)
    e:SetScript("OnEditFocusLost",   function(s) s:SetBackdropBorderColor(unpack(C.border)) end)

    function e:Disable()
        self:EnableMouse(false); self:EnableKeyboard(false); self:ClearFocus()
        self:SetBackdropColor(0.05,0.05,0.07,0.9)
        self:SetTextColor(unpack(C.textDim))
        self.disabled = true
    end
    function e:Enable()
        self:EnableMouse(true); self:EnableKeyboard(true)
        self:SetBackdropColor(unpack(C.bgRow))
        self:SetTextColor(unpack(C.text))
        self.disabled = false
    end
    return e
end

-- ---------- CheckBox ----------
function Skin:CheckBox(parent, label)
    local cb = CreateFrame("Frame", nil, parent)
    cb:SetSize(180, 18)

    local box = CreateFrame("Button", nil, cb)
    box:SetSize(16, 16)
    box:SetPoint("LEFT", 0, 0)
    self:SetBackdrop(box, C.bgRow, C.border)

    local check = box:CreateTexture(nil, "OVERLAY")
    check:SetTexture(self.TEX_WHITE)
    check:SetVertexColor(unpack(C.accent))
    check:SetPoint("TOPLEFT", 3, -3)
    check:SetPoint("BOTTOMRIGHT", -3, 3)
    check:Hide()

    local fs = cb:CreateFontString(nil, "OVERLAY")
    self:Font(fs, 12, false)
    fs:SetTextColor(unpack(C.text))
    fs:SetPoint("LEFT", box, "RIGHT", 6, 0)
    fs:SetText(label or "")

    cb.box, cb.check, cb.text, cb.checked = box, check, fs, false
    function cb:GetChecked() return self.checked end
    function cb:SetChecked(v)
        self.checked = v and true or false
        if self.checked then self.check:Show() else self.check:Hide() end
        if self.OnValueChanged then self:OnValueChanged(self.checked) end
    end
    box:SetScript("OnClick", function() cb:SetChecked(not cb.checked) end)
    box:SetScript("OnEnter", function(s) s:SetBackdropBorderColor(unpack(C.accent)) end)
    box:SetScript("OnLeave", function(s) s:SetBackdropBorderColor(unpack(C.border)) end)
    return cb
end

-- ---------- Scroll list (simple virtual list) ----------
function Skin:ScrollList(parent, rowHeight, builder, updater)
    local f = CreateFrame("Frame", nil, parent)
    self:SetBackdrop(f, C.bgPanel, C.border)
    f.rowHeight = rowHeight or 20
    f.rows      = {}
    f.data      = {}
    f._builder  = builder
    f._updater  = updater

    local sb = CreateFrame("Slider", nil, f)
    sb:SetWidth(14); sb:SetOrientation("VERTICAL")
    sb:SetPoint("TOPRIGHT", -2, -2); sb:SetPoint("BOTTOMRIGHT", -2, 2)
    self:SetBackdrop(sb, C.bgRow, C.border)
    local thumb = sb:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(self.TEX_WHITE)
    thumb:SetVertexColor(unpack(C.accent))
    thumb:SetSize(10, 30)
    sb:SetThumbTexture(thumb)
    sb:SetMinMaxValues(0, 0)
    sb:SetValueStep(1); sb:SetValue(0)
    f.scroll = sb

    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(self, dir)
        local v = sb:GetValue() - dir * 2
        local lo, hi = sb:GetMinMaxValues()
        if v < lo then v = lo end
        if v > hi then v = hi end
        sb:SetValue(v)
    end)

    function f:Refresh()
        local h = self:GetHeight() - 4
        if h <= 0 then
            -- Frame not laid out yet; retry next frame.
            local retry = self._retryFrame or CreateFrame("Frame")
            self._retryFrame = retry
            retry:Show()
            retry:SetScript("OnUpdate", function(s)
                s:SetScript("OnUpdate", nil); s:Hide()
                if self:GetHeight() > 0 then self:Refresh() end
            end)
            return
        end
        local visible = math.max(1, math.floor(h / self.rowHeight))
        local needed  = math.min(visible, #self.data)
        for i = #self.rows + 1, needed do
            local r = self._builder(self)
            r:SetParent(self)
            r:SetHeight(self.rowHeight)
            r:SetPoint("LEFT", 4, 0)
            r:SetPoint("RIGHT", -18, 0)
            self.rows[i] = r
        end
        for i = 1, #self.rows do
            local r = self.rows[i]
            if i <= needed then
                r:Show()
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", 4, -2 - (i-1)*self.rowHeight)
                r:SetPoint("RIGHT", -18, 0)
            else r:Hide() end
        end
        local maxOff = math.max(0, #self.data - visible)
        self.scroll:SetMinMaxValues(0, maxOff)
        if self.scroll:GetValue() > maxOff then self.scroll:SetValue(maxOff) end
        self:Update()
    end
    function f:Update()
        local off = math.floor(self.scroll:GetValue() + 0.5)
        for i = 1, #self.rows do
            local r = self.rows[i]
            if r:IsShown() then
                local idx  = i + off
                local item = self.data[idx]
                self._updater(r, item, idx, idx % 2 == 0)
            end
        end
    end
    sb:SetScript("OnValueChanged", function() f:Update() end)
    f:SetScript("OnSizeChanged", function() f:Refresh() end)

    function f:SetData(data) self.data = data or {}; self:Refresh() end
    return f
end

-- ---------- Tooltip helper ----------
function Skin:AttachTooltip(widget, title, lines)
    widget:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
        if title then GameTooltip:AddLine(title, C.textHead[1], C.textHead[2], C.textHead[3]) end
        if lines then
            for _, ln in ipairs(lines) do
                GameTooltip:AddLine(ln, C.text[1], C.text[2], C.text[3], true)
            end
        end
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end
