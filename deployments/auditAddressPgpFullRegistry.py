#!/usr/bin/env python3
"""
Audit AddressPGP node registrations vs miningRate + Guardian.

Truth sources:
  - miningRate.nodeWallets[] → operational wallet per IP
  - Guardian IP2PGP / ipaddress2owner → domain + owner on Guardian
  - AddressPGP nodeKeyHash2Wallet / nodeWallet2KeyHash / nodeKeyExists

Wrong when:
  - bound wallet ≠ miningRate wallet
  - real wallet has nodeWallet2KeyHash == 0
  - real wallet maps to a different domain than Guardian
  - domain not registered (nodeKeyExists false)
"""
from __future__ import annotations

import json
import subprocess
import sys
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path("/Users/peter/Downloads/BeamioContract")
OUT = ROOT / "deployments" / "addresspgp-full-registry-audit.json"
RPC = "https://rpc1.conet.network"
PGP = "0x684b0ac760cEE9c9b85de36d69746420648Cf9e2"
GUARDIAN = "0xBC6b53065b5647261396d002bDBA0d3396E0722f"
GHOST = "0xb0559C92e9Ca3887556d202792a596FcC7760f10".lower()


def eth_call(to: str, data: str) -> str:
    body = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_call",
            "params": [{"to": to, "data": data}, "latest"],
        }
    ).encode()
    req = urllib.request.Request(
        RPC, data=body, headers={"content-type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        j = json.load(r)
    if "error" in j:
        raise RuntimeError(j["error"])
    return j["result"]


def run_node_audit() -> dict:
    """Use ethers in bizSite for ABI-safe batch audit."""
    script = r"""
const { ethers } = require('ethers')
const fs = require('fs')
const RPC = process.env.RPC || 'https://rpc1.conet.network'
const PGP = '0x684b0ac760cEE9c9b85de36d69746420648Cf9e2'
const G = '0xBC6b53065b5647261396d002bDBA0d3396E0722f'
const GHOST = '0xb0559C92e9Ca3887556d202792a596FcC7760f10'

async function fetchMiningRate() {
  const res = await fetch('https://apiv4.conet.network/api/miningRate', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: '{}',
  })
  if (!res.ok) throw new Error('miningRate HTTP ' + res.status)
  return res.json()
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC)
  const pgp = new ethers.Contract(PGP, [
    'function nodeKeyExists(bytes32) view returns (bool)',
    'function nodeKeyIDByHash(bytes32) view returns (string)',
    'function nodeKeyHash2Wallet(bytes32) view returns (address)',
    'function nodeWallet2KeyHash(address) view returns (bytes32)',
  ], provider)
  const guardian = new ethers.Contract(G, [
    'function IP2PGP(string) view returns (address,string)',
    'function ipaddress2owner(string) view returns (address)',
    'function ipaddressExisting(string) view returns (bool)',
  ], provider)

  const mr = await fetchMiningRate()
  const nodeWallets = Array.isArray(mr.nodeWallets) ? mr.nodeWallets : []
  console.error('miningRate epoch', mr.epoch, 'n', nodeWallets.length)

  // Scan NodeWalletBound events (chunked) for registry set
  const iface = new ethers.Interface([
    'event NodeWalletBound(bytes32 indexed pgpKeyIDHash, address indexed nodeWallet)',
  ])
  const topic0 = iface.getEvent('NodeWalletBound').topicHash
  const head = await provider.getBlockNumber()
  const CHUNK = 4500
  const eventByHash = new Map() // hash -> {wallet, block, tx}
  for (let from = 0; from <= head; from += CHUNK) {
    const to = Math.min(from + CHUNK - 1, head)
    let logs = []
    try {
      logs = await provider.getLogs({ address: PGP, fromBlock: from, toBlock: to, topics: [topic0] })
    } catch (e) {
      console.error('getLogs fail', from, to, e.shortMessage || e.message)
      continue
    }
    for (const log of logs) {
      const p = iface.parseLog(log)
      eventByHash.set(p.args.pgpKeyIDHash, {
        wallet: ethers.getAddress(p.args.nodeWallet),
        block: log.blockNumber,
        tx: log.transactionHash,
      })
    }
    if (logs.length) console.error('events', from, to, logs.length, 'unique', eventByHash.size)
  }

  const conc = 12
  const rows = []
  const queue = [...nodeWallets]
  async function worker() {
    while (queue.length) {
      const item = queue.shift()
      const ip = String(item.ipAddr || '').trim()
      const mrWallet = ethers.getAddress(item.wallet)
      const out = { ip, miningRateWallet: mrWallet }
      try {
        const exists = await guardian.ipaddressExisting(ip)
        out.guardianExists = exists
        if (!exists) {
          out.issues = ['guardian_ip_missing']
          rows.push(out)
          continue
        }
        const owner = await guardian.ipaddress2owner(ip)
        const [, domain] = await guardian.IP2PGP(ip)
        out.guardianOwner = ethers.getAddress(owner)
        out.domain = String(domain || '').toUpperCase()
        const h = ethers.keccak256(ethers.toUtf8Bytes(out.domain))
        out.routeKeyHash = h
        out.nodeKeyExists = await pgp.nodeKeyExists(h)
        out.boundWallet = await pgp.nodeKeyHash2Wallet(h)
        out.boundWalletIsZero = out.boundWallet === ethers.ZeroAddress
        out.realWalletHash = await pgp.nodeWallet2KeyHash(mrWallet)
        out.realWalletHashIsZero = out.realWalletHash === ethers.ZeroHash
        out.guardianOwnerHash = await pgp.nodeWallet2KeyHash(out.guardianOwner)
        out.domainIdOnChain = out.nodeKeyExists ? await pgp.nodeKeyIDByHash(h) : ''
        const issues = []
        if (!out.domain) issues.push('empty_domain')
        if (!out.nodeKeyExists) issues.push('domain_not_in_addresspgp')
        if (out.boundWalletIsZero) issues.push('hash2wallet_zero')
        else if (out.boundWallet.toLowerCase() !== mrWallet.toLowerCase()) {
          issues.push('bound_wallet_ne_miningrate')
        }
        if (out.guardianOwner.toLowerCase() !== mrWallet.toLowerCase()) {
          issues.push('guardian_owner_ne_miningrate')
        }
        if (out.realWalletHashIsZero) issues.push('miningrate_wallet_unbound')
        else if (out.realWalletHash.toLowerCase() !== h.toLowerCase()) {
          issues.push('miningrate_wallet_points_other_domain')
        }
        if (out.boundWallet.toLowerCase() === GHOST.toLowerCase()) {
          issues.push('bound_to_ghost_0xb055')
        }
        out.issues = issues
        out.ok = issues.length === 0
        // event latest binding for this hash
        const ev = eventByHash.get(h)
        if (ev) out.lastEvent = ev
        rows.push(out)
      } catch (e) {
        out.issues = ['rpc_error']
        out.error = e.shortMessage || e.message
        rows.push(out)
      }
    }
  }
  await Promise.all(Array.from({ length: conc }, () => worker()))

  // Also list event-only domains not in miningRate
  const mrHashes = new Set(rows.filter(r => r.routeKeyHash).map(r => r.routeKeyHash.toLowerCase()))
  const orphanEvents = []
  for (const [h, ev] of eventByHash) {
    if (!mrHashes.has(h.toLowerCase())) {
      let domain = ''
      try { domain = await pgp.nodeKeyIDByHash(h) } catch {}
      let exists = false
      try { exists = await pgp.nodeKeyExists(h) } catch {}
      orphanEvents.push({ routeKeyHash: h, domain, nodeKeyExists: exists, ...ev })
    }
  }

  const bad = rows.filter(r => !r.ok)
  const issueCounts = {}
  for (const r of bad) {
    for (const i of r.issues || []) issueCounts[i] = (issueCounts[i] || 0) + 1
  }
  const boundWallets = {}
  for (const r of rows) {
    const w = (r.boundWallet || '').toLowerCase()
    if (!w) continue
    boundWallets[w] = (boundWallets[w] || 0) + 1
  }
  const report = {
    scannedAt: new Date().toISOString(),
    rpc: RPC,
    addressPgp: PGP,
    guardian: G,
    miningRate: { epoch: mr.epoch, totalMiners: mr.totalMiners, nodeWallets: nodeWallets.length },
    eventRegistrySize: eventByHash.size,
    summary: {
      total: rows.length,
      ok: rows.filter(r => r.ok).length,
      bad: bad.length,
      issueCounts,
      topBoundWallets: Object.entries(boundWallets).sort((a,b)=>b[1]-a[1]).slice(0,15),
      ghostBoundCount: rows.filter(r => (r.boundWallet||'').toLowerCase()===GHOST.toLowerCase()).length,
      unboundMiningWallets: rows.filter(r => r.realWalletHashIsZero).length,
    },
    badRows: bad.sort((a,b)=>String(a.ip).localeCompare(String(b.ip))),
    orphanEventsNotInMiningRate: orphanEvents.slice(0, 200),
    orphanEventsCount: orphanEvents.length,
    allRows: rows.sort((a,b)=>String(a.ip).localeCompare(String(b.ip))),
  }
  process.stdout.write(JSON.stringify(report))
}
main().catch(e => { console.error(e); process.exit(1) })
"""
    env = {**dict(**{k: v for k, v in __import__("os").environ.items()}), "RPC": RPC}
    p = subprocess.run(
        ["node", "-e", script],
        cwd=str(ROOT / "src" / "bizSite"),
        capture_output=True,
        text=True,
        env=env,
        timeout=3600,
    )
    if p.returncode != 0:
        print(p.stderr, file=sys.stderr)
        raise SystemExit(p.returncode)
    # stderr is progress, stdout is JSON
    if p.stderr:
        print(p.stderr, file=sys.stderr)
    return json.loads(p.stdout)


def main() -> None:
    report = run_node_audit()
    OUT.write_text(json.dumps(report, indent=2), encoding="utf-8")
    s = report["summary"]
    print("==== AddressPGP full registry audit ====")
    print(f"miningRate nodes: {report['miningRate']['nodeWallets']} epoch={report['miningRate']['epoch']}")
    print(f"NodeWalletBound unique hashes: {report['eventRegistrySize']}")
    print(f"ok={s['ok']} bad={s['bad']} total={s['total']}")
    print("issueCounts:", json.dumps(s["issueCounts"], indent=2))
    print("ghostBoundCount:", s["ghostBoundCount"])
    print("unboundMiningWallets:", s["unboundMiningWallets"])
    print("topBoundWallets:", s["topBoundWallets"][:8])
    print("orphanEventsCount:", report["orphanEventsCount"])
    print("wrote", OUT)
    # print sample bad
    for r in report["badRows"][:15]:
        print(
            f"  BAD {r.get('ip')} domain={r.get('domain')} "
            f"mr={r.get('miningRateWallet')} bound={r.get('boundWallet')} issues={r.get('issues')}"
        )


if __name__ == "__main__":
    main()
