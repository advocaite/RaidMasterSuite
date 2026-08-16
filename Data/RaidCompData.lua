-- Raid Master Suite -- Raid composition data (WOTLK 3.3.5)
-- CURATED, not auto-generated: typical Warmane-style pug expectations and the
-- standard WOTLK buff/debuff coverage checklist. Edit numbers freely to match
-- your guild's standards. TBC/Classic raids can be appended later.
--
-- Spec tokens must match talent-tab names as normalized by the BiS module
-- (spaces -> underscores), e.g. "Feral_Combat", "Beast_Mastery".

local RMS = RaidMasterSuite

-- dps count = size - tanks - healers (computed in the UI)
RMS.RaidComps = {
    { key = "naxx10",  name = "Naxxramas",            size = 10, phase = 1, minGS = 2800, tanks = 2, healers = 3 },
    { key = "naxx25",  name = "Naxxramas",            size = 25, phase = 1, minGS = 3300, tanks = 3, healers = 6 },
    { key = "os10",    name = "Obsidian Sanctum",     size = 10, phase = 1, minGS = 3000, tanks = 2, healers = 3,
      notes = "Drakes-up / zerg runs expect far higher GS than a clean clear." },
    { key = "os25",    name = "Obsidian Sanctum",     size = 25, phase = 1, minGS = 3400, tanks = 3, healers = 6,
      notes = "Drakes-up / zerg runs expect far higher GS than a clean clear." },
    { key = "eoe10",   name = "Eye of Eternity",      size = 10, phase = 1, minGS = 3200, tanks = 1, healers = 3,
      notes = "Single tank; phase 3 is gear-independent (drakes)." },
    { key = "eoe25",   name = "Eye of Eternity",      size = 25, phase = 1, minGS = 3600, tanks = 1, healers = 6,
      notes = "Single tank; phase 3 is gear-independent (drakes)." },
    { key = "voa10",   name = "Vault of Archavon",    size = 10, phase = 1, minGS = 3200, tanks = 2, healers = 3,
      notes = "Expectations rise with each new wing (Emalon/Koralon/Toravon)." },
    { key = "voa25",   name = "Vault of Archavon",    size = 25, phase = 1, minGS = 3700, tanks = 2, healers = 5,
      notes = "Expectations rise with each new wing (Emalon/Koralon/Toravon)." },
    { key = "uld10",   name = "Ulduar",               size = 10, phase = 2, minGS = 3800, tanks = 2, healers = 3,
      notes = "Hard modes (esp. Mimiron/Vezax/Yogg) expect ToC-level gear." },
    { key = "uld25",   name = "Ulduar",               size = 25, phase = 2, minGS = 4300, tanks = 3, healers = 6,
      notes = "Hard modes (esp. Mimiron/Vezax/Yogg) expect ToC-level gear." },
    { key = "toc10",   name = "Trial of the Crusader", size = 10, phase = 3, minGS = 4300, tanks = 2, healers = 3 },
    { key = "toc25",   name = "Trial of the Crusader", size = 25, phase = 3, minGS = 4600, tanks = 2, healers = 6,
      notes = "Anub'arak wants a dedicated add tank; keep 2 solid tanks minimum." },
    { key = "togc10",  name = "Trial of the Grand Crusader", size = 10, phase = 3, minGS = 4800, tanks = 2, healers = 3,
      notes = "Attempt-limited. Faction Champions favors strong dispellers/CC." },
    { key = "togc25",  name = "Trial of the Grand Crusader", size = 25, phase = 3, minGS = 5200, tanks = 2, healers = 5,
      notes = "Attempt-limited; dps checks are tight -- run lean on healers." },
    { key = "ony10",   name = "Onyxia's Lair",        size = 10, phase = 3, minGS = 4300, tanks = 2, healers = 3 },
    { key = "ony25",   name = "Onyxia's Lair",        size = 25, phase = 3, minGS = 4600, tanks = 3, healers = 6,
      notes = "Second tank handles whelps/adds in phase 2." },
    { key = "icc10",   name = "Icecrown Citadel",     size = 10, phase = 4, minGS = 4900, tanks = 2, healers = 3,
      notes = "Later wings (esp. LK) expect noticeably more than entry bosses." },
    { key = "icc25",   name = "Icecrown Citadel",     size = 25, phase = 4, minGS = 5400, tanks = 3, healers = 6,
      notes = "Farm runs often drop to 2 tanks / 5 healers for faster clears." },
    { key = "rs10",    name = "Ruby Sanctum",         size = 10, phase = 4, minGS = 5600, tanks = 2, healers = 3,
      notes = "Halion: split raid inside/outside; two competent tanks required." },
    { key = "rs25",    name = "Ruby Sanctum",         size = 25, phase = 4, minGS = 5800, tanks = 3, healers = 6,
      notes = "Halion: split raid inside/outside; balance dps between realms." },
}

-- Coverage checklist. providers = list of {class=token, spec=optional}.
-- No spec field = any spec of that class brings it.
RMS.RaidBuffs = {
    -- core raid buffs
    { cat = "Raid Buffs", name = "Bloodlust / Heroism",
      providers = {{class="SHAMAN"}} },
    { cat = "Raid Buffs", name = "Blessing of Kings",
      providers = {{class="PALADIN"}} },
    { cat = "Raid Buffs", name = "Might / Battle Shout (AP)",
      providers = {{class="PALADIN"}, {class="WARRIOR"}} },
    { cat = "Raid Buffs", name = "Wisdom / Mana Spring (mp5)",
      providers = {{class="PALADIN"}, {class="SHAMAN"}} },
    { cat = "Raid Buffs", name = "Power Word: Fortitude",
      providers = {{class="PRIEST"}} },
    { cat = "Raid Buffs", name = "Divine Spirit",
      providers = {{class="PRIEST"}} },
    { cat = "Raid Buffs", name = "Shadow Protection",
      providers = {{class="PRIEST"}} },
    { cat = "Raid Buffs", name = "Gift of the Wild",
      providers = {{class="DRUID"}} },
    { cat = "Raid Buffs", name = "Horn of Winter / Str-Agi Totem",
      providers = {{class="DEATHKNIGHT"}, {class="SHAMAN"}} },
    { cat = "Raid Buffs", name = "10% AP (Trueshot / Abom Might / Unleashed Rage)",
      providers = {{class="HUNTER", spec="Marksmanship"}, {class="DEATHKNIGHT", spec="Blood"},
                   {class="SHAMAN", spec="Enhancement"}} },
    { cat = "Raid Buffs", name = "5% crit (Leader of the Pack / Rampage)",
      providers = {{class="DRUID", spec="Feral_Combat"}, {class="WARRIOR", spec="Fury"}} },
    { cat = "Raid Buffs", name = "5% spell crit (Moonkin Aura / Elemental Oath)",
      providers = {{class="DRUID", spec="Balance"}, {class="SHAMAN", spec="Elemental"}} },
    { cat = "Raid Buffs", name = "3% haste (Swift Retribution / Imp Moonkin)",
      providers = {{class="PALADIN", spec="Retribution"}, {class="DRUID", spec="Balance"}} },
    { cat = "Raid Buffs", name = "3% damage (Sanc Retribution / Arcane Emp / Ferocious Insp)",
      providers = {{class="PALADIN", spec="Retribution"}, {class="MAGE", spec="Arcane"},
                   {class="HUNTER", spec="Beast_Mastery"}} },
    { cat = "Raid Buffs", name = "Spellpower (Totem of Wrath / Demonic Pact)",
      providers = {{class="SHAMAN", spec="Elemental"}, {class="WARLOCK", spec="Demonology"}} },
    { cat = "Raid Buffs", name = "Spell haste (Wrath of Air Totem)",
      providers = {{class="SHAMAN"}} },
    { cat = "Raid Buffs", name = "20% melee haste (Windfury / Imp Icy Talons)",
      providers = {{class="SHAMAN", spec="Enhancement"}, {class="DEATHKNIGHT", spec="Frost"}} },
    { cat = "Raid Buffs", name = "Replenishment",
      providers = {{class="HUNTER", spec="Survival"}, {class="PRIEST", spec="Shadow"},
                   {class="PALADIN", spec="Retribution"}, {class="DEATHKNIGHT", spec="Frost"},
                   {class="WARLOCK", spec="Destruction"}} },

    -- debuffs on the boss
    { cat = "Debuffs", name = "20% armor (Sunder / Expose Armor)",
      providers = {{class="WARRIOR"}, {class="ROGUE"}} },
    { cat = "Debuffs", name = "13% spell dmg (Curse of Elements / Ebon Plague)",
      providers = {{class="WARLOCK"}, {class="DEATHKNIGHT", spec="Unholy"}} },
    { cat = "Debuffs", name = "30% bleed dmg (Mangle / Trauma)",
      providers = {{class="DRUID", spec="Feral_Combat"}, {class="WARRIOR", spec="Arms"}} },
    { cat = "Debuffs", name = "3% spell hit (Misery / Imp Faerie Fire)",
      providers = {{class="PRIEST", spec="Shadow"}, {class="DRUID", spec="Balance"}} },
    { cat = "Debuffs", name = "Attack speed slow (Thunder Clap / Infected Wounds / JotJ)",
      providers = {{class="WARRIOR"}, {class="PALADIN", spec="Protection"},
                   {class="DRUID", spec="Feral_Combat"}, {class="DEATHKNIGHT"}} },
    { cat = "Debuffs", name = "Mana return (Judgement of Wisdom)",
      providers = {{class="PALADIN"}} },

    -- utility
    { cat = "Utility", name = "Combat rez (Rebirth)",
      providers = {{class="DRUID"}} },
    { cat = "Utility", name = "Innervate",
      providers = {{class="DRUID"}} },
    { cat = "Utility", name = "Mass decurse (Druid / Mage)",
      providers = {{class="DRUID"}, {class="MAGE"}} },
}
