#!/usr/bin/env python3
"""Parallel SSH: sudo reboot on SI Cluster #100–#571 (472 nodes)."""
from __future__ import annotations

import concurrent.futures
import subprocess
import time
from pathlib import Path

IPS = Path("/tmp/si-cluster-100-571-ips.txt")
OUT = Path("/Users/peter/Downloads/BeamioContract/deployments/si-cluster-100-571-reboot-results.tsv")
LOG_DIR = Path("/tmp/si-reboot-logs")
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
        "ServerAliveInterval=15",
        "-o",
        "ServerAliveCountMax=8",
        "-o",
        "StrictHostKeyChecking=accept-new",
        f"peter@{ip}",
        "bash -lc 'sync; sudo reboot'",
    ]
    try:
        with log.open("w") as f:
            p = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, timeout=180)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        rc = 124
    except Exception as e:
        log.write_text(str(e))
        rc = 1
    dur = int(time.time() - start)
    text = log.read_text(errors="replace") if log.exists() else ""
    status = "fail"
    if rc == 0:
        status = "ok"
    elif rc == 255 and dur >= 2:
        # connection dropped after reboot started
        status = "ok_reboot"
    elif rc == 255 and any(
        x in text.lower()
        for x in ("going down", "closed by remote", "connection to", "reboot")
    ):
        status = "ok_reboot"
    return nft, ip, status, rc, dur


def main() -> None:
    rows = []
    for line in IPS.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 2:
            rows.append((parts[0], parts[1]))
        else:
            # ip-only
            rows.append(("?", parts[0]))
    print(f"targets={len(rows)} parallel={PARALLEL}", flush=True)
    t0 = time.time()
    results: list[tuple[str, str, str, int, int]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=PARALLEL) as ex:
        futs = [ex.submit(run_one, nft, ip) for nft, ip in rows]
        done = 0
        for fut in concurrent.futures.as_completed(futs):
            r = fut.result()
            results.append(r)
            done += 1
            if done % 25 == 0 or done == len(rows):
                ok = sum(1 for x in results if x[2].startswith("ok"))
                print(f"progress {done}/{len(rows)} okish={ok}", flush=True)
    results.sort(key=lambda x: (int(x[0]) if x[0].isdigit() else 0, x[1]))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w") as f:
        f.write("nft\tip\tstatus\trc\tdur_s\n")
        for nft, ip, status, rc, dur in results:
            f.write(f"{nft}\t{ip}\t{status}\t{rc}\t{dur}\n")
    ok = sum(1 for x in results if x[2].startswith("ok"))
    fail = [x for x in results if not x[2].startswith("ok")]
    print(f"done in {int(time.time()-t0)}s ok={ok} fail={len(fail)} wrote {OUT}", flush=True)
    for x in fail[:30]:
        print(f"FAIL {x}", flush=True)


if __name__ == "__main__":
    main()
