/**
 * 在 Base 上为 BaseScan 验证部署样例 BeamioAccount（admin EOA index=0）。
 * 运行: npx hardhat run scripts/deploySampleBeamioAccountForVerify.ts --network base
 */
import { network as networkModule } from "hardhat";
import { BEAMIO_AA_FACTORY_PREDICTED, BEAMIO_AA_PREDICT_SAMPLE_EOA } from "./aaDeployConstants.js";

async function main() {
  const { ethers } = await networkModule.connect();
  const [signer] = await ethers.getSigners();
  if (!signer) throw new Error("无签名账户");

  const factory = await ethers.getContractAt(
    "BeamioFactoryPaymasterV07",
    BEAMIO_AA_FACTORY_PREDICTED,
    signer
  );

  console.log("Factory:", BEAMIO_AA_FACTORY_PREDICTED);
  console.log("Signer:", signer.address);
  console.log("Predicted AA (index=0):", "0xDE72163F1f75C90c4CeDeE11b9E5a17eFc128CB7");

  const before = await factory.beamioAccountOf(signer.address);
  if (before !== ethers.ZeroAddress) {
    console.log("已有 AA:", before);
    return;
  }

  const tx = await factory.createAccount();
  console.log("createAccount tx:", tx.hash);
  await tx.wait();

  const aa = await factory.beamioAccountOf(signer.address);
  console.log("✅ BeamioAccount:", aa);
  if (aa.toLowerCase() !== "0xde72163f1f75c90c4cedee11b9e5a17efc128cb7") {
    console.warn("地址与预测样例不一致，请更新 verify bundle 中 BeamioAccount address");
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
