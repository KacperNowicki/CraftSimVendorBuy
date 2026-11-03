# Changelog

## 1.4.0 - 2026-11-03

- Batches return to 10,000 items by default (1.3.0 capped them at 5,000 items / 5 requests). Configure with `/csvb batch <n>`.
- One batch now spans several reagents, so small mixed orders finish in one round trip. A hard cap of 50 requests per batch remains.
- Items sold in bundles round up to a whole bundle so the queue can complete; `/csvb roundup off` restores the old round-down behaviour. The cost estimate counts whole bundles.
- Duplicate CraftSim entries for one purchasable item (CraftSim's soulbound-alternative mapping) are merged conservatively instead of skipped.
- The Auctionator warning clears when a new order starts.
- Item-info events only trigger a CraftSim recalculation when they name a reagent being shown, avoiding repeated queue scans while a merchant's items load.
- Completed purchase receipts are dropped instead of re-read on every bag update.
- Supports WoW 12.1.5 (interface 120105).

## 1.3.0 - 2026-10-28

- Request groups of up to five calls / 5,000 items per batch with a 0.05-second pause.
- Progress refreshes reuse the running order instead of recalculating the CraftSim queue.

## 1.2.0 - 2026-10-20

- One click buys the whole order in confirmed, spaced batches; click again to cancel.
- Orders stop on merchant close, tab change, queue refresh, purchase errors or stalled delivery.

## 1.1.0 - 2026-10-20

- Optional Auctionator sync: CraftSim's shopping-list entries decrease as vendor items arrive.
- Receipt tracking from bag counts, shopping-character support and a refreshed icon.

## 1.0.0 - 2026-09-11

First public release.

- Buy missing CraftSim Craft Queue vendor reagents with a real button click.
- Compact merchant title-bar button with an original shopping-bag icon.
- Exact itemID matching, fresh CraftSim queries and gold-only purchases.
- Respect vendor stock, bundles, maximum purchase sizes and available gold.
- Optional debug output through `/csvb debug on` and `/csvb status`.
