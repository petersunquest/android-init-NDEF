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
 * @notice Delegatecall module for multisig governance. Card executes (adminManager/mintPoints/mintMemberCard) after executeProposal returns.
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

    function _addAdmin(address newAdmin, uint256 newThreshold, string calldata metadata, address parentAdmin) internal {
        if (newAdmin == address(0)) revert BM_ZeroAddress();
        GovernanceStorage.Layout storage l = GovernanceStorage.layout();
        if (!l.isAdmin[newAdmin]) {
            l.isAdmin[newAdmin] = true;
            l.adminList.push(newAdmin);
            l.adminParent[newAdmin] = parentAdmin;
            if (parentAdmin != address(0)) {
                l.adminChildren[parentAdmin].push(newAdmin);
            }
        }
        l.adminMetadata[newAdmin] = metadata;
        if (newThreshold > l.adminList.length) revert UC_InvalidProposal();
        l.threshold = newThreshold;
    }

    function _removeAdmin(address adminToRemove, uint256 newThreshold, address authorizer) internal {
        if (adminToRemove == address(0)) revert BM_ZeroAddress();
        if (adminToRemove == IUserCardCtx(address(this)).owner()) revert UC_OwnerCannotBeRemoved();
        GovernanceStorage.Layout storage l = GovernanceStorage.layout();
        if (!l.isAdmin[adminToRemove]) revert UC_InvalidProposal();
        if (l.adminList.length <= 1) revert UC_InvalidProposal();

        address cardOwner = IUserCardCtx(address(this)).owner();
        address parent = l.adminParent[adminToRemove];
        if (authorizer != cardOwner && authorizer != parent) revert UC_OnlyParentCanRemoveAdmin(adminToRemove, parent);

        l.isAdmin[adminToRemove] = false;
        l.adminParent[adminToRemove] = address(0);
        if (parent != address(0)) {
            _removeFromAdminChildren(l, parent, adminToRemove);
        }
        bool found = false;
        uint256 n = l.adminList.length;
        for (uint256 i = 0; i < n; i++) {
            if (l.adminList[i] == adminToRemove) {
                l.adminList[i] = l.adminList[n - 1];
                l.adminList.pop();
                found = true;
                break;
            }
        }
        if (!found) revert UC_InvalidProposal();
        if (newThreshold == 0 || newThreshold > l.adminList.length) revert UC_InvalidProposal();
        l.threshold = newThreshold;
    }

    function _removeFromAdminChildren(GovernanceStorage.Layout storage l, address parent, address child) internal {
        address[] storage children = l.adminChildren[parent];
        for (uint256 i = 0; i < children.length; i++) {
            if (children[i] == child) {
                children[i] = children[children.length - 1];
                children.pop();
                return;
            }
        }
    }

    /// @notice owner 离线签字后经 gateway 的 executeForOwner 执行。admin=true 添加（parent=0），admin=false 仅 parent 或 owner 可移除
    function adminManager(address to, bool admin, uint256 newThreshold, string calldata metadata) external onlyGateway {
        if (admin) _addAdmin(to, newThreshold, metadata, address(0));
        else _removeAdmin(to, newThreshold, IUserCardCtx(address(this)).owner());
    }

    /// @notice admin 离线签字后经 gateway 的 executeForAdmin 执行。添加时 authorizer 为 parent；移除时仅 authorizer==parent 可删
    function adminManagerByAdmin(address to, bool admin, uint256 newThreshold, string calldata metadata, address authorizer) external onlyGateway {
        GovernanceStorage.Layout storage l = GovernanceStorage.layout();
        if (!l.isAdmin[authorizer]) revert UC_NotAdmin();
        if (admin) _addAdmin(to, newThreshold, metadata, authorizer);
        else _removeAdmin(to, newThreshold, authorizer);
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
