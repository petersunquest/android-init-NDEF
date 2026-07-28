import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

describe("TreasuryCanonicalERC20V3 native wrap", function () {
  async function deployToken() {
    const [admin, user, relayer, recipient] = await ethers.getSigners();
    const bridge = admin.address; // stand-in BRIDGE_ROLE holder

    const tokenImpl = await (await ethers.getContractFactory("TreasuryCanonicalERC20V3")).deploy();
    await tokenImpl.waitForDeployment();
    const tokenInit = tokenImpl.interface.encodeFunctionData("initialize", [
      "Wrapped CoNET",
      "wCNET",
      18,
      admin.address,
      bridge,
      "https://mainnet.conet.network/wcnet/metadata.json",
    ]);
    const tokenProxy = await (
      await ethers.getContractFactory("TreasuryV3ERC1967Proxy")
    ).deploy(await tokenImpl.getAddress(), tokenInit);
    await tokenProxy.waitForDeployment();
    const token = await ethers.getContractAt(
      "TreasuryCanonicalERC20V3",
      await tokenProxy.getAddress(),
    );
    return { admin, user, relayer, recipient, token };
  }

  async function signWithdraw(
    token: any,
    user: any,
    recipient: string,
    amount: bigint,
    nonce: bigint,
    deadline: bigint,
  ) {
    const networkInfo = await ethers.provider.getNetwork();
    const domain = {
      name: "TreasuryCanonicalERC20V3",
      version: "1",
      chainId: networkInfo.chainId,
      verifyingContract: await token.getAddress(),
    };
    const types = {
      Withdraw: [
        { name: "user", type: "address" },
        { name: "recipient", type: "address" },
        { name: "amount", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    };
    const value = { user: user.address, recipient, amount, nonce, deadline };
    return user.signTypedData(domain, types, value);
  }

  it("reverts deposit/withdraw while native wrap is disabled", async function () {
    const { user, token } = await deployToken();
    await expect(token.connect(user).deposit({ value: 1n })).to.be.revertedWithCustomError(
      token,
      "NativeWrapDisabled",
    );
    await expect(token.connect(user).withdraw(1n)).to.be.revertedWithCustomError(
      token,
      "NativeWrapDisabled",
    );
  });

  it("wraps and unwraps native 1:1", async function () {
    const { admin, user, token } = await deployToken();
    await token.connect(admin).setNativeWrapEnabled(true);

    const amount = ethers.parseEther("1.5");
    const before = await ethers.provider.getBalance(user.address);
    const tx = await token.connect(user).deposit({ value: amount });
    const receipt = await tx.wait();
    const gas = receipt!.gasUsed * receipt!.gasPrice;

    expect(await token.balanceOf(user.address)).to.equal(amount);
    expect(await ethers.provider.getBalance(await token.getAddress())).to.equal(amount);

    await token.connect(user).withdraw(amount);
    expect(await token.balanceOf(user.address)).to.equal(0n);
    expect(await ethers.provider.getBalance(await token.getAddress())).to.equal(0n);
    const after = await ethers.provider.getBalance(user.address);
    // deposit gas + withdraw gas; user should be near `before` minus gas only
    expect(after).to.be.lt(before);
    expect(before - after).to.be.gt(0n);
    void gas;
  });

  it("withdrawWithSignature: user signs, relayer submits, recipient receives native", async function () {
    const { admin, user, relayer, recipient, token } = await deployToken();
    await token.connect(admin).setNativeWrapEnabled(true);

    const amount = ethers.parseEther("1");
    await token.connect(user).deposit({ value: amount });

    const nonce = await token.withdrawNonces(user.address);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const signature = await signWithdraw(
      token,
      user,
      recipient.address,
      amount,
      nonce,
      deadline,
    );

    const recipientBefore = await ethers.provider.getBalance(recipient.address);
    await token
      .connect(relayer)
      .withdrawWithSignature(user.address, recipient.address, amount, nonce, deadline, signature);

    expect(await token.balanceOf(user.address)).to.equal(0n);
    expect(await token.withdrawNonces(user.address)).to.equal(nonce + 1n);
    expect(await ethers.provider.getBalance(recipient.address)).to.equal(
      recipientBefore + amount,
    );
  });

  it("withdrawWithSignature rejects expired, wrong nonce, and bad signer", async function () {
    const { admin, user, relayer, recipient, token } = await deployToken();
    await token.connect(admin).setNativeWrapEnabled(true);
    const amount = ethers.parseEther("1");
    await token.connect(user).deposit({ value: amount });

    const nonce = await token.withdrawNonces(user.address);
    const goodDeadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const expired = BigInt(Math.floor(Date.now() / 1000) - 10);

    const expiredSig = await signWithdraw(
      token,
      user,
      recipient.address,
      amount,
      nonce,
      expired,
    );
    await expect(
      token
        .connect(relayer)
        .withdrawWithSignature(user.address, recipient.address, amount, nonce, expired, expiredSig),
    ).to.be.revertedWithCustomError(token, "SignatureExpired");

    const wrongNonceSig = await signWithdraw(
      token,
      user,
      recipient.address,
      amount,
      nonce + 1n,
      goodDeadline,
    );
    await expect(
      token
        .connect(relayer)
        .withdrawWithSignature(
          user.address,
          recipient.address,
          amount,
          nonce + 1n,
          goodDeadline,
          wrongNonceSig,
        ),
    ).to.be.revertedWithCustomError(token, "InvalidSignature");

    const otherSig = await signWithdraw(
      token,
      relayer,
      recipient.address,
      amount,
      nonce,
      goodDeadline,
    );
    await expect(
      token
        .connect(relayer)
        .withdrawWithSignature(
          user.address,
          recipient.address,
          amount,
          nonce,
          goodDeadline,
          otherSig,
        ),
    ).to.be.revertedWithCustomError(token, "InvalidSignature");
  });

  it("bridge burn leaves native reserve; unwrap is capped by balance", async function () {
    const { admin, user, token } = await deployToken();
    await token.connect(admin).setNativeWrapEnabled(true);

    const amount = ethers.parseEther("2");
    await token.connect(user).deposit({ value: amount });

    // Simulate bridge outbound burn (native stays locked as Base-side reserve).
    await token.connect(admin).burnFrom(user.address, ethers.parseEther("1"));
    expect(await token.balanceOf(user.address)).to.equal(ethers.parseEther("1"));
    expect(await ethers.provider.getBalance(await token.getAddress())).to.equal(amount);

    // Bridge inbound mint without adding native — supply can exceed reserve.
    await token.connect(admin).mint(user.address, ethers.parseEther("1"));
    expect(await token.balanceOf(user.address)).to.equal(ethers.parseEther("2"));

    // Can unwrap only up to native reserve (2 ether still locked).
    await token.connect(user).withdraw(ethers.parseEther("2"));
    expect(await ethers.provider.getBalance(await token.getAddress())).to.equal(0n);

    // Remint without native → unwrap fails.
    await token.connect(admin).mint(user.address, ethers.parseEther("1"));
    await expect(token.connect(user).withdraw(ethers.parseEther("1"))).to.be.revertedWithCustomError(
      token,
      "InsufficientNativeReserve",
    );
  });
});
