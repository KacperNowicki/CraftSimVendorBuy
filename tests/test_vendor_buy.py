"""Execute the actual addon in Lua 5.1 with controllable WoW events and receipts."""
from pathlib import Path
import sys
import unittest

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent
sys.path.insert(0, str(TESTS / ".deps"))
try:
    from lupa.lua51 import LuaRuntime
except ImportError as error:
    raise SystemExit(
        "Install the isolated test runtime first: "
        "python -m pip install --target tests/.deps -r tests/requirements.txt"
    ) from error


class VendorBuyTests(unittest.TestCase):
    BATCH_ITEMS = 5000

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute((TESTS / "wow_mock.lua").read_text(encoding="utf-8"))
        self.lua.globals().addon_source = (
            ROOT / "CraftSimVendorBuy" / "CraftSimVendorBuy.lua"
        ).read_text(encoding="utf-8-sig")
        self.lua.execute("assert(loadstring(addon_source))('CraftSimVendorBuy')")
        self.lua.execute("S.event('ADDON_LOADED', 'CraftSimVendorBuy')")
        if self.BATCH_ITEMS:
            # Flow tests use a smaller batch so multi-batch paths stay exercised.
            self.lua.execute(f"CraftSimVendorBuyDB.batchItems = {self.BATCH_ITEMS}")
        self.lua.execute("S.open()")

    def check(self, scenario):
        self.lua.execute(scenario)

    def load_sync(self):
        self.lua.globals().sync_source = (
            ROOT / "CraftSimVendorBuy" / "AuctionatorSync.lua"
        ).read_text(encoding="utf-8-sig")
        self.check("assert(loadstring(sync_source))('CraftSimVendorBuy')")

    def test_first_click_starts_one_bounded_request_group(self):
        self.check("""
            S.click()
            assert(#S.groups == 1 and S.groups[1].quantity == 5000)
            assert(S.groups[1].fromClick, 'first batch must run from the start click')
            S.advance(0.5)
            assert(#S.groups == 1, 'next batch overlapped an unconfirmed request')
        """)

    def test_idle_event_burst_reuses_canonical_missing_query(self):
        self.check("""
            S.resetCounters()
            for index = 1, 20 do
                S.event('MERCHANT_UPDATE')
                S.event('PLAYER_MONEY')
            end
            assert(S.counters.missingQueries <= 1,
                'unchanged merchant/money events repeatedly rebuilt the CraftSim queue')
            assert(S.counters.crafterReads <= 1,
                'unchanged events repeatedly traversed queue crafter identities')
            assert(#S.groups == 0)
        """)

    def test_running_watchdog_and_event_burst_do_not_rebuild_queue_or_scan_merchant(self):
        self.check("""
            S.click()
            S.resetCounters()
            for index = 1, 8 do
                S.event('MERCHANT_UPDATE')
                S.event('PLAYER_MONEY')
                S.advance(0.05)
            end
            assert(S.counters.missingQueries == 0,
                'receipt watchdog/event refresh rebuilt canonical missing quantities')
            assert(S.counters.crafterReads == 0,
                'receipt watchdog/event refresh traversed the craft queue')
            assert(S.counters.merchantScans == 0,
                'receipt watchdog/event refresh scanned merchant offers')
            assert(#S.groups == 1, 'event burst overlapped the pending request')
        """)

    def test_bag_change_invalidates_cached_idle_need(self):
        self.check("""
            S.resetCounters()
            S.bags[1001] = 12400
            S.event('BAG_UPDATE_DELAYED')
            assert(S.counters.missingQueries >= 1, 'bag update did not invalidate idle need')
            S.click()
            assert(#S.groups == 1 and S.groups[1].quantity == 100,
                'cached quantities ignored newly available inventory')
        """)

    def test_queue_process_invalidates_cached_idle_need(self):
        self.check("""
            S.need[1001] = 75
            S.resetCounters()
            S.craftSimListener.CRAFTSIM_CRAFTQUEUE_QUEUE_PROCESS_FINISHED()
            S.advance(0)
            assert(S.counters.missingQueries >= 1, 'queue update did not invalidate idle need')
            S.click()
            assert(#S.groups == 1 and S.groups[1].quantity == 75)
        """)

    def test_start_click_rechecks_manual_queue_edit_without_inventory_event(self):
        self.check("""
            S.need[1001] = 75
            -- The visible cached plan still represents 12500; click must be fresh.
            S.click()
            assert(#S.groups == 1 and S.groups[1].quantity == 75,
                'start click used cached need after a manual queue edit')
        """)

    def test_pending_bag_burst_defers_full_query_until_next_batch(self):
        self.check("""
            S.click()
            S.resetCounters()
            for index = 1, 10 do S.event('BAG_UPDATE_DELAYED') end
            S.receive(1001, 2000)
            S.advance(1)
            assert(S.counters.missingQueries == 0 and S.counters.merchantScans == 0,
                'pending bag events repeatedly recalculated the purchase plan')
            S.receive(1001, 3000)
            S.advance(0.05)
            assert(#S.groups == 2)
            assert(S.counters.missingQueries <= 1,
                'confirmed next batch performed redundant canonical queries')
        """)

    def test_passive_events_timers_and_slash_never_start_an_order(self):
        self.check("""
            S.advance(30)
            S.event('PLAYER_MONEY')
            S.event('MERCHANT_UPDATE')
            S.event('BAG_UPDATE_DELAYED')
            SlashCmdList.CRAFTSIMVENDORBUY('status')
            SlashCmdList.CRAFTSIMVENDORBUY('sync')
            S.close()
            S.open()
            S.advance(30)
            assert(#S.groups == 0, 'passive activity started buying')
        """)

    def test_large_order_uses_5000_item_groups_and_respects_each_call_limit(self):
        self.check("""
            S.need[1001] = 12000
            S.event('MERCHANT_UPDATE')
            S.click()
            assert(#S.groups == 1 and S.groups[1].quantity == 5000)
            assert(#S.purchases == 5, 'batch exceeded five calls or failed to fill five stacks')
            for _, request in ipairs(S.purchases) do
                assert(request.quantity <= 1000, 'call exceeded merchant max stack')
            end
            S.receive(1001, 5000)
            S.advance(0.05)
            assert(#S.groups == 2 and S.groups[2].quantity == 5000)
            S.receive(1001, 5000)
            S.advance(0.05)
            assert(#S.groups == 3 and S.groups[3].quantity == 2000)
            S.receive(1001, 2000)
            S.advance(1)
            assert(#S.groups == 3 and #S.purchases == 12 and S.clickCount == 1)
        """)

    def test_small_vendor_stack_limits_batch_to_fifty_calls(self):
        self.check("""
            S.offers[1].maximum = 20
            S.need[1001] = 2000
            S.event('MERCHANT_UPDATE')
            S.click()
            assert(#S.purchases == 50 and S.groups[1].quantity == 1000,
                'small vendor stacks bypassed the fifty-call batch limit')
            S.advance(0.2)
            assert(#S.purchases == 50, 'unconfirmed batch allowed more calls')
            S.receive(1001, 1000)
            S.advance(0.05)
            assert(#S.purchases == 100 and S.groups[2].quantity == 1000)
        """)

    def test_large_merchant_stack_is_still_capped_at_5000_items(self):
        self.check("""
            S.offers[1].maximum = 20000
            S.click()
            assert(#S.purchases == 1 and S.purchases[1].quantity == 5000,
                'large merchant limit bypassed per-batch item cap')
        """)

    def test_synchronous_error_stops_remaining_calls_in_current_group(self):
        self.check("""
            S.purchaseHook = function(_, count)
                if count == 2 then
                    S.event('UI_ERROR_MESSAGE', Enum.GameError.InventoryFull, ERR_INV_FULL)
                end
            end
            S.click()
            assert(#S.purchases == 2, 'synchronous purchase error did not stop current batch')
            S.receive(1001, 2000)
            S.advance(30)
            assert(#S.purchases == 2, 'failed batch resumed automatically')
        """)

    def test_synchronous_receipts_do_not_complete_a_group_mid_submission(self):
        self.check("""
            S.purchaseHook = function(request)
                S.receive(request.id, request.quantity)
            end
            S.click()
            assert(#S.groups == 1 and #S.purchases == 5 and S.groups[1].quantity == 5000,
                'synchronous receipt broke the current group or started another one')
            S.advance(0.05)
            assert(#S.groups == 2 and #S.purchases == 10 and S.groups[2].quantity == 5000)
            S.advance(0.05)
            assert(#S.groups == 3 and S.groups[3].quantity == 2500)
            S.advance(1)
            assert(#S.purchases == 13 and S.clickCount == 1)
        """)

    def test_group_reserves_local_gold_and_stock_while_server_values_lag(self):
        self.check("""
            S.money = 15000
            S.offers[1].price = 10
            S.click()
            assert(#S.purchases == 2 and S.groups[1].quantity == 1500,
                'batch ignored local gold reservation between calls')
            assert(S.purchases[1].quantity == 1000 and S.purchases[2].quantity == 500)
        """)

    def test_group_reserves_local_limited_stock_between_calls(self):
        self.check("""
            S.offers[1].numAvailable = 1500
            S.click()
            assert(#S.purchases == 2 and S.groups[1].quantity == 1500,
                'batch ignored local merchant stock reservation')
            assert(S.purchases[1].quantity == 1000 and S.purchases[2].quantity == 500)
        """)

    def test_group_rounds_each_call_to_bundle_and_limited_stock(self):
        self.check("""
            S.need[1001] = 27
            S.offers[1].stackCount = 5
            S.offers[1].maximum = 12
            S.offers[1].numAvailable = 17
            S.event('MERCHANT_UPDATE')
            S.click()
            assert(#S.purchases == 2 and S.groups[1].quantity == 15)
            assert(S.purchases[1].quantity == 10 and S.purchases[2].quantity == 5,
                'batch calls ignored bundle increments or locally reserved stock')
        """)

    def test_one_click_buys_whole_order_with_confirmed_spaced_batches(self):
        self.check("""
            S.click()
            S.receive(1001, 5000)
            assert(#S.groups == 1, 'receipt synchronously issued the next purchase')
            S.advance(0.049)
            assert(#S.groups == 1, 'batch did not wait for pacing interval')
            S.advance(0.001)
            assert(#S.groups == 2 and S.groups[2].quantity == 5000)
            assert(not S.groups[2].fromClick, 'second batch needed another click')
            S.receive(1001, 5000)
            S.advance(0.05)
            assert(#S.groups == 3 and S.groups[3].quantity == 2500)
            S.receive(1001, 2500)
            S.advance(30)
            assert(#S.groups == 3 and S.clickCount == 1)
            assert(not S.clickable(), 'completed order should not offer another purchase')
        """)

    def test_one_click_completes_multiple_item_types_without_overlap(self):
        self.check("""
            S.need = {[1001] = 7500, [1002] = 6000}
            S.offers[2] = { id = 1002, name = 'Second Reagent', price = 10,
                stackCount = 1, numAvailable = -1, maximum = 2500,
                isPurchasable = true, hasExtendedCost = false }
            S.event('MERCHANT_UPDATE')
            S.click()
            local totals = {}
            for index = 1, 3 do
                assert(#S.batches == index, 'more than one batch is in flight')
                local batch = S.batches[index]
                assert(batch.quantity <= 5000, 'batch exceeded configured item cap')
                for id, quantity in pairs(batch.items) do
                    totals[id] = (totals[id] or 0) + quantity
                    S.bags[id] = (S.bags[id] or 0) + quantity
                end
                S.event('BAG_UPDATE_DELAYED')
                S.advance(0.05)
            end
            S.advance(30)
            assert(totals[1001] == 7500 and totals[1002] == 6000)
            assert(#S.batches == 3 and S.clickCount == 1)
            assert(S.batches[2].items[1001] == 2500 and S.batches[2].items[1002] == 2500,
                'batch did not fill its remaining room with the next reagent')
        """)

    def test_partial_delivery_waits_for_full_receipt_before_continuing(self):
        self.check("""
            S.click()
            S.receive(1001, 2000)
            S.advance(0.5)
            assert(#S.groups == 1, 'partial delivery triggered an overlapping batch')
            S.receive(1001, 3000)
            S.advance(0.05)
            assert(#S.groups == 2 and S.groups[2].quantity == 5000)
        """)

    def test_stalled_partial_order_stops_and_late_receipt_cannot_resume(self):
        self.check("""
            S.click()
            S.receive(1001, 2000)
            S.advance(30)
            assert(#S.groups == 1, 'stalled partial purchase was automatically retried')
            S.receive(1001, 3000)
            S.advance(30)
            assert(#S.groups == 1, 'late receipt resumed an order that had stopped')
            S.click()
            assert(#S.groups == 2, 'new explicit click could not start remaining order')
        """)

    def test_stall_recovery_click_buys_nothing_then_next_click_starts(self):
        self.check("""
            S.click()
            S.advance(30)
            assert(#S.groups == 1 and S.clickable())
            S.click()
            S.advance(1)
            assert(#S.groups == 1, 'recovery action started a new purchase')
            S.click()
            assert(#S.groups == 2, 'recovered order stayed permanently locked')
        """)

    def test_cancel_during_inflight_request_prevents_all_continuation(self):
        self.check("""
            S.click()
            assert(S.clickable(), 'running button must offer cancel')
            S.click()
            S.receive(1001, 5000)
            S.advance(30)
            assert(#S.groups == 1, 'cancelled order continued after its receipt')
        """)

    def test_cancel_before_scheduled_next_batch_invalidates_timer(self):
        self.check("""
            S.click()
            S.receive(1001, 5000)
            S.advance(0.01)
            S.click()
            S.advance(30)
            assert(#S.groups == 1, 'cancelled next-batch timer still purchased')
        """)

    def test_merchant_close_and_reopen_do_not_resume(self):
        self.check("""
            S.click()
            S.close()
            S.receive(1001, 5000)
            S.open()
            S.advance(30)
            assert(#S.groups == 1, 'merchant reopen resumed prior order')
            S.click()
            assert(#S.groups == 2, 'new start click did not use confirmed remaining need')
        """)

    def test_buyback_tab_change_stops_session_permanently(self):
        self.check("""
            S.click()
            S.receive(1001, 5000)
            MerchantFrame.selectedTab = 2
            S.event('MERCHANT_UPDATE')
            S.advance(1)
            MerchantFrame.selectedTab = 1
            S.event('MERCHANT_UPDATE')
            S.advance(30)
            assert(#S.groups == 1, 'returning to merchant tab resumed prior order')
        """)

    def test_blizzard_purchase_error_stops_even_if_full_receipt_arrives(self):
        self.check("""
            S.click()
            S.event('UI_ERROR_MESSAGE', Enum.GameError.InventoryFull, ERR_INV_FULL)
            assert(S.tooltip():lower():find('inventory is full', 1, true))
            S.receive(1001, 5000)
            S.advance(30)
            assert(#S.groups == 1, 'error-stopped order resumed after delivery')
        """)

    def test_api_exception_retains_explicit_recovery(self):
        self.check("""
            S.purchaseError = 'simulated API failure'
            S.click()
            S.purchaseError = nil
            S.advance(30)
            assert(#S.groups == 1 and S.clickable())
            S.click()
            assert(#S.groups == 1, 'API exception recovery bought again')
            S.click()
            assert(#S.groups == 2)
        """)

    def test_late_full_bags_on_recovery_click_never_fall_through_to_buy(self):
        self.check("""
            S.click()
            S.advance(30)
            S.bags[1001] = 5000
            S.click()
            S.advance(1)
            assert(#S.groups == 1, 'recovery click fell through after a late full receipt')
            S.click()
            assert(#S.groups == 2 and S.groups[2].quantity == 5000)
        """)

    def test_late_partial_delivery_is_rechecked_before_new_start(self):
        self.check("""
            S.need[1001] = 5000
            S.event('MERCHANT_UPDATE')
            S.click()
            S.receive(1001, 2000)
            S.advance(30)
            S.click()
            S.bags[1001] = 3500
            S.click()
            assert(#S.groups == 2 and S.groups[2].quantity == 1500,
                'new start ignored late inventory update')
        """)

    def test_next_batch_rechecks_current_gold_and_does_not_auto_resume(self):
        self.check("""
            S.click()
            S.receive(1001, 5000)
            S.money = 0
            S.advance(1)
            assert(#S.groups == 1, 'next batch ignored current gold')
            S.money = 10000000
            S.event('PLAYER_MONEY')
            S.advance(30)
            assert(#S.groups == 1, 'money update restarted stopped order')
        """)

    def test_next_batch_rechecks_stock_and_does_not_auto_resume(self):
        self.check("""
            S.click()
            S.receive(1001, 5000)
            S.offers[1].numAvailable = 0
            S.advance(1)
            assert(#S.groups == 1, 'next batch ignored changed stock')
            S.offers[1].numAvailable = -1
            S.event('MERCHANT_UPDATE')
            S.advance(30)
            assert(#S.groups == 1, 'restocked merchant restarted stopped order')
        """)

    def test_next_batch_rechecks_item_identity(self):
        self.check("""
            S.click()
            S.receive(1001, 5000)
            S.offers[1].id = 9999
            S.advance(30)
            assert(#S.groups == 1, 'changed merchant slot bought the wrong item')
        """)

    def test_queue_increase_during_order_cannot_expand_initial_target(self):
        self.check("""
            S.need[1001] = 7500
            S.event('MERCHANT_UPDATE')
            S.click()
            S.receive(1001, 5000)
            S.need[1001] = 12500
            S.advance(0.05)
            assert(#S.groups == 2 and S.groups[2].quantity == 2500,
                'queue edit expanded authorized target')
            S.receive(1001, 2500)
            S.advance(30)
            assert(#S.groups == 2)
            S.click()
            assert(#S.groups == 3 and S.groups[3].quantity == 5000,
                'new click could not authorize newly added queue need')
        """)

    def test_queue_shrink_during_order_reduces_next_batch(self):
        self.check("""
            S.click()
            S.receive(1001, 5000)
            S.need[1001] = 6000
            S.advance(0.05)
            assert(#S.groups == 2 and S.groups[2].quantity == 1000)
            S.receive(1001, 1000)
            S.advance(30)
            assert(#S.groups == 2, 'run ignored reduced current need')
        """)

    def test_fixed_target_prevents_overbuy_when_canonical_missing_is_stale(self):
        self.check("""
            function S.craftSim.SHOPPING:GetMissingReagentsFromCraftQueue()
                return {{itemID=1001, quantity=12500, itemName='Reagent 1001'}}
            end
            S.event('MERCHANT_UPDATE')
            S.click()
            S.receive(1001, 5000)
            S.advance(0.05)
            S.receive(1001, 5000)
            S.advance(0.05)
            assert(S.groups[3].quantity == 2500)
            S.receive(1001, 2500)
            S.advance(30)
            assert(#S.groups == 3, 'stale raw missing caused an unbounded purchase run')
        """)

    def test_new_item_added_to_queue_is_not_automatically_authorized(self):
        self.check("""
            S.need[1001] = 5000
            S.offers[2] = {id=1002, name='Second Reagent', price=10,
                stackCount=1, numAvailable=-1, maximum=5000,
                isPurchasable=true, hasExtendedCost=false}
            S.event('MERCHANT_UPDATE')
            S.click()
            S.need[1002] = 2500
            S.receive(1001, 5000)
            S.advance(30)
            assert(#S.groups == 1, 'run bought item added after initial authorization')
        """)

    def test_transient_craftsim_cache_can_retry_without_overlapping_batch(self):
        self.check("""
            S.click()
            S.receive(1001, 5000)
            S.craftSim.CRAFTQ.itemCountCache = {}
            S.advance(0.5)
            assert(#S.groups == 1)
            S.craftSim.CRAFTQ.itemCountCache = nil
            S.advance(0.5)
            assert(#S.groups == 2, 'temporary CraftSim cache stopped recoverable run')
        """)

    def test_persistent_missing_data_stops_after_bounded_retry(self):
        self.check("""
            S.click()
            S.receive(1001, 5000)
            S.craftSim.CRAFTQ.itemCountCache = {}
            S.advance(30)
            assert(#S.groups == 1)
            S.craftSim.CRAFTQ.itemCountCache = nil
            S.event('BAG_UPDATE_DELAYED')
            S.advance(30)
            assert(#S.groups == 1, 'data becoming available restarted expired run')
        """)

    def test_ready_and_running_tooltips_refresh_while_hovered(self):
        self.check("""
            local before = S.tooltip()
            assert(S.button().icon.desaturated ~= true)
            S.click()
            local running = table.concat(GameTooltip.lines, '\\n')
            assert(running ~= before, 'tooltip did not reflect running state')
            assert(S.clickable(), 'running button must remain usable for cancel')
            S.receive(1001, 5000)
            local received = table.concat(GameTooltip.lines, '\\n')
            assert(received ~= running, 'tooltip did not reflect confirmed progress')
        """)

    def test_no_need_or_no_gold_prevents_start(self):
        self.check("""
            S.need = {}
            S.craftSim.CRAFTQ.UI:UpdateQueueDisplay()
            S.event('MERCHANT_UPDATE')
            assert(not S.clickable())
            S.need = {[1001] = 12500}
            S.money = 0
            S.craftSim.CRAFTQ.UI:UpdateQueueDisplay()
            S.event('PLAYER_MONEY')
            assert(not S.clickable() and #S.groups == 0)
        """)

    def test_out_of_stock_and_extended_cost_are_skipped(self):
        self.check("""
            S.offers[1].numAvailable = 0
            S.event('MERCHANT_UPDATE')
            assert(not S.clickable())
            S.offers[1].numAvailable = -1
            S.offers[1].hasExtendedCost = true
            S.event('MERCHANT_UPDATE')
            assert(not S.clickable() and #S.groups == 0)
        """)

    def test_duplicate_item_slot_can_use_later_valid_gold_offer(self):
        self.check("""
            S.offers[1].hasExtendedCost = true
            S.offers[2] = {id=1001, name='Test Reagent', price=10,
                stackCount=1, numAvailable=-1, maximum=5000,
                isPurchasable=true, hasExtendedCost=false}
            S.event('MERCHANT_UPDATE')
            S.click()
            assert(#S.groups == 1 and S.groups[1].slot == 2)
            S.receive(1001, 5000)
            S.offers[1].hasExtendedCost = false
            S.offers[1].numAvailable = 0
            S.advance(0.05)
            assert(#S.groups == 2 and S.groups[2].slot == 2)
        """)

    def test_fresh_need_stock_and_gold_bound_first_batch(self):
        self.check("""
            S.need[1001] = 75
            S.money = 300
            S.offers[1].numAvailable = 50
            S.click()
            assert(#S.groups == 1 and S.groups[1].quantity == 30)
        """)

    def test_bundle_rounding_off_never_overbuys(self):
        self.check("""
            SlashCmdList.CRAFTSIMVENDORBUY('roundup off')
            S.offers[1].stackCount = 5
            S.need[1001] = 17
            S.event('MERCHANT_UPDATE')
            S.click()
            assert(#S.groups == 1 and S.groups[1].quantity == 15)
            S.receive(1001, 15)
            S.advance(30)
            assert(#S.groups == 1 and not S.clickable())
        """)

    def test_shopping_alt_bags_and_queue_refresh_prevent_rebuy(self):
        self.check("""
            S.rawMissing = true
            S.click()
            S.receive(1001, 5000)
            S.craftSimListener.CRAFTSIM_CRAFTQUEUE_QUEUE_PROCESS_FINISHED()
            S.advance(1)
            assert(#S.groups == 1, 'queue rebuild failed to stop the prior order')
            S.click()
            assert(S.groups[2].quantity == 5000, 'shopping-alt bags were ignored on new start')
            S.receive(1001, 5000)
            S.advance(0.05)
            assert(S.groups[3].quantity == 2500)
            S.receive(1001, 2500)
            S.advance(30)
            assert(#S.groups == 3 and not S.clickable())
        """)

    def test_manual_queue_need_increase_after_completion_needs_no_process_event(self):
        self.check("""
            S.need[1001] = 100
            S.event('MERCHANT_UPDATE')
            S.click()
            S.receive(1001, 100)
            S.advance(0.05)
            S.need[1001] = 200
            S.craftSim.CRAFTQ.UI:UpdateQueueDisplay()
            S.event('MERCHANT_UPDATE')
            S.click()
            assert(#S.groups == 2 and S.groups[2].quantity == 100)
        """)

    def test_real_sync_uses_actual_receipts_across_partial_recovery_and_auto_batches(self):
        self.load_sync()
        self.check("""
            S.setupShopping(250)
            S.need[1001] = 250
            S.offers[1].maximum = 2
            S.event('MERCHANT_UPDATE')
            S.click()
            assert(S.shopping.quantity() == 250)
            S.receive(1001, 40)
            S.event('BAG_UPDATE_DELAYED')
            assert(S.shopping.quantity() == 210 and S.shopping.changes == 1)
            S.advance(30)
            assert(#S.groups == 1)
            S.click()
            assert(#S.groups == 1)
            S.click()
            S.receive(1001, 100)
            assert(S.shopping.quantity() == 110 and S.shopping.changes == 2)
            S.advance(0.05)
            assert(#S.groups == 3 and S.groups[3].quantity == 100)
            S.receive(1001, 100)
            assert(S.shopping.quantity() == 10)
            S.advance(0.05)
            assert(S.groups[4].quantity == 10)
            S.receive(1001, 10)
            S.advance(1)
            assert(S.shopping.quantity() == 0 and #S.groups == 4)
        """)

    def test_consumption_starts_fresh_receipt_and_shopping_snapshot(self):
        self.load_sync()
        self.check("""
            S.setupShopping(5000)
            S.need[1001] = 5000
            S.event('MERCHANT_UPDATE')
            S.click()
            S.receive(1001, 2000)
            S.advance(30)
            S.click()
            S.click()
            assert(S.groups[2].quantity == 3000)
            S.receive(1001, 3000)
            S.advance(0.05)
            assert(S.shopping.quantity() == 0)
            S.bags[1001] = 0
            S.setupShopping(5000)
            S.craftSimListener.CRAFTSIM_CRAFTQUEUE_QUEUE_PROCESS_FINISHED()
            S.advance(0)
            S.click()
            assert(#S.groups == 3 and S.groups[3].quantity == 5000)
            S.receive(1001, 5000)
            S.advance(0.05)
            assert(S.shopping.quantity() == 0 and not S.clickable())
        """)


class DefaultBatchTests(unittest.TestCase):
    """Shipped defaults: 10,000-item batches across reagents, bundles rounded up."""
    BATCH_ITEMS = None
    setUp = VendorBuyTests.setUp
    check = VendorBuyTests.check
    load_sync = VendorBuyTests.load_sync

    def test_default_batch_buys_10000_items(self):
        self.check("""
            S.click()
            assert(#S.batches == 1 and S.batches[1].quantity == 10000 and S.batches[1].calls == 10)
            for _, request in ipairs(S.purchases) do assert(request.quantity <= 1000) end
            S.receive(1001, 10000)
            S.advance(0.05)
            assert(#S.batches == 2 and S.batches[2].quantity == 2500 and not S.batches[2].fromClick)
            S.receive(1001, 2500)
            S.advance(30)
            assert(#S.batches == 2 and S.clickCount == 1 and not S.clickable())
        """)

    def test_cooking_sized_stacks_fill_10000_in_one_batch(self):
        self.check("""
            S.offers[1].maximum = 200
            S.need[1001] = 10000
            S.event('MERCHANT_UPDATE')
            S.click()
            assert(#S.batches == 1 and S.batches[1].quantity == 10000 and S.batches[1].calls == 50)
            S.receive(1001, 10000)
            S.advance(30)
            assert(#S.batches == 1 and not S.clickable())
        """)

    def test_small_reagents_share_one_batch(self):
        self.check("""
            S.need = {[1001] = 300, [1002] = 40, [1003] = 7}
            S.offers[2] = { id = 1002, name = 'B', price = 10, stackCount = 1, numAvailable = -1,
                maximum = 1000, isPurchasable = true, hasExtendedCost = false }
            S.offers[3] = { id = 1003, name = 'C', price = 10, stackCount = 1, numAvailable = -1,
                maximum = 1000, isPurchasable = true, hasExtendedCost = false }
            S.event('MERCHANT_UPDATE')
            S.click()
            local batch = S.batches[1]
            assert(#S.batches == 1 and batch.calls == 3 and batch.quantity == 347)
            assert(batch.items[1001] == 300 and batch.items[1002] == 40 and batch.items[1003] == 7)
            S.receive(1001, 300)
            S.advance(1)
            assert(#S.batches == 1, 'batch continued before every reagent arrived')
            S.bags[1002], S.bags[1003] = 40, 7
            S.event('BAG_UPDATE_DELAYED')
            S.advance(30)
            assert(#S.batches == 1 and not S.clickable() and S.button().check.shown)
        """)

    def test_bundle_round_up_completes_queue_and_prices_whole_bundles(self):
        self.check("""
            S.offers[1].stackCount = 5
            S.offers[1].price = 10
            S.need[1001] = 7
            S.event('MERCHANT_UPDATE')
            assert(S.tooltip():find('Remaining vendor cost | 20 copper', 1, true),
                'cost estimate ignored the partial bundle')
            S.click()
            assert(#S.purchases == 1 and S.purchases[1].quantity == 10)
            assert(S.tooltip():find('This order confirmed | 0 / 7', 1, true))
            S.receive(1001, 10)
            assert(S.tooltip():find('This order confirmed | 7 / 7', 1, true),
                'rounded-up extras overstated order progress')
            S.advance(30)
            assert(S.tooltip():find('Last order confirmed | 7 / 7', 1, true))
            assert(#S.purchases == 1 and not S.clickable() and S.button().check.shown)
        """)

    def test_bundle_round_up_splits_across_calls_without_extra_bundle(self):
        self.check("""
            S.offers[1].stackCount = 5
            S.offers[1].maximum = 10
            S.need[1001] = 12
            S.event('MERCHANT_UPDATE')
            S.click()
            assert(#S.purchases == 2 and S.purchases[1].quantity == 10 and S.purchases[2].quantity == 5)
        """)

    def test_batch_size_setting_is_respected(self):
        self.check("""
            SlashCmdList.CRAFTSIMVENDORBUY('batch 2500')
            assert(CraftSimVendorBuyDB.batchItems == 2500)
            S.click()
            assert(S.batches[1].quantity == 2500)
            SlashCmdList.CRAFTSIMVENDORBUY('batch 0')
            assert(CraftSimVendorBuyDB.batchItems == 2500, 'invalid batch size was accepted')
            SlashCmdList.CRAFTSIMVENDORBUY('batch reset')
            assert(CraftSimVendorBuyDB.batchItems == nil)
        """)

    def test_sync_notice_clears_when_a_new_order_starts(self):
        self.load_sync()
        self.check("""
            S.setupShopping(5000)
            S.need[1001] = 5000
            S.event('MERCHANT_UPDATE')
            S.click()
            -- The user removes the entry: the sync must stop and say so.
            Auctionator.API.v1.GetShoppingListItems = function() return {} end
            S.receive(1001, 2000)
            assert(S.tooltip():find('Auctionator entry changed', 1, true))
            S.advance(30)
            S.setupShopping(3000)
            S.click()
            S.click()
            assert(not S.tooltip():find('Auctionator entry changed', 1, true),
                'stale Auctionator notice survived a new order')
            S.receive(1001, 1000)
            assert(S.shopping.quantity() == 2000, 'fresh order did not sync its receipts')
            assert(not S.tooltip():find('Auctionator entry changed', 1, true))
        """)

    def test_unrelated_item_info_does_not_rerun_craftsim_query(self):
        self.check("""
            S.tooltip()
            S.resetCounters()
            for id = 5000, 5040 do S.event('GET_ITEM_INFO_RECEIVED', id, true) end
            assert(S.counters.missingQueries == 0 and S.counters.merchantScans == 0,
                'unrelated item info rebuilt the CraftSim query')
        """)

    def test_nameless_reagent_info_refreshes_name(self):
        self.check("""
            local named = false
            function S.craftSim.SHOPPING:GetMissingReagentsFromCraftQueue()
                S.counters.missingQueries = S.counters.missingQueries + 1
                return {{itemID = 1001, quantity = 50, itemName = named and 'Loaded Name' or nil}}
            end
            S.craftSim.CRAFTQ.UI:UpdateQueueDisplay()
            S.advance(0)
            S.resetCounters()
            named = true
            S.event('GET_ITEM_INFO_RECEIVED', 1001, true)
            assert(S.counters.missingQueries == 1)
            assert(S.tooltip():find('Loaded Name', 1, true))
        """)

    def test_completed_receipts_are_not_reread_on_later_bag_events(self):
        self.check("""
            S.need[1001] = 500
            S.event('MERCHANT_UPDATE')
            S.click()
            S.receive(1001, 500)
            S.advance(30)
            S.resetCounters()
            for index = 1, 5 do S.event('BAG_UPDATE_DELAYED') end
            assert(S.counters.bagReads == 0, 'finished receipts were re-read on every bag event')
        """)

    def test_duplicate_craftsim_entries_merge_without_overbuying(self):
        self.check("""
            function S.craftSim.SHOPPING:GetMissingReagentsFromCraftQueue()
                return {{itemID = 1001, quantity = 300, itemName = 'Reagent 1001'},
                    {itemID = 1001, quantity = 500, itemName = 'Reagent 1001'}}
            end
            S.craftSim.CRAFTQ.UI:UpdateQueueDisplay()
            S.event('MERCHANT_UPDATE')
            S.click()
            assert(#S.purchases == 1 and S.purchases[1].quantity == 500)
        """)

    def test_toc_supports_current_retail_client(self):
        toc = (ROOT / "CraftSimVendorBuy" / "CraftSimVendorBuy.toc").read_text(encoding="utf-8")
        self.assertIn("120105", toc.splitlines()[0])


class AuctionatorSyncTests(unittest.TestCase):
    def test_public_api_sync_regressions(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().auctionator_sync_source = (
            ROOT / "CraftSimVendorBuy" / "AuctionatorSync.lua"
        ).read_text(encoding="utf-8-sig")
        passed = lua.execute(
            (TESTS / "test_auctionator_sync.lua").read_text(encoding="utf-8")
        )
        self.assertGreaterEqual(passed, 36, "Auctionator sync scenarios did not all execute")


if __name__ == "__main__":
    unittest.main(verbosity=2)
