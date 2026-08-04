/**
 * Blockscout 验证 ConetTreasuryPeer v4 + Offline + DepositLib / SigLib。
 * 用法: npx tsx scripts/verifyConetTreasuryPeerV4OnScan.ts
 */
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SCAN = "https://mainnet.conet.network";
const RPC = process.env.CONET_RPC_URL || "https://rpc1.conet.network";

const meta = JSON.parse(
  fs.readFileSync(path.join(__dirname, "..", "deployments", "conet-TreasuryPeer-v4.json"), "utf-8")
) as {
  peer: string;
  stableSwapOffline: string;
  depositLib: string;
  stableSwapSigLib: string;
  wrappedLib: string;
  stableSwapLib: string;
};

async function rpc(method: string, params: unknown[]) {
  const r = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const j = (await r.json()) as { result?: string; error?: { message: string } };
  if (j.error) throw new Error(j.error.message);
  return j.result as string;
}

async function checkVerified(addr: string): Promise<boolean> {
  const r = await fetch(`${SCAN}/api/v2/smart-contracts/${addr}`);
  if (!r.ok) return false;
  const d = (await r.json()) as {
    is_verified?: boolean;
    is_partially_verified?: boolean;
    source_code?: string;
  };
  return Boolean(d.is_verified || d.is_partially_verified || (d.source_code && d.source_code.length > 0));
}

async function main() {
  const targets = [
    { label: "DepositLib", addr: meta.depositLib },
    { label: "SigLib", addr: meta.stableSwapSigLib },
    { label: "Offline", addr: meta.stableSwapOffline },
    { label: "Peer", addr: meta.peer },
    { label: "WrappedLib", addr: meta.wrappedLib },
    { label: "StableSwapLib", addr: meta.stableSwapLib },
  ];

  console.log("CoNET Peer v4 verification status (Blockscout v2):\n");
  for (const t of targets) {
    const code = await rpc("eth_getCode", [t.addr, "latest"]);
    const codeLen = code && code !== "0x" ? (code.length - 2) / 2 : 0;
    const verified = codeLen > 0 ? await checkVerified(t.addr) : false;
    console.log(
      `${t.label.padEnd(14)} ${t.addr}  code=${codeLen}  verified=${verified ? "yes" : "no"}`
    );
    if (codeLen > 0 && !verified) {
      console.log(
        `  → 需 Standard JSON 验证: project/src/b-unit/... 见 conet-mainnet-blockscout-verify.mdc`
      );
      console.log(
        `     node scripts/exportStandardJsonFromBuildInfo.mjs <Key> --full 后提交 v2 standard-input`
      );
    }
  }
  console.log("\nPeer/Offline 已部署；若 verified=no，请用 FULL build-info + libraries 当场提交 Blockscout。");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
