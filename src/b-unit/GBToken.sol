// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP20Permit3009} from "./EIP20Permit3009.sol";

/**
 * @title GBToken — CONET GB（9 位 ERC20，跨链同址）
 * @dev DePIN 流量代币 GB 的「可转账 ERC20」版本（与作为 miner 记账的 ConetGB1155 并存，互不替代）。
 *
 *  设计要点：
 *   1. 9 位精度：1 GB = 1e9（与 CoNET DePIN「1 byte = 1 最小单位、1e9 bytes = 1 GB」口径一致）。
 *   2. Gasless 代付：继承 {EIP20Permit3009}，支持 EIP-2612 permit 与 EIP-3009
 *      transferWithAuthorization / receiveWithAuthorization（用户离线签字，由 relayer 代付 gas）。
 *   3. 跨链同址：constructor 仅取 initialAdmin（各链相同），配合 Nick CREATE2 factory + 固定 salt
 *      + 编译期 bytecodeHash=none，使 CoNET(224422) 与 Base(8453) 等任意 L1 上地址一致。
 *   4. Admin 空投：admin 角色可 mint / 批量 airdrop。
 *   5. 去中心化投票跨链桥（对称，CoNET ↔ Base 同一套逻辑）：
 *        - 源链：持有人 bridgeOut() 焚烧本链 GB，emit BridgeOut；
 *        - 目标链：bridge validator 对源链 burn txHash 投票 voteBridgeMint()，
 *          达到 2/3 阈值后 mint 等额 GB 给 recipient（executeBridgeMint）。
 *      validators 由 admin 维护（与 ConetTreasury miners 同模式）；阈值 = ceil(2/3 * validatorCount)。
 *   6. Explorer 元数据：name/symbol/decimals 为链上常量，Blockscout / scan 直接读取；
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

contract GBToken is IERC20, EIP20Permit3009 {
    // ---------------------------------------------------------------------
    // ERC20 metadata（Blockscout / scan 读取）
    // ---------------------------------------------------------------------
    string public constant name = "CONET GB";
    string public constant symbol = "GB";
    /// @dev 9 位精度：1 GB = 1e9（1 byte = 1 最小单位）
    uint8 public constant decimals = 9;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
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

    modifier onlyAdmin() {
        if (!admins[msg.sender]) revert NotAdmin();
        _;
    }

    modifier onlyValidator() {
        if (!bridgeValidators[msg.sender]) revert NotValidator();
        _;
    }

    constructor(address initialAdmin) EIP20Permit3009("CONET GB") {
        if (initialAdmin == address(0)) revert ZeroAddress();
        admins[initialAdmin] = true;
        emit AdminAdded(initialAdmin);
    }

    // ---------------------------------------------------------------------
    // ERC20 标准接口
    // ---------------------------------------------------------------------
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
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

    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        uint256 bal = _balances[from];
        if (bal < value) revert InsufficientBalance();
        unchecked {
            _balances[from] = bal - value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _mint(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        _totalSupply += amount;
        unchecked {
            _balances[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        uint256 bal = _balances[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            _balances[from] = bal - amount;
            _totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
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

    /// @notice 跨链铸造所需票数 = ceil(2/3 * validatorCount)
    function requiredVotes() public view returns (uint256) {
        uint256 n = validatorCount;
        if (n == 0) return 0;
        return (n * 2 + 2) / 3;
    }

    // ---------------------------------------------------------------------
    // Admin 铸币 / 空投
    // ---------------------------------------------------------------------
    function mint(address to, uint256 amount) external onlyAdmin {
        if (amount == 0) revert InvalidAmount();
        _mint(to, amount);
    }

    /// @notice admin 批量空投。amounts 单位为最小单位（1 GB = 1e9）。
    function airdrop(address[] calldata recipients, uint256[] calldata amounts) external onlyAdmin {
        uint256 len = recipients.length;
        if (len != amounts.length) revert LengthMismatch();
        uint256 total;
        for (uint256 i = 0; i < len; i++) {
            _mint(recipients[i], amounts[i]);
            total += amounts[i];
        }
        emit Airdrop(msg.sender, len, total);
    }

    /// @notice admin 等额空投（每个地址同一数量）。
    function airdropEqual(address[] calldata recipients, uint256 amountEach) external onlyAdmin {
        if (amountEach == 0) revert InvalidAmount();
        uint256 len = recipients.length;
        for (uint256 i = 0; i < len; i++) {
            _mint(recipients[i], amountEach);
        }
        emit Airdrop(msg.sender, len, amountEach * len);
    }

    // ---------------------------------------------------------------------
    // 焚烧（持有人自焚 / 授权焚烧）
    // ---------------------------------------------------------------------
    function burn(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _burn(msg.sender, amount);
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
        _burn(account, amount);
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
        _burn(msg.sender, amount);
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
        _mint(p.recipient, p.amount);
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
}
