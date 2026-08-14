// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {DLEUpgradeableBase} from "../DLEUpgradeableBase.sol";
import {ITreasuryDleAuthorityV1} from "../interfaces/ITreasuryDleAuthorityV1.sol";
import {IDleOracleAdapterV1} from "../AssetAdmissionRegistryV1.sol";

/// @dev Local-test canonical asset. Production assets remain Treasury V3 tokens.
contract MockCanonicalAsset is DLEUpgradeableBase, ERC20Upgradeable {
    error NotAuthority();

    address public authority;

    function initialize(
        address initialOwner,
        string calldata name_,
        string calldata symbol_
    ) external initializer {
        __DLEUpgradeableBase_init(initialOwner);
        __ERC20_init(name_, symbol_);
    }

    function setAuthority(address authority_) external onlyOwner {
        if (authority_ == address(0)) revert ZeroAddress();
        authority = authority_;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != owner() && msg.sender != authority) revert NotAuthority();
        _mint(to, amount);
    }

    function authorityBurnFrom(address from, uint256 amount) external {
        if (msg.sender != authority) revert NotAuthority();
        _burn(from, amount);
    }

    uint256[48] private __gap;
}

contract MockOracleAdapterV1 is DLEUpgradeableBase, IDleOracleAdapterV1 {
    uint256 public unitScale;
    uint256 public priceUsdc6PerUnit;
    uint64 public updatedAt;

    function initialize(
        address initialOwner,
        uint256 unitScale_,
        uint256 priceUsdc6PerUnit_
    ) external initializer {
        __DLEUpgradeableBase_init(initialOwner);
        unitScale = unitScale_;
        priceUsdc6PerUnit = priceUsdc6PerUnit_;
        updatedAt = uint64(block.timestamp);
    }

    function setQuote(uint256 priceUsdc6PerUnit_, uint64 updatedAt_) external onlyOwner {
        priceUsdc6PerUnit = priceUsdc6PerUnit_;
        updatedAt = updatedAt_;
    }

    function quoteUsdc6(address, uint256 amount) external view returns (uint256 usdc6, uint64 timestamp) {
        return ((amount * priceUsdc6PerUnit) / unitScale, updatedAt);
    }

    uint256[47] private __gap;
}

contract MockTreasuryDleAuthorityV1 is DLEUpgradeableBase, ITreasuryDleAuthorityV1 {
    error NotGateway();
    error NonCanonicalAsset();
    error OperationAlreadyConsumed();
    error InsufficientReplacementCapacity();
    error InsufficientReservation();
    error MockMintFailure();

    address public gateway;
    bool public failMint;
    mapping(address => bool) public override canonicalAsset;
    mapping(address => uint256) public capacity;
    mapping(address => uint256) public override reservedReplacement;
    mapping(bytes32 => bool) public override operationConsumed;

    function initialize(address initialOwner) external initializer {
        __DLEUpgradeableBase_init(initialOwner);
    }

    function setGateway(address gateway_) external onlyOwner {
        if (gateway_ == address(0)) revert ZeroAddress();
        gateway = gateway_;
    }

    function configureAsset(address asset, uint256 replacementCapacity) external onlyOwner {
        canonicalAsset[asset] = true;
        capacity[asset] = replacementCapacity;
    }

    function setFailMint(bool shouldFail) external onlyOwner {
        failMint = shouldFail;
    }

    function availableReplacementCapacity(address asset) external view returns (uint256) {
        uint256 cap = capacity[asset];
        uint256 reserved = reservedReplacement[asset];
        return cap > reserved ? cap - reserved : 0;
    }

    function reserveAndBurn(
        bytes32 operationId,
        address asset,
        address from,
        uint256 amount,
        uint64
    ) external {
        if (msg.sender != gateway) revert NotGateway();
        if (!canonicalAsset[asset]) revert NonCanonicalAsset();
        if (operationConsumed[operationId]) revert OperationAlreadyConsumed();
        if (capacity[asset] - reservedReplacement[asset] < amount) {
            revert InsufficientReplacementCapacity();
        }
        operationConsumed[operationId] = true;
        reservedReplacement[asset] += amount;
        MockCanonicalAsset(asset).authorityBurnFrom(from, amount);
    }

    function releaseReservedAndMint(
        bytes32 operationId,
        address asset,
        address to,
        uint256 amount,
        uint64
    ) external {
        if (msg.sender != gateway) revert NotGateway();
        if (operationConsumed[operationId]) revert OperationAlreadyConsumed();
        if (reservedReplacement[asset] < amount) revert InsufficientReservation();
        if (failMint) revert MockMintFailure();
        operationConsumed[operationId] = true;
        reservedReplacement[asset] -= amount;
        MockCanonicalAsset(asset).mint(to, amount);
    }

    uint256[44] private __gap;
}
