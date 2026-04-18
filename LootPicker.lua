-- Raid Master Suite -- Loot Picker
-- Reusable popup: pick expansion -> instance -> boss -> item.
-- Used by Soft Res, Hard Res, and any module that needs to choose an item.
-- Open with: RMS.LootPicker:Open({ title = "Reserve", onPick = function(link, id, name, q) ... end })

local RMS = RaidMasterSuite
local LP  = {}
RMS.LootPicker = LP

local EXPANSIONS = { "WOTLK", "TBC", "Classic", "Crafting", "Events" }

-- Build an 8-char AARRGGBB hex from r,g,b (3.3.5a often has empty/short c.hex).
local QHEX_FALLBACK = {
    [0] = "ff9d9d9d", [1] = "ffffffff", [2] = "ff1eff00",
    [3] = "ff0070dd", [4] = "ffa335ee", [5] = "ffff8000",
}
local function qcolor(q)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c and c.r then
        return ("ff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255)
    end
    return QHEX_FALLBACK[q] or QHEX_FALLBACK[1]
end

local function makeLink(id, q, name)
    return ("|c%s|Hitem:%d:0:0:0:0:0:0:0|h[%s]|h|r"):format(qcolor(q), id, name)
end

local function instancesIn(exp)
    local db = RMS.LootDB and RMS.LootDB[exp] or {}
    local list = {}
    for k in pairs(db) do list[#list+1] = k end
    table.sort(list)
    return list
end

local function bossesIn(exp, inst)
    local db = RMS.LootDB and RMS.LootDB[exp] and RMS.LootDB[exp][inst] or {}
    local list = {}
    for k in pairs(db) do list[#list+1] = k end
    table.sort(list)
    return list
end

local function itemsIn(exp, inst, boss)
    local db = RMS.LootDB and RMS.LootDB[exp] and RMS.LootDB[exp][inst] and RMS.LootDB[exp][inst][boss] or {}
    return db
end

-- ---------- search across all expansions ----------
local function searchItems(query)
    query = (query or ""):lower()
    if #query < 2 then return {} end
    local results = {}
    if not RMS.LootDB then return results end
    for exp, instances in pairs(RMS.LootDB) do
        for inst, bosses in pairs(instances) do
            for boss, items in pairs(bosses) do
                for _, it in ipairs(items) do
                    if it[3]:lower():find(query, 1, true) then
                        results[#results+1] = { id = it[1], q = it[2], name = it[3],
                                                exp = exp, inst = inst, boss = boss }
                        if #results >= 200 then return results end
                    end
                end
            end
        end
    end
    return results
end

-- ---------- build window ----------
function LP:Build()
    if self.win then return self.win end
    local Skin = RMS.Skin
    local C    = Skin.COLOR

    local f = CreateFrame("Frame", "RaidMasterSuiteLootPicker", UIParent)
    f:SetSize(800, 520)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true); f:SetMovable(true); f:SetClampedToScreen(true)
    Skin:SetBackdrop(f, C.bgMain, C.borderHi)
    f:Hide()
    self.win = f

    -- title bar
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
    titleFs:SetText("LOOT PICKER")
    f.titleFs = titleFs

    local close = Skin:CloseButton(title)
    close:SetPoint("RIGHT", -6, 0)
    close:SetScript("OnClick", function() f:Hide() end)

    -- search box
    local searchEdit = Skin:EditBox(title, 220, 22)
    searchEdit:SetPoint("RIGHT", close, "LEFT", -8, 0)
    f.searchEdit       = searchEdit
    self.searchEdit    = searchEdit  -- mirror onto module for OnClick/Refresh access
    local searchHint = title:CreateFontString(nil, "OVERLAY")
    Skin:Font(searchHint, 10, false)
    searchHint:SetTextColor(unpack(C.textDim))
    searchHint:SetPoint("RIGHT", searchEdit, "LEFT", -6, 0)
    searchHint:SetText("Search:")

    -- expansion tabs
    self.tabs = {}
    local prev
    for i, e in ipairs(EXPANSIONS) do
        local b = Skin:TabButton(f, e, 95, 26)
        if i == 1 then b:SetPoint("TOPLEFT", 8, -36)
        else b:SetPoint("LEFT", prev, "RIGHT", 4, 0) end
        b:SetScript("OnClick", function()
            self.expansion = e
            self.instance  = nil
            self.boss      = nil
            self.searchEdit:SetText("")
            self.searchActive = false
            self:Refresh()
        end)
        prev = b
        self.tabs[e] = b
    end

    -- column panels (use TOPLEFT + BOTTOMLEFT + width for clean anchoring)
    local instCol = Skin:Panel(f); instCol:SetWidth(200)
    instCol:SetPoint("TOPLEFT",    f, "TOPLEFT",    8, -68)
    instCol:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8,   8)
    f.instCol = instCol

    local bossCol = Skin:Panel(f); bossCol:SetWidth(200)
    bossCol:SetPoint("TOPLEFT",    instCol, "TOPRIGHT",    6, 0)
    bossCol:SetPoint("BOTTOMLEFT", instCol, "BOTTOMRIGHT", 6, 0)
    f.bossCol = bossCol

    local itemCol = Skin:Panel(f)
    itemCol:SetPoint("TOPLEFT",     bossCol, "TOPRIGHT", 6, 0)
    itemCol:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT",   -8, 8)
    f.itemCol = itemCol

    -- column headers (small)
    local function colHdr(panel, text)
        local fs = panel:CreateFontString(nil, "OVERLAY")
        Skin:Font(fs, 11, true)
        fs:SetTextColor(unpack(C.accent))
        fs:SetPoint("TOPLEFT", 6, -4)
        fs:SetText(text)
        return fs
    end
    f.instHdr = colHdr(instCol, "Instance")
    f.bossHdr = colHdr(bossCol, "Boss")
    f.itemHdr = colHdr(itemCol, "Item")

    -- generic clickable row
    local function buildClickRow(parent)
        local r = CreateFrame("Button", nil, parent)
        r:SetHeight(20)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
        local hl = r:CreateTexture(nil, "BORDER"); hl:SetAllPoints(); hl:SetTexture(Skin.TEX_WHITE); hl:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.18); hl:Hide(); r.hl = hl
        local fs = r:CreateFontString(nil, "OVERLAY")
        Skin:Font(fs, 11, false)
        fs:SetPoint("LEFT", 6, 0); fs:SetPoint("RIGHT", -6, 0)
        fs:SetJustifyH("LEFT"); fs:SetWordWrap(false); fs:SetNonSpaceWrap(false)
        r.fs = fs
        return r
    end

    -- instance list
    local function updInstRow(r, item, idx, alt)
        if not item then return end
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        r.fs:SetText(item)
        r.fs:SetTextColor(unpack(C.text))
        if LP.instance == item then r.hl:Show() else r.hl:Hide() end
        r:SetScript("OnClick", function()
            LP.instance = item; LP.boss = nil
            LP:Refresh()
        end)
    end
    local instList = Skin:ScrollList(instCol, 20, buildClickRow, updInstRow)
    instList:SetPoint("TOPLEFT", 0, -22); instList:SetPoint("BOTTOMRIGHT", 0, 0)
    f.instList = instList

    -- boss list
    local function updBossRow(r, item, idx, alt)
        if not item then return end
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        r.fs:SetText(item)
        r.fs:SetTextColor(unpack(C.text))
        if LP.boss == item then r.hl:Show() else r.hl:Hide() end
        r:SetScript("OnClick", function()
            LP.boss = item
            LP:Refresh()
        end)
    end
    local bossList = Skin:ScrollList(bossCol, 20, buildClickRow, updBossRow)
    bossList:SetPoint("TOPLEFT", 0, -22); bossList:SetPoint("BOTTOMRIGHT", 0, 0)
    f.bossList = bossList

    -- item rows: link + explicit action button on the right
    local function buildItemRow(parent)
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(24)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg

        local hover = CreateFrame("Button", nil, r)  -- catches mouse for tooltip
        hover:SetPoint("TOPLEFT", 0, 0); hover:SetPoint("BOTTOMRIGHT", -90, 0)
        r.hover = hover

        local fs = hover:CreateFontString(nil, "OVERLAY")
        Skin:Font(fs, 12, false)
        fs:SetPoint("LEFT", 6, 0); fs:SetPoint("RIGHT", -4, 0)
        fs:SetJustifyH("LEFT"); fs:SetWordWrap(false); fs:SetNonSpaceWrap(false)
        r.fs = fs

        local extra = r:CreateFontString(nil, "OVERLAY")
        Skin:Font(extra, 9, false)
        extra:SetPoint("BOTTOMRIGHT", -94, 1)
        extra:SetTextColor(unpack(C.textDim))
        r.extra = extra

        local action = Skin:Button(r, "Reserve", 80, 20)
        action:SetPoint("RIGHT", -4, 0)
        r.action = action
        return r
    end
    local function updItemRow(r, item, idx, alt)
        if not item then return end
        local id    = item.id or item[1]
        local q     = item.q  or item[2]
        local name  = item.name or item[3]
        local link  = makeLink(id, q, name)
        r.fs:SetText(link)
        r.extra:SetText(item.boss and (item.exp..": "..item.boss) or "")

        local opts   = LP.opts or {}
        local picked = opts.isPicked and opts.isPicked(id) or false

        if picked then
            -- green tint to mark "already reserved"
            r.bg:SetVertexColor(C.good[1] * 0.7, C.good[2] * 0.7, C.good[3] * 0.7, 0.35)
            r.action:SetText(opts.unpickLabel or "Unreserve")
        else
            r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
            r.action:SetText(opts.actionLabel or "Reserve")
        end

        r.action:SetScript("OnMouseUp", function()
            local opts2 = LP.opts or {}
            local nowPicked = opts2.isPicked and opts2.isPicked(id) or false
            if nowPicked then
                if opts2.onUnpick then opts2.onUnpick(id, name) end
            else
                if opts2.onPick then opts2.onPick(link, id, name, q) end
            end
            -- repaint visible rows so the toggled row flips immediately
            if f.itemList and f.itemList.Update then f.itemList:Update() end
        end)
        r.hover:SetScript("OnEnter", function(s)
            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:"..id)
            GameTooltip:Show()
        end)
        r.hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    local itemList = Skin:ScrollList(itemCol, 24, buildItemRow, updItemRow)
    itemList:SetPoint("TOPLEFT", 0, -22); itemList:SetPoint("BOTTOMRIGHT", 0, 0)
    f.itemList = itemList

    -- search hookup
    searchEdit:SetScript("OnTextChanged", function(s)
        local q = s:GetText() or ""
        if #q >= 2 then
            self.searchActive = true
            self:Refresh()
        elseif self.searchActive then
            self.searchActive = false
            self:Refresh()
        end
    end)

    -- defaults
    self.expansion = "WOTLK"
    self.instance, self.boss = nil, nil
    return f
end

function LP:Open(opts)
    self:Build()
    self.opts = opts or {}
    self.win.titleFs:SetText(("LOOT PICKER -- %s"):format(self.opts.title or "select item"))
    self.win:Show()
    self:Refresh()
end

function LP:Close() if self.win then self.win:Hide() end end

function LP:Refresh()
    local f = self.win; if not f then return end
    -- expansion tab visuals
    for e, b in pairs(self.tabs) do b:SetSelected(e == self.expansion) end

    if self.searchActive then
        f.instHdr:SetText("Search results")
        f.bossHdr:SetText("(boss / instance)")
        f.itemHdr:SetText("Items")
        f.instList:SetData({})
        f.bossList:SetData({})
        local results = searchItems(self.searchEdit:GetText())
        f.itemList:SetData(results)
        return
    end

    f.instHdr:SetText("Instance ("..self.expansion..")")
    f.bossHdr:SetText("Boss"..(self.instance and " ("..self.instance..")" or ""))
    f.itemHdr:SetText("Item"..(self.boss and " ("..self.boss..")" or ""))

    f.instList:SetData(instancesIn(self.expansion))
    if self.instance then
        f.bossList:SetData(bossesIn(self.expansion, self.instance))
    else
        f.bossList:SetData({})
    end
    if self.instance and self.boss then
        f.itemList:SetData(itemsIn(self.expansion, self.instance, self.boss))
    else
        f.itemList:SetData({})
    end
end
