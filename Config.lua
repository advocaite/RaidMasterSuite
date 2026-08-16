-- Raid Master Suite -- Config
-- SavedVariables defaults + Settings tab UI builder.

local RMS = RaidMasterSuite
local Config = {}
RMS.Config = Config

Config.DEFAULTS = {
    debug = false,
    minimap = { hide = false, angle = 215 },
    softres = {
        autoAccept    = true,
        oneItemPerPlayer = false,  -- multi-item per player by default; toggle on to enforce one
        announceRolls = true,
    },
    hardres = {
        autoAccept = true,
    },
    dkp = {
        defaultBidIncrement = 100,
        minBid = 0,
        bidTimer = 30,
        decayPercent = 10,
    },
    dkp_officerRank = 2,    -- guild rank index <= this counts as officer for DKP writes
    goldbid = {
        minBid       = 100,
        bidIncrement = 100,
        bidTimer     = 30,
        autoTradeDetect = true,
    },
    bis = {
        useStatWeights = false,
        -- phase: nil = newest available; set via the BiS tab phase buttons
    },
    plusone = {
        autoRollWins = true,   -- auto +1 on group-loot / SR roll wins
        announce     = false,  -- post +1 changes to raid chat
        minQuality   = 4,      -- Epic; wins below this don't count
    },
    masterloot = {
        autoOpen         = true,   -- pop window on LOOT_OPENED when ML
        useLootThreshold = true,   -- filter by the group's loot threshold
        minQuality       = 4,      -- fixed filter when useLootThreshold is off
        announceAwards   = true,
        announceRolls    = true,
        autoPlusOne      = true,   -- mark +1 when handing out an item
        rollTime         = 8,      -- seconds Call Roll collects /rolls
        countdown        = true,   -- announce 5..1 as the window closes
    },
    ui = {
        scale       = 1.0,
        locked      = false,
        openOnLogin = false,  -- auto-show main window on login / reload
    },
}

local function deepMerge(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then target[k] = {} end
            deepMerge(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
end

function Config:ApplyDefaults()
    deepMerge(RMS.db, self.DEFAULTS)
end

function Config:Get(path)
    local node = RMS.db
    for seg in tostring(path):gmatch("[^.]+") do
        if type(node) ~= "table" then return nil end
        node = node[seg]
    end
    return node
end

function Config:Set(path, value)
    local node = RMS.db
    local segs = {}
    for seg in tostring(path):gmatch("[^.]+") do segs[#segs+1] = seg end
    for i = 1, #segs - 1 do
        if type(node[segs[i]]) ~= "table" then node[segs[i]] = {} end
        node = node[segs[i]]
    end
    node[segs[#segs]] = value
end

-- ---------- Settings tab builder ----------
function Config:BuildPanel(parent)
    local Skin = RMS.Skin
    local C = Skin.COLOR

    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local header = Skin:Header(panel, "Settings")
    header:SetPoint("TOPLEFT", 8, -8)
    header:SetPoint("TOPRIGHT", -8, -8)

    -- Bug-report / feature-request banner under the header
    local issueLbl = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(issueLbl, 11, false)
    issueLbl:SetTextColor(unpack(C.text))
    issueLbl:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  4, -6)
    issueLbl:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -4, -6)
    issueLbl:SetHeight(16); issueLbl:SetJustifyH("LEFT")
    issueLbl:SetText("Found a bug or want a feature? |cffffd070Open an issue on GitHub:|r")

    local issueUrl = Skin:EditBox(panel, 1, 22)
    issueUrl:SetPoint("TOPLEFT",  issueLbl, "BOTTOMLEFT",  0, -2)
    issueUrl:SetPoint("TOPRIGHT", issueLbl, "BOTTOMRIGHT", 0, -2)
    local URL = "https://github.com/advocaite/RaidMasterSuite/issues"
    issueUrl:SetText(URL)
    issueUrl:SetTextColor(unpack(C.accent))
    issueUrl:SetCursorPosition(0)
    issueUrl:SetScript("OnMouseUp",         function(s) s:HighlightText() end)
    issueUrl:SetScript("OnEditFocusGained", function(s) s:HighlightText() end)
    issueUrl:SetScript("OnTextChanged",     function(s)
        if s:GetText() ~= URL then s:SetText(URL); s:HighlightText() end
    end)

    -- two columns; each col table tracks its own cursor
    local col1 = { x = 16,  y = -90 }
    local col2 = { x = 380, y = -90 }
    -- widgets re-read their config value whenever the tab is shown, so
    -- changes made from the module tabs stay in sync
    local refreshers = {}

    local function addCheck(col, label, path, tooltip)
        local cb = Skin:CheckBox(panel, label)
        cb:SetPoint("TOPLEFT", col.x, col.y)
        cb:SetChecked(Config:Get(path))
        cb.OnValueChanged = function(_, v) Config:Set(path, v) end
        if tooltip then Skin:AttachTooltip(cb.box, label, {tooltip}) end
        refreshers[#refreshers+1] = function() cb:SetChecked(Config:Get(path)) end
        col.y = col.y - 22
        return cb
    end

    local function addSection(col, text)
        col.y = col.y - 8
        local fs = panel:CreateFontString(nil, "OVERLAY")
        Skin:Font(fs, 13, true)
        fs:SetTextColor(unpack(C.accent))
        fs:SetPoint("TOPLEFT", col.x - 4, col.y)
        fs:SetText(text)
        col.y = col.y - 20
    end

    local function addNumber(col, label, path, w)
        local fs = panel:CreateFontString(nil, "OVERLAY")
        Skin:Font(fs, 12, false)
        fs:SetTextColor(unpack(C.text))
        fs:SetPoint("TOPLEFT", col.x, col.y - 4)
        fs:SetText(label)

        local e = Skin:EditBox(panel, w or 80, 20)
        e:SetPoint("TOPLEFT", col.x + 204, col.y)
        e:SetNumeric(true)
        e:SetText(tostring(Config:Get(path) or 0))
        e:SetScript("OnEditFocusLost", function(s)
            local v = tonumber(s:GetText()) or 0
            Config:Set(path, v)
            s:SetText(tostring(v))
            s:SetBackdropBorderColor(unpack(C.border))
        end)
        refreshers[#refreshers+1] = function()
            if not e:HasFocus() then e:SetText(tostring(Config:Get(path) or 0)) end
        end
        col.y = col.y - 24
    end

    addSection(col1, "General")
    addCheck(col1, "Open window on login / reload", "ui.openOnLogin",
        "Automatically show the Raid Master Suite main window when you log in or reload.")
    addCheck(col1, "Enable debug logging", "debug", "Print verbose debug messages to chat.")
    local hideMm = addCheck(col1, "Hide minimap button", "minimap.hide",
        "Remove the round Raid Master Suite button from the minimap edge.")
    local hideMmOrig = hideMm.OnValueChanged
    hideMm.OnValueChanged = function(s, v)
        hideMmOrig(s, v)
        if RMS.MinimapButton then RMS.MinimapButton:UpdateShown() end
    end

    addSection(col1, "Soft Res")
    addCheck(col1, "Auto-accept reservations", "softres.autoAccept", "Automatically accept incoming SR submissions when raid leader.")
    addCheck(col1, "One item per player",      "softres.oneItemPerPlayer")
    addCheck(col1, "Announce roll outcomes",   "softres.announceRolls")

    addSection(col1, "DKP")
    addNumber(col1, "Default bid increment", "dkp.defaultBidIncrement")
    addNumber(col1, "Minimum bid",           "dkp.minBid")
    addNumber(col1, "Bid timer (seconds)",   "dkp.bidTimer")
    addNumber(col1, "Weekly decay (%)",      "dkp.decayPercent")
    addNumber(col1, "Officer rank index (<=)", "dkp_officerRank")

    addSection(col1, "Gold Bid")
    addNumber(col1, "Minimum bid (gold)",    "goldbid.minBid")
    addNumber(col1, "Bid increment (gold)",  "goldbid.bidIncrement")
    addNumber(col1, "Bid timer (seconds)",   "goldbid.bidTimer")
    addCheck (col1, "Auto-detect trade payment", "goldbid.autoTradeDetect",
        "Watch trade window for the winning bid amount and confirm award automatically.")

    addSection(col2, "+1 Loot")
    addCheck(col2, "Auto +1 on roll wins", "plusone.autoRollWins",
        "Automatically mark +1 when someone wins a group-loot roll or a Soft Res roll session.")
    addCheck(col2, "Announce +1 changes", "plusone.announce",
        "Post +1 updates to raid chat (leader/assist only).")
    addNumber(col2, "Min quality (2-5)", "plusone.minQuality")

    addSection(col2, "Master Loot")
    addCheck(col2, "Auto-open window when ML", "masterloot.autoOpen",
        "Pop the loot window automatically when you open a corpse as master looter.")
    addCheck(col2, "Use dungeon loot threshold", "masterloot.useLootThreshold",
        "Only list items at or above the group's loot threshold. Untick to use the fixed quality below.")
    addCheck(col2, "Announce awards", "masterloot.announceAwards")
    addCheck(col2, "Announce roll winners", "masterloot.announceRolls")
    addCheck(col2, "Auto +1 on award", "masterloot.autoPlusOne",
        "Mark the receiving player +1 when you hand out an item.")
    addCheck(col2, "Countdown last 5 seconds", "masterloot.countdown",
        "Announce 5... 4... 3... 2... 1... in raid chat as the roll window closes.")
    addNumber(col2, "Roll timer (seconds)", "masterloot.rollTime")
    addNumber(col2, "Fixed min quality (2-5)", "masterloot.minQuality")

    panel:SetScript("OnShow", function()
        for _, fn in ipairs(refreshers) do fn() end
    end)

    return panel
end

-- module registration so Settings shows up in tab list
RMS:RegisterModule("settings", {
    title = "Settings",
    order = 99,
    BuildUI = function(self, parent) return Config:BuildPanel(parent) end,
})
