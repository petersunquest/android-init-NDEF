#!/usr/bin/env node
/**
 * #132-#300: uptime check + GuardianNodesInfoV6 registration audit/register
 * Usage: node batch_132_300_workflow.cjs [uptime|check|register|all]
 */
const { ethers } = require("ethers");
const { execSync, spawnSync } = require("node:child_process");
const { createRequire } = require("node:module");
const { join } = require("node:path");
const { homedir } = require("node:os");
const fs = require("node:fs");

const CLUSTER = "/Users/peter/Downloads/seguro-pro/CoNET-DL-master/src/CONET-Holesky-new/SI Cluster NEW.sh";
const RPC = "https://publicrpc.conet.network";
const CONTRACT = "0xBC6b53065b5647261396d002bDBA0d3396E0722f";
const abi = require("../src/mainnet/abi/GuardianNodesInfoV6.json");
const MODE = process.argv[2] || "all";
const PARALLEL = Number(process.env.PARALLEL || "25");

function parseNodes() {
  const lines = fs.readFileSync(CLUSTER, "utf8").split("\n");
  const nodes = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^#(\d+)$/);
    if (!m) continue;
    const id = Number(m[1]);
    if (id < 132 || id > 300) continue;
    const row = (lines[i + 1] || "").trim().split(/\s+/);
    if (!row[0] || !/^\d+\.\d+\.\d+\.\d+$/.test(row[0])) continue;
    nodes.push({ id, ip: row[0], region: row[1] || "PA.US" });
  }
  nodes.sort((a, b) => a.id - b.id);
  return nodes;
}

function sshFetchNodeData(ip) {
  const remote =
    'node -e "' +
    'const j=require(process.env.HOME+\\"/.CoNET-SI/nodeSetup.json\\");' +
    'const pk=j.pgpKey||{};' +
    'let addr=null;try{addr=JSON.parse(j.keychain).address}catch(e){}' +
    'console.log(JSON.stringify({pgpB64:Buffer.from(pk.publicKey||\\"\\").toString(\\"base64\\"),keyID:pk.keyID,owner:addr?(\\"0x\\"+addr):null,ip:j.ipV4}));' +
    '"';
  const cmd = `ssh -o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new ${ip} '${remote}'`;
  const out = execSync(cmd, { encoding: "utf8", timeout: 20000 });
  return JSON.parse(out.trim());
}

async function runUptime(nodes) {
  const TMP = fs.mkdtempSync("/tmp/uptime-");
  let i = 0;
  const batch = [];
  async function flush() {
    await Promise.all(batch.splice(0));
  }
  for (const n of nodes) {
    batch.push((async () => {
      const { spawn } = require("node:child_process");
      await new Promise((resolve) => {
        const p = spawn("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new", n.ip, "uptime -p"], { stdio: ["ignore", "pipe", "pipe"] });
        let out = "";
        p.stdout.on("data", (d) => (out += d));
        p.on("close", (rc) => {
          const line = rc === 0 ? `[UP]   #${n.id} ${n.ip}  ${out.trim()}` : `[DOWN] #${n.id} ${n.ip}  rc=${rc}`;
          fs.writeFileSync(`${TMP}/${n.id}.txt`, line);
          resolve();
        });
      });
    })());
    if (batch.length >= PARALLEL) await flush();
  }
  await flush();
  const lines = fs.readdirSync(TMP).sort((a, b) => Number(a) - Number(b)).map((f) => fs.readFileSync(`${TMP}/${f}`, "utf8"));
  fs.rmSync(TMP, { recursive: true, force: true });
  const up = lines.filter((l) => l.startsWith("[UP]")).length;
  const down = lines.filter((l) => l.startsWith("[DOWN]")).length;
  console.log(lines.join("\n"));
  console.log(`---- UP=${up} DOWN=${down} TOTAL=${nodes.length}`);
  return { up, down };
}

async function runCheck(provider, nodes) {
  const c = new ethers.Contract(CONTRACT, abi, provider);
  const results = [];
  for (const n of nodes) {
    const exists = await c.ipaddressExisting(n.ip);
    const chainId = exists ? (await c.ip2id(n.ip)).toString() : "0";
    const idIp = await c.id2ip(n.id);
    const ok = exists && chainId === String(n.id) && idIp === n.ip;
    results.push({ ...n, exists, chainId, idIp, ok });
    if (!ok) console.log(`[MISSING] #${n.id} ${n.ip} exists=${exists} ip2id=${chainId} id2ip=${idIp || "(empty)"}`);
  }
  const okN = results.filter((r) => r.ok).length;
  console.log(`---- registered_ok=${okN} missing=${results.length - okN} total=${results.length}`);
  return results;
}

async function runRegister(provider, wallet, nodes, checkResults) {
  const c = new ethers.Contract(CONTRACT, abi, wallet);
  const c0 = new ethers.Contract(CONTRACT, abi, provider);
  const missing = checkResults.filter((r) => !r.ok).sort((a, b) => a.id - b.id);
  if (!missing.length) {
    console.log("All nodes already registered correctly.");
    return [];
  }
  console.log(`Registering ${missing.length} nodes in ascending id order...`);
  const txs = [];
  for (const n of missing) {
  if (await c0.ipaddressExisting(n.ip)) {
      const cid = (await c0.ip2id(n.ip)).toString();
      if (cid === String(n.id)) { console.log(`[skip] #${n.id} already ok`); continue; }
      console.error(`[ABORT] #${n.id} ${n.ip} ip exists with wrong id=${cid}`);
      continue;
    }
    let nd;
    try { nd = sshFetchNodeData(n.ip); } catch (e) {
      console.error(`[FAIL] #${n.id} ${n.ip} ssh fetch: ${e.message}`);
      continue;
    }
    if (!nd.pgpB64 || !nd.keyID || !nd.owner) {
      console.error(`[FAIL] #${n.id} ${n.ip} incomplete nodeSetup.json`);
      continue;
    }
    const owner = ethers.getAddress(nd.owner);
    console.log(`[addNode] #${n.id} ${n.ip} ${n.region} keyID=${nd.keyID} owner=${owner}`);
    let tx;
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        tx = await c.addNode(n.id, n.ip, n.region, nd.pgpB64, nd.keyID, owner);
        break;
      } catch (e) {
        const msg = e.shortMessage || e.message || "";
        if (attempt < 3 && /replacement fee|nonce|already known/i.test(msg)) {
          console.log(`  retry ${attempt}/3 after fee/nonce issue, waiting 15s...`);
          await new Promise((r) => setTimeout(r, 15000));
          continue;
        }
        throw e;
      }
    }
    console.log(`  tx: ${tx.hash}`);
    const rc = await tx.wait();
    console.log(`  mined block ${rc.blockNumber}`);
    txs.push({ id: n.id, ip: n.ip, hash: tx.hash });
    await new Promise((r) => setTimeout(r, 2000));
  }
  return txs;
}

(async () => {
  const nodes = parseNodes();
  console.log(`Parsed ${nodes.length} nodes (#132-#300)`);
  const provider = new ethers.JsonRpcProvider(RPC);

  if (MODE === "uptime" || MODE === "all") {
    console.log("\n=== UPTIME CHECK ===");
    await runUptime(nodes);
  }
  if (MODE === "check" || MODE === "all") {
    console.log("\n=== ON-CHAIN CHECK ===");
    var checkResults = await runCheck(provider, nodes);
  }
  if (MODE === "register" || MODE === "all") {
    if (!checkResults) checkResults = await runCheck(provider, nodes);
    const require2 = createRequire(__filename);
    const master = require2(join(homedir(), ".master.json"));
    const wallet = new ethers.Wallet(master.settle_contractAdmin[0], provider);
    console.log("\n=== REGISTER (admin " + wallet.address + ") ===");
    const txs = await runRegister(provider, wallet, nodes, checkResults);
    if (txs.length) {
      console.log("\n=== POST-REGISTER VERIFY ===");
      await runCheck(provider, nodes);
    }
  }
})().catch((e) => { console.error("ERROR:", e.shortMessage || e.message); process.exit(1); });
