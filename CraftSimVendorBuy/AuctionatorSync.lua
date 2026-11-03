local addonName = ...
local Sync = {}
_G.CraftSimVendorBuySync = Sync

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function Integer(value, minimum)
    return not IsSecret(value) and type(value) == "number"
        and value >= minimum and value < math.huge and value == math.floor(value)
end

local function API()
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if type(api) ~= "table" then return nil end
    for _, name in ipairs({ "GetShoppingListItems", "ConvertFromSearchString",
        "ConvertToSearchString", "AlterShoppingListItem", "DeleteShoppingListItem" }) do
        if type(api[name]) ~= "function" then return nil end
    end
    return api
end

local function Find(api, listName, name, tier)
    local ok, items = pcall(api.GetShoppingListItems, addonName, listName)
    if not ok or type(items) ~= "table" then return nil, "list unavailable" end
    local match
    for _, search in ipairs(items) do
        if IsSecret(search) or type(search) ~= "string" then return nil, "invalid search" end
        local parsed, terms = pcall(api.ConvertFromSearchString, addonName, search)
        if not parsed or type(terms) ~= "table" then return nil, "invalid search" end
        if not IsSecret(terms.searchString) and not IsSecret(terms.isExact)
            and not IsSecret(terms.tier) and terms.searchString == name
            and terms.isExact == true and terms.tier == tier then
            if match then return nil, "ambiguous item" end
            match = { search = search, terms = terms }
        end
    end
    if not match then return nil, "item absent" end
    if not Integer(match.terms.quantity, 1) then return nil, "quantity unavailable" end
    return match
end

local function CraftSim()
    if not CraftSimAPI or type(CraftSimAPI.GetCraftSim) ~= "function" then return nil end
    local ok, craftSim = pcall(CraftSimAPI.GetCraftSim, CraftSimAPI)
    if ok and type(craftSim) == "table" then return craftSim end
end

local function LegacyListNames(craftSim, baseName)
    local names, seen = {}, {}
    local function Add(uid)
        if not IsSecret(uid) and type(uid) == "string" and uid ~= "" and not seen[uid] then
            seen[uid] = true
            names[#names + 1] = baseName .. " " .. uid
        end
    end
    local crafters = craftSim.DB and craftSim.DB.CRAFTER
    if crafters and type(crafters.GetCrafterUIDs) == "function" then
        local ok, uids = pcall(crafters.GetCrafterUIDs, crafters)
        if ok and type(uids) == "table" then
            for _, uid in pairs(uids) do Add(uid) end
        end
    end
    local util = craftSim.UTIL
    if util and type(util.GetPlayerCrafterUID) == "function" then
        local ok, uid = pcall(util.GetPlayerCrafterUID, util)
        if ok then Add(uid) end
    end
    return names
end

-- Capture before submitting a vendor request. Only CraftSim's own exact searches
-- with quantities can be changed; arbitrary Auctionator lists are never scanned.
function Sync.Capture(itemID, name, qualityID)
    if not Integer(itemID, 1) or IsSecret(name) or type(name) ~= "string" or name == "" then
        return nil, "item identity unavailable"
    end
    if IsSecret(qualityID) then return nil, "invalid reagent tier" end
    if qualityID == 0 then qualityID = nil end
    if qualityID ~= nil and not Integer(qualityID, 1) then return nil, "invalid reagent tier" end
    local api, craftSim = API(), CraftSim()
    if not api or not craftSim then return nil, "integration unavailable" end
    local baseName = craftSim.CONST and craftSim.CONST.AUCTIONATOR_SHOPPING_LIST_QUEUE_NAME
    if IsSecret(baseName) or type(baseName) ~= "string" or baseName == "" then
        return nil, "list name unavailable"
    end
    local listName = baseName
    local match, reason = Find(api, listName, name, qualityID)
    if not match then
        if reason ~= "item absent" and reason ~= "list unavailable" then return nil, reason end
        for _, legacyName in ipairs(LegacyListNames(craftSim, baseName)) do
            local candidate, failure = Find(api, legacyName, name, qualityID)
            if candidate then
                if match then return nil, "ambiguous crafter lists" end
                match, listName = candidate, legacyName
            elseif failure ~= "item absent" and failure ~= "list unavailable" then
                return nil, failure
            end
        end
    end
    if not match then return nil, "matching list item unavailable" end
    return {
        itemID = itemID, name = name, tier = qualityID, listName = listName,
        initialQuantity = match.terms.quantity, expectedSearch = match.search,
        confirmed = 0,
    }
end

local function Stop(snapshot, reason)
    snapshot.stopped = reason
    return false, reason
end

-- confirmedQuantity is cumulative for this purchase receipt, not the latest bag
-- delta. Repeated bag events therefore cannot subtract the same items twice.
function Sync.Apply(snapshot, confirmedQuantity)
    if type(snapshot) ~= "table" then return false, "no snapshot" end
    if snapshot.stopped then return false, snapshot.stopped end
    if not Integer(confirmedQuantity, 0) then return Stop(snapshot, "invalid confirmation") end
    if confirmedQuantity <= snapshot.confirmed then return true, "unchanged" end
    if snapshot.finished then return true, "complete" end
    local api = API()
    if not api then return Stop(snapshot, "integration unavailable") end
    local match, reason = Find(api, snapshot.listName, snapshot.name, snapshot.tier)
    if not match then return Stop(snapshot, reason) end
    -- Another addon, a list rebuild or a user edit may already have accounted for
    -- these items. Never rebase and subtract again from an unexpected entry.
    if match.search ~= snapshot.expectedSearch then return Stop(snapshot, "list item changed") end
    local remaining = math.max(snapshot.initialQuantity - confirmedQuantity, 0)
    local newSearch
    if remaining > 0 then
        match.terms.quantity = remaining
        local ok
        ok, newSearch = pcall(api.ConvertToSearchString, addonName, match.terms)
        if not ok or type(newSearch) ~= "string" or newSearch == "" then
            return Stop(snapshot, "search conversion failed")
        end
    end
    -- Reserve before the API call: an exception or a reentrant event must never
    -- cause a second decrement after an uncertain mutation.
    snapshot.stopped = "shopping list update interrupted"
    local ok
    if newSearch then
        ok = pcall(api.AlterShoppingListItem, addonName, snapshot.listName,
            snapshot.expectedSearch, newSearch)
    else
        ok = pcall(api.DeleteShoppingListItem, addonName, snapshot.listName, snapshot.expectedSearch)
    end
    if not ok then return false, snapshot.stopped end
    snapshot.expectedSearch = newSearch
    snapshot.confirmed = confirmedQuantity
    snapshot.finished = remaining == 0
    snapshot.stopped = nil
    return true, snapshot.finished and "complete" or "updated"
end
