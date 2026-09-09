// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./ReferrerStorage.sol";
import "./ReferrerRegistryLib.sol";
import "./IBeamioUserCardSelfDelegate.sol";

interface IERC1155BalanceView {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface IReferrerLibUserCardGw {
    function factoryGateway() external view returns (address);
}

interface IReferrerLibFactoryAa {
    function aaFactory() external view returns (address);
}

interface IReferrerLibAaFactory {
    function isBeamioAccount(address account) external view returns (bool);
    function beamioAccountOf(address eoa) external view returns (address);
}

/// @dev Referrer registry, pagination views, and #13 reward minting (external library).
/// @dev Canonical registry keys are EOAs; AA keys remain readable for legacy binds.
/// @dev Token #13 is always minted to the referrer's Beamio AA (never EOA).
library BeamioUserCardReferrerLib {
    /// @dev Unified reward points (#13). Legacy #1 balances remain on-chain but are not minted here.
    uint256 internal constant REFERRER_REWARD_TOKEN_ID = 13;
    uint256 internal constant REWARD_RATIO_ONE_E6 = 1_000_000;
    uint8 internal constant LEDGER_KIND_TOPUP = 1;
    uint8 internal constant LEDGER_KIND_CHARGE = 2;

    function registerReferee(address refereeEOA) external {
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        if (r.isReferee[refereeEOA]) revert UC_RefereeAlreadyRegistered(refereeEOA);
        r.isReferee[refereeEOA] = true;
        ReferrerRegistryLib.onRegisterReferee(r, refereeEOA);
    }

    function unregisterReferee(address refereeEOA) external {
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        if (!r.isReferee[refereeEOA]) revert UC_RefereeNotRegistered(refereeEOA);
        delete r.isReferee[refereeEOA];
        ReferrerRegistryLib.onUnregisterReferee(r, refereeEOA);
    }

    function setRefereeReferrer(address refereeEOA, address referrerEOA) external {
        if (refereeEOA == referrerEOA) revert UC_RefereeSelfReferrer(refereeEOA);
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        if (!r.isReferee[refereeEOA]) revert UC_RefereeNotRegistered(refereeEOA);
        if (!r.isReferee[referrerEOA]) revert UC_ReferrerNotRegistered(referrerEOA);
        if (r.referrerOfReferee[referrerEOA] == refereeEOA) revert UC_RefereeReferrerCycle(refereeEOA, referrerEOA);
        ReferrerRegistryLib.onSetRefereeReferrer(r, refereeEOA, referrerEOA);
    }

    function clearRefereeReferrer(address refereeEOA) external {
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        if (!r.isReferee[refereeEOA]) revert UC_RefereeNotRegistered(refereeEOA);
        ReferrerRegistryLib.onClearRefereeReferrer(r, refereeEOA);
    }

    function getReferrersPage(uint256 offset, uint256 pageSize)
        external
        view
        returns (address[] memory referrers, uint256[] memory referrerRewardBalances, uint256 total, uint256 nextOffset)
    {
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        (referrers, total, nextOffset) = ReferrerRegistryLib.getReferrersPage(r, offset, pageSize);
        referrerRewardBalances = new uint256[](referrers.length);
        for (uint256 i = 0; i < referrers.length; i++) {
            address holder = _beamioAaOrZero(referrers[i]);
            if (holder == address(0)) holder = referrers[i];
            referrerRewardBalances[i] =
                IERC1155BalanceView(address(this)).balanceOf(holder, REFERRER_REWARD_TOKEN_ID);
        }
    }

    function getRefereesByReferrerPage(address referrerEOA, uint256 offset, uint256 pageSize)
        external
        view
        returns (address[] memory referees, uint256[] memory refereeChargeTotals6, uint256 total, uint256 nextOffset)
    {
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        (referees, total, nextOffset) = ReferrerRegistryLib.getRefereesByReferrerPage(r, referrerEOA, offset, pageSize);
        if (total == 0) {
            address aa = _aaOfMaybeEoa(referrerEOA);
            if (aa != referrerEOA) {
                (referees, total, nextOffset) = ReferrerRegistryLib.getRefereesByReferrerPage(r, aa, offset, pageSize);
            }
        }
        refereeChargeTotals6 = new uint256[](referees.length);
        for (uint256 i = 0; i < referees.length; i++) {
            refereeChargeTotals6[i] = _chargePointsOf(r, referees[i]);
        }
    }

    function getRegisteredRefereesPage(uint256 offset, uint256 pageSize)
        external
        view
        returns (address[] memory referees, uint256 total, uint256 nextOffset)
    {
        return ReferrerRegistryLib.getRegisteredRefereesPage(ReferrerStorage.layout(), offset, pageSize);
    }

    function recordRefereeChargePoints(address payerAcct, uint256 pointsAmount) external {
        if (payerAcct == address(0) || pointsAmount == 0) return;
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        address key = _registryKeyForPayer(r, payerAcct);
        r.refereeChargePointsTotal6[key] += pointsAmount;
    }

    /// @notice Mint referrer #13 from **charge amountFiat6** when referee has an uplink.
    function mintReferrerRewardForChargeIfConfigured(
        IBeamioUserCardSelfDelegate delegate,
        address refereeAcct,
        uint256 amountFiat6
    ) external {
        _mintReferrerFromAmount(
            delegate,
            refereeAcct,
            amountFiat6,
            ReferrerStorage.layout().referrerRewardFromChargeRewardRatioE6,
            LEDGER_KIND_CHARGE
        );
    }

    /// @notice Mint referrer #13 from **top-up amountFiat6** when referee has an uplink.
    /// @dev Primary same-cycle path: `amountFiat6 × referrerRewardFromTopupAmountRatioE6` (Programs → Referrer Top-up %).
    function mintReferrerRewardForTopupIfConfigured(
        IBeamioUserCardSelfDelegate delegate,
        address refereeAcct,
        uint256 amountFiat6
    ) external {
        _mintReferrerFromAmount(
            delegate,
            refereeAcct,
            amountFiat6,
            ReferrerStorage.layout().referrerRewardFromTopupAmountRatioE6,
            LEDGER_KIND_TOPUP
        );
    }

    /// @notice Mint fixed #13 to uplink referrer AA (`refMint13` units).
    /// @dev Legacy / Social Promotion `getRewardRule(2)` helper. Same-cycle top-up referrer uses
    ///      `mintReferrerRewardForTopupIfConfigured` (ratio) instead — avoid dual-mint.
    /// @return mintToAa Referrer AA that received #13, or address(0) if skipped.
    function mintFixedTopupReward13ToReferrerIfAny(
        IBeamioUserCardSelfDelegate delegate,
        address refereeAcct,
        uint256 refMint13,
        uint256 amountFiat6
    ) external returns (address mintToAa) {
        if (refereeAcct == address(0) || refMint13 == 0) return address(0);
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        (address refereeKey, address referrerKey) = _resolveRefereeReferrer(r, refereeAcct);
        if (refereeKey == address(0) || referrerKey == address(0)) return address(0);
        if (!_isRegisteredReferee(r, refereeKey) || !_isRegisteredReferee(r, referrerKey)) return address(0);

        mintToAa = _beamioAaOrZero(referrerKey);
        if (mintToAa == address(0)) return address(0);
        delegate.cardSelfMint(mintToAa, REFERRER_REWARD_TOKEN_ID, refMint13);
        _accumulateLedger(r, referrerKey, refereeKey, LEDGER_KIND_TOPUP, amountFiat6, refMint13);
        delegate.cardSelfEmitReferrerRewardMinted(refereeKey, referrerKey, refMint13, amountFiat6, LEDGER_KIND_TOPUP);
    }

    /// @dev Alias for charge-amount path (legacy name; base is amountFiat6).
    function mintReferrerRewardIfConfigured(
        IBeamioUserCardSelfDelegate delegate,
        address refereeAcct,
        uint256 amountFiat6
    ) external {
        _mintReferrerFromAmount(
            delegate,
            refereeAcct,
            amountFiat6,
            ReferrerStorage.layout().referrerRewardFromChargeRewardRatioE6,
            LEDGER_KIND_CHARGE
        );
    }

    /// @notice Ledger for referrer UI: topup/charge[referrer][referee] cumulative #13 + fiat bases.
    function getReferrerRefereeLedger(address referrer, address referee)
        external
        view
        returns (
            uint256 topupReward13E6,
            uint256 chargeReward13E6,
            uint256 topupAmountFiat6,
            uint256 chargeAmountFiat6
        )
    {
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        address refKey = _canonicalLedgerKey(r, referrer);
        address eeKey = _canonicalLedgerKey(r, referee);
        ReferrerStorage.ReferrerRefereeLedger storage row = r.referrerRefereeLedger[refKey][eeKey];
        return (row.topupReward13E6, row.chargeReward13E6, row.topupAmountFiat6, row.chargeAmountFiat6);
    }

    function calcReferrerRewardFromChargeAmount(uint256 amountFiat6) public view returns (uint256) {
        return _calcFromRatio(amountFiat6, ReferrerStorage.layout().referrerRewardFromChargeRewardRatioE6);
    }

    function calcReferrerRewardFromTopupAmount(uint256 amountFiat6) public view returns (uint256) {
        return _calcFromRatio(amountFiat6, ReferrerStorage.layout().referrerRewardFromTopupAmountRatioE6);
    }

    /// @dev Backward-compatible name; now amountFiat6 × charge ratio.
    function calcReferrerRewardFromChargeReward(uint256 amountFiat6) public view returns (uint256) {
        return calcReferrerRewardFromChargeAmount(amountFiat6);
    }

    function referrerTotalCount() external view returns (uint256) {
        return ReferrerRegistryLib.referrerTotalCount(ReferrerStorage.layout());
    }

    function refereeCountByReferrer(address referrerEOA) external view returns (uint256) {
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        uint256 n = ReferrerRegistryLib.refereeCountByReferrer(r, referrerEOA);
        if (n != 0) return n;
        address aa = _aaOfMaybeEoa(referrerEOA);
        if (aa != referrerEOA) return ReferrerRegistryLib.refereeCountByReferrer(r, aa);
        return 0;
    }

    function registeredRefereeTotalCount() external view returns (uint256) {
        return ReferrerRegistryLib.registeredRefereeTotalCount(ReferrerStorage.layout());
    }

    /// @notice Uplink referrer for a referee (EOA or AA key; tries both).
    function refereeReferrer(address referee) external view returns (address) {
        (, address referrerKey) = _resolveRefereeReferrer(ReferrerStorage.layout(), referee);
        return referrerKey;
    }

    /// @notice Cumulative charge points (E6) attributed to a referee key (EOA/AA fallback).
    function refereeChargePointsTotal6(address referee) external view returns (uint256) {
        return _chargePointsOf(ReferrerStorage.layout(), referee);
    }

    function _mintReferrerFromAmount(
        IBeamioUserCardSelfDelegate delegate,
        address refereeAcct,
        uint256 amountFiat6,
        uint256 ratioE6,
        uint8 kind
    ) private {
        if (refereeAcct == address(0) || amountFiat6 == 0 || ratioE6 == 0) return;
        ReferrerStorage.Layout storage r = ReferrerStorage.layout();
        (address refereeKey, address referrerKey) = _resolveRefereeReferrer(r, refereeAcct);
        if (refereeKey == address(0) || referrerKey == address(0)) return;
        if (!_isRegisteredReferee(r, refereeKey) || !_isRegisteredReferee(r, referrerKey)) return;

        uint256 referrerReward = _calcFromRatio(amountFiat6, ratioE6);
        if (referrerReward == 0) return;

        address mintToAa = _beamioAaOrZero(referrerKey);
        if (mintToAa == address(0)) return;
        delegate.cardSelfMint(mintToAa, REFERRER_REWARD_TOKEN_ID, referrerReward);
        _accumulateLedger(r, referrerKey, refereeKey, kind, amountFiat6, referrerReward);
        delegate.cardSelfEmitReferrerRewardMinted(refereeKey, referrerKey, referrerReward, amountFiat6, kind);
    }

    function _accumulateLedger(
        ReferrerStorage.Layout storage r,
        address referrerKey,
        address refereeKey,
        uint8 kind,
        uint256 amountFiat6,
        uint256 reward13E6
    ) private {
        address refKey = _canonicalLedgerKey(r, referrerKey);
        address eeKey = _canonicalLedgerKey(r, refereeKey);
        ReferrerStorage.ReferrerRefereeLedger storage row = r.referrerRefereeLedger[refKey][eeKey];
        if (kind == LEDGER_KIND_TOPUP) {
            row.topupReward13E6 += reward13E6;
            row.topupAmountFiat6 += amountFiat6;
        } else if (kind == LEDGER_KIND_CHARGE) {
            row.chargeReward13E6 += reward13E6;
            row.chargeAmountFiat6 += amountFiat6;
        }
    }

    function _canonicalLedgerKey(ReferrerStorage.Layout storage r, address acct) private view returns (address) {
        if (acct == address(0)) return address(0);
        address eoa = _eoaOfMaybeAa(acct);
        if (r.isReferee[eoa] || r.referrerOfReferee[eoa] != address(0) || r.referrerAccountIndexPlusOne[eoa] != 0) {
            return eoa;
        }
        if (r.isReferee[acct] || r.referrerOfReferee[acct] != address(0) || r.referrerAccountIndexPlusOne[acct] != 0) {
            return acct;
        }
        return eoa;
    }

    function _calcFromRatio(uint256 amountFiat6, uint256 ratioE6) private pure returns (uint256) {
        if (amountFiat6 == 0 || ratioE6 == 0) return 0;
        return (amountFiat6 * ratioE6) / REWARD_RATIO_ONE_E6;
    }

    function _isRegisteredReferee(ReferrerStorage.Layout storage r, address key) private view returns (bool) {
        if (r.isReferee[key]) return true;
        address eoa = _eoaOfMaybeAa(key);
        if (eoa != key && r.isReferee[eoa]) return true;
        address aa = _aaOfMaybeEoa(key);
        if (aa != key && r.isReferee[aa]) return true;
        return false;
    }

    function _resolveRefereeReferrer(ReferrerStorage.Layout storage r, address refereeAcct)
        private
        view
        returns (address refereeKey, address referrerKey)
    {
        referrerKey = r.referrerOfReferee[refereeAcct];
        if (referrerKey != address(0)) return (refereeAcct, referrerKey);

        address eoa = _eoaOfMaybeAa(refereeAcct);
        if (eoa != refereeAcct) {
            referrerKey = r.referrerOfReferee[eoa];
            if (referrerKey != address(0)) return (eoa, referrerKey);
        }

        address aa = _aaOfMaybeEoa(refereeAcct);
        if (aa != refereeAcct) {
            referrerKey = r.referrerOfReferee[aa];
            if (referrerKey != address(0)) return (aa, referrerKey);
        }
        return (address(0), address(0));
    }

    function _registryKeyForPayer(ReferrerStorage.Layout storage r, address payerAcct) private view returns (address) {
        if (r.isReferee[payerAcct] || r.referrerOfReferee[payerAcct] != address(0)) return payerAcct;
        address eoa = _eoaOfMaybeAa(payerAcct);
        if (eoa != payerAcct && (r.isReferee[eoa] || r.referrerOfReferee[eoa] != address(0))) return eoa;
        return payerAcct;
    }

    function _chargePointsOf(ReferrerStorage.Layout storage r, address refereeKey) private view returns (uint256) {
        uint256 n = r.refereeChargePointsTotal6[refereeKey];
        if (n != 0) return n;
        address aa = _aaOfMaybeEoa(refereeKey);
        if (aa != refereeKey) {
            uint256 m = r.refereeChargePointsTotal6[aa];
            if (m != 0) return m;
        }
        address eoa = _eoaOfMaybeAa(refereeKey);
        if (eoa != refereeKey) return r.refereeChargePointsTotal6[eoa];
        return 0;
    }

    /// @dev Returns Beamio AA for mint destination, or address(0) if none (never falls back to EOA).
    function _beamioAaOrZero(address referrerKey) private view returns (address) {
        if (referrerKey == address(0)) return address(0);
        address gw = IReferrerLibUserCardGw(address(this)).factoryGateway();
        if (gw == address(0)) return address(0);
        address aaFac;
        try IReferrerLibFactoryAa(gw).aaFactory() returns (address a) {
            aaFac = a;
        } catch {
            return address(0);
        }
        if (aaFac == address(0)) return address(0);
        try IReferrerLibAaFactory(aaFac).isBeamioAccount(referrerKey) returns (bool isAa) {
            if (isAa) return referrerKey;
        } catch {}
        try IReferrerLibAaFactory(aaFac).beamioAccountOf(referrerKey) returns (address aa) {
            if (aa == address(0)) return address(0);
            try IReferrerLibAaFactory(aaFac).isBeamioAccount(aa) returns (bool ok) {
                if (ok) return aa;
            } catch {}
        } catch {}
        return address(0);
    }

    function _eoaOfMaybeAa(address acct) private view returns (address) {
        if (acct == address(0) || acct.code.length == 0) return acct;
        (bool ok, bytes memory ret) = acct.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || ret.length < 32) return acct;
        address o = abi.decode(ret, (address));
        return o == address(0) ? acct : o;
    }

    function _aaOfMaybeEoa(address acct) private view returns (address) {
        address aa = _beamioAaOrZero(acct);
        return aa == address(0) ? acct : aa;
    }
}
