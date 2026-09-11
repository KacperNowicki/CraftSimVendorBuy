local addonName = ...
local events = CreateFrame("Frame")
local button, merchantOpen, refreshQueued, buying
local warnings = {}
-- Purchase receipts only, never a second craft queue. Unconfirmed requests stay
-- blocked across merchant changes; no timer or event can submit a purchase.
local pending = {}
local Refresh, RequestRefresh
local craftSimEventsRegistered

local function Print(message)
    print("|cff33ccffCraftSim Vendor Buy:|r " .. message)
end

local function Debug(message)
    if CraftSimVendorBuyDB and CraftSimVendorBuyDB.debug then
        Print("[debug] " .. message)
    end
end

local function Warn(message)
    if not warnings[message] then
        warnings[message] = true
        Print(message)
    end
end

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function Integer(value, minimum)
    return not IsSecret(value) and type(value) == "number"
        and value >= minimum and value < math.huge and value == math.floor(value)
end

local function APIsReady()
    for _, name in ipairs({ "GetMerchantNumItems", "GetMerchantItemID",
        "GetMerchantItemMaxStack", "GetMerchantItemCostInfo", "BuyMerchantItem", "GetMoney" }) do
        if type(_G[name]) ~= "function" then
            Warn("Required API unavailable: " .. name .. "; buying disabled.")
            return false
        end
    end
    if not C_MerchantFrame or type(C_MerchantFrame.GetItemInfo) ~= "function"
        or not C_Item or type(C_Item.GetItemCount) ~= "function" then
        Warn("Retail merchant/item APIs unavailable; buying disabled.")
        return false
    end
    return true
end

local function Missing()
    if not CraftSimAPI or type(CraftSimAPI.GetCraftSim) ~= "function" then
        Debug("CraftSimAPI:GetCraftSim unavailable.")
        return nil
    end
    local ok, craftSim = pcall(CraftSimAPI.GetCraftSim, CraftSimAPI)
    if not ok or type(craftSim) ~= "table" then
        Warn("Cannot access CraftSim; skipping.")
        return nil
    end
    local shopping, queue = craftSim.SHOPPING, craftSim.CRAFTQ
    if not shopping or type(shopping.GetMissingReagentsFromCraftQueue) ~= "function" then
        Warn("CraftSim Shopping missing-reagent API unavailable; skipping.")
        return nil
    end
    if not queue or not queue.craftQueue or type(queue.craftQueue.craftQueueItems) ~= "table" then
        Debug("CraftSim Craft Queue is not initialized.")
        return nil
    end
    -- This is a temporary display calculation cache in installed CraftSim.
    -- Never read a partially populated cache or mutate CraftSim to bypass it.
    if queue.itemCountCache ~= nil then
        Debug("CraftSim is updating its queue inventory cache; retry on refresh.")
        return nil
    end
    local entries
    ok, entries = pcall(shopping.GetMissingReagentsFromCraftQueue, shopping, false)
    if not ok or type(entries) ~= "table" then
        Warn("CraftSim missing-reagent query failed; skipping. Enable /csvb debug for details.")
        Debug(tostring(entries))
        return nil
    end
    local result, duplicates = {}, {}
    for _, entry in pairs(entries) do
        if type(entry) ~= "table" or not Integer(entry.itemID, 1) or not Integer(entry.quantity, 0) then
            Warn("Invalid CraftSim reagent entry; skipping the query.")
            return nil
        end
        local id = entry.itemID
        if result[id] then
            duplicates[id] = true
            Warn("Ambiguous duplicate CraftSim itemID " .. id .. "; skipping that item.")
        else
            result[id] = { quantity = entry.quantity, name = entry.itemName }
        end
        Debug("Missing itemID=" .. id .. " quantity=" .. entry.quantity)
    end
    for id in pairs(duplicates) do result[id] = nil end
    return result
end

local function BagCount(id)
    local count = C_Item.GetItemCount(id, false, false, false, false)
    if not Integer(count, 0) then error("Cannot safely read bag count for itemID " .. id) end
    return count
end

local function Reconcile()
    for id, receipt in pairs(pending) do
        if BagCount(id) >= receipt.before + receipt.quantity then
            Debug("Received itemID=" .. id .. " quantity=" .. receipt.quantity)
            pending[id] = nil
        end
    end
end

local function Offer(slot, id)
    if GetMerchantItemID(slot) ~= id then return nil end
    Debug("Matched itemID=" .. id .. " merchant slot=" .. slot)
    local info = C_MerchantFrame.GetItemInfo(slot)
    if not info or IsSecret(info) then
        Warn("Merchant information unavailable for slot " .. slot .. "; skipping.")
        return nil
    end
    for _, key in ipairs({ "isPurchasable", "hasExtendedCost", "currencyID", "spellID" }) do
        if IsSecret(info[key]) then
            Warn("Restricted merchant information at slot " .. slot .. "; skipping.")
            return nil
        end
    end
    if info.isPurchasable ~= true then
        Debug("Skip slot " .. slot .. ": not purchasable.")
        return nil
    end
    if info.hasExtendedCost ~= false then
        Debug("Skip slot " .. slot .. ": extended cost or unknown cost flag.")
        return nil
    end
    -- Check both the flag and the cost list, including mixed gold/token offers.
    local costs = GetMerchantItemCostInfo(slot)
    if not Integer(costs, 0) or costs ~= 0 then
        Debug("Skip slot " .. slot .. ": extended cost list is nonempty or unknown.")
        return nil
    end
    if (info.currencyID and info.currencyID ~= 0) or (info.spellID and info.spellID ~= 0) then
        Debug("Skip slot " .. slot .. ": currency or spell offer.")
        return nil
    end
    local maximum = GetMerchantItemMaxStack(slot)
    if not Integer(info.price, 0) or not Integer(info.stackCount, 1)
        or not Integer(info.numAvailable, -1) or not Integer(maximum, 1) then
        Warn("Unknown price, bundle size, stock or purchase limit at slot " .. slot .. "; skipping.")
        return nil
    end
    maximum = math.floor(maximum / info.stackCount) * info.stackCount
    if maximum == 0 or info.numAvailable == 0 then
        Debug("Skip slot " .. slot .. ": no purchasable stock/bundle.")
        return nil
    end
    return { slot = slot, id = id, price = info.price, bundle = info.stackCount,
        stock = info.numAvailable, maximum = maximum, name = info.name }
end

local function Quantity(offer, need, money)
    local quantity = need
    if offer.stock ~= -1 then quantity = math.min(quantity, offer.stock) end
    if offer.price > 0 then
        quantity = math.min(quantity, math.floor(money / offer.price) * offer.bundle)
    end
    return math.floor(quantity / offer.bundle) * offer.bundle
end

local function Plan()
    if not APIsReady() then return {} end
    Reconcile()
    local missing = Missing()
    if not missing then return {} end
    local money, count = GetMoney(), GetMerchantNumItems()
    if not Integer(money, 0) or not Integer(count, 0) then
        Warn("Merchant count or gold unavailable; skipping.")
        return {}
    end
    local plan, remaining = {}, {}
    for id, entry in pairs(missing) do remaining[id] = entry.quantity end
    for slot = 1, count do
        local id = GetMerchantItemID(slot)
        if Integer(id, 1) and remaining[id] and remaining[id] > 0 then
            if pending[id] then
                Debug("Skip itemID=" .. id .. ": previous purchase still unconfirmed in bags.")
            else
                local offer = Offer(slot, id)
                if offer then
                    local quantity = Quantity(offer, remaining[id], money)
                    if quantity > 0 then
                        offer.quantity = quantity
                        plan[#plan + 1] = offer
                        remaining[id] = remaining[id] - quantity
                        money = money - (quantity / offer.bundle) * offer.price
                        Debug("Plan itemID=" .. id .. " quantity=" .. quantity .. " max/call=" .. offer.maximum)
                    else
                        Debug("Skip itemID=" .. id .. ": insufficient gold/stock or need smaller than bundle.")
                    end
                end
            end
        end
    end
    return plan
end

local function AtMerchant()
    return merchantOpen and MerchantFrame and MerchantFrame:IsShown() and MerchantFrame.selectedTab == 1
end

local function Buy()
    if buying or not AtMerchant() then return end
    buying = true
    button:Disable()
    local types, total, boughtIDs = 0, 0, {}
    local ok, err = pcall(function()
        -- Rebuild now, never use the tooltip/display plan for purchases.
        local plan = Plan()
        local budget = GetMoney()
        if not Integer(budget, 0) then error("Cannot safely read gold.") end
        for _, planned in ipairs(plan) do
            local left, stockLeft = planned.quantity, planned.stock
            while left > 0 and AtMerchant() do
                local missing = Missing()
                local entry = missing and missing[planned.id]
                if not entry or entry.quantity <= 0 then break end
                local offer = Offer(planned.slot, planned.id)
                if not offer then break end
                -- Keep a local stock/gold budget as server updates may lag calls.
                if stockLeft ~= -1 then
                    offer.stock = offer.stock == -1 and stockLeft or math.min(offer.stock, stockLeft)
                end
                local money = GetMoney()
                if not Integer(money, 0) then error("Cannot safely read gold.") end
                budget = math.min(budget, money)
                local quantity = Quantity(offer, math.min(left, entry.quantity, offer.maximum), budget)
                if quantity <= 0 then break end
                local receipt = pending[offer.id]
                if not receipt then
                    receipt = { before = BagCount(offer.id), quantity = 0 }
                    pending[offer.id] = receipt
                end
                -- Reserve before calling: even an API exception must not cause a retry.
                receipt.quantity = receipt.quantity + quantity
                Debug("BuyMerchantItem(" .. offer.slot .. ", " .. quantity .. ") itemID=" .. offer.id)
                BuyMerchantItem(offer.slot, quantity)
                total = total + quantity
                if not boughtIDs[offer.id] then
                    boughtIDs[offer.id] = true
                    types = types + 1
                end
                left = left - quantity
                if stockLeft ~= -1 then stockLeft = stockLeft - quantity end
                budget = budget - (quantity / offer.bundle) * offer.price
            end
        end
    end)
    buying = false
    if not ok then
        Warn("Purchase stopped: " .. tostring(err))
    end
    -- BuyMerchantItem has no success result. Do not claim server acceptance.
    if total > 0 then
        Print("Requested purchases for " .. types .. " reagent types, " .. total .. " items total.")
    elseif ok then
        Print("No missing reagents can currently be purchased here.")
    end
    RequestRefresh()
end

local function Tooltip()
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:AddLine("CraftSim Vendor Buy", 1, 0.82, 0)
    GameTooltip:AddLine("Buy missing CraftSim reagents")
    local ok, plan = pcall(Plan)
    if ok then
        for i, offer in ipairs(plan) do
            if i > 15 then
                GameTooltip:AddLine("More reagents available...")
                break
            end
            local name = not IsSecret(offer.name) and type(offer.name) == "string" and offer.name
                or "Reagent"
            GameTooltip:AddDoubleLine(name, tostring(offer.quantity), 1, 1, 1, 1, 1, 1)
        end
        if #plan == 0 then GameTooltip:AddLine("No purchasable missing reagents.", 0.7, 0.7, 0.7) end
    end
    if next(pending) then
        GameTooltip:AddLine("Waiting for previous purchases in bags. /csvb status", 1, 0.8, 0, true)
    end
    GameTooltip:Show()
end

Refresh = function()
    if not MerchantFrame then return end
    if not button then
        button = CreateFrame("Button", "CraftSimVendorBuyButton", MerchantFrame, "UIPanelButtonTemplate")
        button:SetText("")
        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetTexture("Interface\\AddOns\\CraftSimVendorBuy\\Media\\Icon.tga")
        button.icon:SetPoint("TOPLEFT", 4, -4)
        button.icon:SetPoint("BOTTOMRIGHT", -4, 4)
        button.icon:SetTexCoord(0, 1, 0, 1)
        button:RegisterForClicks("LeftButtonUp")
        button:SetScript("OnClick", Buy)
        button:SetScript("OnEnter", Tooltip)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        MerchantFrame:HookScript("OnHide", function() button:Hide() end)
        if type(MerchantFrame_Update) == "function" then
            hooksecurefunc("MerchantFrame_Update", RequestRefresh)
        end
    end
    -- Match the title-bar control size. If PSL is present, sit to its left
    -- instead of covering its coin button; PSL remains entirely optional.
    local anchor = ProfessionShoppingList_MerchantButton
    if not anchor or not anchor:IsShown() then anchor = MerchantFrameCloseButton end
    if not anchor then
        button:Hide()
        Warn("Merchant close button unavailable; cannot safely position the buy button.")
        return
    end
    -- UIPanelCloseButton (also used by PSL) has frameLevel=510 in Retail.
    -- An ordinary panel button otherwise draws beneath the merchant title art.
    button:SetFrameStrata(anchor:GetFrameStrata())
    button:SetFrameLevel(math.max(anchor:GetFrameLevel(), MerchantFrame:GetFrameLevel() + 1) + 1)
    button:SetSize(anchor:GetWidth(), anchor:GetHeight())
    button:ClearAllPoints()
    button:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -2, 0)
    button:SetShown(AtMerchant() and true or false)
    if not AtMerchant() then return end
    local ok, plan = pcall(Plan)
    if not ok then Warn("Refresh skipped: " .. tostring(plan)) end
    local enabled = not buying and ok and #plan > 0
    button:SetEnabled(enabled)
    button.icon:SetDesaturated(not enabled)
    button.icon:SetAlpha(enabled and 1 or 0.65)
end

RequestRefresh = function()
    if not merchantOpen or refreshQueued then return end
    refreshQueued = true
    -- Let CraftSim finish its BAG_UPDATE_DELAYED handlers first.
    C_Timer.After(0, function()
        refreshQueued = false
        Refresh()
    end)
end

local function RegisterCraftSimEvents()
    if craftSimEventsRegistered or not CraftSimAPI or type(CraftSimAPI.RegisterEvents) ~= "function" then return end
    local listener = { CRAFTSIM_CRAFTQUEUE_QUEUE_PROCESS_FINISHED = function() RequestRefresh() end }
    local ok, err = pcall(CraftSimAPI.RegisterEvents, CraftSimAPI, listener,
        { "CRAFTSIM_CRAFTQUEUE_QUEUE_PROCESS_FINISHED" })
    if ok then
        craftSimEventsRegistered = true
    else
        Debug("CraftSim queue event registration skipped: " .. tostring(err))
    end
end

events:SetScript("OnEvent", function(_, event, arg)
    if event == "ADDON_LOADED" then
        if arg == addonName then
            if type(CraftSimVendorBuyDB) ~= "table" then CraftSimVendorBuyDB = {} end
        end
        RegisterCraftSimEvents()
    elseif event == "MERCHANT_SHOW" then
        merchantOpen = true
        warnings = {}
        RegisterCraftSimEvents()
        Debug("APIs: CraftSimAPI:GetCraftSim().SHOPPING:GetMissingReagentsFromCraftQueue(false); " ..
            "C_MerchantFrame.GetItemInfo; GetMerchantItemID/MaxStack/CostInfo; BuyMerchantItem.")
    elseif event == "MERCHANT_CLOSED" then
        merchantOpen = false
        if button then button:Hide() end
    end
    -- Reconcile even after closing a merchant, but never send more purchases.
    if event == "BAG_UPDATE_DELAYED" and next(pending) then
        local ok, err = pcall(Reconcile)
        if not ok then Warn("Purchase receipt check skipped: " .. tostring(err)) end
    end
    RequestRefresh()
end)

for _, event in ipairs({ "ADDON_LOADED", "MERCHANT_SHOW", "MERCHANT_CLOSED", "MERCHANT_UPDATE",
    "MERCHANT_FILTER_ITEM_UPDATE", "BAG_UPDATE_DELAYED", "PLAYER_MONEY", "GET_ITEM_INFO_RECEIVED" }) do
    events:RegisterEvent(event)
end

SLASH_CRAFTSIMVENDORBUY1 = "/csvb"
SlashCmdList.CRAFTSIMVENDORBUY = function(message)
    message = (message or ""):lower():match("^%s*(.-)%s*$")
    if message == "debug" or message == "debug on" or message == "debug off" then
        CraftSimVendorBuyDB = CraftSimVendorBuyDB or {}
        if message == "debug" then
            CraftSimVendorBuyDB.debug = not CraftSimVendorBuyDB.debug
        else
            CraftSimVendorBuyDB.debug = message == "debug on"
        end
        Print("Debug " .. (CraftSimVendorBuyDB.debug and "on." or "off."))
    elseif message == "status" then
        Print(merchantOpen and "Merchant open; refreshing from CraftSim." or "No merchant open.")
        for id, receipt in pairs(pending) do
            Print("Unconfirmed itemID=" .. id .. ", requested=" .. receipt.quantity ..
                ", bag count before=" .. receipt.before .. ". Check bags and Blizzard errors before /reload to retry.")
        end
    else
        Print("/csvb debug [on|off] toggles diagnostics; /csvb status shows pending requests.")
    end
    RequestRefresh()
end
