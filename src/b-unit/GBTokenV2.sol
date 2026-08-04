// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP20Permit3009Upgradeable} from "./EIP20Permit3009Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title GBTokenV2 — CONET GB UUPS implementation（V2：free 不可 P2P 转）
 * @dev **V2 部署范围**：仅 CoNET（chainId 224422）对既有 CREATE2 代理 `upgradeToAndCall`；
 *      Base 等外链入桥 GB 均为 `mintPaid`，无 free 池，可暂不升级。
 *      **Canonical GB**：全项目「GB」默认指 GBToken 代理（free/paid 双池；V2 起 P2P 仅 paid）。
 *      **ConetGB1155** 已弃用 — 见 `.cursor/rules/beamio-gb-erc20-canonical.mdc`。
 *
 *  V2 相对 V1：
 *   - `transfer` / `transferFrom` / EIP-3009：**仅 paidPool**（对齐 BeamioBUnits）。
 *   - 用户 `burn` / `burnFrom`：**仅 paidPool**。
 *   - **免费池 burn**：`burnFree` / `burnFreeFrom` — 持币用户本人，或 CoNET DePIN **节点运营钱包**
 *    （经 `ValidatorDepositRedeem.nodeWalletBeneficiary` 对应 economic beneficiary）；**不可 P2P 转**。
 *   - Admin `consumeFree`（同 `burnFreeFrom` 授权）/ `consumeGb`：瀑布流协议扣减。
 *
 *  设计要点（继承 V1）：
 *   1. 9 位精度：1 GB = 1e9。
 *   2. Gasless：EIP-2612 + EIP-3009（授权转账同 V2 仅 paid 规则）。
 *   3. 代理地址不变：UUPS 升级 implementation；**canonical 地址 = ERC1967 代理**。
 *   4. Admin 空投：mintReward / airdrop → free；mintPaid / 跨链入桥 → paid。
 *   5. P2P：**仅 paidPool** 可转；free 仅 `burnFree*` / admin `consumeGb`，不可 transfer。
 *   6. 去中心化投票跨链桥（对称，CoNET ↔ Base 同一套逻辑）：
 *        - 源链：持有人 bridgeOut() 焚烧本链 **paidPool** GB，emit BridgeOut；
 *        - 目标链：bridge validator 对源链 burn txHash 投票 voteBridgeMint()，
 *          达到 2/3 阈值后 **mintPaid** 等额 GB 给 recipient（executeBridgeMint）。
 *      validators 由 admin 维护（与 ConetTreasury miners 同模式）；阈值 = ceil(2/3 * validatorCount)。
 *   7. Explorer 元数据：name/symbol/decimals 为链上常量，Blockscout / scan 直接读取；
 *      contractURI() 额外提供含 GB 图片的合约级 JSON，供支持的钱包/浏览器展示。
 */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

/// @dev DePIN 节点运营钱包 → economic beneficiary（与 GBDepinAirdrop 同源）。
interface IValidatorDepositRedeemGbBurn {
    function nodeWalletBeneficiary(address wallet) external view returns (address);
}

contract GBTokenV2 is IERC20, EIP20Permit3009Upgradeable, UUPSUpgradeable {
    // ---------------------------------------------------------------------
    // ERC20 metadata（Blockscout / scan 读取）
    // ---------------------------------------------------------------------
    string public constant name = "CONET GB";
    string public constant symbol = "GB";
    /// @dev 9 位精度：1 GB = 1e9（1 byte = 1 最小单位）
    uint8 public constant decimals = 9;

    uint256 private _totalSupply;

    /// @dev 双池账本：freePool 空投/奖励；paidPool USDC 背书 / 跨链 mint（与 BeamioBUnits 语义对齐）。
    struct GbBalance {
        uint128 freePool;
        uint128 paidPool;
    }
    mapping(address => GbBalance) private _gbBalances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ---------------------------------------------------------------------
    // 角色：admin（空投/铸币/治理） + bridge validator（跨链投票）
    // ---------------------------------------------------------------------
    mapping(address => bool) public admins;
    mapping(address => bool) public bridgeValidators;
    uint256 public validatorCount;
    bool public bridgePaused;

    // ---------------------------------------------------------------------
    // 跨链桥状态
    // ---------------------------------------------------------------------
    /// @dev 本链 bridgeOut 自增序号，使每次出桥事件唯一
    uint256 public bridgeOutNonce;

    struct BridgeMintProposal {
        uint256 srcChainId;
        address recipient;
        uint256 amount;
        uint256 voteCount;
        bool executed;
    }
    /// @dev 以源链 burn txHash 为键（跨链唯一）
    mapping(bytes32 => BridgeMintProposal) public bridgeMintProposals;
    mapping(bytes32 => mapping(address => bool)) public hasVotedBridgeMint;

    /// @dev ValidatorDepositRedeem：DePIN 节点钱包 burn 其 beneficiary 的 freePool（V2 新增，占 __gap 1 槽）。
    address public validatorDepositRedeem;

    // ---------------------------------------------------------------------
    // 元数据图片（合约级 metadata，供支持 contractURI 的钱包/浏览器）
    // ---------------------------------------------------------------------
    /// @dev 托管的 GB 合约级元数据 JSON（含 name/symbol/decimals/image）。各链相同，保证 bytecode 一致。
    string public constant contractURI = "https://assets.conet.network/gb/erc20/metadata.json";

    // ---------------------------------------------------------------------
    // 事件
    // ---------------------------------------------------------------------
    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);
    event ValidatorAdded(address indexed account);
    event ValidatorRemoved(address indexed account);
    event BridgePausedSet(bool paused);
    event Airdrop(address indexed operator, uint256 recipients, uint256 totalAmount);
    event MintReward(address indexed to, uint256 amount);
    event MintPaid(address indexed to, uint256 amount);
    event FreeGbBurned(address indexed account, address indexed operator, uint256 amount);
    event ValidatorDepositRedeemUpdated(address indexed oldAddr, address indexed newAddr);
    event GbConsumed(address indexed user, uint256 amount, uint256 freeBurned, uint256 paidBurned);

    /// @notice 源链出桥：本链 GB 已焚烧，等待目标链投票铸造
    event BridgeOut(
        address indexed from,
        address indexed recipient,
        uint256 amount,
        uint256 srcChainId,
        uint256 indexed destChainId,
        uint256 nonce
    );
    event BridgeMintProposed(bytes32 indexed srcTxHash, uint256 srcChainId, address indexed recipient, uint256 amount, address indexed proposer);
    event BridgeMintVoted(bytes32 indexed srcTxHash, address indexed validator, uint256 voteCount);
    event BridgeMintExecuted(bytes32 indexed srcTxHash, address indexed recipient, uint256 amount);

    // ---------------------------------------------------------------------
    // 错误
    // ---------------------------------------------------------------------
    error NotAdmin();
    error NotValidator();
    error ZeroAddress();
    error LengthMismatch();
    error InvalidAmount();
    error InsufficientBalance();
    error InsufficientAllowance();
    error BridgeIsPaused();
    error SameChain();
    error AlreadyVoted();
    error AlreadyExecuted();
    error ProposalMismatch();
    error NotExecutable();
    error NoValidators();

    error InsufficientPaidBalance();
    error InsufficientFreeBalance();
    error NotAuthorizedToBurnFree();

    modifier onlyAdmin() {
        if (!admins[msg.sender]) revert NotAdmin();
        _;
    }

    modifier onlyValidator() {
        if (!bridgeValidators[msg.sender]) revert NotValidator();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialAdmin) external initializer {
        __EIP20Permit3009_init("CONET GB");
        __UUPSUpgradeable_init();
        if (initialAdmin == address(0)) revert ZeroAddress();
        admins[initialAdmin] = true;
        emit AdminAdded(initialAdmin);
    }

    function _authorizeUpgrade(address) internal view override onlyAdmin {}

    /// @dev UUPS implementation 版本；代理地址不变。
    function version() external pure returns (uint256) {
        return 2;
    }

    // ---------------------------------------------------------------------
    // ERC20 标准接口
    // ---------------------------------------------------------------------
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        GbBalance storage bal = _gbBalances[account];
        return uint256(bal.freePool) + uint256(bal.paidPool);
    }

    /// @dev 返回 free / paid 明细；`bridgeableBalanceOf` = paid。
    function balanceOfAll(address account) external view returns (uint256 total, uint256 free, uint256 paid) {
        GbBalance storage bal = _gbBalances[account];
        free = uint256(bal.freePool);
        paid = uint256(bal.paidPool);
        total = free + paid;
    }

    /// @dev 可跨链 / 法币背书 GB（仅 paidPool）。
    function bridgeableBalanceOf(address account) external view returns (uint256) {
        return uint256(_gbBalances[account].paidPool);
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        uint256 current = _allowances[from][msg.sender];
        if (current != type(uint256).max) {
            if (current < value) revert InsufficientAllowance();
            unchecked {
                _allowances[from][msg.sender] = current - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    /// @dev V2：P2P / EIP-3009 仅移动 paidPool（对齐 BeamioBUnits `_transferPaidOnly`）。
    function _transferPaidOnly(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        GbBalance storage fromBal = _gbBalances[from];
        GbBalance storage toBal = _gbBalances[to];
        if (uint256(fromBal.paidPool) < amount) revert InsufficientPaidBalance();
        if (uint256(toBal.paidPool) + amount > type(uint128).max) revert InvalidAmount();
        fromBal.paidPool -= uint128(amount);
        toBal.paidPool += uint128(amount);
        emit Transfer(from, to, amount);
    }

    function _mintReward(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (amount > type(uint128).max) revert InvalidAmount();
        _gbBalances[to].freePool += uint128(amount);
        _totalSupply += amount;
        emit MintReward(to, amount);
        emit Transfer(address(0), to, amount);
    }

    function _mintPaid(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        if (amount > type(uint128).max) revert InvalidAmount();
        _gbBalances[to].paidPool += uint128(amount);
        _totalSupply += amount;
        emit MintPaid(to, amount);
        emit Transfer(address(0), to, amount);
    }

    function _burnPaidOnly(address from, uint256 amount) internal {
        GbBalance storage bal = _gbBalances[from];
        if (uint256(bal.paidPool) < amount) revert InsufficientPaidBalance();
        bal.paidPool -= uint128(amount);
        _totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _burnFreeOnly(address account, uint256 amount) internal {
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        GbBalance storage bal = _gbBalances[account];
        if (uint256(bal.freePool) < amount) revert InsufficientFreeBalance();
        bal.freePool -= uint128(amount);
        _totalSupply -= amount;
        emit Transfer(account, address(0), amount);
    }

    /// @dev 用户本人、GB admin、或 DePIN 节点运营钱包（对其 beneficiary）可 burn freePool。
    function _canBurnFreeFrom(address operator, address account) internal view returns (bool) {
        if (operator == account) return true;
        if (admins[operator]) return true;
        address vdr = validatorDepositRedeem;
        if (vdr == address(0)) return false;
        address beneficiary = IValidatorDepositRedeemGbBurn(vdr).nodeWalletBeneficiary(operator);
        return beneficiary != address(0) && beneficiary == account;
    }

    function _burnFreeFrom(address account, address operator, uint256 amount) internal {
        _burnFreeOnly(account, amount);
        emit FreeGbBurned(account, operator, amount);
    }

    function _transfer(address from, address to, uint256 value) internal {
        _transferPaidOnly(from, to, value);
    }

    // ---------------------------------------------------------------------
    // EIP-2612 / EIP-3009 hooks（gasless）
    // ---------------------------------------------------------------------
    function _transferForAuth(address from, address to, uint256 value) internal override {
        _transfer(from, to, value);
    }

    function _approveForAuth(address owner, address spender, uint256 value) internal override {
        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    // ---------------------------------------------------------------------
    // 角色管理（admin）
    // ---------------------------------------------------------------------
    function addAdmin(address account) external onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        if (!admins[account]) {
            admins[account] = true;
            emit AdminAdded(account);
        }
    }

    function removeAdmin(address account) external onlyAdmin {
        if (account == msg.sender) revert NotAdmin(); // 禁止移除自身，避免误锁
        if (admins[account]) {
            admins[account] = false;
            emit AdminRemoved(account);
        }
    }

    function addValidator(address account) external onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        if (!bridgeValidators[account]) {
            bridgeValidators[account] = true;
            validatorCount += 1;
            emit ValidatorAdded(account);
        }
    }

    function removeValidator(address account) external onlyAdmin {
        if (bridgeValidators[account]) {
            bridgeValidators[account] = false;
            validatorCount -= 1;
            emit ValidatorRemoved(account);
        }
    }

    function setBridgePaused(bool paused) external onlyAdmin {
        bridgePaused = paused;
        emit BridgePausedSet(paused);
    }

    /// @notice 配置 ValidatorDepositRedeem，供 DePIN 节点钱包 `burnFreeFrom(beneficiary, …)` 鉴权。
    function setValidatorDepositRedeem(address addr) external onlyAdmin {
        address old = validatorDepositRedeem;
        validatorDepositRedeem = addr;
        emit ValidatorDepositRedeemUpdated(old, addr);
    }

    /// @notice 跨链铸造所需票数 = ceil(2/3 * validatorCount)
    function requiredVotes() public view returns (uint256) {
        uint256 n = validatorCount;
        if (n == 0) return 0;
        return (n * 2 + 2) / 3;
    }

    // ---------------------------------------------------------------------
    // Admin 铸币 / 空投（免费池 vs 付费池）
    // ---------------------------------------------------------------------
    /// @dev 空投 / 奖励 → 免费池（与 B-Unit `mintReward` 一致）。
    function mintReward(address to, uint256 amount) external onlyAdmin {
        if (amount == 0) revert InvalidAmount();
        _mintReward(to, amount);
    }

    /// @dev USDC 购买 / 跨链入桥 → 付费池（与 B-Unit `mintPaid` 一致）。
    function mintPaid(address to, uint256 amount) external onlyAdmin {
        if (amount == 0) revert InvalidAmount();
        _mintPaid(to, amount);
    }

    /// @dev 兼容旧脚本：等同 `mintReward`（免费池）。
    function mint(address to, uint256 amount) external onlyAdmin {
        if (amount == 0) revert InvalidAmount();
        _mintReward(to, amount);
    }

    /// @notice admin 批量空投 → 免费池。amounts 单位为最小单位（1 GB = 1e9）。
    function airdrop(address[] calldata recipients, uint256[] calldata amounts) external onlyAdmin {
        uint256 len = recipients.length;
        if (len != amounts.length) revert LengthMismatch();
        uint256 total;
        for (uint256 i = 0; i < len; i++) {
            _mintReward(recipients[i], amounts[i]);
            total += amounts[i];
        }
        emit Airdrop(msg.sender, len, total);
    }

    /// @notice admin 等额空投 → 免费池。
    function airdropEqual(address[] calldata recipients, uint256 amountEach) external onlyAdmin {
        if (amountEach == 0) revert InvalidAmount();
        uint256 len = recipients.length;
        for (uint256 i = 0; i < len; i++) {
            _mintReward(recipients[i], amountEach);
        }
        emit Airdrop(msg.sender, len, amountEach * len);
    }

    // ---------------------------------------------------------------------
    // 免费池 burn（不可 P2P 转）：用户本人或 DePIN 节点钱包
    // ---------------------------------------------------------------------
    /// @notice 焚烧调用方自己的 freePool。
    function burnFree(uint256 amount) external {
        _burnFreeFrom(msg.sender, msg.sender, amount);
    }

    /// @notice 焚烧 `account` 的 freePool。授权：account 本人、admin、或 DePIN 节点钱包（beneficiary == account）。
    function burnFreeFrom(address account, uint256 amount) external {
        if (!_canBurnFreeFrom(msg.sender, account)) revert NotAuthorizedToBurnFree();
        _burnFreeFrom(account, msg.sender, amount);
    }

    /// @dev Admin 兼容入口（等同授权通过的 `burnFreeFrom`）。
    function consumeFree(address user, uint256 amount) external onlyAdmin {
        _burnFreeFrom(user, msg.sender, amount);
    }

    /// @dev 瀑布流扣减：优先 free，不足再扣 paid（admin 协议网关）。
    function consumeGb(address user, uint256 amount) external onlyAdmin returns (uint256 freeBurned, uint256 paidBurned) {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        GbBalance storage bal = _gbBalances[user];
        uint256 totalBal = uint256(bal.freePool) + uint256(bal.paidPool);
        if (totalBal < amount) revert InsufficientBalance();

        if (bal.freePool >= amount) {
            freeBurned = amount;
            paidBurned = 0;
            bal.freePool -= uint128(amount);
        } else {
            freeBurned = uint256(bal.freePool);
            paidBurned = amount - freeBurned;
            bal.freePool = 0;
            bal.paidPool -= uint128(paidBurned);
        }
        _totalSupply -= amount;
        emit GbConsumed(user, amount, freeBurned, paidBurned);
        emit Transfer(user, address(0), amount);
    }

    // ---------------------------------------------------------------------
    // 焚烧（持有人自焚 / 授权焚烧 — V2 仅 paidPool）
    // ---------------------------------------------------------------------
    function burn(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _burnPaidOnly(msg.sender, amount);
    }

    function burnFrom(address account, uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        uint256 current = _allowances[account][msg.sender];
        if (current != type(uint256).max) {
            if (current < amount) revert InsufficientAllowance();
            unchecked {
                _allowances[account][msg.sender] = current - amount;
            }
        }
        _burnPaidOnly(account, amount);
    }

    /// @dev 跨链 / 法币路径：仅焚烧 paidPool（Peer admin 调用）。
    function burnPaidFrom(address account, uint256 amount) external onlyAdmin {
        if (amount == 0) revert InvalidAmount();
        _burnPaidOnly(account, amount);
    }

    // ---------------------------------------------------------------------
    // 去中心化投票跨链桥（对称：任意 L1 burn → 任意 L1 mint）
    // ---------------------------------------------------------------------

    /**
     * @notice 出桥：焚烧本链 GB，emit BridgeOut。relayer 监听后在目标链发起投票。
     * @param amount        焚烧数量（最小单位）
     * @param destChainId   目标链 chainId（须 != 当前链）
     * @param recipient     目标链接收地址
     */
    function bridgeOut(uint256 amount, uint256 destChainId, address recipient) external {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (destChainId == block.chainid) revert SameChain();
        if (bridgePaused) revert BridgeIsPaused();
        _burnPaidOnly(msg.sender, amount);
        uint256 n = ++bridgeOutNonce;
        emit BridgeOut(msg.sender, recipient, amount, block.chainid, destChainId, n);
    }

    /**
     * @notice 入桥投票：validator 对「源链某笔 burn」投票，达到阈值后铸造。
     * @param srcTxHash  源链 bridgeOut 交易哈希（跨链唯一键）
     * @param srcChainId 源链 chainId
     * @param recipient  本链接收地址
     * @param amount     铸造数量（须与源链焚烧一致）
     */
    function voteBridgeMint(
        bytes32 srcTxHash,
        uint256 srcChainId,
        address recipient,
        uint256 amount
    ) external onlyValidator {
        if (bridgePaused) revert BridgeIsPaused();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (srcChainId == block.chainid) revert SameChain();
        if (validatorCount == 0) revert NoValidators();
        if (hasVotedBridgeMint[srcTxHash][msg.sender]) revert AlreadyVoted();

        BridgeMintProposal storage p = bridgeMintProposals[srcTxHash];
        if (p.executed) revert AlreadyExecuted();

        if (p.voteCount == 0) {
            p.srcChainId = srcChainId;
            p.recipient = recipient;
            p.amount = amount;
            p.voteCount = 1;
            emit BridgeMintProposed(srcTxHash, srcChainId, recipient, amount, msg.sender);
        } else {
            if (p.srcChainId != srcChainId || p.recipient != recipient || p.amount != amount) {
                revert ProposalMismatch();
            }
            p.voteCount += 1;
        }

        hasVotedBridgeMint[srcTxHash][msg.sender] = true;
        emit BridgeMintVoted(srcTxHash, msg.sender, p.voteCount);

        if (p.voteCount >= requiredVotes()) {
            _executeBridgeMint(srcTxHash);
        }
    }

    /// @notice 票数达标后任何人可触发执行（投票达标时已自动执行；此为兜底）。
    function executeBridgeMint(bytes32 srcTxHash) external {
        _executeBridgeMint(srcTxHash);
    }

    function _executeBridgeMint(bytes32 srcTxHash) internal {
        BridgeMintProposal storage p = bridgeMintProposals[srcTxHash];
        if (p.executed) revert AlreadyExecuted();
        if (p.voteCount < requiredVotes() || p.voteCount == 0) revert NotExecutable();
        p.executed = true;
        _mintPaid(p.recipient, p.amount);
        emit BridgeMintExecuted(srcTxHash, p.recipient, p.amount);
    }

    function getBridgeMintProposal(bytes32 srcTxHash)
        external
        view
        returns (uint256 srcChainId, address recipient, uint256 amount, uint256 voteCount, bool executed)
    {
        BridgeMintProposal storage p = bridgeMintProposals[srcTxHash];
        return (p.srcChainId, p.recipient, p.amount, p.voteCount, p.executed);
    }

    uint256[49] private __gap;
}
