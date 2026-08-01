// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "../contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

/**
 * @dev EIP-2612-style permit for ERC1155 `setApprovalForAll`, plus EIP-3009-style
 *      signed single-id transfers. Used by ConetGB1155 (normally non-transferable).
 *
 * Child must implement {_authTransfer1155} to perform the actual balance move.
 */
abstract contract EIP1155Permit3009 is EIP712 {
    bytes32 private constant PERMIT_FOR_ALL_TYPEHASH =
        keccak256(
            "PermitForAll(address owner,address operator,bool approved,uint256 nonce,uint256 deadline)"
        );

    bytes32 private constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        keccak256(
            "TransferWithAuthorization1155(address from,address to,uint256 id,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );

    constructor(string memory tokenName) EIP712(tokenName, "1") {}

    mapping(address => uint256) private _permitNonces;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    error EIP2612ExpiredSignature(uint256 deadline);
    error EIP2612InvalidSigner(address signer, address owner);
    error EIP3009AuthorizationNotYetValid(uint256 validAfter);
    error EIP3009AuthorizationExpired(uint256 validBefore);
    error EIP3009AuthorizationAlreadyUsed(address authorizer, bytes32 nonce);
    error EIP3009InvalidSignature();

    function nonces(address owner) external view returns (uint256) {
        return _permitNonces[owner];
    }

    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // -----------------------------------------------------------------------------------------------
    //  EIP-2612-style permit → setApprovalForAll
    // -----------------------------------------------------------------------------------------------

    function permitForAll(
        address owner,
        address operator,
        bool approved,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert EIP2612ExpiredSignature(deadline);
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_FOR_ALL_TYPEHASH, owner, operator, approved, _usePermitNonce(owner), deadline)
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (signer != owner) revert EIP2612InvalidSigner(signer, owner);
        _setApprovalForAll(owner, operator, approved);
    }

    function _usePermitNonce(address owner) private returns (uint256) {
        unchecked {
            return _permitNonces[owner]++;
        }
    }

    // -----------------------------------------------------------------------------------------------
    //  EIP-3009-style signed ERC1155 transfer (single id)
    // -----------------------------------------------------------------------------------------------

    function transferWithAuthorization(
        address from,
        address to,
        uint256 id,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        _requireValidAuthorizationWindow(validAfter, validBefore);
        _requireUnusedAuthorization(from, nonce);
        bytes32 structHash = keccak256(
            abi.encode(
                TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
                from,
                to,
                id,
                value,
                validAfter,
                validBefore,
                nonce
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != from) revert EIP3009InvalidSignature();
        _markAuthorizationUsed(from, nonce);
        _authTransfer1155(from, to, id, value);
    }

    function _requireValidAuthorizationWindow(uint256 validAfter, uint256 validBefore) internal view {
        if (block.timestamp <= validAfter) revert EIP3009AuthorizationNotYetValid(validAfter);
        if (block.timestamp >= validBefore) revert EIP3009AuthorizationExpired(validBefore);
    }

    function _requireUnusedAuthorization(address authorizer, bytes32 nonce) internal view {
        if (authorizationState[authorizer][nonce]) revert EIP3009AuthorizationAlreadyUsed(authorizer, nonce);
    }

    function _markAuthorizationUsed(address authorizer, bytes32 nonce) internal {
        authorizationState[authorizer][nonce] = true;
        emit AuthorizationUsed(authorizer, nonce);
    }

    function _setApprovalForAll(address owner, address operator, bool approved) internal virtual;

    function _authTransfer1155(address from, address to, uint256 id, uint256 value) internal virtual;
}
