// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "../contracts/access/Ownable.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

/**
 * @title BaseTreasury (Base L2 Treasury)
 * @dev 部署在 Base 链上的国库合约。可接收 ETH 与任意 ERC20 资产。
 *      转出合约内资产（ETH 或 ERC20）需经 miner 投票 2/3 多数通过后自动执行。
 *      token 参数可为任意 ERC20 地址（USDC、WETH、DAI 等），不限于 USDC。
 *      支持 deposit（直接）与 depositWith3009Authorization（EIP-3009 离线签字）接收 ERC20。
 */
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev EIP-3009: bytes 格式签名（USDC 等使用）
interface IERC3009BytesSig {
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}

/// @dev EIP-3009: v,r,s 格式签名
interface IERC3009VRS {
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
    ) external;
}

contract BaseTreasury is Ownable {
    // --- Miner 治理 ---
    address[] private _miners;
    mapping(address => bool) private _isMiner;

    // --- 提案与投票：以链上交易记录 hash 为键 ---
    enum AssetType { ETH, ERC20 }
    struct Proposal {
        AssetType assetType;  // ETH 或 ERC20
        address token;       // ETH 时为 address(0)，ERC20 时为任意 ERC20 地址
        address recipient;
        uint256 amount;
        uint256 voteCount;
        bool executed;
    }
    mapping(bytes32 => Proposal) public proposals;
    mapping(bytes32 => mapping(address => bool)) public hasVoted;

    event MinerAdded(address indexed miner);
    event MinerRemoved(address indexed miner);
    event ProposalCreated(bytes32 indexed txHash, AssetType assetType, address token, address recipient, uint256 amount, address indexed firstVoter);
    event Voted(bytes32 indexed txHash, address indexed miner, uint256 voteCount);
    event ProposalExecuted(bytes32 indexed txHash);
    event ETHTransferred(address indexed to, uint256 amount);
    event ERC20Transferred(address indexed token, address indexed to, uint256 amount);
    /// @dev ETH 入库事件：用户直接转账存入时触发
    event ETHDeposited(address indexed depositor, uint256 amount);
    /// @dev ERC20 入库事件：用户通过 deposit 或 depositWith3009Authorization 存入时触发
    event ERC20Deposited(address indexed depositor, address indexed token, uint256 amount, bytes32 indexed nonce);
    /// @dev 用户用 USDC 购买 B-Unit：转账成功后触发，miner 监听后在 CoNET 为 user mint 等量 B-Unit
    event BUnitPurchased(address indexed user, address indexed usdc, uint256 amount);

    error NotMiner();
    error AlreadyVoted();
    error ProposalNotExecutable();
    error ProposalAlreadyExecuted();
    error ProposalMismatch();
    error InvalidAmount();
    error InvalidTarget();
    error InsufficientBalance();
    error TransferFailed();
    error SignatureExpired();
    error InvalidSignature();

    bytes32 private constant VOTE_TYPEHASH =
        keccak256("Vote(address miner,bytes32 txHash,bool isEth,address token,address recipient,uint256 amount,uint256 deadline)");
    bytes32 public immutable DOMAIN_SEPARATOR;

    constructor(address initialOwner) Ownable(initialOwner) {
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("BaseTreasury")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }

    /// @dev 接收 ETH。直接转账时触发 ETHDeposited 事件。
    receive() external payable {
        if (msg.value > 0) emit ETHDeposited(msg.sender, msg.value);
    }

    // ==========================================
    // ERC20 入库 (deposit / depositWith3009Authorization)
    // ==========================================

    /**
     * @dev 直接存入 ERC20。调用前需先 approve 本合约。
     */
    function deposit(address token, uint256 amount) external {
        if (token == address(0)) revert InvalidTarget();
        if (amount == 0) revert InvalidAmount();
        if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit ERC20Deposited(msg.sender, token, amount, bytes32(0));
    }

    /**
     * @dev 使用 EIP-3009 授权，从 from 扣款转入本合约。用户离线签 transferWithAuthorization，
     *      任何人可代为提交并代付 gas。适用于 USDC 等支持 EIP-3009 的 token。
     *      nonce 由 token 合约管理，每个 nonce 仅可使用一次。
     */
    function depositWith3009Authorization(
        address from,
        address token,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        if (token == address(0) || from == address(0)) revert InvalidTarget();
        if (amount == 0) revert InvalidAmount();

        IERC3009BytesSig(token).transferWithAuthorization(
            from,
            address(this),
            amount,
            validAfter,
            validBefore,
            nonce,
            signature
        );
        emit ERC20Deposited(from, token, amount, nonce);
    }

    /**
     * @dev 同上，使用 v,r,s 格式签名。
     */
    function depositWith3009AuthorizationVRS(
        address from,
        address token,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (token == address(0) || from == address(0)) revert InvalidTarget();
        if (amount == 0) revert InvalidAmount();

        IERC3009VRS(token).transferWithAuthorization(
            from,
            address(this),
            amount,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s
        );
        emit ERC20Deposited(from, token, amount, nonce);
    }

    // ==========================================
    // 购买 B-Unit (USDC 转账 + emit 事件)
    // ==========================================

    /**
     * @dev 直接购买 B-Unit。用户 approve 后调用，USDC 转入本合约，emit BUnitPurchased。
     *      Miner 监听后在 CoNET 为 user mint 等量 B-Unit（1:1，6 位精度）。
     */
    function purchaseBUnit(address usdc, uint256 amount) external {
        if (usdc == address(0)) revert InvalidTarget();
        if (amount == 0) revert InvalidAmount();
        if (!IERC20(usdc).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit BUnitPurchased(msg.sender, usdc, amount);
    }

    /**
     * @dev 离线签字购买 B-Unit。用户签 EIP-3009 transferWithAuthorization，
     *      USDC 转入本合约后 emit BUnitPurchased。任何人可代为提交并代付 gas。
     */
    function purchaseBUnitWith3009Authorization(
        address from,
        address usdc,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        if (usdc == address(0) || from == address(0)) revert InvalidTarget();
        if (amount == 0) revert InvalidAmount();

        IERC3009BytesSig(usdc).transferWithAuthorization(
            from,
            address(this),
            amount,
            validAfter,
            validBefore,
            nonce,
            signature
        );
        emit BUnitPurchased(from, usdc, amount);
    }

    /**
     * @dev 同上，使用 v,r,s 格式签名。
     */
    function purchaseBUnitWith3009AuthorizationVRS(
        address from,
        address usdc,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (usdc == address(0) || from == address(0)) revert InvalidTarget();
        if (amount == 0) revert InvalidAmount();

        IERC3009VRS(usdc).transferWithAuthorization(
            from,
            address(this),
            amount,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s
        );
        emit BUnitPurchased(from, usdc, amount);
    }

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

    function requiredVotes() public view returns (uint256) {
        uint256 n = _miners.length;
        if (n == 0) return 0;
        return (n * 2 + 2) / 3;
    }

    // ==========================================
    // 提案与投票
    // ==========================================

    modifier onlyMiner() {
        if (!_isMiner[msg.sender]) revert NotMiner();
        _;
    }

    /**
     * @dev 投票接口。txHash 为关联的链上交易记录 hash。
     *      - isEth: true=转 ETH，false=转 ERC20
     *      - token: ETH 时传 address(0)，ERC20 时为任意代币地址（USDC/WETH/DAI 等）
     *      - recipient: 接收地址
     *      - amount: 数量
     */
    function vote(bytes32 txHash, bool isEth, address token, address recipient, uint256 amount) external onlyMiner {
        if (hasVoted[txHash][msg.sender]) revert AlreadyVoted();
        _applyVote(msg.sender, txHash, isEth, token, recipient, amount);
    }

    /**
     * @dev Miner 离线签字投票。miner 签 Vote(miner, txHash, isEth, token, recipient, amount, deadline)，
     *      任何人可代为提交并代付 gas。
     *      EIP-712: domain { name: "BaseTreasury", version: "1", chainId, verifyingContract }
     *      types: { Vote: [{ name: "miner", type: "address" }, { name: "txHash", type: "bytes32" }, { name: "isEth", type: "bool" }, { name: "token", type: "address" }, { name: "recipient", type: "address" }, { name: "amount", type: "uint256" }, { name: "deadline", type: "uint256" }] }
     */
    function voteWithSignature(
        address miner,
        bytes32 txHash,
        bool isEth,
        address token,
        address recipient,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (!_isMiner[miner]) revert NotMiner();
        if (hasVoted[txHash][miner]) revert AlreadyVoted();

        bytes32 structHash = keccak256(abi.encode(
            VOTE_TYPEHASH,
            miner,
            txHash,
            isEth,
            token,
            recipient,
            amount,
            deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address signer = ECDSA.recover(digest, signature);
        if (signer != miner) revert InvalidSignature();

        _applyVote(miner, txHash, isEth, token, recipient, amount);
    }

    /**
     * @dev 返回 voteWithSignature 的 EIP-712 摘要，供 miner 前端 signTypedDataV4。
     */
    function getVoteDigest(
        address miner,
        bytes32 txHash,
        bool isEth,
        address token,
        address recipient,
        uint256 amount,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            VOTE_TYPEHASH,
            miner,
            txHash,
            isEth,
            token,
            recipient,
            amount,
            deadline
        ));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _applyVote(
        address miner,
        bytes32 txHash,
        bool isEth,
        address token,
        address recipient,
        uint256 amount
    ) internal {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidTarget();
        if (!isEth && token == address(0)) revert InvalidTarget();

        Proposal storage p = proposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();

        AssetType at = isEth ? AssetType.ETH : AssetType.ERC20;
        address t = isEth ? address(0) : token;

        if (p.amount == 0) {
            p.assetType = at;
            p.token = t;
            p.recipient = recipient;
            p.amount = amount;
            p.voteCount = 1;
            emit ProposalCreated(txHash, at, t, recipient, amount, miner);
        } else {
            if (p.assetType != at || p.token != t || p.recipient != recipient || p.amount != amount) {
                revert ProposalMismatch();
            }
            p.voteCount++;
        }

        hasVoted[txHash][miner] = true;
        emit Voted(txHash, miner, p.voteCount);

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

        if (p.assetType == AssetType.ETH) {
            if (address(this).balance < p.amount) revert InsufficientBalance();
            (bool ok,) = p.recipient.call{value: p.amount}("");
            if (!ok) revert TransferFailed();
            emit ETHTransferred(p.recipient, p.amount);
        } else {
            if (IERC20(p.token).balanceOf(address(this)) < p.amount) revert InsufficientBalance();
            if (!IERC20(p.token).transfer(p.recipient, p.amount)) revert TransferFailed();
            emit ERC20Transferred(p.token, p.recipient, p.amount);
        }
        emit ProposalExecuted(txHash);
    }

    function getProposal(bytes32 txHash) external view returns (
        AssetType assetType,
        address token,
        address recipient,
        uint256 amount,
        uint256 voteCount,
        bool executed
    ) {
        Proposal storage p = proposals[txHash];
        return (p.assetType, p.token, p.recipient, p.amount, p.voteCount, p.executed);
    }

    // ==========================================
    // 查询
    // ==========================================

    function ethBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev 查询任意 ERC20 代币在合约内的余额。token 可为 USDC、WETH、DAI 等任意地址。
     */
    function erc20Balance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @dev 批量查询多个 ERC20 余额。tokens 为代币地址数组。
     */
    function erc20Balances(address[] calldata tokens) external view returns (uint256[] memory balances) {
        balances = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balances[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
    }
}
