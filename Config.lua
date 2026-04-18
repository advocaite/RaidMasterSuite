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

    local y = -50
    local function addCheck(label, path, tooltip)
        local cb = Skin:CheckBox(panel, label)
        cb:SetPoint("TOPLEFT", 16, y)
        cb:SetChecked(Config:Get(path))
        cb.OnValueChanged = function(_, v) Config:Set(path, v) end
        if tooltip then Skin:AttachTooltip(cb.box, label, {tooltip}) end
        y = y - 22
        return cb
    end

    local function addSection(text)
        y = y - 8
        local fs = panel:CreateFontString(nil, "OVERLAY")
        Skin:Font(fs, 13, true)
        fs:SetTextColor(unpack(C.accent))
        fs:SetPoint("TOPLEFT", 12, y)
        fs:SetText(text)
        y = y - 20
    end

    local function addNumber(label, path, w)
        local fs = panel:CreateFontString(nil, "OVERLAY")
        Skin:Font(fs, 12, false)
        fs:SetTextColor(unpack(C.text))
        fs:SetPoint("TOPLEFT", 16, y - 4)
        fs:SetText(label)

        local e = Skin:EditBox(panel, w or 80, 20)
        e:SetPoint("TOPLEFT", 220, y)
        e:SetNumeric(true)
        e:SetText(tostring(Config:Get(path) or 0))
        e:SetScript("OnEditFocusLost", function(s)
            local v = tonumber(s:GetText()) or 0
            Config:Set(path, v)
            s:SetText(tostring(v))
            s:SetBackdropBorderColor(unpack(C.border))
        end)
        y = y - 24
    end

    addSection("General")
    addCheck("Open window on login / reload", "ui.openOnLogin",
        "Automatically show the Raid Master Suite main window when you log in or reload.")
    addCheck("Enable debug logging", "debug", "Print verbose debug messages to chat.")

    addSection("Soft Res")
    addCheck("Auto-accept reservations", "softres.autoAccept", "Automatically accept incoming SR submissions when raid leader.")
    addCheck("One item per player",      "softres.oneItemPerPlayer")
    addCheck("Announce roll outcomes",   "softres.announceRolls")

    addSection("DKP")
    addNumber("Default bid increment", "dkp.defaultBidIncrement")
    addNumber("Minimum bid",           "dkp.minBid")
    addNumber("Bid timer (seconds)",   "dkp.bidTimer")
    addNumber("Weekly decay (%)",      "dkp.decayPercent")
    addNumber("Officer rank index (<=)", "dkp_officerRank")

    addSection("Gold Bid")
    addNumber("Minimum bid (gold)",    "goldbid.minBid")
    addNumber("Bid increment (gold)",  "goldbid.bidIncrement")
    addNumber("Bid timer (seconds)",   "goldbid.bidTimer")
    addCheck ("Auto-detect trade payment", "goldbid.autoTradeDetect",
        "Watch trade window for the winning bid amount and confirm award automatically.")

    return panel
end

-- module registration so Settings shows up in tab list
RMS:RegisterModule("settings", {
    title = "Settings",
    order = 99,
    BuildUI = function(self, parent) return Config:BuildPanel(parent) end,
})
