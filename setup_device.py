"""
Discover all Midea AC units on the LAN and save them to config.json.

This is the command-line front end for `meow_ac.devices.discovery` and
`meow_ac.config.ConfigStore` — the discovery and config-writing logic
itself lives in the package, so the running service (and any future
"scan for new units" button in the web UI) shares the exact same code.

By default this broadcasts and picks up every unit that answers — no
need to run it three times for three units. Re-running it later (e.g.
one unit was powered off the first time, or you add a fourth one) merges
into the existing config rather than wiping it: units are matched by
their device id, and previously-set names are kept unless you type a
new one.

Usage:
    python setup_device.py                    # broadcast, finds everything
    python setup_device.py --ip 192.168.1.50  # add/update one unit by IP
    python setup_device.py --no-prompt         # skip the naming prompts
"""
import argparse
import asyncio
import json
from pathlib import Path

from meow_ac.config.store import ConfigStore
from meow_ac.devices.discovery import discover_all, discover_one, to_unit
from meow_ac.settings import DEFAULT_CONFIG_PATH


async def main(ip, out_path: Path, interactive_names: bool):
    store = ConfigStore(out_path)
    _, status = store.read_lenient()
    if status == "invalid":
        print(f"Warning: {out_path} exists but isn't valid JSON, starting fresh.")

    is_new_key = store.config.api_key is None
    store.ensure_api_key()

    devices = await (discover_one(ip) if ip else discover_all())

    if not devices:
        print(
            "No devices found. Make sure all the units are powered on and "
            "on the same subnet as meow, or pass --ip for one you already "
            "know (check your router's DHCP leases). You can also just "
            "re-run this later for the ones that were off — it won't "
            "touch the units you've already paired."
        )
        return

    found_count = 0
    for i, device in enumerate(devices, start=1):
        if not device.supported:
            print(f"Warning: device at {device.ip} reports supported=False, skipping.")
            continue

        existing = store.find_unit(str(device.id))
        name = existing.name if existing else f"AC {i}"

        if interactive_names:
            typed = input(f"Name for unit at {device.ip} [{name}]: ").strip()
            if typed:
                name = typed

        store.add_or_update_unit(to_unit(device, name))
        found_count += 1

    store.save()
    units = store.config.units

    print(f"\nThis run found {found_count} unit(s). Config now has {len(units)} total at {out_path}:")
    print(json.dumps([u.model_dump() for u in units], indent=2))

    if is_new_key:
        print(
            f"\nGenerated a new API key — the web UI will ask for this the "
            f"first time you open it on each browser/device:\n\n    {store.config.api_key}\n\n"
            "It's stored in this same config.json (mode 600). Anyone who "
            "has it can control these units over the LAN, so don't paste "
            "it anywhere public."
        )

    if any(u.token and u.key for u in units):
        print(
            "\nAt least one of these is a V3 device — keep its token/key "
            "safe somewhere outside of meow too, in case the Midea cloud "
            "ever goes down."
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--ip", help="Skip broadcast discovery, target a known IP directly")
    parser.add_argument("--out", type=Path, default=DEFAULT_CONFIG_PATH)
    parser.add_argument(
        "--no-prompt", action="store_true",
        help="Don't interactively ask for friendly names, just use defaults / existing names",
    )
    args = parser.parse_args()
    asyncio.run(main(args.ip, args.out, interactive_names=not args.no_prompt))
