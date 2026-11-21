#!/usr/bin/env python3
"""Check network reachability from an independent public or WireGuard client."""
from __future__ import annotations

import argparse
import http.client
import json
import socket
from pathlib import Path
from urllib.parse import urlsplit


def reachable(host, port):
    with socket.create_connection((host, port), timeout=3):
        return True


def probe(host, port, expected):
    try:
        actual = reachable(host, port)
    except OSError:
        actual = False
    passed = actual == expected
    address = f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
    print(f"[{'PASS' if passed else 'FAIL'}] {address} is {'reachable' if actual else 'unreachable'}")
    return {"host": host, "port": port, "reachable": actual, "passed": passed}


def endpoint(value):
    parsed = urlsplit("//" + value)
    if not parsed.hostname or not parsed.port or parsed.username or parsed.path:
        raise argparse.ArgumentTypeError("Use host:port or [IPv6]:port")
    return parsed.hostname, parsed.port


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--role", required=True, choices=("public", "device", "revoked"))
    parser.add_argument("--host", required=True)
    parser.add_argument("--allow", action="append", default=[], type=endpoint)
    parser.add_argument("--block", action="append", default=[], type=endpoint)
    parser.add_argument("--baseline", type=Path, help="Compare results captured before a VPS reboot")
    parser.add_argument("--save-baseline", type=Path)
    args = parser.parse_args()
    if args.role == "device" and not args.allow:
        parser.error("Device checks require --allow with a working private service to prove the tunnel is active")
    if args.role == "revoked" and not args.block:
        parser.error("Revocation checks require --block with a service previously reachable by this device")
    if args.role != "device" and args.allow:
        parser.error("Only an approved device should have reachable private services")
    results = []
    if args.role == "public":
        # Test every advertised A/AAAA address, including a forgotten IPv6 listener.
        addresses = sorted({info[4][0] for info in socket.getaddrinfo(args.host, None, type=socket.SOCK_STREAM)})
        for address in addresses:
            for port in (4173, 4174, 2586, 3000, 3001, 8008, 8080, 30000):
                results.append(probe(address, port, False))
        for path in ("/api/health", "/api/state", "/api/control/overview", "/relay/security-audit", "/.tater_tunnel/vps-agent.json"):
            connection = http.client.HTTPSConnection(args.host, 443, timeout=5)
            try:
                connection.request("GET", path)
                response = connection.getresponse()
                passed = response.status == 404
                response.read(4096)
                print(f"[{'PASS' if passed else 'FAIL'}] Public HTTPS {path}: HTTP {response.status}")
                results.append({"host": args.host, "path": path, "status": response.status, "passed": passed})
            except (OSError, http.client.HTTPException):
                print(f"[FAIL] Public HTTPS {path} could not be verified")
                results.append({"host": args.host, "path": path, "passed": False})
            finally:
                connection.close()
    elif args.role == "device":
        connection = http.client.HTTPConnection(args.host, 4174, timeout=3)
        try:
            connection.request("GET", "/api/state")
            response = connection.getresponse()
            passed = response.status == 403
            response.read(4096)
            print(f"[{'PASS' if passed else 'FAIL'}] Ordinary device management request: HTTP {response.status}")
            results.append({"host": args.host, "port": 4174, "status": response.status, "passed": passed})
        except OSError:
            print("[PASS] Management port is unreachable from this device")
            results.append({"host": args.host, "port": 4174, "reachable": False, "passed": True})
        finally:
            connection.close()
    else:
        results.append(probe(args.host, 4174, False))
    for host, port in args.allow:
        results.append(probe(host, port, True))
    for host, port in args.block:
        results.append(probe(host, port, False))
    report = {"role": args.role, "results": results}
    if args.baseline:
        previous = json.loads(args.baseline.read_text())
        if previous != report:
            print("[FAIL] Network results differ from the saved baseline")
            return 1
        print("[PASS] Network results match the saved baseline")
    if args.save_baseline:
        with args.save_baseline.open("x", encoding="utf-8") as handle:
            json.dump(report, handle, indent=2)
    print("Results describe reachability from this client. Run public tests outside the VPS and WireGuard.")
    return 0 if results and all(item["passed"] for item in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
