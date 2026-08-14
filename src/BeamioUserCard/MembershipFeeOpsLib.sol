// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MembershipFeeStorage.sol";
import "./Errors.sol";

interface IUserCardMembershipFeeCtxLib {
    function owner() external view returns (address);
    function factoryGateway() external view returns (address);
    function tiers(uint256 index) external view returns (uint256 minUsdc6, uint256 attr, uint256 tierExpirySeconds, bool upgradeByBalance);
}

interface IUserCardFactoryPaymasterStatusLib {
    function isPaymaster(address account) external view returns (bool);
}

interface IBeamioAccountFactoryResolveLib {
    function isBeamioAccount(address account) external view returns (bool);
    function beamioAccountOf(address eoa) external view returns (address);
}

interface IUserCardFactoryAaOracleLib {
    function aaFactory() external view returns (address);
    function _aaFactory() external view returns (address);
}

/// @dev External library to keep AdminStatsQueryModuleV5 under EIP-170.
library MembershipFeeOpsLib {
    event MembershipFeesUpdated(uint256 tierCount);
    event MembershipFeePurchaseStaged(
        address indexed account,
        uint256 tierIndex,
        uint256 feePaid6,
        uint256 pointsCredit6,
        uint64 deadline
    );
    event MembershipFeePurchaseCleared(address indexed account);

    function _tiersLength() private view returns (uint256 n) {
        for (;;) {
            try IUserCardMembershipFeeCtxLib(address(this)).tiers(n) returns (uint256, uint256, uint256, bool) {
                unchecked {
                    ++n;
                }
            } catch {
                return n;
            }
        }
    }

    function _resolveAcct(address user) private view returns (address acct) {
        if (user == address(0)) revert BM_ZeroAddress();
        address gw = IUserCardMembershipFeeCtxLib(address(this)).factoryGateway();
        address aaFactory;
        try IUserCardFactoryAaOracleLib(gw)._aaFactory() returns (address f) {
            aaFactory = f;
        } catch {
            aaFactory = IUserCardFactoryAaOracleLib(gw).aaFactory();
        }
        if (aaFactory == address(0)) revert UC_GlobalMisconfigured();
        if (IBeamioAccountFactoryResolveLib(aaFactory).isBeamioAccount(user)) {
            return user;
        }
        acct = IBeamioAccountFactoryResolveLib(aaFactory).beamioAccountOf(user);
        if (acct == address(0)) revert UC_ResolveAccountFailed(user, aaFactory, acct);
        return acct;
    }

    function requireOwnerOrGateway() external view {
        address cardOwner = IUserCardMembershipFeeCtxLib(address(this)).owner();
        address gw = IUserCardMembershipFeeCtxLib(address(this)).factoryGateway();
        if (msg.sender != cardOwner && msg.sender != gw) revert BM_NotAuthorized();
    }

    function requireGatewayOrPaymaster() external view {
        address gw = IUserCardMembershipFeeCtxLib(address(this)).factoryGateway();
        if (msg.sender == gw) return;
        if (IUserCardFactoryPaymasterStatusLib(gw).isPaymaster(msg.sender)) return;
        revert UC_UnauthorizedGateway();
    }

    function resolveAcct(address user) external view returns (address) {
        return _resolveAcct(user);
    }

    function setMembershipFees(uint256[] calldata feeE6, uint8[] calldata durationKind) external {
        uint256 n = _tiersLength();
        if (feeE6.length != n || durationKind.length != n) revert UC_MembershipFeeLenMismatch();
        MembershipFeeStorage.Layout storage l = MembershipFeeStorage.layout();
        for (uint256 i = 0; i < n; i++) {
            if (feeE6[i] > 0) {
                if (!MembershipFeeStorage.isValidDurationKind(durationKind[i])) revert UC_MembershipFeeInvalidDuration();
                l.feeE6[i] = feeE6[i];
                l.durationKind[i] = durationKind[i];
            } else {
                l.feeE6[i] = 0;
                l.durationKind[i] = MembershipFeeStorage.DURATION_NONE;
            }
        }
        emit MembershipFeesUpdated(n);
    }

    function membershipFees() external view returns (uint256[] memory feeE6, uint8[] memory durationKind) {
        uint256 n = _tiersLength();
        feeE6 = new uint256[](n);
        durationKind = new uint8[](n);
        MembershipFeeStorage.Layout storage l = MembershipFeeStorage.layout();
        for (uint256 i = 0; i < n; i++) {
            feeE6[i] = l.feeE6[i];
            durationKind[i] = l.durationKind[i];
        }
    }

    function membershipFeeMode() external view returns (bool) {
        uint256 n = _tiersLength();
        MembershipFeeStorage.Layout storage l = MembershipFeeStorage.layout();
        for (uint256 i = 0; i < n; i++) {
            if (l.feeE6[i] > 0) return true;
        }
        return false;
    }

    function stageMembershipFeePurchase(
        address user,
        uint256 tierIndex,
        uint256 feePaid6,
        uint256 pointsCredit6
    ) external {
        uint256 n = _tiersLength();
        if (tierIndex >= n) revert UC_MustGrow();
        MembershipFeeStorage.Layout storage l = MembershipFeeStorage.layout();
        uint256 expectedFee = l.feeE6[tierIndex];
        if (expectedFee == 0 || feePaid6 != expectedFee) revert UC_MembershipFeeMismatch();
        if (!MembershipFeeStorage.isValidDurationKind(l.durationKind[tierIndex])) revert UC_MembershipFeeInvalidDuration();

        address acct = _resolveAcct(user);
        uint64 deadline = uint64(block.timestamp) + MembershipFeeStorage.PENDING_TTL_SECONDS;
        l.pendingByAcct[acct] = MembershipFeeStorage.PendingPurchase({
            tierIndex: tierIndex,
            feePaid6: feePaid6,
            pointsCredit6: pointsCredit6,
            deadline: deadline,
            active: true
        });
        emit MembershipFeePurchaseStaged(acct, tierIndex, feePaid6, pointsCredit6, deadline);
    }

    function clearMembershipFeePurchase(address user) external {
        address acct = _resolveAcct(user);
        delete MembershipFeeStorage.layout().pendingByAcct[acct];
        emit MembershipFeePurchaseCleared(acct);
    }
}
