"""
LAN discovery + pairing, decoupled from the setup CLI.

setup_device.py is just the command-line front end for these functions;
keeping the msmart-ng discovery calls here means a future "scan for new
units" button in the web UI can reuse the exact same code path (call
`discover_all()`, turn each result into a `UnitConfig` via `to_unit`,
hand it to `ConfigStore.add_or_update_unit`).
"""
from __future__ import annotations

import asyncio
import ipaddress
import socket
from typing import Dict, List, Optional

from msmart.discover import Discover

from meow_ac.config.models import UnitConfig

# Midea LAN control ports. 6444 is the classic one; the 6440–6449 range
# covers firmware/model variants. A TCP-open check on any of these is a good
# "there's probably an AC here" heuristic for the scan-to-add flow — the
# actual add step still runs real msmart discovery (discover_one) to confirm.
MIDEA_PORTS = tuple(range(6440, 6450))

# Safety cap: never scan a subnet larger than this many addresses (a /22).
_MAX_SCAN_HOSTS = 1024


async def discover_all() -> list:
    """Broadcast on the LAN and return every unit that answers."""
    return await Discover.discover()


async def discover_one(ip: str) -> List:
    """Probe a single known IP; returns a 0- or 1-element list so callers
    can treat it the same as `discover_all()`."""
    device = await Discover.discover_single(ip)
    return [device] if device else []


def to_unit(device, name: str) -> UnitConfig:
    """Turn a discovered msmart device into a storable UnitConfig."""
    return UnitConfig(
        name=name,
        ip=device.ip,
        port=getattr(device, "port", 6444),
        id=device.id,
        token=getattr(device, "token", None),
        key=getattr(device, "key", None),
    )


# --- TCP port scan (scan-to-add) --------------------------------------------

def local_private_subnet() -> Optional[str]:
    """Best-effort: the server's own private /24, as a CIDR string.

    Uses the UDP-connect trick — connecting a datagram socket sets the local
    source address via the routing table without sending a packet, so it
    works even under the hardened systemd egress lockdown (no egress needed)
    and behind a loopback bind (the host still has its LAN interface). Tries
    a few private gateways; the first that yields a private, non-loopback
    local address wins. Returns None if it can't tell — callers then require
    an explicit subnet.
    """
    for probe in ("192.168.1.1", "10.0.0.1", "172.16.0.1"):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect((probe, 9))  # no packet is actually sent for UDP connect
            ip = s.getsockname()[0]
        except OSError:
            continue
        finally:
            s.close()
        try:
            addr = ipaddress.ip_address(ip)
        except ValueError:
            continue
        if addr.is_private and not addr.is_loopback:
            return str(ipaddress.ip_network(f"{ip}/24", strict=False))
    return None


async def _port_open(ip: str, port: int, timeout: float) -> Optional[int]:
    """Return `port` if a TCP connection opens within `timeout`, else None."""
    try:
        _, writer = await asyncio.wait_for(asyncio.open_connection(ip, port), timeout)
    except (OSError, asyncio.TimeoutError):
        return None
    writer.close()
    try:
        await asyncio.wait_for(writer.wait_closed(), 0.25)
    except (OSError, asyncio.TimeoutError):
        pass
    return port


async def _host_probe(ip: str, ports, timeout: float) -> Optional[int]:
    """Return the first open Midea port on `ip` (ports probed in parallel)."""
    tasks = [asyncio.create_task(_port_open(ip, p, timeout)) for p in ports]
    try:
        open_port: Optional[int] = None
        for coro in asyncio.as_completed(tasks):
            p = await coro
            if p is not None and open_port is None:
                open_port = p
        return open_port
    finally:
        for t in tasks:
            t.cancel()


async def scan_subnet(
    subnet: str,
    ports=MIDEA_PORTS,
    timeout: float = 0.4,
    host_concurrency: int = 64,
) -> Dict[str, int]:
    """Scan a private subnet for hosts with a Midea port open.

    Returns {ip: first_open_port}. Raises ValueError for a non-private or
    oversized subnet — we never scan public address space, and cap the host
    count so a typo like /8 can't launch a million connections.
    """
    net = ipaddress.ip_network(subnet, strict=False)
    if not net.is_private:
        raise ValueError("refusing to scan a non-private subnet")
    if net.num_addresses > _MAX_SCAN_HOSTS:
        raise ValueError(f"subnet too large (> {_MAX_SCAN_HOSTS} addresses)")

    sem = asyncio.Semaphore(host_concurrency)
    found: Dict[str, int] = {}

    async def _one(ip) -> None:
        async with sem:
            port = await _host_probe(str(ip), ports, timeout)
            if port is not None:
                found[str(ip)] = port

    await asyncio.gather(*[_one(ip) for ip in net.hosts()])
    return found
