// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./IssuedNftStorage.sol";
import "./BeamioERC1155Logic.sol";
import "./BeamioUserCardInterfaces.sol";
import "./BeamioUserCardModuleKinds.sol";
import "./IBeamioUserCardSelfDelegate.sol";

library BeamioUserCardIssuedNftGatewayLib {
    uint256 internal constant POINTS_ID = BeamioERC1155Logic.POINTS_ID;
    uint256 internal constant POINTS_ONE = 1_000_000;
    uint8 internal constant MODULE_ISSUED_NFT = BeamioUserCardModuleKinds.ISSUED_NFT;

    function mintIssuedNftByUserSigClaim(IBeamioUserCardSelfDelegate delegate, address userEOA, uint256 tokenId)
        external
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        address acct = delegate.cardSelfToAccount(userEOA);
        delegate.cardSelfCallModule(
            MODULE_ISSUED_NFT,
            abi.encodeWithSelector(
                IBeamioIssuedNftModuleV1.validateAndRecordMintIssuedNftUserSigClaim.selector,
                userEOA,
                acct,
                tokenId
            )
        );
        delegate.cardSelfMint(acct, tokenId, 1);
        delegate.cardSelfEmitIssuedNftMinted(tokenId, acct, 1);
    }

    function mintIssuedNftByGateway(IBeamioUserCardSelfDelegate delegate, address userEOA, uint256 tokenId, uint256 amount)
        external
    {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (amount == 0) revert UC_AmountZero();
        address acct = delegate.cardSelfToAccount(userEOA);
        mintIssuedNftChecked(delegate, acct, tokenId, amount);
    }

    function purchaseIssuedNftWithPointsCharge(
        IBeamioUserCardSelfDelegate delegate,
        address userEOA,
        uint256 tokenId,
        uint256 amount,
        address payeeEOA,
        uint256 pointsUnitPriceInCurrencyE6
    ) external {
        if (userEOA == address(0) || payeeEOA == address(0)) revert BM_ZeroAddress();
        if (amount == 0) revert UC_AmountZero();

        uint256 unitPrice = IssuedNftStorage.layout().issuedNftPriceInCurrency6[tokenId];
        if (unitPrice == 0) revert UC_PurchaseDisabledBecauseFree();
        requireIssuedNftValid(tokenId);

        uint256 totalPriceInCurrency6 = amount * unitPrice;
        uint256 points6 = _ceilPointsForCurrencyAmount(totalPriceInCurrency6, pointsUnitPriceInCurrencyE6);
        if (points6 == 0) revert UC_AmountZero();

        address payerAcct = delegate.cardSelfToAccount(userEOA);
        address payeeAcct = delegate.cardSelfToAccount(payeeEOA);
        if (payerAcct == payeeAcct) revert BM_NotAuthorized();

        delegate.cardSelfTransferPointsUpdate(payerAcct, payeeAcct, points6);
        mintIssuedNftChecked(delegate, payerAcct, tokenId, amount);
        delegate.cardSelfEmitIssuedNftPurchasedWithPointsCharge(
            userEOA, payeeEOA, tokenId, amount, totalPriceInCurrency6, points6
        );
    }

    function mintIssuedNftChecked(IBeamioUserCardSelfDelegate delegate, address acct, uint256 tokenId, uint256 amount)
        public
    {
        delegate.cardSelfCallModule(
            MODULE_ISSUED_NFT,
            abi.encodeWithSelector(IBeamioIssuedNftModuleV1.validateAndRecordMintIssuedNft.selector, acct, tokenId, amount)
        );
        delegate.cardSelfMint(acct, tokenId, amount);
        delegate.cardSelfEmitIssuedNftMinted(tokenId, acct, amount);
    }

    function quoteIssuedNftPurchasePoints6(uint256 tokenId, uint256 amount, uint256 pointsUnitPriceInCurrencyE6)
        external
        view
        returns (uint256 points6, uint256 totalPriceInCurrency6)
    {
        if (amount == 0) revert UC_AmountZero();
        uint256 unitPrice = IssuedNftStorage.layout().issuedNftPriceInCurrency6[tokenId];
        if (unitPrice == 0) revert UC_PurchaseDisabledBecauseFree();
        totalPriceInCurrency6 = amount * unitPrice;
        points6 = _ceilPointsForCurrencyAmount(totalPriceInCurrency6, pointsUnitPriceInCurrencyE6);
    }

    function requireIssuedNftValid(uint256 tokenId) public view {
        (bool ok, bytes memory ret) = address(this).staticcall(
            abi.encodeWithSelector(IBeamioIssuedNftModuleV1.isIssuedNftValid.selector, tokenId)
        );
        if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) revert UC_IssuedNftInactive(tokenId);
    }

    function _ceilPointsForCurrencyAmount(uint256 amountInCurrency6, uint256 pointsUnitPriceInCurrencyE6)
        private
        pure
        returns (uint256 points6)
    {
        if (pointsUnitPriceInCurrencyE6 == 0) revert UC_PriceNotConfigured();
        points6 = (amountInCurrency6 * POINTS_ONE + pointsUnitPriceInCurrencyE6 - 1) / pointsUnitPriceInCurrencyE6;
    }
}
