// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "../contracts/access/Ownable.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

/**
 * @title ConetTreasury (CoNET L1)
 * @dev CoNET 链上的国库合约。提供 ERC20 工厂（仅 owner 可创建）与 miner 2/3 投票 mint 机制。
 */

// --- 工厂创建的 ERC20 模板 ---
interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface IBurnableFactoryERC20 {
    function burnFrom(address account, uint256 amount) external;
}

interface IBUnitAirdrop {
    function claimFor(address claimant, uint256 nonce, uint256 deadline, bytes calldata signature) external;
    function mintForUsdcPurchase(address to, uint256 bunitAmount) external;
}

/// @dev GuardianNodesInfoV6：miner 鉴定使用其中节点的 nodeAddress（节点地址）。一个 node 唯一对应 id、ipaddress、pgp、pgpKey
interface IGuardianNodesInfoV6 {
    function getOwnerIPs(address nodeAddress) external view returns (string[] memory ips);
    function getUniqueOwnerCount() external view returns (uint256);
}

contract FactoryERC20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    address public immutable minter;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address minter_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        minter = minter_;
    }

    modifier onlyMinter() {
        require(msg.sender == minter, "FactoryERC20: caller is not minter");
        _;
    }

    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public view returns (uint8) { return _decimals; }
    function totalSupply() public view returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view returns (uint256) { return _balances[account]; }
    function allowance(address owner, address spender) public view returns (uint256) { return _allowances[owner][spender]; }

    function mint(address to, uint256 amount) external onlyMinter {
        require(to != address(0), "FactoryERC20: mint to zero");
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 value) public returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= value, "FactoryERC20: insufficient allowance");
        unchecked { _allowances[from][msg.sender] = currentAllowance - value; }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(from != address(0) && to != address(0), "FactoryERC20: zero address");
        require(_balances[from] >= value, "FactoryERC20: insufficient balance");
        unchecked {
            _balances[from] -= value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    /// @dev 仅 minter 可调用，burn 指定账户的代币。调用前 account 需 approve minter。
    function burnFrom(address account, uint256 amount) external onlyMinter {
        uint256 currentAllowance = _allowances[account][msg.sender];
        require(currentAllowance >= amount, "FactoryERC20: insufficient allowance");
        unchecked { _allowances[account][msg.sender] = currentAllowance - amount; }
        require(account != address(0), "FactoryERC20: burn from zero");
        uint256 balance = _balances[account];
        require(balance >= amount, "FactoryERC20: insufficient balance");
        unchecked {
            _balances[account] = balance - amount;
            _totalSupply -= amount;
        }
        emit Transfer(account, address(0), amount);
    }
}

// --- 国库合约 ---
contract ConetTreasury is Ownable {
    // --- Miner 治理：仅使用 GuardianNodesInfoV6（nodeAddress 即节点地址），国库自身不维护 miner 列表 ---

    // --- 工厂创建的 ERC20 一览表 ---
    address[] private _createdTokens;
    mapping(address => bool) private _isCreatedToken;
    /// @dev CoNET token => Base 链上对应 ERC20 地址（出金时 miner 在 BaseTreasury 转账用）
    mapping(address => address) private _baseTokenOf;

    // --- 提案与投票：以 txHash 为键，仅支持 mint ---
    struct Proposal {
        address token;       // 列表中的 ERC20 地址
        address recipient;
        uint256 amount;
        uint256 voteCount;
        bool executed;
    }
    mapping(bytes32 => Proposal) public proposals;
    mapping(bytes32 => mapping(address => bool)) public hasVoted;

    event ERC20Created(address indexed token, string name, string symbol, uint8 decimals, address indexed baseToken);
    event ProposalCreated(bytes32 indexed txHash, address token, address recipient, uint256 amount, address indexed firstVoter);
    event Voted(bytes32 indexed txHash, address indexed miner, uint256 voteCount);
    event ProposalExecuted(bytes32 indexed txHash);
    event MintExecuted(address indexed token, address indexed to, uint256 amount);
    /// @dev 用户出金：burn 时触发，miner 监听此事件获取 txHash 与 baseToken，在 BaseTreasury 发起 vote(txHash, false, baseToken, user, amount)
    event BurnRequested(address indexed user, address indexed token, uint256 amount, address baseToken);
    event BUnitAirdropUpdated(address indexed oldAirdrop, address indexed newAirdrop);
    event AirdropProposalCreated(bytes32 indexed proposalId, address indexed claimant, uint256 nonce, uint256 deadline, address indexed firstVoter);
    event AirdropVoted(bytes32 indexed proposalId, address indexed miner, uint256 voteCount);
    event AirdropExecuted(bytes32 indexed proposalId, address indexed claimant);
    /// @dev USDC 购买 B-Unit 执行：miner 投票通过后按 1 USDC = 100 B-Units 铸造
    event Usdc2BUnitExecuted(bytes32 indexed txHash, address indexed user, uint256 usdcAmount, uint256 bunitAmount);
    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event MintByAdmin(address indexed token, address indexed to, uint256 amount);
    event AirdropBUnitByAdmin(address indexed claimant, uint256 amount);
    event AirdropBUnitFromUsdcByAdmin(address indexed user, uint256 usdcAmount, uint256 bunitAmount);

    error NotMiner();
    error AlreadyVoted();
    error ProposalNotExecutable();
    error ProposalAlreadyExecuted();
    error ProposalMismatch();
    error InvalidAmount();
    error InvalidTarget();
    error TokenNotInList();
    error SignatureExpired();
    error InvalidSignature();
    error BUnitAirdropNotSet();
    error NotAdmin();

    mapping(address => bool) public adminList;

    address public bunitAirdrop;
    /// @dev GuardianNodesInfoV6 地址，用于 miner 鉴定。若已设置，则 getOwnerIPs(nodeAddress).length > 0 即为 miner（nodeAddress 为 Guardian 节点地址）
    address public guardianNodesInfoV6;

    // --- B-Unit Airdrop 投票：2/3 通过后 call BUnitAirdrop.claimFor ---
    struct AirdropProposal {
        address claimant;
        uint256 nonce;
        uint256 deadline;
        bytes signature;
        uint256 voteCount;
        bool executed;
    }

    mapping(bytes32 => AirdropProposal) public airdropProposals;
    mapping(bytes32 => mapping(address => bool)) public hasVotedAirdrop;

    // --- USDC 购买 B-Unit 投票：以 Base 链 txHash 为键，无需用户签名 ---
    struct Usdc2BUnitProposal {
        address user;
        uint256 usdcAmount;
        uint256 voteCount;
        bool executed;
    }
    mapping(bytes32 => Usdc2BUnitProposal) public usdc2BUnitProposals;
    mapping(bytes32 => mapping(address => bool)) public hasVotedUsdc2BUnit;

    /// @dev USDC 兑换 B-Unit 统计：经 miner 投票执行的 airdrop 累计 B-Unit 总量 (6 位精度)
    uint256 public totalUsdc2BUnit;

    /// @dev 每次 airdrop 固定 20 BUint (6 decimals)，与 BUnitAirdrop.CLAIM_AMOUNT 一致
    uint256 public constant AIRDROP_BUNIT_AMOUNT = 20 * 1e6;
    /// @dev USDC 兑换 B-Unit 比例：1 USDC (6 decimals) = 100 B-Units (6 decimals)
    uint256 public constant USDC_TO_BUNIT_RATE = 100;

    bytes32 private constant VOTE_TYPEHASH =
        keccak256("Vote(address miner,bytes32 txHash,address token,address recipient,uint256 amount,uint256 deadline)");
    bytes32 private constant BURN_TYPEHASH =
        keccak256("Burn(address user,address token,uint256 amount,uint256 nonce,uint256 deadline)");
    bytes32 private constant VOTE_AIRDROP_TYPEHASH =
        keccak256("VoteAirdropBUnit(address miner,address claimant,uint256 nonce,uint256 deadline,uint256 voteDeadline)");
    bytes32 public immutable DOMAIN_SEPARATOR;

    mapping(address => uint256) public burnNonces;

    modifier onlyAdmin() {
        if (msg.sender != owner() && !adminList[msg.sender]) revert NotAdmin();
        _;
    }

    constructor(address initialOwner, address _guardianNodesInfoV6) Ownable(initialOwner) {
        guardianNodesInfoV6 = _guardianNodesInfoV6;
        adminList[initialOwner] = true; // owner 默认也是 admin
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("ConetTreasury")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }

    // ==========================================
    // ERC20 工厂 (仅 owner)
    // ==========================================

    /**
     * @dev 创建新的 ERC20。仅 owner 可调用。新代币的 minter 为本合约。
     *      baseToken 为该 CoNET 代币在 Base 链上对应的 ERC20 地址，出金时 miner 在 BaseTreasury 转账用。
     */
    function createERC20(string calldata name_, string calldata symbol_, uint8 decimals_, address baseToken) external onlyOwner returns (address token) {
        token = address(new FactoryERC20(name_, symbol_, decimals_, address(this)));
        _createdTokens.push(token);
        _isCreatedToken[token] = true;
        _baseTokenOf[token] = baseToken;
        emit ERC20Created(token, name_, symbol_, decimals_, baseToken);
        return token;
    }

    /**
     * @dev 查询 CoNET token 对应的 Base 链 ERC20 地址。
     */
    function baseTokenOf(address token) external view returns (address) {
        return _baseTokenOf[token];
    }

    /**
     * @dev Owner 更新 token 对应的 Base 地址。
     */
    function setBaseToken(address token, address baseToken) external onlyOwner {
        if (!_isCreatedToken[token]) revert TokenNotInList();
        _baseTokenOf[token] = baseToken;
    }

    /**
     * @dev Owner 设置 GuardianNodesInfoV6 地址。若已设置，miner 鉴定使用 getOwnerIPs(nodeAddress).length > 0。
     */
    function setGuardianNodesInfoV6(address _guardianNodesInfoV6) external onlyOwner {
        guardianNodesInfoV6 = _guardianNodesInfoV6;
    }

    /**
     * @dev Owner 设置 BUnitAirdrop 合约地址。ConetTreasury 需为 BUnitAirdrop 的 admin。
     */
    function setBUnitAirdrop(address _bunitAirdrop) external onlyOwner {
        address oldAirdrop = bunitAirdrop;
        bunitAirdrop = _bunitAirdrop;
        emit BUnitAirdropUpdated(oldAirdrop, _bunitAirdrop);
    }

    /**
     * @dev Owner 添加 admin。Admin 无需 miner 投票即可执行 ERC20 mint 与 B-Unit airdrop。
     */
    function addAdmin(address admin) external onlyOwner {
        if (admin == address(0)) revert InvalidTarget();
        adminList[admin] = true;
        emit AdminAdded(admin);
    }

    /**
     * @dev Owner 移除 admin。
     */
    function removeAdmin(address admin) external onlyOwner {
        adminList[admin] = false;
        emit AdminRemoved(admin);
    }

    /**
     * @dev 获取工厂创建的 ERC20 一览表
     */
    function getCreatedTokens() external view returns (address[] memory) {
        return _createdTokens;
    }

    /**
     * @dev 检查地址是否在工厂创建的列表中
     */
    function isCreatedToken(address token) external view returns (bool) {
        return _isCreatedToken[token];
    }

    function createdTokenCount() external view returns (uint256) {
        return _createdTokens.length;
    }

    // ==========================================
    // 用户出金 (burn)
    // ==========================================

    /**
     * @dev 用户出金：burn 指定数量的 CoNET 代币。调用前需先 approve 本合约。
     *      发出 BurnRequested 事件，miner 监听后获取该交易的 txHash，
     *      在 BaseTreasury 发起 vote(txHash, false, baseToken, user, amount) 转账投票。
     */
    function burn(address token, uint256 amount) external {
        _doBurn(msg.sender, token, amount);
    }

    /**
     * @dev 用户离线签字出金。用户签 Burn(user, token, amount, nonce, deadline)，
     *      任何人可代为提交并代付 gas。user 需已 approve 本合约。
     *      EIP-712: domain { name: "ConetTreasury", version: "1", chainId, verifyingContract }
     *      types: { Burn: [{ name: "user", type: "address" }, { name: "token", type: "address" }, { name: "amount", type: "uint256" }, { name: "nonce", type: "uint256" }, { name: "deadline", type: "uint256" }] }
     */
    function burnWithSignature(
        address user,
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (burnNonces[user] != nonce) revert InvalidSignature();

        bytes32 structHash = keccak256(abi.encode(BURN_TYPEHASH, user, token, amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address signer = ECDSA.recover(digest, signature);
        if (signer != user) revert InvalidSignature();

        burnNonces[user]++;
        _doBurn(user, token, amount);
    }

    /**
     * @dev 返回 burnWithSignature 的 EIP-712 摘要，供前端 signTypedDataV4。
     */
    function getBurnDigest(address user, address token, uint256 amount, uint256 nonce, uint256 deadline)
        external view returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(BURN_TYPEHASH, user, token, amount, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _doBurn(address user, address token, uint256 amount) internal {
        if (token == address(0)) revert InvalidTarget();
        if (amount == 0) revert InvalidAmount();
        if (!_isCreatedToken[token]) revert TokenNotInList();

        IBurnableFactoryERC20(token).burnFrom(user, amount);
        emit BurnRequested(user, token, amount, _baseTokenOf[token]);
    }

    // ==========================================
    // Admin 直接执行（无需 miner 投票）
    // ==========================================

    /**
     * @dev Admin 直接铸造 ERC20 到指定地址，无需 miner 投票。
     */
    function mintForAdmin(address token, address recipient, uint256 amount) external onlyAdmin {
        if (recipient == address(0)) revert InvalidTarget();
        if (amount == 0) revert InvalidAmount();
        if (!_isCreatedToken[token]) revert TokenNotInList();
        IMintableERC20(token).mint(recipient, amount);
        emit MintByAdmin(token, recipient, amount);
    }

    /**
     * @dev Admin 直接执行 B-Unit 免费池 airdrop（claimFor），无需 miner 投票。
     */
    function airdropBUnitForAdmin(
        address claimant,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external onlyAdmin {
        if (bunitAirdrop == address(0)) revert BUnitAirdropNotSet();
        if (claimant == address(0)) revert InvalidTarget();
        IBUnitAirdrop(bunitAirdrop).claimFor(claimant, nonce, deadline, signature);
        totalUsdc2BUnit += AIRDROP_BUNIT_AMOUNT;
        emit AirdropBUnitByAdmin(claimant, AIRDROP_BUNIT_AMOUNT);
    }

    /**
     * @dev Admin 直接执行 USDC 购买 B-Unit（mintForUsdcPurchase），无需 miner 投票。
     */
    function airdropBUnitFromUsdcForAdmin(address user, uint256 usdcAmount) external onlyAdmin {
        if (bunitAirdrop == address(0)) revert BUnitAirdropNotSet();
        if (user == address(0)) revert InvalidTarget();
        if (usdcAmount == 0) revert InvalidAmount();
        uint256 bunitAmount = usdcAmount * USDC_TO_BUNIT_RATE;
        totalUsdc2BUnit += bunitAmount;
        IBUnitAirdrop(bunitAirdrop).mintForUsdcPurchase(user, bunitAmount);
        emit AirdropBUnitFromUsdcByAdmin(user, usdcAmount, bunitAmount);
    }

    // ==========================================
    // Miner 鉴定：仅使用 GuardianNodesInfoV6.getOwnerIPs(nodeAddress).length > 0
    // ==========================================

    function isMiner(address nodeAddress) public view returns (bool) {
        if (guardianNodesInfoV6 == address(0)) return false;
        return IGuardianNodesInfoV6(guardianNodesInfoV6).getOwnerIPs(nodeAddress).length > 0;
    }

    /// @dev 返回 Guardian 节点地址数量（用于 requiredVotes 的 2/3 计算）
    function minerCount() public view returns (uint256) {
        if (guardianNodesInfoV6 == address(0)) return 0;
        return IGuardianNodesInfoV6(guardianNodesInfoV6).getUniqueOwnerCount();
    }

    function requiredVotes() public view returns (uint256) {
        uint256 n = minerCount();
        if (n == 0) return 0;
        return (n * 2 + 2) / 3;
    }

    // ==========================================
    // 提案与投票：对列表中的 ERC20 执行 mint
    // ==========================================

    modifier onlyMiner() {
        if (!isMiner(msg.sender)) revert NotMiner();
        _;
    }

    /**
     * @dev 投票接口。txHash 为关联的链上交易记录 hash。
     *      token 必须为工厂创建的 ERC20 列表中的地址。
     */
    function vote(bytes32 txHash, address token, address recipient, uint256 amount) external onlyMiner {
        if (hasVoted[txHash][msg.sender]) revert AlreadyVoted();
        _applyVote(msg.sender, txHash, token, recipient, amount);
    }

    /**
     * @dev Miner 离线签字投票。miner 签 Vote(miner, txHash, token, recipient, amount, deadline)，
     *      任何人可代为提交并代付 gas。
     *      EIP-712: domain { name: "ConetTreasury", version: "1", chainId, verifyingContract }
     *      types: { Vote: [{ name: "miner", type: "address" }, { name: "txHash", type: "bytes32" }, { name: "token", type: "address" }, { name: "recipient", type: "address" }, { name: "amount", type: "uint256" }, { name: "deadline", type: "uint256" }] }
     */
    function voteWithSignature(
        address miner,
        bytes32 txHash,
        address token,
        address recipient,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (!isMiner(miner)) revert NotMiner();
        if (hasVoted[txHash][miner]) revert AlreadyVoted();

        bytes32 structHash = keccak256(abi.encode(
            VOTE_TYPEHASH,
            miner,
            txHash,
            token,
            recipient,
            amount,
            deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address signer = ECDSA.recover(digest, signature);
        if (signer != miner) revert InvalidSignature();

        _applyVote(miner, txHash, token, recipient, amount);
    }

    /**
     * @dev 返回 voteWithSignature 的 EIP-712 摘要，供 miner 前端 signTypedDataV4。
     */
    function getVoteDigest(
        address miner,
        bytes32 txHash,
        address token,
        address recipient,
        uint256 amount,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            VOTE_TYPEHASH,
            miner,
            txHash,
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
        address token,
        address recipient,
        uint256 amount
    ) internal {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidTarget();
        if (!_isCreatedToken[token]) revert TokenNotInList();

        Proposal storage p = proposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();

        if (p.amount == 0) {
            p.token = token;
            p.recipient = recipient;
            p.amount = amount;
            p.voteCount = 1;
            emit ProposalCreated(txHash, token, recipient, amount, miner);
        } else {
            if (p.token != token || p.recipient != recipient || p.amount != amount) revert ProposalMismatch();
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
        if (!_isCreatedToken[p.token]) revert TokenNotInList();

        p.executed = true;
        IMintableERC20(p.token).mint(p.recipient, p.amount);
        emit MintExecuted(p.token, p.recipient, p.amount);
        emit ProposalExecuted(txHash);
    }

    function getProposal(bytes32 txHash) external view returns (address token, address recipient, uint256 amount, uint256 voteCount, bool executed) {
        Proposal storage p = proposals[txHash];
        return (p.token, p.recipient, p.amount, p.voteCount, p.executed);
    }

    // ==========================================
    // USDC 购买 B-Unit 投票：miner 监听 Base BUnitPurchased，用 txHash + to 证明
    // ==========================================

    /**
     * @dev Miner 在 Base 监听到 BUnitPurchased 后，用 txHash 和 to 证明用户已支付 USDC，
     *      发起投票。2/3 通过后按 1 USDC = 100 B-Units 铸造到用户付费池。无需用户签名。
     */
    function voteAirdropBUnitFromBase(
        bytes32 txHash,
        address user,
        uint256 usdcAmount
    ) external onlyMiner {
        if (hasVotedUsdc2BUnit[txHash][msg.sender]) revert AlreadyVoted();
        _applyUsdc2BUnitVote(msg.sender, txHash, user, usdcAmount);
    }

    function _applyUsdc2BUnitVote(
        address miner,
        bytes32 txHash,
        address user,
        uint256 usdcAmount
    ) internal {
        if (user == address(0)) revert InvalidTarget();
        if (usdcAmount == 0) revert InvalidAmount();
        if (bunitAirdrop == address(0)) revert BUnitAirdropNotSet();

        Usdc2BUnitProposal storage p = usdc2BUnitProposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();

        if (p.voteCount == 0) {
            p.user = user;
            p.usdcAmount = usdcAmount;
            p.voteCount = 1;
        } else {
            if (p.user != user || p.usdcAmount != usdcAmount) revert ProposalMismatch();
            p.voteCount++;
        }

        hasVotedUsdc2BUnit[txHash][miner] = true;
        if (p.voteCount >= requiredVotes()) {
            _executeUsdc2BUnit(txHash);
        }
    }

    function _executeUsdc2BUnit(bytes32 txHash) internal {
        Usdc2BUnitProposal storage p = usdc2BUnitProposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.voteCount < requiredVotes()) revert ProposalNotExecutable();
        if (bunitAirdrop == address(0)) revert BUnitAirdropNotSet();

        p.executed = true;
        uint256 bunitAmount = p.usdcAmount * USDC_TO_BUNIT_RATE;
        totalUsdc2BUnit += bunitAmount;
        IBUnitAirdrop(bunitAirdrop).mintForUsdcPurchase(p.user, bunitAmount);
        emit Usdc2BUnitExecuted(txHash, p.user, p.usdcAmount, bunitAmount);
    }

    function getUsdc2BUnitProposal(bytes32 txHash) external view returns (
        address user,
        uint256 usdcAmount,
        uint256 voteCount,
        bool executed
    ) {
        Usdc2BUnitProposal storage p = usdc2BUnitProposals[txHash];
        return (p.user, p.usdcAmount, p.voteCount, p.executed);
    }

    // ==========================================
    // B-Unit Airdrop 投票：2/3 通过后 call BUnitAirdrop.claimFor（免费池，需用户签名）
    // ==========================================

    /**
     * @dev Miner 投票批准 B-Unit airdrop。用户需已签 ClaimAirdrop(claimant, nonce, deadline)，
     *      miner 投票通过后 ConetTreasury 调用 BUnitAirdrop.claimFor。ConetTreasury 需为 BUnitAirdrop 的 admin。
     */
    function voteAirdropBUnit(
        address claimant,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external onlyMiner {
        bytes32 proposalId = keccak256(abi.encodePacked(claimant, nonce, deadline, signature));
        _applyAirdropVote(msg.sender, proposalId, claimant, nonce, deadline, signature);
    }

    /**
     * @dev Miner 离线签字投票批准 B-Unit airdrop。
     *      EIP-712: VoteAirdropBUnit(miner, claimant, nonce, deadline, voteDeadline)
     */
    function voteAirdropBUnitWithSignature(
        address miner,
        address claimant,
        uint256 nonce,
        uint256 deadline,
        uint256 voteDeadline,
        bytes calldata claimSignature,
        bytes calldata voteSignature
    ) external {
        if (block.timestamp > voteDeadline) revert SignatureExpired();
        if (!isMiner(miner)) revert NotMiner();

        bytes32 structHash = keccak256(abi.encode(
            VOTE_AIRDROP_TYPEHASH,
            miner,
            claimant,
            nonce,
            deadline,
            voteDeadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address signer = ECDSA.recover(digest, voteSignature);
        if (signer != miner) revert InvalidSignature();

        bytes32 proposalId = keccak256(abi.encodePacked(claimant, nonce, deadline, claimSignature));
        if (hasVotedAirdrop[proposalId][miner]) revert AlreadyVoted();

        _applyAirdropVote(miner, proposalId, claimant, nonce, deadline, claimSignature);
    }

    /**
     * @dev 返回 voteAirdropBUnitWithSignature 的 EIP-712 摘要。
     */
    function getVoteAirdropDigest(
        address miner,
        address claimant,
        uint256 nonce,
        uint256 deadline,
        uint256 voteDeadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            VOTE_AIRDROP_TYPEHASH,
            miner,
            claimant,
            nonce,
            deadline,
            voteDeadline
        ));
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _applyAirdropVote(
        address miner,
        bytes32 proposalId,
        address claimant,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (bunitAirdrop == address(0)) revert BUnitAirdropNotSet();
        if (claimant == address(0)) revert InvalidTarget();

        AirdropProposal storage p = airdropProposals[proposalId];
        if (p.executed) revert ProposalAlreadyExecuted();

        if (p.voteCount == 0) {
            p.claimant = claimant;
            p.nonce = nonce;
            p.deadline = deadline;
            p.signature = signature;
            p.voteCount = 1;
            emit AirdropProposalCreated(proposalId, claimant, nonce, deadline, miner);
        } else {
            if (p.claimant != claimant || p.nonce != nonce || p.deadline != deadline) revert ProposalMismatch();
            if (keccak256(p.signature) != keccak256(signature)) revert ProposalMismatch();
            p.voteCount++;
        }

        hasVotedAirdrop[proposalId][miner] = true;
        emit AirdropVoted(proposalId, miner, p.voteCount);

        if (p.voteCount >= requiredVotes()) {
            _executeAirdrop(proposalId);
        }
    }

    function _executeAirdrop(bytes32 proposalId) internal {
        AirdropProposal storage p = airdropProposals[proposalId];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.voteCount < requiredVotes()) revert ProposalNotExecutable();
        if (bunitAirdrop == address(0)) revert BUnitAirdropNotSet();

        p.executed = true;
        totalUsdc2BUnit += AIRDROP_BUNIT_AMOUNT;
        IBUnitAirdrop(bunitAirdrop).claimFor(p.claimant, p.nonce, p.deadline, p.signature);
        emit AirdropExecuted(proposalId, p.claimant);
    }

    /**
     * @dev 返回 USDC 兑换 B-Unit 统计报告。totalBUnit 为累计 airdrop 的 B-Unit 总量 (6 位精度)，count 为执行次数。
     */
    function getUsdc2BUnitReport() external view returns (uint256 totalBUnit, uint256 count) {
        totalBUnit = totalUsdc2BUnit;
        count = totalBUnit / AIRDROP_BUNIT_AMOUNT;
    }

    function executeAirdropBUnit(bytes32 proposalId) external {
        _executeAirdrop(proposalId);
    }

    function getAirdropProposal(bytes32 proposalId) external view returns (
        address claimant,
        uint256 nonce,
        uint256 deadline,
        uint256 voteCount,
        bool executed
    ) {
        AirdropProposal storage p = airdropProposals[proposalId];
        return (p.claimant, p.nonce, p.deadline, p.voteCount, p.executed);
    }
}
