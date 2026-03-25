// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GovernanceStorage.sol";

/// @dev 供 BeamioUserCard / BeamioUserCardBase 共用，避免与 MembershipStatsModule 重复 bytecode
abstract contract BeamioUserCardAdminPartyMixin {
    function _resolveAdminEoaForPointTransferParty(address party) internal view returns (address eoaAdmin) {
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
}
