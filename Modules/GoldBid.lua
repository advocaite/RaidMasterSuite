-- Raid Master Suite -- Gold Bid
-- Live raid auctions: master looter / leader opens a bid session for an item,
-- raiders place gold bids, highest at timer-end wins. Trade is watched and
-- on payment confirmation the next step (item award) is unlocked. If trade
-- fails, the item is offered to the next-highest bidder.

local RMS = RaidMasterSuite
local M = RMS:RegisterModule("goldbid", { title = "Gold Bid", order = 4 })

-- ---------- session state (mirrored across raid) ----------
M.session = nil  -- {id, host, itemID, link, name, minBid, inc, duration, deadline, bids={}, status="open"|"ended"|"awaiting_pay"|"paid"|"awarded"|"cancelled", winner, runnerUp, awardingTo}
M.history = {}   -- finished sessions (persistent; bound to RMS.db.goldbid.history in OnInit)

local HISTORY_CAP_DEFAULT = 200

local function newSessionId()
    return RMS:PlayerName() .. ":" .. tostring(math.floor(GetTime() * 1000))
end

local function isHost()
    return M.session and M.session.host == RMS:PlayerName()
end

local function broadcast(cmd, payload)
    RMS.Comm:Send("goldbid", cmd, payload)
end

-- snapshot a session for archival (drops volatile fields, keeps display data)
local function snapshot(sess)
    local out = {
        id       = sess.id,    host = sess.host,
        itemID   = sess.itemID, link = sess.link, name = sess.name,
        minBid   = sess.minBid, inc  = sess.inc,  duration = sess.duration,
        status   = sess.status, paid = sess.paid,
        finishedAt = time(),
        bids = {},
    }
    for _, b in ipairs(sess.bids or {}) do
        table.insert(out.bids, { player = b.player, amount = b.amount })
    end
    if sess.winner then out.winner = { player = sess.winner.player, amount = sess.winner.amount } end
    return out
end

function M:OnInit()
    RMS.db.goldbid          = RMS.db.goldbid or {}
    RMS.db.goldbid.history  = RMS.db.goldbid.history or {}
    RMS.db.goldbid.historyCap = RMS.db.goldbid.historyCap or HISTORY_CAP_DEFAULT
    self.history = RMS.db.goldbid.history
end

-- ---------- session lifecycle ----------
function M:Start(itemLink, opts)
    if self.session and self.session.status == "open" then
        RMS:Print("A bid session is already running. Cancel it first.")
        return
    end
    if not (RMS:IsRaidLeader() or RMS:IsMasterLooter() or not RMS:InRaid()) then
        RMS:Print("Only the raid leader or master looter can start a bid.")
        return
    end
    local itemID = tonumber(itemLink and itemLink:match("item:(%d+)"))
    if not itemID then RMS:Print("Need a valid item link to start a bid.") return end
    local name = itemLink:match("%[(.-)%]") or "?"

    local cfg = RMS.db.goldbid
    opts = opts or {}
    local sess = {
        id       = newSessionId(),
        host     = RMS:PlayerName(),
        itemID   = itemID,
        link     = itemLink,
        name     = name,
        minBid   = opts.minBid   or cfg.minBid,
        inc      = opts.inc      or cfg.bidIncrement,
        duration = opts.duration or cfg.bidTimer,
        deadline = GetTime() + (opts.duration or cfg.bidTimer),
        bids     = {},
        status   = "open",
    }
    self.session = sess
    broadcast("start", {
        id = sess.id, host = sess.host, item = sess.itemID, link = sess.link, name = sess.name,
        min = sess.minBid, inc = sess.inc, dur = sess.duration,
    })
    RMS:Print("Bid OPEN for %s -- min %dg, %ds.", sess.link, sess.minBid, sess.duration)
    self:Refresh(); self:ShowPopup()
end

function M:Cancel()
    if not self.session then return end
    if not isHost() then RMS:Print("Only the session host can cancel.") return end
    broadcast("cancel", { id = self.session.id })
    self.session.status = "cancelled"
    RMS:Print("Bid CANCELLED.")
    self:ArchiveSession(); self:Refresh()
end

function M:Extend(seconds)
    if not self.session or self.session.status ~= "open" then return end
    if not isHost() then return end
    seconds = seconds or 15
    self.session.deadline = self.session.deadline + seconds
    broadcast("extend", { id = self.session.id, sec = seconds })
    RMS:Print("Bid extended +%ds.", seconds)
end

function M:CloseNow()
    if not self.session or self.session.status ~= "open" then return end
    if not isHost() then return end
    self.session.deadline = GetTime() - 0.01
end

-- ---------- bidding ----------
function M:PlaceBid(amount)
    local sess = self.session
    if not sess or sess.status ~= "open" then RMS:Print("No open bid.") return end
    amount = tonumber(amount)
    if not amount then RMS:Print("Invalid bid amount.") return end
    if amount < sess.minBid then RMS:Print("Min bid is %dg.", sess.minBid) return end

    local highest = self:Highest()
    if highest and amount < (highest.amount + sess.inc) then
        RMS:Print("Bid must be at least %dg.", highest.amount + sess.inc)
        return
    end

    local me = RMS:PlayerName()
    if GetMoney() / 10000 < amount then
        RMS:Print("You don't have %dg in inventory.", amount)
        return
    end

    broadcast("bid", { id = sess.id, p = me, a = amount })
    -- locally inject so we update immediately even before our own message returns
    self:_ApplyBid(sess.id, me, amount)
end

function M:_ApplyBid(sessionId, player, amount)
    local sess = self.session
    if not sess or sess.id ~= sessionId or sess.status ~= "open" then return end
    table.insert(sess.bids, { player = player, amount = amount, t = GetTime() })
    self:Refresh()
end

function M:Highest()
    if not self.session then return nil end
    local hi
    for _, b in ipairs(self.session.bids) do
        if not hi or b.amount > hi.amount then hi = b end
    end
    return hi
end

function M:RankedBidders()
    if not self.session then return {} end
    -- Take each bidder's max bid, sort desc, then by time asc as tiebreaker
    local maxByPlayer, firstAt = {}, {}
    for _, b in ipairs(self.session.bids) do
        if (maxByPlayer[b.player] or -1) < b.amount then
            maxByPlayer[b.player] = b.amount
            firstAt[b.player] = b.t
        end
    end
    local list = {}
    for p, a in pairs(maxByPlayer) do list[#list+1] = { player = p, amount = a, t = firstAt[p] } end
    table.sort(list, function(x, y)
        if x.amount ~= y.amount then return x.amount > y.amount end
        return x.t < y.t
    end)
    return list
end

-- ---------- end of session ----------
function M:_EndSession()
    local sess = self.session
    if not sess or sess.status ~= "open" then return end
    sess.status = "ended"

    local ranked = self:RankedBidders()
    if #ranked == 0 then
        RMS:Print("Bid for %s ended -- NO BIDS.", sess.link)
        if isHost() and RMS:InRaid() then
            SendChatMessage(("[RMS] %s -- no bids."):format(sess.link), "RAID")
        end
        self:ArchiveSession(); self:Refresh(); return
    end

    sess.winner   = ranked[1]
    sess.runnerUp = ranked[2]
    sess.status   = "awaiting_pay"
    sess.awardingTo = sess.winner.player

    if isHost() then
        if RMS:InRaid() then
            SendChatMessage(
                ("[RMS] %s -- WINNER: %s for %dg. Trade %s now."):format(
                    sess.link, sess.winner.player, sess.winner.amount, RMS:PlayerName()),
                "RAID_WARNING")
        end
        broadcast("winner", { id = sess.id, p = sess.winner.player, a = sess.winner.amount })
    end

    self:Refresh()
    self:ShowPopup()
end

function M:_OfferRunnerUp()
    local sess = self.session
    if not sess then return end
    local ranked = self:RankedBidders()
    -- find next bidder strictly below current awardingTo
    local nextB
    for _, r in ipairs(ranked) do
        if r.player ~= sess.awardingTo and (not sess.skipped or not sess.skipped[r.player]) then
            nextB = r; break
        end
    end
    if not nextB then
        RMS:Print("No more bidders. Item undisbursed.")
        sess.status = "cancelled"
        broadcast("noaward", { id = sess.id })
        self:ArchiveSession(); self:Refresh(); return
    end

    sess.skipped = sess.skipped or {}
    sess.skipped[sess.awardingTo] = true
    sess.awardingTo = nextB.player
    sess.winner    = nextB

    if isHost() and RMS:InRaid() then
        SendChatMessage(
            ("[RMS] %s -- offered to next bidder: %s for %dg."):format(
                sess.link, nextB.player, nextB.amount),
            "RAID_WARNING")
    end
    broadcast("offer", { id = sess.id, p = nextB.player, a = nextB.amount })
    self:Refresh()
end

function M:MarkPaid()
    local sess = self.session
    if not sess or (sess.status ~= "awaiting_pay" and sess.status ~= "paid") then return end
    if not isHost() then return end
    sess.status = "paid"
    sess.paid   = true
    broadcast("paid", { id = sess.id, p = sess.awardingTo })
    RMS:Print("Payment received from %s. Trade them %s now.", sess.awardingTo, sess.link)
    self:Refresh()
end

function M:MarkAwarded()
    local sess = self.session
    if not sess then return end
    if not isHost() then return end
    sess.status = "awarded"
    broadcast("award", { id = sess.id, p = sess.awardingTo })
    RMS:Print("Awarded %s to %s.", sess.link, sess.awardingTo)
    self:ArchiveSession(); self:Refresh()
end

function M:ArchiveSession()
    if not self.session then return end
    -- persistent snapshot
    local snap = snapshot(self.session)
    table.insert(self.history, 1, snap)
    local cap = (RMS.db.goldbid and RMS.db.goldbid.historyCap) or HISTORY_CAP_DEFAULT
    while #self.history > cap do table.remove(self.history) end
    if self.historyWin and self.historyWin:IsShown() then self:RefreshHistory() end

    -- Keep session visible for a few seconds, then clear unless reopened
    local closing = self.session
    local f = CreateFrame("Frame")
    local t = 0
    f:SetScript("OnUpdate", function(s, dt)
        t = t + dt
        if t >= 6 then
            if M.session == closing then M.session = nil end
            s:SetScript("OnUpdate", nil)
            M:Refresh()
            if M.popup then M.popup:Hide() end
        end
    end)
end

-- ---------- comm handlers ----------
RMS.Comm:On("goldbid", "start", function(p, sender)
    if M.session and M.session.status == "open" then return end -- already in one
    local dur = tonumber(p.dur) or 30
    M.session = {
        id = p.id, host = p.host or sender,
        itemID = tonumber(p.item), link = p.link, name = p.name,
        minBid = tonumber(p.min) or 0, inc = tonumber(p.inc) or 100,
        duration = dur, deadline = GetTime() + dur,
        bids = {}, status = "open",
    }
    RMS:Print("Bid OPENED by %s for %s.", M.session.host, M.session.link)
    M:Refresh(); M:ShowPopup()
end)

RMS.Comm:On("goldbid", "bid", function(p, sender)
    if not M.session or M.session.id ~= p.id then return end
    if (p.p or sender) ~= sender then return end -- prevent forging
    M:_ApplyBid(p.id, p.p or sender, tonumber(p.a))
end)

RMS.Comm:On("goldbid", "extend", function(p, sender)
    if not M.session or M.session.id ~= p.id then return end
    if M.session.host ~= sender then return end
    local sec = tonumber(p.sec) or 15
    M.session.deadline = M.session.deadline + sec
    RMS:Print("Bid extended +%ds by %s.", sec, sender)
end)

RMS.Comm:On("goldbid", "cancel", function(p, sender)
    if not M.session or M.session.id ~= p.id then return end
    if M.session.host ~= sender then return end
    M.session.status = "cancelled"
    RMS:Print("Bid cancelled by %s.", sender)
    M:ArchiveSession(); M:Refresh()
end)

RMS.Comm:On("goldbid", "winner", function(p, sender)
    if not M.session or M.session.id ~= p.id then return end
    if M.session.host ~= sender then return end
    M.session.status   = "awaiting_pay"
    M.session.winner   = { player = p.p, amount = tonumber(p.a) }
    M.session.awardingTo = p.p
    M:Refresh(); M:ShowPopup()
end)

RMS.Comm:On("goldbid", "offer", function(p, sender)
    if not M.session or M.session.id ~= p.id then return end
    if M.session.host ~= sender then return end
    M.session.winner = { player = p.p, amount = tonumber(p.a) }
    M.session.awardingTo = p.p
    M.session.status = "awaiting_pay"
    M:Refresh()
end)

RMS.Comm:On("goldbid", "paid", function(p, sender)
    if not M.session or M.session.id ~= p.id then return end
    if M.session.host ~= sender then return end
    M.session.status = "paid"
    M.session.paid   = true
    M:Refresh()
end)

RMS.Comm:On("goldbid", "award", function(p, sender)
    if not M.session or M.session.id ~= p.id then return end
    if M.session.host ~= sender then return end
    M.session.status = "awarded"
    M:ArchiveSession(); M:Refresh()
end)

RMS.Comm:On("goldbid", "noaward", function(_, sender)
    if not M.session then return end
    if M.session.host ~= sender then return end
    M.session.status = "cancelled"
    M:ArchiveSession(); M:Refresh()
end)

-- ---------- trade detection (host side) ----------
local trade = { partner = nil, theirCopper = 0, lastShown = nil }

local function onTradeShow()
    trade.partner = UnitName("NPC") -- the trade target is "NPC" in 3.3.5a tradeframe
    trade.theirCopper = 0
    if M.session and M.session.status == "awaiting_pay"
       and trade.partner and trade.partner == M.session.awardingTo then
        RMS:Print("Trade open with %s -- expecting %dg.", trade.partner, M.session.winner.amount)
    end
end

local function onTradeMoneyChanged()
    if not (M.session and M.session.status == "awaiting_pay") then return end
    if not (trade.partner and trade.partner == M.session.awardingTo) then return end
    -- TargetMoney = what the other side is offering
    local copper = tonumber(GetTargetTradeMoney() or 0) or 0
    trade.theirCopper = copper
    local needCopper = M.session.winner.amount * 10000
    if copper >= needCopper then
        RMS:Print("|cff60ff60Trade money matches bid (%dg). Click Accept to complete.|r",
            M.session.winner.amount)
    end
end

local function onUiInfoMessage(_, msg)
    if not msg then return end
    local TRADE_COMPLETE_MSG = _G.ERR_TRADE_COMPLETE
    if (TRADE_COMPLETE_MSG and msg == TRADE_COMPLETE_MSG) or msg:lower():find("trade complete") then
        if M.session and M.session.status == "awaiting_pay"
           and trade.partner == M.session.awardingTo
           and RMS.db.goldbid.autoTradeDetect then
            -- check if their final money offer covered the bid
            local needCopper = M.session.winner.amount * 10000
            if trade.theirCopper >= needCopper then
                if isHost() then M:MarkPaid() end
            end
        end
        trade.partner = nil; trade.theirCopper = 0
    end
end

local function onTradeClosed()
    trade.partner = nil; trade.theirCopper = 0
end

M.events = {
    TRADE_SHOW           = function(self) onTradeShow() end,
    TRADE_MONEY_CHANGED  = function(self) onTradeMoneyChanged() end,
    TRADE_ACCEPT_UPDATE  = function(self) onTradeMoneyChanged() end,
    UI_INFO_MESSAGE      = function(self, _, msg) onUiInfoMessage(_, msg) end,
    TRADE_CLOSED         = function(self) onTradeClosed() end,
    TRADE_REQUEST_CANCEL = function(self) onTradeClosed() end,
}

-- ---------- timer driver ----------
local timer = CreateFrame("Frame")
timer:SetScript("OnUpdate", function()
    local sess = M.session
    if not sess or sess.status ~= "open" then return end
    if GetTime() >= sess.deadline then
        if isHost() then M:_EndSession() end
        -- non-host clients also flip status when time elapses; host's "winner" msg
        -- will overwrite to authoritative result.
        if not isHost() and sess.status == "open" then
            sess.status = "ended"
        end
    end
    M:RefreshTimerOnly()
end)

-- ---------- slash ----------
function M:OnSlash(arg)
    arg = (arg or ""):gsub("^%s+",""):gsub("%s+$","")
    if arg == "" then RMS.UI:Show("goldbid"); return end
    if arg == "cancel" then return self:Cancel() end
    if arg == "close"  then return self:CloseNow() end
    local link = arg:match("(|c%x+|Hitem:.-|h.-|h|r)")
    if link then return self:Start(link) end
    RMS.UI:Show("goldbid")
end

-- ---------- UI ----------
function M:BuildUI(parent)
    local Skin = RMS.Skin
    local C    = Skin.COLOR
    local panel = CreateFrame("Frame", nil, parent)

    local header = Skin:Header(panel, "Gold Bid")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)

    local status = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(status, 12, true)
    status:SetPoint("RIGHT", header, "RIGHT", -10, 0)

    -- ML controls row
    local hostLabel = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(hostLabel, 11, false)
    hostLabel:SetTextColor(unpack(C.textDim))
    hostLabel:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -8)
    hostLabel:SetText("Host: paste an item link, then Start (uses defaults from Settings):")

    local linkEdit = Skin:EditBox(panel, 380, 22)
    linkEdit:SetPoint("TOPLEFT", hostLabel, "BOTTOMLEFT", 0, -4)
    hooksecurefunc("ChatEdit_InsertLink", function(text)
        if linkEdit:HasFocus() then linkEdit:SetText(text); return true end
    end)

    -- Toolbar row 2: action buttons (kept inside the 380w left column)
    local startBtn  = Skin:Button(panel, "Start Bid", 88, 22)
    startBtn:SetPoint("TOPLEFT", linkEdit, "BOTTOMLEFT", 0, -6)
    startBtn:SetScript("OnMouseUp", function()
        local link = linkEdit:GetText():match("(|c%x+|Hitem:.-|h.-|h|r)")
        if not link then RMS:Print("Paste a real item link first.") return end
        self:Start(link); linkEdit:SetText("")
    end)

    local cancelBtn = Skin:Button(panel, "Cancel", 70, 22)
    cancelBtn:SetPoint("LEFT", startBtn, "RIGHT", 6, 0)
    cancelBtn:SetScript("OnMouseUp", function() self:Cancel() end)

    local closeBtn = Skin:Button(panel, "Close Now", 88, 22)
    closeBtn:SetPoint("LEFT", cancelBtn, "RIGHT", 6, 0)
    closeBtn:SetScript("OnMouseUp", function() self:CloseNow() end)

    local extendBtn = Skin:Button(panel, "+15s", 50, 22)
    extendBtn:SetPoint("LEFT", closeBtn, "RIGHT", 6, 0)
    extendBtn:SetScript("OnMouseUp", function() self:Extend(15) end)

    -- Active session panel
    local actHdr = Skin:Header(panel, "Active Session")
    actHdr:SetPoint("TOPLEFT", startBtn, "BOTTOMLEFT", 0, -12)
    actHdr:SetWidth(380)

    local actBody = Skin:Panel(panel)
    actBody:SetPoint("TOPLEFT", actHdr, "BOTTOMLEFT", 0, -2)
    actBody:SetWidth(380); actBody:SetHeight(190)

    local itemFs = actBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(itemFs, 13, true)
    itemFs:SetPoint("TOPLEFT", 8, -8); itemFs:SetPoint("RIGHT", -8, 0)
    itemFs:SetJustifyH("LEFT")
    itemFs:SetTextColor(unpack(C.text))

    local timerFs = actBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(timerFs, 24, true)
    timerFs:SetPoint("TOP", itemFs, "BOTTOM", 0, -6)
    timerFs:SetTextColor(unpack(C.accent))
    timerFs:SetText("--")

    local highFs = actBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(highFs, 12, false)
    highFs:SetPoint("TOP", timerFs, "BOTTOM", 0, -6)
    highFs:SetTextColor(unpack(C.text))

    -- bidder controls (bottom row)
    local bidEdit = Skin:EditBox(actBody, 80, 22)
    bidEdit:SetPoint("BOTTOMLEFT", 8, 8)
    bidEdit:SetNumeric(true)

    local bidBtn = Skin:Button(actBody, "Bid", 56, 22)
    bidBtn:SetPoint("LEFT", bidEdit, "RIGHT", 4, 0)
    bidBtn:SetScript("OnMouseUp", function()
        local v = tonumber(bidEdit:GetText())
        if v and self.session then self:PlaceBid(v); bidEdit:SetText("") end
    end)

    local incBtn = Skin:Button(actBody, "+inc", 48, 22)
    incBtn:SetPoint("LEFT", bidBtn, "RIGHT", 4, 0)
    incBtn:SetScript("OnMouseUp", function()
        if not self.session then return end
        local hi = self:Highest()
        local nx = (hi and hi.amount or self.session.minBid - self.session.inc) + self.session.inc
        bidEdit:SetText(tostring(nx))
    end)

    local minBtn = Skin:Button(actBody, "min", 44, 22)
    minBtn:SetPoint("LEFT", incBtn, "RIGHT", 4, 0)
    minBtn:SetScript("OnMouseUp", function()
        if self.session then bidEdit:SetText(tostring(self.session.minBid)) end
    end)

    local bidderLabel = actBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(bidderLabel, 10, false)
    bidderLabel:SetTextColor(unpack(C.textDim))
    bidderLabel:SetPoint("BOTTOMLEFT", bidEdit, "TOPLEFT", 2, 2)
    bidderLabel:SetText("Your bid (gold):")

    -- award buttons (host) -- separate row ABOVE the bidder row
    local nextBtn = Skin:Button(actBody, "Next Bidder", 100, 22)
    nextBtn:SetPoint("BOTTOMLEFT", bidderLabel, "TOPLEFT", -2, 6)
    nextBtn:SetScript("OnMouseUp", function() self:_OfferRunnerUp() end)

    local awardBtn = Skin:Button(actBody, "Awarded", 88, 22)
    awardBtn:SetPoint("LEFT", nextBtn, "RIGHT", 6, 0)
    awardBtn:SetScript("OnMouseUp", function() self:MarkAwarded() end)

    local paidBtn = Skin:Button(actBody, "Mark Paid", 88, 22)
    paidBtn:SetPoint("LEFT", awardBtn, "RIGHT", 6, 0)
    paidBtn:SetScript("OnMouseUp", function() self:MarkPaid() end)

    -- bid history list
    local histHdr = Skin:Header(panel, "Bids (this session)")
    histHdr:SetPoint("TOPLEFT", actBody, "BOTTOMLEFT", 0, -8)
    histHdr:SetWidth(380)

    local function buildBidRow(parent)
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(18)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
        local p = r:CreateFontString(nil, "OVERLAY"); Skin:Font(p, 11, false); p:SetPoint("LEFT", 6, 0); r.p = p
        local a = r:CreateFontString(nil, "OVERLAY"); Skin:Font(a, 11, true);  a:SetPoint("RIGHT", -6, 0); a:SetTextColor(unpack(Skin.COLOR.accent)); r.a = a
        return r
    end
    local function updateBidRow(r, item, idx, alt)
        if not item then return end
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        r.p:SetText(item.player)
        r.a:SetText(item.amount.."g")
    end
    local bidsList = Skin:ScrollList(panel, 18, buildBidRow, updateBidRow)
    bidsList:SetPoint("TOPLEFT", histHdr, "BOTTOMLEFT", 0, -2)
    bidsList:SetPoint("BOTTOM", panel, "BOTTOM", 0, 8)
    bidsList:SetWidth(380)

    -- recent results column (right)
    local logHdr = Skin:Header(panel, "Recent Results")
    logHdr:SetPoint("TOPLEFT", actHdr, "TOPRIGHT", 8, 0)
    logHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    local fullHistBtn = Skin:Button(logHdr, "Full History", 90, 22)
    fullHistBtn:SetPoint("RIGHT", -4, 0)
    fullHistBtn:SetScript("OnMouseUp", function() M:OpenHistory() end)
    Skin:AttachTooltip(fullHistBtn, "Bid History",
        {"View all past bid sessions, search by item, see best/avg sale price."})

    local function buildLogRow(parent)
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(36)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
        local item = r:CreateFontString(nil, "OVERLAY")
        Skin:Font(item, 11, true)
        item:SetPoint("TOPLEFT", 6, -3); item:SetPoint("RIGHT", -6, 0)
        item:SetJustifyH("LEFT"); item:SetHeight(14)
        item:SetWordWrap(false); item:SetNonSpaceWrap(false)
        r.item = item

        local result = r:CreateFontString(nil, "OVERLAY")
        Skin:Font(result, 11, false)
        result:SetPoint("TOPLEFT",  item, "BOTTOMLEFT", 0, -2)
        result:SetPoint("RIGHT", -6, 0)
        result:SetJustifyH("LEFT"); result:SetHeight(14)
        result:SetWordWrap(false); result:SetNonSpaceWrap(false)
        r.result = result
        return r
    end
    local C = Skin.COLOR
    local function fmtBadge(text, color)
        return ("|cff%02x%02x%02x[%s]|r"):format(color[1]*255, color[2]*255, color[3]*255, text)
    end
    local function updateLogRow(r, item, idx, alt)
        if not item then return end
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        r.item:SetText(item.link or item.name or "?")
        local badges = {}
        if item.status == "awarded"   then table.insert(badges, fmtBadge("WON",       C.good)) end
        if item.paid                  then table.insert(badges, fmtBadge("PAID",      C.good)) end
        if item.status == "cancelled" then table.insert(badges, fmtBadge("CANCELLED", C.bad )) end
        if item.status == "ended" and (not item.winner) then
            table.insert(badges, fmtBadge("NO BIDS", C.textDim))
        end
        local who = item.winner and item.winner.player or "--"
        local amt = item.winner and (item.winner.amount.."g") or ""
        r.result:SetText(("%s  %s  %s"):format(who, amt, table.concat(badges, " ")))
    end
    local logList = Skin:ScrollList(panel, 36, buildLogRow, updateLogRow)
    logList:SetPoint("TOPLEFT",  logHdr, "BOTTOMLEFT", 0, -2)
    logList:SetPoint("BOTTOM", panel, "BOTTOM", 0, 8)
    logList:SetPoint("RIGHT",  panel, "RIGHT",  -8, 0)

    self._ui = {
        panel = panel, status = status,
        startBtn = startBtn, cancelBtn = cancelBtn, closeBtn = closeBtn, extendBtn = extendBtn,
        linkEdit = linkEdit,
        actBody = actBody, itemFs = itemFs, timerFs = timerFs, highFs = highFs,
        bidEdit = bidEdit, bidBtn = bidBtn, incBtn = incBtn, minBtn = minBtn,
        paidBtn = paidBtn, awardBtn = awardBtn, nextBtn = nextBtn,
        bidsList = bidsList, logList = logList,
    }
    self:Refresh()
    return panel
end

function M:RefreshTimerOnly()
    if not (self._ui and self.session) then return end
    if self.session.status == "open" then
        local rem = math.max(0, self.session.deadline - GetTime())
        self._ui.timerFs:SetText(string.format("%0.1fs", rem))
        if rem <= 5 then self._ui.timerFs:SetTextColor(unpack(RMS.Skin.COLOR.bad))
        else            self._ui.timerFs:SetTextColor(unpack(RMS.Skin.COLOR.accent)) end
    end
    if self.popup and self.popup:IsShown() then
        self:RefreshPopup()
    end
end

function M:Refresh()
    if not self._ui then return end
    local C = RMS.Skin.COLOR
    local sess = self.session
    local canHost = (RMS:IsRaidLeader() or RMS:IsMasterLooter() or not RMS:InRaid())

    -- header status
    if not sess then
        self._ui.status:SetText("IDLE")
        self._ui.status:SetTextColor(unpack(C.textDim))
    else
        local s = sess.status
        local color = (s == "open" and C.good) or (s == "awaiting_pay" and C.warn) or (s == "paid" and C.warn) or (s == "awarded" and C.good) or C.textDim
        self._ui.status:SetText(s:upper())
        self._ui.status:SetTextColor(unpack(color))
    end

    -- host buttons
    local hostNow = sess and isHost()
    if canHost then self._ui.startBtn:Enable() else self._ui.startBtn:Disable() end
    if hostNow and sess.status == "open" then
        self._ui.cancelBtn:Enable(); self._ui.closeBtn:Enable(); self._ui.extendBtn:Enable()
    else
        self._ui.cancelBtn:Disable(); self._ui.closeBtn:Disable(); self._ui.extendBtn:Disable()
    end

    if hostNow and (sess.status == "awaiting_pay" or sess.status == "paid") then
        self._ui.paidBtn:Enable(); self._ui.awardBtn:Enable(); self._ui.nextBtn:Enable()
    else
        self._ui.paidBtn:Disable(); self._ui.awardBtn:Disable(); self._ui.nextBtn:Disable()
    end

    -- active session body
    if sess then
        self._ui.itemFs:SetText(sess.link or sess.name or "?")
        local hi = self:Highest()
        if hi then
            self._ui.highFs:SetText(("High: %s -- %dg  (min %dg, +%dg)"):format(hi.player, hi.amount, sess.minBid, sess.inc))
        else
            self._ui.highFs:SetText(("No bids -- min %dg, +%dg"):format(sess.minBid, sess.inc))
        end
        if sess.status == "awaiting_pay" then
            self._ui.timerFs:SetText("AWAIT $")
            self._ui.timerFs:SetTextColor(unpack(C.warn))
        elseif sess.status == "paid" then
            self._ui.timerFs:SetText("PAID")
            self._ui.timerFs:SetTextColor(unpack(C.good))
        elseif sess.status == "awarded" then
            self._ui.timerFs:SetText("AWARDED")
            self._ui.timerFs:SetTextColor(unpack(C.good))
        elseif sess.status == "cancelled" then
            self._ui.timerFs:SetText("CANCELLED")
            self._ui.timerFs:SetTextColor(unpack(C.bad))
        end

        -- bidder controls only enabled when open and not host (host can also bid in solo test)
        if sess.status == "open" then
            self._ui.bidEdit:Enable(); self._ui.bidBtn:Enable()
            self._ui.incBtn:Enable(); self._ui.minBtn:Enable()
        else
            self._ui.bidEdit:Disable(); self._ui.bidBtn:Disable()
            self._ui.incBtn:Disable(); self._ui.minBtn:Disable()
        end

        self._ui.bidsList:SetData(self:RankedBidders())
    else
        self._ui.itemFs:SetText("(no active session)")
        self._ui.timerFs:SetText("--")
        self._ui.highFs:SetText("")
        self._ui.bidsList:SetData({})
    end

    self._ui.logList:SetData(self.history)
end

-- ---------- popup window (auto-shown to bidders) ----------
function M:BuildPopup()
    if self.popup then return self.popup end
    local Skin = RMS.Skin
    local C    = Skin.COLOR
    local f = CreateFrame("Frame", "RaidMasterSuiteGoldBidPopup", UIParent)
    f:SetSize(320, 160)
    f:SetPoint("TOP", 0, -200)
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true); f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    Skin:SetBackdrop(f, C.bgMain, C.accent)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY")
    Skin:Font(title, 14, true)
    title:SetTextColor(unpack(C.accent))
    title:SetPoint("TOP", 0, -8)
    title:SetText("GOLD BID")

    local item = f:CreateFontString(nil, "OVERLAY")
    Skin:Font(item, 12, true)
    item:SetTextColor(unpack(C.text))
    item:SetPoint("TOP", title, "BOTTOM", 0, -6)
    item:SetWidth(300); item:SetJustifyH("CENTER")

    local timer = f:CreateFontString(nil, "OVERLAY")
    Skin:Font(timer, 22, true)
    timer:SetTextColor(unpack(C.accent))
    timer:SetPoint("TOP", item, "BOTTOM", 0, -4)

    local high = f:CreateFontString(nil, "OVERLAY")
    Skin:Font(high, 11, false)
    high:SetTextColor(unpack(C.textDim))
    high:SetPoint("TOP", timer, "BOTTOM", 0, -4)

    local edit = Skin:EditBox(f, 80, 22)
    edit:SetPoint("BOTTOMLEFT", 12, 12)
    edit:SetNumeric(true)

    local bid = Skin:Button(f, "Bid", 60, 22)
    bid:SetPoint("LEFT", edit, "RIGHT", 4, 0)
    bid:SetScript("OnMouseUp", function()
        local v = tonumber(edit:GetText())
        if v then M:PlaceBid(v); edit:SetText("") end
    end)

    local inc = Skin:Button(f, "+inc", 50, 22)
    inc:SetPoint("LEFT", bid, "RIGHT", 4, 0)
    inc:SetScript("OnMouseUp", function()
        if not M.session then return end
        local hi = M:Highest()
        local nx = (hi and hi.amount or M.session.minBid - M.session.inc) + M.session.inc
        edit:SetText(tostring(nx))
    end)

    local close = Skin:Button(f, "x", 22, 22)
    close:SetPoint("TOPRIGHT", -4, -4)
    close.text:SetTextColor(unpack(C.bad))
    close:SetScript("OnMouseUp", function() f:Hide() end)

    f.title, f.item, f.timer, f.high, f.edit = title, item, timer, high, edit
    self.popup = f
    return f
end

function M:ShowPopup()
    self:BuildPopup()
    self:RefreshPopup()
    self.popup:Show()
end

function M:RefreshPopup()
    local f = self.popup; if not f then return end
    local sess = self.session
    if not sess then f:Hide(); return end
    f.item:SetText(sess.link or sess.name or "?")
    if sess.status == "open" then
        local rem = math.max(0, sess.deadline - GetTime())
        f.timer:SetText(string.format("%0.1fs", rem))
        f.timer:SetTextColor(unpack(rem <= 5 and RMS.Skin.COLOR.bad or RMS.Skin.COLOR.accent))
        local hi = M:Highest()
        f.high:SetText(hi and (("High: %s -- %dg"):format(hi.player, hi.amount))
                          or ("Min %dg, +%dg"):format(sess.minBid, sess.inc))
        f.edit:Enable()
    elseif sess.status == "awaiting_pay" then
        f.timer:SetText("WINNER")
        f.timer:SetTextColor(unpack(RMS.Skin.COLOR.warn))
        local w = sess.winner
        f.high:SetText(w and (("%s -- %dg -- trade %s"):format(w.player, w.amount, sess.host)) or "")
        f.edit:Disable()
    else
        f.high:SetText(sess.status:upper())
        f.timer:SetText("")
        f.edit:Disable()
    end
end

-- ====================================================================
-- History window (saved sessions browser, with By-Item aggregate stats)
-- ====================================================================

local function badgeStr(text, color)
    return ("|cff%02x%02x%02x[%s]|r"):format(color[1]*255, color[2]*255, color[3]*255, text)
end

function M:GetItemStats()
    local map = {}
    for _, sess in ipairs(self.history) do
        local id = sess.itemID
        if id then
            local m = map[id]
            if not m then
                m = { itemID = id, link = sess.link, name = sess.name,
                      count = 0, soldCount = 0, total = 0, max = 0, min = math.huge, sales = {} }
                map[id] = m
            end
            m.count = m.count + 1
            if sess.status == "awarded" and sess.winner then
                m.soldCount = m.soldCount + 1
                m.total     = m.total + sess.winner.amount
                if sess.winner.amount > m.max then m.max = sess.winner.amount end
                if sess.winner.amount < m.min then m.min = sess.winner.amount end
                table.insert(m.sales, sess)
            end
        end
    end
    local list = {}
    for _, m in pairs(map) do
        if m.min == math.huge then m.min = 0 end
        m.avg = (m.soldCount > 0) and math.floor(m.total / m.soldCount) or 0
        list[#list+1] = m
    end
    table.sort(list, function(a, b)
        if a.soldCount ~= b.soldCount then return a.soldCount > b.soldCount end
        return (a.total or 0) > (b.total or 0)
    end)
    return list
end

function M:BuildHistoryWindow()
    if self.historyWin then return self.historyWin end
    local Skin = RMS.Skin
    local C    = Skin.COLOR

    local f = CreateFrame("Frame", "RaidMasterSuiteGoldBidHistory", UIParent)
    f:SetSize(720, 460)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true); f:SetMovable(true); f:SetClampedToScreen(true)
    Skin:SetBackdrop(f, C.bgMain, C.borderHi)
    f:Hide()
    self.historyWin = f

    -- title bar (drag handle)
    local title = CreateFrame("Frame", nil, f)
    title:SetPoint("TOPLEFT"); title:SetPoint("TOPRIGHT")
    title:SetHeight(30)
    Skin:SetBackdrop(title, C.bgHeader, C.border)
    title:EnableMouse(true)
    title:RegisterForDrag("LeftButton")
    title:SetScript("OnDragStart", function() f:StartMoving() end)
    title:SetScript("OnDragStop",  function() f:StopMovingOrSizing() end)

    local tFs = title:CreateFontString(nil, "OVERLAY")
    Skin:Font(tFs, 14, true)
    tFs:SetTextColor(unpack(C.accent))
    tFs:SetPoint("LEFT", 12, 0)
    tFs:SetText("BID HISTORY")

    local close = Skin:CloseButton(title)
    close:SetPoint("RIGHT", -6, 0)
    close:SetScript("OnClick", function() f:Hide() end)

    local clearBtn = Skin:Button(title, "Clear All", 80, 22)
    clearBtn:SetPoint("RIGHT", close, "LEFT", -4, 0)
    clearBtn:SetScript("OnMouseUp", function()
        for k in pairs(M.history) do M.history[k] = nil end
        M.selectedIdx = nil
        M:RefreshHistory()
        M:Refresh()
    end)

    local count = title:CreateFontString(nil, "OVERLAY")
    Skin:Font(count, 11, false)
    count:SetTextColor(unpack(C.textDim))
    count:SetPoint("RIGHT", clearBtn, "LEFT", -10, 0)
    f.countFs = count

    -- mode tabs
    local sesTab  = Skin:TabButton(f, "Sessions", 110, 26)
    local itemTab = Skin:TabButton(f, "By Item",  110, 26)
    sesTab:SetPoint("TOPLEFT", 8, -36)
    itemTab:SetPoint("LEFT", sesTab, "RIGHT", 4, 0)
    f.sesTab, f.itemTab = sesTab, itemTab

    sesTab:SetScript("OnClick",  function() M.histMode="sessions"; M.selectedIdx=nil; sesTab:SetSelected(true);  itemTab:SetSelected(false); M:RefreshHistory() end)
    itemTab:SetScript("OnClick", function() M.histMode="items";    M.selectedIdx=nil; sesTab:SetSelected(false); itemTab:SetSelected(true);  M:RefreshHistory() end)

    -- left list panel
    local listPanel = Skin:Panel(f)
    listPanel:SetPoint("TOPLEFT", 8, -68)
    listPanel:SetPoint("BOTTOMLEFT", 8, 8)
    listPanel:SetWidth(280)

    -- right detail panel
    local detail = Skin:Panel(f)
    detail:SetPoint("TOPLEFT",     listPanel, "TOPRIGHT", 6, 0)
    detail:SetPoint("BOTTOMRIGHT", -8, 8)

    -- list rows (clickable to select)
    local function buildListRow(parent)
        local r = CreateFrame("Button", nil, parent)
        r:SetHeight(38)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
        local hl = r:CreateTexture(nil, "BORDER"); hl:SetAllPoints(); hl:SetTexture(Skin.TEX_WHITE); hl:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.20); hl:Hide(); r.hl = hl
        local top = r:CreateFontString(nil, "OVERLAY"); Skin:Font(top, 11, true)
        top:SetPoint("TOPLEFT", 6, -3); top:SetPoint("RIGHT", -6, 0)
        top:SetJustifyH("LEFT"); top:SetWordWrap(false); top:SetNonSpaceWrap(false)
        r.top = top
        local bot = r:CreateFontString(nil, "OVERLAY"); Skin:Font(bot, 10, false)
        bot:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, -2); bot:SetPoint("RIGHT", -6, 0)
        bot:SetJustifyH("LEFT"); bot:SetWordWrap(false); bot:SetNonSpaceWrap(false)
        bot:SetTextColor(unpack(C.textDim))
        r.bot = bot
        return r
    end
    local function updateListRow(r, item, idx, alt)
        if not item then return end
        r._idx = idx
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        if M.selectedIdx == idx then r.hl:Show() else r.hl:Hide() end
        if M.histMode == "items" then
            r.top:SetText(item.link or item.name or "?")
            r.bot:SetText(("Sold %d  --  Avg %dg  --  Max %dg"):format(item.soldCount, item.avg, item.max))
        else
            r.top:SetText(item.link or item.name or "?")
            local badges = {}
            if item.status == "awarded"   then table.insert(badges, badgeStr("WON",  C.good)) end
            if item.paid                  then table.insert(badges, badgeStr("PAID", C.good)) end
            if item.status == "cancelled" then table.insert(badges, badgeStr("CXL",  C.bad )) end
            if not item.winner            then table.insert(badges, badgeStr("NO BIDS", C.textDim)) end
            local d = item.finishedAt and date("%m/%d %H:%M", item.finishedAt) or ""
            r.bot:SetText(d.."   "..table.concat(badges, " "))
        end
        r:SetScript("OnClick", function()
            M.selectedIdx = r._idx
            M:RefreshHistory()
        end)
    end
    local list = Skin:ScrollList(listPanel, 38, buildListRow, updateListRow)
    list:SetAllPoints(listPanel)
    f.list = list

    -- detail content
    local titleFs = detail:CreateFontString(nil, "OVERLAY")
    Skin:Font(titleFs, 14, true)
    titleFs:SetTextColor(unpack(C.text))
    titleFs:SetPoint("TOPLEFT", 8, -8); titleFs:SetPoint("RIGHT", -8, 0)
    titleFs:SetJustifyH("LEFT"); titleFs:SetWordWrap(false); titleFs:SetNonSpaceWrap(false)
    f.detailTitle = titleFs

    local metaFs = detail:CreateFontString(nil, "OVERLAY")
    Skin:Font(metaFs, 11, false)
    metaFs:SetTextColor(unpack(C.textDim))
    metaFs:SetPoint("TOPLEFT", titleFs, "BOTTOMLEFT", 0, -4); metaFs:SetPoint("RIGHT", -8, 0)
    metaFs:SetJustifyH("LEFT")
    f.detailMeta = metaFs

    local statsFs = detail:CreateFontString(nil, "OVERLAY")
    Skin:Font(statsFs, 12, true)
    statsFs:SetTextColor(unpack(C.accent))
    statsFs:SetPoint("TOPLEFT", metaFs, "BOTTOMLEFT", 0, -6); statsFs:SetPoint("RIGHT", -8, 0)
    statsFs:SetJustifyH("LEFT")
    f.detailStats = statsFs

    local subHdr = Skin:Header(detail, "Bids")
    subHdr:SetPoint("TOPLEFT", statsFs, "BOTTOMLEFT", 0, -8)
    subHdr:SetPoint("RIGHT", detail, "RIGHT", -8, 0)
    subHdr:SetHeight(22)
    f.subHdr = subHdr

    local function buildBidRow(parent)
        local r = CreateFrame("Frame", nil, parent)
        r:SetHeight(18)
        local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
        local rank = r:CreateFontString(nil, "OVERLAY"); Skin:Font(rank, 10, false); rank:SetPoint("LEFT", 6, 0); rank:SetWidth(28); r.rank = rank
        local p    = r:CreateFontString(nil, "OVERLAY"); Skin:Font(p,    11, false); p:SetPoint("LEFT", rank, "RIGHT", 4, 0); r.p = p
        local a    = r:CreateFontString(nil, "OVERLAY"); Skin:Font(a,    11, true);  a:SetPoint("RIGHT", -8, 0); a:SetTextColor(unpack(C.accent)); r.a = a
        local crown= r:CreateFontString(nil, "OVERLAY"); Skin:Font(crown,10, true);  crown:SetPoint("RIGHT", a, "LEFT", -8, 0); crown:SetTextColor(unpack(C.good)); r.crown = crown
        return r
    end
    local function updateBidRow(r, item, idx, alt)
        if not item then return end
        r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
        r.rank:SetText("#"..idx)
        r.p:SetText(item.player or "?")
        r.a:SetText((item.amount or 0).."g")
        r.crown:SetText(item._winner and "WIN" or "")
    end
    local detailList = Skin:ScrollList(detail, 18, buildBidRow, updateBidRow)
    detailList:SetPoint("TOPLEFT",  subHdr, "BOTTOMLEFT", 0, -2)
    detailList:SetPoint("BOTTOMRIGHT", -6, 6)
    f.detailList = detailList

    -- defaults
    self.histMode = "sessions"
    self.selectedIdx = nil
    sesTab:SetSelected(true); itemTab:SetSelected(false)
    return f
end

function M:OpenHistory()
    self:BuildHistoryWindow()
    self.historyWin:Show()
    self:RefreshHistory()
end

function M:RefreshHistory()
    local f = self.historyWin
    if not f or not f:IsShown() then return end
    local C = RMS.Skin.COLOR

    local data = (self.histMode == "items") and self:GetItemStats() or self.history
    f.countFs:SetText(("%d entries"):format(#data))
    f.list:SetData(data)

    local sel = self.selectedIdx and data[self.selectedIdx]
    if not sel then
        f.detailTitle:SetText("Select an entry on the left.")
        f.detailMeta:SetText("")
        f.detailStats:SetText("")
        f.detailList:SetData({})
        return
    end

    if self.histMode == "items" then
        f.detailTitle:SetText(sel.link or sel.name or "?")
        f.detailMeta:SetText(("Logged sessions: %d   --   Sold: %d"):format(sel.count, sel.soldCount))
        f.detailStats:SetText(("Avg: %dg    Max: %dg    Min: %dg    Total: %dg"):format(sel.avg, sel.max, sel.min, sel.total))
        local rows = {}
        for _, s in ipairs(sel.sales) do
            rows[#rows+1] = { player = s.winner.player, amount = s.winner.amount, _winner = true }
        end
        f.detailList:SetData(rows)
    else
        f.detailTitle:SetText(sel.link or sel.name or "?")
        local d = sel.finishedAt and date("%Y-%m-%d %H:%M:%S", sel.finishedAt) or "?"
        f.detailMeta:SetText(("Host: %s    When: %s    Min: %dg  +%dg  %ds"):format(
            sel.host or "?", d, sel.minBid or 0, sel.inc or 0, sel.duration or 0))

        local badges = {}
        if sel.status == "awarded"   then table.insert(badges, badgeStr("WON",       C.good)) end
        if sel.paid                  then table.insert(badges, badgeStr("PAID",      C.good)) end
        if sel.status == "cancelled" then table.insert(badges, badgeStr("CANCELLED", C.bad )) end
        if not sel.winner            then table.insert(badges, badgeStr("NO BIDS",   C.textDim)) end
        local winLine = sel.winner and (("Winner: %s -- %dg "):format(sel.winner.player, sel.winner.amount)) or "No winner "
        f.detailStats:SetText(winLine..table.concat(badges, " "))

        -- ranked unique-bidder list
        local maxByPlayer, firstAt = {}, {}
        for i, b in ipairs(sel.bids or {}) do
            if (maxByPlayer[b.player] or -1) < b.amount then
                maxByPlayer[b.player] = b.amount; firstAt[b.player] = i
            end
        end
        local rows = {}
        for p, a in pairs(maxByPlayer) do
            rows[#rows+1] = { player = p, amount = a,
                              _winner = (sel.winner and sel.winner.player == p),
                              _t = firstAt[p] }
        end
        table.sort(rows, function(x, y)
            if x.amount ~= y.amount then return x.amount > y.amount end
            return x._t < y._t
        end)
        f.detailList:SetData(rows)
    end
end
