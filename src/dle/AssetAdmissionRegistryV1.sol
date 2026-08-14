// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {DLEUpgradeableBase} from "./DLEUpgradeableBase.sol";
import {ITreasuryDleAuthorityV1} from "./interfaces/ITreasuryDleAuthorityV1.sol";

interface IDleOracleAdapterV1 {
    function quoteUsdc6(address asset, uint256 amount) external view returns (uint256 usdc6, uint64 updatedAt);
}

/// @notice L1 admission policy for Treasury-canonical DLE assets.
contract AssetAdmissionRegistryV1 is DLEUpgradeableBase {
    enum Status {
        NONE,
        ACTIVE,
        PAUSED,
        RETIRED,
        /// @notice No new ingress; frozen pending receipts and exit rights keep
        /// their exact-unit safety path under this historical adapter epoch.
        EXIT_ONLY
    }

    struct AssetPolicy {
        address treasuryAuthority;
        address oracleAdapter;
        bytes32 tokenCodeHash;
        bytes32 treasuryAdapterCodeHash;
        bytes32 mintAuthorityProof;
        bytes32 treasuryPolicyHash;
        bytes32 replacementReservationPolicyHash;
        uint64 policyVersion;
        uint64 adapterEpoch;
        uint64 treasuryPolicyVersion;
        uint64 maxOracleAge;
        uint64 minIngressUsdc6;
        uint64 maxTipUsdc6;
        uint256 maxOutstanding;
        Status status;
    }

    error InvalidPolicy();
    error AssetNotCanonical();
    error AssetNotActive();
    error TokenCodeHashMismatch();
    error TreasuryCodeHashMismatch();
    error OracleStale();
    error OutsideAdmissionBand();
    error AdapterEpochRegression();
    error OutstandingLiability();

    bool public globallyPaused;
    mapping(address => AssetPolicy) public policies;
    mapping(address => mapping(uint64 => AssetPolicy)) private _policyByVersion;
    mapping(address => mapping(uint64 => AssetPolicy)) private _policyByAdapterEpoch;

    event AssetPolicySet(
        address indexed asset,
        uint64 indexed policyVersion,
        uint64 indexed adapterEpoch,
        address treasuryAuthority,
        address oracleAdapter,
        Status status
    );
    event AssetStatusSet(address indexed asset, Status status);
    event GlobalPauseSet(bool paused);
    event AssetExitOnly(address indexed asset, uint64 indexed policyVersion, uint64 indexed adapterEpoch);

    function initialize(address initialOwner) external initializer {
        __DLEUpgradeableBase_init(initialOwner);
    }

    function setAssetPolicy(
        address asset,
        address treasuryAuthority,
        address oracleAdapter,
        bytes32 tokenCodeHash,
        bytes32 treasuryAdapterCodeHash,
        bytes32 mintAuthorityProof,
        uint64 adapterEpoch,
        uint64 maxOracleAge,
        uint64 minIngressUsdc6,
        uint64 maxTipUsdc6,
        uint256 maxOutstanding,
        Status status
    ) external onlyOwner {
        _setAssetPolicy(
            asset,
            treasuryAuthority,
            oracleAdapter,
            tokenCodeHash,
            treasuryAdapterCodeHash,
            mintAuthorityProof,
            bytes32(0),
            bytes32(0),
            adapterEpoch,
            0,
            maxOracleAge,
            minIngressUsdc6,
            maxTipUsdc6,
            maxOutstanding,
            status
        );
    }

    /// @notice Admission path for production Treasury V3 authority adapters.
    /// @dev The extra tuple pins the Treasury policy and exclusive replacement
    /// reservation semantics rather than accepting an arbitrary burn/mint ABI.
    function setAssetPolicyV2(
        address asset,
        address treasuryAuthority,
        address oracleAdapter,
        bytes32 tokenCodeHash,
        bytes32 treasuryAdapterCodeHash,
        bytes32 mintAuthorityProof,
        bytes32 treasuryPolicyHash,
        bytes32 replacementReservationPolicyHash,
        uint64 adapterEpoch,
        uint64 treasuryPolicyVersion,
        uint64 maxOracleAge,
        uint64 minIngressUsdc6,
        uint64 maxTipUsdc6,
        uint256 maxOutstanding,
        Status status
    ) external onlyOwner {
        _setAssetPolicy(
            asset,
            treasuryAuthority,
            oracleAdapter,
            tokenCodeHash,
            treasuryAdapterCodeHash,
            mintAuthorityProof,
            treasuryPolicyHash,
            replacementReservationPolicyHash,
            adapterEpoch,
            treasuryPolicyVersion,
            maxOracleAge,
            minIngressUsdc6,
            maxTipUsdc6,
            maxOutstanding,
            status
        );
    }

    function _setAssetPolicy(
        address asset,
        address treasuryAuthority,
        address oracleAdapter,
        bytes32 tokenCodeHash,
        bytes32 treasuryAdapterCodeHash,
        bytes32 mintAuthorityProof,
        bytes32 treasuryPolicyHash,
        bytes32 replacementReservationPolicyHash,
        uint64 adapterEpoch,
        uint64 treasuryPolicyVersion,
        uint64 maxOracleAge,
        uint64 minIngressUsdc6,
        uint64 maxTipUsdc6,
        uint256 maxOutstanding,
        Status status
    ) private {
        if (
            asset == address(0) ||
            treasuryAuthority == address(0) ||
            oracleAdapter == address(0) ||
            maxOracleAge == 0 ||
            minIngressUsdc6 == 0 ||
            maxTipUsdc6 < minIngressUsdc6 ||
            maxOutstanding == 0 ||
            status == Status.NONE
        ) revert InvalidPolicy();
        if (!ITreasuryDleAuthorityV1(treasuryAuthority).canonicalAsset(asset)) {
            revert AssetNotCanonical();
        }

        AssetPolicy storage previous = policies[asset];
        if (previous.status != Status.NONE) {
            if (adapterEpoch < previous.adapterEpoch) revert AdapterEpochRegression();
            bool adapterChanged =
                treasuryAuthority != previous.treasuryAuthority ||
                adapterEpoch != previous.adapterEpoch ||
                treasuryAdapterCodeHash != previous.treasuryAdapterCodeHash;
            if (
                adapterChanged &&
                ITreasuryDleAuthorityV1(previous.treasuryAuthority).reservedReplacement(asset) != 0
            ) revert OutstandingLiability();
            if (adapterChanged && adapterEpoch <= previous.adapterEpoch) {
                revert AdapterEpochRegression();
            }
        }
        uint64 policyVersion = previous.policyVersion + 1;
        policies[asset] = AssetPolicy({
            treasuryAuthority: treasuryAuthority,
            oracleAdapter: oracleAdapter,
            tokenCodeHash: tokenCodeHash,
            treasuryAdapterCodeHash: treasuryAdapterCodeHash,
            mintAuthorityProof: mintAuthorityProof,
            treasuryPolicyHash: treasuryPolicyHash,
            replacementReservationPolicyHash: replacementReservationPolicyHash,
            policyVersion: policyVersion,
            adapterEpoch: adapterEpoch,
            treasuryPolicyVersion: treasuryPolicyVersion,
            maxOracleAge: maxOracleAge,
            minIngressUsdc6: minIngressUsdc6,
            maxTipUsdc6: maxTipUsdc6,
            maxOutstanding: maxOutstanding,
            status: status
        });
        _policyByVersion[asset][policyVersion] = policies[asset];
        _policyByAdapterEpoch[asset][adapterEpoch] = policies[asset];
        emit AssetPolicySet(
            asset,
            policyVersion,
            adapterEpoch,
            treasuryAuthority,
            oracleAdapter,
            status
        );
    }

    function setAssetStatus(address asset, Status status) external onlyOwner {
        if (policies[asset].status == Status.NONE || status == Status.NONE) revert InvalidPolicy();
        policies[asset].status = status;
        emit AssetStatusSet(asset, status);
        if (status == Status.EXIT_ONLY) {
            emit AssetExitOnly(asset, policies[asset].policyVersion, policies[asset].adapterEpoch);
        }
    }

    function setGlobalPause(bool paused) external onlyOwner {
        globallyPaused = paused;
        emit GlobalPauseSet(paused);
    }

    function validateIngress(
        address asset,
        uint256 amount
    ) external view returns (AssetPolicy memory policy, uint256 notionalUsdc6) {
        policy = policies[asset];
        if (globallyPaused || policy.status != Status.ACTIVE) revert AssetNotActive();
        if (policy.tokenCodeHash != bytes32(0) && asset.codehash != policy.tokenCodeHash) {
            revert TokenCodeHashMismatch();
        }
        if (
            policy.treasuryAdapterCodeHash != bytes32(0) &&
            policy.treasuryAuthority.codehash != policy.treasuryAdapterCodeHash
        ) revert TreasuryCodeHashMismatch();
        if (!ITreasuryDleAuthorityV1(policy.treasuryAuthority).canonicalAsset(asset)) {
            revert AssetNotCanonical();
        }

        uint64 updatedAt;
        (notionalUsdc6, updatedAt) = IDleOracleAdapterV1(policy.oracleAdapter).quoteUsdc6(asset, amount);
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > policy.maxOracleAge) {
            revert OracleStale();
        }
        if (notionalUsdc6 < policy.minIngressUsdc6 || notionalUsdc6 > policy.maxTipUsdc6) {
            revert OutsideAdmissionBand();
        }
    }

    function authorityFor(
        address asset
    ) external view returns (address treasuryAuthority, uint64 adapterEpoch, uint64 policyVersion) {
        AssetPolicy storage policy = policies[asset];
        return (policy.treasuryAuthority, policy.adapterEpoch, policy.policyVersion);
    }

    /// @notice Returns the immutable policy snapshot bound to a receipt.
    /// @dev Historical snapshots are deliberately available while a pending
    /// receipt or activated L2 credit still references their adapter epoch.
    function policyByVersion(address asset, uint64 policyVersion) external view returns (AssetPolicy memory) {
        return _policyByVersion[asset][policyVersion];
    }

    function policyByAdapterEpoch(
        address asset,
        uint64 adapterEpoch
    ) external view returns (AssetPolicy memory) {
        return _policyByAdapterEpoch[asset][adapterEpoch];
    }

    function validateExitAuthority(
        address asset,
        uint64 adapterEpoch,
        address treasuryAuthority
    ) external view returns (AssetPolicy memory policy) {
        policy = _policyByAdapterEpoch[asset][adapterEpoch];
        if (
            policy.status == Status.NONE ||
            policy.treasuryAuthority != treasuryAuthority ||
            policy.adapterEpoch != adapterEpoch
        ) revert AssetNotCanonical();
        if (policy.tokenCodeHash != bytes32(0) && asset.codehash != policy.tokenCodeHash) {
            revert TokenCodeHashMismatch();
        }
        if (
            policy.treasuryAdapterCodeHash != bytes32(0) &&
            treasuryAuthority.codehash != policy.treasuryAdapterCodeHash
        ) revert TreasuryCodeHashMismatch();
        if (!ITreasuryDleAuthorityV1(treasuryAuthority).canonicalAsset(asset)) {
            revert AssetNotCanonical();
        }
    }

    uint256[45] private __gap;
}
