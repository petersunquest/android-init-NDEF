// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

/**
 * @title BeamioAgentReferrerRegistry
 * @notice On-chain Agent / Temp EOA / Merchant / Referrer registry for Merchant OS.
 *
 * @dev Roles (all EOAs):
 *      - Agent: registers via offline EIP-712 `RegisterAgent` (self-signed).
 *      - Temp: agent registers a temporary merchant workspace EOA under themselves.
 *      - Merchant: after agent hands off a temp workspace, agent registers the merchant EOA.
 *      - Referrer (referee): a new user offline-signs `RegisterReferrer` to bind under an introducer.
 *
 *      Anyone may submit a signed update (gasless relayer / Master settle). Only the named signer
 *      authorizes the relationship. Per-signer {nonces} provide replay protection.
 *
 *      UUPS upgradeable; canonical address = ERC1967 proxy.
 */
contract BeamioAgentReferrerRegistry is Initializable, UUPSUpgradeable {
    // ---- EIP-712 ----
    bytes32 private constant _EIP712_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("BeamioAgentReferrerRegistry");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("1");

    bytes32 private constant _REGISTER_AGENT_TYPEHASH =
        keccak256("RegisterAgent(address agent,uint256 nonce,uint256 deadline)");
    bytes32 private constant _REGISTER_TEMP_TYPEHASH =
        keccak256("RegisterTemp(address agent,address temp,uint256 nonce,uint256 deadline)");
    bytes32 private constant _REGISTER_MERCHANT_TYPEHASH =
        keccak256(
            "RegisterMerchant(address agent,address merchant,address temp,uint256 nonce,uint256 deadline)"
        );
    bytes32 private constant _REGISTER_REFERRER_TYPEHASH =
        keccak256("RegisterReferrer(address introducer,address referee,uint256 nonce,uint256 deadline)");

    bytes32 private _eip712CachedChainId;
    bytes32 private _eip712CachedSeparator;

    mapping(address => bool) public admins;

    /// @notice True when `eoa` has successfully registered as an Agent.
    mapping(address => bool) public isAgent;
    /// @notice Timestamp when the agent registered (0 if never).
    mapping(address => uint64) public agentRegisteredAt;

    /// @notice Agent that owns a temp EOA (0 if unbound).
    mapping(address => address) public agentOfTemp;
    /// @notice True after the temp was used in a merchant handoff (still historically linked).
    mapping(address => bool) public tempHandedOff;

    /// @notice Agent that owns a merchant EOA (0 if unbound).
    mapping(address => address) public agentOfMerchant;
    /// @notice Optional temp that produced this merchant handoff (0 if none / direct).
    mapping(address => address) public tempOfMerchant;

    /// @notice Introducer (upline) of a referee EOA (0 if unbound).
    mapping(address => address) public introducerOf;
    /// @notice Timestamp when the referee bound under introducer.
    mapping(address => uint64) public refereeRegisteredAt;

    /// @notice Per-signer EIP-712 nonce (strictly increasing).
    mapping(address => uint256) public nonces;

    mapping(address => address[]) private _tempsOfAgent;
    mapping(address => address[]) private _merchantsOfAgent;
    mapping(address => address[]) private _refereesOf;

    event AgentRegistered(address indexed agent, uint256 nonce, uint64 registeredAt);
    event TempRegistered(address indexed agent, address indexed temp, uint256 nonce, uint64 registeredAt);
    event MerchantRegistered(
        address indexed agent,
        address indexed merchant,
        address indexed temp,
        uint256 nonce,
        uint64 registeredAt
    );
    event ReferrerRegistered(
        address indexed introducer,
        address indexed referee,
        uint256 nonce,
        uint64 registeredAt
    );
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);

    error ZeroAddress();
    error NotAdmin();
    error BadNonce();
    error Expired();
    error BadSignature();
    error AlreadyAgent();
    error NotAnAgent();
    error AlreadyBound();
    error TempNotUnderAgent();
    error TempAlreadyHandedOff();

    modifier onlyAdmin() {
        if (!admins[msg.sender]) revert NotAdmin();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialAdmin) external initializer {
        __UUPSUpgradeable_init();
        _initEip712Domain();
        address a = initialAdmin == address(0) ? msg.sender : initialAdmin;
        admins[a] = true;
        emit AdminAdded(a);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    function _initEip712Domain() private {
        _eip712CachedChainId = bytes32(block.chainid);
        _eip712CachedSeparator = keccak256(
            abi.encode(_EIP712_TYPE_HASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function _domainSeparatorV4() internal view returns (bytes32) {
        if (bytes32(block.chainid) == _eip712CachedChainId) {
            return _eip712CachedSeparator;
        }
        return keccak256(
            abi.encode(_EIP712_TYPE_HASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), structHash));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function nonceOf(address account) external view returns (uint256) {
        return nonces[account];
    }

    // ---- Register Agent (self-signed; relayer may submit) ----

    function registerAgentWithSig(address agent, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
    {
        if (agent == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert Expired();
        if (nonce != nonces[agent]) revert BadNonce();
        if (isAgent[agent]) revert AlreadyAgent();
        if (agentOfTemp[agent] != address(0) || agentOfMerchant[agent] != address(0)) revert AlreadyBound();

        bytes32 structHash = keccak256(abi.encode(_REGISTER_AGENT_TYPEHASH, agent, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (signer != agent) revert BadSignature();

        nonces[agent] = nonce + 1;
        isAgent[agent] = true;
        agentRegisteredAt[agent] = uint64(block.timestamp);
        emit AgentRegistered(agent, nonce, uint64(block.timestamp));
    }

    /// @notice Agent self-write (pays own gas).
    function registerAgent() external {
        address agent = msg.sender;
        if (isAgent[agent]) revert AlreadyAgent();
        if (agentOfTemp[agent] != address(0) || agentOfMerchant[agent] != address(0)) revert AlreadyBound();
        uint256 n = nonces[agent];
        nonces[agent] = n + 1;
        isAgent[agent] = true;
        agentRegisteredAt[agent] = uint64(block.timestamp);
        emit AgentRegistered(agent, n, uint64(block.timestamp));
    }

    // ---- Register Temp under Agent (agent-signed) ----

    function registerTempWithSig(
        address agent,
        address temp,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (agent == address(0) || temp == address(0)) revert ZeroAddress();
        if (agent == temp) revert AlreadyBound();
        if (block.timestamp > deadline) revert Expired();
        if (nonce != nonces[agent]) revert BadNonce();
        if (!isAgent[agent]) revert NotAnAgent();
        if (isAgent[temp]) revert AlreadyAgent();
        if (agentOfTemp[temp] != address(0) || agentOfMerchant[temp] != address(0)) revert AlreadyBound();
        if (introducerOf[temp] != address(0)) revert AlreadyBound();

        bytes32 structHash = keccak256(abi.encode(_REGISTER_TEMP_TYPEHASH, agent, temp, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (signer != agent) revert BadSignature();

        nonces[agent] = nonce + 1;
        agentOfTemp[temp] = agent;
        _tempsOfAgent[agent].push(temp);
        emit TempRegistered(agent, temp, nonce, uint64(block.timestamp));
    }

    function registerTemp(address temp) external {
        address agent = msg.sender;
        if (temp == address(0) || agent == temp) revert ZeroAddress();
        if (!isAgent[agent]) revert NotAnAgent();
        if (isAgent[temp]) revert AlreadyAgent();
        if (agentOfTemp[temp] != address(0) || agentOfMerchant[temp] != address(0)) revert AlreadyBound();
        if (introducerOf[temp] != address(0)) revert AlreadyBound();
        uint256 n = nonces[agent];
        nonces[agent] = n + 1;
        agentOfTemp[temp] = agent;
        _tempsOfAgent[agent].push(temp);
        emit TempRegistered(agent, temp, n, uint64(block.timestamp));
    }

    // ---- Register Merchant under Agent after temp handoff (agent-signed) ----

    /**
     * @param temp Optional prior temp EOA (may be address(0) for direct merchant bind).
     *             When non-zero, must already be registered under `agent` and not handed off.
     */
    function registerMerchantWithSig(
        address agent,
        address merchant,
        address temp,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (agent == address(0) || merchant == address(0)) revert ZeroAddress();
        if (agent == merchant) revert AlreadyBound();
        if (block.timestamp > deadline) revert Expired();
        if (nonce != nonces[agent]) revert BadNonce();
        if (!isAgent[agent]) revert NotAnAgent();
        if (isAgent[merchant]) revert AlreadyAgent();
        if (agentOfMerchant[merchant] != address(0)) revert AlreadyBound();
        if (agentOfTemp[merchant] != address(0)) revert AlreadyBound();

        if (temp != address(0)) {
            if (agentOfTemp[temp] != agent) revert TempNotUnderAgent();
            if (tempHandedOff[temp]) revert TempAlreadyHandedOff();
        }

        bytes32 structHash =
            keccak256(abi.encode(_REGISTER_MERCHANT_TYPEHASH, agent, merchant, temp, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (signer != agent) revert BadSignature();

        nonces[agent] = nonce + 1;
        agentOfMerchant[merchant] = agent;
        tempOfMerchant[merchant] = temp;
        _merchantsOfAgent[agent].push(merchant);
        if (temp != address(0)) {
            tempHandedOff[temp] = true;
        }
        emit MerchantRegistered(agent, merchant, temp, nonce, uint64(block.timestamp));
    }

    function registerMerchant(address merchant, address temp) external {
        address agent = msg.sender;
        if (merchant == address(0) || agent == merchant) revert ZeroAddress();
        if (!isAgent[agent]) revert NotAnAgent();
        if (isAgent[merchant]) revert AlreadyAgent();
        if (agentOfMerchant[merchant] != address(0)) revert AlreadyBound();
        if (agentOfTemp[merchant] != address(0)) revert AlreadyBound();
        if (temp != address(0)) {
            if (agentOfTemp[temp] != agent) revert TempNotUnderAgent();
            if (tempHandedOff[temp]) revert TempAlreadyHandedOff();
        }
        uint256 n = nonces[agent];
        nonces[agent] = n + 1;
        agentOfMerchant[merchant] = agent;
        tempOfMerchant[merchant] = temp;
        _merchantsOfAgent[agent].push(merchant);
        if (temp != address(0)) {
            tempHandedOff[temp] = true;
        }
        emit MerchantRegistered(agent, merchant, temp, n, uint64(block.timestamp));
    }

    // ---- Register Referrer / referee under introducer (referee-signed) ----

    /**
     * @notice New user (`referee`) binds under `introducer` (share-link owner).
     *         Signed offline by the referee EOA; relayer pays gas.
     */
    function registerReferrerWithSig(
        address introducer,
        address referee,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (introducer == address(0) || referee == address(0)) revert ZeroAddress();
        if (introducer == referee) revert AlreadyBound();
        if (block.timestamp > deadline) revert Expired();
        if (nonce != nonces[referee]) revert BadNonce();
        if (introducerOf[referee] != address(0)) revert AlreadyBound();
        // Referee may later become agent; binding as downline first is allowed.
        // Do not allow binding if already an agent's temp/merchant slot.
        if (agentOfTemp[referee] != address(0) || agentOfMerchant[referee] != address(0)) {
            revert AlreadyBound();
        }

        bytes32 structHash =
            keccak256(abi.encode(_REGISTER_REFERRER_TYPEHASH, introducer, referee, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (signer != referee) revert BadSignature();

        nonces[referee] = nonce + 1;
        introducerOf[referee] = introducer;
        refereeRegisteredAt[referee] = uint64(block.timestamp);
        _refereesOf[introducer].push(referee);
        emit ReferrerRegistered(introducer, referee, nonce, uint64(block.timestamp));
    }

    // ---- Reads / enumeration ----

    function tempsOfAgentLength(address agent) external view returns (uint256) {
        return _tempsOfAgent[agent].length;
    }

    function tempsOfAgent(address agent) external view returns (address[] memory) {
        return _tempsOfAgent[agent];
    }

    function tempOfAgentAt(address agent, uint256 index) external view returns (address) {
        return _tempsOfAgent[agent][index];
    }

    function merchantsOfAgentLength(address agent) external view returns (uint256) {
        return _merchantsOfAgent[agent].length;
    }

    function merchantsOfAgent(address agent) external view returns (address[] memory) {
        return _merchantsOfAgent[agent];
    }

    function merchantOfAgentAt(address agent, uint256 index) external view returns (address) {
        return _merchantsOfAgent[agent][index];
    }

    function refereesOfLength(address introducer) external view returns (uint256) {
        return _refereesOf[introducer].length;
    }

    function refereesOf(address introducer) external view returns (address[] memory) {
        return _refereesOf[introducer];
    }

    function refereeOfAt(address introducer, uint256 index) external view returns (address) {
        return _refereesOf[introducer][index];
    }

    // ---- Admin ----

    function addAdmin(address a) external onlyAdmin {
        if (a == address(0)) revert ZeroAddress();
        admins[a] = true;
        emit AdminAdded(a);
    }

    function removeAdmin(address a) external onlyAdmin {
        admins[a] = false;
        emit AdminRemoved(a);
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    uint256[40] private __gap;
}
