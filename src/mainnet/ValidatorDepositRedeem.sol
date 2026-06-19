// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "../contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

/**
 * @title ValidatorDepositRedeem
 * @notice Admin issues one-time redeem codes that authorize a specific validator node IP to add validators.
 * @dev The contract does not custody funds or run deposits. Local geth/beacon/validator nodes listen for
 *      ValidatorRedeemClaimed and execute the node-local workflow with their own dedicated deposit key file.
 */
contract ValidatorDepositRedeem is EIP712 {
    uint256 private constant _MAX_REDEEM_CODE_LEN = 512;
    uint256 private constant _MAX_IP_LEN = 64;

    mapping(address => bool) public redeemAdmins;
    mapping(address => uint256) public redeemAdminNonces;

    struct Redeem {
        address allowedClaimer;
        uint128 validatorCount;
        uint128 gbMiningNodeCount;
        uint64 validAfter;
        uint64 validBefore;
        bool active;
        bool consumed;
        string targetNodeIp;
        string[] conetDepinNodeIps;
    }

    mapping(bytes32 => Redeem) private _redeems;

    bytes32 private constant CREATE_REDEEM_TYPEHASH = keccak256(
        "CreateRedeem(address admin,bytes32 codeHash,address allowedClaimer,uint256 validatorCount,string targetNodeIp,bytes32 conetDepinNodeIpsHash,uint256 gbMiningNodeCount,uint256 validAfter,uint256 validBefore,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant CANCEL_REDEEM_TYPEHASH =
        keccak256("CancelRedeem(address admin,bytes32 codeHash,uint256 nonce,uint256 deadline)");
    bytes32 private constant ADD_REDEEM_ADMIN_TYPEHASH =
        keccak256("AddRedeemAdmin(address admin,address account,uint256 nonce,uint256 deadline)");
    bytes32 private constant REMOVE_REDEEM_ADMIN_TYPEHASH =
        keccak256("RemoveRedeemAdmin(address admin,address account,uint256 nonce,uint256 deadline)");
    bytes32 private constant CLAIM_REDEEM_TYPEHASH = keccak256(
        "ClaimRedeem(address claimer,bytes32 codeHash,address beneficiary,uint256 validatorCount,string targetNodeIp,bytes32 conetDepinNodeIpsHash,uint256 gbMiningNodeCount,uint256 deadline)"
    );

    event RedeemAdminAdded(address indexed account);
    event RedeemAdminRemoved(address indexed account);
    event ValidatorRedeemCreated(
        bytes32 indexed codeHash,
        address indexed allowedClaimer,
        uint256 validatorCount,
        string targetNodeIp,
        string[] conetDepinNodeIps,
        uint256 gbMiningNodeCount,
        uint64 validAfter,
        uint64 validBefore
    );
    event ValidatorRedeemCancelled(bytes32 indexed codeHash);
    event ValidatorRedeemClaimed(
        bytes32 indexed requestId,
        bytes32 indexed codeHash,
        address indexed claimer,
        address beneficiary,
        uint256 validatorCount,
        string targetNodeIp,
        string[] conetDepinNodeIps,
        uint256 gbMiningNodeCount
    );

    modifier onlyRedeemAdmin() {
        require(redeemAdmins[msg.sender], "ValidatorRedeem: not admin");
        _;
    }

    constructor(address initialRedeemAdmin) EIP712("ValidatorDepositRedeem", "1") {
        address admin = initialRedeemAdmin == address(0) ? msg.sender : initialRedeemAdmin;
        redeemAdmins[admin] = true;
        emit RedeemAdminAdded(admin);
    }

    function addRedeemAdmin(address account) external onlyRedeemAdmin {
        require(account != address(0), "ValidatorRedeem: zero admin");
        redeemAdmins[account] = true;
        emit RedeemAdminAdded(account);
    }

    function addRedeemAdminFor(
        address admin,
        address account,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(redeemAdmins[admin], "ValidatorRedeem: not admin");
        require(account != address(0), "ValidatorRedeem: zero admin");
        require(redeemAdminNonces[admin] == nonce, "ValidatorRedeem: bad nonce");

        bytes32 structHash = keccak256(abi.encode(ADD_REDEEM_ADMIN_TYPEHASH, admin, account, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "ValidatorRedeem: bad sig");

        redeemAdminNonces[admin]++;
        redeemAdmins[account] = true;
        emit RedeemAdminAdded(account);
    }

    function removeRedeemAdmin(address account) external onlyRedeemAdmin {
        require(account != msg.sender, "ValidatorRedeem: cannot remove self");
        redeemAdmins[account] = false;
        emit RedeemAdminRemoved(account);
    }

    function removeRedeemAdminFor(
        address admin,
        address account,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(redeemAdmins[admin], "ValidatorRedeem: not admin");
        require(redeemAdminNonces[admin] == nonce, "ValidatorRedeem: bad nonce");

        bytes32 structHash = keccak256(abi.encode(REMOVE_REDEEM_ADMIN_TYPEHASH, admin, account, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "ValidatorRedeem: bad sig");

        redeemAdminNonces[admin]++;
        redeemAdmins[account] = false;
        emit RedeemAdminRemoved(account);
    }

    function createRedeem(
        bytes32 codeHash,
        address allowedClaimer,
        uint256 validatorCount,
        string calldata targetNodeIp,
        string[] calldata conetDepinNodeIps,
        uint256 gbMiningNodeCount,
        uint64 validAfter,
        uint64 validBefore
    ) external onlyRedeemAdmin {
        _applyCreateRedeem(
            codeHash,
            allowedClaimer,
            validatorCount,
            targetNodeIp,
            conetDepinNodeIps,
            gbMiningNodeCount,
            validAfter,
            validBefore
        );
    }

    function createRedeemFor(
        address admin,
        bytes32 codeHash,
        address allowedClaimer,
        uint256 validatorCount,
        string calldata targetNodeIp,
        string[] calldata conetDepinNodeIps,
        uint256 gbMiningNodeCount,
        uint256 validAfter,
        uint256 validBefore,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(redeemAdmins[admin], "ValidatorRedeem: not admin");
        require(redeemAdminNonces[admin] == nonce, "ValidatorRedeem: bad nonce");
        require(validAfter <= type(uint64).max && validBefore <= type(uint64).max, "ValidatorRedeem: time overflow");

        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_REDEEM_TYPEHASH,
                admin,
                codeHash,
                allowedClaimer,
                validatorCount,
                keccak256(bytes(targetNodeIp)),
                hashStringArray(conetDepinNodeIps),
                gbMiningNodeCount,
                validAfter,
                validBefore,
                nonce,
                deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "ValidatorRedeem: bad sig");

        redeemAdminNonces[admin]++;
        _applyCreateRedeem(
            codeHash,
            allowedClaimer,
            validatorCount,
            targetNodeIp,
            conetDepinNodeIps,
            gbMiningNodeCount,
            uint64(validAfter),
            uint64(validBefore)
        );
    }

    function cancelRedeem(bytes32 codeHash) external onlyRedeemAdmin {
        _applyCancelRedeem(codeHash);
    }

    function cancelRedeemFor(
        address admin,
        bytes32 codeHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(redeemAdmins[admin], "ValidatorRedeem: not admin");
        require(redeemAdminNonces[admin] == nonce, "ValidatorRedeem: bad nonce");

        bytes32 structHash = keccak256(abi.encode(CANCEL_REDEEM_TYPEHASH, admin, codeHash, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "ValidatorRedeem: bad sig");

        redeemAdminNonces[admin]++;
        _applyCancelRedeem(codeHash);
    }

    function claimRedeemFor(
        address claimer,
        address beneficiary,
        string calldata code,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bytes32 requestId) {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(claimer != address(0), "ValidatorRedeem: zero claimer");
        require(beneficiary != address(0), "ValidatorRedeem: zero beneficiary");
        bytes memory b = bytes(code);
        require(b.length > 0 && b.length <= _MAX_REDEEM_CODE_LEN, "ValidatorRedeem: bad code len");
        bytes32 codeHash = keccak256(b);

        Redeem storage r = _redeems[codeHash];
        require(r.active, "ValidatorRedeem: inactive");
        require(!r.consumed, "ValidatorRedeem: consumed");
        require(_timeOk(r.validAfter, r.validBefore), "ValidatorRedeem: time window");
        require(r.allowedClaimer == address(0) || r.allowedClaimer == claimer, "ValidatorRedeem: claimer not allowed");

        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_REDEEM_TYPEHASH,
                claimer,
                codeHash,
                beneficiary,
                uint256(r.validatorCount),
                keccak256(bytes(r.targetNodeIp)),
                _hashStoredStringArray(r.conetDepinNodeIps),
                uint256(r.gbMiningNodeCount),
                deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == claimer, "ValidatorRedeem: bad sig");

        requestId = _consumeAndEmit(codeHash, claimer, beneficiary, r);
    }

    function claimRedeem(string calldata code, address beneficiary) external returns (bytes32 requestId) {
        require(beneficiary != address(0), "ValidatorRedeem: zero beneficiary");
        bytes memory b = bytes(code);
        require(b.length > 0 && b.length <= _MAX_REDEEM_CODE_LEN, "ValidatorRedeem: bad code len");
        bytes32 codeHash = keccak256(b);

        Redeem storage r = _redeems[codeHash];
        require(r.active, "ValidatorRedeem: inactive");
        require(!r.consumed, "ValidatorRedeem: consumed");
        require(_timeOk(r.validAfter, r.validBefore), "ValidatorRedeem: time window");
        require(r.allowedClaimer == address(0) || r.allowedClaimer == msg.sender, "ValidatorRedeem: claimer not allowed");

        requestId = _consumeAndEmit(codeHash, msg.sender, beneficiary, r);
    }

    function getCreateRedeemDigest(
        address admin,
        bytes32 codeHash,
        address allowedClaimer,
        uint256 validatorCount,
        string calldata targetNodeIp,
        string[] calldata conetDepinNodeIps,
        uint256 gbMiningNodeCount,
        uint256 validAfter,
        uint256 validBefore,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_REDEEM_TYPEHASH,
                admin,
                codeHash,
                allowedClaimer,
                validatorCount,
                keccak256(bytes(targetNodeIp)),
                hashStringArray(conetDepinNodeIps),
                gbMiningNodeCount,
                validAfter,
                validBefore,
                nonce,
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function getClaimRedeemDigest(
        address claimer,
        bytes32 codeHash,
        address beneficiary,
        uint256 deadline
    ) external view returns (bytes32) {
        Redeem storage r = _redeems[codeHash];
        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_REDEEM_TYPEHASH,
                claimer,
                codeHash,
                beneficiary,
                uint256(r.validatorCount),
                keccak256(bytes(r.targetNodeIp)),
                _hashStoredStringArray(r.conetDepinNodeIps),
                uint256(r.gbMiningNodeCount),
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function getCancelRedeemDigest(address admin, bytes32 codeHash, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(CANCEL_REDEEM_TYPEHASH, admin, codeHash, nonce, deadline));
        return _hashTypedDataV4(structHash);
    }

    function getRedeem(bytes32 codeHash)
        external
        view
        returns (
            address allowedClaimer,
            uint256 validatorCount,
            string memory targetNodeIp,
            string[] memory conetDepinNodeIps,
            uint256 gbMiningNodeCount,
            uint64 validAfter,
            uint64 validBefore,
            bool active,
            bool consumed
        )
    {
        Redeem storage r = _redeems[codeHash];
        return (
            r.allowedClaimer,
            uint256(r.validatorCount),
            r.targetNodeIp,
            r.conetDepinNodeIps,
            uint256(r.gbMiningNodeCount),
            r.validAfter,
            r.validBefore,
            r.active,
            r.consumed
        );
    }

    function hashStringArray(string[] memory values) public pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](values.length);
        for (uint256 i = 0; i < values.length; i++) {
            hashes[i] = keccak256(bytes(values[i]));
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _applyCreateRedeem(
        bytes32 codeHash,
        address allowedClaimer,
        uint256 validatorCount,
        string calldata targetNodeIp,
        string[] calldata conetDepinNodeIps,
        uint256 gbMiningNodeCount,
        uint64 validAfter,
        uint64 validBefore
    ) internal {
        require(codeHash != bytes32(0), "ValidatorRedeem: invalid hash");
        require(validatorCount > 0 && validatorCount <= type(uint128).max, "ValidatorRedeem: invalid validators");
        require(gbMiningNodeCount <= type(uint128).max, "ValidatorRedeem: gb overflow");
        require(conetDepinNodeIps.length == validatorCount, "ValidatorRedeem: depin count mismatch");
        _requireValidIpString(targetNodeIp);
        for (uint256 i = 0; i < conetDepinNodeIps.length; i++) {
            _requireValidIpString(conetDepinNodeIps[i]);
        }

        Redeem storage r = _redeems[codeHash];
        require(!r.consumed, "ValidatorRedeem: hash consumed");
        require(!r.active, "ValidatorRedeem: already active");

        r.allowedClaimer = allowedClaimer;
        r.validatorCount = uint128(validatorCount);
        r.gbMiningNodeCount = uint128(gbMiningNodeCount);
        r.validAfter = validAfter;
        r.validBefore = validBefore;
        r.active = true;
        r.targetNodeIp = targetNodeIp;
        for (uint256 i = 0; i < conetDepinNodeIps.length; i++) {
            r.conetDepinNodeIps.push(conetDepinNodeIps[i]);
        }

        emit ValidatorRedeemCreated(
            codeHash,
            allowedClaimer,
            validatorCount,
            targetNodeIp,
            conetDepinNodeIps,
            gbMiningNodeCount,
            validAfter,
            validBefore
        );
    }

    function _applyCancelRedeem(bytes32 codeHash) internal {
        require(codeHash != bytes32(0), "ValidatorRedeem: invalid hash");
        Redeem storage r = _redeems[codeHash];
        require(r.active, "ValidatorRedeem: not active");
        r.active = false;
        emit ValidatorRedeemCancelled(codeHash);
    }

    function _consumeAndEmit(
        bytes32 codeHash,
        address claimer,
        address beneficiary,
        Redeem storage r
    ) internal returns (bytes32 requestId) {
        r.active = false;
        r.consumed = true;
        requestId = keccak256(
            abi.encode(codeHash, claimer, beneficiary, uint256(r.validatorCount), keccak256(bytes(r.targetNodeIp)))
        );
        emit ValidatorRedeemClaimed(
            requestId,
            codeHash,
            claimer,
            beneficiary,
            uint256(r.validatorCount),
            r.targetNodeIp,
            r.conetDepinNodeIps,
            uint256(r.gbMiningNodeCount)
        );
    }

    function _timeOk(uint64 validAfter, uint64 validBefore) internal view returns (bool) {
        uint256 ts = block.timestamp;
        if (validAfter != 0 && ts < validAfter) return false;
        if (validBefore != 0 && ts > validBefore) return false;
        return true;
    }

    function _requireValidIpString(string memory ip) internal pure {
        bytes memory b = bytes(ip);
        require(b.length > 0 && b.length <= _MAX_IP_LEN, "ValidatorRedeem: bad ip len");
    }

    function _hashStoredStringArray(string[] storage values) internal view returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](values.length);
        for (uint256 i = 0; i < values.length; i++) {
            hashes[i] = keccak256(bytes(values[i]));
        }
        return keccak256(abi.encodePacked(hashes));
    }
}
