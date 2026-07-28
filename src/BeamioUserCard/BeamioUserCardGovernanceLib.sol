// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./GovernanceStorage.sol";
import "./BeamioERC1155Logic.sol";
import "./BeamioUserCardInterfaces.sol";
import "./BeamioUserCardModuleKinds.sol";
import "./IBeamioUserCardSelfDelegate.sol";

/// @dev Governance proposal create/approve/execute path (external runtime library).
library BeamioUserCardGovernanceLib {
    uint256 internal constant POINTS_ID = BeamioERC1155Logic.POINTS_ID;
    uint8 internal constant MODULE_GOVERNANCE = BeamioUserCardModuleKinds.GOVERNANCE;
    uint8 internal constant MODULE_MEMBERSHIP_STATS = BeamioUserCardModuleKinds.MEMBERSHIP_STATS;

    function createProposal(
        IBeamioUserCardSelfDelegate delegate,
        address governanceModule,
        bytes4 selector,
        address target,
        uint256 v1,
        uint256 v2,
        uint256 v3
    ) external returns (uint256) {
        bytes memory data = delegate.cardSelfCallModule(
            MODULE_GOVERNANCE,
            abi.encodeWithSelector(IBeamioGovernanceModuleV1.createProposal.selector, selector, target, v1, v2, v3)
        );
        uint256 id = abi.decode(data, (uint256));
        maybeExecuteProposal(delegate, governanceModule, id);
        return id;
    }

    function approveProposalByGateway(IBeamioUserCardSelfDelegate delegate, address governanceModule, uint256 id, address adminSigner)
        external
    {
        (bool ok,) = governanceModule.delegatecall(
            abi.encodeWithSelector(IBeamioGovernanceModuleV1.approveProposalByGateway.selector, id, adminSigner)
        );
        if (!ok) revert UC_NotAdmin();
        maybeExecuteProposal(delegate, governanceModule, id);
    }

    function approveProposal(IBeamioUserCardSelfDelegate delegate, address governanceModule, uint256 id) external {
        (bool ok,) = governanceModule.delegatecall(
            abi.encodeWithSelector(IBeamioGovernanceModuleV1.approveProposal.selector, id)
        );
        if (!ok) revert UC_InvalidProposal();
        maybeExecuteProposal(delegate, governanceModule, id);
    }

    function maybeExecuteProposal(IBeamioUserCardSelfDelegate delegate, address governanceModule, uint256 id) public {
        GovernanceStorage.Layout storage g = GovernanceStorage.layout();
        GovernanceStorage.Proposal storage p = g.proposals[id];
        if (p.executed || p.approvals < g.threshold) return;
        (bool ok, bytes memory data) = governanceModule.delegatecall(
            abi.encodeWithSelector(IBeamioGovernanceModuleV1.executeProposal.selector, id)
        );
        if (!ok) _revertDelegate(data);
        (bytes4 sel, address target, uint256 v1, uint256 v2,) = abi.decode(data, (bytes4, address, uint256, uint256, uint256));
        executeWith(delegate, sel, target, v1, v2);
    }

    function executeWith(IBeamioUserCardSelfDelegate delegate, bytes4 sel, address target, uint256 v1, uint256 v2)
        public
    {
        if (sel == bytes4(keccak256("adminManager(address,bool,uint256,string)"))) {
            revert UC_AdminManagerRequiresOwnerSignature();
        } else if (sel == bytes4(keccak256("mintPoints(address,uint256)"))) {
            delegate.cardSelfMint(target, POINTS_ID, v1);
        } else if (sel == bytes4(keccak256("mintMemberCard(address,uint256)"))) {
            delegate.cardSelfCallModule(
                MODULE_MEMBERSHIP_STATS,
                abi.encodeWithSelector(IBeamioMembershipStatsModuleV1.mintMemberCardInternal.selector, target, v2)
            );
        } else {
            revert UC_InvalidProposal();
        }
    }

    function _revertDelegate(bytes memory data) private pure {
        if (data.length > 0) assembly { revert(add(data, 32), mload(data)) }
        revert UC_RedeemDelegateFailed(data);
    }
}
