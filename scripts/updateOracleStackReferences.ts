/**
 * 从 scripts/oracleDeployConstants.ts / deployments/beamioOracle-create2-meta.json
 * 同步跨链同址 Oracle + QuoteHelper 到 x402sdk / 客户端 / 脚本默认值。
 *
 * 运行: npx tsx scripts/updateOracleStackReferences.ts
 */

import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import {
  BEAMIO_ORACLE_PREDICTED,
  BEAMIO_QUOTE_HELPER_PREDICTED,
} from "./oracleDeployConstants.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");

function patchQuoted(content: string, name: string, addr: string): string {
  return content.replace(
    new RegExp(`(${name}\\s*=\\s*['"])0x[a-fA-F0-9]{40}(['"])`, "g"),
    `$1${addr}$2`
  );
}

function patchConst(content: string, name: string, addr: string): string {
  return content.replace(
    new RegExp(`(const ${name} = ')0x[a-fA-F0-9]{40}(')`, "g"),
    `$1${addr}$2`
  );
}

function patchFile(rel: string, patcher: (c: string) => string, label: string) {
  const fp = path.join(ROOT, rel);
  if (!fs.existsSync(fp)) return;
  const prev = fs.readFileSync(fp, "utf-8");
  const next = patcher(prev);
  if (next !== prev) {
    fs.writeFileSync(fp, next);
    console.log("updated:", label);
  }
}

function main() {
  const oracle = BEAMIO_ORACLE_PREDICTED;
  const qh = BEAMIO_QUOTE_HELPER_PREDICTED;
  console.log("BEAMIO_ORACLE:", oracle);
  console.log("BEAMIO_QUOTE_HELPER:", qh);

  patchFile("src/x402sdk/src/chainAddresses.ts", (c) => {
    let n = c;
    if (!n.includes("export const BEAMIO_ORACLE")) {
      n = n.replace(
        "/** CoNET BeamioOracle；与 deployments/conet-addresses.json `beamioOracle` 同步 */",
        "/** 跨链同址 BeamioOracle（Nick CREATE2；Base + CoNET 同值） */\nexport const BEAMIO_ORACLE = '" +
          oracle +
          "'\n/** 跨链同址 BeamioQuoteHelperV07 */\nexport const BEAMIO_QUOTE_HELPER = '" +
          qh +
          "'\n/** CoNET BeamioOracle；与 deployments/conet-addresses.json `beamioOracle` 同步 */"
      );
    }
    n = patchQuoted(n, "BEAMIO_ORACLE", oracle);
    n = patchQuoted(n, "BEAMIO_QUOTE_HELPER", qh);
    n = patchQuoted(n, "CONET_BEAMIO_ORACLE", oracle);
    n = patchQuoted(n, "BASE_BEAMIO_ORACLE", oracle);
    return n;
  }, "x402sdk chainAddresses.ts");

  patchFile("src/x402sdk/src/MemberCard.ts", (c) => patchConst(c, "BeamioOracle", oracle), "x402sdk MemberCard.ts");

  patchFile("src/SilentPassUI/src/services/beamio.ts", (c) => patchConst(c, "BEAMIO_ORACLE_BASE", oracle), "SilentPassUI beamio.ts");

  patchFile("src/bizSite/src/services/beamio.ts", (c) => patchConst(c, "BEAMIO_ORACLE_BASE", oracle), "bizSite beamio.ts");

  patchFile("src/CoNET-DL/src/endpoint/GuardianOracle.ts", (c) => patchConst(c, "beamioOracleAddr", oracle), "CoNET-DL GuardianOracle.ts");

  patchFile("scripts/checkBeamioOracleIntegrity.ts", (c) => {
    let n = patchConst(c, "ORACLE_BASE", oracle);
    n = patchConst(n, "ORACLE_CONET", oracle);
    return n;
  }, "checkBeamioOracleIntegrity.ts");

  patchFile("scripts/API server/MemberCard.ts", (c) => patchConst(c, "BeamioOracle", oracle), "API server MemberCard.ts");

  // config + deployments authoritative JSON
  const baseCfg = path.join(ROOT, "config", "base-addresses.json");
  if (fs.existsSync(baseCfg)) {
    const j = JSON.parse(fs.readFileSync(baseCfg, "utf-8"));
    j.BEAMIO_ORACLE = oracle;
    j.BEAMIO_QUOTE_HELPER = qh;
    fs.writeFileSync(baseCfg, JSON.stringify(j, null, 2) + "\n");
    console.log("updated: config/base-addresses.json");
  }

  const conetAddr = path.join(ROOT, "deployments", "conet-addresses.json");
  if (fs.existsSync(conetAddr)) {
    const j = JSON.parse(fs.readFileSync(conetAddr, "utf-8"));
    j.beamioOracle = oracle;
    j.beamioQuoteHelperV07 = qh;
    fs.writeFileSync(conetAddr, JSON.stringify(j, null, 2) + "\n");
    console.log("updated: deployments/conet-addresses.json");
  }

  console.log("\n✅ Oracle stack 引用同步完成");
}

main();
