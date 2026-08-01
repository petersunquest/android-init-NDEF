// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "../contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

/**
 * @dev Reusable EIP-2612 permit + EIP-3009 transferWithAuthorization / receiveWithAuthorization
 *      for custom ERC20 implementations (FactoryERC20, BeamioBUnits, …).
 *
 * Child contracts must implement {_transferForAuth} and {_approveForAuth}.
 */
abstract contract EIP20Permit3009 is EIP712 {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    constructor(string memory tokenName) EIP712(tokenName, "1") {}

    bytes32 private constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        keccak256(
            "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );

    bytes32 private constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        keccak256(
            "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );

    bytes32 private constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    /// @dev EIP-2612 sequential nonce per owner (independent from EIP-3009 bytes32 nonces).
    mapping(address => uint256) private _permitNonces;

    /// @dev EIP-3009 authorization replay protection: authorizer => nonce => used.
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    error EIP2612ExpiredSignature(uint256 deadline);
    error EIP2612InvalidSigner(address signer, address owner);
    error EIP3009AuthorizationNotYetValid(uint256 validAfter);
    error EIP3009AuthorizationExpired(uint256 validBefore);
    error EIP3009AuthorizationAlreadyUsed(address authorizer, bytes32 nonce);
    error EIP3009InvalidSignature();
    error EIP3009CallerMustBePayee(address caller, address payee);

    /// @notice EIP-2612 sequential nonce per owner.
    function nonces(address owner) external view returns (uint256) {
        return _permitNonces[owner];
    }

    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // -----------------------------------------------------------------------------------------------
    //  EIP-2612 permit
    // -----------------------------------------------------------------------------------------------

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual {
        _permit(owner, spender, value, deadline, v, r, s);
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _permit(owner, spender, value, deadline, signature);
    }

    function _permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (block.timestamp > deadline) revert EIP2612ExpiredSignature(deadline);
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, spender, value, _usePermitNonce(owner), deadline)
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (signer != owner) revert EIP2612InvalidSigner(signer, owner);
        _approveForAuth(owner, spender, value);
    }

    function _permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        if (block.timestamp > deadline) revert EIP2612ExpiredSignature(deadline);
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, owner, spender, value, _usePermitNonce(owner), deadline)
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), v, r, s);
        if (signer != owner) revert EIP2612InvalidSigner(signer, owner);
        _approveForAuth(owner, spender, value);
    }

    function _usePermitNonce(address owner) private returns (uint256) {
        unchecked {
            return _permitNonces[owner]++;
        }
    }

    // -----------------------------------------------------------------------------------------------
    //  EIP-3009
    // -----------------------------------------------------------------------------------------------

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        _requireValidAuthorizationWindow(validAfter, validBefore);
        _requireUnusedAuthorization(from, nonce);
        bytes32 structHash = keccak256(
            abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != from) revert EIP3009InvalidSignature();
        _markAuthorizationUsed(from, nonce);
        _transferForAuth(from, to, value);
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _requireValidAuthorizationWindow(validAfter, validBefore);
        _requireUnusedAuthorization(from, nonce);
        bytes32 structHash = keccak256(
            abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), v, r, s) != from) revert EIP3009InvalidSignature();
        _markAuthorizationUsed(from, nonce);
        _transferForAuth(from, to, value);
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        if (msg.sender != to) revert EIP3009CallerMustBePayee(msg.sender, to);
        _requireValidAuthorizationWindow(validAfter, validBefore);
        _requireUnusedAuthorization(from, nonce);
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != from) revert EIP3009InvalidSignature();
        _markAuthorizationUsed(from, nonce);
        _transferForAuth(from, to, value);
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (msg.sender != to) revert EIP3009CallerMustBePayee(msg.sender, to);
        _requireValidAuthorizationWindow(validAfter, validBefore);
        _requireUnusedAuthorization(from, nonce);
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), v, r, s) != from) revert EIP3009InvalidSignature();
        _markAuthorizationUsed(from, nonce);
        _transferForAuth(from, to, value);
    }

    function cancelAuthorization(address authorizer, bytes32 nonce, bytes calldata signature) external {
        _requireUnusedAuthorization(authorizer, nonce);
        bytes32 structHash = keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce));
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != authorizer) revert EIP3009InvalidSignature();
        _markAuthorizationUsed(authorizer, nonce);
    }

    function cancelAuthorization(
        address authorizer,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _requireUnusedAuthorization(authorizer, nonce);
        bytes32 structHash = keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce));
        if (ECDSA.recover(_hashTypedDataV4(structHash), v, r, s) != authorizer) revert EIP3009InvalidSignature();
        _markAuthorizationUsed(authorizer, nonce);
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

    /// @dev Move tokens for EIP-3009 (and optionally permit spend paths in child).
    function _transferForAuth(address from, address to, uint256 value) internal virtual;

    /// @dev Set allowance for EIP-2612 permit.
    function _approveForAuth(address owner, address spender, uint256 value) internal virtual;
}
