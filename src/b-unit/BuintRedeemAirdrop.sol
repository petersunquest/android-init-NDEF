// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "../contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

/**
 * @title BuintRedeemAirdrop
 * @notice 独立兑换码空投合约：Redeem Admin 创建/取消兑换；用户凭 secret 字符串领取 B-Unit（免费池）。
 * @dev 部署后必须由 `BeamioBUnits` 的现有 admin 执行 `BeamioBUnits.addAdmin(address(this))`。
 *      Redeem Admin 可链上直接调用，或使用 EIP-712 离线签名由 relayer 代为提交（*For 系列函数）。
 *      用户：`redeemWithCode` 自付 gas；或对自己领取地址签 `RedeemWithCode`，由 relayer 调用 `redeemWithCodeFor` 代付 gas。
 *      Redeem Admin：`redeemWithCodeAsAdmin` 代用户提交并指定 `recipient`（admin 付 gas，须知晓明文 code）。
 */
interface IBeamioBUnitsMint {
    function mintReward(address to, uint256 amount) external;

    function admins(address account) external view returns (bool);
}

contract BuintRedeemAirdrop is EIP712 {
    IBeamioBUnitsMint public immutable buint;

    uint256 private constant _MAX_REDEEM_CODE_LEN = 512;

    mapping(address => bool) public redeemAdmins;
    /// @notice 各 Redeem Admin 的 EIP-712 nonce，每次成功 *For 调用后递增
    mapping(address => uint256) public redeemAdminNonces;

    struct Redeem {
        uint128 amount;
        uint64 validAfter;
        uint64 validBefore;
        bool active;
        bool consumed;
    }

    mapping(bytes32 => Redeem) private _redeems;

    bytes32 private constant CREATE_REDEEM_TYPEHASH = keccak256(
        "CreateRedeem(address admin,bytes32 codeHash,uint256 amount,uint256 validAfter,uint256 validBefore,uint256 nonce,uint256 deadline)"
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
    event BuintRedeemCreated(bytes32 indexed codeHash, uint256 amount, uint64 validAfter, uint64 validBefore);
    event BuintRedeemCancelled(bytes32 indexed codeHash);
    event BuintRedeemConsumed(bytes32 indexed codeHash, address indexed recipient, uint256 amount);

    modifier onlyRedeemAdmin() {
        require(redeemAdmins[msg.sender], "BuintRedeem: not redeem admin");
        _;
    }

    /**
     * @param buint_ `BeamioBUnits` 合约地址
     * @param initialRedeemAdmin 首个 Redeem 管理员；传 `address(0)` 则使用 `msg.sender`
     */
    constructor(address buint_, address initialRedeemAdmin) EIP712("BuintRedeemAirdrop", "1") {
        require(buint_ != address(0), "BuintRedeem: zero buint");
        buint = IBeamioBUnitsMint(buint_);
        address admin = initialRedeemAdmin == address(0) ? msg.sender : initialRedeemAdmin;
        redeemAdmins[admin] = true;
        emit RedeemAdminAdded(admin);
    }

    /// @notice 本合约是否已是 `BeamioBUnits` admin（可成功 `mintReward`）
    function isBuintMintAuthorized() external view returns (bool) {
        return buint.admins(address(this));
    }

    function addRedeemAdmin(address account) external onlyRedeemAdmin {
        require(account != address(0), "BuintRedeem: zero admin");
        redeemAdmins[account] = true;
        emit RedeemAdminAdded(account);
    }

    /// @notice Relayer 提交：Redeem Admin 离线签 `AddRedeemAdmin`
    function addRedeemAdminFor(
        address admin,
        address account,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "BuintRedeem: expired");
        require(redeemAdmins[admin], "BuintRedeem: not redeem admin");
        require(account != address(0), "BuintRedeem: zero admin");
        require(redeemAdminNonces[admin] == nonce, "BuintRedeem: bad nonce");

        bytes32 structHash = keccak256(abi.encode(ADD_REDEEM_ADMIN_TYPEHASH, admin, account, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "BuintRedeem: bad sig");

        redeemAdminNonces[admin]++;
        redeemAdmins[account] = true;
        emit RedeemAdminAdded(account);
    }

    function removeRedeemAdmin(address account) external onlyRedeemAdmin {
        require(account != msg.sender, "BuintRedeem: cannot remove self");
        redeemAdmins[account] = false;
        emit RedeemAdminRemoved(account);
    }

    /// @notice Relayer 提交：Redeem Admin 离线签 `RemoveRedeemAdmin`（可通过签名移除自己）
    function removeRedeemAdminFor(
        address admin,
        address account,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "BuintRedeem: expired");
        require(redeemAdmins[admin], "BuintRedeem: not redeem admin");
        require(redeemAdminNonces[admin] == nonce, "BuintRedeem: bad nonce");

        bytes32 structHash = keccak256(abi.encode(REMOVE_REDEEM_ADMIN_TYPEHASH, admin, account, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "BuintRedeem: bad sig");

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

    function _applyCreateRedeem(bytes32 codeHash, uint256 amount, uint64 validAfter, uint64 validBefore) internal {
        require(codeHash != bytes32(0), "BuintRedeem: invalid hash");
        require(amount > 0 && amount <= type(uint128).max, "BuintRedeem: invalid amount");

        Redeem storage r = _redeems[codeHash];
        require(!r.consumed, "BuintRedeem: hash consumed");
        require(!r.active, "BuintRedeem: already active");

        r.amount = uint128(amount);
        r.validAfter = validAfter;
        r.validBefore = validBefore;
        r.active = true;

        emit BuintRedeemCreated(codeHash, amount, validAfter, validBefore);
    }

    /**
     * @notice 创建兑换。链下计算 `codeHash = keccak256(bytes(secretCode))`，仅提交 hash。
     * @param amount 6 位精度 B-Unit 数量
     */
    function createRedeem(bytes32 codeHash, uint256 amount, uint64 validAfter, uint64 validBefore)
        external
        onlyRedeemAdmin
    {
        _applyCreateRedeem(codeHash, amount, validAfter, validBefore);
    }

    /**
     * @notice Relayer 提交：Redeem Admin 离线签 `CreateRedeem`（validAfter/validBefore 为 uint256，需 ≤ uint64.max）
     */
    function createRedeemFor(
        address admin,
        bytes32 codeHash,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "BuintRedeem: expired");
        require(redeemAdmins[admin], "BuintRedeem: not redeem admin");
        require(redeemAdminNonces[admin] == nonce, "BuintRedeem: bad nonce");
        require(validAfter <= type(uint64).max && validBefore <= type(uint64).max, "BuintRedeem: time overflow");

        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_REDEEM_TYPEHASH, admin, codeHash, amount, validAfter, validBefore, nonce, deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "BuintRedeem: bad sig");

        redeemAdminNonces[admin]++;
        _applyCreateRedeem(codeHash, amount, uint64(validAfter), uint64(validBefore));
    }

    function _applyCancelRedeem(bytes32 codeHash) internal {
        require(codeHash != bytes32(0), "BuintRedeem: invalid hash");
        Redeem storage r = _redeems[codeHash];
        require(r.active, "BuintRedeem: not active");
        r.active = false;
        emit BuintRedeemCancelled(codeHash);
    }

    function cancelRedeem(bytes32 codeHash) external onlyRedeemAdmin {
        _applyCancelRedeem(codeHash);
    }

    /// @notice Relayer 提交：Redeem Admin 离线签 `CancelRedeem`
    function cancelRedeemFor(
        address admin, bytes32 codeHash, uint256 nonce, uint256 deadline, bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "BuintRedeem: expired");
        require(redeemAdmins[admin], "BuintRedeem: not redeem admin");
        require(redeemAdminNonces[admin] == nonce, "BuintRedeem: bad nonce");

        bytes32 structHash = keccak256(abi.encode(CANCEL_REDEEM_TYPEHASH, admin, codeHash, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "BuintRedeem: bad sig");

        redeemAdminNonces[admin]++;
        _applyCancelRedeem(codeHash);
    }

    // --- EIP-712 digest（供链下 signTypedData）---

    function getCreateRedeemDigest(
        address admin,
        bytes32 codeHash,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_REDEEM_TYPEHASH, admin, codeHash, amount, validAfter, validBefore, nonce, deadline
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

    /// @notice 用户领取的 EIP-712 digest（与 `redeemWithCodeFor` 校验一致）
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
        require(r.active, "BuintRedeem: inactive");
        require(!r.consumed, "BuintRedeem: consumed");
        require(_timeOk(r.validAfter, r.validBefore), "BuintRedeem: time window");

        uint256 payout = uint256(r.amount);
        r.active = false;
        r.consumed = true;

        buint.mintReward(recipient, payout);
        emit BuintRedeemConsumed(codeHash, recipient, payout);
    }

    /**
     * @notice 使用与创建时一致的明文 code 领取至 `msg.sender` 免费池（自付 gas）
     */
    function redeemWithCode(string calldata code) external {
        bytes memory b = bytes(code);
        require(b.length > 0 && b.length <= _MAX_REDEEM_CODE_LEN, "BuintRedeem: bad code len");
        bytes32 codeHash = keccak256(b);
        _redeemWithCodeHashTo(codeHash, msg.sender);
    }

    /**
     * @notice Relayer 代付 gas：`recipient` 对 `RedeemWithCode(recipient,codeHash,deadline)` 签名，链上校验 `keccak256(bytes(code)) == codeHash` 且 `recover == recipient`
     */
    function redeemWithCodeFor(address recipient, string calldata code, uint256 deadline, bytes calldata signature)
        external
    {
        require(block.timestamp <= deadline, "BuintRedeem: expired");
        require(recipient != address(0), "BuintRedeem: zero recipient");
        bytes memory b = bytes(code);
        require(b.length > 0 && b.length <= _MAX_REDEEM_CODE_LEN, "BuintRedeem: bad code len");
        bytes32 codeHash = keccak256(b);

        bytes32 structHash = keccak256(abi.encode(REDEEM_WITH_CODE_TYPEHASH, recipient, codeHash, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == recipient, "BuintRedeem: bad sig");

        _redeemWithCodeHashTo(codeHash, recipient);
    }

    /**
     * @notice Redeem Admin 代为兑换：将 B-Unit 免费池划入 `recipient`，gas 由 admin 支付（calldata 含明文 code，仅运维/可信通道使用）
     */
    function redeemWithCodeAsAdmin(address recipient, string calldata code) external onlyRedeemAdmin {
        require(recipient != address(0), "BuintRedeem: zero recipient");
        bytes memory b = bytes(code);
        require(b.length > 0 && b.length <= _MAX_REDEEM_CODE_LEN, "BuintRedeem: bad code len");
        bytes32 codeHash = keccak256(b);
        _redeemWithCodeHashTo(codeHash, recipient);
    }

    function getRedeem(bytes32 codeHash)
        external
        view
        returns (uint256 amount, uint64 validAfter, uint64 validBefore, bool active, bool consumed)
    {
        Redeem storage r = _redeems[codeHash];
        return (uint256(r.amount), r.validAfter, r.validBefore, r.active, r.consumed);
    }
}
