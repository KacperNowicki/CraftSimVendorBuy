# Purchase regression checks

Run from the repository root:

```powershell
python -m pip install --target tests/.deps -r tests/requirements.txt
python -B tests/test_vendor_buy.py
```

The suite executes the actual addon in Lupa's Lua 5.1 runtime. The mocked WoW
boundary controls merchant offers, bag delivery, errors, events and time. A
purchase run must begin with a simulated real click; confirmed batches then
continue on a timer. Tests cover whole multi-item orders, pacing, no overlapping
requests, cancellation, errors, closing, timeouts, target caps, receipt recovery,
live tooltip refresh and purchase limits. Request groups are observed by their
virtual send time; raw calls independently check the 50-call / batch-item caps,
merchant stack limits, bundle increments and local gold/stock reservations.
The suite also executes the actual Auctionator synchronization
module for cumulative receipt integration and 36 public API scenarios.
`VendorBuyTests` pins a 5,000-item batch so multi-batch flows stay exercised;
`DefaultBatchTests` covers shipped defaults (10,000-item multi-reagent batches,
bundle round-up, settings, event filtering and receipt cleanup).
Dependencies stay in the ignored `tests/.deps` folder.

These are addon state checks. They do not establish live server acceptance,
merchant purchase limits, actual event timing, or the rendered appearance in WoW.

`python -B tests/measure_refresh.py` counts calls into canonical CraftSim missing
queries, queue crafter lookups and merchant APIs during deterministic event
bursts. Pass `--addon <path>` to compare an older source snapshot. These counters
measure repeated addon work; they do not measure actual client FPS or prove the
source of every live-frame delay.
