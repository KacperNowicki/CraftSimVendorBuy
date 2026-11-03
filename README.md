# CraftSim Vendor Buy

Buy vendor reagents missing from your CraftSim Craft Queue in confirmed batches.

Open a merchant and click the gold shopping bag beside the close button. One click starts the vendor order in batches of up to 10,000 items. A batch can cover several reagents and never sends more than 50 purchase requests, each within the vendor's per-request limit. After each batch arrives, the next starts after a 0.05-second pause. Click again to cancel. Opening a merchant never starts buying.

Items sold in bundles are rounded up to a whole bundle, so the queue can actually be completed (at most one partial bundle extra per reagent). Turn this off with `/csvb roundup off`.

Progress updates reuse the current order instead of recalculating the entire CraftSim queue. Each new batch checks fresh requirements, gold and stock.

The order stops if you close the merchant, switch tabs, refresh the CraftSim queue, encounter a purchase error, or a delivery stalls. It never retries an unconfirmed batch automatically. To recover, check bags and purchase errors, click the amber check action, then click again to start the remaining order.

The tooltip shows quantities, cost, confirmed purchases and purchase errors. Auctionator's matching CraftSim shopping entries decrease only as items arrive; custom searches and filters are preserved. A green check means the queue's reagents are acquired.

## Commands

- `/csvb status` – purchase progress and current settings
- `/csvb batch <n>` – items per batch (1–50,000, default 10,000); `/csvb batch reset` restores the default
- `/csvb roundup on|off` – round partial vendor bundles up (default on)
- `/csvb debug on|off` – diagnostic output

Requires WoW Retail and CraftSim. Licensed under the [MIT License](LICENSE).
