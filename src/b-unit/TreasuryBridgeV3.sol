// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface ITreasuryBridgeAssetV3 {
    function mint(address to, uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

interface IERC20BridgeV3 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title TreasuryBridgeV3
/// @notice Upgradeable cross-chain treasury with miner-governed asset routes.
/// @dev The same event schema is emitted for every asset and every phase.
contract TreasuryBridgeV3 is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_BPS = 1_000;
    /// @notice Max recipients per cross-chain operation (gas / DoS bound).
    uint256 public constant MAX_BENEFICIARIES = 32;
    /// @dev `beneficiariesHash = keccak256(abi.encode(beneficiaries, amounts))`.
    bytes32 public constant BRIDGE_ATTESTATION_TYPEHASH = keccak256(
        "BridgeAttestation(bytes32 operationId,uint256 sourceChainId,uint256 destinationChainId,address sourceTreasury,address sourceAsset,address destinationAsset,bytes32 beneficiariesHash,uint8 mode,uint256 grossAmount,uint256 feeAmount,bytes32 sourceTxHash,uint256 nonce)"
    );

    enum AssetMode {
        BurnMint,
        LockMint,
        BurnRelease
    }

    enum Phase {
        Initiated,
        Executed,
        Cancelled
    }

    struct AssetPolicy {
        uint256 sourceChainId;
        address sourceTreasury;
        address sourceAsset;
        address destinationAsset;
        AssetMode mode;
        uint8 decimals;
        bool enabled;
        uint256 version;
    }

    struct PolicyProposal {
        AssetPolicy policy;
        uint256 voteCount;
        bool executed;
    }

    struct FeeProposal {
        uint256 destinationChainId;
        uint256 feeBps;
        uint256 voteCount;
        bool executed;
    }

    address[] private _miners;
    address[] private _governanceEoas;
    mapping(address => bool) public isMiner;
    mapping(address => bool) public isGovernanceEoa;
    mapping(bytes32 => AssetPolicy) private _policies;
    mapping(bytes32 => PolicyProposal) private _policyProposals;
    mapping(bytes32 => mapping(address => bool)) public policyVoted;
    mapping(bytes32 => FeeProposal) public feeProposals;
    mapping(bytes32 => mapping(address => bool)) public feeProposalVoted;
    mapping(address => bool) public authorizedBridgeAsset;
    mapping(uint256 => uint256) public destinationFeeBps;
    mapping(bytes32 => bool) public operationExecuted;
    mapping(bytes32 => bool) public operationInitiated;
    mapping(bytes32 => uint256) public bridgeOperationVoteCount;
    mapping(bytes32 => mapping(address => bool)) public bridgeOperationVoted;
    mapping(bytes32 => bytes32) public bridgeOperationPayloadHash;

    /// @notice BUnitAirdrop (or equivalent) allowed to call `mintForAdmin` for fee settlement.
    address public feeSettlement;
    /// @notice Canonical conet-USDC (V3) minted on paid B-Unit burn.
    address public feeSettlementAsset;

    event MinerAdded(address indexed miner);
    event MinerRemoved(address indexed miner);
    event FeeSettlementUpdated(address indexed settlement, address indexed asset);
    event FeeSettlementMinted(address indexed asset, address indexed recipient, uint256 amount);
    event AssetPolicyProposed(bytes32 indexed proposalId, bytes32 indexed policyId, AssetPolicy policy);
    event AssetPolicyVoted(bytes32 indexed proposalId, address indexed miner, uint256 voteCount);
    event AssetPolicyUpdated(bytes32 indexed policyId, AssetPolicy policy);
    event DestinationFeeUpdated(uint256 indexed destinationChainId, uint256 feeBps);
    event GovernanceEoaUpdated(address indexed eoa, bool enabled);
    event DestinationFeeProposalVoted(bytes32 indexed proposalId, address indexed eoa, uint256 voteCount);
    event BridgeAssetAuthorizationUpdated(address indexed asset, bool authorized);
    event BridgeOperationVote(
        bytes32 indexed operationId,
        address indexed miner,
        uint256 voteCount,
        uint256 requiredVotes
    );

    /// @dev The only event miners need to scan on either chain.
    ///      `beneficiaries` / `amounts` are parallel arrays; `sum(amounts) == grossAmount`.
    event BridgeOperation(
        bytes32 indexed operationId,
        uint256 indexed sourceChainId,
        uint256 indexed destinationChainId,
        Phase phase,
        AssetMode mode,
        address sourceTreasury,
        address sourceAsset,
        address destinationAsset,
        address sender,
        address[] beneficiaries,
        uint256[] amounts,
        uint256 grossAmount,
        uint256 feeAmount,
        uint256 netAmount,
        bytes32 sourceTxHash,
        uint256 nonce
    );

    error NotMiner();
    error AlreadyVoted();
    error ProposalNotExecutable();
    error ProposalAlreadyExecuted();
    error InvalidPolicy();
    error PolicyNotEnabled();
    error PolicyNotFound();
    error InvalidAmount();
    error InvalidFee();
    error InvalidSignature();
    error OperationAlreadyUsed();
    error TransferFailed();
    error AssetNotAuthorized();
    error InvalidQuorum();
    error NotGovernanceEoa();
    error NotFeeSettlement();
    error InvalidBeneficiaries();

    modifier onlyMiner() {
        if (!isMiner[msg.sender]) revert NotMiner();
        _;
    }

    modifier onlyGovernanceEoa() {
        if (!isGovernanceEoa[msg.sender]) revert NotGovernanceEoa();
        _;
    }

    modifier onlyFeeSettlement() {
        if (msg.sender != feeSettlement) revert NotFeeSettlement();
        _;
    }

    function initialize(
        address owner_,
        address[] calldata miners_
    ) external initializer {
        if (owner_ == address(0) || miners_.length == 0) revert InvalidPolicy();
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        for (uint256 i; i < miners_.length; ++i) {
            _addMiner(miners_[i]);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function minerCount() external view returns (uint256) {
        return _miners.length;
    }

    function governanceEoaCount() external view returns (uint256) {
        return _governanceEoas.length;
    }

    function requiredGovernanceVotes() public view returns (uint256) {
        uint256 count = _governanceEoas.length;
        return count == 0 ? 0 : (count * 2 + 2) / 3;
    }

    function setGovernanceEoa(address eoa, bool enabled) external onlyOwner {
        if (eoa == address(0)) revert InvalidPolicy();
        if (enabled && !isGovernanceEoa[eoa]) {
            isGovernanceEoa[eoa] = true;
            _governanceEoas.push(eoa);
        } else if (!enabled && isGovernanceEoa[eoa]) {
            isGovernanceEoa[eoa] = false;
            for (uint256 i; i < _governanceEoas.length; ++i) {
                if (_governanceEoas[i] == eoa) {
                    _governanceEoas[i] = _governanceEoas[_governanceEoas.length - 1];
                    _governanceEoas.pop();
                    break;
                }
            }
        }
        emit GovernanceEoaUpdated(eoa, enabled);
    }

    function requiredVotes() public view returns (uint256) {
        uint256 count = _miners.length;
        return count == 0 ? 0 : (count * 2 + 2) / 3;
    }

    function miners() external view returns (address[] memory) {
        return _miners;
    }

    function addMiner(address miner) external onlyOwner {
        _addMiner(miner);
    }

    function removeMiner(address miner) external onlyOwner {
        if (!isMiner[miner] || _miners.length <= 1) revert InvalidPolicy();
        isMiner[miner] = false;
        for (uint256 i; i < _miners.length; ++i) {
            if (_miners[i] == miner) {
                _miners[i] = _miners[_miners.length - 1];
                _miners.pop();
                break;
            }
        }
        emit MinerRemoved(miner);
    }

    function _addMiner(address miner) internal {
        if (miner == address(0) || isMiner[miner]) revert InvalidPolicy();
        isMiner[miner] = true;
        _miners.push(miner);
        emit MinerAdded(miner);
    }

    function policyId(AssetPolicy memory policy) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                policy.sourceChainId,
                policy.sourceTreasury,
                policy.sourceAsset,
                policy.destinationAsset,
                policy.mode
            )
        );
    }

    function assetPolicy(bytes32 id) external view returns (AssetPolicy memory) {
        return _policies[id];
    }

    function proposeAssetPolicy(AssetPolicy calldata policy) external onlyMiner returns (bytes32 proposalId) {
        _validatePolicy(policy);
        bytes32 id = policyId(policy);
        proposalId = keccak256(abi.encode(id, policy.version, block.number));
        PolicyProposal storage proposal = _policyProposals[proposalId];
        if (proposal.policy.sourceAsset != address(0)) revert ProposalAlreadyExecuted();
        proposal.policy = policy;
        proposal.voteCount = 1;
        policyVoted[proposalId][msg.sender] = true;
        emit AssetPolicyProposed(proposalId, id, policy);
        emit AssetPolicyVoted(proposalId, msg.sender, 1);
        if (proposal.voteCount >= requiredVotes()) _executePolicy(proposalId);
    }

    function voteAssetPolicy(bytes32 proposalId, AssetPolicy calldata policy) external onlyMiner {
        PolicyProposal storage proposal = _policyProposals[proposalId];
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (policyId(policy) != policyId(proposal.policy)) revert InvalidPolicy();
        if (policyVoted[proposalId][msg.sender]) revert AlreadyVoted();
        policyVoted[proposalId][msg.sender] = true;
        proposal.voteCount++;
        emit AssetPolicyVoted(proposalId, msg.sender, proposal.voteCount);
        if (proposal.voteCount >= requiredVotes()) _executePolicy(proposalId);
    }

    function executeAssetPolicy(bytes32 proposalId) external {
        _executePolicy(proposalId);
    }

    function _executePolicy(bytes32 proposalId) internal {
        PolicyProposal storage proposal = _policyProposals[proposalId];
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.voteCount < requiredVotes()) revert ProposalNotExecutable();
        proposal.executed = true;
        bytes32 id = policyId(proposal.policy);
        _policies[id] = proposal.policy;
        emit AssetPolicyUpdated(id, proposal.policy);
    }

    function setBridgeAssetAuthorization(address asset, bool authorized) external onlyOwner {
        if (asset == address(0)) revert InvalidPolicy();
        authorizedBridgeAsset[asset] = authorized;
        emit BridgeAssetAuthorizationUpdated(asset, authorized);
    }

    /// @notice Register BUnitAirdrop + V3 USDC for paid B-Unit fee mint (`mintForAdmin` ABI compat).
    function setFeeSettlement(address settlement, address asset) external onlyOwner {
        if (settlement == address(0) || asset == address(0)) revert InvalidPolicy();
        feeSettlement = settlement;
        feeSettlementAsset = asset;
        emit FeeSettlementUpdated(settlement, asset);
    }

    /// @notice Compatible with BUnitAirdrop → ConetTreasury.mintForAdmin; mints feeSettlementAsset only.
    function mintForAdmin(address token, address recipient, uint256 amount)
        external
        onlyFeeSettlement
        nonReentrant
    {
        if (token == address(0) || token != feeSettlementAsset) revert InvalidPolicy();
        if (recipient == address(0) || amount == 0) revert InvalidAmount();
        ITreasuryBridgeAssetV3(token).mint(recipient, amount);
        emit FeeSettlementMinted(token, recipient, amount);
    }

    function setDestinationFeeBps(uint256 destinationChainId, uint256 feeBps) external onlyOwner {
        if (feeBps > MAX_FEE_BPS) revert InvalidFee();
        destinationFeeBps[destinationChainId] = feeBps;
        emit DestinationFeeUpdated(destinationChainId, feeBps);
    }

    function proposeDestinationFeeBps(uint256 destinationChainId, uint256 feeBps)
        external
        onlyGovernanceEoa
        returns (bytes32 proposalId)
    {
        if (feeBps > MAX_FEE_BPS || requiredGovernanceVotes() == 0) revert InvalidFee();
        proposalId = keccak256(abi.encode(destinationChainId, feeBps, block.number));
        FeeProposal storage proposal = feeProposals[proposalId];
        if (proposal.destinationChainId != 0) revert ProposalAlreadyExecuted();
        proposal.destinationChainId = destinationChainId;
        proposal.feeBps = feeBps;
        proposal.voteCount = 1;
        feeProposalVoted[proposalId][msg.sender] = true;
        emit DestinationFeeProposalVoted(proposalId, msg.sender, 1);
        if (proposal.voteCount >= requiredGovernanceVotes()) _executeFeeProposal(proposalId);
    }

    function voteDestinationFeeBps(bytes32 proposalId) external onlyGovernanceEoa {
        FeeProposal storage proposal = feeProposals[proposalId];
        if (proposal.destinationChainId == 0 || proposal.executed) revert ProposalNotExecutable();
        if (feeProposalVoted[proposalId][msg.sender]) revert AlreadyVoted();
        feeProposalVoted[proposalId][msg.sender] = true;
        proposal.voteCount++;
        emit DestinationFeeProposalVoted(proposalId, msg.sender, proposal.voteCount);
        if (proposal.voteCount >= requiredGovernanceVotes()) _executeFeeProposal(proposalId);
    }

    function _executeFeeProposal(bytes32 proposalId) internal {
        FeeProposal storage proposal = feeProposals[proposalId];
        if (proposal.executed || proposal.voteCount < requiredGovernanceVotes()) {
            revert ProposalNotExecutable();
        }
        proposal.executed = true;
        destinationFeeBps[proposal.destinationChainId] = proposal.feeBps;
        emit DestinationFeeUpdated(proposal.destinationChainId, proposal.feeBps);
    }

    function initiateLockMint(
        uint256 destinationChainId,
        address sourceAsset,
        address destinationAsset,
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        bytes32 sourceTxHash,
        uint256 nonce
    ) external nonReentrant returns (bytes32 operationId) {
        return _initiateLockMint(
            destinationChainId, sourceAsset, destinationAsset, beneficiaries, amounts, sourceTxHash, nonce
        );
    }

    function _initiateLockMint(
        uint256 destinationChainId,
        address sourceAsset,
        address destinationAsset,
        address[] memory beneficiaries,
        uint256[] memory amounts,
        bytes32 sourceTxHash,
        uint256 nonce
    ) internal returns (bytes32 operationId) {
        AssetPolicy memory policy = _findPolicy(
            block.chainid, address(this), sourceAsset, destinationAsset, AssetMode.LockMint
        );
        if (!policy.enabled) revert PolicyNotEnabled();
        uint256 amount = _validateBeneficiaries(beneficiaries, amounts);
        uint256 fee = (amount * destinationFeeBps[destinationChainId]) / BPS_DENOMINATOR;
        if (fee > 0 && !IERC20BridgeV3(sourceAsset).transferFrom(msg.sender, address(this), fee)) {
            revert TransferFailed();
        }
        if (!IERC20BridgeV3(sourceAsset).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        operationId = _operationId(
            block.chainid, destinationChainId, address(this), sourceAsset, destinationAsset,
            beneficiaries, amounts, AssetMode.LockMint, amount, fee, sourceTxHash, nonce
        );
        if (operationInitiated[operationId]) revert OperationAlreadyUsed();
        operationInitiated[operationId] = true;
        emit BridgeOperation(
            operationId, block.chainid, destinationChainId, Phase.Initiated, AssetMode.LockMint,
            address(this), sourceAsset, destinationAsset, msg.sender, beneficiaries, amounts, amount, fee,
            amount, sourceTxHash, nonce
        );
    }

    /// @notice Starts a user burn/mint transfer for a Treasury-authorized source token.
    /// @dev The requested amount is burned in full; the fee is an additional transfer
    ///      retained by this Treasury. The destination mints the full requested amount
    ///      split across `beneficiaries` / `amounts`.
    function initiateBurnMintForUser(
        address sourceAsset,
        uint256 destinationChainId,
        address destinationAsset,
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        bytes32 sourceTxHash,
        uint256 nonce
    ) external nonReentrant returns (bytes32 operationId) {
        return _initiateBurnMintForUser(
            sourceAsset, destinationChainId, destinationAsset, beneficiaries, amounts, sourceTxHash, nonce
        );
    }

    function _initiateBurnMintForUser(
        address sourceAsset,
        uint256 destinationChainId,
        address destinationAsset,
        address[] memory beneficiaries,
        uint256[] memory amounts,
        bytes32 sourceTxHash,
        uint256 nonce
    ) internal returns (bytes32 operationId) {
        if (!authorizedBridgeAsset[sourceAsset]) revert AssetNotAuthorized();
        AssetPolicy memory policy = _findPolicy(
            block.chainid, address(this), sourceAsset, destinationAsset, AssetMode.BurnMint
        );
        if (!policy.enabled) revert PolicyNotEnabled();
        uint256 amount = _validateBeneficiaries(beneficiaries, amounts);
        uint256 fee = (amount * destinationFeeBps[destinationChainId]) / BPS_DENOMINATOR;
        if (fee > 0 && !IERC20BridgeV3(sourceAsset).transferFrom(msg.sender, address(this), fee)) {
            revert TransferFailed();
        }
        ITreasuryBridgeAssetV3(sourceAsset).burnFrom(msg.sender, amount);
        operationId = _operationId(
            block.chainid, destinationChainId, address(this), sourceAsset, destinationAsset,
            beneficiaries, amounts, AssetMode.BurnMint, amount, fee, sourceTxHash, nonce
        );
        if (operationInitiated[operationId]) revert OperationAlreadyUsed();
        operationInitiated[operationId] = true;
        emit BridgeOperation(
            operationId, block.chainid, destinationChainId, Phase.Initiated, AssetMode.BurnMint,
            address(this), sourceAsset, destinationAsset, msg.sender, beneficiaries, amounts, amount, fee,
            amount, sourceTxHash, nonce
        );
    }

    /// @notice Starts the reverse leg of a lock/mint route.
    /// @dev The canonical source token is burned in full, the additional fee is
    ///      retained by this Treasury, and the destination releases locked tokens
    ///      split across `beneficiaries` / `amounts`.
    function initiateBurnRelease(
        address sourceAsset,
        uint256 destinationChainId,
        address destinationAsset,
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        bytes32 sourceTxHash,
        uint256 nonce
    ) external nonReentrant returns (bytes32 operationId) {
        return _initiateBurnRelease(
            sourceAsset, destinationChainId, destinationAsset, beneficiaries, amounts, sourceTxHash, nonce
        );
    }

    function _initiateBurnRelease(
        address sourceAsset,
        uint256 destinationChainId,
        address destinationAsset,
        address[] memory beneficiaries,
        uint256[] memory amounts,
        bytes32 sourceTxHash,
        uint256 nonce
    ) internal returns (bytes32 operationId) {
        if (!authorizedBridgeAsset[sourceAsset]) revert AssetNotAuthorized();
        AssetPolicy memory policy = _findPolicy(
            block.chainid, address(this), sourceAsset, destinationAsset, AssetMode.BurnRelease
        );
        if (!policy.enabled) revert PolicyNotEnabled();
        uint256 amount = _validateBeneficiaries(beneficiaries, amounts);
        uint256 fee = (amount * destinationFeeBps[destinationChainId]) / BPS_DENOMINATOR;
        if (fee > 0 && !IERC20BridgeV3(sourceAsset).transferFrom(msg.sender, address(this), fee)) {
            revert TransferFailed();
        }
        ITreasuryBridgeAssetV3(sourceAsset).burnFrom(msg.sender, amount);
        operationId = _operationId(
            block.chainid, destinationChainId, address(this), sourceAsset, destinationAsset,
            beneficiaries, amounts, AssetMode.BurnRelease, amount, fee, sourceTxHash, nonce
        );
        if (operationInitiated[operationId]) revert OperationAlreadyUsed();
        operationInitiated[operationId] = true;
        emit BridgeOperation(
            operationId, block.chainid, destinationChainId, Phase.Initiated, AssetMode.BurnRelease,
            address(this), sourceAsset, destinationAsset, msg.sender, beneficiaries, amounts, amount, fee,
            amount, sourceTxHash, nonce
        );
    }

    function executeMint(
        bytes32 operationId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        address sourceTreasury,
        address sourceAsset,
        address destinationAsset,
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        AssetMode mode,
        uint256 grossAmount,
        uint256 feeAmount,
        bytes32 sourceTxHash,
        uint256 nonce,
        bytes[] calldata signatures
    ) external nonReentrant {
        _verifyAttestations(
            operationId, sourceChainId, destinationChainId, sourceTreasury, sourceAsset,
            destinationAsset, beneficiaries, amounts, mode, grossAmount, feeAmount, sourceTxHash, nonce, signatures
        );
        _consumeOperation(operationId);
        _distributeMint(destinationAsset, beneficiaries, amounts);
        emit BridgeOperation(
            operationId, sourceChainId, destinationChainId, Phase.Executed, mode,
            sourceTreasury, sourceAsset, destinationAsset, sourceTreasury, beneficiaries, amounts,
            grossAmount, feeAmount, grossAmount, sourceTxHash, nonce
        );
    }

    function executeRelease(
        bytes32 operationId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        address sourceTreasury,
        address sourceAsset,
        address destinationAsset,
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        uint256 grossAmount,
        uint256 feeAmount,
        bytes32 sourceTxHash,
        uint256 nonce,
        bytes[] calldata signatures
    ) external nonReentrant {
        _verifyAttestations(
            operationId, sourceChainId, destinationChainId, sourceTreasury, sourceAsset,
            destinationAsset, beneficiaries, amounts, AssetMode.BurnRelease, grossAmount, feeAmount,
            sourceTxHash, nonce, signatures
        );
        _consumeOperation(operationId);
        _distributeRelease(destinationAsset, beneficiaries, amounts);
        emit BridgeOperation(
            operationId, sourceChainId, destinationChainId, Phase.Executed, AssetMode.BurnRelease,
            sourceTreasury, sourceAsset, destinationAsset, sourceTreasury, beneficiaries, amounts,
            grossAmount, feeAmount, grossAmount, sourceTxHash, nonce
        );
    }

    /// @notice Cast a miner vote directly on the destination chain.
    /// @dev The miner reaching quorum executes the operation atomically.
    function voteBridgeOperation(
        bytes32 operationId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        address sourceTreasury,
        address sourceAsset,
        address destinationAsset,
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        AssetMode mode,
        uint256 grossAmount,
        uint256 feeAmount,
        bytes32 sourceTxHash,
        uint256 nonce
    ) external onlyMiner nonReentrant {
        _voteBridgeOperation(
            operationId, sourceChainId, destinationChainId, sourceTreasury, sourceAsset,
            destinationAsset, beneficiaries, amounts, mode, grossAmount, feeAmount, sourceTxHash, nonce
        );
    }

    function _voteBridgeOperation(
        bytes32 operationId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        address sourceTreasury,
        address sourceAsset,
        address destinationAsset,
        address[] memory beneficiaries,
        uint256[] memory amounts,
        AssetMode mode,
        uint256 grossAmount,
        uint256 feeAmount,
        bytes32 sourceTxHash,
        uint256 nonce
    ) internal {
        if (operationId == bytes32(0) || sourceChainId == block.chainid || destinationChainId != block.chainid) {
            revert InvalidPolicy();
        }
        if (operationExecuted[operationId]) revert OperationAlreadyUsed();
        if (grossAmount == 0 || feeAmount > grossAmount) revert InvalidAmount();
        if (_validateBeneficiaries(beneficiaries, amounts) != grossAmount) revert InvalidBeneficiaries();
        // The source chain is authoritative for the fee. Requiring the
        // destination's local fee table here would make valid operations fail
        // while the two chains are updated in different blocks.

        bytes32 routeId = keccak256(
            abi.encode(sourceChainId, sourceTreasury, sourceAsset, destinationAsset, mode)
        );
        AssetPolicy memory route = _policies[routeId];
        if (!route.enabled) revert PolicyNotEnabled();

        bytes32 payloadHash = _bridgeOperationPayloadHash(
            operationId, sourceChainId, destinationChainId, sourceTreasury, sourceAsset,
            destinationAsset, beneficiaries, amounts, mode, grossAmount, feeAmount, sourceTxHash, nonce
        );
        bytes32 storedPayloadHash = bridgeOperationPayloadHash[operationId];
        if (storedPayloadHash == bytes32(0)) {
            bridgeOperationPayloadHash[operationId] = payloadHash;
        } else if (storedPayloadHash != payloadHash) {
            revert InvalidPolicy();
        }
        if (bridgeOperationVoted[operationId][msg.sender]) revert AlreadyVoted();

        bridgeOperationVoted[operationId][msg.sender] = true;
        uint256 voteCount = ++bridgeOperationVoteCount[operationId];
        emit BridgeOperationVote(operationId, msg.sender, voteCount, requiredVotes());

        if (voteCount >= requiredVotes()) {
            _consumeOperation(operationId);
            if (mode == AssetMode.BurnMint || mode == AssetMode.LockMint) {
                _distributeMint(destinationAsset, beneficiaries, amounts);
            } else if (mode == AssetMode.BurnRelease) {
                _distributeRelease(destinationAsset, beneficiaries, amounts);
            } else {
                revert InvalidPolicy();
            }
            emit BridgeOperation(
                operationId, sourceChainId, destinationChainId, Phase.Executed, mode,
                sourceTreasury, sourceAsset, destinationAsset, sourceTreasury, beneficiaries, amounts,
                grossAmount, feeAmount, grossAmount, sourceTxHash, nonce
            );
        }
    }

    function _consumeOperation(bytes32 operationId) internal {
        if (operationExecuted[operationId]) revert OperationAlreadyUsed();
        operationExecuted[operationId] = true;
    }

    function _validateBeneficiaries(address[] memory beneficiaries, uint256[] memory amounts)
        internal
        pure
        returns (uint256 gross)
    {
        uint256 len = beneficiaries.length;
        if (len == 0 || len > MAX_BENEFICIARIES || len != amounts.length) revert InvalidBeneficiaries();
        for (uint256 i; i < len; ++i) {
            if (beneficiaries[i] == address(0) || amounts[i] == 0) revert InvalidBeneficiaries();
            gross += amounts[i];
        }
        if (gross == 0) revert InvalidAmount();
    }

    function _beneficiariesHash(address[] memory beneficiaries, uint256[] memory amounts)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(beneficiaries, amounts));
    }

    function _distributeMint(address asset, address[] memory beneficiaries, uint256[] memory amounts) internal {
        for (uint256 i; i < beneficiaries.length; ++i) {
            ITreasuryBridgeAssetV3(asset).mint(beneficiaries[i], amounts[i]);
        }
    }

    function _distributeRelease(address asset, address[] memory beneficiaries, uint256[] memory amounts) internal {
        for (uint256 i; i < beneficiaries.length; ++i) {
            if (!IERC20BridgeV3(asset).transfer(beneficiaries[i], amounts[i])) revert TransferFailed();
        }
    }

    function _bridgeOperationPayloadHash(
        bytes32 operationId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        address sourceTreasury,
        address sourceAsset,
        address destinationAsset,
        address[] memory beneficiaries,
        uint256[] memory amounts,
        AssetMode mode,
        uint256 grossAmount,
        uint256 feeAmount,
        bytes32 sourceTxHash,
        uint256 nonce
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                operationId, sourceChainId, destinationChainId, sourceTreasury, sourceAsset,
                destinationAsset, _beneficiariesHash(beneficiaries, amounts), mode, grossAmount, feeAmount,
                sourceTxHash, nonce
            )
        );
    }

    function _verifyAttestations(
        bytes32 operationId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        address sourceTreasury,
        address sourceAsset,
        address destinationAsset,
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        AssetMode mode,
        uint256 grossAmount,
        uint256 feeAmount,
        bytes32 sourceTxHash,
        uint256 nonce,
        bytes[] calldata signatures
    ) internal view {
        if (grossAmount == 0 || feeAmount > grossAmount) revert InvalidAmount();
        if (_validateBeneficiaries(beneficiaries, amounts) != grossAmount) revert InvalidBeneficiaries();
        bytes32 routeId = keccak256(
            abi.encode(sourceChainId, sourceTreasury, sourceAsset, destinationAsset, mode)
        );
        AssetPolicy memory route = _policies[routeId];
        if (!route.enabled) revert PolicyNotEnabled();
        if (signatures.length < requiredVotes()) revert InvalidQuorum();
        bytes32 structHash = keccak256(
            abi.encode(
                BRIDGE_ATTESTATION_TYPEHASH,
                operationId,
                sourceChainId,
                destinationChainId,
                sourceTreasury,
                sourceAsset,
                destinationAsset,
                _beneficiariesHash(beneficiaries, amounts),
                mode,
                grossAmount,
                feeAmount,
                sourceTxHash,
                nonce
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
        address lastSigner;
        for (uint256 i; i < signatures.length; ++i) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (!isMiner[signer] || signer <= lastSigner) revert InvalidSignature();
            lastSigner = signer;
        }
    }

    function _domainSeparatorV4() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("TreasuryBridgeV3"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function bridgeAttestationDigest(
        bytes32 operationId,
        uint256 sourceChainId,
        uint256 destinationChainId,
        address sourceTreasury,
        address sourceAsset,
        address destinationAsset,
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        AssetMode mode,
        uint256 grossAmount,
        uint256 feeAmount,
        bytes32 sourceTxHash,
        uint256 nonce
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                BRIDGE_ATTESTATION_TYPEHASH,
                operationId,
                sourceChainId,
                destinationChainId,
                sourceTreasury,
                sourceAsset,
                destinationAsset,
                _beneficiariesHash(beneficiaries, amounts),
                mode,
                grossAmount,
                feeAmount,
                sourceTxHash,
                nonce
            )
        );
        return MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
    }

    function _findPolicy(
        uint256 sourceChainId,
        address sourceTreasury,
        address sourceAsset,
        address destinationAsset,
        AssetMode mode
    ) internal view returns (AssetPolicy memory policy) {
        bytes32 id = keccak256(
            abi.encode(sourceChainId, sourceTreasury, sourceAsset, destinationAsset, mode)
        );
        policy = _policies[id];
        if (policy.sourceAsset == address(0)) revert PolicyNotFound();
    }

    function _validatePolicy(AssetPolicy calldata policy) internal pure {
        if (
            policy.sourceChainId == 0 || policy.sourceTreasury == address(0)
                || policy.sourceAsset == address(0) || policy.destinationAsset == address(0)
                || policy.decimals > 18
        ) revert InvalidPolicy();
    }

    function _operationId(
        uint256 sourceChainId,
        uint256 destinationChainId,
        address sourceTreasury,
        address sourceAsset,
        address destinationAsset,
        address[] memory beneficiaries,
        uint256[] memory amounts,
        AssetMode mode,
        uint256 grossAmount,
        uint256 feeAmount,
        bytes32 sourceTxHash,
        uint256 nonce
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                sourceChainId, destinationChainId, sourceTreasury, sourceAsset,
                destinationAsset, _beneficiariesHash(beneficiaries, amounts), mode, grossAmount, feeAmount,
                sourceTxHash, nonce
            )
        );
    }

    /// @dev Gap reduced by 2 for `feeSettlement` + `feeSettlementAsset`.
    uint256[35] private __gap;
}
