// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TreasuryDeveloperFxLib} from "./TreasuryDeveloperFxLib.sol";

/**
 * @title DeveloperFxIssuer
 * @notice Issues treasury Canonical developer FX tokens: deploy fee + CNET stake + Settlement register.
 * @dev Kept separate from TreasuryBridgeV3 (EIP-170). Token `developerStakeTreasury` points here
 *      for min-stake / miner-gas policy. TreasuryBridgeV3 only checks `isForwardAllowed`.
 */

interface ITreasuryAssetKindIssuer {
    function setTreasuryAssetKindCanonical(address token) external;
}

contract DeveloperFxIssuer is Ownable {
    address public treasury;
    address public registry;
    address public settlement;
    address public deployFeeAsset;

    uint256 public developerTokenMinStakeWei;
    uint256 public developerTokenMinerGasRefundWei;
    uint256 public developerTokenDeployFeeUsdc6;

    mapping(address => bool) public isDeveloperFxToken;

    event WiringUpdated(address indexed treasury, address indexed registry, address indexed settlement);
    event DeployFeeAssetUpdated(address indexed asset);
    event EconomicsUpdated(uint256 minStakeWei, uint256 minerGasRefundWei, uint256 deployFeeUsdc6);
    event DeveloperFxTokenMarked(address indexed token, bool enabled);
    event DeveloperFxIssuedAndRegistered(
        address indexed token,
        address indexed developer,
        uint256 indexed passTokenId,
        uint256 gbPerFullToken,
        uint8 passKind,
        uint64 expiresAt,
        uint256 deployFeeUsdc6,
        uint256 stakeWei
    );

    error ZeroAddress();
    error InvalidAmount();
    error NotWired();

    constructor(address owner_) Ownable(owner_) {}

    function setWiring(address treasury_, address registry_, address settlement_) external onlyOwner {
        if (treasury_ == address(0) || registry_ == address(0) || settlement_ == address(0)) {
            revert ZeroAddress();
        }
        treasury = treasury_;
        registry = registry_;
        settlement = settlement_;
        emit WiringUpdated(treasury_, registry_, settlement_);
    }

    function setDeployFeeAsset(address asset) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        deployFeeAsset = asset;
        emit DeployFeeAssetUpdated(asset);
    }

    function setEconomics(uint256 minStakeWei, uint256 minerGasRefundWei, uint256 deployFeeUsdc6)
        external
        onlyOwner
    {
        if (minStakeWei == 0 || deployFeeUsdc6 == 0) revert InvalidAmount();
        developerTokenMinStakeWei = minStakeWei;
        developerTokenMinerGasRefundWei = minerGasRefundWei;
        developerTokenDeployFeeUsdc6 = deployFeeUsdc6;
        emit EconomicsUpdated(minStakeWei, minerGasRefundWei, deployFeeUsdc6);
    }

    function setDeveloperFxToken(address token, bool enabled) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        isDeveloperFxToken[token] = enabled;
        emit DeveloperFxTokenMarked(token, enabled);
    }

    /// @notice Alias for Settlement / Canonical policy readers.
    function depinGbSettlement() external view returns (address) {
        return settlement;
    }

    /**
     * @notice Non-developer tokens always allowed; developer FX requires live CNET stake ≥ min.
     */
    function isForwardAllowed(address token) external view returns (bool) {
        if (!isDeveloperFxToken[token]) return true;
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("isTreasuryQualified()"));
        return ok && data.length >= 32 && abi.decode(data, (bool));
    }

    /**
     * @notice Atomic issue: stake bind + min stake check + USDC deploy fee → treasury + FX/Settlement register.
     * @param passKind 2=PayByUse, 3=Subscription, 4=Dual
     */
    function issueDeveloperFxAndRegister(
        address token,
        address developer,
        uint256 gbPerFullToken,
        uint64 expiresAt,
        uint8 passKind,
        bool enabled
    ) external onlyOwner returns (uint256 passTokenId) {
        if (treasury == address(0) || registry == address(0) || settlement == address(0)) revert NotWired();
        if (deployFeeAsset == address(0)) revert NotWired();

        uint256 fee = developerTokenDeployFeeUsdc6;
        uint256 stakeWei;
        (passTokenId, stakeWei) = TreasuryDeveloperFxLib.issueAndRegister(
            registry,
            settlement,
            deployFeeAsset,
            treasury,
            address(this),
            developerTokenMinStakeWei,
            fee,
            token,
            developer,
            gbPerFullToken,
            expiresAt,
            passKind,
            enabled
        );

        try ITreasuryAssetKindIssuer(treasury).setTreasuryAssetKindCanonical(token) {} catch {}

        isDeveloperFxToken[token] = true;
        emit DeveloperFxIssuedAndRegistered(
            token, developer, passTokenId, gbPerFullToken, passKind, expiresAt, fee, stakeWei
        );
    }
}
