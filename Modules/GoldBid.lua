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
        count    = sess.count,
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
    RMS.db.goldbid.pot      = RMS.db.goldbid.pot or { sales = {}, startedAt = time() }
    self.history = RMS.db.goldbid.history
end

-- host-side chat line to the whole group (works for raiders without the addon)
local function chatAnnounce(msg)
    if not RMS:InGroup() then RMS:Print(msg) return end
    SendChatMessage(msg, RMS:InRaid() and "RAID" or "PARTY")
end

-- "3x [Primordial Saronite]" for stacks, plain link otherwise
local function sessItemText(s)
    local base = s.link or s.name or "?"
    local c = tonumber(s.count) or 1
    return (c > 1) and (c.."x "..base) or base
end

-- ---------- GDKP pot ----------
function M:PotSales() return (RMS.db.goldbid.pot and RMS.db.goldbid.pot.sales) or {} end

function M:PotTotal()
    local t = 0
    for _, s in ipairs(self:PotSales()) do t = t + (s.amount or 0) end
    return t
end

function M:_RecordSale(sess)
    if not RMS.db.goldbid.gdkpMode then return end
    if not isHost() then return end
    if sess._potRecorded then return end
    if not (sess.winner and sess.awardingTo) then return end
    sess._potRecorded = true
    table.insert(RMS.db.goldbid.pot.sales, {
        itemID = sess.itemID, link = sess.link, name = sess.name,
        count = sess.count,
        player = sess.awardingTo, amount = sess.winner.amount, at = time(),
    })
    local _, _, per = self:PayoutNumbers()
    broadcast("pot", { total = self:PotTotal(), n = #self:PotSales(), share = per })
    self:RefreshPot()
end

function M:ResetPot()
    RMS.db.goldbid.pot = { sales = {}, bonus = {}, startedAt = time() }
    self._remotePot = nil
    broadcast("pot", { total = 0, n = 0 })
    RMS:Print("GDKP pot reset.")
    self:RefreshPot()
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
    local count = tonumber(opts.count) or 1
    if count < 1 then count = 1 end
    local sess = {
        id       = newSessionId(),
        host     = RMS:PlayerName(),
        itemID   = itemID,
        link     = itemLink,
        name     = name,
        count    = count,
        minBid   = opts.minBid   or cfg.minBid,
        inc      = opts.inc      or cfg.bidIncrement,
        duration = opts.duration or cfg.bidTimer,
        deadline = GetTime() + (opts.duration or cfg.bidTimer),
        bids     = {},
        status   = "open",
    }
    self.session = sess
    local payload = {
        id = sess.id, host = sess.host, item = sess.itemID, link = sess.link, name = sess.name,
        min = sess.minBid, inc = sess.inc, dur = sess.duration, cnt = sess.count,
    }
    -- addon messages cap at ~254 bytes and silently vanish over that; the
    -- comm-escaped item link is the fat part, so drop it when the message
    -- would be oversized -- receivers rebuild the link from the item id
    if #("goldbid:start:"..RMS.Comm:Encode(payload)) > 230 then
        payload.link, payload.name = nil, nil
    end
    broadcast("start", payload)
    -- some servers (Warmane included) drop addon-channel bursts; nudge a
    -- compact copy 2s later -- receivers that already have it ignore it
    local nudge = CreateFrame("Frame"); local nt = 0
    nudge:SetScript("OnUpdate", function(s, dt)
        nt = nt + dt
        if nt > 2 then
            s:SetScript("OnUpdate", nil)
            if self.session == sess and sess.status == "open" then
                local hi = self:Highest()
                broadcast("start", {
                    id = sess.id, host = sess.host, item = sess.itemID,
                    min = sess.minBid, inc = sess.inc, cnt = sess.count,
                    dur = math.max(1, math.floor(sess.deadline - GetTime())),
                    hp = hi and hi.player, ha = hi and hi.amount,
                })
            end
        end
    end)
    RMS:Print("Bid OPEN for %s -- min %dg, %ds.", sessItemText(sess), sess.minBid, sess.duration)
    chatAnnounce(("[RMS] Bidding OPEN: %s -- min %dg, +%dg steps, %ds. Type your bid in chat (e.g. %d) or use the popup."):format(
        sessItemText(sess), sess.minBid, sess.inc, sess.duration, sess.minBid))
    self:Refresh(); self:ShowPopup()
end

function M:Cancel()
    if not self.session then return end
    if not isHost() then RMS:Print("Only the session host can cancel.") return end
    broadcast("cancel", { id = self.session.id })
    self.session.status = "cancelled"
    RMS:Print("Bid CANCELLED.")
    if self._queue and #self._queue > 0 then
        RMS:Print("Cleared %d queued auction(s).", #self._queue)
        self._queue = {}
    end
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
    -- host narrates each new high bid to chat so everyone can follow along
    if isHost() then
        local hi = self:Highest()
        if hi and sess._lastAnnounced ~= hi.amount then
            sess._lastAnnounced = hi.amount
            chatAnnounce(("[RMS] %s: %dg by %s (next bid %dg+)"):format(
                sessItemText(sess), hi.amount, hi.player, hi.amount + sess.inc))
        end
    end
end

-- ---------- chat bidding (host ingests, validates, rebroadcasts) ----------
-- lets raiders WITHOUT the addon bid by typing "500" or "bid 500" in chat
local function onChatBid(msg, sender)
    if not RMS.db.goldbid.chatBids then return end
    local sess = M.session
    if not sess or sess.status ~= "open" or not isHost() then return end
    if not sender or sender == "" then return end
    local m = (msg or ""):lower():gsub(",", "")
    local amt = m:match("^%s*bid%s+(%d+)%s*g?%s*$") or m:match("^%s*(%d+)%s*g?%s*$")
    amt = tonumber(amt)
    if not amt then return end
    if amt < sess.minBid then return end
    local hi = M:Highest()
    if hi and amt < (hi.amount + sess.inc) then return end
    broadcast("cbid", { id = sess.id, p = sender, a = amt })
    M:_ApplyBid(sess.id, sender, amt)
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
        RMS:Print("Bid for %s ended -- NO BIDS.", sessItemText(sess))
        if isHost() and RMS:InRaid() then
            SendChatMessage(("[RMS] %s -- no bids."):format(sessItemText(sess)), "RAID")
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
                    sessItemText(sess), sess.winner.player, sess.winner.amount, RMS:PlayerName()),
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
    self:_RecordSale(sess)
    self:Refresh()
end

function M:MarkAwarded()
    local sess = self.session
    if not sess then return end
    if not isHost() then return end
    sess.status = "awarded"
    broadcast("award", { id = sess.id, p = sess.awardingTo })
    RMS:Print("Awarded %s to %s.", sess.link, sess.awardingTo)
    self:_RecordSale(sess)
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
            M:_StartNextQueued()
        end
    end)
end

-- split-stack queue: fire the next single-item auction once the previous
-- session has fully cleared
function M:_StartNextQueued()
    if not self._queue or #self._queue == 0 then return end
    if self.session then return end
    local nextUp = table.remove(self._queue, 1)
    RMS:Print("Starting queued auction (%d left after this one).", #self._queue)
    self:Start(nextUp.link, nextUp.opts)
end

-- ---------- comm handlers ----------
-- ask the host to resend a session we somehow missed (dropped start message,
-- late join, reload mid-auction). Throttled per session id.
local function requestSession(id, hostName)
    if not id then return end
    M._sessReq = M._sessReq or {}
    local now = GetTime()
    if M._sessReq[id] and (now - M._sessReq[id]) < 10 then return end
    M._sessReq[id] = now
    if hostName and hostName ~= RMS:PlayerName() then
        RMS.Comm:SendWhisper("goldbid", "sessreq", { id = id }, hostName)
    else
        RMS.Comm:Send("goldbid", "sessreq", { id = id })
    end
end

RMS.Comm:On("goldbid", "start", function(p, sender)
    if M.session and M.session.status == "open"
       and GetTime() < (M.session.deadline or 0) + 30 then
        return -- already in a live one
    end
    local itemID = tonumber(p.item)
    local link, name = p.link, p.name
    if (not link or link == "") and itemID then
        local n, l = GetItemInfo(itemID)
        name = name or n
        link = l or ("item:"..itemID)
    end
    local dur = tonumber(p.dur) or 30
    M.session = {
        id = p.id, host = p.host or sender,
        itemID = itemID, link = link, name = name or link,
        count = tonumber(p.cnt) or 1,
        minBid = tonumber(p.min) or 0, inc = tonumber(p.inc) or 100,
        duration = dur, deadline = GetTime() + dur,
        bids = {}, status = "open",
    }
    -- resynced sessions carry the current high bid so the popup is accurate
    if p.hp and p.ha then
        table.insert(M.session.bids, { player = p.hp, amount = tonumber(p.ha) or 0, t = GetTime() })
    end
    -- uncached item: warm the cache and repaint once the real link resolves
    if itemID and not GetItemInfo(itemID) then
        if not RMS._itemQueryTip then
            RMS._itemQueryTip = CreateFrame("GameTooltip", "RMSItemQueryTip", UIParent, "GameTooltipTemplate")
        end
        RMS._itemQueryTip:SetOwner(UIParent, "ANCHOR_NONE")
        RMS._itemQueryTip:SetHyperlink("item:"..itemID)
        local fr = CreateFrame("Frame"); local t = 0
        fr:SetScript("OnUpdate", function(s, dt)
            t = t + dt
            if t > 1 then
                s:SetScript("OnUpdate", nil)
                local n2, l2 = GetItemInfo(itemID)
                if l2 and M.session and M.session.id == p.id then
                    M.session.link, M.session.name = l2, n2
                    M:Refresh(); M:RefreshPopup()
                end
            end
        end)
    end
    RMS:Print("Bid OPENED by %s for %s.", M.session.host, M.session.link)
    M:Refresh(); M:ShowPopup()
end)

-- ---------- GDKP budgets (players share, leadership sees) ----------
-- only leader / assist / master looter get replies to a budget request
local function senderCanSeeBudgets(sender)
    local n = GetNumRaidMembers()
    if n == 0 then return true end  -- party/solo testing
    local method, _, raidId = GetLootMethod()
    if method == "master" and raidId and raidId > 0
       and UnitName("raid"..raidId) == sender then
        return true
    end
    for i = 1, n do
        local name, rank = GetRaidRosterInfo(i)
        if name == sender then return (rank or 0) >= 1 end
    end
    return false
end

RMS.Comm:On("goldbid", "budgetreq", function(_, sender)
    if sender == RMS:PlayerName() then return end
    if not senderCanSeeBudgets(sender) then return end
    RMS.Comm:SendWhisper("goldbid", "budget", {
        b = (RMS.charDB and tonumber(RMS.charDB.gdkpBudget)) or 0,
        g = math.floor(GetMoney() / 10000),
    }, sender)
end)

RMS.Comm:On("goldbid", "budget", function(p, sender)
    M._budgets = M._budgets or {}
    M._budgets[sender] = { b = tonumber(p.b) or 0, g = tonumber(p.g) or 0 }
    M:RefreshPayout()
end)

-- host answers a resync request with a compact start (remaining time + high)
-- p.id == "any" means "whatever auction you're running" (chat-beacon path)
RMS.Comm:On("goldbid", "sessreq", function(p, sender)
    local sess = M.session
    if not sess or not isHost() or sess.status ~= "open" then return end
    if sess.id ~= p.id and p.id ~= "any" then return end
    if sender == RMS:PlayerName() then return end
    local hi = M:Highest()
    RMS.Comm:SendWhisper("goldbid", "start", {
        id = sess.id, host = sess.host, item = sess.itemID,
        min = sess.minBid, inc = sess.inc, cnt = sess.count,
        dur = math.max(1, math.floor(sess.deadline - GetTime())),
        hp = hi and hi.player, ha = hi and hi.amount,
    }, sender)
end)

RMS.Comm:On("goldbid", "bid", function(p, sender)
    if not M.session or M.session.id ~= p.id then
        requestSession(p.id)  -- bid for a session we missed: fetch it
        return
    end
    if (p.p or sender) ~= sender then return end -- prevent forging
    M:_ApplyBid(p.id, p.p or sender, tonumber(p.a))
end)

-- chat bid relayed by the host (host already validated it)
RMS.Comm:On("goldbid", "cbid", function(p, sender)
    if not M.session or M.session.id ~= p.id then
        requestSession(p.id, sender)  -- sender IS the host here
        return
    end
    if M.session.host ~= sender then return end
    if not p.p then return end
    M:_ApplyBid(p.id, p.p, tonumber(p.a))
end)

-- pot total pushed by the host so everyone sees the running GDKP pot
RMS.Comm:On("goldbid", "pot", function(p, sender)
    if sender == RMS:PlayerName() then return end
    M._remotePot = { total = tonumber(p.total) or 0, n = tonumber(p.n) or 0,
                     share = tonumber(p.share), host = sender }
    M:RefreshPot()
end)

RMS.Comm:On("goldbid", "extend", function(p, sender)
    if not M.session or M.session.id ~= p.id then
        requestSession(p.id, sender)
        return
    end
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

-- Group chat does double duty: the host reads typed bids from it, and
-- everyone else treats the host's "[RMS] Bidding OPEN" announcement as a
-- session beacon -- chat is delivered reliably even on servers that drop
-- addon-channel messages, so this guarantees the popup appears on start.
local function onGroupChat(msg, sender)
    if msg and msg:find("^%[RMS%] Bidding OPEN") and sender ~= RMS:PlayerName() then
        if not (M.session and M.session.status == "open") then
            requestSession("any", sender)
        end
    end
    onChatBid(msg, sender)
end

M.events = {
    TRADE_SHOW           = function(self) onTradeShow() end,
    TRADE_MONEY_CHANGED  = function(self) onTradeMoneyChanged() end,
    TRADE_ACCEPT_UPDATE  = function(self) onTradeMoneyChanged() end,
    UI_INFO_MESSAGE      = function(self, _, msg) onUiInfoMessage(_, msg) end,
    TRADE_CLOSED         = function(self) onTradeClosed() end,
    TRADE_REQUEST_CANCEL = function(self) onTradeClosed() end,
    -- chat bidding + session beacon (see onGroupChat)
    CHAT_MSG_RAID          = function(self, _, msg, sender) onGroupChat(msg, sender) end,
    CHAT_MSG_RAID_LEADER   = function(self, _, msg, sender) onGroupChat(msg, sender) end,
    CHAT_MSG_PARTY         = function(self, _, msg, sender) onGroupChat(msg, sender) end,
    CHAT_MSG_PARTY_LEADER  = function(self, _, msg, sender) onGroupChat(msg, sender) end,
    CHAT_MSG_WHISPER       = function(self, _, msg, sender) onChatBid(msg, sender) end,
}

-- ---------- timer driver ----------
local timer = CreateFrame("Frame")
timer:SetScript("OnUpdate", function()
    local sess = M.session
    if not sess or sess.status ~= "open" then return end
    -- one "10s left" chat nudge for the non-addon bidders
    local rem = sess.deadline - GetTime()
    if isHost() and not sess._warn10 and rem <= 10 and rem > 0 then
        sess._warn10 = true
        local hi = M:Highest()
        chatAnnounce(("[RMS] 10s left on %s! %s"):format(sessItemText(sess),
            hi and ("Current: %dg by %s."):format(hi.amount, hi.player) or "No bids yet."))
    end
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
    hostLabel:SetText("Host: paste an item link, set the prices, then Start:")

    local linkEdit = Skin:EditBox(panel, 380, 22)
    linkEdit:SetPoint("TOPLEFT", hostLabel, "BOTTOMLEFT", 0, -4)
    hooksecurefunc("ChatEdit_InsertLink", function(text)
        if linkEdit:HasFocus() then linkEdit:SetText(text); return true end
    end)

    -- Toolbar row 2: per-auction start price / increment / timer / stack + Start
    local function priceEdit(label, anchor, w, default)
        local e = Skin:EditBox(panel, w, 22)
        if anchor then e:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
        else e:SetPoint("TOPLEFT", linkEdit, "BOTTOMLEFT", 0, -20) end
        e:SetNumeric(true)
        e:SetText(tostring(default or 0))
        -- make sure clicks always land: sit above siblings and force focus
        e:SetFrameLevel(panel:GetFrameLevel() + 5)
        e:SetScript("OnMouseDown", function(s) s:SetFocus() end)
        local lbl = panel:CreateFontString(nil, "OVERLAY")
        Skin:Font(lbl, 9, false)
        lbl:SetTextColor(unpack(C.textDim))
        lbl:SetPoint("BOTTOMLEFT", e, "TOPLEFT", 2, 2)
        lbl:SetText(label)
        return e
    end
    local cfgGB    = RMS.db.goldbid
    local minEdit  = priceEdit("Start (g)",  nil,      62, cfgGB.minBid)
    local incEdit  = priceEdit("+Inc",       minEdit,  54, cfgGB.bidIncrement)
    local durEdit  = priceEdit("Sec",        incEdit,  44, cfgGB.bidTimer)
    local stackEdit = priceEdit("Stack",     durEdit,  40, 1)

    local startBtn  = Skin:Button(panel, "Start Bid", 84, 22)
    startBtn:SetPoint("LEFT", stackEdit, "RIGHT", 10, 0)
    startBtn:SetScript("OnMouseUp", function()
        local link = linkEdit:GetText():match("(|c%x+|Hitem:.-|h.-|h|r)")
        if not link then RMS:Print("Paste a real item link first.") return end
        self:Start(link, {
            minBid   = tonumber(minEdit:GetText()),
            inc      = tonumber(incEdit:GetText()),
            duration = tonumber(durEdit:GetText()),
            count    = tonumber(stackEdit:GetText()),
        })
        linkEdit:SetText("")
        stackEdit:SetText("1")
    end)

    -- Toolbar row 3: session control buttons
    local cancelBtn = Skin:Button(panel, "Cancel", 70, 22)
    cancelBtn:SetPoint("TOPLEFT", minEdit, "BOTTOMLEFT", 0, -6)
    cancelBtn:SetScript("OnMouseUp", function() self:Cancel() end)

    local closeBtn = Skin:Button(panel, "Close Now", 88, 22)
    closeBtn:SetPoint("LEFT", cancelBtn, "RIGHT", 6, 0)
    closeBtn:SetScript("OnMouseUp", function() self:CloseNow() end)

    local extendBtn = Skin:Button(panel, "+15s", 50, 22)
    extendBtn:SetPoint("LEFT", closeBtn, "RIGHT", 6, 0)
    extendBtn:SetScript("OnMouseUp", function() self:Extend(15) end)

    -- GDKP toggle, right where you run the auctions
    local gdkpCb = Skin:CheckBox(panel, "GDKP mode")
    gdkpCb:SetWidth(100)
    gdkpCb:SetPoint("LEFT", extendBtn, "RIGHT", 12, 0)
    gdkpCb:SetChecked(RMS.db.goldbid.gdkpMode)
    gdkpCb.OnValueChanged = function(_, v)
        RMS.db.goldbid.gdkpMode = v and true or false
        local ml = RMS:GetModule("masterloot")
        if ml and ml.win and ml.win:IsShown() then ml:RefreshWindow() end
        self:RefreshPot()
    end
    Skin:AttachTooltip(gdkpCb.box, "GDKP mode",
        { "Track every sale into the raid pot and add a Start Bid button to the Master Loot window. Same setting as in the Settings tab." })

    -- re-read shared settings when the tab is shown
    panel:SetScript("OnShow", function()
        gdkpCb:SetChecked(RMS.db.goldbid.gdkpMode)
        self:Refresh()
    end)

    -- Toolbar row 4: my GDKP budget (per character, whispered to leadership
    -- on request -- shown in the host's payout window)
    local budgetLbl = panel:CreateFontString(nil, "OVERLAY"); Skin:Font(budgetLbl, 10, false)
    budgetLbl:SetTextColor(unpack(C.textDim))
    budgetLbl:SetPoint("TOPLEFT", cancelBtn, "BOTTOMLEFT", 0, -12)
    budgetLbl:SetText("My GDKP budget (g):")

    local budgetEdit = Skin:EditBox(panel, 70, 20)
    budgetEdit:SetPoint("LEFT", budgetLbl, "RIGHT", 6, 0)
    budgetEdit:SetNumeric(true)
    budgetEdit:SetFrameLevel(panel:GetFrameLevel() + 5)
    budgetEdit:SetScript("OnMouseDown", function(s) s:SetFocus() end)
    budgetEdit:SetText(tostring((RMS.charDB and tonumber(RMS.charDB.gdkpBudget)) or 0))

    -- clamp to carried gold, save, return the value
    local function saveBudget()
        local gold = math.floor(GetMoney() / 10000)
        local v = tonumber(budgetEdit:GetText()) or 0
        if v > gold then
            v = gold
            RMS:Print("Budget capped at your carried gold (%dg).", gold)
        end
        RMS.charDB.gdkpBudget = v
        budgetEdit:SetText(tostring(v))
        return v, gold
    end
    budgetEdit:SetScript("OnEditFocusLost", function(s)
        saveBudget()
        s:SetBackdropBorderColor(unpack(C.border))
    end)

    local budgetSetBtn = Skin:Button(panel, "Set", 44, 20)
    budgetSetBtn:SetPoint("LEFT", budgetEdit, "RIGHT", 6, 0)
    budgetSetBtn:SetScript("OnMouseUp", function()
        budgetEdit:ClearFocus()
        local v, gold = saveBudget()
        -- push straight to raid leadership (leader/assists/ML) by whisper
        local payload = { b = v, g = gold }
        local sent = 0
        local n = GetNumRaidMembers()
        if n > 0 then
            local mlName
            local method, _, raidId = GetLootMethod()
            if method == "master" and raidId and raidId > 0 then
                mlName = UnitName("raid"..raidId)
            end
            for i = 1, n do
                local name, rank = GetRaidRosterInfo(i)
                if name and name ~= RMS:PlayerName()
                   and ((rank or 0) >= 1 or name == mlName) then
                    RMS.Comm:SendWhisper("goldbid", "budget", payload, name)
                    sent = sent + 1
                end
            end
        elseif RMS:InGroup() then
            for i = 1, GetNumPartyMembers() do
                if UnitIsPartyLeader and UnitIsPartyLeader("party"..i) then
                    RMS.Comm:SendWhisper("goldbid", "budget", payload, UnitName("party"..i))
                    sent = sent + 1
                end
            end
        end
        RMS:Print("GDKP budget set: %dg%s.", v,
            sent > 0 and (" -- sent to leadership ("..sent..")") or "")
    end)
    Skin:AttachTooltip(budgetSetBtn, "Set budget",
        {"Saves your budget (capped at your carried gold) and whispers it to the raid leadership."})

    local budgetHint = panel:CreateFontString(nil, "OVERLAY"); Skin:Font(budgetHint, 9, false)
    budgetHint:SetTextColor(unpack(C.textDim))
    budgetHint:SetPoint("LEFT", budgetSetBtn, "RIGHT", 8, 0)
    budgetHint:SetText("shared only with raid leadership")

    -- Active session panel
    local actHdr = Skin:Header(panel, "Active Session")
    actHdr:SetPoint("TOPLEFT", budgetLbl, "BOTTOMLEFT", 0, -18)
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

    -- GDKP pot summary (right column, above results)
    local potHdr = Skin:Header(panel, "GDKP Pot")
    potHdr:SetPoint("TOPLEFT", actHdr, "TOPRIGHT", 8, 0)
    potHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    local payoutBtn = Skin:Button(potHdr, "Payout", 70, 20)
    payoutBtn:SetPoint("RIGHT", -4, 0)
    payoutBtn:SetScript("OnMouseUp", function() M:OpenPayout() end)
    Skin:AttachTooltip(payoutBtn, "GDKP Payout",
        {"Sales list, organizer cut and per-raider split calculator, announce to raid."})

    local potFs = potHdr:CreateFontString(nil, "OVERLAY")
    Skin:Font(potFs, 12, true)
    potFs:SetTextColor(unpack(C.accent))
    potFs:SetPoint("RIGHT", payoutBtn, "LEFT", -10, 0)

    -- recent results column (right)
    local logHdr = Skin:Header(panel, "Recent Results")
    logHdr:SetPoint("TOPLEFT", potHdr, "BOTTOMLEFT", 0, -6)
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
        r.item:SetText(sessItemText(item))
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
        linkEdit = linkEdit, minEdit = minEdit, incEdit = incEdit, durEdit = durEdit,
        actBody = actBody, itemFs = itemFs, timerFs = timerFs, highFs = highFs,
        bidEdit = bidEdit, bidBtn = bidBtn, incBtn = incBtn, minBtn = minBtn,
        paidBtn = paidBtn, awardBtn = awardBtn, nextBtn = nextBtn,
        bidsList = bidsList, logList = logList, potFs = potFs,
    }
    self:Refresh()
    return panel
end

function M:RefreshPot()
    if self._ui and self._ui.potFs then
        local txt
        if #self:PotSales() > 0 then
            txt = ("%dg  (%d sales)"):format(self:PotTotal(), #self:PotSales())
        elseif self._remotePot and self._remotePot.n > 0 then
            txt = ("%dg  (%d sales @ %s)"):format(self._remotePot.total, self._remotePot.n, self._remotePot.host)
        else
            txt = RMS.db.goldbid.gdkpMode and "0g" or "|cff888888GDKP mode off|r"
        end
        self._ui.potFs:SetText(txt)
    end
    if self.payoutWin and self.payoutWin:IsShown() then self:RefreshPayout() end
    self:RefreshPotInfo()
end

function M:RefreshTimerOnly()
    -- popup first: it must keep ticking even if this client never opened
    -- the Gold Bid tab (self._ui only exists once the tab is built)
    if self.popup and self.popup:IsShown() then
        self:RefreshPopup()
    end
    if not (self._ui and self.session) then return end
    if self.session.status == "open" then
        local rem = math.max(0, self.session.deadline - GetTime())
        self._ui.timerFs:SetText(string.format("%0.1fs", rem))
        if rem <= 5 then self._ui.timerFs:SetTextColor(unpack(RMS.Skin.COLOR.bad))
        else            self._ui.timerFs:SetTextColor(unpack(RMS.Skin.COLOR.accent)) end
    end
end

function M:Refresh()
    -- popup repaints on every bid/state change, tab or no tab
    if self.popup and self.popup:IsShown() then self:RefreshPopup() end
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
        self._ui.itemFs:SetText(sessItemText(sess))
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
    self:RefreshPot()
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

    -- all-in: bid every gold piece you're carrying
    local allin = Skin:Button(f, "All In", 56, 22)
    allin:SetPoint("LEFT", inc, "RIGHT", 4, 0)
    allin:SetScript("OnMouseUp", function()
        local sess = M.session
        if not sess or sess.status ~= "open" then return end
        local gold = math.floor(GetMoney() / 10000)
        local hi = M:Highest()
        local needed = math.max(sess.minBid, hi and (hi.amount + sess.inc) or sess.minBid)
        if gold < needed then
            RMS:Print("All-in would be %dg but the bid needs at least %dg.", gold, needed)
            return
        end
        M:PlaceBid(gold)
    end)
    Skin:AttachTooltip(allin, "All In",
        {"Bid all the gold in your bags (must beat the current bid + increment)."})

    local close = Skin:Button(f, "x", 22, 22)
    close:SetPoint("TOPRIGHT", -4, -4)
    close.text:SetTextColor(unpack(C.bad))
    close:SetScript("OnMouseUp", function() f:Hide() end)

    f.title, f.item, f.timer, f.high, f.edit = title, item, timer, high, edit
    f.bidBtn, f.incBtn, f.allBtn = bid, inc, allin
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
    f.item:SetText(sessItemText(sess))

    -- bid controls only exist while the auction is live
    local function bidControls(shown)
        if shown then
            f.edit:Show(); f.bidBtn:Show(); f.incBtn:Show(); f.allBtn:Show()
            f.edit:Enable()
        else
            f.edit:ClearFocus()
            f.edit:Hide(); f.bidBtn:Hide(); f.incBtn:Hide(); f.allBtn:Hide()
        end
    end

    if sess.status == "open" then
        local rem = math.max(0, sess.deadline - GetTime())
        f.timer:SetText(string.format("%0.1fs", rem))
        f.timer:SetTextColor(unpack(rem <= 5 and RMS.Skin.COLOR.bad or RMS.Skin.COLOR.accent))
        local hi = M:Highest()
        f.high:SetText(hi and (("High: %s -- %dg"):format(hi.player, hi.amount))
                          or ("Min %dg, +%dg"):format(sess.minBid, sess.inc))
        bidControls(true)
    elseif sess.status == "awaiting_pay" then
        f.timer:SetText("WINNER")
        f.timer:SetTextColor(unpack(RMS.Skin.COLOR.warn))
        local w = sess.winner
        f.high:SetText(w and (("%s -- %dg -- trade %s"):format(w.player, w.amount, sess.host)) or "")
        bidControls(false)
    else
        f.high:SetText(sess.status:upper())
        f.timer:SetText("")
        bidControls(false)
    end
end

-- ====================================================================
-- Start dialog (used by the Master Loot window's Start Bid button)
-- ====================================================================
function M:OpenStartDialog(itemLink, stackCount)
    if not itemLink then return end
    local Skin = RMS.Skin
    local C    = Skin.COLOR

    local f = self.startDlg
    if not f then
        f = CreateFrame("Frame", "RaidMasterSuiteBidStart", UIParent)
        f:SetSize(380, 178)
        f:SetPoint("CENTER", 0, 120)
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:EnableMouse(true); f:SetMovable(true); f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop",  f.StopMovingOrSizing)
        Skin:SetBackdrop(f, C.bgMain, C.accent)
        tinsert(UISpecialFrames, "RaidMasterSuiteBidStart")

        local title = f:CreateFontString(nil, "OVERLAY"); Skin:Font(title, 13, true)
        title:SetTextColor(unpack(C.accent))
        title:SetPoint("TOP", 0, -8); title:SetText("START GOLD BID")

        local item = f:CreateFontString(nil, "OVERLAY"); Skin:Font(item, 12, true)
        item:SetPoint("TOP", title, "BOTTOM", 0, -6)
        item:SetWidth(360); item:SetJustifyH("CENTER")
        item:SetWordWrap(false); item:SetNonSpaceWrap(false)
        f.itemFs = item

        local function dlgEdit(label, x, w)
            local e = Skin:EditBox(f, w, 22)
            e:SetPoint("TOPLEFT", x, -80)
            e:SetNumeric(true)
            -- clicks must always land: above the draggable dialog, forced focus
            e:SetFrameLevel(f:GetFrameLevel() + 5)
            e:SetScript("OnMouseDown", function(s) s:SetFocus() end)
            local lbl = f:CreateFontString(nil, "OVERLAY"); Skin:Font(lbl, 9, false)
            lbl:SetTextColor(unpack(C.textDim))
            lbl:SetPoint("BOTTOMLEFT", e, "TOPLEFT", 2, 2)
            lbl:SetText(label)
            return e
        end
        f.minEdit   = dlgEdit("Start price (g)", 14,  80)
        f.incEdit   = dlgEdit("+Increment",      108, 76)
        f.durEdit   = dlgEdit("Seconds",         198, 66)
        f.stackEdit = dlgEdit("Stack",           278, 56)

        -- auction each item of the stack separately, one after another
        f.splitCb = Skin:CheckBox(f, "Split stack into separate bids")
        f.splitCb:SetWidth(240)
        f.splitCb:SetPoint("TOPLEFT", 14, -112)
        Skin:AttachTooltip(f.splitCb.box, "Split stack",
            {"Runs one auction per item in the stack, back to back. The next one auto-starts a few seconds after each winner is settled."})

        local go = Skin:Button(f, "Start Bid", 100, 24)
        go:SetPoint("BOTTOMLEFT", 14, 10)
        go:SetScript("OnMouseUp", function()
            local cnt = tonumber(f.stackEdit:GetText()) or 1
            local base = {
                minBid   = tonumber(f.minEdit:GetText()),
                inc      = tonumber(f.incEdit:GetText()),
                duration = tonumber(f.durEdit:GetText()),
            }
            if f.splitCb:GetChecked() and cnt > 1 then
                M._queue = M._queue or {}
                for _ = 2, cnt do
                    table.insert(M._queue, { link = f._link, opts = {
                        minBid = base.minBid, inc = base.inc,
                        duration = base.duration, count = 1,
                    }})
                end
                base.count = 1
                RMS:Print("Queued %d more single-item auctions for %s.", cnt - 1, f._link)
            else
                base.count = cnt
            end
            M:Start(f._link, base)
            f:Hide()
        end)

        local cancel = Skin:Button(f, "Cancel", 80, 24)
        cancel:SetPoint("LEFT", go, "RIGHT", 8, 0)
        cancel:SetScript("OnMouseUp", function() f:Hide() end)

        self.startDlg = f
    end

    f._link = itemLink
    local cnt = tonumber(stackCount) or 1
    f.splitCb:SetChecked(false)
    f.itemFs:SetText((cnt > 1 and (cnt.."x ") or "")..itemLink)
    local cfg = RMS.db.goldbid
    f.minEdit:SetText(tostring(cfg.minBid or 100))
    f.incEdit:SetText(tostring(cfg.bidIncrement or 100))
    f.durEdit:SetText(tostring(cfg.bidTimer or 30))
    f.stackEdit:SetText(tostring(cnt))
    f:Show()
end

-- ====================================================================
-- GDKP payout window (sales list + cut/bonus/split calculator)
-- ====================================================================
local function GB_CLASS_COLOR(token)
    local c = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if c then return ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) end
    return "|cffffffff"
end

-- everyone grouped now, plus already-flagged players who left the group
local function payoutRoster()
    local names, seen = {}, {}
    local n = GetNumRaidMembers()
    if n > 0 then
        for i = 1, n do
            local nm, _, _, _, _, cls = GetRaidRosterInfo(i)
            if nm then names[#names+1] = { name = nm, class = cls }; seen[nm] = true end
        end
    else
        local me = RMS:PlayerName()
        local _, myTok = UnitClass("player")
        names[#names+1] = { name = me, class = myTok }; seen[me] = true
        for i = 1, GetNumPartyMembers() do
            local nm = UnitName("party"..i)
            if nm then
                local _, tk = UnitClass("party"..i)
                names[#names+1] = { name = nm, class = tk }; seen[nm] = true
            end
        end
    end
    local bonus = (RMS.db.goldbid.pot and RMS.db.goldbid.pot.bonus) or {}
    for nm in pairs(bonus) do
        if not seen[nm] then names[#names+1] = { name = nm } end
    end
    table.sort(names, function(a, b) return a.name < b.name end)
    return names
end

local function bonusFlags()
    RMS.db.goldbid.pot.bonus = RMS.db.goldbid.pot.bonus or {}
    return RMS.db.goldbid.pot.bonus
end

-- who may run the payout tools (cut/bonus/reset/announce)
local function canManagePot()
    if not RMS:InGroup() then return true end  -- solo testing
    if RMS:InRaid() then return RMS:IsAssist() or RMS:IsMasterLooter() end
    return (UnitIsPartyLeader and UnitIsPartyLeader("player")) or RMS:IsMasterLooter()
end

-- read-only pot view for regular raiders: total + their share so far
function M:OpenPotInfo()
    local Skin = RMS.Skin
    local C    = Skin.COLOR
    local f = self.potInfoWin
    if not f then
        f = CreateFrame("Frame", "RaidMasterSuiteGDKPPotInfo", UIParent)
        f:SetSize(300, 130)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:EnableMouse(true); f:SetMovable(true); f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop",  f.StopMovingOrSizing)
        Skin:SetBackdrop(f, C.bgMain, C.accent)
        tinsert(UISpecialFrames, "RaidMasterSuiteGDKPPotInfo")

        local title = f:CreateFontString(nil, "OVERLAY"); Skin:Font(title, 14, true)
        title:SetTextColor(unpack(C.accent))
        title:SetPoint("TOP", 0, -8); title:SetText("GDKP POT")

        local close = Skin:CloseButton(f); close:SetPoint("TOPRIGHT", -4, -4)
        close:SetScript("OnClick", function() f:Hide() end)

        f.totalFs = f:CreateFontString(nil, "OVERLAY"); Skin:Font(f.totalFs, 13, true)
        f.totalFs:SetTextColor(unpack(C.accent))
        f.totalFs:SetPoint("TOP", 0, -36)

        f.shareFs = f:CreateFontString(nil, "OVERLAY"); Skin:Font(f.shareFs, 12, false)
        f.shareFs:SetTextColor(unpack(C.text))
        f.shareFs:SetPoint("TOP", f.totalFs, "BOTTOM", 0, -8)

        local note = f:CreateFontString(nil, "OVERLAY"); Skin:Font(note, 9, false)
        note:SetTextColor(unpack(C.textDim))
        note:SetPoint("BOTTOM", 0, 12); note:SetWidth(280)
        note:SetText("Estimate before bonuses. Final payouts are announced by the leader.")

        self.potInfoWin = f
    end
    f:Show()
    self:RefreshPotInfo()
end

function M:RefreshPotInfo()
    local f = self.potInfoWin
    if not f or not f:IsShown() then return end
    local total, n, share
    if #self:PotSales() > 0 then
        total, n = self:PotTotal(), #self:PotSales()
        local _, _, per = self:PayoutNumbers()
        share = per
    elseif self._remotePot then
        total, n, share = self._remotePot.total, self._remotePot.n, self._remotePot.share
    else
        total, n = 0, 0
    end
    f.totalFs:SetText(("Pot: %dg  (%d sale%s)"):format(total or 0, n or 0, n == 1 and "" or "s"))
    f.shareFs:SetText(share and share > 0 and ("Your share so far: ~%dg"):format(share)
                      or "Your share: |cff888888nothing sold yet|r")
end

function M:OpenPayout()
    -- regular raiders only get the read-only pot summary
    if not canManagePot() then self:OpenPotInfo() return end
    local Skin = RMS.Skin
    local C    = Skin.COLOR

    local f = self.payoutWin
    if not f then
        f = CreateFrame("Frame", "RaidMasterSuiteGDKPPayout", UIParent)
        f:SetSize(660, 470)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:EnableMouse(true); f:SetMovable(true); f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop",  f.StopMovingOrSizing)
        Skin:SetBackdrop(f, C.bgMain, C.borderHi)
        tinsert(UISpecialFrames, "RaidMasterSuiteGDKPPayout")

        local title = f:CreateFontString(nil, "OVERLAY"); Skin:Font(title, 14, true)
        title:SetTextColor(unpack(C.accent))
        title:SetPoint("TOP", 0, -8); title:SetText("GDKP PAYOUT")

        local close = Skin:CloseButton(f); close:SetPoint("TOPRIGHT", -4, -4)
        close:SetScript("OnClick", function() f:Hide() end)

        local salesLbl = f:CreateFontString(nil, "OVERLAY"); Skin:Font(salesLbl, 11, true)
        salesLbl:SetTextColor(unpack(C.accent))
        salesLbl:SetPoint("TOPLEFT", 10, -34)
        salesLbl:SetText("Sales")

        local bonusLbl = f:CreateFontString(nil, "OVERLAY"); Skin:Font(bonusLbl, 11, true)
        bonusLbl:SetTextColor(unpack(C.accent))
        bonusLbl:SetPoint("TOPLEFT", 366, -34)
        bonusLbl:SetText("Players  |cff888888(click = bonus, budget/gold)|r")

        -- left: sales list
        local function buildSaleRow(parent)
            local r = CreateFrame("Frame", nil, parent)
            r:SetHeight(20)
            local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
            local item = r:CreateFontString(nil, "OVERLAY"); Skin:Font(item, 11, false)
            item:SetPoint("LEFT", 6, 0); item:SetWidth(180)
            item:SetJustifyH("LEFT"); item:SetWordWrap(false); item:SetNonSpaceWrap(false)
            r.item = item
            local who = r:CreateFontString(nil, "OVERLAY"); Skin:Font(who, 10, false)
            who:SetPoint("LEFT", item, "RIGHT", 6, 0); who:SetPoint("RIGHT", -60, 0)
            who:SetJustifyH("LEFT"); who:SetTextColor(unpack(C.textDim)); r.who = who
            local amt = r:CreateFontString(nil, "OVERLAY"); Skin:Font(amt, 11, true)
            amt:SetPoint("RIGHT", -8, 0); amt:SetTextColor(unpack(C.accent)); r.amt = amt
            return r
        end
        local function updSaleRow(r, item, idx, alt)
            if not item then return end
            r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
            r.item:SetText(sessItemText(item))
            r.who:SetText(item.player or "?")
            r.amt:SetText((item.amount or 0).."g")
        end
        local sales = Skin:ScrollList(f, 20, buildSaleRow, updSaleRow)
        sales:SetPoint("TOPLEFT", 8, -50)
        sales:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", 356, 168)
        f.salesList = sales

        -- right: bonus player picker
        local function buildBonusRow(parent)
            local r = CreateFrame("Button", nil, parent)
            r:SetHeight(20)
            local bg = r:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(Skin.TEX_WHITE); r.bg = bg
            local hl = r:CreateTexture(nil, "BORDER"); hl:SetAllPoints(); hl:SetTexture(Skin.TEX_WHITE)
            hl:SetVertexColor(C.good[1], C.good[2], C.good[3], 0.20); hl:Hide(); r.hl = hl
            local tag = r:CreateFontString(nil, "OVERLAY"); Skin:Font(tag, 10, true)
            tag:SetPoint("RIGHT", -6, 0); tag:SetTextColor(unpack(C.good)); r.tag = tag
            local bud = r:CreateFontString(nil, "OVERLAY"); Skin:Font(bud, 10, false)
            bud:SetPoint("RIGHT", -50, 0); r.bud = bud
            local nameFs = r:CreateFontString(nil, "OVERLAY"); Skin:Font(nameFs, 11, false)
            nameFs:SetPoint("LEFT", 6, 0); nameFs:SetPoint("RIGHT", bud, "LEFT", -6, 0)
            nameFs:SetJustifyH("LEFT"); nameFs:SetWordWrap(false); nameFs:SetNonSpaceWrap(false)
            r.name = nameFs
            return r
        end
        local function updBonusRow(r, item, idx, alt)
            if not item then return end
            r.bg:SetVertexColor(alt and 0.10 or 0.13, alt and 0.10 or 0.13, alt and 0.12 or 0.15, 0.6)
            r.name:SetText(GB_CLASS_COLOR(item.class)..item.name.."|r")
            -- budget/carried gold, whispered by addon users to leadership
            local info = M._budgets and M._budgets[item.name]
            if info then
                r.bud:SetText(("|cffffd070%d|r/|cff60ff60%dg|r"):format(info.b or 0, info.g or 0))
            else
                r.bud:SetText("|cff777777no addon|r")
            end
            local on = bonusFlags()[item.name]
            if on then r.hl:Show(); r.tag:SetText("BONUS") else r.hl:Hide(); r.tag:SetText("") end
            r:SetScript("OnClick", function()
                if not canManagePot() then return end
                local flags = bonusFlags()
                flags[item.name] = (not flags[item.name]) and true or nil
                M:RefreshPayout()
            end)
        end
        local bonusList = Skin:ScrollList(f, 20, buildBonusRow, updBonusRow)
        bonusList:SetPoint("TOPLEFT", 364, -50)
        bonusList:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 168)
        f.bonusList = bonusList

        local totalFs = f:CreateFontString(nil, "OVERLAY"); Skin:Font(totalFs, 13, true)
        totalFs:SetTextColor(unpack(C.accent))
        totalFs:SetPoint("TOPLEFT", 10, -310)
        f.totalFs = totalFs

        -- calculator inputs
        local function calcEdit(label, x, w, default)
            local e = Skin:EditBox(f, w, 22)
            e:SetPoint("TOPLEFT", x, -352)
            e:SetNumeric(true)
            e:SetText(tostring(default))
            local lbl = f:CreateFontString(nil, "OVERLAY"); Skin:Font(lbl, 9, false)
            lbl:SetTextColor(unpack(C.textDim))
            lbl:SetPoint("BOTTOMLEFT", e, "TOPLEFT", 2, 2)
            lbl:SetText(label)
            return e
        end
        f.cutEdit   = calcEdit("Organizer cut %", 10,  70, RMS.db.goldbid.cutPercent or 15)
        f.bonusEdit = calcEdit("Bonus pool %",    100, 70, RMS.db.goldbid.bonusPercent or 5)
        f.countEdit = calcEdit("Split between",   190, 70, 25)

        f.cutEdit:SetScript("OnTextChanged", function(s)
            RMS.db.goldbid.cutPercent = tonumber(s:GetText()) or 0
            M:RefreshPayout()
        end)
        f.bonusEdit:SetScript("OnTextChanged", function(s)
            RMS.db.goldbid.bonusPercent = tonumber(s:GetText()) or 0
            M:RefreshPayout()
        end)
        f.countEdit:SetScript("OnTextChanged", function() M:RefreshPayout() end)

        local resultFs = f:CreateFontString(nil, "OVERLAY"); Skin:Font(resultFs, 12, true)
        resultFs:SetTextColor(unpack(C.text))
        resultFs:SetPoint("TOPLEFT", 10, -396)
        resultFs:SetPoint("RIGHT", -10, 0)
        resultFs:SetJustifyH("LEFT"); resultFs:SetWordWrap(true)
        f.resultFs = resultFs

        local annBtn = Skin:Button(f, "Announce to Raid", 130, 24)
        annBtn:SetPoint("BOTTOMLEFT", 10, 10)
        annBtn:SetScript("OnMouseUp", function()
            local total, cut, per, n, bonusPool, perBonus, bonusNames = M:PayoutNumbers()
            if total <= 0 then RMS:Print("Pot is empty.") return end
            chatAnnounce(("[RMS] GDKP pot: %dg over %d sales."):format(total, #M:PotSales()))
            if bonusPool > 0 then
                local names = table.concat(bonusNames, ", ")
                if #names > 120 then names = ("%d players"):format(#bonusNames) end
                chatAnnounce(("[RMS] Cut %d%% = %dg. Bonus %d%% = %dg to %s (%dg each)."):format(
                    RMS.db.goldbid.cutPercent or 0, cut,
                    RMS.db.goldbid.bonusPercent or 0, bonusPool, names, perBonus))
            else
                chatAnnounce(("[RMS] Organizer cut %d%% = %dg."):format(RMS.db.goldbid.cutPercent or 0, cut))
            end
            chatAnnounce(("[RMS] Payout: %dg each to %d raiders. Collect from %s after the raid."):format(
                per, n, RMS:PlayerName()))
        end)

        local resetBtn = Skin:Button(f, "Reset Pot", 90, 24)
        resetBtn:SetPoint("LEFT", annBtn, "RIGHT", 8, 0)
        resetBtn:SetScript("OnMouseUp", function() M:ResetPot() end)
        Skin:AttachTooltip(resetBtn, "Reset Pot",
            {"Clears all recorded sales and bonus picks. Do this at the start of a new raid."})

        self.payoutWin = f
    end

    -- sensible default: current group size
    local n = GetNumRaidMembers()
    if n == 0 then n = GetNumPartyMembers() + 1 end
    if n > 1 and not f.countEdit:HasFocus() then f.countEdit:SetText(tostring(n)) end

    -- budgets: seed our own, then ask addon users to whisper theirs
    -- (only leader / assist / ML get replies)
    self._budgets = { [RMS:PlayerName()] = {
        b = (RMS.charDB and tonumber(RMS.charDB.gdkpBudget)) or 0,
        g = math.floor(GetMoney() / 10000),
    }}
    if RMS:InGroup() then RMS.Comm:Send("goldbid", "budgetreq", {}) end

    f:Show()
    self:RefreshPayout()
end

-- total -> organizer cut -> bonus pool (split by picked players) -> even split
function M:PayoutNumbers()
    local total = self:PotTotal()
    local pct   = tonumber(RMS.db.goldbid.cutPercent) or 0
    local bpct  = tonumber(RMS.db.goldbid.bonusPercent) or 0
    local n = self.payoutWin and tonumber(self.payoutWin.countEdit:GetText())
    if not n then
        n = GetNumRaidMembers()
        if n == 0 then n = GetNumPartyMembers() + 1 end
    end
    if n < 1 then n = 1 end
    local cut = math.floor(total * pct / 100)
    local afterCut = total - cut

    local bonusNames = {}
    for name, on in pairs((RMS.db.goldbid.pot and RMS.db.goldbid.pot.bonus) or {}) do
        if on then bonusNames[#bonusNames+1] = name end
    end
    table.sort(bonusNames)

    local bonusPool = (#bonusNames > 0) and math.floor(afterCut * bpct / 100) or 0
    local perBonus  = (#bonusNames > 0) and math.floor(bonusPool / #bonusNames) or 0
    local per = math.floor((afterCut - bonusPool) / n)
    return total, cut, per, n, bonusPool, perBonus, bonusNames
end

function M:RefreshPayout()
    local f = self.payoutWin
    if not f or not f:IsShown() then return end
    f.salesList:SetData(self:PotSales())
    f.bonusList:SetData(payoutRoster())
    local total, cut, per, n, bonusPool, perBonus, bonusNames = self:PayoutNumbers()
    f.totalFs:SetText(("Total pot: %dg  (%d sales)"):format(total, #self:PotSales()))
    local line = ("Cut: |cffffd070%dg|r    Bonus: |cff60ff60%dg|r -> %d player%s (%dg each)    Per raider: |cff60ff60%dg|r x %d"):format(
        cut, bonusPool, #bonusNames, #bonusNames == 1 and "" or "s", perBonus, per, n)
    if #bonusNames == 0 then
        line = ("Cut: |cffffd070%dg|r    Bonus: |cff888888none picked|r    Per raider: |cff60ff60%dg|r x %d"):format(cut, per, n)
    end
    f.resultFs:SetText(line)
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
