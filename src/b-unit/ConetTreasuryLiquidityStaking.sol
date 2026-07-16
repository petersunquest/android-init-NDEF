// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IConetTreasuryLiquidityGateway {
    function isCreatedToken(address token) external view returns (bool);
    function burnFactoryFromLiquidityStaking(address token, address account, uint256 amount) external;
    function mintFactoryTokenLiquidityStaking(address token, address to, uint256 amount) external;
}

/**
 * @title ConetTreasuryLiquidityStaking
 * @notice CoNET-side timed liquidity staking for Treasury-created ERC20s.
 *
 * The staked amount is burned by ConetTreasury. Principal and block-based
 * rewards are minted back by the same Treasury gateway when claimed or
 * redeemed. Rates are snapshotted per position, so a later governance vote
 * cannot rewrite an existing user's economics.
 */
contract ConetTreasuryLiquidityStaking is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_ANNUAL_RATE_BPS = 10_000; // 100% APY safety cap
    uint256 public constant MAX_EARLY_EXIT_PENALTY_BPS = 5_000; // 50%
    uint256 public constant DEFAULT_BLOCKS_PER_YEAR = 2_365_000;

    uint64 public constant TERM_1_MONTH = 30 days;
    uint64 public constant TERM_3_MONTHS = 90 days;
    uint64 public constant TERM_6_MONTHS = 180 days;
    uint64 public constant TERM_1_YEAR = 365 days;

    struct RateConfig {
        uint256 annualRateBps;
        uint256 earlyExitPenaltyBps;
        bool configured;
    }

    struct RateProposal {
        uint256 chainId;
        address token;
        uint64 termSeconds;
        uint256 annualRateBps;
        uint256 earlyExitPenaltyBps;
        uint256 voteCount;
        bool executed;
    }

    struct StakePosition {
        address owner;
        address token;
        uint256 chainId;
        uint256 principal;
        uint64 termSeconds;
        uint256 startBlock;
        uint256 lastClaimBlock;
        uint256 maturityBlock;
        uint256 annualRateBps;
        uint256 earlyExitPenaltyBps;
        uint256 blocksPerYear;
        uint256 claimedReward;
        bool active;
    }

    address public treasury;
    uint256 public blocksPerYear;
    mapping(address => bool) public governanceEoas;
    uint256 public governanceEoaCount;
    mapping(bytes32 => RateConfig) private _rates;
    mapping(bytes32 => RateProposal) private _rateProposals;
    mapping(bytes32 => mapping(address => bool)) private _rateProposalVoted;
    mapping(uint256 => StakePosition) private _positions;
    mapping(address => uint256[]) private _positionsByOwner;
    mapping(bytes32 => uint256) public totalPrincipalByChainAndToken;
    uint256 public nextPositionId;

    event GovernanceEoaUpdated(address indexed account, bool enabled);
    event RateProposalCreated(
        bytes32 indexed proposalId,
        uint256 indexed chainId,
        address indexed token,
        uint64 termSeconds,
        uint256 annualRateBps,
        uint256 earlyExitPenaltyBps
    );
    event RateProposalVoted(bytes32 indexed proposalId, address indexed governanceEoa, uint256 voteCount);
    event RateUpdated(
        bytes32 indexed proposalId,
        uint256 indexed chainId,
        address indexed token,
        uint64 termSeconds,
        uint256 annualRateBps,
        uint256 earlyExitPenaltyBps
    );
    event LiquidityStaked(
        uint256 indexed positionId,
        address indexed owner,
        uint256 indexed chainId,
        address token,
        uint256 principal,
        uint64 termSeconds,
        uint256 maturityBlock,
        uint256 annualRateBps,
        uint256 earlyExitPenaltyBps
    );
    event RewardClaimed(uint256 indexed positionId, address indexed owner, uint256 amount, uint256 throughBlock);
    event LiquidityRedeemed(
        uint256 indexed positionId,
        address indexed owner,
        uint256 principalMinted,
        uint256 rewardMinted,
        uint256 penaltyAmount,
        bool early
    );

    error InvalidAddress();
    error InvalidAmount();
    error InvalidTerm();
    error InvalidRate();
    error InvalidPenalty();
    error NotGovernanceEoa();
    error AlreadyVoted();
    error ProposalMismatch();
    error ProposalNotExecutable();
    error ProposalAlreadyExecuted();
    error RateNotConfigured();
    error PositionNotFound();
    error NotPositionOwner();
    error PositionAlreadyRedeemed();
    error NoReward();
    error NotTreasury();

    modifier onlyGovernanceEoa() {
        if (!governanceEoas[msg.sender]) revert NotGovernanceEoa();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address treasury_, address[] calldata governanceAccounts)
        external
        initializer
    {
        if (owner_ == address(0) || treasury_ == address(0)) revert InvalidAddress();
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        treasury = treasury_;
        blocksPerYear = DEFAULT_BLOCKS_PER_YEAR;
        for (uint256 i = 0; i < governanceAccounts.length; i++) {
            _setGovernanceEoa(governanceAccounts[i], true);
        }
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert InvalidAddress();
        treasury = treasury_;
    }

    function setBlocksPerYear(uint256 blocksPerYear_) external onlyOwner {
        if (blocksPerYear_ == 0) revert InvalidAmount();
        blocksPerYear = blocksPerYear_;
    }

    function setGovernanceEoa(address account, bool enabled) external onlyOwner {
        _setGovernanceEoa(account, enabled);
    }

    function _setGovernanceEoa(address account, bool enabled) internal {
        if (account == address(0)) revert InvalidAddress();
        if (governanceEoas[account] == enabled) return;
        governanceEoas[account] = enabled;
        if (enabled) governanceEoaCount++;
        else governanceEoaCount--;
        emit GovernanceEoaUpdated(account, enabled);
    }

    function governanceRequiredVotes() public view returns (uint256) {
        if (governanceEoaCount == 0) return 0;
        return (governanceEoaCount * 2 + 2) / 3;
    }

    function rateKey(uint256 chainId, address token, uint64 termSeconds) public pure returns (bytes32) {
        return keccak256(abi.encode(chainId, token, termSeconds));
    }

    function rateConfig(uint256 chainId, address token, uint64 termSeconds)
        external
        view
        returns (RateConfig memory)
    {
        return _rates[rateKey(chainId, token, termSeconds)];
    }

    function proposeRate(
        uint256 chainId,
        address token,
        uint64 termSeconds,
        uint256 annualRateBps,
        uint256 earlyExitPenaltyBps
    ) external onlyGovernanceEoa returns (bytes32 proposalId) {
        _validateRate(token, termSeconds, annualRateBps, earlyExitPenaltyBps);
        proposalId = keccak256(
            abi.encode(chainId, token, termSeconds, annualRateBps, earlyExitPenaltyBps, block.number)
        );
        RateProposal storage proposal = _rateProposals[proposalId];
        proposal.chainId = chainId;
        proposal.token = token;
        proposal.termSeconds = termSeconds;
        proposal.annualRateBps = annualRateBps;
        proposal.earlyExitPenaltyBps = earlyExitPenaltyBps;
        proposal.voteCount = 1;
        _rateProposalVoted[proposalId][msg.sender] = true;
        emit RateProposalCreated(
            proposalId, chainId, token, termSeconds, annualRateBps, earlyExitPenaltyBps
        );
        emit RateProposalVoted(proposalId, msg.sender, 1);
        if (proposal.voteCount >= governanceRequiredVotes()) {
            _executeRateProposal(proposalId);
        }
    }

    function voteRate(
        bytes32 proposalId,
        uint256 chainId,
        address token,
        uint64 termSeconds,
        uint256 annualRateBps,
        uint256 earlyExitPenaltyBps
    ) external onlyGovernanceEoa {
        RateProposal storage proposal = _rateProposals[proposalId];
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (_rateProposalVoted[proposalId][msg.sender]) revert AlreadyVoted();
        if (
            proposal.chainId != chainId || proposal.token != token || proposal.termSeconds != termSeconds
                || proposal.annualRateBps != annualRateBps
                || proposal.earlyExitPenaltyBps != earlyExitPenaltyBps
        ) revert ProposalMismatch();
        _rateProposalVoted[proposalId][msg.sender] = true;
        proposal.voteCount++;
        emit RateProposalVoted(proposalId, msg.sender, proposal.voteCount);
        if (proposal.voteCount >= governanceRequiredVotes()) {
            _executeRateProposal(proposalId);
        }
    }

    function executeRateProposal(bytes32 proposalId) external {
        _executeRateProposal(proposalId);
    }

    function _executeRateProposal(bytes32 proposalId) internal {
        RateProposal storage proposal = _rateProposals[proposalId];
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.voteCount < governanceRequiredVotes()) revert ProposalNotExecutable();
        proposal.executed = true;
        _rates[rateKey(proposal.chainId, proposal.token, proposal.termSeconds)] = RateConfig({
            annualRateBps: proposal.annualRateBps,
            earlyExitPenaltyBps: proposal.earlyExitPenaltyBps,
            configured: true
        });
        emit RateUpdated(
            proposalId,
            proposal.chainId,
            proposal.token,
            proposal.termSeconds,
            proposal.annualRateBps,
            proposal.earlyExitPenaltyBps
        );
    }

    function stake(address token, uint256 chainId, uint64 termSeconds, uint256 amount)
        external
        nonReentrant
        returns (uint256 positionId)
    {
        if (amount == 0) revert InvalidAmount();
        if (!IConetTreasuryLiquidityGateway(treasury).isCreatedToken(token)) revert InvalidAddress();
        RateConfig memory config = _rates[rateKey(chainId, token, termSeconds)];
        if (!config.configured) revert RateNotConfigured();

        IConetTreasuryLiquidityGateway(treasury).burnFactoryFromLiquidityStaking(
            token, msg.sender, amount
        );

        positionId = ++nextPositionId;
        uint256 maturityBlock = block.number + _termBlocks(termSeconds, blocksPerYear);
        _positions[positionId] = StakePosition({
            owner: msg.sender,
            token: token,
            chainId: chainId,
            principal: amount,
            termSeconds: termSeconds,
            startBlock: block.number,
            lastClaimBlock: block.number,
            maturityBlock: maturityBlock,
            annualRateBps: config.annualRateBps,
            earlyExitPenaltyBps: config.earlyExitPenaltyBps,
            blocksPerYear: blocksPerYear,
            claimedReward: 0,
            active: true
        });
        _positionsByOwner[msg.sender].push(positionId);
        totalPrincipalByChainAndToken[keccak256(abi.encode(chainId, token))] += amount;
        emit LiquidityStaked(
            positionId,
            msg.sender,
            chainId,
            token,
            amount,
            termSeconds,
            maturityBlock,
            config.annualRateBps,
            config.earlyExitPenaltyBps
        );
    }

    function pendingReward(uint256 positionId) public view returns (uint256) {
        StakePosition memory position = _positions[positionId];
        if (!position.active) return 0;
        uint256 throughBlock = block.number < position.maturityBlock ? block.number : position.maturityBlock;
        if (throughBlock <= position.lastClaimBlock) return 0;
        return _rewardFor(
            position.principal,
            position.annualRateBps,
            throughBlock - position.lastClaimBlock,
            position.blocksPerYear
        );
    }

    function claimReward(uint256 positionId) external nonReentrant returns (uint256 reward) {
        StakePosition storage position = _positions[positionId];
        _requirePositionOwner(position);
        reward = pendingReward(positionId);
        if (reward == 0) revert NoReward();
        uint256 throughBlock = block.number < position.maturityBlock ? block.number : position.maturityBlock;
        position.lastClaimBlock = throughBlock;
        position.claimedReward += reward;
        IConetTreasuryLiquidityGateway(treasury).mintFactoryTokenLiquidityStaking(
            position.token, position.owner, reward
        );
        emit RewardClaimed(positionId, position.owner, reward, throughBlock);
    }

    function redeem(uint256 positionId) external nonReentrant returns (uint256 principalMinted, uint256 rewardMinted) {
        StakePosition storage position = _positions[positionId];
        _requirePositionOwner(position);
        bool early = block.number < position.maturityBlock;
        rewardMinted = pendingReward(positionId);
        uint256 penaltyAmount = early
            ? (position.principal * position.earlyExitPenaltyBps) / BPS_DENOMINATOR
            : 0;
        principalMinted = position.principal - penaltyAmount;
        position.active = false;
        totalPrincipalByChainAndToken[keccak256(abi.encode(position.chainId, position.token))] -= position.principal;
        IConetTreasuryLiquidityGateway(treasury).mintFactoryTokenLiquidityStaking(
            position.token, position.owner, principalMinted + rewardMinted
        );
        emit LiquidityRedeemed(
            positionId, position.owner, principalMinted, rewardMinted, penaltyAmount, early
        );
    }

    function getPosition(uint256 positionId) external view returns (StakePosition memory) {
        StakePosition memory position = _positions[positionId];
        if (position.owner == address(0)) revert PositionNotFound();
        return position;
    }

    function getPositionIds(address owner_) external view returns (uint256[] memory) {
        return _positionsByOwner[owner_];
    }

    function getPositions(address owner_, uint256 offset, uint256 limit)
        external
        view
        returns (StakePosition[] memory positions, uint256 total)
    {
        uint256[] storage ids = _positionsByOwner[owner_];
        total = ids.length;
        if (offset >= total || limit == 0) return (new StakePosition[](0), total);
        uint256 end = offset + limit;
        if (end > total) end = total;
        positions = new StakePosition[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            positions[i - offset] = _positions[ids[i]];
        }
    }

    function _requirePositionOwner(StakePosition storage position) internal view {
        if (position.owner == address(0)) revert PositionNotFound();
        if (position.owner != msg.sender) revert NotPositionOwner();
        if (!position.active) revert PositionAlreadyRedeemed();
    }

    function _validateRate(address token, uint64 termSeconds, uint256 annualRateBps, uint256 penaltyBps)
        internal
        view
    {
        if (!IConetTreasuryLiquidityGateway(treasury).isCreatedToken(token)) revert InvalidAddress();
        if (!_isSupportedTerm(termSeconds)) revert InvalidTerm();
        if (annualRateBps == 0 || annualRateBps > MAX_ANNUAL_RATE_BPS) revert InvalidRate();
        if (penaltyBps > MAX_EARLY_EXIT_PENALTY_BPS) revert InvalidPenalty();
    }

    function _isSupportedTerm(uint64 termSeconds) internal pure returns (bool) {
        return termSeconds == TERM_1_MONTH || termSeconds == TERM_3_MONTHS
            || termSeconds == TERM_6_MONTHS || termSeconds == TERM_1_YEAR;
    }

    function _termBlocks(uint64 termSeconds, uint256 blocksPerYear_)
        internal
        pure
        returns (uint256)
    {
        return (uint256(termSeconds) * blocksPerYear_) / uint64(365 days);
    }

    function _rewardFor(
        uint256 principal,
        uint256 annualRateBps,
        uint256 elapsedBlocks,
        uint256 blocksPerYear_
    )
        internal
        pure
        returns (uint256)
    {
        return (principal * annualRateBps * elapsedBlocks) / (blocksPerYear_ * BPS_DENOMINATOR);
    }

    uint256[40] private __gap;
}
