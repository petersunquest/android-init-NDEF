// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

/**
 * @title ChatIndexRegistry
 * @notice On-chain head pointer for a wallet's encrypted chat-history index (IPFS content hash).
 *
 * @dev Each EOA owns a single mutable pointer to the keccak256 content hash of its latest encrypted
 *      history index (stored as a content-addressed IPFS fragment). The pointer is updated with an
 *      EIP-712 signature produced offline by the owner EOA; ANYONE may submit that signed update
 *      (e.g. a gasless relayer/API server pays gas). Only the owner's signature can move the owner's
 *      pointer, so the write right is protected by the private key and cannot be hijacked by a relayer
 *      or a third-party attacker.
 *
 *      Replay protection: a strictly increasing per-owner {nonces} guarantees each signature is single
 *      use and that updates apply in signed order. {ts} / {seq} are stored as non-decreasing metadata so
 *      the head can never silently roll back.
 *
 *      Recovery model: on a fresh device the owner re-derives the same EOA from its mnemonic, reads
 *      {getPointer} via RPC to obtain the latest index hash, fetches the encrypted index from IPFS by
 *      content hash, decrypts it and rehydrates the fragmented history — no server-side mutable state.
 *
 *      UUPS upgradeable; canonical address = ERC1967 proxy. See beamio-contract-upgradeable-address-stable.mdc.
 */
contract ChatIndexRegistry is Initializable, UUPSUpgradeable {
    struct Pointer {
        bytes32 indexHash; // keccak256 IPFS content hash of the latest encrypted history index
        uint64 ts; // client-chosen monotonic timestamp (unix ms recommended); non-decreasing
        uint64 seq; // monotonic append sequence; non-decreasing
        uint64 updatedAt; // block.timestamp when this pointer was recorded on-chain
    }

    // ---- EIP-712 (hand-rolled domain, cached chainId — same pattern as ValidatorDepositRedeem) ----
    bytes32 private constant _EIP712_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("ChatIndexRegistry");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("1");
    bytes32 private constant _SET_POINTER_TYPEHASH =
        keccak256("SetPointer(address owner,bytes32 indexHash,uint64 ts,uint64 seq,uint256 nonce)");

    bytes32 private _eip712CachedChainId;
    bytes32 private _eip712CachedSeparator;

    /// @notice Contract admins — sole role allowed to authorize UUPS upgrades and manage admins.
    mapping(address => bool) public admins;
    /// @notice Latest head pointer per owner EOA.
    mapping(address => Pointer) public pointerOf;
    /// @notice Per-owner EIP-712 nonce (strictly increasing; replay protection + signed ordering).
    mapping(address => uint256) public nonces;

    event PointerUpdated(address indexed owner, bytes32 indexHash, uint64 ts, uint64 seq, uint256 nonce);
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);

    modifier onlyAdmin() {
        require(admins[msg.sender], "ChatIndexRegistry: not admin");
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

    // ---- EIP-712 helpers ----
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

    /// @notice EIP-712 domain separator for clients constructing the SetPointer signature.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---- Write: gasless relay path (anyone may submit; only owner's signature authorizes) ----
    /**
     * @notice Record the owner's latest encrypted-index content hash, authorized by an offline EIP-712
     *         signature from `owner`. The submitter (relayer) pays gas; the pointer is bound to `owner`.
     * @param owner     The wallet whose head pointer is updated (EIP-712 signer).
     * @param indexHash keccak256 IPFS content hash of the encrypted history index (non-zero).
     * @param ts        Client monotonic timestamp (non-decreasing vs current).
     * @param seq       Client monotonic append sequence (non-decreasing vs current).
     * @param nonce     Must equal the owner's current {nonces} value.
     * @param signature 65-byte EIP-712 signature over SetPointer(owner,indexHash,ts,seq,nonce).
     */
    function setPointerWithSig(
        address owner,
        bytes32 indexHash,
        uint64 ts,
        uint64 seq,
        uint256 nonce,
        bytes calldata signature
    ) external {
        require(owner != address(0), "ChatIndexRegistry: zero owner");
        require(indexHash != bytes32(0), "ChatIndexRegistry: zero index");
        require(nonce == nonces[owner], "ChatIndexRegistry: bad nonce");
        Pointer storage cur = pointerOf[owner];
        require(ts >= cur.ts, "ChatIndexRegistry: stale ts");
        require(seq >= cur.seq, "ChatIndexRegistry: stale seq");

        bytes32 structHash = keccak256(abi.encode(_SET_POINTER_TYPEHASH, owner, indexHash, ts, seq, nonce));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == owner, "ChatIndexRegistry: bad sig");

        nonces[owner] = nonce + 1;
        cur.indexHash = indexHash;
        cur.ts = ts;
        cur.seq = seq;
        cur.updatedAt = uint64(block.timestamp);
        emit PointerUpdated(owner, indexHash, ts, seq, nonce);
    }

    /// @notice Owner self-write (pays own gas). Same monotonic + nonce semantics as the relayed path.
    function setPointer(bytes32 indexHash, uint64 ts, uint64 seq) external {
        require(indexHash != bytes32(0), "ChatIndexRegistry: zero index");
        Pointer storage cur = pointerOf[msg.sender];
        require(ts >= cur.ts, "ChatIndexRegistry: stale ts");
        require(seq >= cur.seq, "ChatIndexRegistry: stale seq");
        uint256 n = nonces[msg.sender];
        nonces[msg.sender] = n + 1;
        cur.indexHash = indexHash;
        cur.ts = ts;
        cur.seq = seq;
        cur.updatedAt = uint64(block.timestamp);
        emit PointerUpdated(msg.sender, indexHash, ts, seq, n);
    }

    // ---- Read ----
    function getPointer(address owner)
        external
        view
        returns (bytes32 indexHash, uint64 ts, uint64 seq, uint64 updatedAt)
    {
        Pointer storage p = pointerOf[owner];
        return (p.indexHash, p.ts, p.seq, p.updatedAt);
    }

    function nonceOf(address owner) external view returns (uint256) {
        return nonces[owner];
    }

    // ---- Admin ----
    function addAdmin(address a) external onlyAdmin {
        require(a != address(0), "ChatIndexRegistry: zero admin");
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

    uint256[45] private __gap;
}
