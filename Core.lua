-- Traveler's Codex Companion
-- Collects character data and saves to SavedVariables for the Traveler's Codex desktop app

local addonName = "TravelersCodexCompanion"
TravelersCodexDB = TravelersCodexDB or {}

-- Version detection and API compatibility
local gameVersion = select(4, GetBuildInfo())
local isClassic = gameVersion < 30000  -- Vanilla Classic
local isTBC = gameVersion >= 20000 and gameVersion < 30000  -- TBC Classic
local isWrath = gameVersion >= 30000 and gameVersion < 40000  -- Wrath Classic
local isRetail = gameVersion >= 100000  -- Retail (Dragonflight+)
local isCata = gameVersion >= 40000 and gameVersion < 50000  -- Cata Classic

-- API Compatibility shims
local GetContainerNumSlots = C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
local GetContainerItemInfo = C_Container and C_Container.GetContainerItemInfo or function(bagID, slot)
    local texture, itemCount, locked, quality, readable, lootable, itemLink, isFiltered, noValue, itemID = GetContainerItemInfo(bagID, slot)
    if itemID then
        return {
            itemID = itemID,
            stackCount = itemCount or 1,
            hyperlink = itemLink,
            isLocked = locked,
            quality = quality,
        }
    end
    return nil
end

-- Bank container constant
local BANK_CONTAINER_ID = BANK_CONTAINER or -1

local function GetCharacterKey()
    local name = UnitName("player")
    local realm = GetRealmName()
    return name .. "-" .. realm
end

-- Price addon integration (supports multiple addons)
local function GetItemPrice(itemID)
    if not itemID then return nil end

    -- Try Auctionator first (most common for TBC Classic)
    if Auctionator and Auctionator.API and Auctionator.API.v1 then
        local success, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "TravelersCodexCompanion", itemID)
        if success and price and price > 0 then
            return price, "Auctionator"
        end
    end

    -- Try TSM (TradeSkillMaster)
    if TSM_API then
        local success, price = pcall(function()
            return TSM_API.GetCustomPriceValue("DBMarket", "i:" .. itemID)
        end)
        if success and price and price > 0 then
            return price, "TSM"
        end
    end

    -- Try Auctioneer
    if AucAdvanced and AucAdvanced.API then
        local success, price = pcall(function()
            local marketValue = AucAdvanced.API.GetMarketValue(itemID)
            return marketValue
        end)
        if success and price and price > 0 then
            return price, "Auctioneer"
        end
    end

    return nil, nil
end

-- Get TSM price data for an item (market value, min buyout, sale rate, etc.)
local function GetTSMPriceData(itemID)
    if not TSM_API or not itemID then return nil end

    local itemString = "i:" .. itemID
    local data = {}

    -- Get various price sources from TSM
    local success, marketValue = pcall(TSM_API.GetCustomPriceValue, "DBMarket", itemString)
    if success and marketValue then data.marketValue = marketValue end

    local success2, minBuyout = pcall(TSM_API.GetCustomPriceValue, "DBMinBuyout", itemString)
    if success2 and minBuyout then data.minBuyout = minBuyout end

    local success3, historical = pcall(TSM_API.GetCustomPriceValue, "DBHistorical", itemString)
    if success3 and historical then data.historical = historical end

    local success4, regionMarket = pcall(TSM_API.GetCustomPriceValue, "DBRegionMarketAvg", itemString)
    if success4 and regionMarket then data.regionMarketAvg = regionMarket end

    local success5, saleRate = pcall(TSM_API.GetCustomPriceValue, "DBRegionSaleRate", itemString)
    if success5 and saleRate then data.regionSaleRate = saleRate end

    local success6, soldPerDay = pcall(TSM_API.GetCustomPriceValue, "DBRegionSoldPerDay", itemString)
    if success6 and soldPerDay then data.regionSoldPerDay = soldPerDay end

    return next(data) and data or nil
end

-- Extract item ID from Auctionator dbKey
-- Formats: "12345" (plain ID) or "gr:12345:of the Monkey" (random suffix)
local function ExtractItemID(dbKey)
    if not dbKey then return nil end

    -- Check for "gr:" prefix (random suffix items)
    local grMatch = dbKey:match("^gr:(%d+):")
    if grMatch then
        return tonumber(grMatch)
    end

    -- Check for plain number
    local numMatch = dbKey:match("^(%d+)$")
    if numMatch then
        return tonumber(numMatch)
    end

    -- Check for item ID anywhere in the key (fallback)
    local anyNum = dbKey:match("(%d+)")
    if anyNum then
        return tonumber(anyNum)
    end

    return nil
end

-- Get item category from class/subclass
-- Returns exact WoW item types for 1:1 AH category matching
local function GetItemCategory(itemID)
    local _, _, _, _, _, itemType, itemSubType = GetItemInfo(itemID)
    -- Return the raw itemType from WoW - matches AH categories exactly
    return itemType or "Other"
end

-- Extract icon name for Wowhead URL conversion
-- Input: "Interface\\Icons\\INV_Elemental_Primal_Fire"
-- Output: "inv_elemental_primal_fire"
local function ExtractIconName(iconPath)
    if not iconPath then return nil end

    -- Handle number icons (newer WoW returns icon IDs)
    if type(iconPath) == "number" then
        return tostring(iconPath)
    end

    -- Extract the icon name from the path
    local iconName = iconPath:match("Interface\\Icons\\(.+)") or iconPath:match("([^\\]+)$") or iconPath
    return iconName:lower()
end

-- Scan FULL Auctionator database
local scanInProgress = false
local pendingItems = {}
local processedCount = 0
local totalItems = 0

local function ProcessScanBatch()
    if #pendingItems == 0 then
        -- Scan complete - no retry needed, we save ALL items
        scanInProgress = false
        local withPrice = 0
        local withTSM = 0
        local needsEnrichment = 0
        for _, item in pairs(TravelersCodexDB.ahPrices.items) do
            if item.price and item.price > 0 then
                withPrice = withPrice + 1
            end
            if item.tsm then
                withTSM = withTSM + 1
            end
            if item.needsEnrichment then
                needsEnrichment = needsEnrichment + 1
            end
        end
        print("|cFF00FF00Traveler's Codex:|r Scan complete! " .. processedCount .. " items captured, " .. withPrice .. " with prices.")
        if needsEnrichment > 0 then
            print("|cFF00FF00Traveler's Codex:|r " .. needsEnrichment .. " items will be enriched by desktop app.")
        end
        if TSM_API and withTSM > 0 then
            print("|cFF00FF00Traveler's Codex:|r TSM data added for " .. withTSM .. " items.")
        end
        print("|cFF00FF00Traveler's Codex:|r Type /reload to save and sync with desktop app.")
        return
    end

    -- Process batch of items (50 per frame to avoid lag)
    local batchSize = math.min(50, #pendingItems)
    local today = date("%Y-%m-%d")
    local cutoff = time() - (21 * 24 * 60 * 60) -- 21 days

    for i = 1, batchSize do
        local itemData = table.remove(pendingItems, 1)
        if itemData then
            local itemID = itemData.itemID
            local dbKey = itemData.dbKey
            local priceData = itemData.priceData

            -- Get item info (may return nil if not cached)
            local itemName, itemLink, itemQuality, itemLevel, itemMinLevel, itemType, itemSubType, itemStackCount, itemEquipLoc, itemTexture = GetItemInfo(itemID)

            -- Build history from Auctionator's price data
            local history = {}
            if priceData.h then
                for dayStr, price in pairs(priceData.h) do
                    -- Convert Auctionator's day number to date string
                    local dayNum = tonumber(dayStr)
                    if dayNum then
                        local timestamp = dayNum * 86400 + 1577836800 -- Auctionator epoch
                        local dateStr = date("%Y-%m-%d", timestamp)
                        history[dateStr] = price
                    end
                end
            end

            -- Store item data - ALWAYS save, desktop app enriches from database
            local existing = TravelersCodexDB.ahPrices.items[itemID] or {}

            -- If GetItemInfo returned data, use it; otherwise flag for desktop enrichment
            if itemName then
                existing.name = itemName
                existing.category = itemType or "Other"
                existing.subCategory = itemSubType or ""
                existing.icon = ExtractIconName(itemTexture)
                existing.quality = itemQuality or 1
                existing.itemLevel = itemLevel
                existing.minLevel = itemMinLevel
                existing.needsEnrichment = false
            else
                -- No item info from WoW cache - save minimal data, desktop will enrich
                existing.needsEnrichment = true
                -- Keep existing enriched data if we had it before
                existing.name = existing.name or nil
                existing.category = existing.category or nil
            end

            -- Always save price data (this is what we actually need!)
            existing.price = priceData.m or 0
            existing.lastUpdate = time()
            existing.source = "Auctionator"
            existing.dbKey = dbKey

            -- Enrich with TSM data if available
            local tsmData = GetTSMPriceData(itemID)
            if tsmData then
                existing.tsm = tsmData
                if tsmData.marketValue and tsmData.marketValue > 0 then
                    existing.marketValue = tsmData.marketValue
                end
            end

            -- Merge history
            existing.history = existing.history or {}
            for dateStr, price in pairs(history) do
                existing.history[dateStr] = price
            end
            existing.history[today] = priceData.m

            -- Prune old history
            for dateStr, _ in pairs(existing.history) do
                local year, month, day = dateStr:match("(%d+)-(%d+)-(%d+)")
                if year and month and day then
                    local timestamp = time({year=tonumber(year), month=tonumber(month), day=tonumber(day)})
                    if timestamp < cutoff then
                        existing.history[dateStr] = nil
                    end
                end
            end

            TravelersCodexDB.ahPrices.items[itemID] = existing
            processedCount = processedCount + 1
        end
    end

    -- Progress update every 500 items
    if processedCount % 500 == 0 and processedCount > 0 then
        print("|cFF00FF00Traveler's Codex:|r Processed " .. processedCount .. "/" .. totalItems .. " items...")
    end

    -- Schedule next batch
    C_Timer.After(0.01, ProcessScanBatch)
end

local function ScanAHPrices()
    -- Check for Auctionator
    if not Auctionator then
        print("|cFF00FF00Traveler's Codex:|r Auctionator not detected. Install Auctionator for price data.")
        return
    end

    -- Check for Auctionator database
    if not Auctionator.Database or not Auctionator.Database.db then
        print("|cFF00FF00Traveler's Codex:|r Auctionator database not found. Do a Full Scan in Auctionator first!")
        return
    end

    if scanInProgress then
        print("|cFF00FF00Traveler's Codex:|r Scan already in progress...")
        return
    end

    scanInProgress = true
    pendingItems = {}
    processedCount = 0

    -- Initialize storage
    TravelersCodexDB.ahPrices = TravelersCodexDB.ahPrices or {}
    TravelersCodexDB.ahPrices.items = TravelersCodexDB.ahPrices.items or {}
    TravelersCodexDB.ahPrices.scanTime = time()
    TravelersCodexDB.ahPrices.realm = GetRealmName()
    TravelersCodexDB.ahPrices.faction = UnitFactionGroup("player")

    -- Collect all items from Auctionator's database
    print("|cFF00FF00Traveler's Codex:|r Scanning Auctionator database...")

    for dbKey, priceData in pairs(Auctionator.Database.db) do
        local itemID = ExtractItemID(dbKey)
        if itemID and priceData and priceData.m and priceData.m > 0 then
            table.insert(pendingItems, {
                itemID = itemID,
                dbKey = dbKey,
                priceData = priceData
            })
        end
    end

    totalItems = #pendingItems
    print("|cFF00FF00Traveler's Codex:|r Found " .. totalItems .. " items in Auctionator database. Processing...")

    -- Pre-request item info for all items (helps with caching)
    for _, itemData in ipairs(pendingItems) do
        -- This triggers the server to send item info
        GetItemInfo(itemData.itemID)
    end

    -- Start processing after a short delay to let item info cache
    C_Timer.After(0.5, ProcessScanBatch)
end

local function CollectBagContents()
    local bags = {}

    -- Backpack (bag 0) + 4 equipped bags (1-4)
    for bagID = 0, 4 do
        local numSlots = GetContainerNumSlots(bagID)
        if numSlots and numSlots > 0 then
            bags[bagID] = {
                size = numSlots,
                items = {}
            }

            for slot = 1, numSlots do
                local itemInfo = GetContainerItemInfo(bagID, slot)
                if itemInfo then
                    local itemName = ""
                    local auctionPrice = nil
                    if itemInfo.itemID then
                        itemName = GetItemInfo(itemInfo.itemID) or ""
                        auctionPrice = GetItemPrice(itemInfo.itemID)
                    end
                    bags[bagID].items[slot] = {
                        id = itemInfo.itemID,
                        count = itemInfo.stackCount,
                        link = itemInfo.hyperlink,
                        name = itemName,
                        auctionPrice = auctionPrice
                    }
                end
            end
        end
    end

    return bags
end

local function CollectBankContents()
    local bank = {}

    -- Bank is only accessible when the bank frame is open
    if not BankFrame or not BankFrame:IsShown() then
        return nil
    end

    -- Main bank slots (BANK_CONTAINER = -1)
    local numBankSlots = GetContainerNumSlots(BANK_CONTAINER_ID)
    if numBankSlots and numBankSlots > 0 then
        bank[-1] = {
            size = numBankSlots,
            items = {}
        }
        for slot = 1, numBankSlots do
            local itemInfo = GetContainerItemInfo(BANK_CONTAINER_ID, slot)
            if itemInfo then
                local itemName = ""
                local auctionPrice = nil
                if itemInfo.itemID then
                    itemName = GetItemInfo(itemInfo.itemID) or ""
                    auctionPrice = GetItemPrice(itemInfo.itemID)
                end
                bank[-1].items[slot] = {
                    id = itemInfo.itemID,
                    count = itemInfo.stackCount,
                    link = itemInfo.hyperlink,
                    name = itemName,
                    auctionPrice = auctionPrice
                }
            end
        end
    end

    -- Bank bags (5-11)
    for bagID = 5, 11 do
        local numSlots = GetContainerNumSlots(bagID)
        if numSlots and numSlots > 0 then
            bank[bagID] = {
                size = numSlots,
                items = {}
            }

            for slot = 1, numSlots do
                local itemInfo = GetContainerItemInfo(bagID, slot)
                if itemInfo then
                    local itemName = ""
                    local auctionPrice = nil
                    if itemInfo.itemID then
                        itemName = GetItemInfo(itemInfo.itemID) or ""
                        auctionPrice = GetItemPrice(itemInfo.itemID)
                    end
                    bank[bagID].items[slot] = {
                        id = itemInfo.itemID,
                        count = itemInfo.stackCount,
                        link = itemInfo.hyperlink,
                        name = itemName,
                        auctionPrice = auctionPrice
                    }
                end
            end
        end
    end

    return bank
end

local function CollectEquipment()
    local equipment = {}

    for slot = 1, 19 do
        local itemLink = GetInventoryItemLink("player", slot)
        if itemLink then
            local itemID = GetInventoryItemID("player", slot)
            local itemName = GetItemInfo(itemID) or ""
            equipment[slot] = {
                id = itemID,
                link = itemLink,
                name = itemName
            }
        end
    end

    return equipment
end

local function CollectProfessions()
    local professions = {}

    local prof1, prof2, archaeology, fishing, cooking, firstAid = GetProfessions()

    local function AddProfession(index)
        if index then
            local name, icon, skillLevel, maxSkillLevel = GetProfessionInfo(index)
            if name then
                professions[name] = {
                    skill = skillLevel,
                    maxSkill = maxSkillLevel,
                    icon = icon
                }
            end
        end
    end

    AddProfession(prof1)
    AddProfession(prof2)
    AddProfession(cooking)
    AddProfession(fishing)
    AddProfession(firstAid)

    return professions
end

local function CollectCooldowns()
    local cooldowns = {}

    local trackedSpells = {
        -- Alchemy Transmutes
        {id = 28566, name = "Transmute: Primal Air to Fire"},
        {id = 28567, name = "Transmute: Primal Earth to Water"},
        {id = 28568, name = "Transmute: Primal Fire to Earth"},
        {id = 28569, name = "Transmute: Primal Water to Air"},
        {id = 28580, name = "Transmute: Primal Shadow to Water"},
        {id = 28581, name = "Transmute: Primal Water to Shadow"},
        {id = 28582, name = "Transmute: Primal Mana to Fire"},
        {id = 28583, name = "Transmute: Primal Fire to Mana"},
        {id = 28584, name = "Transmute: Primal Life to Earth"},
        {id = 28585, name = "Transmute: Primal Earth to Life"},
        {id = 29688, name = "Transmute: Primal Might"},
        {id = 17187, name = "Transmute: Arcanite"},

        -- Tailoring Cooldowns
        {id = 26751, name = "Primal Mooncloth"},
        {id = 26750, name = "Shadowcloth"},
        {id = 31373, name = "Spellcloth"},

        -- Leatherworking
        {id = 19566, name = "Salt Shaker"},
    }

    local currentTime = GetTime()

    for _, spell in ipairs(trackedSpells) do
        if IsSpellKnown(spell.id) then
            local start, duration = GetSpellCooldown(spell.id)
            if start and start > 0 and duration > 0 then
                local readyAt = start + duration
                cooldowns[spell.name] = {
                    spellId = spell.id,
                    readyAt = readyAt,
                    remaining = readyAt - currentTime,
                    ready = false
                }
            else
                cooldowns[spell.name] = {
                    spellId = spell.id,
                    readyAt = 0,
                    remaining = 0,
                    ready = true
                }
            end
        end
    end

    return cooldowns
end

local function CollectGuildInfo()
    local guild = {}

    local guildName, guildRankName, guildRankIndex = GetGuildInfo("player")
    if guildName then
        guild.name = guildName
        guild.rank = guildRankName
        guild.rankIndex = guildRankIndex
    end

    return guild
end

local function CollectSpecInfo()
    local specInfo = {
        activeSpec = 1,
        specs = {}
    }

    -- Get active spec (1 or 2 for dual spec, nil if dual spec not available)
    if GetActiveTalentGroup then
        specInfo.activeSpec = GetActiveTalentGroup() or 1
    end

    -- Get talent points in each tree
    local numTabs = GetNumTalentTabs and GetNumTalentTabs() or 3
    local trees = {}

    for i = 1, numTabs do
        -- TBC API: id, name, description, iconTexture, pointsSpent, background
        local _, name, _, texture, pointsSpent = GetTalentTabInfo(i)
        if name then
            trees[i] = {
                name = name,
                points = tonumber(pointsSpent) or 0,
                icon = texture
            }
        end
    end

    -- Determine primary spec based on most points spent
    local maxPoints = 0
    local primaryTree = nil
    local primaryTreeName = nil

    for i, tree in pairs(trees) do
        if tree.points > maxPoints then
            maxPoints = tree.points
            primaryTree = i
            primaryTreeName = tree.name
        end
    end

    specInfo.trees = trees
    specInfo.primaryTree = primaryTree
    specInfo.primaryTreeName = primaryTreeName
    specInfo.totalPoints = (trees[1] and trees[1].points or 0) +
                           (trees[2] and trees[2].points or 0) +
                           (trees[3] and trees[3].points or 0)

    return specInfo
end

local function CollectAllData()
    local key = GetCharacterKey()
    local _, classFilename = UnitClass("player")
    local _, race = UnitRace("player")
    local faction = UnitFactionGroup("player")

    TravelersCodexDB.characters = TravelersCodexDB.characters or {}

    -- Preserve existing data if we're logging out (APIs return 0/empty)
    local existing = TravelersCodexDB.characters[key]
    local currentMoney = GetMoney()
    local currentBags = CollectBagContents()
    local currentEquipment = CollectEquipment()
    local currentProfessions = CollectProfessions()
    local currentCooldowns = CollectCooldowns()

    -- Check if current data looks valid (not a logout state)
    local dataIsValid = currentMoney > 0 or next(currentBags) ~= nil

    -- If data looks invalid and we have existing data, preserve it
    local money = currentMoney
    local bags = currentBags
    local equipment = currentEquipment
    local professions = currentProfessions
    local cooldowns = currentCooldowns
    local existingBank = nil
    local existingBankLastUpdate = nil

    if existing then
        existingBank = existing.bank
        existingBankLastUpdate = existing.bankLastUpdate

        -- Preserve existing data if current data is invalid (logout)
        if not dataIsValid and existing.money and existing.money > 0 then
            money = existing.money
            bags = existing.bags or bags
            equipment = existing.equipment or equipment
            professions = existing.professions or professions
            cooldowns = existing.cooldowns or cooldowns
        end
    end

    TravelersCodexDB.characters[key] = {
        name = UnitName("player"),
        realm = GetRealmName(),
        class = classFilename,
        race = race,
        level = UnitLevel("player"),
        faction = faction,
        money = money,

        bags = bags,
        bank = existingBank,
        bankLastUpdate = existingBankLastUpdate,
        equipment = equipment,
        professions = professions,
        cooldowns = cooldowns,
        guild = CollectGuildInfo(),
        spec = CollectSpecInfo(),

        lastUpdate = time()
    }

    TravelersCodexDB.lastSync = time()
    TravelersCodexDB.addonVersion = "1.1.0"
end

local function CollectBankData()
    local key = GetCharacterKey()
    if TravelersCodexDB.characters and TravelersCodexDB.characters[key] then
        local bankData = CollectBankContents()
        if bankData then
            TravelersCodexDB.characters[key].bank = bankData
            TravelersCodexDB.characters[key].bankLastUpdate = time()
            print("|cFF00FF00Traveler's Codex:|r Bank data collected!")
        end
    end
end

local function PrintSummary()
    local key = GetCharacterKey()
    local char = TravelersCodexDB.characters and TravelersCodexDB.characters[key]
    if not char then
        print("|cFF00FF00Traveler's Codex:|r No data collected yet.")
        return
    end

    print("|cFF00FF00Traveler's Codex:|r Data synced for " .. key)
    print("|cFF00FF00Traveler's Codex:|r Gold: " .. GetCoinTextureString(char.money))

    local totalItems = 0
    if char.bags then
        for _, bag in pairs(char.bags) do
            if bag.items then
                for _ in pairs(bag.items) do
                    totalItems = totalItems + 1
                end
            end
        end
    end
    print("|cFF00FF00Traveler's Codex:|r Bag slots used: " .. totalItems)

    if char.professions then
        local profList = {}
        for name, prof in pairs(char.professions) do
            table.insert(profList, name .. " " .. prof.skill .. "/" .. prof.maxSkill)
        end
        if #profList > 0 then
            print("|cFF00FF00Traveler's Codex:|r Professions: " .. table.concat(profList, ", "))
        end
    end

    -- Show AH price data status
    if TravelersCodexDB.ahPrices and TravelersCodexDB.ahPrices.items then
        local count = 0
        for _ in pairs(TravelersCodexDB.ahPrices.items) do
            count = count + 1
        end
        local lastScan = TravelersCodexDB.ahPrices.scanTime and date("%Y-%m-%d %H:%M", TravelersCodexDB.ahPrices.scanTime) or "Never"
        print("|cFF00FF00Traveler's Codex:|r AH Data: " .. count .. " items (last scan: " .. lastScan .. ")")
    else
        print("|cFF00FF00Traveler's Codex:|r AH Data: None. Use /aha scan after doing Auctionator Full Scan.")
    end
end

-- Event handling
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_MONEY")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("BANKFRAME_OPENED")
frame:RegisterEvent("TRADE_SKILL_UPDATE")
frame:RegisterEvent("SKILL_LINES_CHANGED")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(2, function()
            CollectAllData()
            print("|cFF00FF00Traveler's Codex:|r Character data collected for " .. GetCharacterKey())

            -- Hook into Auctionator's scan completion event
            if Auctionator and Auctionator.EventBus and Auctionator.FullScan and Auctionator.FullScan.Events then
                local TravelersCodexEventHandler = {}
                function TravelersCodexEventHandler:ReceiveEvent(eventName)
                    if eventName == Auctionator.FullScan.Events.ScanComplete then
                        print("|cFF00FF00Traveler's Codex:|r Auctionator scan complete! Auto-exporting prices...")
                        ScanAHPrices()
                    end
                end
                Auctionator.EventBus:Register(TravelersCodexEventHandler, {
                    Auctionator.FullScan.Events.ScanComplete
                })
                print("|cFF00FF00Traveler's Codex:|r Hooked into Auctionator - prices will auto-export after Full Scan.")
            else
                print("|cFF00FF00Traveler's Codex:|r Auctionator not detected. Use /aha scan manually after scanning.")
            end
        end)
    elseif event == "PLAYER_MONEY" then
        local key = GetCharacterKey()
        if TravelersCodexDB.characters and TravelersCodexDB.characters[key] then
            TravelersCodexDB.characters[key].money = GetMoney()
            TravelersCodexDB.characters[key].lastUpdate = time()
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        local key = GetCharacterKey()
        if TravelersCodexDB.characters and TravelersCodexDB.characters[key] then
            TravelersCodexDB.characters[key].bags = CollectBagContents()
            TravelersCodexDB.characters[key].lastUpdate = time()
        end
    elseif event == "BANKFRAME_OPENED" then
        C_Timer.After(0.5, CollectBankData)
    elseif event == "TRADE_SKILL_UPDATE" or event == "SKILL_LINES_CHANGED" then
        local key = GetCharacterKey()
        if TravelersCodexDB.characters and TravelersCodexDB.characters[key] then
            TravelersCodexDB.characters[key].professions = CollectProfessions()
            TravelersCodexDB.characters[key].lastUpdate = time()
        end
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        local key = GetCharacterKey()
        if TravelersCodexDB.characters and TravelersCodexDB.characters[key] then
            TravelersCodexDB.characters[key].equipment = CollectEquipment()
            TravelersCodexDB.characters[key].lastUpdate = time()
        end
    elseif event == "PLAYER_LOGOUT" then
        CollectAllData()
    end
end)

-- Slash commands
SLASH_TRAVELERSCODEX1 = "/tc"
SLASH_TRAVELERSCODEX2 = "/travelerscodex"
SLASH_TRAVELERSCODEX3 = "/aha"  -- Keep old command for compatibility
SlashCmdList["TRAVELERSCODEX"] = function(msg)
    msg = msg and msg:lower() or ""

    if msg == "scan" then
        ScanAHPrices()
    elseif msg == "clear" then
        -- Clear AH price data to start fresh
        TravelersCodexDB.ahPrices = nil
        print("|cFF00FF00Traveler's Codex:|r AH price data cleared! Do /reload then run a Full Scan in Auctionator.")
    elseif msg == "debug" then
        -- Debug: show what's in Auctionator's database
        print("|cFF00FF00Traveler's Codex Debug:|r Checking Auctionator database...")

        if not Auctionator then
            print("|cFFFF0000  Auctionator addon not loaded!|r")
            return
        end

        -- Check various possible database locations
        print("|cFFFFD700  Checking Auctionator structure:|r")
        print("    Auctionator.Database exists: " .. tostring(Auctionator.Database ~= nil))
        print("    Auctionator.Database.db exists: " .. tostring(Auctionator.Database and Auctionator.Database.db ~= nil))

        -- Check saved variables directly
        print("|cFFFFD700  Checking SavedVariables:|r")
        print("    AUCTIONATOR_PRICE_DATABASE exists: " .. tostring(AUCTIONATOR_PRICE_DATABASE ~= nil))
        print("    AUCTIONATOR_POSTING_HISTORY exists: " .. tostring(AUCTIONATOR_POSTING_HISTORY ~= nil))

        -- Count entries in main database
        local dbCount = 0
        local sampleKeys = {}
        if Auctionator.Database and Auctionator.Database.db then
            for k, v in pairs(Auctionator.Database.db) do
                dbCount = dbCount + 1
                if #sampleKeys < 5 then
                    table.insert(sampleKeys, k)
                end
            end
        end
        print("    Auctionator.Database.db entries: " .. dbCount)

        -- Check AUCTIONATOR_PRICE_DATABASE structure
        local priceDbCount = 0
        local priceDbSample = {}
        if AUCTIONATOR_PRICE_DATABASE then
            -- It might be nested by realm
            for realm, realmData in pairs(AUCTIONATOR_PRICE_DATABASE) do
                print("    Found realm in price DB: " .. tostring(realm))
                if type(realmData) == "table" then
                    for k, v in pairs(realmData) do
                        priceDbCount = priceDbCount + 1
                        if #priceDbSample < 3 then
                            table.insert(priceDbSample, {realm = realm, key = k})
                        end
                    end
                end
            end
        end
        print("    AUCTIONATOR_PRICE_DATABASE total entries: " .. priceDbCount)

        if #sampleKeys > 0 then
            print("|cFFFFD700  Sample keys from Database.db:|r")
            for _, k in ipairs(sampleKeys) do
                print("    " .. tostring(k))
            end
        end

        if #priceDbSample > 0 then
            print("|cFFFFD700  Sample from PRICE_DATABASE:|r")
            for _, s in ipairs(priceDbSample) do
                print("    [" .. tostring(s.realm) .. "] " .. tostring(s.key))
            end
        end

        -- Search for specific items like Dawnstone
        print("|cFFFFD700  Searching for known gems:|r")
        local testItems = {
            {id = 23440, name = "Dawnstone"},
            {id = 23436, name = "Living Ruby"},
            {id = 23439, name = "Noble Topaz"},
            {id = 23441, name = "Nightseye"},
            {id = 7910, name = "Star Ruby"},
        }

        -- Also show what GetItemInfo returns for these items
        print("|cFFFFD700  Item info check:|r")
        for _, item in ipairs(testItems) do
            local itemName, _, _, _, _, itemType, itemSubType = GetItemInfo(item.id)
            if itemName then
                print("    " .. item.name .. ": type=" .. tostring(itemType) .. ", subtype=" .. tostring(itemSubType))
            else
                print("    " .. item.name .. ": GetItemInfo returned nil (not cached)")
            end
        end
        for _, item in ipairs(testItems) do
            local found = false
            local foundIn = ""
            -- Check Database.db
            if Auctionator.Database and Auctionator.Database.db then
                if Auctionator.Database.db[tostring(item.id)] then
                    found = true
                    foundIn = "Database.db[" .. item.id .. "]"
                end
            end
            -- Check AUCTIONATOR_PRICE_DATABASE
            if not found and AUCTIONATOR_PRICE_DATABASE then
                for realm, realmData in pairs(AUCTIONATOR_PRICE_DATABASE) do
                    if type(realmData) == "table" and realmData[tostring(item.id)] then
                        found = true
                        foundIn = "PRICE_DATABASE[" .. realm .. "][" .. item.id .. "]"
                        break
                    end
                end
            end
            local status = found and "|cFF00FF00FOUND|r in " .. foundIn or "|cFFFF0000NOT FOUND|r"
            print("    " .. item.name .. " (" .. item.id .. "): " .. status)
        end

    elseif msg == "help" then
        print("|cFF00FF00Traveler's Codex Commands:|r")
        print("  /tc - Show status and sync character data")
        print("  /tc scan - Manually export Auctionator's AH database")
        print("  /tc clear - Clear AH price data and start fresh")
        print("  /tc debug - Debug Auctionator database structure")
        print("  /tc help - Show this help")
        print("")
        print("|cFFFFD700Workflow:|r")
        print("  1. Open Auction House and click 'Full Scan' in Auctionator")
        print("  2. Prices auto-export when scan completes!")
        print("  3. Type /reload or logout to save")
        print("  4. Desktop app will auto-update")
    else
        CollectAllData()
        PrintSummary()
    end
end
