// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* =========================================================
   Beamio: unified errors with prefixes
   Rule: DO NOT redeclare these errors anywhere else.
   ========================================================= */

// -------- Common --------
error BM_ZeroAddress();
error BM_NotAuthorized();
error BM_CallFailed();
error BM_InvalidSecret();
error BM_DeployFailed();
/// @notice createCard 失败时冒泡步骤：0=CREATE 失败，1=gateway 不匹配，2=owner 不匹配，3=currency 不匹配，4=price 不匹配
error BM_DeployFailedAtStep(uint8 step);
/// @notice 若用 try new Contract() catch (bytes reason) 时可冒泡 constructor 的 revert 原因
error BM_DeployFailedWithReason(bytes reason);
/// @notice `subject` 已登记为另一张 BeamioUserCard 的 admin；须先在该卡上以 adminManager(..., false) 移除后，方可登记为其他卡的 admin
error BM_ExclusiveAdminBoundToOtherCard(address subject, address boundCard);
error UC_TiersNotDecreasing();

// -------- ERC1155 / UserCard (UC_) --------
error UC_OwnerLocked();
error UC_OwnerCannotBeRemoved();
error UC_AdminManagerRequiresOwnerSignature();
error UC_OnlyParentCanRemoveAdmin(address adminToRemove, address requiredParent);
error UC_NotAdmin();
error UC_AdminDepthExceeded(address admin);
error UC_AdminAirdropLimitExceeded(address admin, uint256 used, uint256 requested, uint256 limit);
error UC_AdminAirdropLimitTooHigh(address admin, uint256 limit, uint256 maxAllowed);
error UC_UnauthorizedGateway();
error UC_OpenMintExecutorUnauthorized();
error UC_AmountZero();
error UC_InvalidProposal();
error UC_NonceUsed();
error UC_PoolAlreadyClaimed(bytes32 poolHash, address user);

error DEP_NotOwner();
error DEP_InvalidFactory();

// membership / tiers
error UC_AlreadyHasValidCard();
error UC_TierLenMismatch();
error UC_TierMinZero();
error UC_InvalidUpgradeType();
error UC_TiersNotIncreasing();
error UC_MustGrow();
error UC_PriceZero();
error UC_PointsZero();
error UC_Slippage();
error UC_BelowMinThreshold();
error UC_PointsToNotWhitelisted();
error UC_BeneficiaryMustBeAA();
error UC_SBTNonTransferable();
error UC_RedeemModuleZero();
error UC_StatsModuleZero();
error UC_RedeemDelegateFailed(bytes data);
error UC_GlobalMisconfigured();
error UC_NoBeamioAccount();

// faucet
error UC_FaucetNotEnabled();
error UC_FaucetExpired();
error UC_FaucetAmountTooLarge();
error UC_FaucetMaxExceeded();
error UC_FaucetConfigInvalid();
error UC_FaucetGlobalMaxExceeded();
error UC_FaucetConfigFrozen();
error UC_FaucetIdNotIssued();
error UC_FaucetDisabledBecausePriced();
error UC_PurchaseDisabledBecauseFree();
error UC_PriceNotConfigured();

// -------- QuoteHelper (QH_) --------
error QH_OracleError();

// -------- Deployer (DEP_) --------
error DEP_NotFactory();

// -------- Factory/Paymaster (F_) --------
error F_InvalidRedeemHash();
error F_BadDeployedCard();
error F_AlreadyRegistered();

// -------- GatewayExecutor (GX_) --------
error GX_SecretUsed();

/**
UC_ResolveAccountFailed 里把 aaFactory/acct 带出来，外部就能判断是 “aaFactory 配错 / account 未部署 / mapping 不存在”。
UC_InsufficientBalance 能直接告诉你余额差多少。
 */
error UC_InvalidTokenId(uint256 got, uint256 expected);
error UC_InvalidSignature(address recovered, address expected);
error UC_InvalidTimeWindow(uint256 nowTs, uint256 validAfter, uint256 validBefore);
error UC_InvalidDateRange(uint64 validAfter, uint64 validBefore);
error UC_ResolveAccountFailed(address eoa, address aaFactory, address acct);
error UC_InsufficientBalance(address fromAccount, uint256 id, uint256 have, uint256 need);
/// @dev User EIP-712 free claim cannot mint if series has paid list price (>0 purchase path).
error UC_IssuedNftSigClaimNotFree(uint256 tokenId, uint256 priceInCurrency6);
/// @dev At most one free signed claim per (userEOA, issued tokenId).
error UC_IssuedNftSigClaimAlreadyUsed(address userEOA, uint256 tokenId);
/// @dev issued series outside validAfter/validBefore or unknown id (isIssuedNftValid false)
error UC_IssuedNftInactive(uint256 tokenId);