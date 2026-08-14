// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TreasuryDeveloperFxLib
 * @notice External library for DeveloperFxIssuer issue path (EIP-170 friendly).
 * @dev Linked via DELEGATECALL — `msg.sender` on outbound calls is the Issuer.
 */

interface IDeveloperTokenStakeViewLib {
    function developerCnetStake() external view returns (uint256);
}

interface IDeveloperTokenStakeAdminLib {
    function bindDeveloperStakeTreasury(address treasury_) external;
}

interface IDeveloperTokenFxRegistryLib {
    function registerDeveloperApp(
        address token,
        address developer,
        uint256 gbPerFullToken,
        uint64 expiresAt,
        uint8 kind,
        bool enabled
    ) external returns (uint256 passTokenId);
}

interface IDepinGbSettlementTreasuryLib {
    function registerFxPassFromTreasury(
        uint256 tokenId,
        address developer,
        uint8 kind,
        uint64 expiresAt,
        address erc20
    ) external;
}

interface IERC20TransferFromLib {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

library TreasuryDeveloperFxLib {
    error InvalidPolicy();
    error InvalidAmount();
    error InsufficientDeveloperStake();
    error DeveloperDeployFeeFailed();

    /**
     * @param feeRecipient Treasury that receives the one-time conet-USDC deploy fee
     * @param stakePolicy Issuer address bound on the token for min-stake / gas-refund reads
     */
    function issueAndRegister(
        address registry,
        address settlement,
        address feeAsset,
        address feeRecipient,
        address stakePolicy,
        uint256 minStakeWei,
        uint256 deployFeeUsdc6,
        address token,
        address developer,
        uint256 gbPerFullToken,
        uint64 expiresAt,
        uint8 passKind,
        bool enabled
    ) external returns (uint256 passTokenId, uint256 stakeWei) {
        if (token == address(0) || developer == address(0) || stakePolicy == address(0)) {
            revert InvalidPolicy();
        }
        if (registry == address(0) || settlement == address(0) || feeAsset == address(0) || feeRecipient == address(0))
        {
            revert InvalidPolicy();
        }
        if (expiresAt == 0 || minStakeWei == 0 || deployFeeUsdc6 == 0) revert InvalidAmount();

        IDeveloperTokenStakeAdminLib(token).bindDeveloperStakeTreasury(stakePolicy);
        stakeWei = IDeveloperTokenStakeViewLib(token).developerCnetStake();
        if (stakeWei < minStakeWei) revert InsufficientDeveloperStake();

        if (!IERC20TransferFromLib(feeAsset).transferFrom(developer, feeRecipient, deployFeeUsdc6)) {
            revert DeveloperDeployFeeFailed();
        }

        passTokenId = IDeveloperTokenFxRegistryLib(registry).registerDeveloperApp(
            token, developer, gbPerFullToken, expiresAt, passKind, enabled
        );
        IDepinGbSettlementTreasuryLib(settlement).registerFxPassFromTreasury(
            passTokenId, developer, passKind, expiresAt, token
        );
    }
}
