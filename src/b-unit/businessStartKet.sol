// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "../contracts/token/ERC1155/ERC1155.sol";

/// @title BusinessStartKet
/// @notice Standalone ERC-1155 multi-token collection for business starter NFTs (fungible amounts per token id).
/// @dev Metadata: use an EIP-1155 URI template with `{id}` substitution, e.g. `https://example.com/metadata/{id}.json`.
///      Access control matches Beamio B-Units: multiple `admins` may mint and update URI.
///      End users cannot transfer or approve operators; only admins may move their own holdings via ERC-1155 transfer,
///      and admins may burn from any account without holder approval.
contract BusinessStartKet is ERC1155 {
    string public collectionName;
    string public collectionSymbol;

    mapping(address => bool) public admins;

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);

    modifier onlyAdmin() {
        require(admins[msg.sender], "BusinessStartKet: Caller is not an admin");
        _;
    }

    /// @param uri_ ERC-1155 metadata URI template (clients replace `{id}` per token type).
    /// @param name_ Human-readable collection name (not part of ERC-1155; for explorers/tooling).
    /// @param symbol_ Short ticker-style symbol for tooling.
    /// @dev Deployer is the first admin; use `addAdmin` to grant more accounts.
    constructor(string memory uri_, string memory name_, string memory symbol_) ERC1155(uri_) {
        collectionName = name_;
        collectionSymbol = symbol_;
        admins[msg.sender] = true;
        emit AdminAdded(msg.sender);
    }

    function addAdmin(address account) external onlyAdmin {
        require(account != address(0), "BusinessStartKet: Invalid admin address");
        admins[account] = true;
        emit AdminAdded(account);
    }

    function removeAdmin(address account) external onlyAdmin {
        require(account != msg.sender, "BusinessStartKet: Cannot remove self");
        admins[account] = false;
        emit AdminRemoved(account);
    }

    // --- Transfer / approval lock (non-admin) ---

    function setApprovalForAll(address operator, bool approved) public virtual override {
        require(admins[msg.sender], "BusinessStartKet: Approvals are locked");
        super.setApprovalForAll(operator, approved);
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes memory data)
        public
        virtual
        override
    {
        require(admins[msg.sender], "BusinessStartKet: Transfers are locked");
        super.safeTransferFrom(from, to, id, value, data);
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) public virtual override {
        require(admins[msg.sender], "BusinessStartKet: Transfers are locked");
        super.safeBatchTransferFrom(from, to, ids, values, data);
    }

    /// @notice Mint `amount` of token `id` to `to` (admin only).
    function mint(address to, uint256 id, uint256 amount, bytes calldata data) external onlyAdmin {
        _mint(to, id, amount, data);
    }

    /// @notice Batch mint (admin only).
    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data)
        external
        onlyAdmin
    {
        _mintBatch(to, ids, amounts, data);
    }

    /// @notice Update the URI template for all ids (admin only).
    function setURI(string calldata newuri) external onlyAdmin {
        _setURI(newuri);
    }

    /// @notice Burn `value` of `id` from `from` without holder approval (admin only).
    function adminBurn(address from, uint256 id, uint256 value) external onlyAdmin {
        _burn(from, id, value);
    }

    /// @notice Batch burn from `from` without holder approval (admin only).
    function adminBurnBatch(address from, uint256[] calldata ids, uint256[] calldata values) external onlyAdmin {
        _burnBatch(from, ids, values);
    }
}
