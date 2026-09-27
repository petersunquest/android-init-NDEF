// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "../contracts/utils/cryptography/MessageHashUtils.sol";
import "./Errors.sol";
import "./GovernanceStorage.sol";

interface IKycCardCtx {
    function owner() external view returns (address);
    function factoryGateway() external view returns (address);
}

interface IKycFactoryAuth {
    function owner() external view returns (address);
    function isPaymaster(address account) external view returns (bool);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @dev Per-card KYC link. Slot is namespaced so it never shifts BeamioUserCard linear storage.
library KycLinkOps {
    struct Layout {
        bool kycRequired;
        uint8 nameMode;
        uint8 phoneMode;
        uint8 emailMode;
        mapping(address wallet => bytes32 ipfsHash) ipfsHashOf;
        mapping(address wallet => mapping(uint256 nonce => bool used)) nonceUsed;
    }

    bytes32 private constant SLOT = keccak256("beamio.usercard.kyc.link.storage.v1");
    bytes32 private constant LINK_WALLET_TYPEHASH =
        keccak256("LinkKycIpfsHash(address wallet,bytes32 ipfsHash,uint256 deadline,uint256 nonce)");
    bytes32 private constant LINK_ADMIN_TYPEHASH =
        keccak256("LinkKycIpfsHashByAdmin(address wallet,bytes32 ipfsHash,uint256 deadline,uint256 nonce)");

    error Kyc_InvalidFieldMode(uint8 mode);
    error Kyc_InvalidIpfsHash();

    event KycPolicySet(bool required, uint8 nameMode, uint8 phoneMode, uint8 emailMode);
    event KycIpfsHashLinked(address indexed wallet, bytes32 ipfsHash);

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }

    function kycIpfsHashOf(address wallet) internal view returns (bytes32) {
        return layout().ipfsHashOf[wallet];
    }

    function kycPolicy() internal view returns (bool required, uint8 nameMode, uint8 phoneMode, uint8 emailMode) {
        Layout storage l = layout();
        return (l.kycRequired, l.nameMode, l.phoneMode, l.emailMode);
    }

    function setKycPolicy(bool required, uint8 nameMode, uint8 phoneMode, uint8 emailMode) internal {
        _requireCardOwnerOrPaymaster();
        _requireMode(nameMode);
        _requireMode(phoneMode);
        _requireMode(emailMode);
        Layout storage l = layout();
        l.kycRequired = required;
        l.nameMode = nameMode;
        l.phoneMode = phoneMode;
        l.emailMode = emailMode;
        emit KycPolicySet(required, nameMode, phoneMode, emailMode);
    }

    function linkKycIpfsHashWithSignature(
        address wallet,
        bytes32 ipfsHash,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) internal {
        if (wallet == address(0)) revert BM_ZeroAddress();
        if (ipfsHash == bytes32(0)) revert Kyc_InvalidIpfsHash();
        if (block.timestamp > deadline) revert UC_InvalidTimeWindow(block.timestamp, 0, deadline);
        Layout storage l = layout();
        if (l.nonceUsed[wallet][nonce]) revert UC_NonceUsed();
        bytes32 digest = _digest(LINK_WALLET_TYPEHASH, wallet, ipfsHash, deadline, nonce);
        address signer = ECDSA.recover(digest, signature);
        if (signer != wallet) revert BM_NotAuthorized();
        l.nonceUsed[wallet][nonce] = true;
        l.ipfsHashOf[wallet] = ipfsHash;
        emit KycIpfsHashLinked(wallet, ipfsHash);
    }

    function linkKycIpfsHashByAdmin(
        address wallet,
        bytes32 ipfsHash,
        uint256 deadline,
        uint256 nonce,
        bytes calldata adminSignature
    ) internal {
        if (wallet == address(0)) revert BM_ZeroAddress();
        if (ipfsHash == bytes32(0)) revert Kyc_InvalidIpfsHash();
        if (block.timestamp > deadline) revert UC_InvalidTimeWindow(block.timestamp, 0, deadline);
        _requirePaymasterOrAdminCaller();
        Layout storage l = layout();
        if (l.nonceUsed[wallet][nonce]) revert UC_NonceUsed();
        bytes32 digest = _digest(LINK_ADMIN_TYPEHASH, wallet, ipfsHash, deadline, nonce);
        address admin = ECDSA.recover(digest, adminSignature);
        if (admin == address(0) || !GovernanceStorage.layout().isAdmin[admin]) revert BM_NotAuthorized();
        l.nonceUsed[wallet][nonce] = true;
        l.ipfsHashOf[wallet] = ipfsHash;
        emit KycIpfsHashLinked(wallet, ipfsHash);
    }

    function _digest(
        bytes32 typehash,
        address wallet,
        bytes32 ipfsHash,
        uint256 deadline,
        uint256 nonce
    ) private view returns (bytes32) {
        address factory = IKycCardCtx(address(this)).factoryGateway();
        bytes32 domain = IKycFactoryAuth(factory).DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(abi.encode(typehash, wallet, ipfsHash, deadline, nonce));
        return MessageHashUtils.toTypedDataHash(domain, structHash);
    }

    function _requireMode(uint8 mode) private pure {
        if (mode > 2) revert Kyc_InvalidFieldMode(mode);
    }

    function _requireCardOwnerOrPaymaster() private view {
        if (msg.sender == IKycCardCtx(address(this)).owner()) return;
        _requirePaymasterOrFactoryOwner();
    }

    function _requirePaymasterOrAdminCaller() private view {
        if (GovernanceStorage.layout().isAdmin[msg.sender]) return;
        _requirePaymasterOrFactoryOwner();
    }

    function _requirePaymasterOrFactoryOwner() private view {
        address factory = IKycCardCtx(address(this)).factoryGateway();
        IKycFactoryAuth auth = IKycFactoryAuth(factory);
        if (msg.sender == auth.owner() || auth.isPaymaster(msg.sender)) return;
        revert BM_NotAuthorized();
    }
}
