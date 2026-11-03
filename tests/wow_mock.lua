-- A deterministic WoW boundary, not a replacement purchase implementation.
-- The real addon executes inside this Lua 5.1 environment in every test.
S = {
    time = 0, frames = {}, timers = {}, purchases = {}, groups = {}, batches = {}, messages = {},
    bags = {}, need = { [1001] = 12500 }, money = 10000000,
    offers = { { id = 1001, name = "Test Reagent", price = 10,
        stackCount = 1, numAvailable = -1, maximum = 1000,
        isPurchasable = true, hasExtendedCost = false } },
    inClick = false, sessionAuthorized = false, clickCount = 0, syncs = {},
    counters = { missingQueries = 0, merchantScans = 0, offerReads = 0,
        merchantIDReads = 0, bagReads = 0, crafterReads = 0 },
}

function S.resetCounters()
    for name in pairs(S.counters) do S.counters[name] = 0 end
end

local Frame = {}
function Frame:SetScript(name, callback) self.scripts[name] = callback end
function Frame:GetScript(name) return self.scripts[name] end
function Frame:HookScript(name, callback)
    local before = self.scripts[name]
    self.scripts[name] = function(...)
        if before then before(...) end
        callback(...)
    end
end
function Frame:RegisterEvent(name) self.events[name] = true end
function Frame:UnregisterEvent(name) self.events[name] = nil end
function Frame:RegisterForClicks(...) self.clicks = {...} end
function Frame:SetText(value) self.text = value end
function Frame:SetFormattedText(format, ...) self.text = format:format(...) end
function Frame:GetText() return self.text end
function Frame:SetEnabled(value) self.enabled = value and true or false end
function Frame:IsEnabled() return self.enabled end
function Frame:Enable() self.enabled = true end
function Frame:Disable() self.enabled = false end
function Frame:SetShown(value) self.shown = value and true or false end
function Frame:Show() self.shown = true end
function Frame:Hide()
    self.shown = false
    if self.scripts.OnHide then self.scripts.OnHide(self) end
end
function Frame:IsShown() return self.shown end
function Frame:IsVisible() return self.shown end
function Frame:IsMouseOver() return self.mouseOver and true or false end
function Frame:SetSize(width, height) self.width, self.height = width, height end
function Frame:SetWidth(width) self.width = width end
function Frame:SetHeight(height) self.height = height end
function Frame:GetWidth() return self.width end
function Frame:GetHeight() return self.height end
function Frame:SetFrameStrata(value) self.strata = value end
function Frame:GetFrameStrata() return self.strata or "MEDIUM" end
function Frame:SetFrameLevel(value) self.level = value end
function Frame:GetFrameLevel() return self.level or 1 end
function Frame:SetPoint(...) self.point = {...} end
function Frame:ClearAllPoints() self.point = nil end
function Frame:SetAllPoints(...) self.allPoints = {...} end
function Frame:SetAlpha(value) self.alpha = value end
function Frame:GetAlpha() return self.alpha or 1 end
function Frame:SetTexture(value) self.texture = value end
function Frame:SetColorTexture(...) self.colorTexture = {...} end
function Frame:SetTexCoord(...) self.texCoord = {...} end
function Frame:SetVertexColor(...) self.vertexColor = {...} end
function Frame:SetDesaturated(value) self.desaturated = value end
function Frame:SetDrawLayer(...) self.drawLayer = {...} end
function Frame:SetNormalTexture(value) self.normalTexture = value end
function Frame:SetPushedTexture(value) self.pushedTexture = value end
function Frame:SetHighlightTexture(value) self.highlightTexture = value end
function Frame:SetDisabledTexture(value) self.disabledTexture = value end
function Frame:SetFontObject(value) self.fontObject = value end
function Frame:SetFont(...) self.font = {...} end
function Frame:SetTextColor(...) self.textColor = {...} end
function Frame:SetJustifyH(value) self.justifyH = value end
function Frame:SetJustifyV(value) self.justifyV = value end
function Frame:SetShadowColor(...) self.shadowColor = {...} end
function Frame:SetShadowOffset(...) self.shadowOffset = {...} end
function Frame:EnableMouse(value) self.mouseEnabled = value end
function Frame:SetMouseClickEnabled(value) self.mouseClickEnabled = value end
function Frame:EnableMouseMotion(value) self.mouseMotionEnabled = value end
function Frame:SetMouseMotionEnabled(value) self.mouseMotionEnabled = value end
function Frame:CreateTexture(name, layer)
    local value = setmetatable({ scripts = {}, events = {}, layer = layer }, {__index = Frame})
    self.textures = self.textures or {}
    self.textures[#self.textures + 1] = value
    if name then _G[name] = value end
    return value
end
function Frame:CreateFontString(name, layer, template)
    return self:CreateTexture(name, layer)
end

function CreateFrame(kind, name, parent, template)
    local frame = setmetatable({ scripts = {}, events = {}, enabled = true,
        shown = true, width = 32, height = 32, parent = parent, template = template }, {__index = Frame})
    S.frames[#S.frames + 1] = frame
    if name then _G[name] = frame end
    return frame
end

MerchantFrame = CreateFrame("Frame", "MerchantFrame")
MerchantFrame.selectedTab = 1
MerchantFrameCloseButton = CreateFrame("Button", "MerchantFrameCloseButton", MerchantFrame)
MerchantFrameCloseButton.level = 510
GameTooltip = CreateFrame("Frame", "GameTooltip")
GameTooltip.shown = false
GameTooltip.lines = {}
function GameTooltip:SetOwner(owner, anchor)
    self.owner, self.anchor, self.lines = owner, anchor, {}
end
function GameTooltip:GetOwner() return self.owner end
function GameTooltip:IsOwned(owner) return self.owner == owner end
function GameTooltip:ClearLines() self.lines = {} end
function GameTooltip:AddLine(text, ...) self.lines[#self.lines + 1] = tostring(text) end
function GameTooltip:AddDoubleLine(left, right, ...)
    self.lines[#self.lines + 1] = tostring(left) .. " | " .. tostring(right)
end
function S.tooltip()
    S.button().mouseOver = true
    S.button().scripts.OnEnter(S.button())
    return table.concat(GameTooltip.lines, "\n")
end
function S.button()
    assert(CraftSimVendorBuyButton, "addon button was not created")
    return CraftSimVendorBuyButton
end
function S.clickable()
    local button = S.button()
    return button.shown and button.enabled and button.mouseClickEnabled ~= false
end

function GetTime() return S.time end
C_Timer = {}
function C_Timer.After(delay, callback)
    S.timers[#S.timers + 1] = { at = S.time + delay, callback = callback }
end
function C_Timer.NewTimer(delay, callback)
    local timer = { cancelled = false }
    function timer:Cancel() self.cancelled = true end
    C_Timer.After(delay, function() if not timer.cancelled then callback(timer) end end)
    return timer
end
function S.advance(seconds)
    local target, count = S.time + seconds, 0
    while true do
        local selected, earliest
        for index, timer in ipairs(S.timers) do
            if timer.at <= target and (not earliest or timer.at < earliest) then
                selected, earliest = index, timer.at
            end
        end
        if not selected then break end
        local timer = table.remove(S.timers, selected)
        S.time = timer.at
        timer.callback()
        count = count + 1
        assert(count < 10000, "timer loop did not settle")
    end
    S.time = target
end
function S.event(event, ...)
    for _, frame in ipairs(S.frames) do
        if frame.events[event] and frame.scripts.OnEvent then
            frame.scripts.OnEvent(frame, event, ...)
        end
    end
    S.advance(0)
end
function S.click()
    local button = S.button()
    assert(S.clickable(), "button is not clickable")
    S.sessionAuthorized = true
    S.clickCount = S.clickCount + 1
    S.inClick = true
    local ok, err = pcall(button.scripts.OnClick, button, "LeftButton")
    S.inClick = false
    assert(ok, err)
    S.advance(0)
end
function S.receive(id, quantity)
    S.bags[id] = (S.bags[id] or 0) + quantity
    S.event("BAG_UPDATE_DELAYED")
end
function S.open()
    MerchantFrame.shown = true
    S.event("MERCHANT_SHOW")
end
function S.close()
    S.event("MERCHANT_CLOSED")
    MerchantFrame:Hide()
end
function print(message) S.messages[#S.messages + 1] = tostring(message) end
function issecretvalue(value) return false end
function GetMoney() return S.money end
function GetMerchantNumItems()
    S.counters.merchantScans = S.counters.merchantScans + 1
    return #S.offers
end
function GetMerchantItemID(slot)
    S.counters.merchantIDReads = S.counters.merchantIDReads + 1
    return S.offers[slot] and S.offers[slot].id
end
function GetMerchantItemMaxStack(slot) return S.offers[slot].maximum end
function GetMerchantItemCostInfo(slot) return S.offers[slot].costCount or 0 end
function BuyMerchantItem(slot, quantity)
    assert(S.sessionAuthorized, "purchase occurred before any explicit start click")
    local purchase = { slot = slot, quantity = quantity,
        id = GetMerchantItemID(slot), time = S.time, fromClick = S.inClick }
    S.purchases[#S.purchases + 1] = purchase
    -- Observe synchronous request groups without accessing addon internals.
    local group = S.groups[#S.groups]
    if not group or group.time ~= S.time or group.id ~= purchase.id then
        group = { slot = slot, id = purchase.id, time = S.time,
            fromClick = S.inClick, quantity = 0, calls = {} }
        S.groups[#S.groups + 1] = group
    end
    group.quantity = group.quantity + quantity
    group.calls[#group.calls + 1] = purchase
    -- A batch is every request sent at one virtual instant, across reagents.
    local batch = S.batches[#S.batches]
    if not batch or batch.time ~= S.time then
        batch = { time = S.time, fromClick = S.inClick, quantity = 0, calls = 0, items = {} }
        S.batches[#S.batches + 1] = batch
    end
    batch.quantity = batch.quantity + quantity
    batch.calls = batch.calls + 1
    batch.items[purchase.id] = (batch.items[purchase.id] or 0) + quantity
    if S.purchaseHook then S.purchaseHook(purchase, #S.purchases) end
    if S.purchaseError then error(S.purchaseError) end
    -- Inventory changes occur only when a test explicitly delivers a receipt.
end
C_Item = {}
function C_Item.GetItemCount(id, ...)
    S.counters.bagReads = S.counters.bagReads + 1
    return S.bags[id] or 0
end
C_MerchantFrame = {}
function C_MerchantFrame.GetItemInfo(slot)
    S.counters.offerReads = S.counters.offerReads + 1
    return S.offers[slot]
end
function GetCoinTextureString(value) return tostring(value) .. " copper" end
function GetCoinText(value) return tostring(value) .. " copper" end
function hooksecurefunc(target, name, callback)
    if type(target) == "string" then
        target, name, callback = _G, target, name
    end
    local before = target[name]
    target[name] = function(...)
        if before then before(...) end
        callback(...)
    end
end
function MerchantFrame_Update() end
SlashCmdList = {}
ERR_INV_FULL = "Inventory is full."
ERR_NOT_ENOUGH_MONEY = "Not enough money."
ERR_ITEM_MAX_COUNT = "You cannot carry any more of those items."
ERR_VENDOR_SOLD_OUT = "That item is currently sold out."
Enum = { GameError = { InventoryFull = 4, NotEnoughMoney = 5,
    ItemMaxCount = 17, VendorSoldOut = 30 } }

CraftSimAPI = {}
local recipeData = {}
function recipeData:GetCrafterUID()
    S.counters.crafterReads = S.counters.crafterReads + 1
    return S.rawMissing and "alt" or "player"
end
local craftSim = {
    CRAFTQ = {
        craftQueue = { craftQueueItems = { { recipeData = recipeData } } },
        UI = { UpdateQueueDisplay = function() end },
    },
    SHOPPING = {},
    UTIL = { GetPlayerCrafterUID = function() return "player" end },
}
S.craftSim = craftSim
function CraftSimAPI:GetCraftSim() return craftSim end
function CraftSimAPI:RegisterEvents(listener, events)
    S.craftSimListener = listener
end
function craftSim.SHOPPING:GetMissingReagentsFromCraftQueue()
    S.counters.missingQueries = S.counters.missingQueries + 1
    local result = {}
    for id, required in pairs(S.need) do
        local missing = S.rawMissing and required or math.max(0, required - (S.bags[id] or 0))
        if missing > 0 then
            result[#result + 1] = { itemID = id, quantity = missing, itemName = "Reagent " .. id }
        end
    end
    return result
end

-- Optional real AuctionatorSync module integration. Searches are deliberately
-- opaque to the addon; only mocked public conversion APIs can interpret them.
function S.setupShopping(quantity)
    S.craftSim.CONST = { AUCTIONATOR_SHOPPING_LIST_QUEUE_NAME = "CraftSim CraftQueue" }
    local lists, terms, nextSearch = {}, {}, 0
    S.shopping = { changes = 0 }
    local function Encode(value)
        nextSearch = nextSearch + 1
        local search, copy = "search-" .. nextSearch, {}
        for key, item in pairs(value) do copy[key] = item end
        terms[search] = copy
        return search
    end
    local listName = S.craftSim.CONST.AUCTIONATOR_SHOPPING_LIST_QUEUE_NAME
    lists[listName] = { Encode({ searchString = "Reagent 1001", isExact = true, quantity = quantity }) }
    local function Caller(caller) assert(caller == "CraftSimVendorBuy") end
    local api = {}
    function api.GetShoppingListItems(caller, name)
        Caller(caller)
        local result = {}
        for index, search in ipairs(assert(lists[name], "unknown list")) do result[index] = search end
        return result
    end
    function api.ConvertFromSearchString(caller, search)
        Caller(caller)
        local result = {}
        for key, value in pairs(assert(terms[search], "unknown search")) do result[key] = value end
        return result
    end
    function api.ConvertToSearchString(caller, value) Caller(caller); return Encode(value) end
    function api.AlterShoppingListItem(caller, name, oldSearch, newSearch)
        Caller(caller)
        for index, search in ipairs(assert(lists[name])) do
            if search == oldSearch then
                lists[name][index] = newSearch
                S.shopping.changes = S.shopping.changes + 1
                return
            end
        end
        error("old search missing")
    end
    function api.DeleteShoppingListItem(caller, name, oldSearch)
        Caller(caller)
        for index, search in ipairs(assert(lists[name])) do
            if search == oldSearch then
                table.remove(lists[name], index)
                S.shopping.changes = S.shopping.changes + 1
                return
            end
        end
        error("old search missing")
    end
    function S.shopping.quantity()
        local search = lists[listName][1]
        return search and terms[search].quantity or 0
    end
    Auctionator = { API = { v1 = api } }
end
