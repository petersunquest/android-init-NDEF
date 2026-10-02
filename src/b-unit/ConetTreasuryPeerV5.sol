// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PeerV5DeveloperERC20} from "./PeerV5DeveloperERC20.sol";

interface IPeerV5Gb {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function burnFrom(address account, uint256 amount) external;
    function mintPaid(address to, uint256 amount) external;
}

interface IPeerV5UsdcAuth {
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

interface IPeerV5BridgeTreasury {
    function destinationFeeBps(uint256 destinationChainId) external view returns (uint256);
    function initiateBurnRelease(
        address sourceAsset,
        uint256 destinationChainId,
        address destinationAsset,
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        bytes32 sourceTxHash,
        uint256 nonce
    ) external returns (bytes32 operationId);
}

interface IPeerV5Guardians {
    function idOwner(uint256 id) external view returns (address);
}

/**
 * @title ConetTreasuryPeerV5
 * @notice CONET DePIN 按 GB 结算的新国库。Nick CREATE2 同址部署到 CONET 与 Base。
 * @dev 只有 `createERC20` 会 `new`，从而推进本合约 nonce。入金、出金、投票、清算都不创建合约。
 *      规范 USDC 的跨链放币仍由 TreasuryBridgeV3 执行：本合约验签、把 USDC 拉进来，再调用
 *      `initiateBurnRelease`。SI 继续对 V3 `voteBridgeOperation`。
 */
contract ConetTreasuryPeerV5 {
    uint256 public constant CONET_CHAIN_ID = 224422;
    uint256 public constant GB_UNIT = 1e9;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant DEFAULT_VOTER_THRESHOLD = 500 ether;
    /// @dev 与 B-Unit 初始 admin 相同。只负责加 miner 和一次性 configure，不能改汇率。
    address public constant BOOTSTRAP = 0x87cAeD4e51C36a2C2ece3Aaf4ddaC9693d2405E1;

    bytes32 public constant DEPOSIT_GB_TYPEHASH = keccak256(
        "DepositGb(address user,address token,uint256 usdcAmount,uint256 minGb,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant INITIATE_BURN_RELEASE_TYPEHASH = keccak256(
        "InitiateBurnRelease(address user,address sourceAsset,uint256 destinationChainId,address destinationAsset,bytes32 beneficiariesHash,bytes32 sourceTxHash,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    address public gbToken;
    address public canonicalUsdc;
    address public bridgeTreasury;
    address public guardianNodes;
    /// @dev 等于本链 chainId 时才允许 GB 入金、赎回和流量清算。生产配置为 224422。
    uint256 public settlementChainId;
    bool public configured;

    uint256 public usdc6PerFullGb;
    uint256 public voterThreshold = DEFAULT_VOTER_THRESHOLD;
    address[] public voters;
    mapping(address => bool) public isVoter;
    uint256 public voterCount;

    struct Proposal {
        uint8 kind;
        uint256 newValue;
        uint256 yesCount;
        bool opened;
        bool executed;
    }
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    struct DevToken {
        bool exists;
        bool gbBound;
        uint256 tokensPerGb;
    }
    mapping(address => DevToken) public devTokens;
    address[] public createdTokens;

    mapping(address => address) public registeredMiner;
    mapping(address => uint256) public depositNonce;
    mapping(address => uint256) public withdrawNonce;

    address[] public miners;
    mapping(address => bool) public isMiner;

    struct DeveloperBridge {
        address token;
        address recipient;
        uint256 amount;
        uint256 srcChainId;
        uint256 voteCount;
        bool opened;
        bool executed;
    }
    mapping(bytes32 => DeveloperBridge) public developerBridges;
    mapping(bytes32 => mapping(address => bool)) public developerBridgeVoted;
    uint256 public developerBridgeNonce;

    uint256 private _lock = 1;

    struct WithdrawRequest {
        address user;
        uint256 destinationChainId;
        address destinationAsset;
        address[] beneficiaries;
        uint256[] amounts;
        bytes32 sourceTxHash;
        uint256 bridgeNonce;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 authNonce;
        uint256 nonce;
        uint256 deadline;
    }

    event Configured(address gbToken, address canonicalUsdc, address bridgeTreasury, uint256 settlementChainId);
    event MinerAdded(address indexed miner);
    event MinerRemoved(address indexed miner);
    event VoterRegistered(address indexed voter, uint256 voterCount);
    event ProposalOpened(uint256 indexed id, address indexed proposer, uint8 kind, uint256 newValue);
    event ProposalVoted(uint256 indexed id, address indexed voter, uint256 yesCount);
    event ProposalExecuted(uint256 indexed id, uint8 kind, uint256 newValue);
    event DeveloperTokenCreated(address indexed token, bool gbBound, uint256 tokensPerGb);
    event MinerRegistered(address indexed user, uint256 indexed nodeId, address indexed miner);
    event GbDeposited(address indexed user, address indexed token, uint256 usdcAmount, uint256 gbAmount);
    event GbRedeemed(address indexed user, uint256 gbAmount, uint256 usdcAmount);
    event GbSettled(address indexed user, address indexed payer, address indexed miner, uint256 wholeGb);
    event DeveloperTokenSettled(address indexed user, address indexed token, address indexed miner, uint256 wholeGb, uint256 burned);
    event UsdcWithdrawInitiated(address indexed user, bytes32 operationId, uint256 principal, uint256 fee);
    event DeveloperBridgeOut(bytes32 indexed outflowId, address indexed user, address indexed token, address recipient, uint256 amount, uint256 srcChainId, uint256 destChainId);
    event DeveloperBridgeMinted(bytes32 indexed outflowId, address indexed token, address indexed recipient, uint256 amount);

    error NotBootstrap();
    error NotMiner();
    error NotConfigured();
    error WrongChain();
    error ZeroAddress();
    error InvalidAmount();
    error AlreadyConfigured();
    error AlreadyRegistered();
    error BelowThreshold();
    error NotVoter();
    error BadProposal();
    error AlreadyVoted();
    error TransfersDisabled();
    error NotGbBound();
    error NotBridgeable();
    error Slippage();
    error SignatureExpired();
    error InvalidSignature();
    error BadNonce();
    error NotRegisteredMiner();
    error NodeNotFound();
    error TransferFailed();
    error Reentered();
    error LengthMismatch();
    error ProposalMismatch();

    modifier onlyBootstrap() {
        if (msg.sender != BOOTSTRAP) revert NotBootstrap();
        _;
    }

    modifier onlyMiner() {
        if (!isMiner[msg.sender]) revert NotMiner();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentered();
        _lock = 2;
        _;
        _lock = 1;
    }

    function minerCount() external view returns (uint256) { return miners.length; }
    function createdTokenCount() external view returns (uint256) { return createdTokens.length; }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(
            EIP712_DOMAIN_TYPEHASH,
            keccak256(bytes("ConetTreasuryPeerV5")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }

    function configure(
        address gbToken_,
        address canonicalUsdc_,
        address bridgeTreasury_,
        address guardianNodes_,
        uint256 settlementChainId_
    ) external onlyBootstrap {
        if (configured) revert AlreadyConfigured();
        if (bridgeTreasury_ == address(0) || settlementChainId_ == 0) revert ZeroAddress();
        if (block.chainid == settlementChainId_) {
            if (gbToken_ == address(0) || canonicalUsdc_ == address(0) || guardianNodes_ == address(0)) {
                revert ZeroAddress();
            }
        }
        gbToken = gbToken_;
        canonicalUsdc = canonicalUsdc_;
        bridgeTreasury = bridgeTreasury_;
        guardianNodes = guardianNodes_;
        settlementChainId = settlementChainId_;
        configured = true;
        emit Configured(gbToken_, canonicalUsdc_, bridgeTreasury_, settlementChainId_);
    }

    function addMiner(address miner) external onlyBootstrap {
        if (miner == address(0)) revert ZeroAddress();
        if (isMiner[miner]) revert AlreadyRegistered();
        isMiner[miner] = true;
        miners.push(miner);
        emit MinerAdded(miner);
    }

    function removeMiner(address miner) external onlyBootstrap {
        if (!isMiner[miner]) revert NotMiner();
        isMiner[miner] = false;
        uint256 n = miners.length;
        for (uint256 i = 0; i < n; i++) {
            if (miners[i] == miner) {
                miners[i] = miners[n - 1];
                miners.pop();
                break;
            }
        }
        emit MinerRemoved(miner);
    }

    function registerVoter() external {
        if (isVoter[msg.sender]) revert AlreadyRegistered();
        if (msg.sender.balance < voterThreshold) revert BelowThreshold();
        isVoter[msg.sender] = true;
        voters.push(msg.sender);
        voterCount = voters.length;
        emit VoterRegistered(msg.sender, voterCount);
    }

    /// @notice kind 1 = 修改 1 GB 的 USDC 价格（6 位小数）；kind 2 = 修改持有门槛（wei）。
    function propose(uint8 kind, uint256 newValue) external returns (uint256 id) {
        if (!isVoter[msg.sender] || msg.sender.balance < voterThreshold) revert NotVoter();
        if ((kind != 1 && kind != 2) || newValue == 0) revert BadProposal();
        id = ++proposalCount;
        proposals[id] = Proposal({kind: kind, newValue: newValue, yesCount: 0, opened: true, executed: false});
        emit ProposalOpened(id, msg.sender, kind, newValue);
    }

    function vote(uint256 id) external {
        Proposal storage p = proposals[id];
        if (!p.opened || p.executed) revert BadProposal();
        if (!isVoter[msg.sender] || msg.sender.balance < voterThreshold) revert NotVoter();
        if (hasVoted[id][msg.sender]) revert AlreadyVoted();
        hasVoted[id][msg.sender] = true;
        uint256 yes = ++p.yesCount;
        emit ProposalVoted(id, msg.sender, yes);
        if (yes * 3 > voterCount * 2) {
            p.executed = true;
            if (p.kind == 1) usdc6PerFullGb = p.newValue;
            else voterThreshold = p.newValue;
            emit ProposalExecuted(id, p.kind, p.newValue);
        }
    }

    function createERC20(
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_,
        bool gbBound,
        uint256 tokensPerGb
    ) external onlyMiner returns (address token) {
        if (!configured) revert NotConfigured();
        if (gbBound) {
            if (tokensPerGb == 0) revert InvalidAmount();
        } else if (tokensPerGb != 0) {
            revert InvalidAmount();
        }
        PeerV5DeveloperERC20 created = new PeerV5DeveloperERC20(name_, symbol_, decimals_, address(this), gbBound);
        token = address(created);
        devTokens[token] = DevToken({exists: true, gbBound: gbBound, tokensPerGb: tokensPerGb});
        createdTokens.push(token);
        emit DeveloperTokenCreated(token, gbBound, tokensPerGb);
    }

    function mintDeveloper(address token, address to, uint256 amount) external onlyMiner {
        DevToken memory d = devTokens[token];
        if (!d.exists || to == address(0) || amount == 0) revert InvalidAmount();
        PeerV5DeveloperERC20(token).mint(to, amount);
    }

    function registerMiner(uint256 nodeId) external {
        if (!configured) revert NotConfigured();
        address miner = IPeerV5Guardians(guardianNodes).idOwner(nodeId);
        if (miner == address(0)) revert NodeNotFound();
        registeredMiner[msg.sender] = miner;
        emit MinerRegistered(msg.sender, nodeId, miner);
    }

    function quoteGb(uint256 usdcAmount) public view returns (uint256 gbAmount) {
        if (usdc6PerFullGb == 0) return 0;
        return usdcAmount * GB_UNIT / usdc6PerFullGb;
    }

    function quoteUsdc(uint256 gbAmount) public view returns (uint256 usdcAmount) {
        return gbAmount * usdc6PerFullGb / GB_UNIT;
    }

    function depositGbWithSignature(
        address user,
        address token,
        uint256 usdcAmount,
        uint256 minGb,
        uint256 nonce,
        uint256 deadline,
        bytes calldata treasurySig,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 authNonce,
        bytes calldata transferSig
    ) external nonReentrant {
        _onlySettlement();
        DevToken memory d = devTokens[token];
        if (!d.exists || !d.gbBound) revert NotGbBound();
        if (block.timestamp > deadline) revert SignatureExpired();
        if (nonce != depositNonce[user]) revert BadNonce();
        if (usdcAmount == 0 || usdc6PerFullGb == 0) revert InvalidAmount();
        bytes32 structHash = keccak256(abi.encode(
            DEPOSIT_GB_TYPEHASH, user, token, usdcAmount, minGb, nonce, deadline
        ));
        address signer = ECDSA.recover(MessageHashUtils.toTypedDataHash(domainSeparator(), structHash), treasurySig);
        if (signer != user) revert InvalidSignature();
        uint256 gbOut = quoteGb(usdcAmount);
        if (gbOut < minGb) revert Slippage();
        depositNonce[user] = nonce + 1;
        IPeerV5UsdcAuth(canonicalUsdc).transferWithAuthorization(
            user, address(this), usdcAmount, validAfter, validBefore, authNonce, transferSig
        );
        IPeerV5Gb(gbToken).mintPaid(token, gbOut);
        emit GbDeposited(user, token, usdcAmount, gbOut);
    }

    function redeemGb(uint256 gbAmount) external nonReentrant {
        _onlySettlement();
        if (gbAmount == 0 || usdc6PerFullGb == 0) revert InvalidAmount();
        uint256 usdcOut = quoteUsdc(gbAmount);
        if (usdcOut == 0) revert InvalidAmount();
        IPeerV5Gb(gbToken).burnFrom(msg.sender, gbAmount);
        if (!IERC20(canonicalUsdc).transfer(msg.sender, usdcOut)) revert TransferFailed();
        emit GbRedeemed(msg.sender, gbAmount, usdcOut);
    }

    function settleGb(address payer, uint256 wholeGb) external nonReentrant {
        _settleGb(payer, payer, wholeGb);
    }

    function settleSponsorGb(address user, address sponsor, uint256 wholeGb) external nonReentrant {
        _settleGb(user, sponsor, wholeGb);
    }

    function settleDeveloperToken(address user, address token, uint256 wholeGb) external nonReentrant {
        _onlySettlement();
        DevToken memory d = devTokens[token];
        if (!d.exists || !d.gbBound) revert NotGbBound();
        address miner = _minerFor(user);
        uint256 burned = d.tokensPerGb * wholeGb;
        PeerV5DeveloperERC20(token).burnFrom(user, burned);
        PeerV5DeveloperERC20(token).releaseGb(gbToken, miner, wholeGb * GB_UNIT);
        emit DeveloperTokenSettled(user, token, miner, wholeGb, burned);
    }

    function withdrawUsdcWithSignature(WithdrawRequest calldata req, bytes calldata transferSig, bytes calldata treasurySig)
        external
        nonReentrant
        returns (bytes32 operationId)
    {
        _onlySettlement();
        if (block.timestamp > req.deadline) revert SignatureExpired();
        if (req.nonce != withdrawNonce[req.user]) revert BadNonce();
        if (req.user == address(0) || req.destinationAsset == address(0)) revert ZeroAddress();
        uint256 principal = _sum(req.beneficiaries, req.amounts);
        uint256 feeBps = IPeerV5BridgeTreasury(bridgeTreasury).destinationFeeBps(req.destinationChainId);
        uint256 fee = principal * feeBps / BPS_DENOMINATOR;
        bytes32 beneficiariesHash = keccak256(abi.encode(req.beneficiaries, req.amounts));
        bytes32 structHash = keccak256(abi.encode(
            INITIATE_BURN_RELEASE_TYPEHASH,
            req.user,
            canonicalUsdc,
            req.destinationChainId,
            req.destinationAsset,
            beneficiariesHash,
            req.sourceTxHash,
            req.nonce,
            req.deadline
        ));
        address signer = ECDSA.recover(MessageHashUtils.toTypedDataHash(domainSeparator(), structHash), treasurySig);
        if (signer != req.user) revert InvalidSignature();
        withdrawNonce[req.user] = req.nonce + 1;
        IPeerV5UsdcAuth(canonicalUsdc).transferWithAuthorization(
            req.user, address(this), principal + fee, req.validAfter, req.validBefore, req.authNonce, transferSig
        );
        if (fee > 0) {
            if (!IERC20(canonicalUsdc).approve(bridgeTreasury, fee)) revert TransferFailed();
        }
        operationId = IPeerV5BridgeTreasury(bridgeTreasury).initiateBurnRelease(
            canonicalUsdc,
            req.destinationChainId,
            req.destinationAsset,
            req.beneficiaries,
            req.amounts,
            req.sourceTxHash,
            req.bridgeNonce
        );
        emit UsdcWithdrawInitiated(req.user, operationId, principal, fee);
    }

    function bridgeDeveloper(address token, uint256 amount, uint256 destChainId, address recipient)
        external
        returns (bytes32 outflowId)
    {
        DevToken memory d = devTokens[token];
        if (!d.exists || d.gbBound) revert NotBridgeable();
        if (amount == 0 || recipient == address(0) || destChainId == block.chainid) revert InvalidAmount();
        PeerV5DeveloperERC20(token).burnFrom(msg.sender, amount);
        outflowId = keccak256(abi.encode(
            address(this), msg.sender, token, recipient, amount, destChainId, ++developerBridgeNonce
        ));
        emit DeveloperBridgeOut(outflowId, msg.sender, token, recipient, amount, block.chainid, destChainId);
    }

    function voteMintDeveloper(
        bytes32 outflowId,
        uint256 srcChainId,
        address token,
        address recipient,
        uint256 amount
    ) external onlyMiner {
        DevToken memory d = devTokens[token];
        if (!d.exists || d.gbBound) revert NotBridgeable();
        if (srcChainId == block.chainid || amount == 0 || recipient == address(0)) revert InvalidAmount();
        if (developerBridgeVoted[outflowId][msg.sender]) revert AlreadyVoted();
        DeveloperBridge storage b = developerBridges[outflowId];
        if (b.executed) revert BadProposal();
        if (!b.opened) {
            b.token = token;
            b.recipient = recipient;
            b.amount = amount;
            b.srcChainId = srcChainId;
            b.opened = true;
        } else if (b.token != token || b.recipient != recipient || b.amount != amount || b.srcChainId != srcChainId) {
            revert ProposalMismatch();
        }
        developerBridgeVoted[outflowId][msg.sender] = true;
        uint256 votes = ++b.voteCount;
        if (votes >= _requiredVotes()) {
            b.executed = true;
            PeerV5DeveloperERC20(token).mint(recipient, amount);
            emit DeveloperBridgeMinted(outflowId, token, recipient, amount);
        }
    }

    function requiredDeveloperVotes() external view returns (uint256) {
        return _requiredVotes();
    }

    function _settleGb(address user, address payer, uint256 wholeGb) internal {
        _onlySettlement();
        address miner = _minerFor(user);
        if (wholeGb == 0) revert InvalidAmount();
        if (!IPeerV5Gb(gbToken).transferFrom(payer, miner, wholeGb * GB_UNIT)) revert TransferFailed();
        emit GbSettled(user, payer, miner, wholeGb);
    }

    function _minerFor(address user) internal view returns (address miner) {
        miner = registeredMiner[user];
        if (miner == address(0) || msg.sender != miner) revert NotRegisteredMiner();
    }

    function _onlySettlement() internal view {
        if (!configured) revert NotConfigured();
        if (block.chainid != settlementChainId) revert WrongChain();
    }

    function _requiredVotes() internal view returns (uint256) {
        uint256 n = miners.length;
        if (n == 0) revert NotMiner();
        return (n * 2 + 2) / 3;
    }

    function _sum(address[] calldata beneficiaries, uint256[] calldata amounts) internal pure returns (uint256 total) {
        if (beneficiaries.length == 0 || beneficiaries.length != amounts.length) revert LengthMismatch();
        for (uint256 i = 0; i < amounts.length; i++) {
            if (beneficiaries[i] == address(0) || amounts[i] == 0) revert InvalidAmount();
            total += amounts[i];
        }
    }
}
