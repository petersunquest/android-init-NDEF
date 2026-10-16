// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

interface IMerchantCardRoles {
    function owner() external view returns (address);
    function isAdmin(address account) external view returns (bool);
}

/**
 * @title BeamioAgentRegistry
 * @notice CoNET registry of agent temp EOAs used to create one merchant program card.
 *
 * A used temp EOA is bound to at most one card. The row stores the agent, that temp,
 * the card, the merchant EOA that later receives owner(), and the merchant's POS
 * disposition. Completed rows are the airdrop input. The airdrop recipient is the
 * merchant EOA.
 *
 * Writes that an EOA authorizes use an offline EIP-712 signature. Any relayer,
 * including the Beamio API, may submit and pay gas. Binding the card after create
 * is admin-only so a third party cannot attach a different card the temp happens
 * to own. This contract does not move card owner() and does not add or remove admins.
 *
 * UUPS. Canonical address is the ERC1967 proxy. Not deployed by this source file.
 */
contract BeamioAgentRegistry is Initializable, UUPSUpgradeable {
    uint8 public constant POS_UNSET = 0;
    uint8 public constant POS_REVOKE_ALL = 1;
    uint8 public constant POS_ACCEPT_ALL = 2;

    struct Issuance {
        address agent;
        address merchant;
        address card;
        uint64 reservedAt;
        uint64 boundAt;
        uint64 handedOffAt;
        uint64 disposedAt;
        uint8 posDisposition;
        bool reserved;
        bool used;
    }

    struct AirdropBasis {
        address agent;
        address merchant;
        address card;
        uint8 posDisposition;
        bool complete;
    }

    bytes32 private constant _EIP712_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("BeamioAgentRegistry");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("1");
    bytes32 private constant _RESERVE_TYPEHASH =
        keccak256("ReserveTemp(address agent,address temp,uint256 nonce,uint256 deadline)");
    bytes32 private constant _DISPOSE_TYPEHASH = keccak256(
        "DisposePos(address merchant,address temp,address card,uint8 posDisposition,uint256 nonce,uint256 deadline)"
    );

    bytes32 private _eip712CachedChainId;
    bytes32 private _eip712CachedSeparator;

    mapping(address => bool) public admins;
    mapping(address => Issuance) private _issuanceOf;
    mapping(address => address) public tempOfCard;
    mapping(address => uint256) public nonces;
    mapping(address => address[]) private _tempsOfAgent;

    event TempReserved(address indexed agent, address indexed temp, uint256 nonce);
    event CardBound(address indexed agent, address indexed temp, address indexed card);
    event MerchantRecorded(address indexed temp, address indexed card, address indexed merchant);
    event PosDisposed(address indexed temp, address indexed card, address indexed merchant, uint8 posDisposition);
    event AdminUpdated(address indexed admin, bool enabled);

    error NotAdmin();
    error ZeroAddress();
    error BadDeadline();
    error BadNonce();
    error BadSignature();
    error TempTaken();
    error NotReserved();
    error AlreadyUsed();
    error CardTaken();
    error OwnerMismatch();
    error MerchantAlreadySet();
    error DispositionUnsetOrInvalid();
    error DispositionAlreadySet();
    error HandoffIncomplete();
    error PageOutOfRange();

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
        if (initialAdmin == address(0)) revert ZeroAddress();
        admins[initialAdmin] = true;
        emit AdminUpdated(initialAdmin, true);
    }

    function _authorizeUpgrade(address) internal view override onlyAdmin {}

    function addAdmin(address account) external onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        admins[account] = true;
        emit AdminUpdated(account, true);
    }

    function removeAdmin(address account) external onlyAdmin {
        admins[account] = false;
        emit AdminUpdated(account, false);
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function issuanceOf(address temp)
        external
        view
        returns (
            address agent,
            address merchant,
            address card,
            uint64 reservedAt,
            uint64 boundAt,
            uint64 handedOffAt,
            uint64 disposedAt,
            uint8 posDisposition,
            bool reserved,
            bool used
        )
    {
        Issuance storage row = _issuanceOf[temp];
        return (
            row.agent,
            row.merchant,
            row.card,
            row.reservedAt,
            row.boundAt,
            row.handedOffAt,
            row.disposedAt,
            row.posDisposition,
            row.reserved,
            row.used
        );
    }

    /// @notice True after this temp EOA has been bound to a created card.
    function isUsedTemp(address temp) external view returns (bool) {
        return _issuanceOf[temp].used;
    }

    function tempCountOfAgent(address agent) external view returns (uint256) {
        return _tempsOfAgent[agent].length;
    }

    function tempsOfAgent(address agent, uint256 offset, uint256 limit) external view returns (address[] memory) {
        address[] storage all = _tempsOfAgent[agent];
        if (offset > all.length) revert PageOutOfRange();
        uint256 end = offset + limit;
        if (end > all.length) end = all.length;
        address[] memory page = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = all[i];
        }
        return page;
    }

    /**
     * @notice Agent attests a fresh temp EOA before createCard. Relayer pays gas.
     * @dev A second reservation of the same temp reverts. This does not mark the temp used.
     */
    function reserveTempWithSig(address agent, address temp, uint256 nonce, uint256 deadline, bytes calldata signature)
        external
    {
        if (agent == address(0) || temp == address(0) || agent == temp) revert ZeroAddress();
        if (block.timestamp > deadline) revert BadDeadline();
        if (nonce != nonces[agent]) revert BadNonce();
        Issuance storage row = _issuanceOf[temp];
        if (row.reserved || row.used) revert TempTaken();

        bytes32 structHash = keccak256(abi.encode(_RESERVE_TYPEHASH, agent, temp, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (signer != agent) revert BadSignature();

        nonces[agent] = nonce + 1;
        row.agent = agent;
        row.reserved = true;
        row.reservedAt = uint64(block.timestamp);
        _tempsOfAgent[agent].push(temp);
        emit TempReserved(agent, temp, nonce);
    }

    /**
     * @notice After createCard, bind the card whose owner() is this reserved temp.
     * @dev Admin-only. Sets used so the temp cannot be bound to another card.
     */
    function bindCard(address temp, address card) external onlyAdmin {
        if (temp == address(0) || card == address(0)) revert ZeroAddress();
        Issuance storage row = _issuanceOf[temp];
        if (!row.reserved || row.agent == address(0)) revert NotReserved();
        if (row.used) revert AlreadyUsed();
        if (tempOfCard[card] != address(0)) revert CardTaken();
        if (IMerchantCardRoles(card).owner() != temp) revert OwnerMismatch();

        row.card = card;
        row.used = true;
        row.boundAt = uint64(block.timestamp);
        tempOfCard[card] = temp;
        emit CardBound(row.agent, temp, card);
    }

    /**
     * @notice Record the merchant EOA after owner() has moved off the temp.
     * @dev Permissionless. Accepts the write only when the card's current owner is `merchant`.
     */
    function recordMerchant(address temp, address merchant) external {
        if (temp == address(0) || merchant == address(0) || merchant == temp) revert ZeroAddress();
        Issuance storage row = _issuanceOf[temp];
        if (!row.used || row.card == address(0)) revert HandoffIncomplete();
        if (row.merchant != address(0)) revert MerchantAlreadySet();
        if (IMerchantCardRoles(row.card).owner() != merchant) revert OwnerMismatch();

        row.merchant = merchant;
        row.handedOffAt = uint64(block.timestamp);
        emit MerchantRecorded(temp, row.card, merchant);
    }

    /**
     * @notice Merchant records revoke-all (1) or accept-all (2). Relayer pays gas.
     * @dev Does not change card admins. The card Governance calls do that. This stores the choice.
     */
    function disposePosWithSig(
        address merchant,
        address temp,
        address card,
        uint8 posDisposition,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (merchant == address(0) || temp == address(0) || card == address(0)) revert ZeroAddress();
        if (posDisposition != POS_REVOKE_ALL && posDisposition != POS_ACCEPT_ALL) revert DispositionUnsetOrInvalid();
        if (block.timestamp > deadline) revert BadDeadline();
        if (nonce != nonces[merchant]) revert BadNonce();

        Issuance storage row = _issuanceOf[temp];
        if (!row.used || row.card != card || row.merchant != merchant) revert HandoffIncomplete();
        if (row.posDisposition != POS_UNSET) revert DispositionAlreadySet();
        if (IMerchantCardRoles(card).owner() != merchant) revert OwnerMismatch();

        bytes32 structHash =
            keccak256(abi.encode(_DISPOSE_TYPEHASH, merchant, temp, card, posDisposition, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (signer != merchant) revert BadSignature();

        nonces[merchant] = nonce + 1;
        row.posDisposition = posDisposition;
        row.disposedAt = uint64(block.timestamp);
        emit PosDisposed(temp, card, merchant, posDisposition);
    }

    /**
     * @notice Airdrop input. `complete` is true only for a finished handoff.
     * @dev Recipient is `merchant`. A card read that reverts yields complete = false.
     */
    function airdropBasis(address temp) external view returns (AirdropBasis memory basis) {
        Issuance storage row = _issuanceOf[temp];
        basis.agent = row.agent;
        basis.merchant = row.merchant;
        basis.card = row.card;
        basis.posDisposition = row.posDisposition;
        basis.complete = false;
        if (!row.used || row.merchant == address(0) || row.card == address(0)) return basis;
        if (row.posDisposition != POS_REVOKE_ALL && row.posDisposition != POS_ACCEPT_ALL) return basis;
        try IMerchantCardRoles(row.card).owner() returns (address liveOwner) {
            if (liveOwner != row.merchant) return basis;
        } catch {
            return basis;
        }
        try IMerchantCardRoles(row.card).isAdmin(temp) returns (bool tempIsAdmin) {
            if (tempIsAdmin) return basis;
        } catch {
            return basis;
        }
        basis.complete = true;
    }

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

    uint256[40] private __gap;
}
