// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AdminStatsQueryModuleV2.sol";
import "./Errors.sol";
import "./IssuedNftStorage.sol";
import "./ReferrerStorage.sol";
import "./ReferrerRegistryLib.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "../contracts/utils/cryptography/MessageHashUtils.sol";

interface IBeamioUserCardFactoryEip712V4 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IBeamioUserCardFactoryAaOracleV4 {
    function aaFactory() external view returns (address);
}

interface IBeamioAccountFactoryResolveAaV4 {
    function beamioAccountOf(address eoa) external view returns (address);
    function isBeamioAccount(address account) external view returns (bool);
}

/**
 * @title BeamioUserCardAdminStatsQueryModuleV4
 * @notice Routes + implements Plan A `bindShareRefereeWithSignature` and dual referrer amount ratios.
 * @dev Kept off IssuedNftModuleV2 to stay under EIP-170 on the IssuedNft module.
 *      Referrer index + downline keys are **EOA only** (AA addresses cannot be registered).
 */
contract BeamioUserCardAdminStatsQueryModuleV4 is BeamioUserCardAdminStatsQueryModuleV2 {
    uint8 private constant ROUTE_STATS_QUERY = type(uint8).max - 1;

    bytes32 public constant BIND_SHARE_REFEREE_TYPEHASH = keccak256(
        "BindShareReferee(address cardAddress,address downlineEOA,address refereeEOA,uint256 deadline,bytes32 nonce)"
    );

    event ShareRefereeBoundWithSignature(
        address indexed downlineEOA,
        address indexed refereeEOA,
        address downlineAA,
        address refereeAA,
        bytes32 nonce
    );

    event ReferrerChargeAmountRatioUpdated(uint256 oldRatioE6, uint256 newRatioE6);
    event ReferrerTopupAmountRatioUpdated(uint256 oldRatioE6, uint256 newRatioE6);

    modifier onlyOwnerOrGateway() {
        address cardOwner = IUserCardCtx(address(this)).owner();
        address gw = IUserCardCtx(address(this)).factoryGateway();
        if (msg.sender != cardOwner && msg.sender != gw) revert BM_NotAuthorized();
        _;
    }

    function selectorModuleKind(bytes4 sel) public pure virtual override returns (uint8) {
        if (
            sel == bytes4(keccak256("bindShareRefereeWithSignature(address,address,uint256,bytes32,bytes)"))
                || sel == bytes4(keccak256("setReferrerChargeAmountRatio(uint256)"))
                || sel == bytes4(keccak256("setReferrerTopupAmountRatio(uint256)"))
                || sel == bytes4(keccak256("referrerChargeAmountRatioE6()"))
                || sel == bytes4(keccak256("referrerTopupAmountRatioE6()"))
        ) {
            return ROUTE_STATS_QUERY;
        }
        return super.selectorModuleKind(sel);
    }

    /// @notice E6 ratio of charge amountFiat6 → referrer token #1; 0 = off.
    function referrerChargeAmountRatioE6() external view returns (uint256) {
        return ReferrerStorage.layout().referrerRewardFromChargeRewardRatioE6;
    }

    /// @notice E6 ratio of top-up amountFiat6 → referrer token #1; 0 = off.
    function referrerTopupAmountRatioE6() external view returns (uint256) {
        return ReferrerStorage.layout().referrerRewardFromTopupAmountRatioE6;
    }

    function setReferrerChargeAmountRatio(uint256 ratioE6) external onlyOwnerOrGateway {
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        uint256 old = r.referrerRewardFromChargeRewardRatioE6;
        r.referrerRewardFromChargeRewardRatioE6 = ratioE6;
        emit ReferrerChargeAmountRatioUpdated(old, ratioE6);
    }

    function setReferrerTopupAmountRatio(uint256 ratioE6) external onlyOwnerOrGateway {
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        uint256 old = r.referrerRewardFromTopupAmountRatioE6;
        r.referrerRewardFromTopupAmountRatioE6 = ratioE6;
        emit ReferrerTopupAmountRatioUpdated(old, ratioE6);
    }

    /// @notice Plan A: share-landing bind — opener (downlineEOA) becomes refereeEOA's downline on this card.
    /// @dev Registry storage keys are EOAs. Inputs that are Beamio AA addresses revert with UC_MustBeEoa.
    function bindShareRefereeWithSignature(
        address downlineEOA,
        address refereeEOA,
        uint256 deadline,
        bytes32 nonce,
        bytes calldata userSignature
    ) external returns (address downlineAA, address refereeAA) {
        if (downlineEOA == address(0) || refereeEOA == address(0)) revert BM_ZeroAddress();
        if (downlineEOA == refereeEOA) revert UC_RefereeSelfReferrer(downlineEOA);
        if (block.timestamp > deadline) revert UC_InvalidTimeWindow(block.timestamp, 0, deadline);

        address gw = IUserCardCtx(address(this)).factoryGateway();
        if (gw == address(0)) revert BM_ZeroAddress();

        IssuedNftStorage.Layout storage issued = IssuedNftStorage.layout();
        bytes32 nonceKey = keccak256(abi.encode(downlineEOA, nonce));
        if (issued.usedBindShareRefereeNonces[nonceKey]) revert UC_NonceUsed();
        issued.usedBindShareRefereeNonces[nonceKey] = true;

        bytes32 structHash = keccak256(
            abi.encode(BIND_SHARE_REFEREE_TYPEHASH, address(this), downlineEOA, refereeEOA, deadline, nonce)
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(
            IBeamioUserCardFactoryEip712V4(gw).DOMAIN_SEPARATOR(),
            structHash
        );
        address signer = ECDSA.recover(digest, userSignature);
        if (signer != downlineEOA) revert UC_InvalidSignature(signer, downlineEOA);

        address aaFactory = IBeamioUserCardFactoryAaOracleV4(gw).aaFactory();
        if (aaFactory == address(0)) revert BM_ZeroAddress();
        IBeamioAccountFactoryResolveAaV4 aaFac = IBeamioAccountFactoryResolveAaV4(aaFactory);

        // AA cannot be used as referrer / downline registry keys.
        if (aaFac.isBeamioAccount(downlineEOA)) revert UC_MustBeEoa(downlineEOA);
        if (aaFac.isBeamioAccount(refereeEOA)) revert UC_MustBeEoa(refereeEOA);

        // Product gate: both sides must already have Express Pay (AA), but index EOAs.
        downlineAA = aaFac.beamioAccountOf(downlineEOA);
        refereeAA = aaFac.beamioAccountOf(refereeEOA);
        if (downlineAA == address(0) || !aaFac.isBeamioAccount(downlineAA)) revert UC_NoBeamioAccount();
        if (refereeAA == address(0) || !aaFac.isBeamioAccount(refereeAA)) revert UC_NoBeamioAccount();

        ReferrerStorage.Layout storage r = ReferrerStorage.layout();

        // Idempotency / immutability: EOA key (canonical) + legacy AA key (pre-EOA-index binds).
        address existingEoa = r.referrerOfReferee[downlineEOA];
        if (existingEoa != address(0)) {
            if (existingEoa != refereeEOA) revert UC_RefereeReferrerAlreadySet(downlineEOA, existingEoa);
            emit ShareRefereeBoundWithSignature(downlineEOA, refereeEOA, downlineAA, refereeAA, nonce);
            return (downlineAA, refereeAA);
        }
        address existingLegacyAa = r.referrerOfReferee[downlineAA];
        if (existingLegacyAa != address(0)) {
            // Already bound under legacy AA index — treat as immutable (do not rewrite).
            if (existingLegacyAa != refereeAA && existingLegacyAa != refereeEOA) {
                revert UC_RefereeReferrerAlreadySet(downlineAA, existingLegacyAa);
            }
            emit ShareRefereeBoundWithSignature(downlineEOA, refereeEOA, downlineAA, refereeAA, nonce);
            return (downlineAA, refereeAA);
        }

        if (!r.isReferee[refereeEOA]) {
            r.isReferee[refereeEOA] = true;
            ReferrerRegistryLib.onRegisterReferee(r, refereeEOA);
        }
        if (!r.isReferee[downlineEOA]) {
            r.isReferee[downlineEOA] = true;
            ReferrerRegistryLib.onRegisterReferee(r, downlineEOA);
        }
        if (r.referrerOfReferee[refereeEOA] == downlineEOA) revert UC_RefereeReferrerCycle(downlineEOA, refereeEOA);
        ReferrerRegistryLib.onSetRefereeReferrer(r, downlineEOA, refereeEOA);
        emit ShareRefereeBoundWithSignature(downlineEOA, refereeEOA, downlineAA, refereeAA, nonce);
    }
}
