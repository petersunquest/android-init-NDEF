// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./RedeemStorage.sol";
import "./GovernanceStorage.sol";
import "./AdminStatsStorage.sol";
import "./BeamioERC1155Logic.sol";
import "./BeamioUserCardInterfaces.sol";
import "./BeamioUserCardTypes.sol";

/// @dev External library：转账/AA 解析/redeem 元数据等大块逻辑移出主合约以满足 EIP-170。
///      由 BeamioUserCard 以 delegatecall 调用，存储布局与主合约一致。
library BeamioUserCardTransferLib {
    function _toAccount(address gw, address maybeEoaOrAcct) private view returns (address acct) {
        address f = IBeamioFactoryOracle(gw).aaFactory();
        if (f == address(0)) revert UC_GlobalMisconfigured();

        if (IBeamioAccountFactoryV07(f).isBeamioAccount(maybeEoaOrAcct)) {
            if (maybeEoaOrAcct.code.length == 0) revert UC_NoBeamioAccount();
            return maybeEoaOrAcct;
        }
        return _resolveAccountForCard(gw, maybeEoaOrAcct);
    }

    function _resolveAccountForCard(address gw, address eoa) private view returns (address) {
        address aaFactory = IBeamioGatewayAAFactoryGetter(gw)._aaFactory();
        if (aaFactory == address(0)) revert UC_GlobalMisconfigured();

        address a = IBeamioAccountFactoryV07(aaFactory).beamioAccountOf(eoa);
        if (a == address(0) || a.code.length == 0) revert UC_ResolveAccountFailed(eoa, aaFactory, a);
        return a;
    }

    function toAccount(address gw, address maybeEoaOrAcct) external view returns (address acct) {
        return _toAccount(gw, maybeEoaOrAcct);
    }

    function resolveAccountForCard(address gw, address eoa) external view returns (address) {
        return _resolveAccountForCard(gw, eoa);
    }

    function getRedeemCreatorAndRecommender(string calldata code)
        external
        view
        returns (address creator, address recommender)
    {
        if (bytes(code).length == 0) return (address(0), address(0));
        bytes32 hash = keccak256(bytes(code));
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (r.active) return (r.creator, r.recommender);
        RedeemStorage.RedeemPool storage p = l.pools[hash];
        if (p.active) return (p.creator, p.recommender);
        return (address(0), address(0));
    }

    function _resolveTransferRecipientForAdminRedirect(address gw, address to)
        private
        view
        returns (address effectiveTo, address beneficiaryAdmin, address upperAdmin)
    {
        effectiveTo = to;
        beneficiaryAdmin = address(0);
        upperAdmin = address(0);

        if (to.code.length == 0) return (to, address(0), address(0));
        (bool ok, bytes memory ret) = to.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || ret.length < 32) return (to, address(0), address(0));
        address eoa = abi.decode(ret, (address));

        GovernanceStorage.Layout storage g = GovernanceStorage.layout();
        if (!g.isAdmin[eoa]) return (to, address(0), address(0));
        address parent = g.adminParent[eoa];
        if (parent == address(0)) return (to, address(0), address(0));

        beneficiaryAdmin = eoa;
        upperAdmin = parent;
        effectiveTo = _toAccount(gw, parent);
    }

    function resolveTransferRecipientForAdminRedirect(address gw, address to)
        external
        view
        returns (address effectiveTo, address beneficiaryAdmin, address upperAdmin)
    {
        return _resolveTransferRecipientForAdminRedirect(gw, to);
    }

    function _resolveAdminEoaForPointTransferParty(address party) private view returns (address eoaAdmin) {
        if (party == address(0)) return address(0);
        GovernanceStorage.Layout storage g = GovernanceStorage.layout();
        if (party.code.length == 0) {
            return g.isAdmin[party] ? party : address(0);
        }
        (bool ok, bytes memory ret) = party.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || ret.length < 32) return address(0);
        address eoa = abi.decode(ret, (address));
        return g.isAdmin[eoa] ? eoa : address(0);
    }

    function resolveAdminEoaForPointTransferParty(address party) external view returns (address eoaAdmin) {
        return _resolveAdminEoaForPointTransferParty(party);
    }

    function _resolveTransferStatsOperator(address from, address msgSender) private view returns (address operator) {
        GovernanceStorage.Layout storage g = GovernanceStorage.layout();
        if (g.isAdmin[msgSender]) return msgSender;
        if (from == address(0) || from.code.length == 0) return address(0);

        (bool ok, bytes memory ret) = from.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || ret.length < 32) return address(0);
        address ownerOfFrom = abi.decode(ret, (address));
        if (g.isAdmin[ownerOfFrom]) return ownerOfFrom;
        return address(0);
    }

    function resolveTransferStatsOperator(address from, address msgSender) external view returns (address operator) {
        return _resolveTransferStatsOperator(from, msgSender);
    }

    function recordPointTransferStats(
        address from,
        address originalTo,
        address beneficiaryAdmin,
        address upperAdmin,
        uint256 count,
        uint256 amount,
        address cardOwner
    ) external {
        upperAdmin;
        if (count > 0 || amount > 0) {
            address senderAdm = _resolveAdminEoaForPointTransferParty(from);
            address recvAdm = _resolveAdminEoaForPointTransferParty(originalTo);
            if (
                senderAdm != address(0) && recvAdm != address(0) && senderAdm != recvAdm && senderAdm != cardOwner
                    && recvAdm != cardOwner
            ) {
                AdminStatsStorage.recordGlobalAdminToAdminTransfer(count, amount);
            }
        }

        if (beneficiaryAdmin != address(0)) {
            AdminStatsStorage.recordTransfer(beneficiaryAdmin, count, amount);
            return;
        }
        address operator = _resolveTransferStatsOperator(from, msg.sender);
        if (operator != address(0) && (count > 0 || amount > 0)) {
            AdminStatsStorage.recordTransfer(operator, count, amount);
        }
    }

    function updatePreProcess(address gw, address from, address to, uint256[] memory ids, uint256[] memory values)
        external
        view
        returns (UpdatePreResult memory r)
    {
        uint256 NFT_START_ID = BeamioERC1155Logic.NFT_START_ID;
        uint256 ISSUED_NFT_START_ID = BeamioERC1155Logic.ISSUED_NFT_START_ID;
        uint256 POINTS_ID = BeamioERC1155Logic.POINTS_ID;

        bool isRealTransfer = (from != address(0) && to != address(0));
        if (isRealTransfer && to.code.length == 0) revert UC_BeneficiaryMustBeAA();

        (r.effectiveTo, r.beneficiaryAdmin, r.upperAdmin) = _resolveTransferRecipientForAdminRedirect(gw, to);
        r.burnedFrom = new address[](ids.length);
        r.burnedIds = new uint256[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (id >= NFT_START_ID && id < ISSUED_NFT_START_ID) {
                if (to == address(0) && from != address(0)) {
                    r.burnedFrom[r.burnedCount] = from;
                    r.burnedIds[r.burnedCount] = id;
                    r.burnedCount++;
                }
                continue;
            }
            if (id == POINTS_ID && isRealTransfer) {
                if (values[i] > 0) {
                    r.pointTransferCount += 1;
                    r.pointTransferAmount += values[i];
                }
                if (!IBeamioUserCardWhitelist(address(this)).isPointsTransferRecipientAllowed(r.effectiveTo)) {
                    revert UC_PointsToNotWhitelisted();
                }
            }
        }
    }
}
