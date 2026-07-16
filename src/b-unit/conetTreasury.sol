// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";
import {FactoryERC20} from "./FactoryERC20.sol";

/**
 * @title ConetTreasury
 * @dev 跨链去中心化「单一国库」（各链 Nick CREATE2 同址）。miner 2/3 投票后执行 mint/burn/airdrop。
 *      跨链 peer 桥（wCNET / BUint / GB / wrapped ERC20）见 ConetTreasuryPeer（CREATE2 同址）。
 *      入金：receive() 收原生 ETH；depositWith3009Authorization 收任意 ERC20（EIP-3009 离线签字）；
 *           purchaseBUnitWith3009Authorization 收 USDC 并 emit BUnitPurchased（CoNET-SI 监听铸 B-Unit）。
 *      出金：voteErc20Transfer*（miner 2/3 + EIP-712 离线签字）转出任意 ERC20（含 Circle USDC）；
 *           token == address(0) 表示原生 ETH 出金（同一投票轨，取代旧 BaseTreasury ETH 投票）。
 *      注：受 EIP-170 24576 字节限制，未保留 BaseTreasury 的 approve-deposit / VRS 变体（无调用方），能力不减。
 *      本合约取代旧 BaseTreasury（功能超集），原 BaseTreasury / 旧 ConetTreasury 已弃用。
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

/// @dev 任意 ERC20 出金：从本合约余额 transfer（非工厂 mint）。
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
}

/// @dev EIP-3009: bytes 格式签名（USDC 等使用）。离线入金 / 购买 B-Unit 走此接口。
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

interface IBUnitAirdrop {
    function claimFor(address claimant, uint256 nonce, uint256 deadline, bytes calldata signature) external;
    function mintForUsdcPurchase(address to, uint256 usdcAmount, bytes32 baseTxHash) external;
    function consumeFromUser(address user, uint256 amount, bytes32 baseHash, uint256 baseGas, uint256 kind) external;
}

interface IConetGB1155 {
    function issueGB(address to, uint256 amountGB18) external;
    function revokeTotalOnly(address from, uint256 amountGB18) external;
}

interface IConetTreasuryPeerView {
    function buint() external view returns (address);
}

// --- 国库合约 ---
contract ConetTreasury {
    // --- Miner 治理：与 BaseTreasury 对齐，自维护 miner 表，部署者为首个 miner ---
    address[] private _miners;
    mapping(address => bool) private _isMiner;

    // --- 工厂创建的 ERC20 一览表 ---
    address[] private _createdTokens;
    mapping(address => bool) private _isCreatedToken;
    /// @dev CoNET token => Base 链上对应 ERC20 地址（出金时 miner 在 BaseTreasury 转账用）
    mapping(address => address) private _baseTokenOf;
    /// @dev 包装 token => 源链 chainId / 源链 ERC20（Peer 模块登记后镜像，供 burn 路由）
    mapping(address => uint256) private _peerChainIdOf;
    mapping(address => address) private _peerTokenOf;

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
    event MinerAdded(address indexed miner);
    event MintByMiner(address indexed token, address indexed to, uint256 amount);
    event AirdropBUnitByMiner(address indexed claimant, uint256 amount);
    event AirdropBUnitFromUsdcByMiner(address indexed user, uint256 usdcAmount, uint256 bunitAmount);
    event ConetGBUpdated(address indexed oldGb, address indexed newGb);
    /// @dev 跨链桥：miner 投票通过后工厂 ERC20 burnFrom（account 须 approve 本合约）
    event FactoryBurnProposalCreated(bytes32 indexed txHash, address token, address account, uint256 amount, address indexed firstVoter);
    event FactoryBurnVoted(bytes32 indexed txHash, address indexed miner, uint256 voteCount);
    event FactoryBurnExecuted(bytes32 indexed txHash, address token, address account, uint256 amount);
    /// @dev 跨链桥：B-Unit 消耗（经 BUnitAirdrop.consumeFromUser）
    event BUnitBurnProposalCreated(bytes32 indexed txHash, address user, uint256 amount, bytes32 peerTxHash, address indexed firstVoter);
    event BUnitBurnVoted(bytes32 indexed txHash, address indexed miner, uint256 voteCount);
    event BUnitBurnExecuted(bytes32 indexed txHash, address user, uint256 amount, bytes32 peerTxHash);
    /// @dev 跨链桥：GB 发行 / 撤销总量
    event GBIssueProposalCreated(bytes32 indexed txHash, address to, uint256 amountGB18, address indexed firstVoter);
    event GBIssueVoted(bytes32 indexed txHash, address indexed miner, uint256 voteCount);
    event GBIssueExecuted(bytes32 indexed txHash, address to, uint256 amountGB18);
    event GBRevokeProposalCreated(bytes32 indexed txHash, address from, uint256 amountGB18, address indexed firstVoter);
    event GBRevokeVoted(bytes32 indexed txHash, address indexed miner, uint256 voteCount);
    event GBRevokeExecuted(bytes32 indexed txHash, address from, uint256 amountGB18);
    event PeerModuleUpdated(address indexed oldPeer, address indexed newPeer);
    event AssetBridgeModuleUpdated(address indexed oldBridge, address indexed newBridge);
    event LiquidityStakingModuleUpdated(address indexed oldModule, address indexed newModule);
    event ERC20CreatedByBridge(
        address indexed token,
        string name,
        string symbol,
        uint8 decimals,
        address indexed baseToken,
        bytes32 indexed salt
    );
    /// @dev 任意 ERC20 出金：miner 2/3 通过后从本合约余额 transfer
    event Erc20TransferProposalCreated(
        bytes32 indexed txHash,
        address indexed token,
        address recipient,
        uint256 amount,
        address indexed firstVoter
    );
    event Erc20TransferVoted(bytes32 indexed txHash, address indexed miner, uint256 voteCount);
    event Erc20TransferExecuted(bytes32 indexed txHash, address indexed token, address recipient, uint256 amount);
    /// @dev 入金事件（与旧 BaseTreasury 签名一致，CoNET-SI / 客户端监听器无需改协议）
    event ETHDeposited(address indexed depositor, uint256 amount);
    event BUnitPurchased(address indexed user, address indexed usdc, uint256 amount);

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
    error ConetGBNotSet();
    error EmptyTokenMetadata();
    error InsufficientBalance();
    error TransferFailed();
    error NotAssetBridge();
    error TokenDeploymentFailed();
    error NotLiquidityStakingModule();

    address public peerModule;
    address public assetBridgeModule;
    address public liquidityStakingModule;
    address public bunitAirdrop;
    address public conetGB;

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

    /// @dev 跨链桥：工厂 ERC20 burn（对端链事件 → 本链 txHash 投票 → burnFrom）
    struct FactoryBurnProposal {
        address token;
        address account;
        uint256 amount;
        uint256 voteCount;
        bool executed;
    }
    mapping(bytes32 => FactoryBurnProposal) public factoryBurnProposals;
    mapping(bytes32 => mapping(address => bool)) public hasVotedFactoryBurn;

    /// @dev 跨链桥：B-Unit 业务 burn（consumeFromUser）
    struct BUnitBurnProposal {
        address user;
        uint256 amount;
        bytes32 peerTxHash;
        uint256 baseGas;
        uint256 kind;
        uint256 voteCount;
        bool executed;
    }
    mapping(bytes32 => BUnitBurnProposal) public bunitBurnProposals;
    mapping(bytes32 => mapping(address => bool)) public hasVotedBUnitBurn;

    /// @dev 跨链桥：GB 发行
    struct GBIssueProposal {
        address to;
        uint256 amountGB18;
        uint256 voteCount;
        bool executed;
    }
    mapping(bytes32 => GBIssueProposal) public gbIssueProposals;
    mapping(bytes32 => mapping(address => bool)) public hasVotedGBIssue;

    /// @dev 跨链桥：GB 撤销总量
    struct GBRevokeProposal {
        address from;
        uint256 amountGB18;
        uint256 voteCount;
        bool executed;
    }
    mapping(bytes32 => GBRevokeProposal) public gbRevokeProposals;
    mapping(bytes32 => mapping(address => bool)) public hasVotedGBRevoke;

    /// @dev 任意 ERC20 出金投票：从本合约余额 transfer 给 recipient（token 可为 Circle USDC 等外部 ERC20）
    struct Erc20TransferProposal {
        address token;
        address recipient;
        uint256 amount;
        uint256 voteCount;
        bool executed;
    }

    mapping(bytes32 => Erc20TransferProposal) public erc20TransferProposals;
    mapping(bytes32 => mapping(address => bool)) public hasVotedErc20Transfer;

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
    bytes32 private constant VOTE_ERC20_TRANSFER_TYPEHASH =
        keccak256(
            "VoteErc20Transfer(address miner,bytes32 txHash,address token,address recipient,uint256 amount,uint256 deadline)"
        );
    bytes32 public immutable DOMAIN_SEPARATOR;

    mapping(address => uint256) public burnNonces;

    modifier onlyMiner() {
        if (!_isMiner[msg.sender]) revert NotMiner();
        _;
    }

    constructor(address initialMiner) {
        if (initialMiner == address(0)) revert InvalidTarget();
        _miners.push(initialMiner);
        _isMiner[initialMiner] = true;
        emit MinerAdded(initialMiner);
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("ConetTreasury")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }

    // ==========================================
    // Miner 管理（与 BaseTreasury 对齐，miner 可添加新 miner）
    // ==========================================

    function addMiner(address miner) external onlyMiner {
        if (miner == address(0)) revert InvalidTarget();
        if (_isMiner[miner]) return;
        _miners.push(miner);
        _isMiner[miner] = true;
        emit MinerAdded(miner);
    }

    function getMiners() external view returns (address[] memory) {
        return _miners;
    }

    function minerCount() public view returns (uint256) {
        return _miners.length;
    }

    function requiredVotes() public view returns (uint256) {
        uint256 n = minerCount();
        if (n == 0) return 0;
        return (n * 2 + 2) / 3;
    }

    function isMiner(address account) external view returns (bool) {
        return _isMiner[account];
    }

    // ==========================================
    // ERC20 工厂 (仅 miner)
    // ==========================================

    /**
     * @dev 创建新的 ERC20。仅 miner 可调用。新代币的 minter 为本合约。
     *      baseToken 为该 CoNET 代币在 Base 链上对应的 ERC20 地址，出金时 miner 在 BaseTreasury 转账用。
     */
    function createERC20(string calldata name_, string calldata symbol_, uint8 decimals_, address baseToken) external onlyMiner returns (address token) {
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert EmptyTokenMetadata();
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
     * @dev Miner 更新 token 对应的 Base 地址。
     */
    function setBaseToken(address token, address baseToken) external onlyMiner {
        if (!_isCreatedToken[token]) revert TokenNotInList();
        _baseTokenOf[token] = baseToken;
    }

    // ==========================================
    // ConetTreasuryPeer 链接（跨链桥在 Peer 模块；包装 ERC20 minter 仍为本合约）
    // ==========================================

    function setPeerModule(address _peer) external onlyMiner {
        if (_peer == address(0)) revert InvalidTarget();
        address old = peerModule;
        peerModule = _peer;
        emit PeerModuleUpdated(old, _peer);
    }

    function setAssetBridgeModule(address bridge) external onlyMiner {
        if (bridge == address(0)) revert InvalidTarget();
        address old = assetBridgeModule;
        assetBridgeModule = bridge;
        emit AssetBridgeModuleUpdated(old, bridge);
    }

    /**
     * @dev Timed liquidity staking module. The module never receives mint/burn
     * authority directly; this treasury remains the sole FactoryERC20 minter.
     */
    function setLiquidityStakingModule(address module) external onlyMiner {
        if (module == address(0)) revert InvalidTarget();
        address old = liquidityStakingModule;
        liquidityStakingModule = module;
        emit LiquidityStakingModuleUpdated(old, module);
    }

    /**
     * @dev Deployment path reserved for the cross-chain bridge governance
     * contract. The created token is minter-controlled by this treasury.
     */
    function createERC20FromBridge(
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_,
        address baseToken,
        bytes32 salt
    ) external returns (address token) {
        if (msg.sender != assetBridgeModule) revert NotAssetBridge();
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert EmptyTokenMetadata();
        bytes memory initCode = abi.encodePacked(
            type(FactoryERC20).creationCode,
            abi.encode(name_, symbol_, decimals_, address(this))
        );
        assembly {
            token := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (token == address(0)) revert TokenDeploymentFailed();
        _createdTokens.push(token);
        _isCreatedToken[token] = true;
        _baseTokenOf[token] = baseToken;
        emit ERC20CreatedByBridge(token, name_, symbol_, decimals_, baseToken, salt);
    }

    function mintFactoryToken(address token, address to, uint256 amount) external {
        if (msg.sender != peerModule) revert NotMiner();
        IMintableERC20(token).mint(to, amount);
    }

    function burnFactoryFrom(address token, address account, uint256 amount) external {
        if (msg.sender != peerModule) revert NotMiner();
        IBurnableFactoryERC20(token).burnFrom(account, amount);
    }

    function mintFactoryTokenLiquidityStaking(address token, address to, uint256 amount) external {
        if (msg.sender != liquidityStakingModule) revert NotLiquidityStakingModule();
        if (!_isCreatedToken[token]) revert TokenNotInList();
        if (to == address(0) || amount == 0) revert InvalidTarget();
        IMintableERC20(token).mint(to, amount);
    }

    function burnFactoryFromLiquidityStaking(address token, address account, uint256 amount) external {
        if (msg.sender != liquidityStakingModule) revert NotLiquidityStakingModule();
        if (!_isCreatedToken[token]) revert TokenNotInList();
        if (account == address(0) || amount == 0) revert InvalidTarget();
        IBurnableFactoryERC20(token).burnFrom(account, amount);
    }

    /// @dev Peer 部署包装 ERC20 后登记，供 factoryBurn / baseTokenOf 使用
    function registerPeerWrappedToken(address wrapped, uint256 peerChainId, address peerToken) external {
        if (msg.sender != peerModule) revert NotMiner();
        if (wrapped == address(0)) revert InvalidTarget();
        if (!_isCreatedToken[wrapped]) {
            _createdTokens.push(wrapped);
            _isCreatedToken[wrapped] = true;
        }
        _peerChainIdOf[wrapped] = peerChainId;
        _peerTokenOf[wrapped] = peerToken;
        if (peerChainId == 8453) {
            _baseTokenOf[wrapped] = peerToken;
        }
    }

    function peerChainIdOf(address wrappedToken) external view returns (uint256) {
        return _peerChainIdOf[wrappedToken];
    }

    function peerTokenOf(address wrappedToken) external view returns (address) {
        return _peerTokenOf[wrappedToken];
    }

    /**
     * @dev Miner 设置 BUnitAirdrop 合约地址。ConetTreasury 需为 BUnitAirdrop 的 admin。
     */
    function setBUnitAirdrop(address _bunitAirdrop) external onlyMiner {
        address oldAirdrop = bunitAirdrop;
        bunitAirdrop = _bunitAirdrop;
        emit BUnitAirdropUpdated(oldAirdrop, _bunitAirdrop);
    }

    /**
     * @dev Miner 设置 ConetGB1155 地址。ConetTreasury 须持有 GB 的 ISSUER_ROLE 方可 issue/revoke。
     */
    function setConetGB(address _conetGB) external onlyMiner {
        address oldGb = conetGB;
        conetGB = _conetGB;
        emit ConetGBUpdated(oldGb, _conetGB);
    }

    /**
     * @dev 跨链桥已配置目标一览（各链 post-deploy 写入；CREATE2 同址后地址一致）。
     */
    function getBridgeTargets()
        external
        view
        returns (address airdrop, address gb, address bUnit, uint256 factoryTokenCount)
    {
        address bu = address(0);
        if (peerModule != address(0)) {
            bu = IConetTreasuryPeerView(peerModule).buint();
        }
        return (bunitAirdrop, conetGB, bu, _createdTokens.length);
    }

    /**
     * @dev BUnitAirdrop 焚烧付费池 B-Unit 后调用，将等值 USDC mint 到 recipient。
     *      仅 BUnitAirdrop 可调用。token 须为工厂创建的 ERC20（如 conetUsdc）。
     */
    function mintForAdmin(address token, address recipient, uint256 amount) external {
        if (msg.sender != bunitAirdrop) revert NotMiner();
        if (token == address(0) || recipient == address(0)) revert InvalidTarget();
        if (amount == 0) revert InvalidAmount();
        if (!_isCreatedToken[token]) revert TokenNotInList();
        IMintableERC20(token).mint(recipient, amount);
        emit MintByMiner(token, recipient, amount);
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

 

    /**
     * @dev Miner 直接执行 B-Unit 免费池 airdrop（claimFor），无需投票。
     */
    function airdropBUnitForAdmin(
        address claimant,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external onlyMiner {
        if (bunitAirdrop == address(0)) revert BUnitAirdropNotSet();
        if (claimant == address(0)) revert InvalidTarget();
        IBUnitAirdrop(bunitAirdrop).claimFor(claimant, nonce, deadline, signature);
        totalUsdc2BUnit += AIRDROP_BUNIT_AMOUNT;
        emit AirdropBUnitByMiner(claimant, AIRDROP_BUNIT_AMOUNT);
    }

    // ==========================================
    // 提案与投票：对列表中的 ERC20 执行 mint
    // ==========================================

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
        if (!_isMiner[miner]) revert NotMiner();
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
    // 任意 ERC20 出金：miner 2/3 投票后从本合约余额 transfer（含 Circle USDC 等）
    // ==========================================

    /**
     * @dev Miner 对「从本合约余额转出任意 ERC20 或原生 ETH」投票。txHash 为关联链上业务交易 hash（幂等键）。
     *      token 可为任意 ERC20（含非工厂创建的 Circle USDC）；token == address(0) 表示原生 ETH。
     *      与上方工厂 token mint 的 {vote} 独立。
     */
    function voteErc20Transfer(bytes32 txHash, address token, address recipient, uint256 amount) external onlyMiner {
        if (hasVotedErc20Transfer[txHash][msg.sender]) revert AlreadyVoted();
        _applyErc20TransferVote(msg.sender, txHash, token, recipient, amount);
    }

    /**
     * @dev Miner 离线签字 ERC20 出金投票。任何人可代为提交并代付 gas。
     *      EIP-712 types: VoteErc20Transfer(miner, txHash, token, recipient, amount, deadline)
     */
    function voteErc20TransferWithSignature(
        address miner,
        bytes32 txHash,
        address token,
        address recipient,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();
        if (!_isMiner[miner]) revert NotMiner();
        if (hasVotedErc20Transfer[txHash][miner]) revert AlreadyVoted();

        bytes32 structHash = keccak256(
            abi.encode(VOTE_ERC20_TRANSFER_TYPEHASH, miner, txHash, token, recipient, amount, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address signer = ECDSA.recover(digest, signature);
        if (signer != miner) revert InvalidSignature();

        _applyErc20TransferVote(miner, txHash, token, recipient, amount);
    }

    // 注：ERC20/ETH 出金的 EIP-712 digest 由链下用 DOMAIN_SEPARATOR + VOTE_ERC20_TRANSFER_TYPEHASH 自行计算
    // （ethers TypedDataEncoder），不再提供 on-chain getErc20TransferVoteDigest（节省 bytecode，EIP-170）。

    function executeErc20Transfer(bytes32 txHash) external {
        _executeErc20Transfer(txHash);
    }

    function _applyErc20TransferVote(
        address miner,
        bytes32 txHash,
        address token,
        address recipient,
        uint256 amount
    ) internal {
        // token == address(0) 表示原生 ETH 出金；非零为 ERC20（含 Circle USDC）
        if (recipient == address(0)) revert InvalidTarget();
        if (amount == 0) revert InvalidAmount();

        Erc20TransferProposal storage p = erc20TransferProposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();

        if (p.amount == 0) {
            p.token = token;
            p.recipient = recipient;
            p.amount = amount;
            p.voteCount = 1;
            emit Erc20TransferProposalCreated(txHash, token, recipient, amount, miner);
        } else {
            if (p.token != token || p.recipient != recipient || p.amount != amount) revert ProposalMismatch();
            p.voteCount++;
        }

        hasVotedErc20Transfer[txHash][miner] = true;
        emit Erc20TransferVoted(txHash, miner, p.voteCount);

        if (p.voteCount >= requiredVotes()) {
            _executeErc20Transfer(txHash);
        }
    }

    function _executeErc20Transfer(bytes32 txHash) internal {
        Erc20TransferProposal storage p = erc20TransferProposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.amount == 0) revert ProposalNotExecutable();
        if (p.voteCount < requiredVotes()) revert ProposalNotExecutable();

        p.executed = true;
        if (p.token == address(0)) {
            // 原生 ETH 出金
            if (address(this).balance < p.amount) revert InsufficientBalance();
            (bool ok, ) = payable(p.recipient).call{value: p.amount}("");
            if (!ok) revert TransferFailed();
        } else {
            if (IERC20(p.token).balanceOf(address(this)) < p.amount) revert InsufficientBalance();
            if (!IERC20(p.token).transfer(p.recipient, p.amount)) revert TransferFailed();
        }
        emit Erc20TransferExecuted(txHash, p.token, p.recipient, p.amount);
    }

    // getErc20TransferProposal 已由 public mapping erc20TransferProposals(txHash) 自动 getter 提供，无需重复（EIP-170）。

    // 余额查询用链下 RPC：ERC20.balanceOf(treasury) / provider.getBalance(treasury)。
    // 不再提供 on-chain erc20Balance / ethBalance view（节省 bytecode，EIP-170）。

    // ==========================================
    // 入金（取代旧 BaseTreasury）：原生 ETH / ERC20 / EIP-3009 离线
    // ==========================================

    /// @dev 接收原生 ETH。直接转账时触发 ETHDeposited。
    receive() external payable {
        if (msg.value > 0) emit ETHDeposited(msg.sender, msg.value);
    }

    // 通用 ERC20 入金可直接 transfer 到本合约地址（落入余额，经 voteErc20Transfer 出金）。
    // 任意 ERC20 也可直接 transfer 进来。若需 EIP-3009 离线入金，使用 purchaseBUnitWith3009Authorization（USDC）。

    // ==========================================
    // 购买 B-Unit（USDC → 本合约 + emit BUnitPurchased，CoNET-SI 监听铸 B-Unit）
    // ==========================================

    /// @dev 离线签字购买 B-Unit（EIP-3009 bytes 签名）。任何人可代付 gas。
    ///      服务端 MemberCard.purchaseBUnitFromBaseProcess 调用本函数。
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
            from, address(this), amount, validAfter, validBefore, nonce, signature
        );
        emit BUnitPurchased(from, usdc, amount);
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
        IBUnitAirdrop(bunitAirdrop).mintForUsdcPurchase(p.user, p.usdcAmount, txHash);
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
        if (!_isMiner[miner]) revert NotMiner();

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

    // ==========================================
    // 跨链桥：工厂 ERC20 burn（miner 2/3 → burnFrom，account 须 approve 本合约）
    // ==========================================

    function voteFactoryBurn(bytes32 txHash, address token, address account, uint256 amount) external onlyMiner {
        if (hasVotedFactoryBurn[txHash][msg.sender]) revert AlreadyVoted();
        _applyFactoryBurnVote(msg.sender, txHash, token, account, amount);
    }

    function _applyFactoryBurnVote(
        address miner,
        bytes32 txHash,
        address token,
        address account,
        uint256 amount
    ) internal {
        if (amount == 0) revert InvalidAmount();
        if (account == address(0)) revert InvalidTarget();
        if (!_isCreatedToken[token]) revert TokenNotInList();

        FactoryBurnProposal storage p = factoryBurnProposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();

        if (p.amount == 0) {
            p.token = token;
            p.account = account;
            p.amount = amount;
            p.voteCount = 1;
            emit FactoryBurnProposalCreated(txHash, token, account, amount, miner);
        } else {
            if (p.token != token || p.account != account || p.amount != amount) revert ProposalMismatch();
            p.voteCount++;
        }

        hasVotedFactoryBurn[txHash][miner] = true;
        emit FactoryBurnVoted(txHash, miner, p.voteCount);

        if (p.voteCount >= requiredVotes()) {
            _executeFactoryBurn(txHash);
        }
    }

    function executeFactoryBurn(bytes32 txHash) external {
        _executeFactoryBurn(txHash);
    }

    function _executeFactoryBurn(bytes32 txHash) internal {
        FactoryBurnProposal storage p = factoryBurnProposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.amount == 0) revert ProposalNotExecutable();
        if (p.voteCount < requiredVotes()) revert ProposalNotExecutable();
        if (!_isCreatedToken[p.token]) revert TokenNotInList();

        p.executed = true;
        IBurnableFactoryERC20(p.token).burnFrom(p.account, p.amount);
        emit FactoryBurnExecuted(txHash, p.token, p.account, p.amount);
    }

    // getFactoryBurnProposal 已由 public mapping factoryBurnProposals(txHash) 自动 getter 提供（EIP-170）。

    // ==========================================
    // 跨链桥：B-Unit burn（miner 2/3 → BUnitAirdrop.consumeFromUser）
    // ==========================================

    function voteBUnitBurn(
        bytes32 txHash,
        address user,
        uint256 amount,
        bytes32 peerTxHash,
        uint256 baseGas,
        uint256 kind
    ) external onlyMiner {
        if (hasVotedBUnitBurn[txHash][msg.sender]) revert AlreadyVoted();
        _applyBUnitBurnVote(msg.sender, txHash, user, amount, peerTxHash, baseGas, kind);
    }

    function _applyBUnitBurnVote(
        address miner,
        bytes32 txHash,
        address user,
        uint256 amount,
        bytes32 peerTxHash,
        uint256 baseGas,
        uint256 kind
    ) internal {
        if (user == address(0)) revert InvalidTarget();
        if (amount == 0) revert InvalidAmount();
        if (bunitAirdrop == address(0)) revert BUnitAirdropNotSet();

        BUnitBurnProposal storage p = bunitBurnProposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();

        if (p.voteCount == 0) {
            p.user = user;
            p.amount = amount;
            p.peerTxHash = peerTxHash;
            p.baseGas = baseGas;
            p.kind = kind;
            p.voteCount = 1;
            emit BUnitBurnProposalCreated(txHash, user, amount, peerTxHash, miner);
        } else {
            if (
                p.user != user || p.amount != amount || p.peerTxHash != peerTxHash || p.baseGas != baseGas
                    || p.kind != kind
            ) revert ProposalMismatch();
            p.voteCount++;
        }

        hasVotedBUnitBurn[txHash][miner] = true;
        emit BUnitBurnVoted(txHash, miner, p.voteCount);

        if (p.voteCount >= requiredVotes()) {
            _executeBUnitBurn(txHash);
        }
    }

    function executeBUnitBurn(bytes32 txHash) external {
        _executeBUnitBurn(txHash);
    }

    function _executeBUnitBurn(bytes32 txHash) internal {
        BUnitBurnProposal storage p = bunitBurnProposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.voteCount < requiredVotes()) revert ProposalNotExecutable();
        if (bunitAirdrop == address(0)) revert BUnitAirdropNotSet();

        p.executed = true;
        IBUnitAirdrop(bunitAirdrop).consumeFromUser(p.user, p.amount, p.peerTxHash, p.baseGas, p.kind);
        emit BUnitBurnExecuted(txHash, p.user, p.amount, p.peerTxHash);
    }

    function getBUnitBurnProposal(bytes32 txHash)
        external
        view
        returns (address user, uint256 amount, bytes32 peerTxHash, uint256 baseGas, uint256 kind, uint256 voteCount, bool executed)
    {
        BUnitBurnProposal storage p = bunitBurnProposals[txHash];
        return (p.user, p.amount, p.peerTxHash, p.baseGas, p.kind, p.voteCount, p.executed);
    }

    // ==========================================
    // 跨链桥：GB issue / revoke（miner 2/3 → ConetGB1155）
    // ==========================================

    function voteGBIssue(bytes32 txHash, address to, uint256 amountGB18) external onlyMiner {
        if (hasVotedGBIssue[txHash][msg.sender]) revert AlreadyVoted();
        _applyGBIssueVote(msg.sender, txHash, to, amountGB18);
    }

    function _applyGBIssueVote(address miner, bytes32 txHash, address to, uint256 amountGB18) internal {
        if (to == address(0)) revert InvalidTarget();
        if (amountGB18 == 0) revert InvalidAmount();
        if (conetGB == address(0)) revert ConetGBNotSet();

        GBIssueProposal storage p = gbIssueProposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();

        if (p.voteCount == 0) {
            p.to = to;
            p.amountGB18 = amountGB18;
            p.voteCount = 1;
            emit GBIssueProposalCreated(txHash, to, amountGB18, miner);
        } else {
            if (p.to != to || p.amountGB18 != amountGB18) revert ProposalMismatch();
            p.voteCount++;
        }

        hasVotedGBIssue[txHash][miner] = true;
        emit GBIssueVoted(txHash, miner, p.voteCount);

        if (p.voteCount >= requiredVotes()) {
            _executeGBIssue(txHash);
        }
    }

    function executeGBIssue(bytes32 txHash) external {
        _executeGBIssue(txHash);
    }

    function _executeGBIssue(bytes32 txHash) internal {
        GBIssueProposal storage p = gbIssueProposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.voteCount < requiredVotes()) revert ProposalNotExecutable();
        if (conetGB == address(0)) revert ConetGBNotSet();

        p.executed = true;
        IConetGB1155(conetGB).issueGB(p.to, p.amountGB18);
        emit GBIssueExecuted(txHash, p.to, p.amountGB18);
    }

    function getGBIssueProposal(bytes32 txHash)
        external
        view
        returns (address to, uint256 amountGB18, uint256 voteCount, bool executed)
    {
        GBIssueProposal storage p = gbIssueProposals[txHash];
        return (p.to, p.amountGB18, p.voteCount, p.executed);
    }

    function voteGBRevoke(bytes32 txHash, address from, uint256 amountGB18) external onlyMiner {
        if (hasVotedGBRevoke[txHash][msg.sender]) revert AlreadyVoted();
        _applyGBRevokeVote(msg.sender, txHash, from, amountGB18);
    }

    function _applyGBRevokeVote(address miner, bytes32 txHash, address from, uint256 amountGB18) internal {
        if (from == address(0)) revert InvalidTarget();
        if (amountGB18 == 0) revert InvalidAmount();
        if (conetGB == address(0)) revert ConetGBNotSet();

        GBRevokeProposal storage p = gbRevokeProposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();

        if (p.voteCount == 0) {
            p.from = from;
            p.amountGB18 = amountGB18;
            p.voteCount = 1;
            emit GBRevokeProposalCreated(txHash, from, amountGB18, miner);
        } else {
            if (p.from != from || p.amountGB18 != amountGB18) revert ProposalMismatch();
            p.voteCount++;
        }

        hasVotedGBRevoke[txHash][miner] = true;
        emit GBRevokeVoted(txHash, miner, p.voteCount);

        if (p.voteCount >= requiredVotes()) {
            _executeGBRevoke(txHash);
        }
    }

    function executeGBRevoke(bytes32 txHash) external {
        _executeGBRevoke(txHash);
    }

    function _executeGBRevoke(bytes32 txHash) internal {
        GBRevokeProposal storage p = gbRevokeProposals[txHash];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.voteCount < requiredVotes()) revert ProposalNotExecutable();
        if (conetGB == address(0)) revert ConetGBNotSet();

        p.executed = true;
        IConetGB1155(conetGB).revokeTotalOnly(p.from, p.amountGB18);
        emit GBRevokeExecuted(txHash, p.from, p.amountGB18);
    }

    function getGBRevokeProposal(bytes32 txHash)
        external
        view
        returns (address from, uint256 amountGB18, uint256 voteCount, bool executed)
    {
        GBRevokeProposal storage p = gbRevokeProposals[txHash];
        return (p.from, p.amountGB18, p.voteCount, p.executed);
    }
}
