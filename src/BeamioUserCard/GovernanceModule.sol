// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./GovernanceStorage.sol";

interface IUserCardCtx {
    function owner() external view returns (address);
    function factoryGateway() external view returns (address);
}

/**
 * @title BeamioUserCardGovernanceModuleV1
 * @notice Delegatecall module for multisig governance. Card executes (addAdmin/mintPoints/mintMemberCard) after executeProposal returns.
 */
contract BeamioUserCardGovernanceModuleV1 {
    event ProposalCreated(uint256 indexed id, bytes4 indexed selector, address indexed proposer);
    event ProposalApproved(uint256 indexed id, address indexed admin);
    event ProposalExecuted(uint256 indexed id);

    modifier onlyGateway() {
        if (msg.sender != IUserCardCtx(address(this)).factoryGateway()) revert UC_UnauthorizedGateway();
        _;
    }

    modifier onlyAdmin() {
        if (!GovernanceStorage.layout().isAdmin[msg.sender]) revert UC_NotAdmin();
        _;
    }

    function _addAdmin(address newAdmin, uint256 newThreshold) internal {
        if (newAdmin == address(0)) revert BM_ZeroAddress();
        GovernanceStorage.Layout storage l = GovernanceStorage.layout();
        if (!l.isAdmin[newAdmin]) {
            l.isAdmin[newAdmin] = true;
            l.adminList.push(newAdmin);
        }
        if (newThreshold > l.adminList.length) revert UC_InvalidProposal();
        l.threshold = newThreshold;
    }

    function addAdmin(address newAdmin, uint256 newThreshold) external {
        address cardOwner = IUserCardCtx(address(this)).owner();
        address gw = IUserCardCtx(address(this)).factoryGateway();
        if (msg.sender != cardOwner && msg.sender != gw) revert BM_NotAuthorized();
        _addAdmin(newAdmin, newThreshold);
    }

    /// @notice Create proposal; gateway or admin can call. Returns proposal id.
    function createProposal(bytes4 selector, address target, uint256 v1, uint256 v2, uint256 v3)
        external
        onlyGateway
        returns (uint256 id)
    {
        GovernanceStorage.Layout storage l = GovernanceStorage.layout();
        id = l.proposalCount++;
        l.proposals[id] = GovernanceStorage.Proposal(target, v1, v2, v3, selector, 0, false);
        emit ProposalCreated(id, selector, msg.sender);

        if (l.isAdmin[msg.sender]) _approve(l, id, msg.sender);
        return id;
    }

    function approveProposalByGateway(uint256 id, address adminSigner) external onlyGateway {
        GovernanceStorage.Layout storage l = GovernanceStorage.layout();
        if (!l.isAdmin[adminSigner]) revert UC_NotAdmin();
        _approve(l, id, adminSigner);
    }

    function approveProposal(uint256 id) external onlyAdmin {
        _approve(GovernanceStorage.layout(), id, msg.sender);
    }

    function _approve(GovernanceStorage.Layout storage l, uint256 id, address admin) internal {
        GovernanceStorage.Proposal storage p = l.proposals[id];
        if (p.executed) revert UC_InvalidProposal();
        if (l.isApproved[id][admin]) revert UC_InvalidProposal();

        l.isApproved[id][admin] = true;
        p.approvals++;
        emit ProposalApproved(id, admin);
    }

    /// @notice If approvals >= threshold, mark executed and return (selector, target, v1, v2, v3) for card to execute.
    function executeProposal(uint256 id)
        external
        returns (bytes4 selector, address target, uint256 v1, uint256 v2, uint256 v3)
    {
        GovernanceStorage.Layout storage l = GovernanceStorage.layout();
        GovernanceStorage.Proposal storage p = l.proposals[id];
        if (p.executed) revert UC_InvalidProposal();
        if (p.approvals < l.threshold) revert UC_InvalidProposal();

        p.executed = true;
        emit ProposalExecuted(id);

        return (p.selector, p.target, p.v1, p.v2, p.v3);
    }
}
