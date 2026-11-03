local addonName = ...
local events = CreateFrame("Frame")
local button, merchantOpen, refreshQueued, buying, active, view, order, lastOrder
local warnings = {}
-- A real click starts a bounded order. Only that order can continue buying;
-- cancellation invalidates its queued callbacks without discarding receipts.
local receipts = {}
local progress = { requested = 0, received = 0 }
local lastError, syncNotice, unavailableReason
local RECOVERY_DELAY, QUIET_DELAY = 2, 1
local BATCH_DELAY, STALL_DELAY = 0.05, 5
-- One batch may span several reagents. Items are bounded by the configurable
-- batch size; calls are a hard safety bound for small vendor stack limits.
local DEFAULT_BATCH_ITEMS, MAX_BATCH_ITEMS, BATCH_CALLS = 10000, 50000, 50
local missingCache, missingDirty = nil, true
local hookedQueueUI
local Refresh, RequestRefresh
local QueueNext, StopOrder, SendNext
local BagCount
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
    unavailableReason = message
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

local function BatchItems()
    local value = type(CraftSimVendorBuyDB) == "table" and CraftSimVendorBuyDB.batchItems
    if not Integer(value, 1) then return DEFAULT_BATCH_ITEMS end
    return math.min(value, MAX_BATCH_ITEMS)
end

-- Rounding up buys at most one partial vendor bundle extra per reagent, so a
-- queue that needs 7 of an item sold in fives can actually be completed.
local function RoundUp()
    return not (type(CraftSimVendorBuyDB) == "table" and CraftSimVendorBuyDB.roundUp == false)
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

local function Name(value, fallback)
    return not IsSecret(value) and type(value) == "string" and value ~= "" and value or fallback
end

local function Missing()
    if not CraftSimAPI or type(CraftSimAPI.GetCraftSim) ~= "function" then
        unavailableReason = "CraftSim is not loaded."
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
        unavailableReason = "CraftSim's Craft Queue is not ready."
        Debug("CraftSim Craft Queue is not initialized.")
        return nil
    end
    -- This is a temporary display calculation cache in installed CraftSim.
    -- Never read a partially populated cache or mutate CraftSim to bypass it.
    if queue.itemCountCache ~= nil then
        unavailableReason = "CraftSim is updating its queue."
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
    -- CraftSim counts inventory for the queue's crafters. A separate shopping
    -- character's bags are additional stock and must not be bought again.
    local shoppingCharacter = false
    local util = craftSim.UTIL
    if util and type(util.GetPlayerCrafterUID) == "function" then
        local gotUID, playerUID = pcall(util.GetPlayerCrafterUID, util)
        if gotUID and not IsSecret(playerUID) and type(playerUID) == "string" and playerUID ~= "" then
            shoppingCharacter = true
            for _, item in pairs(queue.craftQueue.craftQueueItems) do
                local recipe = item.recipeData
                if not recipe or type(recipe.GetCrafterUID) ~= "function" then
                    shoppingCharacter = false
                    break
                end
                local gotCrafter, uid = pcall(recipe.GetCrafterUID, recipe)
                if not gotCrafter or IsSecret(uid) or type(uid) ~= "string" or uid == "" or uid == playerUID then
                    shoppingCharacter = false
                    break
                end
            end
        end
    end
    local result = {}
    for _, entry in pairs(entries) do
        if type(entry) ~= "table" or not Integer(entry.itemID, 1) or not Integer(entry.quantity, 0) then
            Warn("Invalid CraftSim reagent entry; skipping the query.")
            return nil
        end
        local id = entry.itemID
        local quantity = entry.quantity
        if shoppingCharacter then quantity = math.max(0, quantity - BagCount(id)) end
        if result[id] then
            -- CraftSim maps several queue reagents (e.g. soulbound variants) to
            -- one purchasable item and subtracts the same inventory from each.
            -- Their sum could overbuy; the largest entry never exceeds true need.
            result[id].quantity = math.max(result[id].quantity, quantity)
            result[id].name = Name(result[id].name, entry.itemName)
            Debug("Merged duplicate CraftSim itemID " .. id .. " conservatively.")
        else
            result[id] = { quantity = quantity, name = entry.itemName, quality = entry.qualityID }
        end
        Debug("Missing itemID=" .. id .. " quantity=" .. entry.quantity)
    end
    return result
end

BagCount = function(id)
    local count = C_Item.GetItemCount(id, false, false, false, false)
    if not Integer(count, 0) then error("Cannot safely read bag count for itemID " .. id) end
    return count
end

local function LineReceived(line)
    return math.min(line.quantity, math.max(0, line.receipt.received - line.startReceived))
end

local function BatchProgress(batch)
    local received, quantity = 0, 0
    for _, line in ipairs(batch.lines) do
        received = received + LineReceived(line)
        quantity = quantity + line.quantity
    end
    return received, quantity
end

local function Reconcile()
    for id, receipt in pairs(receipts) do
        local received = math.min(receipt.requested, math.max(0, BagCount(id) - receipt.before))
        if received > receipt.received then
            local delta = received - receipt.received
            receipt.received = received
            progress.received = progress.received + delta
            local line = active and active.byId[id]
            if line and line.receipt == receipt then active.lastProgress = GetTime() end
            if receipt.sync and CraftSimVendorBuySync then
                local ok, reason = CraftSimVendorBuySync.Apply(receipt.sync, received)
                if not ok then
                    syncNotice = "Auctionator entry changed or could not be updated; left unchanged."
                    Debug("Auctionator sync skipped: " .. tostring(reason))
                end
            end
            Debug("Received itemID=" .. id .. " confirmed=" .. received .. "/" .. receipt.requested)
        end
    end
    local done = active ~= nil
    if active then
        local run = active.order
        for _, line in ipairs(active.lines) do
            local received = LineReceived(line)
            local delta = received - line.credited
            if delta > 0 then
                line.credited = received
                if run then
                    -- Rounded-up bundles may deliver more than the target.
                    local remaining = run.remaining[line.id] or 0
                    run.received = run.received + math.min(delta, remaining)
                    run.remaining[line.id] = math.max(0, remaining - delta)
                end
            end
            if received < line.quantity then done = false end
        end
    end
    -- Completed receipts can never receive more items (their Auctionator sync
    -- already saw the full amount); drop them so later bag events stop
    -- re-reading them. Receipts in the active batch must stay.
    for id, receipt in pairs(receipts) do
        local line = active and active.byId[id]
        if receipt.received >= receipt.requested and not (line and line.receipt == receipt) then
            receipts[id] = nil
        end
    end
    if done and not active.submitting then
        local completed = active
        Debug("Batch received: " .. completed.quantity .. " items in " .. #completed.lines .. " reagents")
        active = nil
        if order and completed.order == order then QueueNext(order) end
    end
end

local function CanRecover()
    return active and GetTime() - active.started >= RECOVERY_DELAY
        and GetTime() - active.lastProgress >= QUIET_DELAY
end

local function CachedMissing(force)
    if force or missingDirty or not missingCache then
        missingCache = Missing()
        missingDirty = missingCache == nil
    end
    if not missingCache then return nil end
    local copy = {}
    for id, entry in pairs(missingCache) do
        copy[id] = { quantity = entry.quantity, name = entry.name, quality = entry.quality }
    end
    return copy
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
    if not IsSecret(info.numAvailable) and info.numAvailable == 0 then return nil, "Merchant out of stock." end
    if info.isPurchasable ~= true then
        Debug("Skip slot " .. slot .. ": not purchasable.")
        return nil, "This reagent cannot currently be purchased."
    end
    if info.hasExtendedCost ~= false then
        Debug("Skip slot " .. slot .. ": extended cost or unknown cost flag.")
        return nil, "This reagent requires a currency or item payment."
    end
    -- Check both the flag and the cost list, including mixed gold/token offers.
    local costs = GetMerchantItemCostInfo(slot)
    if not Integer(costs, 0) or costs ~= 0 then
        Debug("Skip slot " .. slot .. ": extended cost list is nonempty or unknown.")
        return nil, "This reagent requires a currency or item payment."
    end
    if (info.currencyID and info.currencyID ~= 0) or (info.spellID and info.spellID ~= 0) then
        Debug("Skip slot " .. slot .. ": currency or spell offer.")
        return nil, "Currency and spell offers are not supported."
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

local function Bundles(offer, need)
    if RoundUp() then return math.ceil(need / offer.bundle) end
    return math.floor(need / offer.bundle)
end

-- need is the remaining target; cap is a bundle multiple bounding this request.
local function Quantity(offer, need, money, cap)
    if need <= 0 then return 0 end
    local quantity = Bundles(offer, need) * offer.bundle
    if cap then quantity = math.min(quantity, cap) end
    if offer.stock ~= -1 then quantity = math.min(quantity, offer.stock) end
    if offer.price > 0 then
        quantity = math.min(quantity, math.floor(money / offer.price) * offer.bundle)
    end
    return math.floor(quantity / offer.bundle) * offer.bundle
end

local function BatchCap(offer, itemsLeft)
    return math.floor(itemsLeft / offer.bundle) * offer.bundle
end

local function BuildView(limits, force)
    unavailableReason = nil
    local data = { state = "blocked", reason = "CraftSim is not ready.", needs = {}, targets = {},
        offers = {}, total = 0, cost = 0, batch = 0 }
    if not APIsReady() then
        data.reason = unavailableReason
        return data
    end
    Reconcile()
    local missing = CachedMissing(force)
    if missing then
        local money, count = GetMoney(), GetMerchantNumItems()
        if not Integer(money, 0) or not Integer(count, 0) then
            data.reason = "Merchant information or gold is not available."
            return data
        end
        data.valid = true
        for id, entry in pairs(missing) do
            if limits then entry.quantity = math.min(entry.quantity, limits[id] or 0) end
            data.total = data.total + entry.quantity
        end
        local seen, priced, chosen, reason = {}, {}, {}, "No missing reagents are sold by this merchant."
        local batchItems = BatchItems()
        for slot = 1, count do
            local id = GetMerchantItemID(slot)
            local entry = Integer(id, 1) and missing[id]
            if entry and entry.quantity > 0 then
                local offer, failure = Offer(slot, id)
                if not seen[id] then
                    seen[id] = true
                    data.needs[#data.needs + 1] = { id = id, name = Name(entry.name, "Reagent"), quantity = entry.quantity }
                end
                if offer then
                    offer.name = Name(entry.name, Name(offer.name, "Reagent"))
                    offer.quality = entry.quality
                    offer.need = entry.quantity
                    local cap = math.min(offer.maximum * BATCH_CALLS, BatchCap(offer, batchItems))
                    offer.quantity = Quantity(offer, entry.quantity, money, cap)
                    data.targets[id] = entry.quantity
                    if not priced[id] then
                        data.cost = data.cost + Bundles(offer, entry.quantity) * offer.price
                        priced[id] = true
                    end
                    if offer.quantity > 0 and not chosen[id] then
                        chosen[id] = true
                        data.offers[#data.offers + 1] = offer
                    end
                    if offer.quantity == 0 then
                        if cap < offer.bundle then
                            reason = "Batch size is smaller than a vendor bundle; raise it with /csvb batch."
                        elseif not RoundUp() and entry.quantity < offer.bundle then
                            reason = "Need fewer items than a vendor bundle (/csvb roundup on buys it)."
                        else
                            reason = "Not enough gold for a vendor bundle."
                        end
                    end
                else
                    reason = failure or "Merchant information is not available."
                end
            end
        end
        data.offer = data.offers[1]
        local left = batchItems
        for _, offer in ipairs(data.offers) do
            local take = math.min(offer.quantity, BatchCap(offer, left))
            data.batch = data.batch + take
            left = left - take
        end
        data.reason = reason
        if data.total == 0 then
            data.state, data.reason = "complete", "All queue reagents have been acquired."
        elseif data.offer then
            data.state = "ready"
        end
    else
        data.reason = unavailableReason or "CraftSim is updating its queue."
    end
    if active then
        data.state = CanRecover() and "recover" or "waiting"
        data.reason = data.state == "recover" and "Check purchase and enable retry"
            or "Waiting for purchased items"
    end
    return data
end

local function AtMerchant()
    return merchantOpen and MerchantFrame and MerchantFrame:IsShown() and MerchantFrame.selectedTab == 1
end

StopOrder = function(reason, problem)
    if not order then return end
    lastOrder = order
    order = nil
    missingDirty = true
    if problem then lastError = reason end
    Print(reason .. " " .. lastOrder.received .. " / " .. lastOrder.total .. " items confirmed.")
    RequestRefresh()
end

local function Watch(batch)
    C_Timer.After(0.1, function()
        if active ~= batch then return end
        if order and batch.order == order and not AtMerchant() then
            StopOrder("Merchant closed or tab changed.", false)
        end
        local ok, err = pcall(Reconcile)
        if not ok then
            lastError = "Cannot check received items: " .. tostring(err)
            StopOrder(lastError, true)
        end
        if active == batch then
            if order and batch.order == order and GetTime() - batch.lastProgress >= STALL_DELAY then
                StopOrder("Delivery stalled; check bags and purchase errors before retrying.", true)
            end
            RequestRefresh()
            if order or not CanRecover() then Watch(batch) end
        end
    end)
end

QueueNext = function(run)
    if order ~= run or run.queued then return end
    run.queued = true
    C_Timer.After(BATCH_DELAY, function()
        run.queued = false
        if order == run and not active then SendNext(run) end
    end)
end

-- Reuse an unfinished receipt for the item, or start a fresh bag baseline.
local function ReceiptFor(offer)
    local count = BagCount(offer.id)
    local snapshot, reason
    if CraftSimVendorBuySync then
        snapshot, reason = CraftSimVendorBuySync.Capture(offer.id, offer.name, offer.quality)
    end
    local receipt = receipts[offer.id]
    local changedList = receipt and snapshot and (not receipt.sync
        or snapshot.expectedSearch ~= receipt.sync.expectedSearch
        or snapshot.listName ~= receipt.sync.listName)
    if not receipt or receipt.received == receipt.requested or count < receipt.before + receipt.received
        or changedList or (receipt.sync and (receipt.sync.finished or receipt.sync.stopped)) then
        receipt = { before = count, requested = 0, received = 0, sync = snapshot }
        receipts[offer.id] = receipt
        if reason then Debug("Auctionator snapshot: " .. reason) end
    end
    return receipt
end

SendNext = function(run, prepared)
    if order ~= run or buying or active then return end
    if not AtMerchant() then
        StopOrder("Merchant closed or tab changed.", false)
        return
    end
    buying = true
    local submittedBatch
    local ok, err = pcall(function()
        -- Recalculate queue need once per batch, then check each vendor request.
        -- The start-click limits prevent queue changes or stale inventory from
        -- expanding the order after it has already been authorized.
        local data = prepared or BuildView(run.remaining, true)
        run.display = data
        if order ~= run then return end
        if not data.valid then
            run.unavailableSince = run.unavailableSince or GetTime()
            if GetTime() - run.unavailableSince >= STALL_DELAY then
                StopOrder(data.reason or "CraftSim is unavailable.", true)
            else
                QueueNext(run)
            end
            return
        end
        run.unavailableSince = nil
        if not data.offer then
            StopOrder(data.total == 0 and "Vendor order complete." or data.reason, false)
            return
        end
        local batch = { quantity = 0, started = GetTime(), lastProgress = GetTime(),
            order = run, submitting = true, calls = 0, lines = {}, byId = {} }
        active, submittedBatch = batch, batch
        local budget = GetMoney()
        if not Integer(budget, 0) then error("Cannot safely read gold.") end
        local itemsLeft = BatchItems()
        -- A bounded burst across reagents: never more than the batch size or
        -- BATCH_CALLS legal requests. Reserve gold and stock locally because
        -- the server may update them later.
        for _, offer in ipairs(data.offers) do
            if itemsLeft <= 0 or batch.calls >= BATCH_CALLS or order ~= run or not AtMerchant() then break end
            local left, stockLeft, line = offer.need, offer.stock, nil
            while left > 0 and itemsLeft > 0 and batch.calls < BATCH_CALLS and order == run and AtMerchant() do
                local current = Offer(offer.slot, offer.id)
                if not current then break end
                if current.stock ~= -1 then
                    stockLeft = stockLeft == -1 and current.stock or math.min(stockLeft, current.stock)
                end
                if stockLeft ~= -1 then current.stock = stockLeft end
                local money = GetMoney()
                if not Integer(money, 0) then error("Cannot safely read gold.") end
                budget = math.min(budget, money)
                local cap = math.min(current.maximum, BatchCap(current, itemsLeft))
                local quantity = Quantity(current, left, budget, cap)
                if quantity <= 0 then break end
                if not line then
                    local receipt = ReceiptFor(offer)
                    line = { id = offer.id, name = offer.name, receipt = receipt, quantity = 0,
                        startReceived = receipt.received, credited = 0, maximum = current.maximum }
                    batch.lines[#batch.lines + 1] = line
                    batch.byId[offer.id] = line
                end
                line.receipt.requested = line.receipt.requested + quantity
                progress.requested = progress.requested + quantity
                line.quantity = line.quantity + quantity
                batch.quantity = batch.quantity + quantity
                batch.calls = batch.calls + 1
                left = left - quantity
                itemsLeft = itemsLeft - quantity
                budget = budget - quantity / current.bundle * current.price
                if stockLeft ~= -1 then stockLeft = stockLeft - quantity end
                Debug("BuyMerchantItem(" .. current.slot .. ", " .. quantity .. ") itemID=" .. current.id)
                BuyMerchantItem(current.slot, quantity)
            end
        end
        if batch.quantity == 0 then
            active = nil
            StopOrder("Merchant offer changed; no items requested.", false)
        end
    end)
    if submittedBatch then submittedBatch.submitting = false end
    buying = false
    if not ok then
        lastError = "Purchase stopped: " .. tostring(err)
        StopOrder(lastError, true)
    end
    if submittedBatch and active == submittedBatch then
        -- Synchronous receipts may already cover the batch. Do not add a poll
        -- interval to the continuation delay when the delivery is known now.
        local checked, failure = pcall(Reconcile)
        if not checked then
            lastError = "Cannot check received items: " .. tostring(failure)
            StopOrder(lastError, true)
        end
        if active == submittedBatch then Watch(submittedBatch) end
    end
    RequestRefresh()
end

local function Buy()
    if buying or not AtMerchant() then return end
    if order then
        StopOrder("Order cancelled.", false)
        return
    end
    local ok, err = pcall(function()
        local wasWaiting = active
        Reconcile()
        if wasWaiting then
            if active and CanRecover() then
                local received, quantity = BatchProgress(active)
                Print("Checked bags: received " .. received .. " of " .. quantity ..
                    " items. Click again to buy the remaining order.")
                active = nil
            end
            return
        end
        local data = BuildView(nil, true)
        if data.state ~= "ready" or not data.offer then
            Print(data.reason or "No missing reagents can currently be purchased here.")
            return
        end
        local targets, total = {}, 0
        for id, quantity in pairs(data.targets) do
            targets[id] = quantity
            total = total + quantity
        end
        order = { remaining = targets, total = total, received = 0, display = data }
        lastError, syncNotice = nil, nil
        SendNext(order, data)
    end)
    if not ok then
        lastError = "Purchase stopped: " .. tostring(err)
        if order then StopOrder(lastError, true) else Print(lastError) end
    end
    RequestRefresh()
end

local function Money(copper)
    if type(GetCoinTextureString) == "function" then return GetCoinTextureString(copper) end
    return string.format("%dg %ds %dc", math.floor(copper / 10000),
        math.floor(copper / 100) % 100, copper % 100)
end

local function BatchLines(batch, suffix)
    for i, line in ipairs(batch.lines) do
        if i > 5 then GameTooltip:AddLine("More reagents in this batch..."); break end
        GameTooltip:AddDoubleLine(line.name, LineReceived(line) .. " / " .. line.quantity .. suffix,
            0.8, 0.8, 0.8, 1, 1, 1)
    end
end

local function Tooltip()
    if not view or not button then return end
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("CraftSim Vendor Buy", 1, 0.82, 0)
    if order then
        GameTooltip:AddLine("Buying vendor order — click to cancel", 1, 0.75, 0.2)
        GameTooltip:AddDoubleLine("This order confirmed", order.received .. " / " .. order.total)
        if active then
            local received, quantity = BatchProgress(active)
            GameTooltip:AddDoubleLine("Current batch", received .. " / " .. quantity)
            BatchLines(active, "")
        else
            GameTooltip:AddLine("Preparing the next batch...", 0.8, 0.8, 0.8)
        end
    elseif view.state == "ready" then
        GameTooltip:AddLine("Buy vendor order", 0.3, 1, 0.8)
        GameTooltip:AddDoubleLine("First batch", view.batch .. " items, " .. #view.offers .. " reagents",
            1, 1, 1, 1, 1, 1)
        GameTooltip:AddLine("One click buys all available vendor reagents in confirmed batches of up to "
            .. BatchItems() .. " items. Click again to cancel.", 0.8, 0.8, 0.8, true)
    elseif active then
        local received, quantity = BatchProgress(active)
        GameTooltip:AddLine(view.reason, 1, 0.75, 0.2)
        GameTooltip:AddDoubleLine("Last batch", received .. " / " .. quantity .. " received")
        BatchLines(active, " received")
        if view.state == "recover" then
            GameTooltip:AddLine("Click to check bags and release the wait. This click buys nothing.", 1, 0.85, 0.4, true)
            GameTooltip:AddLine("Retrying a delayed request can buy extra items. Check bags and any purchase errors first.", 0.8, 0.8, 0.8, true)
        end
    else
        GameTooltip:AddLine(view.reason, 0.75, 0.75, 0.75, true)
    end
    if view.total > 0 then
        GameTooltip:AddDoubleLine("Still missing from queue", tostring(view.total))
        for i, item in ipairs(view.needs) do
            if i > 10 then GameTooltip:AddLine("More reagents needed..."); break end
            GameTooltip:AddDoubleLine(item.name, tostring(item.quantity), 0.8, 0.8, 0.8, 1, 1, 1)
        end
        if view.cost > 0 then GameTooltip:AddDoubleLine("Remaining vendor cost", Money(view.cost)) end
    end
    if progress.requested > 0 then
        GameTooltip:AddDoubleLine("Confirmed in bags this session", tostring(progress.received))
    end
    if not order and lastOrder then
        GameTooltip:AddDoubleLine("Last order confirmed", lastOrder.received .. " / " .. lastOrder.total)
    end
    if lastError then GameTooltip:AddLine(lastError, 1, 0.35, 0.25, true) end
    if syncNotice then GameTooltip:AddLine(syncNotice, 1, 0.75, 0.2, true) end
    GameTooltip:Show()
end

local colors = {
    ready = { 0.15, 0.95, 0.75 }, waiting = { 1, 0.65, 0.12 },
    running = { 1, 0.65, 0.12 },
    recover = { 1, 0.65, 0.12 }, complete = { 0.35, 0.75, 0.4 },
    blocked = { 0.45, 0.45, 0.45 },
}

local function RunningView(run)
    -- Progress paints touch only the small vendor order, never CraftSim's full
    -- queue, inventory calculation or a merchant scan.
    local data = { state = "running", needs = {}, offers = {}, total = 0, cost = 0, batch = 0 }
    for _, item in ipairs(run.display.needs) do
        local remaining = run.remaining[item.id] or 0
        if remaining > 0 then
            data.needs[#data.needs + 1] = { name = item.name, quantity = remaining }
            data.total = data.total + remaining
        end
    end
    return data
end

Refresh = function()
    if not MerchantFrame then return end
    if order and not AtMerchant() then StopOrder("Merchant closed or tab changed.", false) end
    if not button then
        button = CreateFrame("Button", "CraftSimVendorBuyButton", MerchantFrame, "UIPanelButtonTemplate")
        button:SetText("")
        button.rim = button:CreateTexture(nil, "ARTWORK")
        button.rim:SetPoint("TOPLEFT", 3, -3)
        button.rim:SetPoint("BOTTOMRIGHT", -3, 3)
        button.icon = button:CreateTexture(nil, "ARTWORK", nil, 1)
        button.icon:SetTexture("Interface\\AddOns\\CraftSimVendorBuy\\Media\\Icon.tga")
        button.icon:SetPoint("TOPLEFT", 4, -4)
        button.icon:SetPoint("BOTTOMRIGHT", -4, 4)
        button.icon:SetTexCoord(0, 1, 0, 1)
        button.mark = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        button.mark:SetPoint("BOTTOMRIGHT", -2, 2)
        button.check = button:CreateTexture(nil, "OVERLAY")
        button.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
        button.check:SetSize(12, 12)
        button.check:SetPoint("BOTTOMRIGHT", -1, 1)
        button:EnableMouse(true)
        button:SetMouseMotionEnabled(true)
        button:RegisterForClicks("LeftButtonUp")
        button:SetScript("OnClick", Buy)
        button:SetScript("OnEnter", function()
            if not order then missingDirty = true; Refresh() end
            Tooltip()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        MerchantFrame:HookScript("OnHide", function()
            StopOrder("Merchant closed.", false)
            button:Hide()
        end)
        if type(MerchantFrame_Update) == "function" then
            hooksecurefunc("MerchantFrame_Update", RequestRefresh)
        end
    end
    local anchor = ProfessionShoppingList_MerchantButton
    if not anchor or not anchor:IsShown() then anchor = MerchantFrameCloseButton end
    if not anchor then
        button:Hide()
        Warn("Merchant close button unavailable; cannot safely position the buy button.")
        return
    end
    button:SetFrameStrata(anchor:GetFrameStrata())
    button:SetFrameLevel(math.max(anchor:GetFrameLevel(), MerchantFrame:GetFrameLevel() + 1) + 1)
    button:SetSize(anchor:GetWidth(), anchor:GetHeight())
    button:ClearAllPoints()
    button:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -2, 0)
    button:SetShown(AtMerchant() and true or false)
    if not AtMerchant() then return end
    local ok, data
    if order then ok, data = pcall(RunningView, order)
    else ok, data = pcall(BuildView) end
    view = ok and data or { state = "blocked", reason = "Cannot refresh: " .. tostring(data),
        needs = {}, offers = {}, total = 0, batch = 0 }
    if order then view.state = "running" end
    local state = view.state
    -- Keep the button enabled for hover tooltips; reject clicks independently.
    button:SetMouseClickEnabled(not buying and (state == "ready" or state == "recover" or state == "running"))
    button.icon:SetDesaturated(state == "blocked" or state == "complete")
    button.icon:SetAlpha(state == "blocked" and 0.5 or state == "complete" and 0.65 or 1)
    local color = colors[state]
    button.rim:SetColorTexture(color[1], color[2], color[3], 0.95)
    button.mark:SetText(state == "running" and "X" or state == "waiting" and "..." or state == "recover" and "!" or "")
    button.mark:SetTextColor(color[1], color[2], color[3])
    button.check:SetShown(state == "complete")
    if GameTooltip:IsOwned(button) then Tooltip() end
end

RequestRefresh = function()
    if not merchantOpen or refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0, function()
        refreshQueued = false
        Refresh()
    end)
end

local function RegisterCraftSimEvents()
    if not hookedQueueUI and CraftSimAPI and type(CraftSimAPI.GetCraftSim) == "function" then
        local ok, craftSim = pcall(CraftSimAPI.GetCraftSim, CraftSimAPI)
        local ui = ok and craftSim and craftSim.CRAFTQ and craftSim.CRAFTQ.UI
        if ui and type(ui.UpdateQueueDisplay) == "function" then
            hooksecurefunc(ui, "UpdateQueueDisplay", function()
                missingDirty = true
                RequestRefresh()
            end)
            hookedQueueUI = ui
        end
    end
    if craftSimEventsRegistered or not CraftSimAPI or type(CraftSimAPI.RegisterEvents) ~= "function" then return end
    local listener = { CRAFTSIM_CRAFTQUEUE_QUEUE_PROCESS_FINISHED = function()
        missingDirty = true
        StopOrder("Craft queue refreshed; click to start its remaining order.", false)
        RequestRefresh()
    end }
    local ok, err = pcall(CraftSimAPI.RegisterEvents, CraftSimAPI, listener,
        { "CRAFTSIM_CRAFTQUEUE_QUEUE_PROCESS_FINISHED" })
    if ok then craftSimEventsRegistered = true else Debug("CraftSim event registration: " .. tostring(err)) end
end

local purchaseErrors = {
    "ERR_INV_FULL", "ERR_ITEM_MAX_COUNT", "ERR_NOT_ENOUGH_MONEY", "ERR_VENDOR_SOLD_OUT",
    "ERR_ITEM_NOT_FOUND", "ERR_CANT_BUY_QUANTITY", "ERR_TOO_MANY_SPECIAL_BAGS",
}

-- Item info arrives constantly (other merchants, AH, tooltips). Only names of
-- reagents we are showing can change the view; quantities never depend on it.
local function NeedsName(id)
    if IsSecret(id) or not missingCache then return false end
    local entry = missingCache[id]
    return entry ~= nil and Name(entry.name, nil) == nil
end

events:SetScript("OnEvent", function(_, event, arg, message)
    if event == "ADDON_LOADED" then
        if arg == addonName and type(CraftSimVendorBuyDB) ~= "table" then CraftSimVendorBuyDB = {} end
        RegisterCraftSimEvents()
    elseif event == "MERCHANT_SHOW" then
        StopOrder("Merchant changed.", false)
        merchantOpen = true
        warnings = {}
        missingDirty = true
        RegisterCraftSimEvents()
    elseif event == "MERCHANT_CLOSED" then
        StopOrder("Merchant closed.", false)
        merchantOpen = false
        if button then button:Hide() end
    elseif event == "UI_ERROR_MESSAGE" and (active or order) and not IsSecret(message) then
        for _, name in ipairs(purchaseErrors) do
            if type(_G[name]) == "string" and message == _G[name] then
                lastError = message
                if order then StopOrder("Purchase interrupted: " .. message, true)
                else Print("Purchase interrupted: " .. message) end
                break
            end
        end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if not NeedsName(arg) then return end
        missingDirty = true
    end
    -- Observe late delivery after stopping too; only a live order can continue.
    if event == "BAG_UPDATE_DELAYED" then
        missingDirty = true
        local ok, err = pcall(Reconcile)
        if not ok then
            lastError = "Cannot check received items: " .. tostring(err)
            StopOrder(lastError, true)
        end
    end
    RequestRefresh()
end)

for _, event in ipairs({ "ADDON_LOADED", "MERCHANT_SHOW", "MERCHANT_CLOSED", "MERCHANT_UPDATE",
    "MERCHANT_FILTER_ITEM_UPDATE", "BAG_UPDATE_DELAYED", "PLAYER_MONEY", "GET_ITEM_INFO_RECEIVED", "UI_ERROR_MESSAGE" }) do
    events:RegisterEvent(event)
end

SLASH_CRAFTSIMVENDORBUY1 = "/csvb"
SlashCmdList.CRAFTSIMVENDORBUY = function(message)
    message = (message or ""):lower():match("^%s*(.-)%s*$")
    CraftSimVendorBuyDB = type(CraftSimVendorBuyDB) == "table" and CraftSimVendorBuyDB or {}
    local db = CraftSimVendorBuyDB
    local batchArg = message:match("^batch%s*(.*)$")
    local roundArg = message:match("^roundup%s*(.*)$")
    if message == "debug" or message == "debug on" or message == "debug off" then
        if message == "debug" then db.debug = not db.debug
        else db.debug = message == "debug on" end
        Print("Debug " .. (db.debug and "on." or "off."))
    elseif batchArg then
        local value = tonumber(batchArg)
        if batchArg == "" then
            Print("Batch size: " .. BatchItems() .. " items (/csvb batch <1-" .. MAX_BATCH_ITEMS .. "> or reset).")
        elseif batchArg == "reset" or batchArg == "default" then
            db.batchItems = nil
            Print("Batch size reset to " .. BatchItems() .. " items.")
        elseif value and value >= 1 and value <= MAX_BATCH_ITEMS and value == math.floor(value) then
            db.batchItems = value
            missingDirty = true
            Print("Batch size set to " .. value .. " items.")
        else
            Print("Batch size must be a whole number from 1 to " .. MAX_BATCH_ITEMS .. ".")
        end
    elseif roundArg then
        if roundArg == "on" or roundArg == "off" then
            db.roundUp = roundArg == "on"
            missingDirty = true
        elseif roundArg ~= "" then
            Print("Use /csvb roundup on or /csvb roundup off.")
        end
        Print("Round up to whole vendor bundles: " .. (RoundUp() and "on." or "off."))
    elseif message == "status" then
        Print("Confirmed in bags this session: " .. progress.received .. " items.")
        Print("Batch size: " .. BatchItems() .. " items; round up bundles: " .. (RoundUp() and "on." or "off."))
        if order then Print("Order running: " .. order.received .. " / " .. order.total .. ". Click the merchant button to cancel.") end
        if active then
            local received, quantity = BatchProgress(active)
            Print("Batch: received " .. received .. " of " .. quantity .. " items in " .. #active.lines .. " reagents" ..
                (order and ". Batches continue automatically; click the merchant button to cancel."
                    or ". Use the merchant button to check and retry after the wait."))
            Print("Batch requests: " .. active.calls .. " (limit " .. BATCH_CALLS .. ").")
        else
            Print(merchantOpen and "Ready to check the CraftSim queue." or "No merchant open.")
        end
        if lastError then Print(lastError) end
        if syncNotice then Print(syncNotice) end
    else
        Print("/csvb status | batch [n|reset] | roundup [on|off] | debug [on|off]")
    end
    RequestRefresh()
end
