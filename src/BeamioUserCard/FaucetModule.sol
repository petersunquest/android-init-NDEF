// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./FaucetStorage.sol";
import "./BeamioERC1155Logic.sol";

interface IUserCardCtx {
    function owner() external view returns (address);
    function factoryGateway() external view returns (address);
}

/**
 * @title BeamioUserCardFaucetModuleV1
 * @notice Delegatecall module for faucet config and claim recording. Card does _mint after delegatecall.
 */
contract BeamioUserCardFaucetModuleV1 {

    uint8 private constant POINTS_DECIMALS = BeamioERC1155Logic.POINTS_DECIMALS;

    event FaucetConfigUpdated(uint256 indexed id, FaucetStorage.FaucetConfig cfg);
    event FaucetClaimed(uint256 indexed id, address indexed userEOA, address indexed acct, uint256 amount, uint256 claimedAfter);

    modifier onlyGateway() {
        address gw = IUserCardCtx(address(this)).factoryGateway();
        if (msg.sender != gw) revert UC_UnauthorizedGateway();
        _;
    }

    function _validateFaucetConfig(FaucetStorage.FaucetConfig memory cfg) internal pure {
        if (!cfg.enabled && cfg.validUntil == 0) revert UC_FaucetConfigInvalid();
        if (cfg.decimals != POINTS_DECIMALS) revert UC_FaucetConfigInvalid();
        if (cfg.perClaimMax == 0) revert UC_FaucetConfigInvalid();
        if (cfg.maxPerUser == 0 || cfg.maxGlobal == 0) revert UC_FaucetConfigInvalid();
    }

    function setFaucetConfig(
        uint256 id,
        uint64 validUntil,
        uint64 perClaimMax,
        uint128 maxPerUser,
        uint128 maxGlobal,
        bool enabled,
        uint8 currency,
        uint128 priceInCurrency6
    ) external onlyGateway {
        FaucetStorage.Layout storage l = FaucetStorage.layout();
        if (l.faucetConfigFrozen[id]) revert UC_FaucetConfigFrozen();

        FaucetStorage.FaucetConfig storage cfg = l.faucetConfig[id];
        cfg.validUntil = validUntil;
        cfg.perClaimMax = perClaimMax;
        cfg.maxPerUser = maxPerUser;
        cfg.maxGlobal = maxGlobal;
        cfg.enabled = enabled;
        cfg.currency = currency;
        cfg.decimals = POINTS_DECIMALS;
        cfg.priceInCurrency6 = priceInCurrency6;

        _validateFaucetConfig(cfg);
        l.faucetConfigFrozen[id] = true;

        emit FaucetConfigUpdated(id, cfg);
    }

    /// @notice Validate and record free faucet claim; card mints after.
    function validateAndRecordFreeFaucet(address userEOA, uint256 id, uint256 amount)
        external
        onlyGateway
        returns (uint256 outId, uint256 outAmount)
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (amount == 0) revert UC_AmountZero();

        FaucetStorage.Layout storage l = FaucetStorage.layout();
        FaucetStorage.FaucetConfig storage cfg = l.faucetConfig[id];
        if (!cfg.enabled) revert UC_FaucetNotEnabled();
        if (block.timestamp > cfg.validUntil) revert UC_FaucetExpired();
        if (amount > cfg.perClaimMax) revert UC_FaucetAmountTooLarge();
        if (cfg.priceInCurrency6 != 0) revert UC_FaucetDisabledBecausePriced();

        address card = address(this);
        if (!IBeamioFactoryOracle(IUserCardCtx(card).factoryGateway()).isTokenIdIssued(card, id)) revert UC_FaucetIdNotIssued();

        if (l.faucetClaimed[id][userEOA] + amount > cfg.maxPerUser) revert UC_FaucetMaxExceeded();
        if (l.faucetGlobalMinted[id] + amount > cfg.maxGlobal) revert UC_FaucetGlobalMaxExceeded();

        l.faucetClaimed[id][userEOA] += amount;
        l.faucetGlobalMinted[id] += amount;

        return (id, amount);
    }

    /// @notice Validate and record paid faucet mint; card mints after.
    function validateAndRecordPaidFaucet(address userEOA, uint256 id, uint256 amount6)
        external
        onlyGateway
        returns (uint256 outId, uint256 outAmount)
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (amount6 == 0) revert UC_AmountZero();

        FaucetStorage.Layout storage l = FaucetStorage.layout();
        FaucetStorage.FaucetConfig storage cfg = l.faucetConfig[id];
        if (!cfg.enabled) revert UC_FaucetNotEnabled();
        if (block.timestamp > cfg.validUntil) revert UC_FaucetExpired();
        if (amount6 > cfg.perClaimMax) revert UC_FaucetAmountTooLarge();
        if (cfg.priceInCurrency6 == 0) revert UC_PurchaseDisabledBecauseFree();

        address card = address(this);
        if (!IBeamioFactoryOracle(IUserCardCtx(card).factoryGateway()).isTokenIdIssued(card, id)) revert UC_FaucetIdNotIssued();

        if (l.faucetClaimed[id][userEOA] + amount6 > cfg.maxPerUser) revert UC_FaucetMaxExceeded();
        if (l.faucetGlobalMinted[id] + amount6 > cfg.maxGlobal) revert UC_FaucetGlobalMaxExceeded();

        l.faucetClaimed[id][userEOA] += amount6;
        l.faucetGlobalMinted[id] += amount6;

        return (id, amount6);
    }
}
