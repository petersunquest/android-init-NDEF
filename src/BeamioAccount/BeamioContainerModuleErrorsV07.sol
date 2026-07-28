// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Shared by BeamioContainerModuleV07 and BeamioContainerModuleExternalLibV07.
error CM_ToZero();
error CM_Expired(uint256 nowTs, uint256 deadline);
error CM_BadNonce(uint256 got, uint256 expected);
error CM_BadSigLen(uint256 got);
error CM_SignerNotOwner(address signer, address owner);

error CM_EmptyItems();
error CM_ItemAssetZero(uint256 i);
error CM_UnsupportedKind(uint256 i);
error CM_ERC20HasTokenIdOrData(uint256 i);
error CM_ERC1155TokenIdNotZero(uint256 i, uint256 tokenId);

error CM_NoFactory();
error CM_NoQuoteHelper();
error CM_NoUSDC();
error CM_NoUserCard();
error CM_ERC1155NotUserCard(uint256 i, address token, address userCard);
error CM_TokenNotUSDC(address token, address usdc);

error CM_UnitPriceZero();
error CM_ExceedsMaxDetailed(uint256 totalUsdc6, uint256 cardValueUsdc6, uint256 maxUsdc6);
error CM_MaxAmountTooSmall(uint256 maxAmount);

error CM_OpenTopupNotMixed();
error CM_OpenTopupNoExecutor();
error CM_OpenTopupZeroOut();

error CM_ReservedERC20Violation(address token, uint256 spend, uint256 bal, uint256 reserved);
error CM_Reserved1155Violation(address token, uint256 id, uint256 spend, uint256 bal, uint256 reserved);

error CM_ERC20TransferFailed(address token, address to, uint256 amount);
error CM_ERC1155TransferFailed(address token, address to);

error RD_ZeroPasswordHash();
error RD_AlreadyExists(bytes32 passwordHash);
error RD_NotFound(bytes32 passwordHash);
error RD_AlreadyUsed(bytes32 passwordHash);
error RD_Expired(bytes32 passwordHash);
error RD_BadPassword();
error RD_PresetToMismatch(address to, address presetTo);

error FP_ZeroPasswordHash();
error FP_InvalidTotalCount();
error FP_AlreadyExists(bytes32 passwordHash);
error FP_NotFound(bytes32 passwordHash);
error FP_Expired(bytes32 passwordHash);
error FP_OutOfStock(bytes32 passwordHash);
error FP_AlreadyClaimed(bytes32 passwordHash, address to);
error FP_ToMustEqualClaimer();
error FP_ItemsMismatch();

error CM_OnlyDelegatecall();

error RS_BeneficiaryZero();
error RS_CancelWindowZero();
error RS_CancelWindowTooLong();
error RS_BadIndex(address beneficiary, uint256 index, uint256 len);
error RS_NotFound(uint256 id);
error RS_BadStatus(uint256 id, uint8 got, uint8 need);
error RS_CancelDeadlinePassed(uint64 deadline, uint256 nowTs);
error RS_CancelNotYetExpired(uint64 deadline, uint256 nowTs);
error RS_NotBeneficiary(address caller, address beneficiary);
error RS_NotOwner(address caller, address owner_);
