// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

interface IBusinessStartKetReferral {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function mint(address to, uint256 id, uint256 amount, bytes calldata data) external;
    function adminBurn(address from, uint256 id, uint256 amount) external;
}

interface IBUnitAirdropReferral {
    function mintPaidForCreditCashPurchase(address recipient, uint256 amount, bytes32 redeemHash) external;
    function reserveClaimable(uint256 amount) external;
    function payoutClaimable(address recipient, uint256 amount) external;
}

interface IUserCardFactoryReferral {
    function createCardCollectionWithInitCode(
        address cardOwner,
        uint8 currency,
        uint256 priceInCurrencyE6,
        bytes calldata initCode
    ) external returns (address card);
    function isBeamioUserCard(address card) external view returns (bool);
}

interface IUserCardReferralView {
    function owner() external view returns (address);
    function factoryGateway() external view returns (address);
}

/**
 * @title ReferralRegistryVaultV1
 * @notice Global Admin -> L0 -> L1/Merchant registry and claimable CONET-USDC vault.
 *
 * Merchant onboarding is deliberately two-step:
 * claimMerchantCode() grants BusinessStartKet #0 and paid B-Units;
 * createMerchantCard() accepts the full card init payload, burns the starter
 * certificate, creates the card through the UserCard factory, and only then
 * registers Merchant under the issuing L0 with parentAdmin = assigned L1.
 */
contract ReferralRegistryVaultV1 is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using ECDSA for bytes32;

    uint256 public constant BPS = 10_000;
    uint256 public constant BUSINESS_START_KET_ID = 0;
    uint256 public constant DEFAULT_MERCHANT_REDEEM_BUNIT_AIRDROP = 2_000 * 1e6;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant EIP712_NAME_HASH = keccak256("ReferralRegistryVaultV1");
    bytes32 private constant EIP712_VERSION_HASH = keccak256("1");
    bytes32 private constant ISSUE_L0_REDEEM_TYPEHASH =
        keccak256("IssueL0RedeemCode(address admin,bytes32 redeemHash,uint256 rebateBps,uint256 nonce,uint256 deadline)");
    bytes32 private constant ISSUE_L1_REDEEM_TYPEHASH =
        keccak256("IssueL1RedeemCode(address l0,bytes32 redeemHash,uint256 rebateBps,uint256 nonce,uint256 deadline)");
    bytes32 private constant CANCEL_L0_REDEEM_TYPEHASH =
        keccak256("CancelL0RedeemCode(address admin,bytes32 redeemHash,uint256 nonce,uint256 deadline)");
    bytes32 private constant CANCEL_L1_REDEEM_TYPEHASH =
        keccak256("CancelL1RedeemCode(address l0,bytes32 redeemHash,uint256 nonce,uint256 deadline)");
    bytes32 private constant CLAIM_L0_REDEEM_TYPEHASH =
        keccak256("ClaimL0RedeemCode(address claimer,bytes32 redeemHash,uint256 nonce,uint256 deadline)");
    bytes32 private constant CLAIM_L1_REDEEM_TYPEHASH =
        keccak256("ClaimL1RedeemCode(address claimer,bytes32 redeemHash,uint256 nonce,uint256 deadline)");
    bytes32 private constant SET_L0_RATE_TYPEHASH =
        keccak256("SetL0Rate(address admin,address l0,uint256 rebateBps,uint256 nonce,uint256 deadline)");
    bytes32 private constant SET_L0_QUOTA_TYPEHASH =
        keccak256(
            "SetL0Quota(address admin,address l0,uint256 starterKetRemaining,uint256 paidBunitRemaining,uint256 nonce,uint256 deadline)"
        );
    bytes32 private constant SET_L0_STARTER_KET_QUOTA_TYPEHASH =
        keccak256("SetL0StarterKetQuota(address admin,address l0,uint256 starterKetRemaining,uint256 nonce,uint256 deadline)");
    bytes32 private constant ASSIGN_MERCHANT_TYPEHASH =
        keccak256(
            "AssignMerchantToL0(address admin,address l0,address merchant,address card,uint256 nonce,uint256 deadline)"
        );
    bytes32 private constant ISSUE_MERCHANT_REDEEM_TYPEHASH =
        keccak256("IssueMerchantRedeemCode(address l0,address l1,bytes32 redeemHash,uint256 nonce,uint256 deadline)");
    bytes32 private constant CANCEL_MERCHANT_REDEEM_TYPEHASH =
        keccak256("CancelMerchantRedeemCode(address l0,bytes32 redeemHash,uint256 nonce,uint256 deadline)");
    bytes32 private constant SET_MERCHANT_REDEEM_BUNIT_AIRDROP_TYPEHASH =
        keccak256("SetMerchantRedeemBunitAirdrop(address admin,uint256 amount,uint256 nonce,uint256 deadline)");

    enum Role {
        None,
        L0,
        L1,
        Merchant
    }

    struct Member {
        Role role;
        address parentAdmin;
        address parentL0;
        uint256 rebateBps;
        uint256 ratioBps;
        bool active;
    }

    struct MerchantQuota {
        uint256 starterKetRemaining;
        uint256 paidBunitRemaining;
        uint256 issuedCodeCount;
        uint256 claimedCodeCount;
    }

    struct MerchantCode {
        address issuerL0;
        uint256 paidBunitAmount;
        uint64 validAfter;
        uint64 validBefore;
        bool active;
        bool claimed;
    }

    struct PaidBunitCode {
        uint256 amount;
        uint64 validAfter;
        uint64 validBefore;
        bool active;
        bool claimed;
    }

    // Appended after the original V1 storage. Never insert fields above this line.
    struct L0RedeemCode {
        address issuerAdmin;
        uint256 rebateBps;
        uint64 validAfter;
        uint64 validBefore;
        bool active;
        bool claimed;
        bool cancelled;
    }

    struct L1RedeemCode {
        address issuerL0;
        uint256 rebateBps;
        uint256 ratioBps;
        uint64 validAfter;
        uint64 validBefore;
        bool active;
        bool claimed;
        bool cancelled;
    }

    address public businessStartKet;
    address public bunitAirdrop;
    address public userCardFactory;
    address public conetUsdc;

    mapping(address => bool) public admins;
    mapping(address => Member) public members;
    mapping(address => MerchantQuota) public merchantQuotas;
    mapping(bytes32 => MerchantCode) public merchantCodes;
    mapping(bytes32 => PaidBunitCode) public paidBunitCodes;
    mapping(address => address) public claimedMerchantL0;
    mapping(address => bytes32) public claimedMerchantCode;

    mapping(address => uint256) public claimableConetUsdc;
    mapping(address => uint256) public claimedConetUsdc;
    mapping(address => uint256) public claimNonces;
    mapping(address => bool) public l0ClaimPaused;
    mapping(address => mapping(address => bool)) public l1ClaimPaused;

    // New redeem registries are appended for UUPS storage safety.
    mapping(bytes32 => L0RedeemCode) public l0RedeemCodes;
    mapping(bytes32 => L1RedeemCode) public l1RedeemCodes;
    bytes32[] private l0RedeemCodeHashes;
    bytes32[] private l1RedeemCodeHashes;
    bytes32[] private merchantCodeHashes;
    mapping(bytes32 => bool) public merchantCodeCancelled;
    uint256 public merchantRedeemBunitAirdrop;
    mapping(address => uint256) public redeemActionNonces;
    mapping(address => uint256) public referralClaimNonces;

    // Start Kit codes must bind an L1 under the issuing L0 (appended for UUPS safety).
    mapping(bytes32 => address) public merchantCodeAssignedL1;
    mapping(address => address) public claimedMerchantL1;

    error Unauthorized();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidRole();
    error InvalidCode();
    error CodeUnavailable();
    error CodeExpired();
    error QuotaExceeded();
    error AlreadyRegistered();
    error NotRegistered();
    error SignatureExpired();
    error InvalidSignature();
    error NonceUsed();
    error ClaimPaused();
    error InvalidCard();
    error DistributionMismatch();
    error InvalidL1Rebate();

    event AdminUpdated(address indexed account, bool enabled);
    event ConfigUpdated(address indexed businessStartKet, address indexed bunitAirdrop, address userCardFactory, address conetUsdc);
    event L0QuotaUpdated(address indexed l0, uint256 starterKetRemaining, uint256 paidBunitRemaining);
    event MerchantCodeIssued(bytes32 indexed redeemHash, address indexed l0, address indexed l1, uint256 paidBunitAmount);
    event MerchantCodeClaimed(bytes32 indexed redeemHash, address indexed merchant, address indexed l0, uint256 paidBunitAmount);
    event MerchantCodeCancelled(bytes32 indexed redeemHash, address indexed l0);
    event MerchantRedeemBunitAirdropUpdated(uint256 amount);
    event MerchantCardCreated(address indexed merchant, address indexed l0, address indexed card, bytes32 metadataHash);
    event PaidBunitCodeIssued(bytes32 indexed redeemHash, uint256 amount);
    event PaidBunitCodeClaimed(bytes32 indexed redeemHash, address indexed recipient, uint256 amount);
    event L0RedeemCodeIssued(bytes32 indexed redeemHash, address indexed admin, uint256 rebateBps, uint64 validBefore);
    event L0RedeemCodeClaimed(bytes32 indexed redeemHash, address indexed l0, address indexed admin, uint256 rebateBps);
    event L0RedeemCodeCancelled(bytes32 indexed redeemHash, address indexed admin);
    event L1RedeemCodeIssued(
        bytes32 indexed redeemHash,
        address indexed l0,
        uint256 rebateBps,
        uint256 ratioBps,
        uint64 validBefore
    );
    event L1RedeemCodeClaimed(
        bytes32 indexed redeemHash,
        address indexed l1,
        address indexed l0,
        uint256 rebateBps,
        uint256 ratioBps
    );
    event L1RedeemCodeCancelled(bytes32 indexed redeemHash, address indexed l0);
    event MemberRegistered(address indexed account, Role role, address indexed parentL0, address indexed parentAdmin);
    event L0RateUpdated(address indexed l0, uint256 rebateBps);
    event MerchantAssignedToL0(address indexed merchant, address indexed l0, address indexed card, address admin);
    event L1RatioUpdated(address indexed l0, address indexed l1, uint256 ratioBps);
    event ClaimableAccrued(bytes32 indexed settlementId, address indexed account, uint256 amount);
    event ConetUsdcClaimed(address indexed account, uint256 amount, uint256 nonce);
    event L0ClaimPauseUpdated(address indexed l0, bool paused);
    event L1ClaimPauseUpdated(address indexed l0, address indexed l1, bool paused);

    modifier onlyAdmin() {
        if (!admins[msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlyL0() {
        if (members[msg.sender].role != Role.L0 || !members[msg.sender].active) revert Unauthorized();
        _;
    }

    modifier onlyBunitAirdrop() {
        if (msg.sender != bunitAirdrop) revert Unauthorized();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address businessStartKet_,
        address bunitAirdrop_,
        address userCardFactory_,
        address conetUsdc_
    ) external initializer {
        if (
            owner_ == address(0) ||
            businessStartKet_ == address(0) ||
            bunitAirdrop_ == address(0) ||
            userCardFactory_ == address(0) ||
            conetUsdc_ == address(0)
        ) revert InvalidAddress();
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        merchantRedeemBunitAirdrop = DEFAULT_MERCHANT_REDEEM_BUNIT_AIRDROP;
        businessStartKet = businessStartKet_;
        bunitAirdrop = bunitAirdrop_;
        userCardFactory = userCardFactory_;
        conetUsdc = conetUsdc_;
        admins[owner_] = true;
        emit AdminUpdated(owner_, true);
        emit ConfigUpdated(businessStartKet_, bunitAirdrop_, userCardFactory_, conetUsdc_);
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}

    function setConfig(
        address businessStartKet_,
        address bunitAirdrop_,
        address userCardFactory_,
        address conetUsdc_
    ) external onlyOwner {
        if (
            businessStartKet_ == address(0) ||
            bunitAirdrop_ == address(0) ||
            userCardFactory_ == address(0) ||
            conetUsdc_ == address(0)
        ) revert InvalidAddress();
        businessStartKet = businessStartKet_;
        bunitAirdrop = bunitAirdrop_;
        userCardFactory = userCardFactory_;
        conetUsdc = conetUsdc_;
        emit ConfigUpdated(businessStartKet_, bunitAirdrop_, userCardFactory_, conetUsdc_);
    }

    function setAdmin(address account, bool enabled) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        admins[account] = enabled;
        emit AdminUpdated(account, enabled);
    }

    function setL0Quota(
        address l0,
        uint256 starterKetRemaining,
        uint256 paidBunitRemaining
    ) external onlyAdmin {
        _setL0Quota(l0, starterKetRemaining, paidBunitRemaining);
    }

    function _setL0Quota(
        address l0,
        uint256 starterKetRemaining,
        uint256 paidBunitRemaining
    ) internal {
        if (members[l0].role != Role.L0 || !members[l0].active) revert NotRegistered();
        merchantQuotas[l0].starterKetRemaining = starterKetRemaining;
        merchantQuotas[l0].paidBunitRemaining = paidBunitRemaining;
        emit L0QuotaUpdated(l0, starterKetRemaining, paidBunitRemaining);
    }

    function setL0QuotaFor(
        address admin,
        address l0,
        uint256 starterKetRemaining,
        uint256 paidBunitRemaining,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyRedeemAction(
            admin,
            keccak256(
                abi.encode(
                    SET_L0_QUOTA_TYPEHASH,
                    admin,
                    l0,
                    starterKetRemaining,
                    paidBunitRemaining,
                    nonce,
                    deadline
                )
            ),
            nonce,
            deadline,
            signature
        );
        if (!admins[admin]) revert Unauthorized();
        _setL0Quota(l0, starterKetRemaining, paidBunitRemaining);
    }

    function setL0StarterKetQuota(address l0, uint256 starterKetRemaining) external onlyAdmin {
        _setL0StarterKetQuota(l0, starterKetRemaining);
    }

    function _setL0StarterKetQuota(address l0, uint256 starterKetRemaining) internal {
        if (members[l0].role != Role.L0 || !members[l0].active) revert NotRegistered();
        merchantQuotas[l0].starterKetRemaining = starterKetRemaining;
        emit L0QuotaUpdated(l0, starterKetRemaining, merchantQuotas[l0].paidBunitRemaining);
    }

    function setMerchantRedeemBunitAirdrop(uint256 amount) external onlyAdmin {
        if (amount == 0) revert InvalidAmount();
        merchantRedeemBunitAirdrop = amount;
        emit MerchantRedeemBunitAirdropUpdated(amount);
    }

    function setMerchantRedeemBunitAirdropFor(
        address admin,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyRedeemAction(
            admin,
            keccak256(abi.encode(SET_MERCHANT_REDEEM_BUNIT_AIRDROP_TYPEHASH, admin, amount, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        if (!admins[admin]) revert Unauthorized();
        if (amount == 0) revert InvalidAmount();
        merchantRedeemBunitAirdrop = amount;
        emit MerchantRedeemBunitAirdropUpdated(amount);
    }

    function setL0StarterKetQuotaFor(
        address admin,
        address l0,
        uint256 starterKetRemaining,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyRedeemAction(
            admin,
            keccak256(abi.encode(SET_L0_STARTER_KET_QUOTA_TYPEHASH, admin, l0, starterKetRemaining, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        if (!admins[admin]) revert Unauthorized();
        _setL0StarterKetQuota(l0, starterKetRemaining);
    }

    function addL0(address l0, address parentAdmin, uint256 rebateBps) external onlyAdmin {
        if (l0 == address(0) || parentAdmin == address(0) || rebateBps > BPS) revert InvalidAmount();
        if (members[l0].role != Role.None && members[l0].active) revert AlreadyRegistered();
        members[l0] = Member(Role.L0, parentAdmin, address(0), rebateBps, 0, true);
        emit MemberRegistered(l0, Role.L0, address(0), parentAdmin);
        emit L0RateUpdated(l0, rebateBps);
    }

    function issueMerchantRedeemCode(
        bytes32 redeemHash,
        address l1,
        uint64 validAfter,
        uint64 validBefore
    ) external onlyL0 {
        _issueMerchantRedeemCode(msg.sender, l1, redeemHash, validAfter, validBefore);
    }

    function _issueMerchantRedeemCode(
        address l0,
        address l1,
        bytes32 redeemHash,
        uint64 validAfter,
        uint64 validBefore
    ) internal {
        uint256 paidBunitAmount = merchantRedeemBunitAirdrop;
        if (redeemHash == bytes32(0) || paidBunitAmount == 0) revert InvalidAmount();
        if (
            l1 == address(0) ||
            members[l1].role != Role.L1 ||
            !members[l1].active ||
            members[l1].parentL0 != l0
        ) revert InvalidAddress();
        MerchantQuota storage q = merchantQuotas[l0];
        if (q.starterKetRemaining < 1) revert QuotaExceeded();
        q.starterKetRemaining -= 1;
        q.issuedCodeCount += 1;
        merchantCodes[redeemHash] = MerchantCode(l0, paidBunitAmount, validAfter, validBefore, true, false);
        merchantCodeAssignedL1[redeemHash] = l1;
        merchantCodeHashes.push(redeemHash);
        emit MerchantCodeIssued(redeemHash, l0, l1, paidBunitAmount);
    }

    function issueMerchantRedeemCodeFor(
        address l0,
        address l1,
        bytes32 redeemHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyRedeemAction(
            l0,
            keccak256(abi.encode(ISSUE_MERCHANT_REDEEM_TYPEHASH, l0, l1, redeemHash, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        _issueMerchantRedeemCode(l0, l1, redeemHash, 0, 0);
    }

    function merchantCodeCount() external view returns (uint256) {
        return merchantCodeHashes.length;
    }

    function merchantCodeHashAt(uint256 index) external view returns (bytes32) {
        return merchantCodeHashes[index];
    }

    function merchantCodesStatus(bytes32 redeemHash) external view returns (uint8) {
        MerchantCode memory c = merchantCodes[redeemHash];
        if (c.active) return 1;
        if (c.claimed) return 2;
        if (merchantCodeCancelled[redeemHash]) return 3;
        return 0;
    }

    function cancelMerchantRedeemCode(bytes32 redeemHash) external onlyL0 {
        _cancelMerchantRedeemCode(msg.sender, redeemHash);
    }

    function cancelMerchantRedeemCodeFor(
        address l0,
        bytes32 redeemHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyRedeemAction(
            l0,
            keccak256(abi.encode(CANCEL_MERCHANT_REDEEM_TYPEHASH, l0, redeemHash, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        _cancelMerchantRedeemCode(l0, redeemHash);
    }

    function _cancelMerchantRedeemCode(address l0, bytes32 redeemHash) internal {
        MerchantCode storage c = merchantCodes[redeemHash];
        if (c.issuerL0 != l0 || !c.active || c.claimed) revert CodeUnavailable();
        c.active = false;
        merchantCodeCancelled[redeemHash] = true;
        emit MerchantCodeCancelled(redeemHash, l0);
    }

    function issuePaidBunitRedeemCode(
        bytes32 redeemHash,
        uint256 amount,
        uint64 validAfter,
        uint64 validBefore
    ) external onlyAdmin {
        if (redeemHash == bytes32(0) || amount == 0) revert InvalidAmount();
        paidBunitCodes[redeemHash] = PaidBunitCode(amount, validAfter, validBefore, true, false);
        emit PaidBunitCodeIssued(redeemHash, amount);
    }

    /**
     * @notice Issue an Admin -> L0 registration code.
     *         The redeem code itself has no expiry; only the relayed signature expires.
     */
    function issueL0RedeemCode(bytes32 redeemHash, uint256 rebateBps) external onlyAdmin {
        _issueL0RedeemCode(msg.sender, redeemHash, rebateBps);
    }

    function _issueL0RedeemCode(address admin, bytes32 redeemHash, uint256 rebateBps) internal {
        if (redeemHash == bytes32(0) || rebateBps > BPS) revert InvalidAmount();
        L0RedeemCode storage existing = l0RedeemCodes[redeemHash];
        if (existing.active || existing.claimed || existing.cancelled) revert CodeUnavailable();
        l0RedeemCodes[redeemHash] = L0RedeemCode(
            admin,
            rebateBps,
            0,
            0,
            true,
            false,
            false
        );
        l0RedeemCodeHashes.push(redeemHash);
        emit L0RedeemCodeIssued(redeemHash, admin, rebateBps, 0);
    }

    /**
     * @notice Issue an L0 -> L1 registration code.
     *         The UI supplies the desired L1 rebate; ratioBps is derived on-chain.
     */
    function issueL1RedeemCode(bytes32 redeemHash, uint256 l1RebateBps) external onlyL0 {
        _issueL1RedeemCode(msg.sender, redeemHash, l1RebateBps);
    }

    function _issueL1RedeemCode(address l0, bytes32 redeemHash, uint256 l1RebateBps) internal {
        if (redeemHash == bytes32(0) || l1RebateBps > BPS) revert InvalidAmount();
        Member storage l0Member = members[l0];
        if (l0Member.role != Role.L0 || !l0Member.active) revert Unauthorized();
        uint256 l0RebateBps = members[l0].rebateBps;
        if (l1RebateBps > l0RebateBps) revert InvalidL1Rebate();
        uint256 ratioBps = l0RebateBps == 0 ? 0 : (l1RebateBps * BPS) / l0RebateBps;
        L1RedeemCode storage existing = l1RedeemCodes[redeemHash];
        if (existing.active || existing.claimed || existing.cancelled) revert CodeUnavailable();
        l1RedeemCodes[redeemHash] = L1RedeemCode(
            l0,
            l1RebateBps,
            ratioBps,
            0,
            0,
            true,
            false,
            false
        );
        l1RedeemCodeHashes.push(redeemHash);
        emit L1RedeemCodeIssued(redeemHash, l0, l1RebateBps, ratioBps, 0);
    }

    function cancelL0RedeemCode(bytes32 redeemHash) external {
        _cancelL0RedeemCode(msg.sender, redeemHash);
    }

    function _cancelL0RedeemCode(address admin, bytes32 redeemHash) internal {
        L0RedeemCode storage c = l0RedeemCodes[redeemHash];
        if (!c.active || c.claimed || c.cancelled || c.issuerAdmin != admin) revert Unauthorized();
        c.active = false;
        c.cancelled = true;
        emit L0RedeemCodeCancelled(redeemHash, admin);
    }

    function cancelL1RedeemCode(bytes32 redeemHash) external {
        _cancelL1RedeemCode(msg.sender, redeemHash);
    }

    function _cancelL1RedeemCode(address l0, bytes32 redeemHash) internal {
        L1RedeemCode storage c = l1RedeemCodes[redeemHash];
        if (!c.active || c.claimed || c.cancelled || c.issuerL0 != l0) revert Unauthorized();
        c.active = false;
        c.cancelled = true;
        emit L1RedeemCodeCancelled(redeemHash, l0);
    }

    function issueL0RedeemCodeFor(
        address admin,
        bytes32 redeemHash,
        uint256 rebateBps,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyRedeemAction(
            admin,
            keccak256(abi.encode(ISSUE_L0_REDEEM_TYPEHASH, admin, redeemHash, rebateBps, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        if (!admins[admin]) revert Unauthorized();
        _issueL0RedeemCode(admin, redeemHash, rebateBps);
    }

    function issueL1RedeemCodeFor(
        address l0,
        bytes32 redeemHash,
        uint256 l1RebateBps,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyRedeemAction(
            l0,
            keccak256(abi.encode(ISSUE_L1_REDEEM_TYPEHASH, l0, redeemHash, l1RebateBps, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        _issueL1RedeemCode(l0, redeemHash, l1RebateBps);
    }

    function cancelL0RedeemCodeFor(
        address admin,
        bytes32 redeemHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyRedeemAction(
            admin,
            keccak256(abi.encode(CANCEL_L0_REDEEM_TYPEHASH, admin, redeemHash, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        _cancelL0RedeemCode(admin, redeemHash);
    }

    function cancelL1RedeemCodeFor(
        address l0,
        bytes32 redeemHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyRedeemAction(
            l0,
            keccak256(abi.encode(CANCEL_L1_REDEEM_TYPEHASH, l0, redeemHash, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        _cancelL1RedeemCode(l0, redeemHash);
    }

    function referralDomainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, EIP712_NAME_HASH, EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function _verifyRedeemAction(
        address signer,
        bytes32 structHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (redeemActionNonces[signer] != nonce) revert NonceUsed();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", referralDomainSeparator(), structHash));
        if (ECDSA.recover(digest, signature) != signer) revert InvalidSignature();
        redeemActionNonces[signer] = nonce + 1;
    }

    function _verifyReferralClaim(
        address claimer,
        bytes32 structHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (referralClaimNonces[claimer] != nonce) revert NonceUsed();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", referralDomainSeparator(), structHash));
        if (ECDSA.recover(digest, signature) != claimer) revert InvalidSignature();
        referralClaimNonces[claimer] = nonce + 1;
    }

    function l0RedeemCodeCount() external view returns (uint256) {
        return l0RedeemCodeHashes.length;
    }

    function l1RedeemCodeCount() external view returns (uint256) {
        return l1RedeemCodeHashes.length;
    }

    function l0RedeemCodeHashAt(uint256 index) external view returns (bytes32) {
        return l0RedeemCodeHashes[index];
    }

    function l1RedeemCodeHashAt(uint256 index) external view returns (bytes32) {
        return l1RedeemCodeHashes[index];
    }

    // 0 = unknown, 1 = pending, 2 = claimed, 3 = cancelled.
    function l0RedeemCodeStatus(bytes32 redeemHash) external view returns (uint8) {
        L0RedeemCode memory c = l0RedeemCodes[redeemHash];
        if (c.active) return 1;
        if (c.claimed) return 2;
        if (c.cancelled) return 3;
        return 0;
    }

    function l1RedeemCodeStatus(bytes32 redeemHash) external view returns (uint8) {
        L1RedeemCode memory c = l1RedeemCodes[redeemHash];
        if (c.active) return 1;
        if (c.claimed) return 2;
        if (c.cancelled) return 3;
        return 0;
    }

    function _checkWindow(uint64 validAfter, uint64 validBefore) internal view {
        if (validAfter != 0 && block.timestamp < validAfter) revert CodeUnavailable();
        if (validBefore != 0 && block.timestamp > validBefore) revert CodeExpired();
    }

    function claimMerchantCode(bytes calldata secret) external {
        bytes32 redeemHash = keccak256(bytes(secret));
        MerchantCode storage c = merchantCodes[redeemHash];
        if (!c.active || c.claimed) revert CodeUnavailable();
        if (merchantCodeCancelled[redeemHash]) revert CodeUnavailable();
        address l1 = merchantCodeAssignedL1[redeemHash];
        if (l1 == address(0)) revert InvalidAddress();
        _checkWindow(c.validAfter, c.validBefore);
        if (members[msg.sender].role != Role.None || claimedMerchantL0[msg.sender] != address(0)) {
            revert AlreadyRegistered();
        }
        c.claimed = true;
        c.active = false;
        merchantQuotas[c.issuerL0].claimedCodeCount += 1;
        claimedMerchantL0[msg.sender] = c.issuerL0;
        claimedMerchantL1[msg.sender] = l1;
        claimedMerchantCode[msg.sender] = redeemHash;
        IBusinessStartKetReferral(businessStartKet).mint(msg.sender, BUSINESS_START_KET_ID, 1, "");
        IBUnitAirdropReferral(bunitAirdrop).mintPaidForCreditCashPurchase(msg.sender, c.paidBunitAmount, redeemHash);
        emit MerchantCodeClaimed(redeemHash, msg.sender, c.issuerL0, c.paidBunitAmount);
    }

    function claimL0RedeemCode(bytes calldata secret) external {
        _claimL0RedeemCode(msg.sender, secret);
    }

    function claimL0RedeemCodeFor(
        address claimer,
        bytes calldata secret,
        bytes32 redeemHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyReferralClaim(
            claimer,
            keccak256(abi.encode(CLAIM_L0_REDEEM_TYPEHASH, claimer, redeemHash, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        if (keccak256(bytes(secret)) != redeemHash) revert InvalidCode();
        _claimL0RedeemCode(claimer, secret);
    }

    function _claimL0RedeemCode(address claimer, bytes calldata secret) internal {
        bytes32 redeemHash = keccak256(bytes(secret));
        L0RedeemCode storage c = l0RedeemCodes[redeemHash];
        if (!c.active || c.claimed || c.cancelled) revert CodeUnavailable();
        _checkWindow(c.validAfter, c.validBefore);
        if (admins[claimer] || members[claimer].role != Role.None) revert AlreadyRegistered();
        c.claimed = true;
        c.active = false;
        members[claimer] = Member(Role.L0, c.issuerAdmin, address(0), c.rebateBps, 0, true);
        emit MemberRegistered(claimer, Role.L0, address(0), c.issuerAdmin);
        emit L0RedeemCodeClaimed(redeemHash, claimer, c.issuerAdmin, c.rebateBps);
    }

    function claimL1RedeemCode(bytes calldata secret) external {
        _claimL1RedeemCode(msg.sender, secret);
    }

    function claimL1RedeemCodeFor(
        address claimer,
        bytes calldata secret,
        bytes32 redeemHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyReferralClaim(
            claimer,
            keccak256(abi.encode(CLAIM_L1_REDEEM_TYPEHASH, claimer, redeemHash, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        if (keccak256(bytes(secret)) != redeemHash) revert InvalidCode();
        _claimL1RedeemCode(claimer, secret);
    }

    function _claimL1RedeemCode(address claimer, bytes calldata secret) internal {
        bytes32 redeemHash = keccak256(bytes(secret));
        L1RedeemCode storage c = l1RedeemCodes[redeemHash];
        if (!c.active || c.claimed || c.cancelled) revert CodeUnavailable();
        _checkWindow(c.validAfter, c.validBefore);
        if (admins[claimer] || members[claimer].role != Role.None) revert AlreadyRegistered();
        c.claimed = true;
        c.active = false;
        members[claimer] = Member(Role.L1, address(0), c.issuerL0, c.rebateBps, c.ratioBps, true);
        emit MemberRegistered(claimer, Role.L1, c.issuerL0, address(0));
        emit L1RedeemCodeClaimed(redeemHash, claimer, c.issuerL0, c.rebateBps, c.ratioBps);
    }

    function claimPaidBunitRedeem(bytes calldata secret) external {
        bytes32 redeemHash = keccak256(bytes(secret));
        PaidBunitCode storage c = paidBunitCodes[redeemHash];
        if (!c.active || c.claimed) revert CodeUnavailable();
        _checkWindow(c.validAfter, c.validBefore);
        c.claimed = true;
        c.active = false;
        IBUnitAirdropReferral(bunitAirdrop).mintPaidForCreditCashPurchase(msg.sender, c.amount, redeemHash);
        emit PaidBunitCodeClaimed(redeemHash, msg.sender, c.amount);
    }

    /**
     * @notice Creates the card after the separate claim transaction.
     *         Full metadata is represented by metadataHash; the initCode carries
     *         the actual card constructor data.
     */
    function createMerchantCard(
        uint8 currency,
        uint256 priceInCurrencyE6,
        bytes calldata initCode,
        bytes32 metadataHash
    ) external returns (address card) {
        address l0 = claimedMerchantL0[msg.sender];
        address l1 = claimedMerchantL1[msg.sender];
        if (l0 == address(0) || l1 == address(0)) revert NotRegistered();
        if (
            members[l1].role != Role.L1 ||
            !members[l1].active ||
            members[l1].parentL0 != l0
        ) revert InvalidAddress();
        if (IBusinessStartKetReferral(businessStartKet).balanceOf(msg.sender, BUSINESS_START_KET_ID) < 1) {
            revert InvalidAmount();
        }
        IBusinessStartKetReferral(businessStartKet).adminBurn(msg.sender, BUSINESS_START_KET_ID, 1);
        card = IUserCardFactoryReferral(userCardFactory).createCardCollectionWithInitCode(
            msg.sender,
            currency,
            priceInCurrencyE6,
            initCode
        );
        if (
            !IUserCardFactoryReferral(userCardFactory).isBeamioUserCard(card) ||
            IUserCardReferralView(card).owner() != msg.sender ||
            IUserCardReferralView(card).factoryGateway() != userCardFactory
        ) revert InvalidCard();
        // parentAdmin stores the assigned L1 for Merchant rows (was always address(0)).
        members[msg.sender] = Member(Role.Merchant, l1, l0, 0, 0, true);
        delete claimedMerchantL0[msg.sender];
        delete claimedMerchantL1[msg.sender];
        delete claimedMerchantCode[msg.sender];
        emit MemberRegistered(msg.sender, Role.Merchant, l0, l1);
        emit MerchantCardCreated(msg.sender, l0, card, metadataHash);
    }

    function setL0RebateRate(address l0, uint256 rebateBps) external onlyAdmin {
        _setL0RebateRate(l0, rebateBps);
    }

    function _setL0RebateRate(address l0, uint256 rebateBps) internal {
        if (members[l0].role != Role.L0 || !members[l0].active || rebateBps > BPS) revert InvalidAmount();
        members[l0].rebateBps = rebateBps;
        emit L0RateUpdated(l0, rebateBps);
    }

    function setL0RebateRateFor(
        address admin,
        address l0,
        uint256 rebateBps,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyRedeemAction(
            admin,
            keccak256(abi.encode(SET_L0_RATE_TYPEHASH, admin, l0, rebateBps, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        if (!admins[admin]) revert Unauthorized();
        _setL0RebateRate(l0, rebateBps);
    }

    function assignMerchantToL0(address l0, address merchant, address card) external onlyAdmin {
        _assignMerchantToL0(msg.sender, l0, merchant, card);
    }

    function assignMerchantToL0For(
        address admin,
        address l0,
        address merchant,
        address card,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyRedeemAction(
            admin,
            keccak256(abi.encode(ASSIGN_MERCHANT_TYPEHASH, admin, l0, merchant, card, nonce, deadline)),
            nonce,
            deadline,
            signature
        );
        if (!admins[admin]) revert Unauthorized();
        _assignMerchantToL0(admin, l0, merchant, card);
    }

    function _assignMerchantToL0(address admin, address l0, address merchant, address card) internal {
        if (
            l0 == address(0) ||
            merchant == address(0) ||
            card == address(0) ||
            members[l0].role != Role.L0 ||
            !members[l0].active
        ) revert InvalidAddress();
        if (members[merchant].role != Role.None || claimedMerchantL0[merchant] != address(0)) {
            revert AlreadyRegistered();
        }
        if (
            !IUserCardFactoryReferral(userCardFactory).isBeamioUserCard(card) ||
            IUserCardReferralView(card).owner() != merchant
        ) revert InvalidCard();

        members[merchant] = Member(Role.Merchant, address(0), l0, 0, 0, true);
        emit MemberRegistered(merchant, Role.Merchant, l0, address(0));
        emit MerchantAssignedToL0(merchant, l0, card, admin);
    }

    function setL1Ratio(address l1, uint256 ratioBps) external {
        address l0 = members[msg.sender].role == Role.L0 ? msg.sender : address(0);
        if (l0 == address(0) || members[l1].role != Role.L1 || members[l1].parentL0 != l0 || ratioBps > BPS) {
            revert Unauthorized();
        }
        members[l1].ratioBps = ratioBps;
        emit L1RatioUpdated(l0, l1, ratioBps);
    }

    function setL0ClaimPaused(address l0, bool paused) external onlyAdmin {
        if (members[l0].role != Role.L0 || !members[l0].active) revert NotRegistered();
        l0ClaimPaused[l0] = paused;
        emit L0ClaimPauseUpdated(l0, paused);
    }

    function setL1ClaimPaused(address l1, bool paused) external onlyL0 {
        if (members[l1].role != Role.L1 || members[l1].parentL0 != msg.sender) revert Unauthorized();
        l1ClaimPaused[msg.sender][l1] = paused;
        emit L1ClaimPauseUpdated(msg.sender, l1, paused);
    }

    function onPaidBUnitConsumed(
        address payer,
        uint256 paidBurned,
        uint256 usdcAmount,
        bytes32 sourceHash,
        uint256 kind
    ) external onlyBunitAirdrop {
        if (paidBurned / 100 != usdcAmount) revert DistributionMismatch();
        Member memory payerMember = members[payer];
        uint256 l0Reward;
        uint256 l1Reward;
        address l0;
        address l1;

        if (payerMember.role == Role.Merchant) {
            l0 = payerMember.parentL0;
            l1 = payerMember.parentAdmin;
            if (
                l1 != address(0) &&
                (members[l1].role != Role.L1 || !members[l1].active || members[l1].parentL0 != l0)
            ) {
                l1 = address(0);
            }
        } else if (payerMember.role == Role.L1) {
            l0 = payerMember.parentL0;
            l1 = payer;
        }
        if (l0 == address(0)) return;

        uint256 totalRebate = (usdcAmount * members[l0].rebateBps) / BPS;
        if (l1 != address(0)) {
            l1Reward = (totalRebate * members[l1].ratioBps) / BPS;
        }
        l0Reward = totalRebate - l1Reward;
        uint256 retained = usdcAmount - l0Reward - l1Reward;
        if (l0Reward + l1Reward + retained != usdcAmount) revert DistributionMismatch();

        if (l0Reward > 0) {
            claimableConetUsdc[l0] += l0Reward;
            emit ClaimableAccrued(sourceHash, l0, l0Reward);
        }
        if (l1Reward > 0) {
            claimableConetUsdc[l1] += l1Reward;
            emit ClaimableAccrued(sourceHash, l1, l1Reward);
        }
        if (l0Reward + l1Reward > 0) {
            IBUnitAirdropReferral(bunitAirdrop).reserveClaimable(l0Reward + l1Reward);
        }
        kind;
    }

    function claimableUsdc(address account) external view returns (uint256) {
        return claimableConetUsdc[account];
    }

    function claimConetUsdc(
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (claimNonces[msg.sender] != nonce) revert NonceUsed();
        if (amount == 0 || amount > claimableConetUsdc[msg.sender]) revert InvalidAmount();
        Member memory m = members[msg.sender];
        if (m.role == Role.L0 && l0ClaimPaused[msg.sender]) revert ClaimPaused();
        if (m.role == Role.L1 && l1ClaimPaused[m.parentL0][msg.sender]) revert ClaimPaused();
        bytes32 digest = keccak256(
            abi.encode(
                keccak256("ClaimConetUsdc(address account,uint256 amount,uint256 nonce,uint256 deadline)"),
                msg.sender,
                amount,
                nonce,
                deadline
            )
        );
        bytes32 ethDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        if (ethDigest.recover(signature) != msg.sender) revert InvalidSignature();
        claimNonces[msg.sender] = nonce + 1;
        claimableConetUsdc[msg.sender] -= amount;
        claimedConetUsdc[msg.sender] += amount;
        IBUnitAirdropReferral(bunitAirdrop).payoutClaimable(msg.sender, amount);
        emit ConetUsdcClaimed(msg.sender, amount, nonce);
    }
}
