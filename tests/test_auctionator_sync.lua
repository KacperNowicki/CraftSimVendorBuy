-- Execute the real module against opaque searches and controllable public APIs.
-- The runner supplies auctionator_sync_source from the addon file on disk.
assert(type(auctionator_sync_source) == "string", "Auctionator sync source is required")
local BASE = "CraftSim CraftQueue"
local passed = 0

local function Copy(value)
    local result = {}
    for key, item in pairs(value) do result[key] = item end
    return result
end

local function Reset()
    local env = { lists = {}, searches = {}, reads = {}, mutations = {}, uids = { "Player", "Alt" } }
    function env.encode(terms)
        local fields = {}
        for key, value in pairs(terms) do
            fields[#fields + 1] = key .. "=" .. type(value) .. ":" .. tostring(value)
        end
        table.sort(fields)
        local search = table.concat(fields, "|")
        env.searches[search] = Copy(terms)
        return search
    end
    function env.term(quantity, extras)
        local terms = { searchString = "Test Reagent", isExact = true, quantity = quantity }
        for key, value in pairs(extras or {}) do terms[key] = value end
        return env.encode(terms)
    end
    function env.quantity(listName, index)
        local search = assert(env.lists[listName or BASE][index or 1], "list item missing")
        return env.searches[search].quantity
    end
    local api = {}
    local function Caller(caller)
        assert(caller == "CraftSimVendorBuy", "invalid public API caller")
    end
    function api.GetShoppingListItems(caller, listName)
        Caller(caller)
        env.reads[#env.reads + 1] = listName
        if env.failRead then error("read failed") end
        return Copy(assert(env.lists[listName], "list does not exist"))
    end
    function api.ConvertFromSearchString(caller, search)
        Caller(caller)
        if env.failDecode then error("decode failed") end
        return Copy(assert(env.searches[search], "unknown search"))
    end
    function api.ConvertToSearchString(caller, terms)
        Caller(caller)
        if env.failEncode then error("encode failed") end
        return env.encode(terms)
    end
    function api.AlterShoppingListItem(caller, listName, oldSearch, newSearch)
        Caller(caller)
        if env.failAlterBefore then error("alter failed before mutation") end
        local list = assert(env.lists[listName])
        for index, search in ipairs(list) do
            if search == oldSearch then
                list[index] = newSearch
                env.mutations[#env.mutations + 1] = "alter"
                if env.alterHook then env.alterHook() end
                if env.failAlterAfter then error("alter failed after mutation") end
                return
            end
        end
        error("old search not found")
    end
    function api.DeleteShoppingListItem(caller, listName, oldSearch)
        Caller(caller)
        if env.failDeleteBefore then error("delete failed before mutation") end
        local list = assert(env.lists[listName])
        for index, search in ipairs(list) do
            if search == oldSearch then
                table.remove(list, index)
                env.mutations[#env.mutations + 1] = "delete"
                if env.failDeleteAfter then error("delete failed after mutation") end
                return
            end
        end
    end
    Auctionator = { API = { v1 = api } }
    local craftSim = {
        CONST = { AUCTIONATOR_SHOPPING_LIST_QUEUE_NAME = BASE },
        DB = { CRAFTER = { GetCrafterUIDs = function() return env.uids end } },
        UTIL = { GetPlayerCrafterUID = function() return "Player" end },
    }
    CraftSimAPI = { GetCraftSim = function() return craftSim end }
    issecretvalue = nil
    assert(loadstring(auctionator_sync_source))("CraftSimVendorBuy")
    env.sync, env.api, env.craftSim = CraftSimVendorBuySync, api, craftSim
    env.lists[BASE] = { env.term(100) }
    function env.capture(tier, name)
        return env.sync.Capture(1001, name or "Test Reagent", tier)
    end
    return env
end

local function Test(name, callback)
    local ok, failure = pcall(callback, Reset())
    assert(ok, name .. ": " .. tostring(failure))
    passed = passed + 1
end

Test("capture and zero confirmation do not change lists", function(e)
    local snapshot = assert(e.capture())
    assert(e.sync.Apply(snapshot, 0))
    assert(e.quantity() == 100 and #e.mutations == 0)
end)

Test("partial receipts use cumulative quantities exactly once", function(e)
    local snapshot = assert(e.capture())
    assert(e.sync.Apply(snapshot, 30))
    assert(e.quantity() == 70 and #e.mutations == 1)
    assert(e.sync.Apply(snapshot, 30))
    assert(e.quantity() == 70 and #e.mutations == 1, "duplicate event subtracted twice")
    assert(e.sync.Apply(snapshot, 60))
    assert(e.quantity() == 40 and #e.mutations == 2, "cumulative count treated as a delta")
    assert(e.sync.Apply(snapshot, 15))
    assert(e.quantity() == 40 and #e.mutations == 2, "older receipt changed quantity")
end)

Test("completed receipt deletes only the purchased item", function(e)
    local other = e.term(50, { searchString = "Other Reagent" })
    e.lists[BASE][2] = other
    local snapshot = assert(e.capture())
    assert(e.sync.Apply(snapshot, 100))
    assert(#e.lists[BASE] == 1 and e.lists[BASE][1] == other)
    assert(#e.mutations == 1 and e.mutations[1] == "delete")
    assert(e.sync.Apply(snapshot, 100))
    assert(e.sync.Apply(snapshot, 150))
    assert(#e.mutations == 1)
end)

Test("confirmation larger than list need never creates negative quantities", function(e)
    local snapshot = assert(e.capture())
    assert(e.sync.Apply(snapshot, 120))
    assert(#e.lists[BASE] == 0 and e.mutations[1] == "delete")
end)

Test("external quantity edit before receipt permanently stops snapshot", function(e)
    local snapshot = assert(e.capture())
    e.lists[BASE][1] = e.term(80)
    assert(not e.sync.Apply(snapshot, 30))
    assert(e.quantity() == 80 and #e.mutations == 0)
    e.lists[BASE][1] = e.term(100)
    assert(not e.sync.Apply(snapshot, 60), "stopped snapshot resumed after external edit")
    assert(e.quantity() == 100 and #e.mutations == 0)
end)

Test("external edit between partial receipts is not double accounted", function(e)
    local snapshot = assert(e.capture())
    assert(e.sync.Apply(snapshot, 30))
    e.lists[BASE][1] = e.term(40)
    assert(not e.sync.Apply(snapshot, 60))
    assert(e.quantity() == 40 and #e.mutations == 1)
end)

Test("external filter edit also stops snapshot", function(e)
    local snapshot = assert(e.capture())
    e.lists[BASE][1] = e.term(100, { maxPrice = 50000 })
    assert(not e.sync.Apply(snapshot, 30))
    assert(e.quantity() == 100 and #e.mutations == 0)
end)

Test("externally deleted item is never recreated", function(e)
    local snapshot = assert(e.capture())
    e.lists[BASE] = {}
    assert(not e.sync.Apply(snapshot, 30))
    assert(#e.lists[BASE] == 0 and #e.mutations == 0)
end)

Test("exact tier selects the correct reagent quality", function(e)
    local tier3 = e.term(80, { tier = 3 })
    e.lists[BASE] = { e.term(100, { tier = 2 }), tier3 }
    local snapshot = assert(e.capture(2))
    assert(e.sync.Apply(snapshot, 30))
    assert(e.quantity() == 70 and e.lists[BASE][2] == tier3)
    assert(e.capture(1) == nil and e.capture() == nil, "wrong reagent tier matched")
end)

Test("zero tier represents an unqualified vendor reagent", function(e)
    local snapshot = assert(e.capture(0))
    assert(e.sync.Apply(snapshot, 30) and e.quantity() == 70)
end)

Test("name matching is exact and never uses prefixes", function(e)
    e.lists[BASE] = { e.term(100, { searchString = "Test Reagent Extra" }) }
    assert(e.capture() == nil and #e.mutations == 0)
end)

Test("nonexact searches are left alone", function(e)
    e.lists[BASE] = { e.term(100, { isExact = false }) }
    assert(e.capture() == nil and #e.mutations == 0)
end)

Test("duplicate matching searches are ambiguous even with different filters", function(e)
    e.lists[BASE][2] = e.term(20, { minPrice = 10000 })
    assert(e.capture() == nil and #e.mutations == 0)
end)

Test("searches without quantity are not changed", function(e)
    e.lists[BASE] = { e.term(nil) }
    assert(e.capture() == nil)
    e.lists[BASE][2] = e.term(100)
    assert(e.capture() == nil, "quantityless duplicate was ignored")
end)

Test("unrelated named lists are never scanned or altered", function(e)
    e.lists[BASE] = {}
    e.lists["My Private List"] = { e.term(100) }
    assert(e.capture() == nil)
    for _, listName in ipairs(e.reads) do assert(listName ~= "My Private List") end
    assert(e.quantity("My Private List") == 100 and #e.mutations == 0)
end)

Test("canonical list takes precedence over legacy crafter lists", function(e)
    e.lists[BASE .. " Alt"] = { e.term(90) }
    local snapshot = assert(e.capture())
    assert(e.sync.Apply(snapshot, 30))
    assert(e.quantity() == 70 and e.quantity(BASE .. " Alt") == 90)
end)

Test("one known legacy list is supported when canonical is absent", function(e)
    e.lists[BASE] = nil
    e.lists[BASE .. " Alt"] = { e.term(100) }
    local snapshot = assert(e.capture())
    assert(e.sync.Apply(snapshot, 30))
    assert(e.quantity(BASE .. " Alt") == 70)
end)

Test("one legacy list is supported when canonical lacks this item", function(e)
    e.lists[BASE] = { e.term(60, { searchString = "Other Reagent" }) }
    e.lists[BASE .. " Player"] = { e.term(100) }
    local snapshot = assert(e.capture())
    assert(e.sync.Apply(snapshot, 30))
    assert(e.quantity() == 60 and e.quantity(BASE .. " Player") == 70)
end)

Test("legacy crafter names are deduplicated", function(e)
    e.lists[BASE] = nil
    e.uids = { "Player", "Player" }
    e.lists[BASE .. " Player"] = { e.term(100) }
    assert(e.capture())
    assert(#e.reads == 2, "same legacy list read repeatedly and treated as ambiguous")
end)

Test("multiple matching legacy lists are ambiguous", function(e)
    e.lists[BASE] = nil
    e.lists[BASE .. " Player"] = { e.term(100) }
    e.lists[BASE .. " Alt"] = { e.term(80) }
    assert(e.capture() == nil and #e.mutations == 0)
end)

Test("unknown crafter suffixes are not scanned", function(e)
    e.lists[BASE] = nil
    e.lists[BASE .. " Stranger"] = { e.term(100) }
    assert(e.capture() == nil)
    for _, listName in ipairs(e.reads) do assert(listName ~= BASE .. " Stranger") end
end)

Test("all existing search filters survive quantity updates", function(e)
    local filters = {
        categoryKey = "2_7", tier = 2, quality = 3, expansion = 11,
        minPrice = 10000, maxPrice = 50000, minLevel = 10, maxLevel = 80,
        minItemLevel = 100, maxItemLevel = 200, minCraftedLevel = 20, maxCraftedLevel = 40,
    }
    e.lists[BASE] = { e.term(100, filters) }
    local snapshot = assert(e.capture(2))
    assert(e.sync.Apply(snapshot, 30))
    local updated = e.searches[e.lists[BASE][1]]
    for key, value in pairs(filters) do assert(updated[key] == value, "filter lost: " .. key) end
    assert(updated.searchString == "Test Reagent" and updated.isExact and updated.quantity == 70)
end)

Test("missing Auctionator and incomplete public APIs remain optional", function(e)
    Auctionator = nil
    assert(e.capture() == nil)
    Auctionator = { API = { v1 = e.api } }
    e.api.AlterShoppingListItem = nil
    assert(e.capture() == nil and #e.mutations == 0)
end)

Test("missing CraftSim and failing accessor skip capture", function(e)
    CraftSimAPI = nil
    assert(e.capture() == nil)
    CraftSimAPI = { GetCraftSim = function() error("CraftSim unavailable") end }
    assert(e.capture() == nil)
end)

Test("public API disappearing stops an existing snapshot", function(e)
    local snapshot = assert(e.capture())
    Auctionator = nil
    assert(not e.sync.Apply(snapshot, 30))
    Auctionator = { API = { v1 = e.api } }
    assert(not e.sync.Apply(snapshot, 60) and #e.mutations == 0)
end)

Test("read API errors cannot mutate or later retry the snapshot", function(e)
    local snapshot = assert(e.capture())
    e.failRead = true
    assert(e.capture() == nil)
    assert(not e.sync.Apply(snapshot, 30))
    e.failRead = false
    assert(not e.sync.Apply(snapshot, 60) and #e.mutations == 0)
end)

Test("malformed or undecodable search strings fail closed", function(e)
    local snapshot = assert(e.capture())
    e.failDecode = true
    assert(e.capture() == nil and not e.sync.Apply(snapshot, 30))
    e.failDecode = false
    assert(not e.sync.Apply(snapshot, 60) and #e.mutations == 0)
    e.lists[BASE] = { false }
    assert(e.capture() == nil)
end)

Test("conversion errors do not send mutations or resume later", function(e)
    local snapshot = assert(e.capture())
    e.failEncode = true
    assert(not e.sync.Apply(snapshot, 30))
    e.failEncode = false
    assert(not e.sync.Apply(snapshot, 60))
    assert(e.quantity() == 100 and #e.mutations == 0)
end)

for _, after in ipairs({ false, true }) do
    Test("alter exception " .. (after and "after" or "before") .. " mutation cannot double subtract", function(e)
        local snapshot = assert(e.capture())
        e.failAlterBefore, e.failAlterAfter = not after, after
        assert(not e.sync.Apply(snapshot, 30))
        assert(e.quantity() == (after and 70 or 100))
        e.failAlterBefore, e.failAlterAfter = false, false
        assert(not e.sync.Apply(snapshot, 60))
        assert(#e.mutations == (after and 1 or 0))
    end)
    Test("delete exception " .. (after and "after" or "before") .. " mutation cannot repeat", function(e)
        local snapshot = assert(e.capture())
        e.failDeleteBefore, e.failDeleteAfter = not after, after
        assert(not e.sync.Apply(snapshot, 100))
        assert(#e.lists[BASE] == (after and 0 or 1))
        e.failDeleteBefore, e.failDeleteAfter = false, false
        assert(not e.sync.Apply(snapshot, 120))
        assert(#e.mutations == (after and 1 or 0))
    end)
end

Test("reentrant public API event cannot subtract again", function(e)
    local snapshot = assert(e.capture())
    e.alterHook = function() assert(not e.sync.Apply(snapshot, 60), "reentrant mutation allowed") end
    assert(e.sync.Apply(snapshot, 30))
    assert(e.quantity() == 70 and #e.mutations == 1)
    e.alterHook = nil
    assert(e.sync.Apply(snapshot, 60) and e.quantity() == 40)
end)

Test("unrelated item edits do not prevent a safe target update", function(e)
    local snapshot = assert(e.capture())
    local other = e.term(50, { searchString = "Other Reagent" })
    e.lists[BASE][2] = other
    assert(e.sync.Apply(snapshot, 30))
    assert(e.quantity() == 70 and e.lists[BASE][2] == other)
end)

Test("invalid identity and confirmation are rejected", function(e)
    assert(e.sync.Capture(0, "Test Reagent") == nil)
    assert(e.sync.Capture(1001, "") == nil)
    assert(e.capture(-1) == nil and e.capture(1.5) == nil)
    assert(not e.sync.Apply(nil, 30))
    local snapshot = assert(e.capture())
    assert(not e.sync.Apply(snapshot, -1))
    assert(not e.sync.Apply(snapshot, 30) and #e.mutations == 0)
end)

Test("secret item identity is never used for shopping list updates", function(e)
    local secret = {}
    issecretvalue = function(value) return value == secret end
    assert(e.sync.Capture(1001, secret) == nil)
    assert(e.sync.Capture(1001, "Test Reagent", secret) == nil)
    local snapshot = assert(e.capture())
    assert(not e.sync.Apply(snapshot, secret) and #e.mutations == 0)
end)

return passed
