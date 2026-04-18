-- Raid Master Suite -- Donate / Support
-- Informational tab: how to send the addon author Warmane coins (server
-- service) or gold via in-game mail.

local RMS = RaidMasterSuite
local M = RMS:RegisterModule("donate", { title = "Donate", order = 50 })

-- These are the addon author's defaults. Forks/users can edit if hosting elsewhere.
M.AUTHOR_CHAR  = "Mishdk"
M.AUTHOR_REALM = "Icecrown"

-- ---------- chat helpers ----------
function M:PrintInfoToChat()
    RMS:Print("|cffffd070--- Support Raid Master Suite ---|r")
    RMS:Print("Coin gifts: %s on %s realm (Account Services -> Coins -> Coin Gifting)",
        self.AUTHOR_CHAR, self.AUTHOR_REALM)
    RMS:Print("Gold via in-game mail: |cffffff00%s|r (same realm: %s)",
        self.AUTHOR_CHAR, self.AUTHOR_REALM)
end

function M:OpenMailToAuthor()
    -- only works if the user is at a mailbox (mail UI must be open)
    if not MailFrame or not MailFrame:IsShown() then
        RMS:Print("Open a mailbox first, then click again.")
        return
    end
    if MailFrameTab_OnClick then MailFrameTab_OnClick(nil, 2) end  -- Send tab
    if SendMailNameEditBox then
        SendMailNameEditBox:SetText(self.AUTHOR_CHAR)
        SendMailNameEditBox:ClearFocus()
    end
    if SendMailSubjectEditBox then
        SendMailSubjectEditBox:SetText("RMS donation, ty <3")
    end
end

-- ---------- slash ----------
function M:OnSlash(arg)
    arg = (arg or ""):lower()
    if arg == "chat"  then return self:PrintInfoToChat() end
    if arg == "mail"  then return self:OpenMailToAuthor() end
    RMS.UI:Show("donate")
end

-- =============================================================================
-- UI
-- =============================================================================

function M:BuildUI(parent)
    local Skin = RMS.Skin
    local C    = Skin.COLOR
    local panel = CreateFrame("Frame", nil, parent)

    local header = Skin:Header(panel, "Donate / Support")
    header:SetPoint("TOPLEFT", 8, -8); header:SetPoint("TOPRIGHT", -8, -8)

    local thanks = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(thanks, 12, false)
    thanks:SetTextColor(unpack(C.text))
    thanks:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  4, -10)
    thanks:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -4, -10)
    thanks:SetHeight(40)  -- room for ~2 lines of wrapped text
    thanks:SetJustifyH("LEFT"); thanks:SetJustifyV("TOP")
    thanks:SetWordWrap(true); thanks:SetNonSpaceWrap(true)
    thanks:SetText("Thanks for using Raid Master Suite! Donations are 100% optional and help keep the addon updated. Pick whichever method is easiest:")

    -- ===== Coin Gifting block =====
    local coinHdr = Skin:Header(panel, "Server Coin Gifting")
    coinHdr:SetPoint("TOPLEFT", thanks, "BOTTOMLEFT", 0, -14)
    coinHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    local coinBody = Skin:Panel(panel)
    coinBody:SetPoint("TOPLEFT", coinHdr, "BOTTOMLEFT", 0, -2)
    coinBody:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    coinBody:SetHeight(150)

    local coinIntro = coinBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(coinIntro, 11, false); coinIntro:SetTextColor(unpack(C.text))
    coinIntro:SetPoint("TOPLEFT",  8, -8)
    coinIntro:SetPoint("TOPRIGHT", -8, -8)
    coinIntro:SetHeight(40)
    coinIntro:SetJustifyH("LEFT"); coinIntro:SetJustifyV("TOP")
    coinIntro:SetWordWrap(true); coinIntro:SetNonSpaceWrap(true)
    coinIntro:SetText("Send coins through your server account: |cffffd070Account Services -> Coins -> Coin Gifting|r. Use the values below as Receiver Character and Realm.")

    local function bigField(label, value, anchor)
        local lbl = coinBody:CreateFontString(nil, "OVERLAY")
        Skin:Font(lbl, 11, false); lbl:SetTextColor(unpack(C.textDim))
        lbl:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10); lbl:SetWidth(140)
        lbl:SetText(label)
        local val = coinBody:CreateFontString(nil, "OVERLAY")
        Skin:Font(val, 14, true); val:SetTextColor(unpack(C.accent))
        val:SetPoint("LEFT", lbl, "RIGHT", 4, 0); val:SetPoint("RIGHT", -8, 0)
        val:SetJustifyH("LEFT")
        val:SetText(value)
        return lbl
    end
    local rcvLbl   = bigField("Receiver Character:", self.AUTHOR_CHAR,  coinIntro)
    local realmLbl = bigField("Receiver Realm:",     self.AUTHOR_REALM, rcvLbl)

    -- ===== Gold Mail block =====
    local goldHdr = Skin:Header(panel, "In-Game Gold Mail")
    goldHdr:SetPoint("TOPLEFT", coinBody, "BOTTOMLEFT", 0, -10)
    goldHdr:SetPoint("RIGHT", panel, "RIGHT", -8, 0)

    local goldBody = Skin:Panel(panel)
    goldBody:SetPoint("TOPLEFT", goldHdr, "BOTTOMLEFT", 0, -2)
    goldBody:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    goldBody:SetHeight(110)

    local goldIntro = goldBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(goldIntro, 11, false); goldIntro:SetTextColor(unpack(C.text))
    goldIntro:SetPoint("TOPLEFT",  8, -8)
    goldIntro:SetPoint("TOPRIGHT", -8, -8)
    goldIntro:SetHeight(28)
    goldIntro:SetJustifyH("LEFT"); goldIntro:SetJustifyV("TOP")
    goldIntro:SetWordWrap(true); goldIntro:SetNonSpaceWrap(true)
    goldIntro:SetText("Mail gold to me in-game (same realm). I also accept gold tips ;)")

    local mailLbl = goldBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(mailLbl, 11, false); mailLbl:SetTextColor(unpack(C.textDim))
    mailLbl:SetPoint("TOPLEFT", goldIntro, "BOTTOMLEFT", 0, -10); mailLbl:SetWidth(140)
    mailLbl:SetText("Mail recipient:")

    local mailVal = goldBody:CreateFontString(nil, "OVERLAY")
    Skin:Font(mailVal, 14, true); mailVal:SetTextColor(unpack(C.accent))
    mailVal:SetPoint("LEFT", mailLbl, "RIGHT", 4, 0); mailVal:SetPoint("RIGHT", -8, 0)
    mailVal:SetJustifyH("LEFT")
    mailVal:SetText(("%s  -  %s"):format(self.AUTHOR_CHAR, self.AUTHOR_REALM))

    local fillBtn = Skin:Button(goldBody, "Auto-fill Mail (mailbox open)", 220, 22)
    fillBtn:SetPoint("TOPLEFT", mailLbl, "BOTTOMLEFT", 0, -10)
    fillBtn:SetScript("OnMouseUp", function() self:OpenMailToAuthor() end)
    Skin:AttachTooltip(fillBtn, "Auto-fill Send Mail",
        {"Stand at a mailbox with the Mail UI open, then click this. The recipient and a subject will be filled in for you - just attach the gold and send."})

    -- ===== Print to chat (always available) =====
    local printBtn = Skin:Button(panel, "Print donation info to chat", 240, 22)
    printBtn:SetPoint("TOPLEFT", goldBody, "BOTTOMLEFT", 0, -10)
    printBtn:SetScript("OnMouseUp", function() self:PrintInfoToChat() end)

    -- ===== thank you note =====
    local foot = panel:CreateFontString(nil, "OVERLAY")
    Skin:Font(foot, 10, false); foot:SetTextColor(unpack(C.textDim))
    foot:SetPoint("TOPLEFT",  printBtn, "BOTTOMLEFT", 0, -14)
    foot:SetPoint("TOPRIGHT", panel,    "RIGHT",     -8, 0)
    foot:SetHeight(28)
    foot:SetJustifyH("LEFT"); foot:SetJustifyV("TOP")
    foot:SetWordWrap(true); foot:SetNonSpaceWrap(true)
    foot:SetText("All donations are optional. Bug reports and feature requests are equally appreciated. <3")

    self._ui = { panel = panel }
    return panel
end
