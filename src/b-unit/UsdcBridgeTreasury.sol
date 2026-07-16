// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IUsdcBridgeMinerRegistry {
    function isMiner(address account) external view returns (bool);
    function minerCount() external view returns (uint256);
}

interface IConetTreasuryTokenRegistry {
    function isCreatedToken(address token) external view returns (bool);
}

interface IConetTreasuryAssetFactory {
    function createERC20FromBridge(
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_,
        address baseToken,
        bytes32 salt
    ) external returns (address token);
}

interface IUsdcBridgeMintable {
    function mint(address to, uint256 amount) external;
}

interface IUsdcBridgeBurnable {
    function burnFrom(address account, uint256 amount) external;
}

/**
 * @title UsdcBridgeTreasury
 * @notice Asymmetric Base ↔ CoNET USDC custody bridge.
 *
 * Base locks Circle USDC and CoNET mints conet-USDC after independent miner
 * attestations. CoNET burns conet-USDC and Base releases Circle USDC after
 * independent miner attestations. The same UUPS proxy init code can be
 * deployed with Nick CREATE2 on both chains; chain-specific token addresses
 * are configured after deployment because storage is independent per chain.
 */
contract UsdcBridgeTreasury is
    Initializable,
    OwnableUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 public constant BASE_CHAIN_ID = 8453;
    uint256 public constant CONET_CHAIN_ID = 224422;
    uint8 public constant DIRECTION_BASE_TO_CONET = 1;
    uint8 public constant DIRECTION_CONET_TO_BASE = 2;
    uint8 public constant DIRECTION_CONET_NATIVE_TO_BASE = 3;
    uint8 public constant DIRECTION_BASE_WCNET_TO_CONET = 4;
    uint8 public constant DIRECTION_GENERIC_BURN_TO_MINT = 5;
    uint256 public constant EXIT_FEE_BPS = 100; // 1%
    uint256 public constant MAX_EXIT_FEE_BPS = 1_000; // 10% governance safety cap
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint8 public constant LEDGER_OUTBOUND = 1;
    uint8 public constant LEDGER_INBOUND = 2;

    bytes32 private constant BRIDGE_ATTESTATION_TYPEHASH = keccak256(
        "BridgeAttestation(address bridgeAddress,uint256 sourceChainId,uint256 destinationChainId,uint8 direction,bytes32 sourceTxHash,bytes32 operationId,address token,address recipient,uint256 grossAmount,uint256 netAmount,uint256 feeAmount,uint256 sourceBlockNumber,uint256 deadline)"
    );

    address public minerRegistry;
    address public baseUsdc;
    address public conetUsdc;
    address public wcnet;
    address public conetTreasuryTokenRegistry;
    uint256 public quorum;
    uint256 public configurationVersion;

    mapping(bytes32 => bool) public initiated;
    mapping(bytes32 => bool) public executed;
    mapping(uint256 => uint256) public exitFeeBpsByDestinationChain;
    mapping(uint256 => bool) public exitFeeRateConfigured;
    mapping(uint256 => uint256) public exitFeeProposalNonce;

    struct ExitFeeRateProposal {
        uint256 destinationChainId;
        uint256 newFeeBps;
        uint256 voteCount;
        bool executed;
    }

    mapping(bytes32 => ExitFeeRateProposal) private _exitFeeRateProposals;
    mapping(bytes32 => mapping(address => bool)) private _exitFeeRateVoted;

    mapping(address => bool) public governanceEoas;
    uint256 public governanceEoaCount;

    struct AssetRouteApplication {
        address applicant;
        address baseToken;
        string name;
        string symbol;
        uint8 decimals;
        bytes32 salt;
        uint256 voteCount;
        bool approved;
    }

    mapping(bytes32 => AssetRouteApplication) private _assetApplications;
    mapping(bytes32 => mapping(address => bool)) private _assetApplicationVoted;

    struct AssetDeploymentProposal {
        address baseToken;
        string name;
        string symbol;
        uint8 decimals;
        bytes32 salt;
        bytes32 baseApprovalTxHash;
        uint256 voteCount;
        bool executed;
        address conetToken;
    }

    mapping(bytes32 => AssetDeploymentProposal) private _assetDeploymentProposals;
    mapping(bytes32 => mapping(address => bool)) private _assetDeploymentVoted;

    struct MintBurnAssetRoute {
        address localToken;
        address peerToken;
        bool sourceCanBurn;
        bool enabled;
    }

    mapping(uint256 => mapping(address => MintBurnAssetRoute)) private _mintBurnAssetRoutes;

    struct Ledger {
        uint256 inboundGross;
        uint256 inboundNet;
        uint256 outboundGross;
        uint256 outboundNet;
        uint256 fees;
        uint256 operations;
    }

    mapping(uint256 => mapping(address => Ledger)) private _peerLedgers;
    mapping(address => Ledger) private _totalLedgers;

    event BridgeConfigured(
        address indexed minerRegistry,
        address indexed baseUsdc,
        address indexed conetUsdc,
        address wcnet,
        uint256 quorum,
        uint256 configurationVersion
    );
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);
    event ExitFeeRateVote(
        bytes32 indexed proposalId,
        uint256 indexed destinationChainId,
        uint256 newFeeBps,
        address indexed miner,
        uint256 voteCount
    );
    event ExitFeeRateUpdated(
        bytes32 indexed proposalId,
        uint256 indexed destinationChainId,
        uint256 oldFeeBps,
        uint256 newFeeBps,
        uint256 signerCount
    );
    event MintBurnAssetRouteConfigured(
        uint256 indexed peerChainId,
        address indexed localToken,
        address indexed peerToken,
        bool sourceCanBurn,
        bool enabled
    );
    event LockMintAssetRouteConfigured(
        uint256 indexed peerChainId,
        address indexed lockedToken,
        address indexed wrappedToken,
        bool enabled
    );
    event AssetRouteApplicationSubmitted(
        bytes32 indexed applicationId,
        address indexed applicant,
        address indexed baseToken,
        string name,
        string symbol,
        uint8 decimals,
        bytes32 salt
    );
    event AssetRouteApplicationVoted(
        bytes32 indexed applicationId,
        address indexed governanceEoa,
        uint256 voteCount
    );
    event AssetRouteApplicationApproved(bytes32 indexed applicationId, uint256 voteCount);
    event AssetDeploymentVote(
        bytes32 indexed deploymentId,
        bytes32 indexed applicationId,
        address indexed miner,
        uint256 voteCount
    );
    event AssetDeploymentExecuted(
        bytes32 indexed deploymentId,
        bytes32 indexed applicationId,
        address baseToken,
        address conetToken,
        bytes32 baseApprovalTxHash,
        uint256 voteCount
    );
    event GenericBurnInitiated(
        bytes32 indexed operationId,
        address indexed sender,
        address indexed recipient,
        uint256 sourceChainId,
        uint256 destinationChainId,
        address sourceToken,
        address destinationToken,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount,
        bytes32 paymentRef
    );
    event GenericMintExecuted(
        bytes32 indexed operationId,
        bytes32 indexed sourceTxHash,
        address indexed recipient,
        uint256 sourceChainId,
        address sourceToken,
        address destinationToken,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 signerCount
    );
    event LockedAssetDepositInitiated(
        bytes32 indexed operationId,
        address indexed sender,
        address indexed recipient,
        uint256 sourceChainId,
        uint256 destinationChainId,
        address sourceToken,
        address destinationToken,
        uint256 payoutAmount,
        uint256 feeAmount,
        bytes32 paymentRef
    );
    event LockedAssetMintExecuted(
        bytes32 indexed operationId,
        bytes32 indexed sourceTxHash,
        address indexed recipient,
        uint256 sourceChainId,
        address sourceToken,
        address destinationToken,
        uint256 payoutAmount,
        uint256 feeAmount,
        uint256 signerCount
    );
    event LockedAssetReleaseExecuted(
        bytes32 indexed operationId,
        bytes32 indexed sourceTxHash,
        address indexed recipient,
        uint256 sourceChainId,
        address sourceToken,
        address destinationToken,
        uint256 payoutAmount,
        uint256 feeAmount,
        uint256 signerCount
    );
    event DepositInitiated(
        bytes32 indexed operationId,
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 feeAmount,
        bytes32 paymentRef
    );
    event BurnInitiated(
        bytes32 indexed operationId,
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 feeAmount,
        bytes32 paymentRef
    );
    event NativeDepositInitiated(
        bytes32 indexed operationId,
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 feeAmount,
        bytes32 paymentRef
    );
    event WcnetBurnInitiated(
        bytes32 indexed operationId,
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 feeAmount,
        bytes32 paymentRef
    );
    event MintExecuted(
        bytes32 indexed operationId,
        bytes32 indexed sourceTxHash,
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 signerCount
    );
    event ReleaseExecuted(
        bytes32 indexed operationId,
        bytes32 indexed sourceTxHash,
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 signerCount
    );
    event WcnetMintExecuted(
        bytes32 indexed operationId,
        bytes32 indexed sourceTxHash,
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 signerCount
    );
    event NativeReleaseExecuted(
        bytes32 indexed operationId,
        bytes32 indexed sourceTxHash,
        address indexed recipient,
        uint256 amount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 signerCount
    );

    error WrongChain(uint256 expected, uint256 actual);
    error ZeroAddress();
    error ZeroAmount();
    error InvalidRecipient();
    error InvalidOperation();
    error OperationAlreadyExists(bytes32 operationId);
    error OperationAlreadyExecuted(bytes32 operationId);
    error InvalidSourceTxHash();
    error InvalidDeadline();
    error InvalidAttestation();
    error InvalidSigner(address signer);
    error DuplicateSigner(address signer);
    error InsufficientSignatures(uint256 supplied, uint256 required);
    error InsufficientLiquidity(uint256 available, uint256 required);
    error NativeTransferFailed();
    error UnsupportedToken();
    error InvalidQuorum(uint256 quorum, uint256 minerCount);
    error InvalidDestinationChain();
    error InvalidFeeRate(uint256 feeBps);
    error FeeRateProposalExecuted(bytes32 proposalId);
    error MinerAlreadyVoted(bytes32 proposalId, address miner);
    error AssetRouteUnavailable(uint256 peerChainId, address token);
    error InvalidFeeAmount(uint256 supplied, uint256 expected);
    error ConetTokenNotTreasuryCreated(address token);
    error NotGovernanceEoa();
    error GovernanceAlreadyVoted(bytes32 applicationId, address voter);
    error AssetApplicationNotFound(bytes32 applicationId);
    error AssetApplicationMismatch();
    error AssetDeploymentAlreadyExecuted(bytes32 deploymentId);
    error MinerAlreadyVotedDeployment(bytes32 deploymentId, address miner);
    error InvalidApprovalTxHash();

    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Keep this initializer argument identical on Base and CoNET when
     * building the same CREATE2 proxy init code. Token/miner configuration is
     * deliberately separate and happens after deployment.
     */
    function initialize(address initialOwner, address conetTreasuryTokenRegistry_) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (conetTreasuryTokenRegistry_ == address(0)) revert ZeroAddress();
        conetTreasuryTokenRegistry = conetTreasuryTokenRegistry_;
        __Ownable_init(initialOwner);
        __EIP712_init("Beamio USDC Bridge", "1");
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
    }

    function configure(
        address minerRegistry_,
        address baseUsdc_,
        address conetUsdc_,
        address wcnet_,
        uint256 quorum_
    ) external onlyOwner {
        if (
            minerRegistry_ == address(0)
                || baseUsdc_ == address(0)
                || conetUsdc_ == address(0)
                || wcnet_ == address(0)
        ) {
            revert ZeroAddress();
        }
        uint256 minerTotal = IUsdcBridgeMinerRegistry(minerRegistry_).minerCount();
        if (quorum_ == 0) {
            quorum_ = _defaultQuorum(minerTotal);
        }
        if (quorum_ == 0 || quorum_ > minerTotal) {
            revert InvalidQuorum(quorum_, minerTotal);
        }
        minerRegistry = minerRegistry_;
        baseUsdc = baseUsdc_;
        conetUsdc = conetUsdc_;
        wcnet = wcnet_;
        quorum = quorum_;
        configurationVersion++;
        emit BridgeConfigured(minerRegistry_, baseUsdc_, conetUsdc_, wcnet_, quorum_, configurationVersion);
    }

    function setQuorum(uint256 newQuorum) external onlyOwner {
        uint256 minerTotal = _minerCount();
        if (newQuorum == 0 || newQuorum > minerTotal) {
            revert InvalidQuorum(newQuorum, minerTotal);
        }
        emit QuorumUpdated(quorum, newQuorum);
        quorum = newQuorum;
    }

    function requiredSignatures() public view returns (uint256) {
        if (quorum != 0) return quorum;
        return _defaultQuorum(_minerCount());
    }

    function exitFee(uint256 grossAmount) public pure returns (uint256 feeAmount, uint256 netAmount) {
        return _splitExitFee(EXIT_FEE_BPS, grossAmount);
    }

    function exitFeeForDestination(uint256 destinationChainId, uint256 grossAmount)
        public
        view
        returns (uint256 feeAmount, uint256 netAmount)
    {
        return _splitExitFee(exitFeeBps(destinationChainId), grossAmount);
    }

    function exitFeeBps(uint256 destinationChainId) public view returns (uint256) {
        if (exitFeeRateConfigured[destinationChainId]) {
            return exitFeeBpsByDestinationChain[destinationChainId];
        }
        return EXIT_FEE_BPS;
    }

    function exitFeeRateProposal(bytes32 proposalId)
        external
        view
        returns (ExitFeeRateProposal memory)
    {
        return _exitFeeRateProposals[proposalId];
    }

    function hasVotedExitFeeRate(bytes32 proposalId, address miner) external view returns (bool) {
        return _exitFeeRateVoted[proposalId][miner];
    }

    /**
     * @notice Miner governance for a destination-L1-specific exit fee.
     * The first vote fixes the proposal tuple; subsequent votes must use the
     * same proposalId, destination chain and rate.
     */
    function voteExitFeeRate(
        uint256 destinationChainId,
        uint256 newFeeBps,
        uint256 proposalNonce
    ) external returns (bytes32 proposalId) {
        if (destinationChainId == 0 || destinationChainId == block.chainid) {
            revert InvalidDestinationChain();
        }
        if (newFeeBps > MAX_EXIT_FEE_BPS) revert InvalidFeeRate(newFeeBps);
        if (!IUsdcBridgeMinerRegistry(minerRegistry).isMiner(msg.sender)) {
            revert InvalidSigner(msg.sender);
        }

        proposalId = keccak256(
            abi.encode(address(this), destinationChainId, newFeeBps, proposalNonce)
        );
        ExitFeeRateProposal storage proposal = _exitFeeRateProposals[proposalId];
        if (proposal.executed) revert FeeRateProposalExecuted(proposalId);
        if (proposal.voteCount == 0) {
            proposal.destinationChainId = destinationChainId;
            proposal.newFeeBps = newFeeBps;
        }
        if (_exitFeeRateVoted[proposalId][msg.sender]) {
            revert MinerAlreadyVoted(proposalId, msg.sender);
        }
        _exitFeeRateVoted[proposalId][msg.sender] = true;
        proposal.voteCount++;
        emit ExitFeeRateVote(
            proposalId,
            destinationChainId,
            newFeeBps,
            msg.sender,
            proposal.voteCount
        );

        uint256 required = requiredSignatures();
        if (proposal.voteCount >= required) {
            uint256 oldFeeBps = exitFeeBps(destinationChainId);
            exitFeeBpsByDestinationChain[destinationChainId] = newFeeBps;
            exitFeeRateConfigured[destinationChainId] = true;
            proposal.executed = true;
            emit ExitFeeRateUpdated(
                proposalId,
                destinationChainId,
                oldFeeBps,
                newFeeBps,
                proposal.voteCount
            );
        }
    }

    function _splitExitFee(uint256 feeBps, uint256 grossAmount)
        internal
        pure
        returns (uint256 feeAmount, uint256 netAmount)
    {
        if (grossAmount == 0) revert ZeroAmount();
        feeAmount = (grossAmount * feeBps + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        if (feeAmount >= grossAmount) revert ZeroAmount();
        // The requested payout is minted/released in full. The fee is an
        // additional debit retained by the source treasury.
        netAmount = grossAmount;
    }

    function peerLedger(uint256 peerChainId, address asset)
        external
        view
        returns (Ledger memory)
    {
        return _peerLedgers[peerChainId][asset];
    }

    function totalLedger(address asset) external view returns (Ledger memory) {
        return _totalLedgers[asset];
    }

    function configureMintBurnAssetRoute(
        uint256 peerChainId,
        address localToken,
        address peerToken,
        bool enabled
    ) external onlyOwner {
        if (peerChainId == 0 || peerChainId == block.chainid) {
            revert InvalidDestinationChain();
        }
        if (localToken == address(0) || peerToken == address(0)) revert ZeroAddress();
        if (block.chainid == CONET_CHAIN_ID) _requireConetTreasuryToken(localToken);
        _mintBurnAssetRoutes[peerChainId][localToken] = MintBurnAssetRoute({
            localToken: localToken,
            peerToken: peerToken,
            sourceCanBurn: true,
            enabled: enabled
        });
        emit MintBurnAssetRouteConfigured(peerChainId, localToken, peerToken, true, enabled);
    }

    function configureLockMintAssetRoute(
        uint256 peerChainId,
        address lockedToken,
        address wrappedToken,
        bool enabled
    ) external onlyOwner {
        if (peerChainId == 0 || peerChainId == block.chainid) {
            revert InvalidDestinationChain();
        }
        if (lockedToken == address(0) || wrappedToken == address(0)) revert ZeroAddress();
        if (block.chainid == CONET_CHAIN_ID) _requireConetTreasuryToken(lockedToken);
        _mintBurnAssetRoutes[peerChainId][lockedToken] = MintBurnAssetRoute({
            localToken: lockedToken,
            peerToken: wrappedToken,
            sourceCanBurn: false,
            enabled: enabled
        });
        emit LockMintAssetRouteConfigured(peerChainId, lockedToken, wrappedToken, enabled);
    }

    function mintBurnAssetRoute(uint256 peerChainId, address localToken)
        external
        view
        returns (MintBurnAssetRoute memory)
    {
        return _mintBurnAssetRoutes[peerChainId][localToken];
    }

    function setGovernanceEoa(address account, bool enabled) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (governanceEoas[account] == enabled) return;
        governanceEoas[account] = enabled;
        if (enabled) governanceEoaCount++;
        else governanceEoaCount--;
    }

    function governanceRequiredSignatures() public view returns (uint256) {
        if (governanceEoaCount == 0) return 0;
        return (governanceEoaCount * 2 + 2) / 3;
    }

    function assetRouteApplication(bytes32 applicationId)
        external
        view
        returns (AssetRouteApplication memory)
    {
        return _assetApplications[applicationId];
    }

    function assetDeploymentProposal(bytes32 deploymentId)
        external
        view
        returns (AssetDeploymentProposal memory)
    {
        return _assetDeploymentProposals[deploymentId];
    }

    /**
     * @notice Base-side project application for a CoNET-created wrapped ERC20.
     */
    function submitAssetRouteApplication(
        address baseToken,
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_,
        bytes32 salt,
        uint256 nonce
    ) external returns (bytes32 applicationId) {
        _requireBase();
        if (baseToken == address(0) || bytes(name_).length == 0 || bytes(symbol_).length == 0) {
            revert InvalidOperation();
        }
        applicationId = keccak256(
            abi.encode(
                address(this),
                block.chainid,
                msg.sender,
                baseToken,
                keccak256(bytes(name_)),
                keccak256(bytes(symbol_)),
                decimals_,
                salt,
                nonce
            )
        );
        AssetRouteApplication storage application = _assetApplications[applicationId];
        if (application.applicant != address(0)) revert OperationAlreadyExists(applicationId);
        application.applicant = msg.sender;
        application.baseToken = baseToken;
        application.name = name_;
        application.symbol = symbol_;
        application.decimals = decimals_;
        application.salt = salt;
        emit AssetRouteApplicationSubmitted(
            applicationId,
            msg.sender,
            baseToken,
            name_,
            symbol_,
            decimals_,
            salt
        );
    }

    function voteAssetRouteApplication(bytes32 applicationId) external {
        _requireBase();
        if (!governanceEoas[msg.sender]) revert NotGovernanceEoa();
        AssetRouteApplication storage application = _assetApplications[applicationId];
        if (application.applicant == address(0)) revert AssetApplicationNotFound(applicationId);
        if (application.approved) revert OperationAlreadyExecuted(applicationId);
        if (_assetApplicationVoted[applicationId][msg.sender]) {
            revert GovernanceAlreadyVoted(applicationId, msg.sender);
        }
        _assetApplicationVoted[applicationId][msg.sender] = true;
        application.voteCount++;
        emit AssetRouteApplicationVoted(applicationId, msg.sender, application.voteCount);
        uint256 required = governanceRequiredSignatures();
        if (required != 0 && application.voteCount >= required) {
            application.approved = true;
            emit AssetRouteApplicationApproved(applicationId, application.voteCount);
        }
    }

    /**
     * @notice CoNET miner vote. Miners independently verify the Base approval
     * event and provide its transaction hash before voting for deployment.
     */
    function voteConetAssetDeployment(
        bytes32 applicationId,
        address baseToken,
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_,
        bytes32 salt,
        bytes32 baseApprovalTxHash
    ) external returns (bytes32 deploymentId) {
        _requireConet();
        if (!IUsdcBridgeMinerRegistry(minerRegistry).isMiner(msg.sender)) {
            revert InvalidSigner(msg.sender);
        }
        if (baseApprovalTxHash == bytes32(0)) revert InvalidApprovalTxHash();
        deploymentId = keccak256(
            abi.encode(
                address(this),
                applicationId,
                baseToken,
                keccak256(bytes(name_)),
                keccak256(bytes(symbol_)),
                decimals_,
                salt,
                baseApprovalTxHash
            )
        );
        AssetDeploymentProposal storage proposal = _assetDeploymentProposals[deploymentId];
        if (proposal.executed) revert AssetDeploymentAlreadyExecuted(deploymentId);
        if (proposal.voteCount == 0) {
            proposal.baseToken = baseToken;
            proposal.name = name_;
            proposal.symbol = symbol_;
            proposal.decimals = decimals_;
            proposal.salt = salt;
            proposal.baseApprovalTxHash = baseApprovalTxHash;
        } else if (
            proposal.baseToken != baseToken
                || keccak256(bytes(proposal.name)) != keccak256(bytes(name_))
                || keccak256(bytes(proposal.symbol)) != keccak256(bytes(symbol_))
                || proposal.decimals != decimals_
                || proposal.salt != salt
                || proposal.baseApprovalTxHash != baseApprovalTxHash
        ) {
            revert AssetApplicationMismatch();
        }
        if (_assetDeploymentVoted[deploymentId][msg.sender]) {
            revert MinerAlreadyVotedDeployment(deploymentId, msg.sender);
        }
        _assetDeploymentVoted[deploymentId][msg.sender] = true;
        proposal.voteCount++;
        emit AssetDeploymentVote(
            deploymentId,
            applicationId,
            msg.sender,
            proposal.voteCount
        );
        uint256 required = requiredSignatures();
        if (proposal.voteCount >= required) {
            proposal.conetToken = IConetTreasuryAssetFactory(conetTreasuryTokenRegistry)
                .createERC20FromBridge(name_, symbol_, decimals_, baseToken, salt);
            proposal.executed = true;
            emit AssetDeploymentExecuted(
                deploymentId,
                applicationId,
                baseToken,
                proposal.conetToken,
                baseApprovalTxHash,
                proposal.voteCount
            );
        }
    }

    /**
     * @notice Burn any registered mint/burn ERC-20 on this chain and mint its
     * corresponding peer token on the destination chain.
     *
     * For CoNET-originated exits, the destination-specific exit fee is
     * transferred to this treasury and the requested payout amount is burned.
     */
    function burnMintAssetToChain(
        uint256 destinationChainId,
        address sourceToken,
        uint256 grossAmount,
        address recipient,
        bytes32 paymentRef
    ) external nonReentrant whenNotPaused returns (bytes32 operationId) {
        _requireConfigured();
        _requireConetTreasuryToken(sourceToken);
        MintBurnAssetRoute memory route = _mintBurnAssetRoutes[destinationChainId][sourceToken];
        if (!route.enabled || !route.sourceCanBurn || route.peerToken == address(0)) {
            revert AssetRouteUnavailable(destinationChainId, sourceToken);
        }
        if (grossAmount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();

        (uint256 feeAmount, uint256 netAmount) =
            exitFeeForDestination(destinationChainId, grossAmount);

        operationId = keccak256(
            abi.encode(
                address(this),
                block.chainid,
                destinationChainId,
                DIRECTION_GENERIC_BURN_TO_MINT,
                sourceToken,
                route.peerToken,
                msg.sender,
                recipient,
                grossAmount,
                netAmount,
                feeAmount,
                paymentRef,
                block.number
            )
        );
        if (initiated[operationId]) revert OperationAlreadyExists(operationId);
        initiated[operationId] = true;

        if (feeAmount != 0) {
            IERC20(sourceToken).safeTransferFrom(msg.sender, address(this), feeAmount);
        }
        IUsdcBridgeBurnable(sourceToken).burnFrom(msg.sender, netAmount);
        _recordLedger(
            destinationChainId,
            sourceToken,
            LEDGER_OUTBOUND,
            grossAmount,
            netAmount,
            feeAmount
        );
        emit GenericBurnInitiated(
            operationId,
            msg.sender,
            recipient,
            block.chainid,
            destinationChainId,
            sourceToken,
            route.peerToken,
            grossAmount,
            netAmount,
            feeAmount,
            paymentRef
        );
    }

    /**
     * @notice Lock an ERC-20 for which this treasury has no mint/burn
     * permission. The peer chain receives a same-address wrapped token.
     */
    function lockAssetToChain(
        uint256 destinationChainId,
        address sourceToken,
        uint256 payoutAmount,
        address recipient,
        bytes32 paymentRef
    ) external nonReentrant whenNotPaused returns (bytes32 operationId) {
        _requireConfigured();
        _requireConetTreasuryToken(sourceToken);
        MintBurnAssetRoute memory route = _mintBurnAssetRoutes[destinationChainId][sourceToken];
        if (!route.enabled || route.sourceCanBurn || route.peerToken == address(0)) {
            revert AssetRouteUnavailable(destinationChainId, sourceToken);
        }
        if (payoutAmount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        (uint256 feeAmount,) = exitFeeForDestination(destinationChainId, payoutAmount);
        uint256 debitAmount = payoutAmount + feeAmount;

        operationId = keccak256(
            abi.encode(
                address(this),
                block.chainid,
                destinationChainId,
                DIRECTION_GENERIC_BURN_TO_MINT,
                sourceToken,
                route.peerToken,
                msg.sender,
                recipient,
                payoutAmount,
                feeAmount,
                paymentRef,
                block.number
            )
        );
        if (initiated[operationId]) revert OperationAlreadyExists(operationId);
        initiated[operationId] = true;
        IERC20(sourceToken).safeTransferFrom(msg.sender, address(this), debitAmount);
        _recordLedger(
            destinationChainId,
            sourceToken,
            LEDGER_OUTBOUND,
            payoutAmount,
            payoutAmount,
            feeAmount
        );
        emit LockedAssetDepositInitiated(
            operationId,
            msg.sender,
            recipient,
            block.chainid,
            destinationChainId,
            sourceToken,
            route.peerToken,
            payoutAmount,
            feeAmount,
            paymentRef
        );
    }

    function executeGenericLockedMint(
        bytes32 operationId,
        bytes32 sourceTxHash,
        uint256 sourceChainId,
        uint256 destinationChainId,
        address sourceToken,
        address destinationToken,
        address recipient,
        uint256 payoutAmount,
        uint256 feeAmount,
        uint256 sourceBlockNumber,
        uint256 deadline,
        bytes[] calldata signatures
    ) external nonReentrant whenNotPaused {
        _requireConfigured();
        _requireConetTreasuryToken(destinationToken);
        if (block.chainid != destinationChainId) {
            revert WrongChain(destinationChainId, block.chainid);
        }
        MintBurnAssetRoute memory route = _mintBurnAssetRoutes[sourceChainId][destinationToken];
        if (!route.enabled || route.sourceCanBurn || route.peerToken != sourceToken) {
            revert AssetRouteUnavailable(sourceChainId, destinationToken);
        }
        _validateExecution(
            operationId,
            sourceTxHash,
            recipient,
            payoutAmount,
            payoutAmount,
            feeAmount,
            sourceBlockNumber,
            deadline
        );
        _validateSourceFee(sourceChainId, destinationChainId, payoutAmount, feeAmount);
        if (executed[operationId]) revert OperationAlreadyExecuted(operationId);
        uint256 signerCount = _verifyGenericAttestations(
            operationId,
            sourceTxHash,
            sourceChainId,
            destinationChainId,
            sourceToken,
            recipient,
            payoutAmount,
            payoutAmount,
            feeAmount,
            sourceBlockNumber,
            deadline,
            signatures
        );
        executed[operationId] = true;
        IUsdcBridgeMintable(destinationToken).mint(recipient, payoutAmount);
        _recordLedger(
            sourceChainId,
            destinationToken,
            LEDGER_INBOUND,
            payoutAmount,
            payoutAmount,
            feeAmount
        );
        emit LockedAssetMintExecuted(
            operationId,
            sourceTxHash,
            recipient,
            sourceChainId,
            sourceToken,
            destinationToken,
            payoutAmount,
            feeAmount,
            signerCount
        );
    }

    /**
     * @notice Burn the peer wrapped token and release the original token
     * held by this treasury.
     */
    function executeGenericLockedRelease(
        bytes32 operationId,
        bytes32 sourceTxHash,
        uint256 sourceChainId,
        uint256 destinationChainId,
        address sourceToken,
        address destinationToken,
        address recipient,
        uint256 payoutAmount,
        uint256 feeAmount,
        uint256 sourceBlockNumber,
        uint256 deadline,
        bytes[] calldata signatures
    ) external nonReentrant whenNotPaused {
        _requireConfigured();
        _requireConetTreasuryToken(destinationToken);
        if (block.chainid != destinationChainId) {
            revert WrongChain(destinationChainId, block.chainid);
        }
        MintBurnAssetRoute memory route = _mintBurnAssetRoutes[sourceChainId][destinationToken];
        if (!route.enabled || route.sourceCanBurn || route.peerToken != sourceToken) {
            revert AssetRouteUnavailable(sourceChainId, destinationToken);
        }
        _validateExecution(
            operationId,
            sourceTxHash,
            recipient,
            payoutAmount,
            payoutAmount,
            feeAmount,
            sourceBlockNumber,
            deadline
        );
        _validateSourceFee(sourceChainId, destinationChainId, payoutAmount, feeAmount);
        if (executed[operationId]) revert OperationAlreadyExecuted(operationId);
        uint256 available = IERC20(destinationToken).balanceOf(address(this));
        if (available < payoutAmount) revert InsufficientLiquidity(available, payoutAmount);
        uint256 signerCount = _verifyGenericAttestations(
            operationId,
            sourceTxHash,
            sourceChainId,
            destinationChainId,
            sourceToken,
            recipient,
            payoutAmount,
            payoutAmount,
            feeAmount,
            sourceBlockNumber,
            deadline,
            signatures
        );
        executed[operationId] = true;
        IERC20(destinationToken).safeTransfer(recipient, payoutAmount);
        _recordLedger(
            sourceChainId,
            destinationToken,
            LEDGER_INBOUND,
            payoutAmount,
            payoutAmount,
            feeAmount
        );
        emit LockedAssetReleaseExecuted(
            operationId,
            sourceTxHash,
            recipient,
            sourceChainId,
            sourceToken,
            destinationToken,
            payoutAmount,
            feeAmount,
            signerCount
        );
    }

    /**
     * @notice Verify miner attestations and invoke the destination token's
     * native mint function. The target token must be registered locally and
     * point back to the source token.
     */
    function executeGenericMint(
        bytes32 operationId,
        bytes32 sourceTxHash,
        uint256 sourceChainId,
        uint256 destinationChainId,
        address sourceToken,
        address destinationToken,
        address recipient,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 sourceBlockNumber,
        uint256 deadline,
        bytes[] calldata signatures
    ) external nonReentrant whenNotPaused {
        _requireConfigured();
        _requireConetTreasuryToken(destinationToken);
        if (block.chainid != destinationChainId) {
            revert WrongChain(destinationChainId, block.chainid);
        }
        MintBurnAssetRoute memory route = _mintBurnAssetRoutes[sourceChainId][destinationToken];
        if (!route.enabled || route.sourceCanBurn || route.peerToken != sourceToken) {
            revert AssetRouteUnavailable(sourceChainId, destinationToken);
        }
        _validateExecution(
            operationId,
            sourceTxHash,
            recipient,
            grossAmount,
            netAmount,
            feeAmount,
            sourceBlockNumber,
            deadline
        );
        _validateSourceFee(sourceChainId, destinationChainId, grossAmount, feeAmount);
        if (executed[operationId]) revert OperationAlreadyExecuted(operationId);
        uint256 signerCount = _verifyGenericAttestations(
            operationId,
            sourceTxHash,
            sourceChainId,
            destinationChainId,
            sourceToken,
            recipient,
            grossAmount,
            netAmount,
            feeAmount,
            sourceBlockNumber,
            deadline,
            signatures
        );
        executed[operationId] = true;
        IUsdcBridgeMintable(destinationToken).mint(recipient, grossAmount);
        _recordLedger(
            sourceChainId,
            destinationToken,
            LEDGER_INBOUND,
            grossAmount,
            grossAmount,
            feeAmount
        );
        emit GenericMintExecuted(
            operationId,
            sourceTxHash,
            recipient,
            sourceChainId,
            sourceToken,
            destinationToken,
            grossAmount,
            netAmount,
            feeAmount,
            signerCount
        );
    }

    /**
     * @dev Base-only lock. operationId is supplied by the caller but must be
     * unique; paymentRef is application metadata and is included in the
     * deterministic operation id by the client/API.
     */
    function depositToConet(
        uint256 amount,
        address recipient,
        bytes32 paymentRef
    ) external whenNotPaused nonReentrant returns (bytes32 operationId) {
        _requireBase();
        _requireConfigured();
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        (uint256 feeAmount, uint256 netAmount) = exitFeeForDestination(CONET_CHAIN_ID, amount);
        operationId = keccak256(
            abi.encode(
                address(this),
                block.chainid,
                CONET_CHAIN_ID,
                DIRECTION_BASE_TO_CONET,
                msg.sender,
                recipient,
                amount,
                netAmount,
                feeAmount,
                paymentRef,
                block.number
            )
        );
        if (initiated[operationId]) revert OperationAlreadyExists(operationId);
        initiated[operationId] = true;
        IERC20(baseUsdc).safeTransferFrom(msg.sender, address(this), feeAmount);
        IERC20(baseUsdc).safeTransferFrom(msg.sender, address(this), netAmount);
        _recordLedger(CONET_CHAIN_ID, baseUsdc, LEDGER_OUTBOUND, amount, netAmount, feeAmount);
        emit DepositInitiated(operationId, msg.sender, recipient, amount, netAmount, feeAmount, paymentRef);
    }

    /**
     * @dev CoNET-only burn. The bridge must be the minter/burner configured on
     * the conet-USDC token; no relayer is allowed to burn arbitrary balances.
     */
    function burnToBase(
        uint256 amount,
        address recipient,
        bytes32 paymentRef
    ) external whenNotPaused nonReentrant returns (bytes32 operationId) {
        _requireConet();
        _requireConfigured();
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        (uint256 feeAmount, uint256 netAmount) = exitFeeForDestination(BASE_CHAIN_ID, amount);
        operationId = keccak256(
            abi.encode(
                address(this),
                block.chainid,
                BASE_CHAIN_ID,
                DIRECTION_CONET_TO_BASE,
                msg.sender,
                recipient,
                amount,
                paymentRef,
                block.number
            )
        );
        if (initiated[operationId]) revert OperationAlreadyExists(operationId);
        initiated[operationId] = true;
        IERC20(conetUsdc).safeTransferFrom(msg.sender, address(this), feeAmount);
        IUsdcBridgeBurnable(conetUsdc).burnFrom(msg.sender, netAmount);
        _recordLedger(BASE_CHAIN_ID, conetUsdc, LEDGER_OUTBOUND, amount, netAmount, feeAmount);
        emit BurnInitiated(operationId, msg.sender, recipient, amount, netAmount, feeAmount, paymentRef);
    }

    /**
     * @notice CoNET native CNET reserve leg. CNET remains in this bridge until
     * a Base-side wCNET burn reaches the miner attestation threshold.
     */
    function depositNativeCnetToBase(
        uint256 payoutAmount,
        address recipient,
        bytes32 paymentRef
    ) external payable whenNotPaused returns (bytes32 operationId) {
        _requireConet();
        _requireConfigured();
        if (payoutAmount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        (uint256 feeAmount, uint256 netAmount) = exitFeeForDestination(BASE_CHAIN_ID, payoutAmount);
        if (msg.value != payoutAmount + feeAmount) revert InvalidOperation();
        operationId = keccak256(
            abi.encode(
                address(this),
                block.chainid,
                BASE_CHAIN_ID,
                DIRECTION_CONET_NATIVE_TO_BASE,
                msg.sender,
                recipient,
                payoutAmount,
                paymentRef,
                block.number
            )
        );
        if (initiated[operationId]) revert OperationAlreadyExists(operationId);
        initiated[operationId] = true;
        _recordLedger(BASE_CHAIN_ID, address(0), LEDGER_OUTBOUND, payoutAmount, netAmount, feeAmount);
        emit NativeDepositInitiated(operationId, msg.sender, recipient, payoutAmount, netAmount, feeAmount, paymentRef);
    }

    /**
     * @notice Base-side wCNET burn. The bridge must be the wCNET minter/burner.
     */
    function burnWcnetToConet(
        uint256 amount,
        address recipient,
        bytes32 paymentRef
    ) external nonReentrant whenNotPaused returns (bytes32 operationId) {
        _requireBase();
        _requireConfigured();
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        operationId = keccak256(
            abi.encode(
                address(this),
                block.chainid,
                CONET_CHAIN_ID,
                DIRECTION_BASE_WCNET_TO_CONET,
                msg.sender,
                recipient,
                amount,
                paymentRef,
                block.number
            )
        );
        if (initiated[operationId]) revert OperationAlreadyExists(operationId);
        initiated[operationId] = true;
        (uint256 feeAmount, uint256 netAmount) = exitFeeForDestination(CONET_CHAIN_ID, amount);
        IERC20(wcnet).safeTransferFrom(msg.sender, address(this), feeAmount);
        IUsdcBridgeBurnable(wcnet).burnFrom(msg.sender, netAmount);
        _recordLedger(CONET_CHAIN_ID, wcnet, LEDGER_OUTBOUND, amount, netAmount, feeAmount);
        emit WcnetBurnInitiated(operationId, msg.sender, recipient, amount, netAmount, feeAmount, paymentRef);
    }

    function executeMint(
        bytes32 operationId,
        bytes32 sourceTxHash,
        address recipient,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 sourceBlockNumber,
        uint256 deadline,
        bytes[] calldata signatures
    ) external whenNotPaused nonReentrant {
        _requireConet();
        _requireConfigured();
        _requireConetTreasuryToken(conetUsdc);
        _validateExecution(operationId, sourceTxHash, recipient, grossAmount, netAmount, feeAmount, sourceBlockNumber, deadline);
        _validateSourceFee(BASE_CHAIN_ID, CONET_CHAIN_ID, grossAmount, feeAmount);
        if (executed[operationId]) revert OperationAlreadyExecuted(operationId);
        uint256 signerCount = _verifyAttestations(
            operationId,
            sourceTxHash,
            recipient,
            grossAmount,
            netAmount,
            feeAmount,
            sourceBlockNumber,
            deadline,
            DIRECTION_BASE_TO_CONET,
            signatures
        );
        executed[operationId] = true;
        IUsdcBridgeMintable(conetUsdc).mint(recipient, grossAmount);
        _recordLedger(BASE_CHAIN_ID, conetUsdc, LEDGER_INBOUND, grossAmount, grossAmount, feeAmount);
        emit MintExecuted(operationId, sourceTxHash, recipient, grossAmount, grossAmount, feeAmount, signerCount);
    }

    function executeRelease(
        bytes32 operationId,
        bytes32 sourceTxHash,
        address recipient,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 sourceBlockNumber,
        uint256 deadline,
        bytes[] calldata signatures
    ) external whenNotPaused nonReentrant {
        _requireBase();
        _requireConfigured();
        _validateExecution(operationId, sourceTxHash, recipient, grossAmount, netAmount, feeAmount, sourceBlockNumber, deadline);
        _validateSourceFee(CONET_CHAIN_ID, BASE_CHAIN_ID, grossAmount, feeAmount);
        if (executed[operationId]) revert OperationAlreadyExecuted(operationId);
        uint256 available = IERC20(baseUsdc).balanceOf(address(this));
        if (available < grossAmount) revert InsufficientLiquidity(available, grossAmount);
        uint256 signerCount = _verifyAttestations(
            operationId,
            sourceTxHash,
            recipient,
            grossAmount,
            netAmount,
            feeAmount,
            sourceBlockNumber,
            deadline,
            DIRECTION_CONET_TO_BASE,
            signatures
        );
        executed[operationId] = true;
        IERC20(baseUsdc).safeTransfer(recipient, grossAmount);
        _recordLedger(CONET_CHAIN_ID, baseUsdc, LEDGER_INBOUND, grossAmount, grossAmount, feeAmount);
        emit ReleaseExecuted(operationId, sourceTxHash, recipient, grossAmount, netAmount, feeAmount, signerCount);
    }

    function executeMintWcnet(
        bytes32 operationId,
        bytes32 sourceTxHash,
        address recipient,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 sourceBlockNumber,
        uint256 deadline,
        bytes[] calldata signatures
    ) external nonReentrant whenNotPaused {
        _requireBase();
        _requireConfigured();
        _requireConetTreasuryToken(wcnet);
        _validateExecution(operationId, sourceTxHash, recipient, grossAmount, netAmount, feeAmount, sourceBlockNumber, deadline);
        _validateSourceFee(CONET_CHAIN_ID, BASE_CHAIN_ID, grossAmount, feeAmount);
        if (executed[operationId]) revert OperationAlreadyExecuted(operationId);
        uint256 signerCount = _verifyAttestations(
            operationId,
            sourceTxHash,
            recipient,
            grossAmount,
            netAmount,
            feeAmount,
            sourceBlockNumber,
            deadline,
            DIRECTION_CONET_NATIVE_TO_BASE,
            signatures
        );
        executed[operationId] = true;
        IUsdcBridgeMintable(wcnet).mint(recipient, grossAmount);
        _recordLedger(CONET_CHAIN_ID, wcnet, LEDGER_INBOUND, grossAmount, grossAmount, feeAmount);
        emit WcnetMintExecuted(operationId, sourceTxHash, recipient, grossAmount, netAmount, feeAmount, signerCount);
    }

    function executeReleaseNative(
        bytes32 operationId,
        bytes32 sourceTxHash,
        address recipient,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 sourceBlockNumber,
        uint256 deadline,
        bytes[] calldata signatures
    ) external nonReentrant whenNotPaused {
        _requireConet();
        _requireConfigured();
        _validateExecution(operationId, sourceTxHash, recipient, grossAmount, netAmount, feeAmount, sourceBlockNumber, deadline);
        _validateSourceFee(BASE_CHAIN_ID, CONET_CHAIN_ID, grossAmount, feeAmount);
        if (executed[operationId]) revert OperationAlreadyExecuted(operationId);
        uint256 available = address(this).balance;
        if (available < grossAmount) revert InsufficientLiquidity(available, grossAmount);
        uint256 signerCount = _verifyAttestations(
            operationId,
            sourceTxHash,
            recipient,
            grossAmount,
            netAmount,
            feeAmount,
            sourceBlockNumber,
            deadline,
            DIRECTION_BASE_WCNET_TO_CONET,
            signatures
        );
        executed[operationId] = true;
        (bool ok,) = payable(recipient).call{value: grossAmount}("");
        if (!ok) revert NativeTransferFailed();
        _recordLedger(BASE_CHAIN_ID, address(0), LEDGER_INBOUND, grossAmount, grossAmount, feeAmount);
        emit NativeReleaseExecuted(operationId, sourceTxHash, recipient, grossAmount, netAmount, feeAmount, signerCount);
    }

    function attestationDigest(
        uint256 sourceChainId,
        uint256 destinationChainId,
        uint8 direction,
        bytes32 sourceTxHash,
        bytes32 operationId,
        address token,
        address recipient,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 sourceBlockNumber,
        uint256 deadline
    ) external view returns (bytes32) {
        return _hashAttestation(
            sourceChainId,
            destinationChainId,
            direction,
            sourceTxHash,
            operationId,
            token,
            recipient,
            grossAmount,
            netAmount,
            feeAmount,
            sourceBlockNumber,
            deadline
        );
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _verifyAttestations(
        bytes32 operationId,
        bytes32 sourceTxHash,
        address recipient,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 sourceBlockNumber,
        uint256 deadline,
        uint8 direction,
        bytes[] calldata signatures
    ) internal view returns (uint256 signerCount) {
        uint256 required = requiredSignatures();
        if (signatures.length < required) revert InsufficientSignatures(signatures.length, required);
        address token;
        uint256 sourceChainId;
        uint256 destinationChainId;
        if (direction == DIRECTION_BASE_TO_CONET) {
            token = baseUsdc;
            sourceChainId = BASE_CHAIN_ID;
            destinationChainId = CONET_CHAIN_ID;
        } else if (direction == DIRECTION_CONET_TO_BASE) {
            token = conetUsdc;
            sourceChainId = CONET_CHAIN_ID;
            destinationChainId = BASE_CHAIN_ID;
        } else if (direction == DIRECTION_CONET_NATIVE_TO_BASE) {
            token = address(0);
            sourceChainId = CONET_CHAIN_ID;
            destinationChainId = BASE_CHAIN_ID;
        } else if (direction == DIRECTION_BASE_WCNET_TO_CONET) {
            token = wcnet;
            sourceChainId = BASE_CHAIN_ID;
            destinationChainId = CONET_CHAIN_ID;
        } else {
            revert InvalidAttestation();
        }
        bytes32 digest = _hashAttestation(
            sourceChainId,
            destinationChainId,
            direction,
            sourceTxHash,
            operationId,
            token,
            recipient,
            grossAmount,
            netAmount,
            feeAmount,
            sourceBlockNumber,
            deadline
        );
        address[] memory seen = new address[](signatures.length);
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (!IUsdcBridgeMinerRegistry(minerRegistry).isMiner(signer)) {
                revert InvalidSigner(signer);
            }
            for (uint256 j = 0; j < signerCount; j++) {
                if (seen[j] == signer) revert DuplicateSigner(signer);
            }
            seen[signerCount] = signer;
            signerCount++;
        }
    }

    function _verifyGenericAttestations(
        bytes32 operationId,
        bytes32 sourceTxHash,
        uint256 sourceChainId,
        uint256 destinationChainId,
        address sourceToken,
        address recipient,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 sourceBlockNumber,
        uint256 deadline,
        bytes[] calldata signatures
    ) internal view returns (uint256 signerCount) {
        if (signatures.length < requiredSignatures()) {
            revert InsufficientSignatures(signatures.length, requiredSignatures());
        }
        bytes32 digest = _hashAttestation(
            sourceChainId,
            destinationChainId,
            DIRECTION_GENERIC_BURN_TO_MINT,
            sourceTxHash,
            operationId,
            sourceToken,
            recipient,
            grossAmount,
            netAmount,
            feeAmount,
            sourceBlockNumber,
            deadline
        );
        address[] memory seen = new address[](signatures.length);
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (!IUsdcBridgeMinerRegistry(minerRegistry).isMiner(signer)) {
                revert InvalidSigner(signer);
            }
            for (uint256 j = 0; j < signerCount; j++) {
                if (seen[j] == signer) revert DuplicateSigner(signer);
            }
            seen[signerCount] = signer;
            signerCount++;
        }
    }

    function _hashAttestation(
        uint256 sourceChainId,
        uint256 destinationChainId,
        uint8 direction,
        bytes32 sourceTxHash,
        bytes32 operationId,
        address token,
        address recipient,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 sourceBlockNumber,
        uint256 deadline
    ) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    BRIDGE_ATTESTATION_TYPEHASH,
                    address(this),
                    sourceChainId,
                    destinationChainId,
                    direction,
                    sourceTxHash,
                    operationId,
                    token,
                    recipient,
                    grossAmount,
                    netAmount,
                    feeAmount,
                    sourceBlockNumber,
                    deadline
                )
            )
        );
    }

    function _validateExecution(
        bytes32 operationId,
        bytes32 sourceTxHash,
        address recipient,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount,
        uint256 sourceBlockNumber,
        uint256 deadline
    ) internal view {
        if (operationId == bytes32(0)) revert InvalidOperation();
        if (sourceTxHash == bytes32(0)) revert InvalidSourceTxHash();
        if (recipient == address(0)) revert InvalidRecipient();
        if (
            grossAmount == 0
                || netAmount == 0
                || netAmount != grossAmount
                || sourceBlockNumber == 0
        ) revert InvalidOperation();
        if (deadline < block.timestamp) revert InvalidDeadline();
    }

    function _validateSourceFee(
        uint256 sourceChainId,
        uint256 destinationChainId,
        uint256 payoutAmount,
        uint256 feeAmount
    ) internal view {
        sourceChainId;
        destinationChainId;
        uint256 maxFee = (payoutAmount * MAX_EXIT_FEE_BPS + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR;
        if (feeAmount > maxFee) {
            revert InvalidFeeAmount(feeAmount, maxFee);
        }
    }

    function _recordLedger(
        uint256 peerChainId,
        address asset,
        uint8 direction,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 feeAmount
    ) internal {
        Ledger storage peer = _peerLedgers[peerChainId][asset];
        Ledger storage total = _totalLedgers[asset];
        if (direction == LEDGER_OUTBOUND) {
            peer.outboundGross += grossAmount;
            peer.outboundNet += netAmount;
            total.outboundGross += grossAmount;
            total.outboundNet += netAmount;
        } else if (direction == LEDGER_INBOUND) {
            peer.inboundGross += grossAmount;
            peer.inboundNet += netAmount;
            total.inboundGross += grossAmount;
            total.inboundNet += netAmount;
        } else {
            revert InvalidOperation();
        }
        peer.fees += feeAmount;
        peer.operations += 1;
        total.fees += feeAmount;
        total.operations += 1;
    }

    function _requireConfigured() internal view {
        if (
            minerRegistry == address(0)
                || baseUsdc == address(0)
                || conetUsdc == address(0)
                || wcnet == address(0)
        ) {
            revert ZeroAddress();
        }
    }

    function _requireConetTreasuryToken(address token) internal view {
        if (
            block.chainid == CONET_CHAIN_ID
                && (
                    conetTreasuryTokenRegistry == address(0)
                        || !IConetTreasuryTokenRegistry(conetTreasuryTokenRegistry).isCreatedToken(token)
                )
        ) {
            revert ConetTokenNotTreasuryCreated(token);
        }
    }

    function _requireBase() internal view {
        if (block.chainid != BASE_CHAIN_ID) revert WrongChain(BASE_CHAIN_ID, block.chainid);
    }

    function _requireConet() internal view {
        if (block.chainid != CONET_CHAIN_ID) revert WrongChain(CONET_CHAIN_ID, block.chainid);
    }

    function _minerCount() internal view returns (uint256) {
        if (minerRegistry == address(0)) return 0;
        return IUsdcBridgeMinerRegistry(minerRegistry).minerCount();
    }

    function _defaultQuorum(uint256 minerTotal) internal pure returns (uint256) {
        if (minerTotal == 0) return 0;
        return (minerTotal * 2 + 2) / 3;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[42] private __gap;
}
