// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./FaucetStorage.sol";

/// @dev Factory gateway 专用轻量接口，避免 import 完整 BeamioUserCard 增大 Factory bytecode
interface IBeamioUserCardForFactory {
    function factoryGateway() external view returns (address);
    function currency() external view returns (uint8);
    function pointsUnitPriceInCurrencyE6() external view returns (uint256);
    function owner() external view returns (address);
    function isAdmin(address account) external view returns (bool);
    function adminParent(address admin) external view returns (address);

    function appendTier(uint256 minUsdc6, uint256 attr, uint256 tierExpirySeconds) external;

    function redeemByGateway(string calldata code, address userEOA) external;
    function redeemBatchByGateway(string[] calldata codes, address userEOA) external;
    function redeemPoolByGateway(string calldata code, address userEOA) external;
    function redeemAdminByGateway(string calldata code, address to) external;

    function mintPointsByGatewayWithOperator(address fromEOA, uint256 points6, address operator) external;
    function faucetConfig(uint256 id) external view returns (FaucetStorage.FaucetConfig memory);
    function issuedNftPriceInCurrency6(uint256 tokenId) external view returns (uint256);
    function mintFaucetByGateway(address userEOA, uint256 id, uint256 amount6) external;
    function mintIssuedNftByGateway(address userEOA, uint256 tokenId, uint256 amount) external;
    function mintIssuedNftByUserSigClaim(address userEOA, uint256 tokenId) external;
    function recordSocialExchangeUsdcClaim(address userEOA, uint256 tokenId) external;
    function burnSocialPointsForExchange(address userEOA, uint256 pointsCost) external;
    function payoutSocialExchangeUsdc(address userEOA, uint256 usdcReward6) external;
    function fundSocialExchangeUsdcEscrow(address payerEOA, uint256 amount6) external;
    function purchaseIssuedNftWithPointsCharge(address userEOA, uint256 tokenId, uint256 amount, address payee) external;

    function clearAdminMintCounterForSubordinate(address subordinate, address authorizer) external;
    function resetAdminLimitByAdmin(address adminAddr, address signer) external;
    function mintPointsByAdminWithOperator(address user, uint256 points6, address operator) external;
    function recordAdminBurnForStats(address admin, uint256 amount) external;
}
