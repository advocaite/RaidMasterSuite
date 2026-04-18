-- Raid Master Suite -- Advertising
-- Compose and broadcast raid/dungeon recruitment ads to selected chat channels
-- (Trade, LookingForGroup, GeneralX, Custom). Auto-repeat at a configurable
-- interval. Persists settings between sessions.

local RMS = RaidMasterSuite
local M = RMS:RegisterModule("advertising", { title = "Advertise", order = 6 })

-- ---------- defaults ----------
local DEFAULTS = {
    raidName    = "ICC 25",
    runType     = "Gold Run",
    minGS       = 5800,
    achievement = "ICC10/25 exp preferred",
    discord     = "",
    notes       = "PST for invite",
    customMsg   = "",      -- if set, overrides the built message
    template    = "auto",  -- "auto" | "custom"
    interval    = 90,      -- seconds; min 30
    channels    = {},      -- [channelSlot] = true
    log         = {},
}

local RUN_TYPES = {
    "Gold Run", "DKP", "Soft Res", "Hard Res", "Loot Council", "Free Loot",
}

-- Common WOTLK PvE achievements raid leaders typically ask for. Grouped by tier.
local ACHIEVEMENT_LIST = {
    { tier = "Icecrown Citadel", entries = {
        { 4530, "Storming the Citadel (10)" },
        { 4604, "Storming the Citadel (25)" },
        { 4531, "The Plagueworks (10)" },
        { 4605, "The Plagueworks (25)" },
        { 4532, "The Crimson Hall (10)" },
        { 4606, "The Crimson Hall (25)" },
        { 4533, "The Frostwing Halls (10)" },
        { 4607, "The Frostwing Halls (25)" },
        { 4534, "Fall of the Lich King (10)" },
        { 4608, "Fall of the Lich King (25)" },
        { 4583, "Bane of the Fallen King (LK 10 HC)" },
        { 4584, "The Light of Dawn (LK 25 HC)" },
    }},
    { tier = "Ruby Sanctum", entries = {
        { 4818, "The Twilight Destroyer (10)" },
        { 4817, "The Twilight Destroyer (25)" },
    }},
    { tier = "Trial of the Crusader", entries = {
        { 3917, "Call of the Crusade (10)" },
        { 4076, "Call of the Crusade (25)" },
        { 3918, "Crusader (10)" },
        { 4077, "Crusader (25)" },
    }},
    { tier = "Ulduar", entries = {
        { 2958, "The Siege of Ulduar (10)" },
        { 2978, "The Siege of Ulduar (25)" },
        { 2961, "The Descent into Madness (10)" },
        { 2981, "The Descent into Madness (25)" },
    }},
    { tier = "Naxxramas / EoE", entries = {
        { 575,  "Heroic: The Construct Quarter" },
        { 580,  "The Spellweaver's Downfall (Malygos 25)" },
    }},
    { tier = "Onyxia (Lvl 80)", entries = {
        { 4404, "More Dots! (10)" },
        { 4405, "More Dots! (25)" },
    }},
}

local MIN_INTERVAL = 30

-- ---------- state ----------
M.cfg     = nil       -- bound to RMS.db.advertising in OnInit
M.running = false
M.lastSentAt = 0

function M:OnInit()
    RMS.db.advertising = RMS.db.advertising or {}
    for k, v in pairs(DEFAULTS) do
        if RMS.db.advertising[k] == nil then
            if type(v) == "table" then RMS.db.advertising[k] = {} else RMS.db.advertising[k] = v end
        end
    end
    self.cfg = RMS.db.advertising
end

-- ---------- channel discovery ----------
function M:GetAvailableChannels()
    local out = {}
    for slot = 1, 10 do  -- WoW user channels are 1..10
        local id, name = GetChannelName(slot)
        if id and id > 0 and name then
            out[#out+1] = { slot = slot, id = id, name = name }
        end
    end
    return out
end

-- ---------- message composition ----------
function M:BuildMessage()
    if self.cfg.template == "custom" and self.cfg.customMsg ~= "" then
        return self.cfg.customMsg
    end
    -- auto-build from fields, skipping empty ones
    local parts = {}
    if self.cfg.raidName  and self.cfg.raidName  ~= "" then parts[#parts+1] = "[" .. self.cfg.raidName .. "]" end
    if self.cfg.runType   and self.cfg.runType   ~= "" then parts[#parts+1] = "(" .. self.cfg.runType .. ")" end
    if self.cfg.minGS  and tonumber(self.cfg.minGS)  and tonumber(self.cfg.minGS) > 0
        then parts[#parts+1] = "GS " .. self.cfg.minGS .. "+" end
    if self.cfg.achievement and self.cfg.achievement ~= "" then parts[#parts+1] = self.cfg.achievement end
    if self.cfg.notes  and self.cfg.notes  ~= "" then parts[#parts+1] = self.cfg.notes end
    if self.cfg.discord and self.cfg.discord ~= "" then parts[#parts+1] = "Discord: " .. self.cfg.discord end
    if RMS.NAME then parts[#parts+1] = "(RMS addon for bidding)" end
    return table.concat(parts, " - ")
end

-- ---------- send ----------
function M:SelectedChannelSlots()
    local out = {}
    for slot, on in pairs(self.cfg.channels or {}) do
        if on then out[#out+1] = slot end
    end
    table.sort(out)
    return out
end

function M:SendOnce()
    local msg = self:BuildMessage()
    if not msg or msg == "" then RMS:Print("Empty message; aborting.") return end
    local slots = self:SelectedChannelSlots()
    if #slots == 0 then RMS:Print("No channels selected.") return end

    local sent = {}
    for _, slot in ipairs(slots) do
        local id, name = GetChannelName(slot)
        if id and id > 0 then
            SendChatMessage(msg, "CHANNEL", nil, slot)
            sent[#sent+1] = name or ("ch"..slot)
        end
    end

    if #sent > 0 then
        table.insert(self.cfg.log, 1, {
            time = time(), msg = msg,
            channels = table.concat(sent, ", "),
        })
        if #self.cfg.log > 50 then table.remove(self.cfg.log) end
        self.lastSentAt = GetTime()
    end
    self:Refresh()
end

-- ---------- auto-broadcast loop ----------
local ticker = CreateFrame("Frame")
ticker:Hide()
ticker:SetScript("OnUpdate", function()
    if not M.running then return end
    if (GetTime() - M.lastSentAt) >= M:Interval() then
        M:SendOnce()
    end
end)

function M:Interval()
    local v = tonumber(self.cfg.interval) or DEFAULTS.interval
    if v < MIN_INTERVAL then v = MIN_INTERVAL end
    return v
end

function M:Start()
    if self:SelectedChannelSlots()[1] == nil then RMS:Print("Pick at least one channel first.") return end
    self.running = true
    self.lastSentAt = 0  -- send first one immediately
    ticker:Show()
    RMS:Print("Advertising STARTED. Interval %ds.", self:Interval())
    self:Refresh()
end

function M:Stop()
    self.running = false
    ticker:Hide()
    RMS:Print("Advertising STOPPED.")
    self:Refresh()
end

-- ---------- achievement list (built at runtime from the game's DB) ----------
-- Walks every category that descends from "Dungeons & Raids" and pulls all
-- achievements. Falls back to the hand-curated ACHIEVEMENT_LIST above if the
-- game APIs aren't ready or no categories matched.
local function _buildAchievementListFromGame()
    if not GetCategoryList or not GetCategoryInfo
       or not GetCategoryNumAchievements or not GetAchievementInfo then
        return nil
    end
    local categories = GetCategoryList()
    if not categories or #categories == 0 then return nil end

    -- Find the "Dungeons & Raids" root by name.
    local drRoot
    for _, cid in ipairs(categories) do
        local name = GetCategoryInfo(cid)
        if name and name:find("Dungeons") and name:find("Raids") then
            drRoot = cid; break
        end
    end
    if not drRoot then return nil end

    local function descendsFrom(cid, target)
        local guard, cur = 0, cid
        while cur and guard < 10 do
            if cur == target then return true end
            local _, parent = GetCategoryInfo(cur)
            if not parent or parent == -1 or parent == cur then return false end
            cur, guard = parent, guard + 1
        end
        return false
    end

    local groups = {}
    for _, cid in ipairs(categories) do
        if cid ~= drRoot and descendsFrom(cid, drRoot) then
            local name = GetCategoryInfo(cid)
            local count = GetCategoryNumAchievements(cid) or 0
            local entries = {}
            for i = 1, count do
                local id, ach_name = GetAchievementInfo(cid, i)
                if id and ach_name then entries[#entries+1] = { id, ach_name } end
            end
            if #entries > 0 and name then
                groups[#groups+1] = { tier = name, entries = entries }
            end
        end
    end
    if #groups == 0 then return nil end
    -- Stable order: by tier name
    table.sort(groups, function(a, b) return a.tier < b.tier end)
    return groups
end

local function _getAchievementList()
    if M._achListCache then return M._achListCache end
    local list = _buildAchievementListFromGame()
    if not list or #list == 0 then list = ACHIEVEMENT_LIST end
    M._achListCache = list
    return list
end

-- ---------- achievement picker popup ----------
function M:_ShowAchievementPicker(targetEdit)
    local Skin = RMS.Skin
    local C    = Skin.COLOR

    if self._achPopup and self._achPopup:IsShown() then
        self._achPopup:Hide(); return
    end

    local f = self._achPopup
    if not f then
        f = CreateFrame("Frame", "RaidMasterSuiteAchPicker", UIParent)
        f:SetSize(380, 460); f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:EnableMouse(true); f:SetMovable(true); f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop",  f.StopMovingOrSizing)
        Skin:SetBackdrop(f, C.bgMain, C.accent)
        tinsert(UISpecialFrames, "RaidMasterSuiteAchPicker")
        f:Hide()

        local title = f:CreateFontString(nil, "OVERLAY"); Skin:Font(title, 14, true)
        title:SetTextColor(unpack(C.accent))
        title:SetPoint("TOP", 0, -8); title:SetText("ACHIEVEMENT PICKER")

        local close = Skin:CloseButton(f); close:SetPoint("TOPRIGHT", -4, -4)
        close:SetScript("OnClick", function() f:Hide() end)

        -- search edit
        local search = Skin:EditBox(f, 1, 22)
        search:SetPoint("TOPLEFT", 8, -32); search:SetPoint("RIGHT", -8, 0)
        f.search = search

        local hint = f:CreateFontString(nil, "OVERLAY"); Skin:Font(hint, 9, false)
        hint:SetTextColor(unpack(C.textDim))
        hint:SetPoint("BOTTOMLEFT", search, "TOPLEFT", 2, 1)
        hint:SetText("Filter (type to narrow):")

        -- list
        local function buildRow(parent)
            local r = CreateFrame("Frame", nil, parent)
            r:SetHeight(20)
            local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
            local fs = r:CreateFontString(nil, "OVERLAY"); Skin:Font(fs, 11, false)
            fs:SetPoint("LEFT", 6, 0); fs:SetPoint("RIGHT", -56, 0)
            fs:SetJustifyH("LEFT"); fs:SetWordWrap(false); fs:SetNonSpaceWrap(false)
            r.fs = fs
            local btn = Skin:Button(r, "Insert", 50, 18)
            btn:SetPoint("RIGHT", -3, 0)
            r.btn = btn
            return r
        end
        local function updRow(r, item, idx, alt)
            if not item then return end
            r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.5)
            if item.section then
                r.fs:SetText(("|cffffd070-- %s --|r"):format(item.section))
                r.btn:Hide()
            else
                local link = item.id and GetAchievementLink and GetAchievementLink(item.id)
                r.fs:SetText(link or item.name or "?")
                r.btn:Show()
                r.btn:SetScript("OnMouseUp", function()
                    local lk = item.id and GetAchievementLink and GetAchievementLink(item.id)
                    if lk and M._achEdit then
                        if M._achEdit:GetText() ~= "" then M._achEdit:Insert(" ") end
                        M._achEdit:Insert(lk)
                        M:_RefreshPreview()
                    end
                end)
            end
        end
        local list = Skin:ScrollList(f, 22, buildRow, updRow)
        list:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -6)
        list:SetPoint("BOTTOMRIGHT", -8, 8)
        f.list = list

        local function rebuild(query)
            query = (query or ""):lower()
            local data = {}
            for _, group in ipairs(_getAchievementList()) do
                local kept = {}
                for _, e in ipairs(group.entries) do
                    if query == "" or (e[2] and e[2]:lower():find(query, 1, true)) then
                        kept[#kept+1] = { id = e[1], name = e[2] }
                    end
                end
                if #kept > 0 then
                    data[#data+1] = { section = group.tier }
                    for _, k in ipairs(kept) do data[#data+1] = k end
                end
            end
            list:SetData(data)
        end
        f._rebuild = rebuild
        search:SetScript("OnTextChanged", function(s) rebuild(s:GetText() or "") end)

        self._achPopup = f
    end

    f.search:SetText("")
    f._rebuild("")
    f:Show()
end

-- ---------- slash ----------
function M:OnSlash(arg)
    arg = (arg or ""):lower()
    if arg == "start" then return self:Start() end
    if arg == "stop"  then return self:Stop()  end
    if arg == "send"  then return self:SendOnce() end
    RMS.UI:Show("advertising")
end

-- =============================================================================
-- UI
-- =============================================================================

function M:BuildUI(parent)
    local Skin = RMS.Skin
    local C    = Skin.COLOR
    local panel = CreateFrame("Frame", nil, parent)

    local header = Skin:Header(panel, "Advertising")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)

    local status = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(status, 12, true)
    status:SetPoint("RIGHT", header, "RIGHT", -10, 0)

    -- ============ left column: form ============
    local FORM_W = 360
    local formHdr = Skin:Header(panel, "Message Builder")
    formHdr:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -8)
    formHdr:SetWidth(FORM_W)

    local formBody = Skin:Panel(panel)
    formBody:SetPoint("TOPLEFT", formHdr, "BOTTOMLEFT", 0, -2)
    formBody:SetWidth(FORM_W)
    formBody:SetHeight(360)

    -- field with width controlled by anchors (always fills form)
    local function field(label, anchor, kind)
        local lbl = formBody:CreateFontString(nil, "OVERLAY"); Skin:Font(lbl, 10, false)
        lbl:SetTextColor(unpack(C.textDim))
        if anchor then lbl:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
        else           lbl:SetPoint("TOPLEFT", 8, -8) end
        lbl:SetWidth(80); lbl:SetText(label)
        local input = Skin:EditBox(formBody, 100, 22)
        input:SetPoint("LEFT",  lbl, "RIGHT", 4, 0)
        if kind == "number" then
            input:SetNumeric(true); input:SetWidth(60)
        else
            input:SetPoint("RIGHT", formBody, "RIGHT", -8, 0)
        end
        return lbl, input
    end

    local raidLbl, raidEdit = field("Raid Name:")

    -- run-type cycler button
    local typeLbl, typeBtn
    do
        local lbl = formBody:CreateFontString(nil, "OVERLAY"); Skin:Font(lbl, 10, false)
        lbl:SetTextColor(unpack(C.textDim))
        lbl:SetPoint("TOPLEFT", raidLbl, "BOTTOMLEFT", 0, -10); lbl:SetWidth(80); lbl:SetText("Run Type:")
        local b = Skin:Button(formBody, "Gold Run", 100, 22)
        b:SetPoint("LEFT", lbl, "RIGHT", 4, 0)
        b:SetPoint("RIGHT", formBody, "RIGHT", -8, 0)
        b:SetScript("OnMouseUp", function()
            local cur = self.cfg.runType
            local idx = 1
            for i, n in ipairs(RUN_TYPES) do if n == cur then idx = i break end end
            self.cfg.runType = RUN_TYPES[(idx % #RUN_TYPES) + 1]
            b:SetText(self.cfg.runType); self:_RefreshPreview()
        end)
        typeLbl, typeBtn = lbl, b
    end

    local gsLbl,    gsEdit    = field("Min GS:",     typeLbl, "number")
    local dscLbl,   dscEdit   = field("Discord:",    gsLbl)
    local notesLbl, notesEdit = field("Notes:",      dscLbl)

    -- Achievement: multi-line area with paste support
    local achLbl = formBody:CreateFontString(nil, "OVERLAY"); Skin:Font(achLbl, 10, false)
    achLbl:SetTextColor(unpack(C.textDim))
    achLbl:SetPoint("TOPLEFT", notesLbl, "BOTTOMLEFT", 0, -10); achLbl:SetWidth(80); achLbl:SetText("Achievement:")
    local achHint = formBody:CreateFontString(nil, "OVERLAY"); Skin:Font(achHint, 9, false)
    achHint:SetTextColor(unpack(C.textDim))
    achHint:SetPoint("TOPLEFT", achLbl, "TOPLEFT", 90, 0); achHint:SetPoint("RIGHT", formBody, "RIGHT", -8, 0)
    achHint:SetJustifyH("LEFT"); achHint:SetText("(shift-click achievements to insert)")

    local achEdit = Skin:EditBox(formBody, 100, 60)
    achEdit:SetPoint("TOPLEFT", achLbl, "BOTTOMLEFT", 8, -4)
    achEdit:SetPoint("RIGHT", formBody, "RIGHT", -34, 0)  -- leave room for Pick button
    achEdit:SetMultiLine(true); achEdit:SetAutoFocus(false)
    achEdit:SetMaxLetters(0)
    achEdit:SetTextInsets(6, 6, 4, 4)

    -- Pick button opens a curated achievement popup
    local pickBtn = Skin:Button(formBody, "Pick", 30, 22)
    pickBtn:SetPoint("TOPLEFT", achEdit, "TOPRIGHT", 4, 0)
    pickBtn:SetScript("OnMouseUp", function() M:_ShowAchievementPicker(achEdit) end)

    self._achEdit = achEdit  -- expose for global shift-click hook below

    -- Shift-click links from any source (achievement frame, character pane,
    -- quest log, etc.) when our edit has focus. ChatEdit_InsertLink only
    -- fires when chat is active, so we hook the lower-level entry point too.
    if not RMS._advClickHooked then
        RMS._advClickHooked = true
        hooksecurefunc("ChatEdit_InsertLink", function(text)
            local e = M._achEdit
            if e and e:IsVisible() and e:HasFocus() then e:Insert(text); return true end
        end)
        hooksecurefunc("HandleModifiedItemClick", function(link)
            if not link or not IsShiftKeyDown() then return end
            local e = M._achEdit
            if e and e:IsVisible() and e:HasFocus() then e:Insert(link) end
        end)
    end

    -- preview (anchor BOTTOMRIGHT so wrap actually wraps)
    local prevHdr = formBody:CreateFontString(nil, "OVERLAY"); Skin:Font(prevHdr, 10, true)
    prevHdr:SetTextColor(unpack(C.accent))
    prevHdr:SetPoint("TOPLEFT", achEdit, "BOTTOMLEFT", -8, -10)
    prevHdr:SetText("Preview:")

    local prev = formBody:CreateFontString(nil, "OVERLAY"); Skin:Font(prev, 11, false)
    prev:SetTextColor(unpack(C.text))
    prev:SetPoint("TOPLEFT", prevHdr, "BOTTOMLEFT", 0, -2)
    prev:SetPoint("BOTTOMRIGHT", formBody, "BOTTOMRIGHT", -8, 8)
    prev:SetJustifyH("LEFT"); prev:SetJustifyV("TOP")
    prev:SetWordWrap(true); prev:SetNonSpaceWrap(true)

    -- wire inputs
    local function bindEdit(edit, key, isNumber)
        edit:SetText(tostring(self.cfg[key] or ""))
        edit:SetScript("OnTextChanged", function(s)
            local v = s:GetText() or ""
            if isNumber then v = tonumber(v) or 0 end
            self.cfg[key] = v
            self:_RefreshPreview()
        end)
    end
    bindEdit(raidEdit,  "raidName")
    bindEdit(gsEdit,    "minGS",    true)
    bindEdit(achEdit,   "achievement")
    bindEdit(dscEdit,   "discord")
    bindEdit(notesEdit, "notes")
    typeBtn:SetText(self.cfg.runType or "Gold Run")

    -- ============ right column: channels + controls ============
    local chHdr = Skin:Header(panel, "Channels")
    chHdr:SetPoint("TOPLEFT", formHdr, "TOPRIGHT", 8, 0)
    chHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    local chBody = Skin:Panel(panel)
    chBody:SetPoint("TOPLEFT", chHdr, "BOTTOMLEFT", 0, -2)
    chBody:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    chBody:SetHeight(190)

    self._chRows = {}

    -- manual add row at bottom of chBody
    local addEdit = Skin:EditBox(chBody, 100, 20)
    addEdit:SetPoint("BOTTOMLEFT", 8, 8)
    addEdit:SetPoint("RIGHT", chBody, "RIGHT", -130, 0)

    local addHint = chBody:CreateFontString(nil, "OVERLAY"); Skin:Font(addHint, 9, false)
    addHint:SetTextColor(unpack(C.textDim))
    addHint:SetPoint("BOTTOMLEFT", addEdit, "TOPLEFT", 2, 2)
    addHint:SetText("Manual add (channel name):")

    local joinBtn = Skin:Button(chBody, "Join", 50, 20)
    joinBtn:SetPoint("LEFT", addEdit, "RIGHT", 4, 0)
    joinBtn:SetScript("OnMouseUp", function()
        local name = (addEdit:GetText() or ""):gsub("^%s+",""):gsub("%s+$","")
        if name == "" then return end
        if JoinChannelByName then JoinChannelByName(name) end
        addEdit:SetText("")
        -- short delay so the channel appears in GetChannelName
        local f = CreateFrame("Frame"); local t = 0
        f:SetScript("OnUpdate", function(s, dt)
            t = t + dt
            if t > 0.6 then s:SetScript("OnUpdate", nil); self:Refresh() end
        end)
    end)

    local refreshChans = Skin:Button(chBody, "Refresh", 60, 20)
    refreshChans:SetPoint("LEFT", joinBtn, "RIGHT", 4, 0)
    refreshChans:SetScript("OnMouseUp", function() self:Refresh() end)

    -- save the bottom of the channel-list area so checkbox rows don't overlap inputs
    self._chListBottom = addHint  -- checkbox rows stop above this

    -- interval + buttons under channels
    local ctrlHdr = Skin:Header(panel, "Broadcast")
    ctrlHdr:SetPoint("TOPLEFT", chBody, "BOTTOMLEFT", 0, -8)
    ctrlHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    local ctrlBody = Skin:Panel(panel)
    ctrlBody:SetPoint("TOPLEFT", ctrlHdr, "BOTTOMLEFT", 0, -2)
    ctrlBody:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    ctrlBody:SetHeight(80)

    local intLbl = ctrlBody:CreateFontString(nil, "OVERLAY"); Skin:Font(intLbl, 10, false)
    intLbl:SetTextColor(unpack(C.textDim))
    intLbl:SetPoint("TOPLEFT", 8, -8); intLbl:SetText("Interval (sec, min "..MIN_INTERVAL.."):")
    intLbl:SetWidth(160)
    local intEdit = Skin:EditBox(ctrlBody, 50, 20)
    intEdit:SetPoint("LEFT", intLbl, "RIGHT", 4, 0); intEdit:SetNumeric(true)
    intEdit:SetText(tostring(self.cfg.interval or 90))
    intEdit:SetScript("OnEditFocusLost", function(s)
        local v = tonumber(s:GetText()) or 90
        if v < MIN_INTERVAL then v = MIN_INTERVAL end
        self.cfg.interval = v; s:SetText(tostring(v))
    end)

    -- broadcast buttons (compact so they fit in the narrow right column)
    local sendBtn = Skin:Button(ctrlBody, "Send Now", 70, 22)
    sendBtn:SetPoint("BOTTOMLEFT", 8, 8)
    sendBtn:SetScript("OnMouseUp", function() self:SendOnce() end)

    local startBtn = Skin:Button(ctrlBody, "Start", 60, 22)
    startBtn:SetPoint("LEFT", sendBtn, "RIGHT", 4, 0)
    startBtn:SetScript("OnMouseUp", function() self:Start() end)

    local stopBtn = Skin:Button(ctrlBody, "Stop", 50, 22)
    stopBtn:SetPoint("LEFT", startBtn, "RIGHT", 4, 0)
    stopBtn:SetScript("OnMouseUp", function() self:Stop() end)

    -- ============ log (bottom, full width) ============
    local logHdr = Skin:Header(panel, "Recent Broadcasts")
    logHdr:SetPoint("TOPLEFT", formBody, "BOTTOMLEFT", 0, -8)
    logHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

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
        r.fs:SetText(("|cff999999%s|r |cffffd070[%s]|r %s"):format(
            date("%H:%M:%S", item.time or 0), item.channels or "?", item.msg or ""))
    end
    local logScroll = Skin:ScrollList(panel, 18, buildLogRow, updateLogRow)
    logScroll:SetPoint("TOPLEFT", logHdr, "BOTTOMLEFT", 0, -2)
    logScroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 8)

    self._ui = {
        panel = panel, status = status,
        prev = prev,
        chBody = chBody,
        intEdit = intEdit,
        sendBtn = sendBtn, startBtn = startBtn, stopBtn = stopBtn,
        logScroll = logScroll,
        raidEdit = raidEdit, gsEdit = gsEdit, achEdit = achEdit, dscEdit = dscEdit,
        notesEdit = notesEdit, typeBtn = typeBtn,
    }
    self:Refresh()
    return panel
end

function M:_RefreshPreview()
    if not self._ui then return end
    self._ui.prev:SetText(self:BuildMessage())
end

function M:Refresh()
    if not self._ui then return end
    local Skin = RMS.Skin
    local C    = Skin.COLOR

    -- status
    if self.running then
        self._ui.status:SetText("|cff60ff60RUNNING|r ("..self:Interval().."s)")
    else
        self._ui.status:SetText("|cffaaaaaaSTOPPED|r")
    end

    -- preview
    self:_RefreshPreview()

    -- channels: rebuild row buttons
    local channels = self:GetAvailableChannels()
    -- create more rows if needed
    for i = #self._chRows + 1, #channels do
        local cb = Skin:CheckBox(self._ui.chBody, "")
        cb:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 22)
        self._chRows[i] = cb
    end
    -- populate / show / hide
    for i, row in ipairs(self._chRows) do
        local ch = channels[i]
        if ch then
            row:Show()
            row.text:SetText(("|cffffd070%d.|r %s"):format(ch.slot, ch.name))
            row:SetChecked(self.cfg.channels[ch.slot] == true)
            row.OnValueChanged = function(_, v)
                self.cfg.channels[ch.slot] = v and true or nil
            end
        else
            row:Hide()
        end
    end
    if #channels == 0 then
        if not self._ui._noChMsg then
            local fs = self._ui.chBody:CreateFontString(nil, "OVERLAY")
            Skin:Font(fs, 10, false)
            fs:SetTextColor(unpack(C.textDim))
            fs:SetPoint("TOPLEFT", 8, -8)
            fs:SetText("No chat channels detected. Join one (e.g. /join Trade) and click Refresh.")
            fs:SetWidth(300); fs:SetWordWrap(true)
            self._ui._noChMsg = fs
        end
        self._ui._noChMsg:Show()
    elseif self._ui._noChMsg then
        self._ui._noChMsg:Hide()
    end

    -- interval display
    self._ui.intEdit:SetText(tostring(self.cfg.interval or 90))

    -- log
    self._ui.logScroll:SetData(self.cfg.log or {})
end
