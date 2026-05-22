// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BeamioUserCardTypes.sol";

/// @dev Self-call hooks for external runtime libraries (msg.sender must be address(this)).
interface IBeamioUserCardSelfDelegate {
    function cardSelfMint(address to, uint256 id, uint256 amount) external;
    function cardSelfCallModule(uint8 kind, bytes calldata data) external returns (bytes memory);
    function cardSelfGovernanceDelegate(address module, bytes calldata data) external returns (bool);
    function cardSelfAppendMembershipNftIfMissing(address acct, uint256 id) external;
    function cardSelfMembershipFlowTotals() external view returns (uint256 issued, uint256 upgraded);
    function cardSelfRecordAdminMembershipFlow(address operator, uint256 issuedBefore, uint256 upgradedBefore)
        external;
    function cardSelfRequirePointsMintAllowsFirstMembership(address acct, uint256 points6) external view;
    function cardSelfHasValidCard(address acct) external view returns (bool);
    function cardSelfToAccount(address eoa) external view returns (address);
    function cardSelfOwner() external view returns (address);
    function cardSelfUpgradeType() external view returns (uint8);
    function cardSelfPointsUnitPriceInCurrencyE6() external view returns (uint256);
    function cardSelfCurrencyType() external view returns (uint8);
    function cardSelfEmitChargeRewardAirdropped(
        address userEOA,
        address acct,
        uint8 chargeCurrency,
        uint256 amountFiat6,
        uint256 reward
    ) external;
    function cardSelfTransferPointsUpdate(address from, address to, uint256 amount) external;
    function cardSelfRecordAdminRedeemMint(address operator, uint256 amount) external;
    function cardSelfRecordAdminUsdcMint(address operator, uint256 amount) external;
    function cardSelfRecordAdminStatsMint(address operator, uint256 amount) external;
    function cardSelfEmitFaucetClaimed(uint256 id, address userEOA, address acct, uint256 amount, uint256 claimedAfter)
        external;
    function cardSelfEmitPointsMintedByGateway(address userEOA, address acct, uint256 points6) external;
    function cardSelfEmitAdminPointsMinted(address acct, uint256 points6) external;
    function cardSelfEmitIssuedNftMinted(uint256 tokenId, address acct, uint256 amount) external;
    function cardSelfEmitReferrerRewardMinted(address refereeAA, address referrerAA, uint256 rewardAmount) external;
    function cardSelfEmitIssuedNftPurchasedWithPointsCharge(
        address userEOA,
        address payeeEOA,
        uint256 tokenId,
        uint256 amount,
        uint256 totalPriceInCurrency6,
        uint256 pointsCharged6
    ) external;
}
