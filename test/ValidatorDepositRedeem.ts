import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";

const CREATE_TYPES = {
  CreateRedeem: [
    { name: "admin", type: "address" },
    { name: "codeHash", type: "bytes32" },
    { name: "allowedClaimer", type: "address" },
    { name: "validatorCount", type: "uint256" },
    { name: "targetNodeIp", type: "string" },
    { name: "conetDepinNodeIpsHash", type: "bytes32" },
    { name: "gbMiningNodeCount", type: "uint256" },
    { name: "validAfter", type: "uint256" },
    { name: "validBefore", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
};

const CLAIM_TYPES = {
  ClaimRedeem: [
    { name: "claimer", type: "address" },
    { name: "codeHash", type: "bytes32" },
    { name: "beneficiary", type: "address" },
    { name: "validatorCount", type: "uint256" },
    { name: "targetNodeIp", type: "string" },
    { name: "conetDepinNodeIpsHash", type: "bytes32" },
    { name: "gbMiningNodeCount", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
};

describe("ValidatorDepositRedeem", async () => {
  const { ethers } = await network.connect();

  async function fixture() {
    const [admin, claimer, beneficiary, attacker] = await ethers.getSigners();
    const factory = await ethers.getContractFactory("ValidatorDepositRedeem");
    const contract = await factory.deploy(admin.address);
    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();
    const net = await ethers.provider.getNetwork();
    const domain = {
      name: "ValidatorDepositRedeem",
      version: "1",
      chainId: Number(net.chainId),
      verifyingContract: contractAddress,
    };
    const code = "redeem-code-1";
    const codeHash = ethers.keccak256(ethers.toUtf8Bytes(code));
    const depinIps = ["66.179.255.8", "70.35.205.77"];
    const depinHash = await contract.hashStringArray(depinIps);
    return { admin, claimer, beneficiary, attacker, contract, domain, code, codeHash, depinIps, depinHash };
  }

  it("creates and claims a validator redeem with expected event payload", async () => {
    const { admin, claimer, beneficiary, contract, domain, code, codeHash, depinIps, depinHash } = await fixture();
    const deadline = Math.floor(Date.now() / 1000) + 3600;
    const createMessage = {
      admin: admin.address,
      codeHash,
      allowedClaimer: claimer.address,
      validatorCount: 2n,
      targetNodeIp: "66.179.255.8",
      conetDepinNodeIpsHash: depinHash,
      gbMiningNodeCount: 2n,
      validAfter: 0n,
      validBefore: 0n,
      nonce: 0n,
      deadline: BigInt(deadline),
    };
    const createSig = await admin.signTypedData(domain, CREATE_TYPES, createMessage);
    await contract.createRedeemFor(
      admin.address,
      codeHash,
      claimer.address,
      2n,
      "66.179.255.8",
      depinIps,
      2n,
      0n,
      0n,
      0n,
      deadline,
      createSig
    );

    const claimMessage = {
      claimer: claimer.address,
      codeHash,
      beneficiary: beneficiary.address,
      validatorCount: 2n,
      targetNodeIp: "66.179.255.8",
      conetDepinNodeIpsHash: depinHash,
      gbMiningNodeCount: 2n,
      deadline: BigInt(deadline),
    };
    const claimSig = await claimer.signTypedData(domain, CLAIM_TYPES, claimMessage);
    const tx = await contract.claimRedeemFor(claimer.address, beneficiary.address, code, deadline, claimSig);
    const receipt = await tx.wait();
    const event = receipt?.logs
      .map((log) => {
        try {
          return contract.interface.parseLog(log);
        } catch {
          return null;
        }
      })
      .find((log) => log?.name === "ValidatorRedeemClaimed");

    assert.ok(event);
    assert.equal(event.args.claimer, claimer.address);
    assert.equal(event.args.beneficiary, beneficiary.address);
    assert.equal(event.args.validatorCount, 2n);
    assert.equal(event.args.targetNodeIp, "66.179.255.8");
    assert.deepEqual([...event.args.conetDepinNodeIps], depinIps);
    assert.equal(event.args.gbMiningNodeCount, 2n);

    const redeem = await contract.getRedeem(codeHash);
    assert.equal(redeem.active, false);
    assert.equal(redeem.consumed, true);
  });

  it("rejects DePIN IP count mismatch", async () => {
    const { admin, claimer, contract, domain, codeHash, depinHash } = await fixture();
    const deadline = Math.floor(Date.now() / 1000) + 3600;
    const sig = await admin.signTypedData(domain, CREATE_TYPES, {
      admin: admin.address,
      codeHash,
      allowedClaimer: claimer.address,
      validatorCount: 2n,
      targetNodeIp: "66.179.255.8",
      conetDepinNodeIpsHash: depinHash,
      gbMiningNodeCount: 2n,
      validAfter: 0n,
      validBefore: 0n,
      nonce: 0n,
      deadline: BigInt(deadline),
    });
    await assert.rejects(
      contract.createRedeemFor(admin.address, codeHash, claimer.address, 2n, "66.179.255.8", ["66.179.255.8"], 2n, 0n, 0n, 0n, deadline, sig),
      /depin count mismatch|revert/
    );
  });

  it("rejects unauthorized claimer and beneficiary replacement", async () => {
    const { admin, claimer, beneficiary, attacker, contract, domain, code, codeHash, depinIps, depinHash } = await fixture();
    const deadline = Math.floor(Date.now() / 1000) + 3600;
    const createSig = await admin.signTypedData(domain, CREATE_TYPES, {
      admin: admin.address,
      codeHash,
      allowedClaimer: claimer.address,
      validatorCount: 2n,
      targetNodeIp: "66.179.255.8",
      conetDepinNodeIpsHash: depinHash,
      gbMiningNodeCount: 2n,
      validAfter: 0n,
      validBefore: 0n,
      nonce: 0n,
      deadline: BigInt(deadline),
    });
    await contract.createRedeemFor(admin.address, codeHash, claimer.address, 2n, "66.179.255.8", depinIps, 2n, 0n, 0n, 0n, deadline, createSig);

    const claimSig = await claimer.signTypedData(domain, CLAIM_TYPES, {
      claimer: claimer.address,
      codeHash,
      beneficiary: beneficiary.address,
      validatorCount: 2n,
      targetNodeIp: "66.179.255.8",
      conetDepinNodeIpsHash: depinHash,
      gbMiningNodeCount: 2n,
      deadline: BigInt(deadline),
    });
    await assert.rejects(
      contract.claimRedeemFor(attacker.address, beneficiary.address, code, deadline, claimSig),
      /claimer not allowed|revert/
    );
    await assert.rejects(
      contract.claimRedeemFor(claimer.address, attacker.address, code, deadline, claimSig),
      /bad sig|revert/
    );
  });
});
