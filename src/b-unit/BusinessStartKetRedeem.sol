// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "../contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

/**
 * @title BusinessStartKetRedeem
 * @notice 兑换码同时领取 BusinessStartKet ERC-1155 与（可选）B-Unit 免费池：`createRedeem` 指定 `tokenId`、Ket 数量、`buintAmount`。
 * @dev 部署后须：
 *      - `BusinessStartKet.addAdmin(address(this))`
 *      - `BeamioBUnits.addAdmin(address(this))`（与 `BuintRedeemAirdrop` 相同，以便 `mintReward`）
 *      模式对齐 `BuintRedeemAirdrop`：链上 / EIP-712 *For / 用户自领 / Redeem Admin 代领。
 */
interface IBusinessStartKetMint {
    function mint(address to, uint256 id, uint256 amount, bytes calldata data) external;

    function admins(address account) external view returns (bool);
}

interface IBeamioBUnitsMintReward {
    function mintReward(address to, uint256 amount) external;

    function admins(address account) external view returns (bool);
}

contract BusinessStartKetRedeem is EIP712 {
    IBusinessStartKetMint public immutable ket;
    IBeamioBUnitsMintReward public immutable buint;

    uint256 private constant _MAX_REDEEM_CODE_LEN = 512;

    mapping(address => bool) public redeemAdmins;
    mapping(address => uint256) public redeemAdminNonces;

    struct Redeem {
        uint256 tokenId;
        uint128 amount;
        uint128 buintAmount;
        uint64 validAfter;
        uint64 validBefore;
        bool active;
        bool consumed;
    }

    mapping(bytes32 => Redeem) private _redeems;

    bytes32 private constant CREATE_REDEEM_TYPEHASH = keccak256(
        "CreateRedeem(address admin,bytes32 codeHash,uint256 tokenId,uint256 amount,uint256 buintAmount,uint256 validAfter,uint256 validBefore,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant CANCEL_REDEEM_TYPEHASH =
        keccak256("CancelRedeem(address admin,bytes32 codeHash,uint256 nonce,uint256 deadline)");
    bytes32 private constant ADD_REDEEM_ADMIN_TYPEHASH =
        keccak256("AddRedeemAdmin(address admin,address account,uint256 nonce,uint256 deadline)");
    bytes32 private constant REMOVE_REDEEM_ADMIN_TYPEHASH =
        keccak256("RemoveRedeemAdmin(address admin,address account,uint256 nonce,uint256 deadline)");
    bytes32 private constant REDEEM_WITH_CODE_TYPEHASH =
        keccak256("RedeemWithCode(address recipient,bytes32 codeHash,uint256 deadline)");

    event RedeemAdminAdded(address indexed account);
    event RedeemAdminRemoved(address indexed account);
    event KetRedeemCreated(
        bytes32 indexed codeHash,
        uint256 tokenId,
        uint256 ketAmount,
        uint256 buintAmount,
        uint64 validAfter,
        uint64 validBefore
    );
    event KetRedeemCancelled(bytes32 indexed codeHash);
    event KetRedeemConsumed(
        bytes32 indexed codeHash,
        address indexed recipient,
        uint256 tokenId,
        uint256 ketAmount,
        uint256 buintAmount
    );

    modifier onlyRedeemAdmin() {
        require(redeemAdmins[msg.sender], "KetRedeem: not redeem admin");
        _;
    }

    /**
     * @param ket_ `BusinessStartKet` 合约地址
     * @param buint_ `BeamioBUnits` 合约地址
     * @param initialRedeemAdmin 首个 Redeem 管理员；`address(0)` 则 `msg.sender`
     */
    constructor(address ket_, address buint_, address initialRedeemAdmin) EIP712("BusinessStartKetRedeem", "1") {
        require(ket_ != address(0), "KetRedeem: zero ket");
        require(buint_ != address(0), "KetRedeem: zero buint");
        ket = IBusinessStartKetMint(ket_);
        buint = IBeamioBUnitsMintReward(buint_);
        address admin = initialRedeemAdmin == address(0) ? msg.sender : initialRedeemAdmin;
        redeemAdmins[admin] = true;
        emit RedeemAdminAdded(admin);
    }

    function isKetMintAuthorized() external view returns (bool) {
        return ket.admins(address(this));
    }

    function isBuintMintAuthorized() external view returns (bool) {
        return buint.admins(address(this));
    }

    function addRedeemAdmin(address account) external onlyRedeemAdmin {
        require(account != address(0), "KetRedeem: zero admin");
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
        require(block.timestamp <= deadline, "KetRedeem: expired");
        require(redeemAdmins[admin], "KetRedeem: not redeem admin");
        require(account != address(0), "KetRedeem: zero admin");
        require(redeemAdminNonces[admin] == nonce, "KetRedeem: bad nonce");

        bytes32 structHash = keccak256(abi.encode(ADD_REDEEM_ADMIN_TYPEHASH, admin, account, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "KetRedeem: bad sig");

        redeemAdminNonces[admin]++;
        redeemAdmins[account] = true;
        emit RedeemAdminAdded(account);
    }

    function removeRedeemAdmin(address account) external onlyRedeemAdmin {
        require(account != msg.sender, "KetRedeem: cannot remove self");
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
        require(block.timestamp <= deadline, "KetRedeem: expired");
        require(redeemAdmins[admin], "KetRedeem: not redeem admin");
        require(redeemAdminNonces[admin] == nonce, "KetRedeem: bad nonce");

        bytes32 structHash = keccak256(abi.encode(REMOVE_REDEEM_ADMIN_TYPEHASH, admin, account, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "KetRedeem: bad sig");

        redeemAdminNonces[admin]++;
        redeemAdmins[account] = false;
        emit RedeemAdminRemoved(account);
    }

    function _timeOk(uint64 validAfter, uint64 validBefore) internal view returns (bool) {
        uint256 ts = block.timestamp;
        if (validAfter != 0 && ts < validAfter) return false;
        if (validBefore != 0 && ts > validBefore) return false;
        return true;
    }

    function _applyCreateRedeem(
        bytes32 codeHash,
        uint256 tokenId,
        uint256 ketAmount,
        uint256 buintAmount_,
        uint64 validAfter,
        uint64 validBefore
    ) internal {
        require(codeHash != bytes32(0), "KetRedeem: invalid hash");
        require(ketAmount <= type(uint128).max && buintAmount_ <= type(uint128).max, "KetRedeem: amount overflow");
        require(ketAmount > 0 || buintAmount_ > 0, "KetRedeem: nothing to redeem");

        Redeem storage r = _redeems[codeHash];
        require(!r.consumed, "KetRedeem: hash consumed");
        require(!r.active, "KetRedeem: already active");

        r.tokenId = tokenId;
        r.amount = uint128(ketAmount);
        r.buintAmount = uint128(buintAmount_);
        r.validAfter = validAfter;
        r.validBefore = validBefore;
        r.active = true;

        emit KetRedeemCreated(codeHash, tokenId, ketAmount, buintAmount_, validAfter, validBefore);
    }

    /**
     * @notice 创建兑换。链下 `codeHash = keccak256(bytes(secretCode))`。
     * @param tokenId ERC-1155 token type id（`ketAmount == 0` 时可占位）
     * @param ketAmount Ket 铸造数量；0 表示本码仅发 B-Unit
     * @param buintAmount B-Unit 数量（6 位精度，免费池 `mintReward`）；0 表示本码仅发 Ket
     */
    function createRedeem(
        bytes32 codeHash,
        uint256 tokenId,
        uint256 ketAmount,
        uint256 buintAmount,
        uint64 validAfter,
        uint64 validBefore
    ) external onlyRedeemAdmin {
        _applyCreateRedeem(codeHash, tokenId, ketAmount, buintAmount, validAfter, validBefore);
    }

    function createRedeemFor(
        address admin,
        bytes32 codeHash,
        uint256 tokenId,
        uint256 ketAmount,
        uint256 buintAmount,
        uint256 validAfter,
        uint256 validBefore,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "KetRedeem: expired");
        require(redeemAdmins[admin], "KetRedeem: not redeem admin");
        require(redeemAdminNonces[admin] == nonce, "KetRedeem: bad nonce");
        require(validAfter <= type(uint64).max && validBefore <= type(uint64).max, "KetRedeem: time overflow");

        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_REDEEM_TYPEHASH,
                admin,
                codeHash,
                tokenId,
                ketAmount,
                buintAmount,
                validAfter,
                validBefore,
                nonce,
                deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "KetRedeem: bad sig");

        redeemAdminNonces[admin]++;
        _applyCreateRedeem(codeHash, tokenId, ketAmount, buintAmount, uint64(validAfter), uint64(validBefore));
    }

    function _applyCancelRedeem(bytes32 codeHash) internal {
        require(codeHash != bytes32(0), "KetRedeem: invalid hash");
        Redeem storage r = _redeems[codeHash];
        require(r.active, "KetRedeem: not active");
        r.active = false;
        emit KetRedeemCancelled(codeHash);
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
        require(block.timestamp <= deadline, "KetRedeem: expired");
        require(redeemAdmins[admin], "KetRedeem: not redeem admin");
        require(redeemAdminNonces[admin] == nonce, "KetRedeem: bad nonce");

        bytes32 structHash = keccak256(abi.encode(CANCEL_REDEEM_TYPEHASH, admin, codeHash, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "KetRedeem: bad sig");

        redeemAdminNonces[admin]++;
        _applyCancelRedeem(codeHash);
    }

    function getCreateRedeemDigest(
        address admin,
        bytes32 codeHash,
        uint256 tokenId,
        uint256 ketAmount,
        uint256 buintAmount,
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
                tokenId,
                ketAmount,
                buintAmount,
                validAfter,
                validBefore,
                nonce,
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

    function getAddRedeemAdminDigest(address admin, address account, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(ADD_REDEEM_ADMIN_TYPEHASH, admin, account, nonce, deadline));
        return _hashTypedDataV4(structHash);
    }

    function getRemoveRedeemAdminDigest(address admin, address account, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(REMOVE_REDEEM_ADMIN_TYPEHASH, admin, account, nonce, deadline));
        return _hashTypedDataV4(structHash);
    }

    function getRedeemWithCodeDigest(address recipient, bytes32 codeHash, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(REDEEM_WITH_CODE_TYPEHASH, recipient, codeHash, deadline));
        return _hashTypedDataV4(structHash);
    }

    function _redeemWithCodeHashTo(bytes32 codeHash, address recipient) internal {
        Redeem storage r = _redeems[codeHash];
        require(r.active, "KetRedeem: inactive");
        require(!r.consumed, "KetRedeem: consumed");
        require(_timeOk(r.validAfter, r.validBefore), "KetRedeem: time window");

        uint256 tid = r.tokenId;
        uint256 ketPayout = uint256(r.amount);
        uint256 buintPayout = uint256(r.buintAmount);
        r.active = false;
        r.consumed = true;

        if (ketPayout > 0) {
            ket.mint(recipient, tid, ketPayout, "");
        }
        if (buintPayout > 0) {
            buint.mintReward(recipient, buintPayout);
        }

        emit KetRedeemConsumed(codeHash, recipient, tid, ketPayout, buintPayout);
    }

    function redeemWithCode(string calldata code) external {
        bytes memory b = bytes(code);
        require(b.length > 0 && b.length <= _MAX_REDEEM_CODE_LEN, "KetRedeem: bad code len");
        bytes32 codeHash = keccak256(b);
        _redeemWithCodeHashTo(codeHash, msg.sender);
    }

    function redeemWithCodeFor(address recipient, string calldata code, uint256 deadline, bytes calldata signature)
        external
    {
        require(block.timestamp <= deadline, "KetRedeem: expired");
        require(recipient != address(0), "KetRedeem: zero recipient");
        bytes memory b = bytes(code);
        require(b.length > 0 && b.length <= _MAX_REDEEM_CODE_LEN, "KetRedeem: bad code len");
        bytes32 codeHash = keccak256(b);

        bytes32 structHash = keccak256(abi.encode(REDEEM_WITH_CODE_TYPEHASH, recipient, codeHash, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == recipient, "KetRedeem: bad sig");

        _redeemWithCodeHashTo(codeHash, recipient);
    }

    function redeemWithCodeAsAdmin(address recipient, string calldata code) external onlyRedeemAdmin {
        require(recipient != address(0), "KetRedeem: zero recipient");
        bytes memory b = bytes(code);
        require(b.length > 0 && b.length <= _MAX_REDEEM_CODE_LEN, "KetRedeem: bad code len");
        bytes32 codeHash = keccak256(b);
        _redeemWithCodeHashTo(codeHash, recipient);
    }

    function getRedeem(bytes32 codeHash)
        external
        view
        returns (
            uint256 tokenId,
            uint256 ketAmount,
            uint256 buintAmount,
            uint64 validAfter,
            uint64 validBefore,
            bool active,
            bool consumed
        )
    {
        Redeem storage r = _redeems[codeHash];
        return (
            r.tokenId,
            uint256(r.amount),
            uint256(r.buintAmount),
            r.validAfter,
            r.validBefore,
            r.active,
            r.consumed
        );
    }
}
