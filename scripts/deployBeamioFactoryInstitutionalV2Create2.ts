/**
 * Nick CREATE2 deploy BeamioFactoryInstitutionalV2 (institutional AA V2 track).
 *
 *   npx hardhat run scripts/deployBeamioFactoryInstitutionalV2Create2.ts --network conet
 *
 * DRY_RUN=1 — predict only
 */

import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";
import { concat } from "ethers";
import {
  BEAMIO_AA_FACTORY_V2_ADMIN,
  BEAMIO_AA_FACTORY_V2_CREATE2_SALT,
  BEAMIO_AA_FACTORY_V2_INITIAL_ACCOUNT_LIMIT,
  NICK_CREATE2_FACTORY,
} from "./aaInstitutionalV2DeployConstants.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function nickCreate2DeployCalldata(salt: string, initCode: string): string {
  return concat([salt, initCode]);
}

async function main() {
  const { ethers } = await networkModule.connect();
  const [deployer] = await ethers.getSigners();
  if (!deployer) throw new Error("无签名账户");

  const nickFactory = ethers.getAddress(
    process.env.BEAMIO_AA_CREATE2_FACTORY || NICK_CREATE2_FACTORY
  );
  const dryRun = process.env.DRY_RUN === "1";

  const factoryCf = await ethers.getContractFactory("BeamioFactoryInstitutionalV2");
  const deployTx = await factoryCf.getDeployTransaction(
    BEAMIO_AA_FACTORY_V2_INITIAL_ACCOUNT_LIMIT,
    BEAMIO_AA_FACTORY_V2_ADMIN
  );
  const initCode = deployTx.data;
  if (!initCode) throw new Error("无法生成 BeamioFactoryInstitutionalV2 initCode");

  const initCodeHash = ethers.keccak256(initCode);
  const predicted = ethers.getAddress(
    "0x" +
      ethers
        .keccak256(
          ethers.solidityPacked(
            ["bytes1", "address", "bytes32", "bytes32"],
            ["0xff", nickFactory, BEAMIO_AA_FACTORY_V2_CREATE2_SALT, initCodeHash]
          )
        )
        .slice(-40)
  );

  const net = await ethers.provider.getNetwork();
  console.log("=".repeat(60));
  console.log("BeamioFactoryInstitutionalV2 CREATE2 deploy");
  console.log("=".repeat(60));
  console.log("chainId:", net.chainId.toString());
  console.log("deployer:", deployer.address);
  console.log("admin:", BEAMIO_AA_FACTORY_V2_ADMIN);
  console.log("accountLimit:", BEAMIO_AA_FACTORY_V2_INITIAL_ACCOUNT_LIMIT);
  console.log("Nick factory:", nickFactory);
  console.log("salt:", BEAMIO_AA_FACTORY_V2_CREATE2_SALT);
  console.log("initCodeHash:", initCodeHash);
  console.log("predicted:", predicted);

  const bal = await ethers.provider.getBalance(deployer.address);
  console.log("deployer balance:", ethers.formatEther(bal), "CNET");

  const existing = await ethers.provider.getCode(predicted);
  if (existing && existing !== "0x" && existing.length > 2) {
    console.log("Already deployed at predicted address — skip create2");
    const out = {
      chainId: Number(net.chainId),
      factory: predicted,
      salt: BEAMIO_AA_FACTORY_V2_CREATE2_SALT,
      initCodeHash,
      admin: BEAMIO_AA_FACTORY_V2_ADMIN,
      alreadyDeployed: true,
      deployedAt: new Date().toISOString(),
    };
    const outPath = path.join(__dirname, "../deployments/conet-BeamioFactoryInstitutionalV2.json");
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
    console.log("Wrote", outPath);
    return;
  }

  if (dryRun) {
    console.log("DRY_RUN=1 — not sending tx");
    return;
  }

  if (bal === 0n) {
    throw new Error("Deployer CNET balance is 0 — fund deployer before deploy");
  }

  const data = nickCreate2DeployCalldata(BEAMIO_AA_FACTORY_V2_CREATE2_SALT, initCode);
  const tx = await deployer.sendTransaction({ to: nickFactory, data });
  console.log("tx:", tx.hash);
  const receipt = await tx.wait();
  console.log("status:", receipt?.status, "block:", receipt?.blockNumber);

  const codeAfter = await ethers.provider.getCode(predicted);
  if (!codeAfter || codeAfter === "0x" || codeAfter.length <= 2) {
    throw new Error(`Deploy failed — no code at ${predicted}`);
  }

  const fac = factoryCf.attach(predicted) as Awaited<ReturnType<typeof factoryCf.attach>> & {
    factoryVersion: () => Promise<bigint>;
    admin: () => Promise<string>;
  };
  const ver = await fac.factoryVersion();
  const adm = await fac.admin();
  console.log("factoryVersion:", ver.toString(), "admin:", adm);

  const out = {
    chainId: Number(net.chainId),
    factory: predicted,
    salt: BEAMIO_AA_FACTORY_V2_CREATE2_SALT,
    initCodeHash,
    admin: BEAMIO_AA_FACTORY_V2_ADMIN,
    accountLimit: BEAMIO_AA_FACTORY_V2_INITIAL_ACCOUNT_LIMIT,
    deployTx: tx.hash,
    deployBlock: receipt?.blockNumber,
    factoryVersion: Number(ver),
    deployedAt: new Date().toISOString(),
  };
  const outPath = path.join(__dirname, "../deployments/conet-BeamioFactoryInstitutionalV2.json");
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
  console.log("Wrote", outPath);
  console.log("Next: verify on https://mainnet.conet.network (standard-json) for factory + sample AA if needed");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
