"""Count actual addon boundary calls; this is not a live-client FPS benchmark."""
from pathlib import Path
import argparse
import json
import sys

TESTS = Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS / ".deps"))
from lupa.lua51 import LuaRuntime


def measure(source: Path, scenario: str) -> dict[str, int]:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute((TESTS / "wow_mock.lua").read_text(encoding="utf-8"))
    lua.globals().addon_source = source.read_text(encoding="utf-8-sig")
    lua.execute("assert(loadstring(addon_source))('CraftSimVendorBuy')")
    lua.execute("S.event('ADDON_LOADED','CraftSimVendorBuy'); S.open()")
    lua.execute(scenario)
    return dict(lua.globals().S.counters.items())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--addon", type=Path,
        default=TESTS.parent / "CraftSimVendorBuy" / "CraftSimVendorBuy.lua",
    )
    args = parser.parse_args()
    scenarios = {
        "idle_20_merchant_and_money_pairs": """
            S.resetCounters()
            for index=1,20 do
                S.event('MERCHANT_UPDATE')
                S.event('PLAYER_MONEY')
            end
        """,
        "running_watchdog_2_seconds": "S.click(); S.resetCounters(); S.advance(2)",
        "running_8_event_pairs_and_watchdog": """
            S.click()
            S.resetCounters()
            for index=1,8 do
                S.event('MERCHANT_UPDATE')
                S.event('PLAYER_MONEY')
                S.advance(0.25)
            end
        """,
    }
    print(json.dumps({name: measure(args.addon, body) for name, body in scenarios.items()}, indent=2))
