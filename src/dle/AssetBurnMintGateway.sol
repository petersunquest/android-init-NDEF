// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {DLEUpgradeableBase} from "./DLEUpgradeableBase.sol";
import {AssetAdmissionRegistryV1} from "./AssetAdmissionRegistryV1.sol";
import {ArchiveCertificateVerifierV1} from "./ArchiveCertificateVerifierV1.sol";
import {DLEArchiveDisputeManagerV1} from "./DLEArchiveDisputeManagerV1.sol";
import {DLEChainRegistry1155V1} from "./DLEChainRegistry1155V1.sol";
import {ITreasuryDleAuthorityV1} from "./interfaces/ITreasuryDleAuthorityV1.sol";

/// @notice CoNET-DLE asset ingress/exit accounting gateway.
/// @dev The MVP deliberately delegates physical supply changes to a
/// Treasury-authority adapter; it never grants itself free-standing token mint.
contract AssetBurnMintGateway is DLEUpgradeableBase, ReentrancyGuardUpgradeable {
    enum ReceiptStatus {
        NONE,
        BURNED_PENDING,
        ACTIVATED,
        REFUNDED
    }

    enum ExitKind {
        NONE,
        NORMAL,
        FORCE
    }

    enum ExitStatus {
        NONE,
        NORMAL_PENDING,
        FORCE_PENDING,
        PROOF_REQUIRED,
        FINALIZED,
        CANCELLED,
        SUPERSEDED
    }

    struct AssetAccounting {
        uint256 physicalBurned;
        uint256 pendingBurnLiability;
        uint256 l2CreditLiability;
        uint256 refundedPending;
        uint256 mintedExit;
        uint256 reservedReplacement;
    }

    struct BurnReceipt {
        address from;
        address asset;
        address treasuryAuthority;
        uint256 assetNftId;
        uint256 amount;
        uint64 deadline;
        uint64 policyVersion;
        uint64 adapterEpoch;
        ReceiptStatus status;
        bytes32 burnOperationId;
    }

    struct LatestAc {
        uint64 height;
        bytes32 certificateHash;
    }

    struct ExitRight {
        uint256 assetNftId;
        address owner;
        address asset;
        address treasuryAuthority;
        uint256 amount;
        uint64 adapterEpoch;
        uint64 bestAcHeight;
        uint64 requestedAt;
        uint64 requestL1Block;
        uint64 challengeDeadline;
        ExitKind kind;
        ExitStatus status;
        bytes32 bestAcHash;
        bool observedRequest;
    }

    error InvalidAmount();
    error InvalidDeadline();
    error NotAssetChain();
    error NotChainOwner();
    error IngressPaused();
    error OrdinaryActionPaused();
    error OracleUnhealthy();
    error CapacityExceeded();
    error UnknownReceipt();
    error InvalidReceiptState();
    error ActivationExpired();
    error RefundTooEarly();
    error InvalidCertificateChain();
    error InvalidCertificateGroup();
    error StaleArchiveCertificate();
    error ConflictingArchiveCertificate();
    error NonDescendantArchiveCertificate();
    error InsufficientTipCredit();
    error InvalidExitState();
    error ExitChallengeOpen();
    error ExitChallengeClosed();
    error LatestProofMismatch();
    error ForceExitAlreadyPending();
    error ChallengeMayNotIncreaseClaim();
    error NormalExitNotTimedOut();
    error InvalidFrozenReference();
    error DuplicateId();
    error InvariantViolation();
    error AdapterEpochAuthorityMismatch();

    AssetAdmissionRegistryV1 public admissionRegistry;
    ArchiveCertificateVerifierV1 public certificateVerifier;
    DLEChainRegistry1155V1 public chainRegistry;
    DLEArchiveDisputeManagerV1 public disputeManager;

    bool public ingressPaused;
    bool public transferPaused;
    bool public tokenUserPaused;
    bool public oracleHealthy;
    uint64 public forceExitChallengePeriod;
    uint64 public normalExitTimeout;
    uint64 public nextMintSequence;

    mapping(address => uint64) public burnNonce;
    mapping(address => uint64) public normalExitNonce;
    mapping(bytes32 => uint64) public forceExitEpoch;
    mapping(bytes32 => BurnReceipt) public burnReceipts;
    mapping(bytes32 => ExitRight) public exitRights;
    mapping(bytes32 => bool) public idConsumed;
    mapping(address => AssetAccounting) private _assetAccounting;
    mapping(uint256 => LatestAc) public latestKnownAc;
    mapping(uint256 => mapping(address => mapping(uint64 => uint256))) public tipCredit;
    mapping(uint256 => mapping(address => mapping(uint64 => uint256))) public reservedExitCredit;
    mapping(address => mapping(uint64 => address)) public authorityByAssetEpoch;
    mapping(bytes32 => bytes32) public activeForceExit;
    mapping(bytes32 => bytes32) public forceTupleKeyByExit;

    event BurnPending(
        bytes32 indexed burnId,
        uint256 indexed assetNftId,
        address indexed asset,
        address from,
        uint256 amount,
        uint64 deadline,
        uint64 adapterEpoch
    );
    event BurnIngressActivated(
        bytes32 indexed burnId,
        uint256 indexed assetNftId,
        bytes32 indexed archiveCertificateHash,
        uint256 amount
    );
    event BurnIngressRefunded(bytes32 indexed burnId, address indexed to, uint256 amount);
    event LatestArchiveCertificateAdvanced(
        uint256 indexed assetNftId,
        uint64 indexed height,
        bytes32 indexed certificateHash
    );
    event ExitRequested(
        bytes32 indexed exitRightId,
        ExitKind indexed kind,
        uint256 indexed assetNftId,
        address owner,
        address asset,
        uint256 amount,
        uint64 adapterEpoch
    );
    event ExitProofRefreshed(
        bytes32 indexed exitRightId,
        uint64 indexed acHeight,
        bytes32 indexed acHash,
        uint256 amount
    );
    event ExitFinalized(
        bytes32 indexed exitRightId,
        uint64 indexed mintSequence,
        address indexed owner,
        uint256 amount,
        ExitKind kind
    );
    event ExitCancelled(bytes32 indexed exitRightId);
    event NormalExitSuperseded(bytes32 indexed exitRightId);
    event CreditReallocated(
        address indexed asset,
        uint256 indexed sourceAssetNftId,
        uint256 indexed targetAssetNftId,
        uint64 adapterEpoch,
        uint256 amount
    );
    event PauseStateSet(bool ingressPaused, bool transferPaused, bool tokenUserPaused, bool oracleHealthy);

    function initialize(
        address initialOwner,
        address admissionRegistry_,
        address certificateVerifier_,
        address chainRegistry_,
        address disputeManager_,
        uint64 forceExitChallengePeriod_,
        uint64 normalExitTimeout_
    ) external initializer {
        __DLEUpgradeableBase_init(initialOwner);
        __ReentrancyGuard_init();
        if (
            admissionRegistry_ == address(0) ||
            certificateVerifier_ == address(0) ||
            chainRegistry_ == address(0) ||
            disputeManager_ == address(0)
        ) revert ZeroAddress();
        admissionRegistry = AssetAdmissionRegistryV1(admissionRegistry_);
        certificateVerifier = ArchiveCertificateVerifierV1(certificateVerifier_);
        chainRegistry = DLEChainRegistry1155V1(chainRegistry_);
        disputeManager = DLEArchiveDisputeManagerV1(disputeManager_);
        forceExitChallengePeriod = forceExitChallengePeriod_;
        normalExitTimeout = normalExitTimeout_;
        oracleHealthy = true;
        nextMintSequence = 1;
    }

    function burnToDle(
        uint256 assetNftId,
        address asset,
        uint256 amount,
        uint64 deadline
    ) external nonReentrant returns (bytes32 burnId) {
        if (ingressPaused || tokenUserPaused) revert IngressPaused();
        if (amount == 0) revert InvalidAmount();
        if (deadline <= block.timestamp) revert InvalidDeadline();
        _requireAssetChainOwner(assetNftId, msg.sender);

        (AssetAdmissionRegistryV1.AssetPolicy memory policy, ) =
            admissionRegistry.validateIngress(asset, amount);
        AssetAccounting storage accounting_ = _assetAccounting[asset];
        if (
            accounting_.pendingBurnLiability + accounting_.l2CreditLiability + amount >
            policy.maxOutstanding
        ) revert CapacityExceeded();
        ITreasuryDleAuthorityV1 authority = ITreasuryDleAuthorityV1(policy.treasuryAuthority);
        if (authority.availableReplacementCapacity(asset) < amount) revert CapacityExceeded();

        uint64 nonce = ++burnNonce[msg.sender];
        burnId = keccak256(
            abi.encode(
                keccak256("CoNET-DLE-Burn-v1"),
                block.chainid,
                address(this),
                msg.sender,
                assetNftId,
                asset,
                amount,
                nonce
            )
        );
        if (idConsumed[burnId]) revert DuplicateId();
        bytes32 operationId = keccak256(abi.encode("DLE_BURN", burnId));

        idConsumed[burnId] = true;
        burnReceipts[burnId] = BurnReceipt({
            from: msg.sender,
            asset: asset,
            treasuryAuthority: policy.treasuryAuthority,
            assetNftId: assetNftId,
            amount: amount,
            deadline: deadline,
            policyVersion: policy.policyVersion,
            adapterEpoch: policy.adapterEpoch,
            status: ReceiptStatus.BURNED_PENDING,
            burnOperationId: operationId
        });
        address epochAuthority = authorityByAssetEpoch[asset][policy.adapterEpoch];
        if (epochAuthority != address(0) && epochAuthority != policy.treasuryAuthority) {
            revert AdapterEpochAuthorityMismatch();
        }
        authorityByAssetEpoch[asset][policy.adapterEpoch] = policy.treasuryAuthority;
        accounting_.physicalBurned += amount;
        accounting_.pendingBurnLiability += amount;
        accounting_.reservedReplacement += amount;
        _assertAccounting(accounting_);

        authority.reserveAndBurn(operationId, asset, msg.sender, amount, policy.adapterEpoch);
        emit BurnPending(burnId, assetNftId, asset, msg.sender, amount, deadline, policy.adapterEpoch);
    }

    function activateBurn(
        bytes32 burnId,
        ArchiveCertificateVerifierV1.ArchiveCertificateV1 calldata certificate,
        bytes[] calldata signatures
    ) external {
        BurnReceipt storage receipt = burnReceipts[burnId];
        if (receipt.status == ReceiptStatus.NONE) revert UnknownReceipt();
        if (receipt.status != ReceiptStatus.BURNED_PENDING) revert InvalidReceiptState();
        if (block.timestamp > receipt.deadline) revert ActivationExpired();
        if (ingressPaused || tokenUserPaused) revert IngressPaused();

        AssetAdmissionRegistryV1.AssetPolicy memory policy;
        (policy, ) = admissionRegistry.validateIngress(receipt.asset, receipt.amount);
        if (
            policy.policyVersion != receipt.policyVersion ||
            policy.adapterEpoch != receipt.adapterEpoch ||
            policy.treasuryAuthority != receipt.treasuryAuthority
        ) revert InvalidReceiptState();

        bytes32 acHash = _verifyAndAdvanceAc(receipt.assetNftId, certificate, signatures);
        receipt.status = ReceiptStatus.ACTIVATED;
        AssetAccounting storage accounting_ = _assetAccounting[receipt.asset];
        accounting_.pendingBurnLiability -= receipt.amount;
        accounting_.l2CreditLiability += receipt.amount;
        tipCredit[receipt.assetNftId][receipt.asset][receipt.adapterEpoch] += receipt.amount;
        _assertAccounting(accounting_);
        emit BurnIngressActivated(burnId, receipt.assetNftId, acHash, receipt.amount);
    }

    function refundBurn(bytes32 burnId) external nonReentrant {
        BurnReceipt storage receipt = burnReceipts[burnId];
        if (receipt.status == ReceiptStatus.NONE) revert UnknownReceipt();
        if (receipt.status != ReceiptStatus.BURNED_PENDING) revert InvalidReceiptState();
        if (block.timestamp <= receipt.deadline) revert RefundTooEarly();

        receipt.status = ReceiptStatus.REFUNDED;
        AssetAccounting storage accounting_ = _assetAccounting[receipt.asset];
        accounting_.pendingBurnLiability -= receipt.amount;
        accounting_.refundedPending += receipt.amount;
        accounting_.reservedReplacement -= receipt.amount;
        _assertAccounting(accounting_);

        bytes32 operationId = keccak256(abi.encode("DLE_REFUND", burnId));
        ITreasuryDleAuthorityV1(receipt.treasuryAuthority).releaseReservedAndMint(
            operationId,
            receipt.asset,
            receipt.from,
            receipt.amount,
            receipt.adapterEpoch
        );
        emit BurnIngressRefunded(burnId, receipt.from, receipt.amount);
    }

    function requestNormalExit(
        uint256 assetNftId,
        address asset,
        uint64 adapterEpoch,
        uint256 amount,
        ArchiveCertificateVerifierV1.ArchiveCertificateV1 calldata certificate,
        bytes[] calldata signatures
    ) external returns (bytes32 exitRightId) {
        if (transferPaused || tokenUserPaused) revert OrdinaryActionPaused();
        if (!oracleHealthy) revert OracleUnhealthy();
        _requireAssetChainOwner(assetNftId, msg.sender);
        _reserveTipCredit(assetNftId, asset, adapterEpoch, amount);
        bytes32 acHash = _verifyAndAdvanceAc(assetNftId, certificate, signatures);

        uint64 nonce = ++normalExitNonce[msg.sender];
        exitRightId = keccak256(
            abi.encode(
                keccak256("CoNET-DLE-NormalExit-v1"),
                block.chainid,
                address(this),
                assetNftId,
                msg.sender,
                asset,
                adapterEpoch,
                nonce
            )
        );
        _createExitRight(
            exitRightId,
            ExitKind.NORMAL,
            ExitStatus.NORMAL_PENDING,
            assetNftId,
            asset,
            adapterEpoch,
            amount,
            certificate.tipHeight,
            acHash,
            true
        );
    }

    function requestForceExit(
        uint256 assetNftId,
        address asset,
        uint64 adapterEpoch,
        uint256 amount,
        uint8 claimType,
        ArchiveCertificateVerifierV1.ArchiveCertificateV1 calldata certificate,
        bytes[] calldata signatures
    ) external returns (bytes32 exitRightId) {
        _requireAssetChainOwner(assetNftId, msg.sender);
        bytes32 tupleKey = keccak256(abi.encode(assetNftId, msg.sender, claimType));
        if (activeForceExit[tupleKey] != bytes32(0)) revert ForceExitAlreadyPending();
        _reserveTipCredit(assetNftId, asset, adapterEpoch, amount);
        bytes32 acHash = _verifyAndAdvanceAc(assetNftId, certificate, signatures);

        uint64 epoch = ++forceExitEpoch[tupleKey];
        exitRightId = keccak256(
            abi.encode(
                keccak256("CoNET-DLE-ForceExit-v1"),
                block.chainid,
                address(this),
                assetNftId,
                msg.sender,
                claimType,
                epoch
            )
        );
        activeForceExit[tupleKey] = exitRightId;
        forceTupleKeyByExit[exitRightId] = tupleKey;
        _createExitRight(
            exitRightId,
            ExitKind.FORCE,
            ExitStatus.FORCE_PENDING,
            assetNftId,
            asset,
            adapterEpoch,
            amount,
            certificate.tipHeight,
            acHash,
            false
        );
    }

    function challengeForceExit(
        bytes32 exitRightId,
        uint256 correctedAmount,
        ArchiveCertificateVerifierV1.ArchiveCertificateV1 calldata newerCertificate,
        bytes[] calldata signatures
    ) external {
        ExitRight storage right = exitRights[exitRightId];
        if (right.status != ExitStatus.FORCE_PENDING && right.status != ExitStatus.PROOF_REQUIRED) {
            revert InvalidExitState();
        }
        if (block.timestamp > right.challengeDeadline) revert ExitChallengeClosed();
        if (correctedAmount > right.amount) revert ChallengeMayNotIncreaseClaim();
        bytes32 acHash = _verifyAndAdvanceAc(right.assetNftId, newerCertificate, signatures);
        if (newerCertificate.tipHeight <= right.bestAcHeight) revert StaleArchiveCertificate();
        _applyCorrectedForceProof(
            right,
            exitRightId,
            correctedAmount,
            newerCertificate.tipHeight,
            acHash,
            newerCertificate.l1ContextBlockNumber >= right.requestL1Block
        );
    }

    function refreshForceExitProof(
        bytes32 exitRightId,
        uint256 correctedAmount,
        ArchiveCertificateVerifierV1.ArchiveCertificateV1 calldata certificate,
        bytes[] calldata signatures
    ) external {
        ExitRight storage right = exitRights[exitRightId];
        if (right.status != ExitStatus.FORCE_PENDING && right.status != ExitStatus.PROOF_REQUIRED) {
            revert InvalidExitState();
        }
        if (correctedAmount > right.amount) revert ChallengeMayNotIncreaseClaim();
        bytes32 acHash = _verifyAndAdvanceAc(right.assetNftId, certificate, signatures);
        _applyCorrectedForceProof(
            right,
            exitRightId,
            correctedAmount,
            certificate.tipHeight,
            acHash,
            certificate.l1ContextBlockNumber >= right.requestL1Block
        );
    }

    function markForceExitProofRequired(
        bytes32 exitRightId,
        ArchiveCertificateVerifierV1.ArchiveCertificateV1 calldata newerCertificate,
        bytes[] calldata signatures
    ) external {
        ExitRight storage right = exitRights[exitRightId];
        if (right.status != ExitStatus.FORCE_PENDING) revert InvalidExitState();
        bytes32 acHash = _verifyAndAdvanceAc(right.assetNftId, newerCertificate, signatures);
        if (newerCertificate.tipHeight <= right.bestAcHeight) revert StaleArchiveCertificate();
        right.status = ExitStatus.PROOF_REQUIRED;
        emit ExitProofRefreshed(exitRightId, newerCertificate.tipHeight, acHash, right.amount);
    }

    function finalizeNormalExit(bytes32 exitRightId) external nonReentrant {
        ExitRight storage right = exitRights[exitRightId];
        if (right.status != ExitStatus.NORMAL_PENDING) revert InvalidExitState();
        _requireLatestProof(right);
        _finalizeExit(exitRightId, right);
    }

    function finalizeForceExit(bytes32 exitRightId) external nonReentrant {
        ExitRight storage right = exitRights[exitRightId];
        if (right.status != ExitStatus.FORCE_PENDING) revert InvalidExitState();
        if (block.timestamp <= right.challengeDeadline) revert ExitChallengeOpen();
        _requireLatestProof(right);

        bool frozen = disputeManager.isFrozenReference(
            right.assetNftId,
            right.bestAcHeight,
            right.bestAcHash
        );
        if (!right.observedRequest && !frozen) revert InvalidFrozenReference();
        _finalizeExit(exitRightId, right);
    }

    function takeOverTimedOutNormal(bytes32 exitRightId) external {
        ExitRight storage right = exitRights[exitRightId];
        if (right.status != ExitStatus.NORMAL_PENDING) revert InvalidExitState();
        if (block.timestamp <= right.requestedAt + normalExitTimeout) revert NormalExitNotTimedOut();
        right.status = ExitStatus.SUPERSEDED;
        reservedExitCredit[right.assetNftId][right.asset][right.adapterEpoch] -= right.amount;
        emit NormalExitSuperseded(exitRightId);
    }

    function reallocateCredit(
        uint256 sourceAssetNftId,
        uint256 targetAssetNftId,
        address asset,
        uint64 adapterEpoch,
        uint256 amount
    ) external onlyOwner {
        if (transferPaused || tokenUserPaused) revert OrdinaryActionPaused();
        if (amount == 0) revert InvalidAmount();
        uint256 sourceCredit = tipCredit[sourceAssetNftId][asset][adapterEpoch];
        uint256 sourceReserved = reservedExitCredit[sourceAssetNftId][asset][adapterEpoch];
        if (sourceCredit < sourceReserved + amount) revert InsufficientTipCredit();
        if (
            chainRegistry.chainClass(targetAssetNftId) != DLEChainRegistry1155V1.ChainClass.ASSET
        ) revert NotAssetChain();
        tipCredit[sourceAssetNftId][asset][adapterEpoch] = sourceCredit - amount;
        tipCredit[targetAssetNftId][asset][adapterEpoch] += amount;
        emit CreditReallocated(asset, sourceAssetNftId, targetAssetNftId, adapterEpoch, amount);
    }

    function setPauseState(
        bool ingressPaused_,
        bool transferPaused_,
        bool tokenUserPaused_,
        bool oracleHealthy_
    ) external onlyOwner {
        ingressPaused = ingressPaused_;
        transferPaused = transferPaused_;
        tokenUserPaused = tokenUserPaused_;
        oracleHealthy = oracleHealthy_;
        emit PauseStateSet(ingressPaused_, transferPaused_, tokenUserPaused_, oracleHealthy_);
    }

    function setExitWindows(uint64 forceChallengePeriod, uint64 normalTimeout) external onlyOwner {
        forceExitChallengePeriod = forceChallengePeriod;
        normalExitTimeout = normalTimeout;
    }

    function assetAccounting(address asset) external view returns (AssetAccounting memory) {
        return _assetAccounting[asset];
    }

    function spendableTipCredit(
        uint256 assetNftId,
        address asset,
        uint64 adapterEpoch
    ) external view returns (uint256) {
        return
            tipCredit[assetNftId][asset][adapterEpoch] -
            reservedExitCredit[assetNftId][asset][adapterEpoch];
    }

    function accountingInvariantHolds(address asset) external view returns (bool) {
        AssetAccounting storage accounting_ = _assetAccounting[asset];
        return
            accounting_.physicalBurned ==
            accounting_.pendingBurnLiability +
                accounting_.l2CreditLiability +
                accounting_.refundedPending +
                accounting_.mintedExit &&
            accounting_.reservedReplacement ==
            accounting_.pendingBurnLiability + accounting_.l2CreditLiability;
    }

    function _createExitRight(
        bytes32 exitRightId,
        ExitKind kind,
        ExitStatus status,
        uint256 assetNftId,
        address asset,
        uint64 adapterEpoch,
        uint256 amount,
        uint64 acHeight,
        bytes32 acHash,
        bool observedRequest
    ) private {
        if (idConsumed[exitRightId]) revert DuplicateId();
        address authority = authorityByAssetEpoch[asset][adapterEpoch];
        if (authority == address(0)) revert InvalidExitState();
        // Exits are intentionally validated against the receipt/credit's
        // frozen adapter epoch, not today's ingress policy. This permits a
        // paused or exit-only asset to settle existing exact-unit rights
        // without admitting fresh burns through a replacement adapter.
        admissionRegistry.validateExitAuthority(asset, adapterEpoch, authority);
        idConsumed[exitRightId] = true;
        exitRights[exitRightId] = ExitRight({
            assetNftId: assetNftId,
            owner: msg.sender,
            asset: asset,
            treasuryAuthority: authority,
            amount: amount,
            adapterEpoch: adapterEpoch,
            bestAcHeight: acHeight,
            requestedAt: uint64(block.timestamp),
            requestL1Block: uint64(block.number),
            challengeDeadline: kind == ExitKind.FORCE
                ? uint64(block.timestamp) + forceExitChallengePeriod
                : 0,
            kind: kind,
            status: status,
            bestAcHash: acHash,
            observedRequest: observedRequest
        });
        emit ExitRequested(exitRightId, kind, assetNftId, msg.sender, asset, amount, adapterEpoch);
    }

    function _applyCorrectedForceProof(
        ExitRight storage right,
        bytes32 exitRightId,
        uint256 correctedAmount,
        uint64 acHeight,
        bytes32 acHash,
        bool observedRequest
    ) private {
        uint256 released = right.amount - correctedAmount;
        if (released != 0) {
            reservedExitCredit[right.assetNftId][right.asset][right.adapterEpoch] -= released;
        }
        right.amount = correctedAmount;
        right.bestAcHeight = acHeight;
        right.bestAcHash = acHash;
        right.challengeDeadline = uint64(block.timestamp) + forceExitChallengePeriod;
        right.observedRequest = right.observedRequest || observedRequest;
        if (correctedAmount == 0) {
            right.status = ExitStatus.CANCELLED;
            bytes32 tupleKey = forceTupleKeyByExit[exitRightId];
            activeForceExit[tupleKey] = bytes32(0);
            emit ExitCancelled(exitRightId);
        } else {
            right.status = ExitStatus.FORCE_PENDING;
            emit ExitProofRefreshed(exitRightId, acHeight, acHash, correctedAmount);
        }
    }

    function _finalizeExit(bytes32 exitRightId, ExitRight storage right) private {
        uint256 amount = right.amount;
        if (amount == 0) revert InvalidAmount();

        right.status = ExitStatus.FINALIZED;
        if (right.kind == ExitKind.FORCE) {
            bytes32 tupleKey = forceTupleKeyByExit[exitRightId];
            activeForceExit[tupleKey] = bytes32(0);
        }
        tipCredit[right.assetNftId][right.asset][right.adapterEpoch] -= amount;
        reservedExitCredit[right.assetNftId][right.asset][right.adapterEpoch] -= amount;
        AssetAccounting storage accounting_ = _assetAccounting[right.asset];
        accounting_.l2CreditLiability -= amount;
        accounting_.mintedExit += amount;
        accounting_.reservedReplacement -= amount;
        _assertAccounting(accounting_);

        uint64 mintSequence = nextMintSequence++;
        bytes32 operationId = keccak256(abi.encode("DLE_EXIT", exitRightId, mintSequence));
        ITreasuryDleAuthorityV1(right.treasuryAuthority).releaseReservedAndMint(
            operationId,
            right.asset,
            right.owner,
            amount,
            right.adapterEpoch
        );
        emit ExitFinalized(exitRightId, mintSequence, right.owner, amount, right.kind);
    }

    function _reserveTipCredit(
        uint256 assetNftId,
        address asset,
        uint64 adapterEpoch,
        uint256 amount
    ) private {
        if (amount == 0) revert InvalidAmount();
        uint256 credit = tipCredit[assetNftId][asset][adapterEpoch];
        uint256 reserved = reservedExitCredit[assetNftId][asset][adapterEpoch];
        if (credit < reserved + amount) revert InsufficientTipCredit();
        reservedExitCredit[assetNftId][asset][adapterEpoch] = reserved + amount;
    }

    function _verifyAndAdvanceAc(
        uint256 assetNftId,
        ArchiveCertificateVerifierV1.ArchiveCertificateV1 calldata certificate,
        bytes[] calldata signatures
    ) private returns (bytes32 acHash) {
        if (certificate.chainNftId != assetNftId) revert InvalidCertificateChain();
        uint64 groupId = chainRegistry.archiveGroupId(assetNftId);
        if (groupId == 0 || certificate.archiveGroupId != groupId) revert InvalidCertificateGroup();
        acHash = certificateVerifier.verifyArchiveCertificate(certificate, signatures);

        LatestAc storage latest = latestKnownAc[assetNftId];
        if (certificate.tipHeight < latest.height) revert StaleArchiveCertificate();
        if (certificate.tipHeight == latest.height) {
            if (latest.certificateHash != bytes32(0) && latest.certificateHash != acHash) {
                revert ConflictingArchiveCertificate();
            }
            if (latest.certificateHash == bytes32(0)) {
                latest.certificateHash = acHash;
            }
            return acHash;
        }
        if (
            latest.certificateHash != bytes32(0) &&
            certificate.parentArchiveCertificateHash != latest.certificateHash
        ) revert NonDescendantArchiveCertificate();
        latest.height = certificate.tipHeight;
        latest.certificateHash = acHash;
        emit LatestArchiveCertificateAdvanced(assetNftId, certificate.tipHeight, acHash);
    }

    function _requireLatestProof(ExitRight storage right) private view {
        LatestAc storage latest = latestKnownAc[right.assetNftId];
        if (latest.height != right.bestAcHeight || latest.certificateHash != right.bestAcHash) {
            revert LatestProofMismatch();
        }
    }

    function _requireAssetChainOwner(uint256 assetNftId, address caller) private view {
        if (chainRegistry.chainClass(assetNftId) != DLEChainRegistry1155V1.ChainClass.ASSET) {
            revert NotAssetChain();
        }
        if (chainRegistry.chainOwner(assetNftId) != caller) revert NotChainOwner();
    }

    function _assertAccounting(AssetAccounting storage accounting_) private view {
        if (
            accounting_.physicalBurned !=
            accounting_.pendingBurnLiability +
                accounting_.l2CreditLiability +
                accounting_.refundedPending +
                accounting_.mintedExit ||
            accounting_.reservedReplacement !=
            accounting_.pendingBurnLiability + accounting_.l2CreditLiability
        ) revert InvariantViolation();
    }

    uint256[35] private __gap;
}
