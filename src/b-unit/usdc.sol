// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "../contracts/access/Ownable.sol";

/**
 * @title USDC (CoNET L1)
 * @dev USDC 在 CoNET 链上的实现。name/symbol/decimals 与 Base USDC 一致。
 *      mint 由 miner 投票 2/3 多数通过后执行。owner 可增删 miner。
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

contract USDC is IERC20, Ownable {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // --- Miner 治理 ---
    address[] private _miners;
    mapping(address => bool) private _isMiner;

    // --- 提案与投票：以链上交易记录 hash 为键，仅支持 mint ---
    struct Proposal {
        address target;      // mint 接收地址
        uint256 amount;
        uint256 voteCount;
        bool executed;
    }
    mapping(bytes32 => Proposal) public proposals;           // txHash => Proposal
    mapping(bytes32 => mapping(address => bool)) public hasVoted;

    event MinerAdded(address indexed miner);
    event MinerRemoved(address indexed miner);
    event ProposalCreated(bytes32 indexed txHash, address target, uint256 amount, address indexed firstVoter);
    event Voted(bytes32 indexed txHash, address indexed miner, uint256 voteCount);
    event ProposalExecuted(bytes32 indexed txHash);

    error NotMiner();
    error AlreadyVoted();
    error ProposalNotExecutable();
    error ProposalAlreadyExecuted();
    error ProposalMismatch();
    error InvalidAmount();
    error InvalidTarget();
    error InsufficientBalance();

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ==========================================
    // Miner 管理 (仅 owner)
    // ==========================================

    function addMiner(address miner) external onlyOwner {
        if (miner == address(0)) revert InvalidTarget();
        if (_isMiner[miner]) return;
        _miners.push(miner);
        _isMiner[miner] = true;
        emit MinerAdded(miner);
    }

    function removeMiner(address miner) external onlyOwner {
        if (!_isMiner[miner]) return;
        _isMiner[miner] = false;
        for (uint256 i = 0; i < _miners.length; i++) {
            if (_miners[i] == miner) {
                _miners[i] = _miners[_miners.length - 1];
                _miners.pop();
                break;
            }
        }
        emit MinerRemoved(miner);
    }

    function getMiners() external view returns (address[] memory) {
        return _miners;
    }

    function isMiner(address account) external view returns (bool) {
        return _isMiner[account];
    }

    function minerCount() public view returns (uint256) {
        return _miners.length;
    }

    /// @dev 2/3 多数所需票数 (向上取整)
    function requiredVotes() public view returns (uint256) {
        uint256 n = _miners.length;
        if (n == 0) return 0;
        return (n * 2 + 2) / 3;
    }

    // ==========================================
    // 提案与投票：仅支持 mint，以 txHash 为键
    // ==========================================
    // @dev miner 观察到链上交易记录 hash 后调用 vote。首次出现该 hash 则建立新投票（voteCount=1），
    //      后续 miner 使用相同 hash 则投票数 +1。
    modifier onlyMiner() {
        if (!_isMiner[msg.sender]) revert NotMiner();
        _;
    }

    /**
     * @dev 投票接口（仅 mint）。txHash 为关联的链上交易记录 hash。
     *      - 首次出现 txHash：建立新提案，voteCount=1
     *      - 后续相同 txHash：voteCount+1，且 target/amount 须与已存提案一致
     */
    function vote(bytes32 txHash, address target, uint256 amount) external onlyMiner {
        if (amount == 0) revert InvalidAmount();
        if (target == address(0)) revert InvalidTarget();
        if (hasVoted[txHash][msg.sender]) revert AlreadyVoted();

        Proposal storage p = proposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();

        if (p.amount == 0) {
            // 首次：建立新投票
            p.target = target;
            p.amount = amount;
            p.voteCount = 1;
            emit ProposalCreated(txHash, target, amount, msg.sender);
        } else {
            // 后续：校验一致后累加
            if (p.target != target || p.amount != amount) revert ProposalMismatch();
            p.voteCount++;
        }

        hasVoted[txHash][msg.sender] = true;
        emit Voted(txHash, msg.sender, p.voteCount);

        if (p.voteCount >= requiredVotes()) {
            _execute(txHash);
        }
    }

    function execute(bytes32 txHash) external {
        _execute(txHash);
    }

    function _execute(bytes32 txHash) internal {
        Proposal storage p = proposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.amount == 0) revert ProposalNotExecutable();
        if (p.voteCount < requiredVotes()) revert ProposalNotExecutable();

        p.executed = true;
        _mintInternal(p.target, p.amount);
        emit ProposalExecuted(txHash);
    }

    function getProposal(bytes32 txHash) external view returns (address target, uint256 amount, uint256 voteCount, bool executed) {
        Proposal storage p = proposals[txHash];
        return (p.target, p.amount, p.voteCount, p.executed);
    }

    function _mintInternal(address to, uint256 amount) internal {
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    // ==========================================
    // ERC20 标准
    // ==========================================

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        if (currentAllowance < value) {
            revert("USDC: insufficient allowance");
        }
        unchecked {
            _allowances[from][msg.sender] = currentAllowance - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0) || to == address(0)) revert InvalidTarget();
        if (_balances[from] < value) revert InsufficientBalance();
        unchecked {
            _balances[from] -= value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }
}
