// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "../contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

interface IBeamioBUnitsV2 {
 function consumeFuel(address user, uint256 amount) external returns (uint256 paidBurned);
 function mintReward(address to, uint256 amount) external;
 function mintPaid(address to, uint256 amount) external;
 function balanceOf(address account) external view returns (uint256);
 function balanceOfAll(address account) external view returns (uint256 total, uint256 free, uint256 paid);
}

interface IConetTreasuryV2 {
 function mintForAdmin(address token, address to, uint256 amount) external;
}

interface IReferralSettlementV2 {
 function onPaidBUnitConsumed(
 address payer,
 uint256 paidBurned,
 uint256 usdcAmount,
 bytes32 sourceHash,
 uint256 kind
 ) external;
}

interface IReferralPurchaseSplitV1 {
 function allocatePurchase(address beneficiary, uint256 usdcAmount, bytes32 sourceHash) external;
 function purchaseAllocated(bytes32 sourceHash) external view returns (bool);
 function takeEscrowedPaid(address user, uint256 paidBurned) external returns (uint256 taken);
 function releaseDeferred(address user, uint256 paidBurned, bytes32 sourceHash) external;
}

interface IBeamioAccountOwnerV2 {
 function owner() external view returns (address);
}

interface ILegacyBUnitAirdropV2 {
 function hasClaimed(address account) external view returns (bool);
}

/**
 * @title Beamio BUnitAirdrop V2
 * @notice Atomic paid-pool consumption, CONET-USDC backing, and claimable payout vault.
 *
 * The contract deliberately has no unrestricted USDC withdrawal. CONET-USDC minted
 * here is either reserved for L0/L1 claims or retained by this contract.
 */
contract BUnitAirdropV2 is Initializable, OwnableUpgradeable, UUPSUpgradeable {
 uint256 public constant BUNIT_TO_USDC = 100;

 address public bunit;
 address public conetTreasury;
 address public conetUsdc;
 address public referralSettlement;

 mapping(address => bool) public admins;
 uint256 public reservedClaimableUsdc;
 uint256 public totalPaidBunitAirdropped;
 uint256 public totalPaidBunitConsumed;
 uint256 public totalConetUsdcMinted;

 // Appended after the original V2 storage. Never insert fields above this line.
 address public legacyBunitAirdrop;
 mapping(address => bool) public hasClaimed;
 mapping(address => uint256) public claimNonces;
 uint256 public claimAmount;
 bool public storageRepairApplied;
 // Appended after V2 storage. Never insert fields above this line.
 address public purchaseSplit;

 error Unauthorized();
 error InvalidAddress();
 error InvalidAmount();
 error InsufficientReservedBalance();
 error TransferFailed();

 event AdminUpdated(address indexed account, bool enabled);
 event ConfigUpdated(address indexed bunit, address indexed treasury, address conetUsdc, address referralSettlement);
 event LegacyAirdropUpdated(address indexed oldAirdrop, address indexed newAirdrop);
 event FreeClaimed(address indexed account, uint256 amount, address indexed relayer);
 event PaidBUnitAirdropped(address indexed recipient, uint256 amount, bytes32 indexed redeemHash);
 event FreeBUnitAirdropped(address indexed recipient, uint256 amount, bytes32 indexed redeemHash);
 event PaidBUnitConsumed(address indexed payer, uint256 paidBurned, uint256 usdcAmount, bytes32 indexed sourceHash, uint256 kind);
 event ClaimableReserved(uint256 amount, uint256 reservedAfter);
 event ClaimablePaid(address indexed recipient, uint256 amount, uint256 reservedAfter);
 event PurchaseSplitUpdated(address indexed purchaseSplit);

 modifier onlyAdmin() {
 if (!admins[msg.sender]) revert Unauthorized();
 _;
 }

 modifier onlyReferralSettlement() {
 if (msg.sender != referralSettlement) revert Unauthorized();
 _;
 }

 constructor() {
 _disableInitializers();
 }

 function initialize(
 address owner_,
 address bunit_,
 address treasury_,
 address conetUsdc_,
 address referralSettlement_
 ) external initializer {
 if (
 owner_ == address(0) ||
 bunit_ == address(0) ||
 treasury_ == address(0) ||
 conetUsdc_ == address(0) ||
 referralSettlement_ == address(0)
 ) revert InvalidAddress();
 __Ownable_init(owner_);
 __UUPSUpgradeable_init();
 bunit = bunit_;
 conetTreasury = treasury_;
 conetUsdc = conetUsdc_;
 referralSettlement = referralSettlement_;
 claimAmount = 20e6;
 admins[owner_] = true;
 emit AdminUpdated(owner_, true);
 emit ConfigUpdated(bunit_, treasury_, conetUsdc_, referralSettlement_);
 }

 function _authorizeUpgrade(address) internal view override onlyOwner {}

 function setConfig(
 address bunit_,
 address treasury_,
 address conetUsdc_,
 address referralSettlement_
 ) external onlyOwner {
 if (
 bunit_ == address(0) ||
 treasury_ == address(0) ||
 conetUsdc_ == address(0) ||
 referralSettlement_ == address(0)
 ) revert InvalidAddress();
 bunit = bunit_;
 conetTreasury = treasury_;
 conetUsdc = conetUsdc_;
 referralSettlement = referralSettlement_;
 emit ConfigUpdated(bunit_, treasury_, conetUsdc_, referralSettlement_);
 }

 function setPurchaseSplit(address purchaseSplit_) external onlyOwner {
 purchaseSplit = purchaseSplit_;
 emit PurchaseSplitUpdated(purchaseSplit_);
 }

 function setLegacyBunitAirdrop(address legacy) external onlyOwner {
 address old = legacyBunitAirdrop;
 legacyBunitAirdrop = legacy;
 emit LegacyAirdropUpdated(old, legacy);
 }

 function setClaimAmount(uint256 amount) external onlyOwner {
 if (amount == 0) revert InvalidAmount();
 claimAmount = amount;
 }

 /**
 * @dev One-time correction for the pre-release storage-layout migration.
 * It is intentionally owner-only and cannot be called again.
 */
 function repairLegacyStorageCounters(
 uint256 paidBunitAirdropped_,
 uint256 paidBunitConsumed_,
 uint256 conetUsdcMinted_
 ) external onlyOwner {
 if (storageRepairApplied) revert Unauthorized();
 totalPaidBunitAirdropped = paidBunitAirdropped_;
 totalPaidBunitConsumed = paidBunitConsumed_;
 totalConetUsdcMinted = conetUsdcMinted_;
 storageRepairApplied = true;
 }

 function addAdmin(address account) external onlyOwner {
 if (account == address(0)) revert InvalidAddress();
 admins[account] = true;
 emit AdminUpdated(account, true);
 }

 function removeAdmin(address account) external onlyOwner {
 if (account == address(0)) revert InvalidAddress();
 admins[account] = false;
 emit AdminUpdated(account, false);
 }

 function setAdmin(address account, bool enabled) external onlyOwner {
 if (account == address(0)) revert InvalidAddress();
 admins[account] = enabled;
 emit AdminUpdated(account, enabled);
 }

 function getBUnitBalance(address account) external view returns (uint256) {
 return IBeamioBUnitsV2(bunit).balanceOf(account);
 }

 function _legacyClaimed(address account) internal view returns (bool) {
 if (hasClaimed[account]) return true;
 if (legacyBunitAirdrop == address(0)) return false;
 try ILegacyBUnitAirdropV2(legacyBunitAirdrop).hasClaimed(account) returns (bool claimed) {
 return claimed;
 } catch {
 return false;
 }
 }

 /// @notice True if this EOA already received free B-Units (new-EOA claim or Referral free redeem).
 function alreadyClaimedFree(address account) external view returns (bool) {
 return _legacyClaimed(account);
 }

 function _claimFree(address claimant, address beneficiary, address relayer) internal {
 if (claimant == address(0) || _legacyClaimed(claimant)) revert InvalidAmount();
 if (beneficiary != claimant) {
 if (beneficiary.code.length == 0 || IBeamioAccountOwnerV2(beneficiary).owner() != claimant) {
 revert Unauthorized();
 }
 }
 hasClaimed[claimant] = true;
 IBeamioBUnitsV2(bunit).mintReward(beneficiary, claimAmount);
 emit FreeClaimed(beneficiary, claimAmount, relayer);
 }

 function claim() external {
 _claimFree(msg.sender, msg.sender, msg.sender);
 }

 function claimFor(
 address claimant,
 uint256 nonce,
 uint256 deadline,
 bytes calldata signature
 ) external {
 _verifyClaimSignature(claimant, nonce, deadline, signature);
 claimNonces[claimant] = nonce + 1;
 _claimFree(claimant, claimant, msg.sender);
 }

 function claimForWithBeneficiary(
 address claimant,
 address beneficiary,
 uint256 nonce,
 uint256 deadline,
 bytes calldata signature
 ) external {
 _verifyClaimSignature(claimant, nonce, deadline, signature);
 claimNonces[claimant] = nonce + 1;
 _claimFree(claimant, beneficiary, msg.sender);
 }

 function claimForV2(
 address claimant,
 uint256 nonce,
 uint256 deadline,
 address merchantCard,
 uint256 targetTokenId,
 address referrer,
 bytes calldata signature
 ) external {
 _verifyClaimV2Signature(
 claimant,
 nonce,
 deadline,
 merchantCard,
 targetTokenId,
 referrer,
 signature
 );
 claimNonces[claimant] = nonce + 1;
 _claimFree(claimant, claimant, msg.sender);
 }

 function _verifyClaimSignature(
 address claimant,
 uint256 nonce,
 uint256 deadline,
 bytes calldata signature
 ) internal view {
 if (block.timestamp > deadline || claimNonces[claimant] != nonce) revert Unauthorized();
 bytes32 domain = keccak256(
 abi.encode(
 keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
 keccak256(bytes("BUnitAirdrop")),
 keccak256(bytes("1")),
 block.chainid,
 address(this)
 )
 );
 bytes32 structHash = keccak256(
 abi.encode(
 keccak256("ClaimAirdrop(address claimant,uint256 nonce,uint256 deadline)"),
 claimant,
 nonce,
 deadline
 )
 );
 bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
 if (ECDSA.recover(digest, signature) != claimant) revert Unauthorized();
 }

 function _verifyClaimV2Signature(
 address claimant,
 uint256 nonce,
 uint256 deadline,
 address merchantCard,
 uint256 targetTokenId,
 address referrer,
 bytes calldata signature
 ) internal view {
 if (block.timestamp > deadline || claimNonces[claimant] != nonce) revert Unauthorized();
 bytes32 domain = keccak256(
 abi.encode(
 keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
 keccak256(bytes("BUnitAirdrop")),
 keccak256(bytes("1")),
 block.chainid,
 address(this)
 )
 );
 bytes32 structHash = keccak256(
 abi.encode(
 keccak256(
 "ClaimAirdropV2(address claimant,uint256 nonce,uint256 deadline,address merchantCard,uint256 targetTokenId,address referrer)"
 ),
 claimant,
 nonce,
 deadline,
 merchantCard,
 targetTokenId,
 referrer
 )
 );
 bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
 if (ECDSA.recover(digest, signature) != claimant) revert Unauthorized();
 }

 function mintForUsdcPurchase(address to, uint256 usdcAmount, bytes32 baseTxHash) external onlyAdmin {
 if (to == address(0) || usdcAmount == 0) revert InvalidAmount();
 if (purchaseSplit != address(0) && !IReferralPurchaseSplitV1(purchaseSplit).purchaseAllocated(baseTxHash)) {
 IConetTreasuryV2(conetTreasury).mintForAdmin(conetUsdc, purchaseSplit, usdcAmount);
 totalConetUsdcMinted += usdcAmount;
 IReferralPurchaseSplitV1(purchaseSplit).allocatePurchase(to, usdcAmount, baseTxHash);
 }
 IBeamioBUnitsV2(bunit).mintPaid(to, usdcAmount * 100);
 emit PaidBUnitAirdropped(to, usdcAmount * 100, baseTxHash);
 }

 function balanceOfAll(address account) external view returns (uint256 total, uint256 free, uint256 paid) {
 return IBeamioBUnitsV2(bunit).balanceOfAll(account);
 }

 /**
 * @notice Credit a credit-card/cash purchase into the paidPool.
 * Only the Referral settlement contract may call this route.
 */
 function mintPaidForCreditCashPurchase(
 address recipient,
 uint256 amount,
 bytes32 redeemHash
 ) external onlyReferralSettlement {
 if (recipient == address(0) || amount == 0) revert InvalidAmount();
 IBeamioBUnitsV2(bunit).mintPaid(recipient, amount);
 totalPaidBunitAirdropped += amount;
 emit PaidBUnitAirdropped(recipient, amount, redeemHash);
 }

 /**
 * @notice Credit a free-pool B-Unit grant for Referral Admin merchant package codes.
 * Only the Referral settlement contract may call this route.
 * Shares the same one-time free grant with claim()/claimFor* (new-EOA free
 * airdrop): each EOA may receive free B-Units at most once across both paths.
 */
 function mintFreeForReferralSettlement(
 address recipient,
 uint256 amount,
 bytes32 redeemHash
 ) external onlyReferralSettlement {
 if (recipient == address(0) || amount == 0) revert InvalidAmount();
 // Same gate as _claimFree: redeem free grant and new-EOA free claim are mutually exclusive.
 if (_legacyClaimed(recipient)) revert InvalidAmount();
 hasClaimed[recipient] = true;
 IBeamioBUnitsV2(bunit).mintReward(recipient, amount);
 emit FreeBUnitAirdropped(recipient, amount, redeemHash);
 }

 /**
 * @notice Consume B-Units and atomically mint the CONET-USDC backing into this vault.
 * paidBurned is the only amount eligible for referral settlement.
 */
 function consumeFromUser(
 address user,
 uint256 amount,
 bytes32 sourceHash,
 uint256 baseGas,
 uint256 kind
 ) external onlyAdmin {
 baseGas;
 if (user == address(0) || amount == 0) revert InvalidAmount();
 uint256 paidBurned = IBeamioBUnitsV2(bunit).consumeFuel(user, amount);
 totalPaidBunitConsumed += paidBurned;

 uint256 escrowed;
 if (purchaseSplit != address(0) && paidBurned > 0) {
 escrowed = IReferralPurchaseSplitV1(purchaseSplit).takeEscrowedPaid(user, paidBurned);
 }
 uint256 unbacked = paidBurned - escrowed;
 uint256 unbackedUsdc = unbacked / BUNIT_TO_USDC;

 if (unbackedUsdc > 0) {
 IConetTreasuryV2(conetTreasury).mintForAdmin(conetUsdc, address(this), unbackedUsdc);
 totalConetUsdcMinted += unbackedUsdc;
 IReferralSettlementV2(referralSettlement).onPaidBUnitConsumed(
 user,
 unbacked,
 unbackedUsdc,
 sourceHash,
 kind
 );
 }
 if (escrowed > 0) {
 IReferralPurchaseSplitV1(purchaseSplit).releaseDeferred(user, escrowed, sourceHash);
 }
 emit PaidBUnitConsumed(user, paidBurned, paidBurned / BUNIT_TO_USDC, sourceHash, kind);
 }

 function reserveClaimable(uint256 amount) external onlyReferralSettlement {
 if (amount == 0) revert InvalidAmount();
 reservedClaimableUsdc += amount;
 emit ClaimableReserved(amount, reservedClaimableUsdc);
 }

 function payoutClaimable(address recipient, uint256 amount) external onlyReferralSettlement {
 if (recipient == address(0) || amount == 0) revert InvalidAmount();
 if (amount > reservedClaimableUsdc) revert InsufficientReservedBalance();
 reservedClaimableUsdc -= amount;
 if (!IERC20(conetUsdc).transfer(recipient, amount)) revert TransferFailed();
 emit ClaimablePaid(recipient, amount, reservedClaimableUsdc);
 }

 function retainedConetUsdc() external view returns (uint256) {
 uint256 balance = IERC20(conetUsdc).balanceOf(address(this));
 return balance > reservedClaimableUsdc ? balance - reservedClaimableUsdc : 0;
 }
}
