// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "../contracts/access/Ownable.sol";
import {EIP712} from "../contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";
import {CoNETIncomePeriodLib} from "./CoNETIncomePeriodLib.sol";

/**
 * @title GBDepinAirdrop
 * @dev GBToken ERC20 settlement for ValidatorDepositRedeem DePIN node beneficiaries.
 *
 * On-chain ledger (single RPC view — no off-chain event scan):
 *   - beneficiaryPaidGbTotal / guardianNodePaidGbTotal — mintPaid credited to redeem beneficiary
 *   - paidGbSummaryOf / paidGbSummaryOfGuardianNode — cumulative + hour/day/week/month/year (UTC, Indexer-aligned)
 *   - beneficiaryUserFeeGbBurned / guardianNodeUserFeeGbBurned — user GB consumed via chargeUserGbForGuardianNode
 *   - beneficiaryUserFeePaidMinted — paidBurned portion minted to beneficiary on user charge
 *   - beneficiaryProtocolPaidGbMinted — protocol time-accrual via airdropDepinPaidAll
 *
 * User fee path (DEPRECATED — migrate to DepinGbSettlement1155.batchSettle):
 *   chargeUserGbForGuardianNode(nodeId, user, amount) → consumeGb(user) + ledger + mintPaid(beneficiary, paidBurned)
 *   New DePIN bandwidth charges must use DepinGbSettlement1155 (CNET settler bond + ERC-1155 passes).
 *
 * Protocol subsidy path (retained):
 *   airdropDepinPaidAll() — perSecond × elapsed since lastDepinPaidCallAt, mint to each node's beneficiary.
 *
 * Mint recipient = ValidatorDepositRedeem redeem **beneficiary**, never DePIN node operator wallet.
 */
interface IGBTokenDepinSettler {
    function consumeGb(address user, uint256 amount) external returns (uint256 freeBurned, uint256 paidBurned);

    function mintReward(address to, uint256 amount) external;

    function mintPaid(address to, uint256 amount) external;
}

struct GuardianNodeInfo {
    uint256 id;
    string PGP;
    string PGPKey;
    string ip_addr;
    string regionName;
}

interface IGuardianNodesInfoV6 {
    function getAllNodes(uint256 start, uint256 length) external view returns (GuardianNodeInfo[] memory allNodes);
}

interface IValidatorDepositRedeemDepin {
    function guardianIdBeneficiary(uint256 nodeId) external view returns (address);

    function nodeWalletBeneficiary(address wallet) external view returns (address);

    function resolveNodeBundle(
        address maybeWallet,
        string calldata conetDepinNodeIp
    )
        external
        view
        returns (
            address beneficiary,
            uint256[] memory guardianNodeIds,
            string[] memory depinNodeIps,
            address[] memory nodeWallets,
            bytes[] memory validatorPubkeys,
            bool[] memory validatorActive,
            uint256 validatorNodeCount,
            uint256 gbMiningNodeCount,
            uint256 claimCount,
            uint256 nativeBalance,
            uint256 gbBalance,
            uint256 usdcBalance
        );
}

contract GBDepinAirdrop is Ownable, EIP712 {
    /// @dev 30 × 24 × 60 × 60
    uint256 public constant SECONDS_PER_MONTH = 30 days;

    /// @dev 1 GB = 1e9 (GBToken decimals)
    uint256 public constant GB_UNIT = 1_000_000_000;

    IGBTokenDepinSettler public immutable gbToken;
    IValidatorDepositRedeemDepin public validatorDepositRedeem;
    IGuardianNodesInfoV6 public guardianNodes;

    /// @dev GB per DePIN node per 30-day month (9-decimal raw). Default 3000 GB.
    uint256 public monthlyPaidGbPerNode;

    /// @dev Global timestamp of last successful protocol paid admin call.
    uint256 public lastDepinPaidCallAt;

    /// @dev First protocol call on which node was eligible — mid-period joiners get no backfill before this.
    mapping(uint256 => uint256) public nodeFirstEligibleAt;

    /// @dev Cumulative mintPaid to redeem beneficiary via this contract (user fees + protocol).
    mapping(address => uint256) public beneficiaryPaidGbTotal;
    mapping(uint256 => uint256) public guardianNodePaidGbTotal;

    /// @dev User bandwidth charges (GBToken consumeGb total burned, free + paid).
    mapping(address => uint256) public beneficiaryUserFeeGbBurned;
    mapping(uint256 => uint256) public guardianNodeUserFeeGbBurned;

    /// @dev mintPaid to beneficiary from user paidBurned portion only.
    mapping(address => uint256) public beneficiaryUserFeePaidMinted;
    mapping(uint256 => uint256) public guardianNodeUserFeePaidMinted;

    /// @dev mintPaid from protocol time-accrual (airdropDepinPaidAll).
    mapping(address => uint256) public beneficiaryProtocolPaidGbMinted;
    mapping(uint256 => uint256) public guardianNodeProtocolPaidGbMinted;

    /// @dev Free claim config. Default 10 GB every 24 hours.
    uint256 public freeClaimAmount;
    uint256 public freeClaimInterval;
    mapping(address => uint256) public lastFreeClaimAt;
    mapping(address => uint256) public freeClaimNonces;

    mapping(address => bool) public admins;
    /// @dev DePIN / API gateway may charge user GB without full admin rights.
    mapping(address => bool) public gbSettlers;

    /// @dev Paid-GB period buckets (9-decimal raw), aligned with ValidatorNodeRewardIndexer UTC boundaries.
    mapping(address => mapping(uint256 => uint256)) public beneficiaryPaidGbHourly;
    mapping(address => mapping(uint8 => mapping(uint256 => uint256))) public beneficiaryPaidGbPeriod;
    mapping(uint256 => mapping(uint256 => uint256)) public guardianNodePaidGbHourly;
    mapping(uint256 => mapping(uint8 => mapping(uint256 => uint256))) public guardianNodePaidGbPeriod;

    bytes32 private constant CLAIM_FREE_GB_TYPEHASH =
        keccak256("ClaimFreeGb(address claimant,uint256 nonce,uint256 deadline)");

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);
    event GbSettlerAdded(address indexed account);
    event GbSettlerRemoved(address indexed account);
    event ValidatorDepositRedeemUpdated(address indexed oldAddr, address indexed newAddr);
    event GuardianNodesUpdated(address indexed oldAddr, address indexed newAddr);
    event MonthlyPaidGbPerNodeUpdated(uint256 oldAmount, uint256 newAmount);
    event FreeClaimAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event FreeClaimIntervalUpdated(uint256 oldInterval, uint256 newInterval);
    event DepinPaidAirdrop(
        uint256 indexed guardianNodeId,
        address indexed beneficiary,
        uint256 amount,
        uint256 elapsedSeconds,
        bool fromUserFee
    );
    event DepinPaidNodeRegistered(uint256 indexed guardianNodeId, address indexed beneficiary, uint256 registeredAt);
    event DepinPaidAll(
        uint256 nodesMinted,
        uint256 nodesRegistered,
        uint256 totalGbMinted,
        uint256 elapsedSeconds
    );
    event DepinPaidPage(
        uint256 start,
        uint256 length,
        uint256 nodesMinted,
        uint256 nodesRegistered,
        uint256 totalGbMinted,
        bool advancedGlobalClock
    );
    event UserGbFeeCharged(
        uint256 indexed guardianNodeId,
        address indexed user,
        address indexed beneficiary,
        uint256 amount,
        uint256 freeBurned,
        uint256 paidBurned
    );
    event FreeGbClaimed(address indexed claimant, uint256 amount);
    event FreeGbClaimedFor(address indexed claimant, uint256 amount, address indexed relayer);

    modifier onlyAdmin() {
        if (msg.sender != owner() && !admins[msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlyGbOperator() {
        if (msg.sender != owner() && !admins[msg.sender] && !gbSettlers[msg.sender]) revert Unauthorized();
        _;
    }

    error Unauthorized();
    error InvalidConfig();
    error InvalidSignature();
    error SignatureExpired();
    error NotEligible();
    error ClaimTooSoon();
    error TransferFailed();
    error NothingToAirdrop();
    error ConsumeFailed();

    constructor(address gbToken_, address initialOwner) Ownable(initialOwner) EIP712("GBDepinAirdrop", "1") {
        if (gbToken_ == address(0)) revert InvalidConfig();
        gbToken = IGBTokenDepinSettler(gbToken_);
        monthlyPaidGbPerNode = 3000 * GB_UNIT;
        lastDepinPaidCallAt = block.timestamp;
        freeClaimAmount = 10 * GB_UNIT;
        freeClaimInterval = 1 days;
    }

    // ---------------------------------------------------------------------
    // Admin config
    // ---------------------------------------------------------------------

    function setValidatorDepositRedeem(address addr) external onlyOwner {
        address old = address(validatorDepositRedeem);
        validatorDepositRedeem = IValidatorDepositRedeemDepin(addr);
        emit ValidatorDepositRedeemUpdated(old, addr);
    }

    function setGuardianNodes(address addr) external onlyOwner {
        address old = address(guardianNodes);
        guardianNodes = IGuardianNodesInfoV6(addr);
        emit GuardianNodesUpdated(old, addr);
    }

    function setMonthlyPaidGbPerNode(uint256 amount) external onlyAdmin {
        if (amount == 0) revert InvalidConfig();
        uint256 old = monthlyPaidGbPerNode;
        monthlyPaidGbPerNode = amount;
        emit MonthlyPaidGbPerNodeUpdated(old, amount);
    }

    function setFreeClaimAmount(uint256 amount) external onlyAdmin {
        if (amount == 0) revert InvalidConfig();
        uint256 old = freeClaimAmount;
        freeClaimAmount = amount;
        emit FreeClaimAmountUpdated(old, amount);
    }

    function setFreeClaimInterval(uint256 intervalSeconds) external onlyAdmin {
        if (intervalSeconds == 0) revert InvalidConfig();
        uint256 old = freeClaimInterval;
        freeClaimInterval = intervalSeconds;
        emit FreeClaimIntervalUpdated(old, intervalSeconds);
    }

    function addAdmin(address account) external onlyOwner {
        if (account == address(0)) revert Unauthorized();
        admins[account] = true;
        emit AdminAdded(account);
    }

    function removeAdmin(address account) external onlyOwner {
        admins[account] = false;
        emit AdminRemoved(account);
    }

    function addGbSettler(address account) external onlyOwner {
        if (account == address(0)) revert Unauthorized();
        gbSettlers[account] = true;
        emit GbSettlerAdded(account);
    }

    function removeGbSettler(address account) external onlyOwner {
        gbSettlers[account] = false;
        emit GbSettlerRemoved(account);
    }

    function _requirePaidConfigured() internal view {
        if (address(guardianNodes) == address(0) || address(validatorDepositRedeem) == address(0)) {
            revert InvalidConfig();
        }
    }

    // ---------------------------------------------------------------------
    // On-chain ledger views
    // ---------------------------------------------------------------------

    function paidGbReceivedOf(address beneficiary) external view returns (uint256) {
        return beneficiaryPaidGbTotal[beneficiary];
    }

    function paidGbReceivedOfGuardianNode(uint256 guardianNodeId) external view returns (uint256) {
        return guardianNodePaidGbTotal[guardianNodeId];
    }

    /// @notice Paid-GB income summary for a redeem beneficiary (cumulative + current UTC period buckets).
    function paidGbSummaryOf(address beneficiary, uint256 anchorTs)
        external
        view
        returns (CoNETIncomePeriodLib.IncomePeriodSummary memory)
    {
        return CoNETIncomePeriodLib.readSummary(
            beneficiaryPaidGbHourly[beneficiary],
            beneficiaryPaidGbPeriod[beneficiary],
            beneficiaryPaidGbTotal[beneficiary],
            anchorTs
        );
    }

    /// @notice Paid-GB income summary for a guardian node id.
    function paidGbSummaryOfGuardianNode(uint256 guardianNodeId, uint256 anchorTs)
        external
        view
        returns (CoNETIncomePeriodLib.IncomePeriodSummary memory)
    {
        return CoNETIncomePeriodLib.readSummary(
            guardianNodePaidGbHourly[guardianNodeId],
            guardianNodePaidGbPeriod[guardianNodeId],
            guardianNodePaidGbTotal[guardianNodeId],
            anchorTs
        );
    }

    function userFeeGbBurnedOf(address beneficiary) external view returns (uint256) {
        return beneficiaryUserFeeGbBurned[beneficiary];
    }

    function userFeeGbBurnedOfGuardianNode(uint256 guardianNodeId) external view returns (uint256) {
        return guardianNodeUserFeeGbBurned[guardianNodeId];
    }

    // ---------------------------------------------------------------------
    // Paid rate helpers (protocol time accrual)
    // ---------------------------------------------------------------------

    function paidGbPerSecond() public view returns (uint256) {
        return monthlyPaidGbPerNode / SECONDS_PER_MONTH;
    }

    function computePaidGbForElapsed(uint256 elapsedSeconds) public view returns (uint256) {
        if (elapsedSeconds == 0) return 0;
        return (monthlyPaidGbPerNode * elapsedSeconds) / SECONDS_PER_MONTH;
    }

    function previewStandardPaidOwed(uint256 timestamp)
        external
        view
        returns (uint256 owed, uint256 elapsedSeconds, uint256 perSecond)
    {
        if (timestamp <= lastDepinPaidCallAt) return (0, 0, paidGbPerSecond());
        elapsedSeconds = timestamp - lastDepinPaidCallAt;
        owed = computePaidGbForElapsed(elapsedSeconds);
        perSecond = paidGbPerSecond();
    }

    function paidRecipientOfGuardianNode(uint256 guardianNodeId) public view returns (address) {
        return _resolveNodePaidRecipient(guardianNodeId);
    }

    function _resolveNodePaidRecipient(uint256 guardianNodeId) internal view returns (address) {
        if (guardianNodeId == 0 || address(validatorDepositRedeem) == address(0)) return address(0);

        address owner = validatorDepositRedeem.guardianIdBeneficiary(guardianNodeId);
        if (owner == address(0)) return address(0);

        address economic = validatorDepositRedeem.nodeWalletBeneficiary(owner);
        return economic != address(0) ? economic : owner;
    }

    function computeNodePaidOwed(uint256 guardianNodeId, uint256 timestamp)
        public
        view
        returns (uint256 owed, uint256 elapsedSeconds)
    {
        if (_resolveNodePaidRecipient(guardianNodeId) == address(0)) return (0, 0);

        uint256 firstEligible = nodeFirstEligibleAt[guardianNodeId];
        if (firstEligible == 0) return (0, 0);

        uint256 effectiveStart =
            firstEligible > lastDepinPaidCallAt ? firstEligible : lastDepinPaidCallAt;
        if (timestamp <= effectiveStart) return (0, 0);

        elapsedSeconds = timestamp - effectiveStart;
        owed = computePaidGbForElapsed(elapsedSeconds);
    }

    // ---------------------------------------------------------------------
    // User GB fee (consumeGb + ledger + mint paidBurned to beneficiary)
    // ---------------------------------------------------------------------

    /**
     * @notice Deduct `amount` GB from `user` (GBToken consumeGb waterfall), attribute to `guardianNodeId`,
     *         book cumulative bandwidth on this contract, and mint `paidBurned` to the node's redeem beneficiary.
     * @dev DEPRECATED: use DepinGbSettlement1155.batchSettle. Kept for transition; do not add new callers.
     *      GBDepinAirdrop must be GBToken admin. Requires GBToken V2 `consumeGb`.
     */
    function chargeUserGbForGuardianNode(uint256 guardianNodeId, address user, uint256 amount)
        external
        onlyGbOperator
        returns (uint256 freeBurned, uint256 paidBurned)
    {
        if (guardianNodeId == 0 || user == address(0) || amount == 0) revert InvalidConfig();

        address beneficiary = _resolveNodePaidRecipient(guardianNodeId);
        if (beneficiary == address(0)) revert NotEligible();

        (freeBurned, paidBurned) = gbToken.consumeGb(user, amount);
        if (freeBurned + paidBurned != amount) revert ConsumeFailed();

        guardianNodeUserFeeGbBurned[guardianNodeId] += amount;
        beneficiaryUserFeeGbBurned[beneficiary] += amount;

        if (paidBurned > 0) {
            _creditPaidGb(guardianNodeId, beneficiary, paidBurned, true, 0);
        }

        emit UserGbFeeCharged(guardianNodeId, user, beneficiary, amount, freeBurned, paidBurned);
    }

    // ---------------------------------------------------------------------
    // Protocol paid DePIN batch (mintPaid → paidPool)
    // ---------------------------------------------------------------------

    function _creditPaidGb(
        uint256 nodeId,
        address beneficiary,
        uint256 amount,
        bool fromUserFee,
        uint256 elapsedSeconds
    ) internal {
        if (amount == 0) return;

        _mintPaid(beneficiary, amount);

        guardianNodePaidGbTotal[nodeId] += amount;
        beneficiaryPaidGbTotal[beneficiary] += amount;

        CoNETIncomePeriodLib.accumulate(
            beneficiaryPaidGbHourly[beneficiary], beneficiaryPaidGbPeriod[beneficiary], block.timestamp, amount
        );
        CoNETIncomePeriodLib.accumulate(
            guardianNodePaidGbHourly[nodeId], guardianNodePaidGbPeriod[nodeId], block.timestamp, amount
        );

        if (fromUserFee) {
            guardianNodeUserFeePaidMinted[nodeId] += amount;
            beneficiaryUserFeePaidMinted[beneficiary] += amount;
        } else {
            guardianNodeProtocolPaidGbMinted[nodeId] += amount;
            beneficiaryProtocolPaidGbMinted[beneficiary] += amount;
        }

        emit DepinPaidAirdrop(nodeId, beneficiary, amount, elapsedSeconds, fromUserFee);
    }

    function _payoutNodePaid(uint256 nodeId, uint256 nowTs, uint256 globalAnchor)
        internal
        returns (uint256 minted, bool registered)
    {
        if (nodeId == 0) return (0, false);

        address beneficiary = _resolveNodePaidRecipient(nodeId);
        if (beneficiary == address(0)) return (0, false);

        uint256 firstEligible = nodeFirstEligibleAt[nodeId];
        if (firstEligible == 0) {
            nodeFirstEligibleAt[nodeId] = nowTs;
            emit DepinPaidNodeRegistered(nodeId, beneficiary, nowTs);
            return (0, true);
        }

        uint256 effectiveStart = firstEligible > globalAnchor ? firstEligible : globalAnchor;
        if (nowTs <= effectiveStart) return (0, false);

        uint256 elapsed = nowTs - effectiveStart;
        minted = computePaidGbForElapsed(elapsed);
        if (minted == 0) return (0, false);

        _creditPaidGb(nodeId, beneficiary, minted, false, elapsed);
    }

    function airdropDepinPaidAll()
        external
        onlyAdmin
        returns (uint256 nodesMinted, uint256 nodesRegistered, uint256 totalGbMinted)
    {
        _requirePaidConfigured();

        uint256 nowTs = block.timestamp;
        uint256 anchor = lastDepinPaidCallAt;
        if (nowTs <= anchor) revert NothingToAirdrop();
        uint256 globalElapsed = nowTs - anchor;

        uint256 start;
        uint256 batchSize = 100;
        for (;;) {
            GuardianNodeInfo[] memory page = guardianNodes.getAllNodes(start, batchSize);
            if (page.length == 0) break;
            uint256 len = page.length;
            for (uint256 i = 0; i < len; i++) {
                (uint256 minted, bool registered) = _payoutNodePaid(page[i].id, nowTs, anchor);
                if (registered) nodesRegistered++;
                if (minted > 0) {
                    nodesMinted++;
                    totalGbMinted += minted;
                }
            }
            start += len;
            if (len < batchSize) break;
        }

        lastDepinPaidCallAt = nowTs;
        emit DepinPaidAll(nodesMinted, nodesRegistered, totalGbMinted, globalElapsed);
    }

    function airdropDepinPaidPage(uint256 start, uint256 length, bool advanceGlobalClock)
        external
        onlyAdmin
        returns (uint256 nodesMinted, uint256 nodesRegistered, uint256 totalGbMinted)
    {
        _requirePaidConfigured();
        if (length == 0) revert InvalidConfig();

        uint256 nowTs = block.timestamp;
        uint256 anchor = lastDepinPaidCallAt;
        if (nowTs <= anchor) revert NothingToAirdrop();

        GuardianNodeInfo[] memory page = guardianNodes.getAllNodes(start, length);
        uint256 len = page.length;
        for (uint256 i = 0; i < len; i++) {
            (uint256 minted, bool registered) = _payoutNodePaid(page[i].id, nowTs, anchor);
            if (registered) nodesRegistered++;
            if (minted > 0) {
                nodesMinted++;
                totalGbMinted += minted;
            }
        }

        if (advanceGlobalClock) {
            lastDepinPaidCallAt = nowTs;
        }

        emit DepinPaidPage(start, length, nodesMinted, nodesRegistered, totalGbMinted, advanceGlobalClock);
    }

    function _mintPaid(address to, uint256 amount) internal {
        gbToken.mintPaid(to, amount);
    }

    // ---------------------------------------------------------------------
    // Free GB claim (mintReward → freePool)
    // ---------------------------------------------------------------------

    function getFreeClaimDigest(address claimant, uint256 nonce, uint256 deadline) external view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(CLAIM_FREE_GB_TYPEHASH, claimant, nonce, deadline));
        return _hashTypedDataV4(structHash);
    }

    function claimFreeGb() external {
        _claimFreeGb(msg.sender);
        emit FreeGbClaimed(msg.sender, freeClaimAmount);
    }

    function claimFreeGbFor(
        address claimant,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (freeClaimNonces[claimant] != nonce) revert InvalidSignature();

        bytes32 structHash = keccak256(abi.encode(CLAIM_FREE_GB_TYPEHASH, claimant, nonce, deadline));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        if (signer != claimant) revert InvalidSignature();

        freeClaimNonces[claimant]++;
        _claimFreeGb(claimant);
        emit FreeGbClaimedFor(claimant, freeClaimAmount, msg.sender);
    }

    function _claimFreeGb(address claimant) internal {
        if (address(validatorDepositRedeem) == address(0)) revert InvalidConfig();
        if (!_hasDepinNodes(claimant)) revert NotEligible();

        uint256 last = lastFreeClaimAt[claimant];
        if (last != 0 && block.timestamp < last + freeClaimInterval) revert ClaimTooSoon();

        lastFreeClaimAt[claimant] = block.timestamp;

        gbToken.mintReward(claimant, freeClaimAmount);
    }

    function _hasDepinNodes(address wallet) internal view returns (bool) {
        (, , string[] memory depinNodeIps, , , , , , , , , ) =
            validatorDepositRedeem.resolveNodeBundle(wallet, "");
        return depinNodeIps.length > 0;
    }

    function nextFreeClaimAt(address claimant) external view returns (uint256) {
        uint256 last = lastFreeClaimAt[claimant];
        if (last == 0) return 0;
        return last + freeClaimInterval;
    }

    function canClaimFreeGb(address claimant) external view returns (bool) {
        if (address(validatorDepositRedeem) == address(0)) return false;
        if (!_hasDepinNodes(claimant)) return false;
        uint256 last = lastFreeClaimAt[claimant];
        return last == 0 || block.timestamp >= last + freeClaimInterval;
    }
}
