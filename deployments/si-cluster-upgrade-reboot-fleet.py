#!/usr/bin/env python3
"""Parallel SSH: ~/.sh/upgrade && sudo reboot on SI Cluster #100–#571."""
from __future__ import annotations

import concurrent.futures
import subprocess
import time
from pathlib import Path

IPS = Path("/tmp/si-cluster-100-571-ips.txt")
OUT = Path("/tmp/si-upgrade-reboot-results.tsv")
LOG_DIR = Path("/tmp/si-upgrade-reboot-logs")
PARALLEL = 40
SSH_CONNECT_TIMEOUT = 20


def run_one(nft: str, ip: str) -> tuple[str, str, str, int, int]:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log = LOG_DIR / f"{nft}_{ip}.log"
    start = time.time()
    cmd = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        f"ConnectTimeout={SSH_CONNECT_TIMEOUT}",
        "-o",
        "ServerAliveInterval=30",
        "-o",
        "ServerAliveCountMax=120",
        "-o",
        "StrictHostKeyChecking=accept-new",
        f"peter@{ip}",
        "bash -lc 'set -e; ~/.sh/upgrade; sync; sudo reboot'",
    ]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=2400)
        rc = p.returncode
        text = (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired as e:
        rc = 124
        text = (e.stdout or "") + (e.stderr or "") + "\nTIMEOUT\n"
    except Exception as e:
        rc = 1
        text = f"LOCAL_ERROR {e}\n"
    log.write_text(text, encoding="utf-8", errors="replace")
    dur = int(time.time() - start)
    low = text.lower()
    st = "fail"
    if rc == 0:
        st = "ok"
    elif rc == 255 and any(
        x in low for x in ("reboot", "going down", "closed by remote", "connection to")
    ):
        st = "ok_reboot"
    elif rc == 255 and dur > 60:
        st = "ok_drop"
    print(f"[{st}] #{nft} {ip} rc={rc} {dur}s", flush=True)
    return nft, ip, st, rc, dur


def main() -> None:
    rows = []
    for line in IPS.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        nft, ip = line.split("\t")
        rows.append((nft, ip))
    print(f"hosts={len(rows)} parallel={PARALLEL}", flush=True)
    results: list[tuple[str, str, str, int, int]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=PARALLEL) as ex:
        futs = [ex.submit(run_one, nft, ip) for nft, ip in rows]
        for fut in concurrent.futures.as_completed(futs):
            results.append(fut.result())
    results.sort(key=lambda r: int(r[0]))
    with OUT.open("w", encoding="utf-8") as f:
        for nft, ip, st, rc, dur in results:
            f.write(f"{nft}\t{ip}\t{st}\t{rc}\t{dur}\n")
    from collections import Counter

    c = Counter(r[2] for r in results)
    print("==== SUMMARY ====", flush=True)
    for k, v in sorted(c.items()):
        print(f"{k} {v}", flush=True)
    fails = [r for r in results if r[2] == "fail"]
    print(f"fail_count={len(fails)}", flush=True)
    for r in fails[:40]:
        print(f"FAIL #{r[0]} {r[1]} rc={r[3]} {r[4]}s", flush=True)


if __name__ == "__main__":
    main()
