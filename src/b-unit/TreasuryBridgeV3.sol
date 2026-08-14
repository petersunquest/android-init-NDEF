// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ITreasuryGbPaidAdmin, ITreasuryBUnitPaidAdmin, ITreasuryEip3009} from "./ITreasuryAdminERC20.sol";

interface ITreasuryBridgeAssetV3 {
    function mint(address to, uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

interface IERC20BridgeV3 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Optional LockMint destination hook; Treasury is `msg.sender`.
interface ITreasuryBridgeMintCallback {
    function onBridgeMint(
        bytes32 operationId,
        uint256 sourceChainId,
        address destinationAsset,
        address[] calldata beneficiaries,
        uint256[] calldata amounts
    ) external;
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
    /// @notice Gas stipend for best-effort LockMint callback after mint.
    uint256 public constant MINT_CALLBACK_GAS = 200_000;
    /// @dev `beneficiariesHash = keccak256(abi.encode(beneficiaries, amounts))`.
    bytes32 public constant BRIDGE_ATTESTATION_TYPEHASH = keccak256(
        "BridgeAttestation(bytes32 operationId,uint256 sourceChainId,uint256 destinationChainId,address sourceTreasury,address sourceAsset,address destinationAsset,bytes32 beneficiariesHash,uint8 mode,uint256 grossAmount,uint256 feeAmount,bytes32 sourceTxHash,uint256 nonce,address callbackTarget)"
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
    /// @notice CoNET contracts allowed as LockMint `onBridgeMint` targets.
    mapping(address => bool) public allowedMintCallbacks;

    /// @notice How treasury calls mint/burn on a registered asset (offline-sign path).
    enum TreasuryAssetKind {
        None,
        /// @dev Canonical / developer ERC20: `mint` + admin `burnFrom`.
        Canonical,
        /// @dev GBToken paid pool: `mintPaid` + `burnPaidFrom`.
        GbPaid,
        /// @dev BUint paid pool: `mintPaid` + `consumePaidFuel`.
        BUnitPaid
    }

    enum TreasuryAssetOp {
        Mint,
        Burn
    }

    /// @dev `TreasuryAssetOp(address signer,address asset,uint8 op,address account,uint256 amount,uint256 nonce,uint256 deadline)`
    bytes32 public constant TREASURY_ASSET_OP_TYPEHASH = keccak256(
        "TreasuryAssetOp(address signer,address asset,uint8 op,address account,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    /// @dev Pay USDC (EIP-3009) into treasury then mint another managed asset (face amounts may differ).
    /// `PayAndMint(address signer,address paymentAsset,uint256 paymentAmount,address mintAsset,uint256 mintAmount,uint256 nonce,uint256 deadline)`
    bytes32 public constant PAY_AND_MINT_TYPEHASH = keccak256(
        "PayAndMint(address signer,address paymentAsset,uint256 paymentAmount,address mintAsset,uint256 mintAmount,uint256 nonce,uint256 deadline)"
    );

    /// @dev Offline initiate burn/mint (bridge). Beneficiaries bound via `beneficiariesHash`.
    bytes32 public constant INITIATE_BURN_MINT_TYPEHASH = keccak256(
        "InitiateBurnMint(address user,address sourceAsset,uint256 destinationChainId,address destinationAsset,bytes32 beneficiariesHash,bytes32 sourceTxHash,uint256 nonce,uint256 deadline)"
    );

    /// @dev Same-chain P2P via admin burn+mint (token need not support EIP-3009).
    /// `TransferViaMintBurn(address signer,address asset,address to,uint256 amount,uint256 nonce,uint256 deadline)`
    bytes32 public constant TRANSFER_VIA_MINT_BURN_TYPEHASH = keccak256(
        "TransferViaMintBurn(address signer,address asset,address to,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    mapping(address => TreasuryAssetKind) public treasuryAssetKind;
    mapping(address => uint256) public treasuryAssetOpNonces;

    /// @dev DeveloperFxIssuer — stake-gate + issue path (kept external for EIP-170).
    address public developerFxIssuer;

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
    event MintCallbackAllowed(address indexed target, bool allowed);
    event TreasuryAssetKindUpdated(address indexed asset, TreasuryAssetKind kind);
    event DeveloperFxIssuerUpdated(address indexed issuer);
    event TreasuryAssetOpExecuted(
        address indexed signer,
        address indexed asset,
        TreasuryAssetOp op,
        address indexed account,
        uint256 amount,
        uint256 nonce
    );
    event PayAndMintExecuted(
        address indexed signer,
        address indexed paymentAsset,
        uint256 paymentAmount,
        address mintAsset,
        uint256 mintAmount,
        uint256 nonce
    );
    event TransferViaMintBurnExecuted(
        address indexed from,
        address indexed asset,
        address indexed to,
        uint256 amount,
        uint256 nonce
    );
    event BridgeMintCallbackSucceeded(bytes32 indexed operationId, address indexed target);
    event BridgeMintCallbackFailed(bytes32 indexed operationId, address indexed target, bytes reason);
    event BridgeMintCallbackSkipped(bytes32 indexed operationId, address indexed target);
    event BridgeOperationVote(
        bytes32 indexed operationId,
        address indexed miner,
        uint256 voteCount,
        uint256 requiredVotes
    );

    /// @dev The only event miners need to scan on either chain.
    ///      `beneficiaries` / `amounts` are parallel arrays; `sum(amounts) == grossAmount`.
    ///      `callbackTarget` is set for LockMint hooks; otherwise `address(0)`.
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
        uint256 nonce,
        address callbackTarget
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
    error AssetNotManaged();
    error SignatureExpired();
    error InvalidUserSignature();
    error InvalidOpNonce();
    error DeveloperTokenUnqualified();

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

    /// @notice Allowlist a CoNET contract for LockMint `onBridgeMint` best-effort hooks.
    function setMintCallbackAllowed(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert InvalidPolicy();
        allowedMintCallbacks[target] = allowed;
        emit MintCallbackAllowed(target, allowed);
    }

    /// @notice Register how this treasury mints/burns `asset` for offline-sign relays.
    /// @dev ERC20 must already grant this treasury admin / TREASURY_ROLE / BRIDGE_ROLE.
    function setTreasuryAssetKind(address asset, TreasuryAssetKind kind) external onlyOwner {
        if (asset == address(0)) revert InvalidPolicy();
        treasuryAssetKind[asset] = kind;
        emit TreasuryAssetKindUpdated(asset, kind);
    }

    /// @notice Wire DeveloperFxIssuer (stake gate + issue+Settlement register).
    function setDeveloperFxIssuer(address issuer) external onlyOwner {
        if (issuer == address(0)) revert InvalidPolicy();
        developerFxIssuer = issuer;
        emit DeveloperFxIssuerUpdated(issuer);
    }

    /// @notice Called by DeveloperFxIssuer after a successful issue (marks asset Canonical).
    function setTreasuryAssetKindCanonical(address token) external {
        if (msg.sender != developerFxIssuer) revert InvalidPolicy();
        if (token == address(0)) revert InvalidPolicy();
        if (treasuryAssetKind[token] != TreasuryAssetKind.Canonical) {
            treasuryAssetKind[token] = TreasuryAssetKind.Canonical;
            emit TreasuryAssetKindUpdated(token, TreasuryAssetKind.Canonical);
        }
    }

    /**
     * @notice Whether treasury may forward mint/burn/bridge for `token`.
     * @dev Developer FX (marked on Issuer): live CNET stake must be ≥ Issuer min stake.
     */
    function isDeveloperFxForwardAllowed(address token) public view returns (bool) {
        address issuer = developerFxIssuer;
        if (issuer == address(0)) return true;
        (bool ok, bytes memory data) =
            issuer.staticcall(abi.encodeWithSignature("isForwardAllowed(address)", token));
        return ok && data.length >= 32 && abi.decode(data, (bool));
    }

    /**
     * @notice Registry-only: mint Canonical developer FX after burning paid GB (no Registry mint role).
     * @dev `msg.sender` must be DeveloperFxIssuer.registry(); Canonical sees mint from this treasury.
     */
    function mintDeveloperFxFromRegistry(address token, address to, uint256 amount) external nonReentrant {
        if (token == address(0) || to == address(0) || amount == 0) revert InvalidPolicy();
        address issuer = developerFxIssuer;
        if (issuer == address(0)) revert InvalidPolicy();
        (bool ok, bytes memory data) = issuer.staticcall(abi.encodeWithSignature("registry()"));
        if (!ok || data.length < 32) revert InvalidPolicy();
        address reg = abi.decode(data, (address));
        if (msg.sender != reg) revert InvalidPolicy();
        if (treasuryAssetKind[token] != TreasuryAssetKind.Canonical) revert AssetNotManaged();
        _requireDeveloperFxQualified(token);
        ITreasuryBridgeAssetV3(token).mint(to, amount);
    }

    /// @notice Relayer-paid mint or burn: user signs EIP-712; treasury executes as token admin.
    /// @param op Mint → credit `account`; Burn → debit `account` (signer must equal `account`).
    function executeTreasuryAssetOpWithSignature(
        address signer,
        address asset,
        TreasuryAssetOp op,
        address account,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _verifyTreasuryAssetOp(signer, asset, op, account, amount, nonce, deadline, signature);
        _executeManagedAssetOp(asset, op, account, amount);
        emit TreasuryAssetOpExecuted(signer, asset, op, account, amount, nonce);
    }

    /// @notice Relayer-paid: pull `paymentAmount` via EIP-3009 into this treasury, then mint `mintAmount`.
    /// @dev User signs both EIP-3009 (paymentAsset → treasury) and PayAndMint (treasury domain).
    function payAndMintWithSignature(
        address signer,
        address paymentAsset,
        uint256 paymentAmount,
        address mintAsset,
        uint256 mintAmount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 paymentNonce,
        bytes calldata paymentSignature,
        uint256 opNonce,
        uint256 deadline,
        bytes calldata opSignature
    ) external nonReentrant {
        if (signer == address(0) || paymentAsset == address(0) || mintAsset == address(0)) {
            revert InvalidPolicy();
        }
        if (paymentAmount == 0 || mintAmount == 0) revert InvalidAmount();
        if (block.timestamp > deadline) revert SignatureExpired();
        if (treasuryAssetOpNonces[signer] != opNonce) revert InvalidOpNonce();
        if (treasuryAssetKind[mintAsset] == TreasuryAssetKind.None) revert AssetNotManaged();

        bytes32 structHash = keccak256(
            abi.encode(
                PAY_AND_MINT_TYPEHASH,
                signer,
                paymentAsset,
                paymentAmount,
                mintAsset,
                mintAmount,
                opNonce,
                deadline
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
        if (ECDSA.recover(digest, opSignature) != signer) revert InvalidUserSignature();
        treasuryAssetOpNonces[signer] = opNonce + 1;

        ITreasuryEip3009(paymentAsset).transferWithAuthorization(
            signer,
            address(this),
            paymentAmount,
            validAfter,
            validBefore,
            paymentNonce,
            paymentSignature
        );
        _executeManagedAssetOp(mintAsset, TreasuryAssetOp.Mint, signer, mintAmount);
        emit PayAndMintExecuted(signer, paymentAsset, paymentAmount, mintAsset, mintAmount, opNonce);
    }

    /// @notice Relayer-paid P2P: burn `amount` from signer, mint same amount to `to` (treasury as token admin).
    /// @dev Asset need not support EIP-3009; must be registered via `setTreasuryAssetKind`.
    function transferViaMintBurnWithSignature(
        address signer,
        address asset,
        address to,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        if (signer == address(0) || asset == address(0) || to == address(0)) revert InvalidPolicy();
        if (to == signer) revert InvalidPolicy();
        if (amount == 0) revert InvalidAmount();
        if (block.timestamp > deadline) revert SignatureExpired();
        if (treasuryAssetOpNonces[signer] != nonce) revert InvalidOpNonce();
        if (treasuryAssetKind[asset] == TreasuryAssetKind.None) revert AssetNotManaged();

        bytes32 structHash = keccak256(
            abi.encode(TRANSFER_VIA_MINT_BURN_TYPEHASH, signer, asset, to, amount, nonce, deadline)
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
        if (ECDSA.recover(digest, signature) != signer) revert InvalidUserSignature();
        treasuryAssetOpNonces[signer] = nonce + 1;

        _executeManagedAssetOp(asset, TreasuryAssetOp.Burn, signer, amount);
        _executeManagedAssetOp(asset, TreasuryAssetOp.Mint, to, amount);
        emit TransferViaMintBurnExecuted(signer, asset, to, amount, nonce);
    }

    /// @notice Same as `initiateBurnMintForUser` but user signs offline; relayer pays gas.
    /// @dev Digest binds full bridge initiate payload via INITIATE_BURN_MINT_TYPEHASH.
    function initiateBurnMintForUserWithSignature(
        address user,
        address sourceAsset,
        uint256 destinationChainId,
        address destinationAsset,
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        bytes32 sourceTxHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant returns (bytes32 operationId) {
        if (user == address(0)) revert InvalidPolicy();
        if (block.timestamp > deadline) revert SignatureExpired();
        _verifyInitiateBurnMintSig(
            user,
            sourceAsset,
            destinationChainId,
            destinationAsset,
            beneficiaries,
            amounts,
            sourceTxHash,
            nonce,
            deadline,
            signature
        );
        return _initiateBurnMintForUserFrom(
            user, sourceAsset, destinationChainId, destinationAsset, beneficiaries, amounts, sourceTxHash, nonce
        );
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
            destinationChainId, sourceAsset, destinationAsset, beneficiaries, amounts, sourceTxHash, nonce,
            address(0)
        );
    }

    /// @param callbackTarget Optional CoNET contract for post-mint `onBridgeMint` (must be allowlisted on dest).
    function initiateLockMint(
        uint256 destinationChainId,
        address sourceAsset,
        address destinationAsset,
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        bytes32 sourceTxHash,
        uint256 nonce,
        address callbackTarget
    ) external nonReentrant returns (bytes32 operationId) {
        return _initiateLockMint(
            destinationChainId, sourceAsset, destinationAsset, beneficiaries, amounts, sourceTxHash, nonce,
            callbackTarget
        );
    }

    function _initiateLockMint(
        uint256 destinationChainId,
        address sourceAsset,
        address destinationAsset,
        address[] memory beneficiaries,
        uint256[] memory amounts,
        bytes32 sourceTxHash,
        uint256 nonce,
        address callbackTarget
    ) internal returns (bytes32 operationId) {
        _requireDeveloperFxQualified(sourceAsset);
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
            beneficiaries, amounts, AssetMode.LockMint, amount, fee, sourceTxHash, nonce, callbackTarget
        );
        if (operationInitiated[operationId]) revert OperationAlreadyUsed();
        operationInitiated[operationId] = true;
        emit BridgeOperation(
            operationId, block.chainid, destinationChainId, Phase.Initiated, AssetMode.LockMint,
            address(this), sourceAsset, destinationAsset, msg.sender, beneficiaries, amounts, amount, fee,
            amount, sourceTxHash, nonce, callbackTarget
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
        return _initiateBurnMintForUserFrom(
            msg.sender, sourceAsset, destinationChainId, destinationAsset, beneficiaries, amounts, sourceTxHash, nonce
        );
    }

    function _initiateBurnMintForUserFrom(
        address user,
        address sourceAsset,
        uint256 destinationChainId,
        address destinationAsset,
        address[] memory beneficiaries,
        uint256[] memory amounts,
        bytes32 sourceTxHash,
        uint256 nonce
    ) internal returns (bytes32 operationId) {
        if (!authorizedBridgeAsset[sourceAsset]) revert AssetNotAuthorized();
        _requireDeveloperFxQualified(sourceAsset);
        AssetPolicy memory policy = _findPolicy(
            block.chainid, address(this), sourceAsset, destinationAsset, AssetMode.BurnMint
        );
        if (!policy.enabled) revert PolicyNotEnabled();
        uint256 amount = _validateBeneficiaries(beneficiaries, amounts);
        uint256 fee = (amount * destinationFeeBps[destinationChainId]) / BPS_DENOMINATOR;
        if (fee > 0 && !IERC20BridgeV3(sourceAsset).transferFrom(user, address(this), fee)) {
            revert TransferFailed();
        }
        ITreasuryBridgeAssetV3(sourceAsset).burnFrom(user, amount);
        operationId = _operationId(
            block.chainid, destinationChainId, address(this), sourceAsset, destinationAsset,
            beneficiaries, amounts, AssetMode.BurnMint, amount, fee, sourceTxHash, nonce, address(0)
        );
        if (operationInitiated[operationId]) revert OperationAlreadyUsed();
        operationInitiated[operationId] = true;
        emit BridgeOperation(
            operationId, block.chainid, destinationChainId, Phase.Initiated, AssetMode.BurnMint,
            address(this), sourceAsset, destinationAsset, user, beneficiaries, amounts, amount, fee,
            amount, sourceTxHash, nonce, address(0)
        );
    }

    /// @notice Starts the reverse leg of a lock/mint route.
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
        _requireDeveloperFxQualified(sourceAsset);
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
            beneficiaries, amounts, AssetMode.BurnRelease, amount, fee, sourceTxHash, nonce, address(0)
        );
        if (operationInitiated[operationId]) revert OperationAlreadyUsed();
        operationInitiated[operationId] = true;
        emit BridgeOperation(
            operationId, block.chainid, destinationChainId, Phase.Initiated, AssetMode.BurnRelease,
            address(this), sourceAsset, destinationAsset, msg.sender, beneficiaries, amounts, amount, fee,
            amount, sourceTxHash, nonce, address(0)
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
        address callbackTarget,
        bytes[] calldata signatures
    ) external nonReentrant {
        _verifyAttestations(
            operationId, sourceChainId, destinationChainId, sourceTreasury, sourceAsset,
            destinationAsset, beneficiaries, amounts, mode, grossAmount, feeAmount, sourceTxHash, nonce,
            callbackTarget, signatures
        );
        _consumeOperation(operationId);
        _distributeMint(destinationAsset, beneficiaries, amounts);
        emit BridgeOperation(
            operationId, sourceChainId, destinationChainId, Phase.Executed, mode,
            sourceTreasury, sourceAsset, destinationAsset, sourceTreasury, beneficiaries, amounts,
            grossAmount, feeAmount, grossAmount, sourceTxHash, nonce, callbackTarget
        );
        if (mode == AssetMode.LockMint) {
            _tryMintCallback(operationId, sourceChainId, destinationAsset, beneficiaries, amounts, callbackTarget);
        }
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
            sourceTxHash, nonce, address(0), signatures
        );
        _consumeOperation(operationId);
        _distributeRelease(destinationAsset, beneficiaries, amounts);
        emit BridgeOperation(
            operationId, sourceChainId, destinationChainId, Phase.Executed, AssetMode.BurnRelease,
            sourceTreasury, sourceAsset, destinationAsset, sourceTreasury, beneficiaries, amounts,
            grossAmount, feeAmount, grossAmount, sourceTxHash, nonce, address(0)
        );
    }

    /// @notice Cast a miner vote directly on the destination chain.
    /// @dev Quorum-final vote mints/releases then best-effort LockMint callback.
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
        uint256 nonce,
        address callbackTarget
    ) external onlyMiner nonReentrant {
        _voteBridgeOperation(
            operationId, sourceChainId, destinationChainId, sourceTreasury, sourceAsset,
            destinationAsset, beneficiaries, amounts, mode, grossAmount, feeAmount, sourceTxHash, nonce,
            callbackTarget
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
        uint256 nonce,
        address callbackTarget
    ) internal {
        if (operationId == bytes32(0) || sourceChainId == block.chainid || destinationChainId != block.chainid) {
            revert InvalidPolicy();
        }
        if (operationExecuted[operationId]) revert OperationAlreadyUsed();
        if (grossAmount == 0 || feeAmount > grossAmount) revert InvalidAmount();
        if (_validateBeneficiaries(beneficiaries, amounts) != grossAmount) revert InvalidBeneficiaries();
        if (callbackTarget != address(0) && mode != AssetMode.LockMint) revert InvalidPolicy();

        bytes32 routeId = keccak256(
            abi.encode(sourceChainId, sourceTreasury, sourceAsset, destinationAsset, mode)
        );
        AssetPolicy memory route = _policies[routeId];
        if (!route.enabled) revert PolicyNotEnabled();

        bytes32 payloadHash = _bridgeOperationPayloadHash(
            operationId, sourceChainId, destinationChainId, sourceTreasury, sourceAsset,
            destinationAsset, beneficiaries, amounts, mode, grossAmount, feeAmount, sourceTxHash, nonce,
            callbackTarget
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
                grossAmount, feeAmount, grossAmount, sourceTxHash, nonce, callbackTarget
            );
            if (mode == AssetMode.LockMint) {
                _tryMintCallback(
                    operationId, sourceChainId, destinationAsset, beneficiaries, amounts, callbackTarget
                );
            }
        }
    }

    /// @dev Mint already succeeded; callback failures must not revert the bridge op.
    function _tryMintCallback(
        bytes32 operationId,
        uint256 sourceChainId,
        address destinationAsset,
        address[] memory beneficiaries,
        uint256[] memory amounts,
        address callbackTarget
    ) internal {
        if (callbackTarget == address(0)) return;
        if (!allowedMintCallbacks[callbackTarget]) {
            emit BridgeMintCallbackSkipped(operationId, callbackTarget);
            return;
        }
        try ITreasuryBridgeMintCallback(callbackTarget).onBridgeMint{gas: MINT_CALLBACK_GAS}(
            operationId, sourceChainId, destinationAsset, beneficiaries, amounts
        ) {
            emit BridgeMintCallbackSucceeded(operationId, callbackTarget);
        } catch (bytes memory reason) {
            emit BridgeMintCallbackFailed(operationId, callbackTarget, reason);
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
        uint256 nonce,
        address callbackTarget
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                operationId, sourceChainId, destinationChainId, sourceTreasury, sourceAsset,
                destinationAsset, _beneficiariesHash(beneficiaries, amounts), mode, grossAmount, feeAmount,
                sourceTxHash, nonce, callbackTarget
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
        address callbackTarget,
        bytes[] calldata signatures
    ) internal view {
        if (grossAmount == 0 || feeAmount > grossAmount) revert InvalidAmount();
        if (_validateBeneficiaries(beneficiaries, amounts) != grossAmount) revert InvalidBeneficiaries();
        if (callbackTarget != address(0) && mode != AssetMode.LockMint) revert InvalidPolicy();
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
                nonce,
                callbackTarget
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

    function _verifyTreasuryAssetOp(
        address signer,
        address asset,
        TreasuryAssetOp op,
        address account,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (signer == address(0) || asset == address(0) || account == address(0)) revert InvalidPolicy();
        if (amount == 0) revert InvalidAmount();
        if (block.timestamp > deadline) revert SignatureExpired();
        if (treasuryAssetOpNonces[signer] != nonce) revert InvalidOpNonce();
        if (treasuryAssetKind[asset] == TreasuryAssetKind.None) revert AssetNotManaged();
        if (op == TreasuryAssetOp.Burn && signer != account) revert InvalidUserSignature();

        bytes32 structHash = keccak256(
            abi.encode(TREASURY_ASSET_OP_TYPEHASH, signer, asset, uint8(op), account, amount, nonce, deadline)
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
        if (ECDSA.recover(digest, signature) != signer) revert InvalidUserSignature();
        treasuryAssetOpNonces[signer] = nonce + 1;
    }

    function _verifyInitiateBurnMintSig(
        address user,
        address sourceAsset,
        uint256 destinationChainId,
        address destinationAsset,
        address[] calldata beneficiaries,
        uint256[] calldata amounts,
        bytes32 sourceTxHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                INITIATE_BURN_MINT_TYPEHASH,
                user,
                sourceAsset,
                destinationChainId,
                destinationAsset,
                _beneficiariesHash(beneficiaries, amounts),
                sourceTxHash,
                nonce,
                deadline
            )
        );
        bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
        if (ECDSA.recover(digest, signature) != user) revert InvalidUserSignature();
    }

    function _requireDeveloperFxQualified(address asset) internal view {
        if (!isDeveloperFxForwardAllowed(asset)) revert DeveloperTokenUnqualified();
    }

    function _executeManagedAssetOp(
        address asset,
        TreasuryAssetOp op,
        address account,
        uint256 amount
    ) internal {
        TreasuryAssetKind kind = treasuryAssetKind[asset];
        if (kind == TreasuryAssetKind.None) revert AssetNotManaged();
        if (kind == TreasuryAssetKind.Canonical) {
            _requireDeveloperFxQualified(asset);
        }

        if (op == TreasuryAssetOp.Mint) {
            if (kind == TreasuryAssetKind.Canonical) {
                ITreasuryBridgeAssetV3(asset).mint(account, amount);
            } else if (kind == TreasuryAssetKind.GbPaid) {
                ITreasuryGbPaidAdmin(asset).mintPaid(account, amount);
            } else if (kind == TreasuryAssetKind.BUnitPaid) {
                ITreasuryBUnitPaidAdmin(asset).mintPaid(account, amount);
            } else {
                revert AssetNotManaged();
            }
            return;
        }

        // Burn
        if (kind == TreasuryAssetKind.Canonical) {
            ITreasuryBridgeAssetV3(asset).burnFrom(account, amount);
        } else if (kind == TreasuryAssetKind.GbPaid) {
            ITreasuryGbPaidAdmin(asset).burnPaidFrom(account, amount);
        } else if (kind == TreasuryAssetKind.BUnitPaid) {
            ITreasuryBUnitPaidAdmin(asset).consumePaidFuel(account, amount);
        } else {
            revert AssetNotManaged();
        }
    }

    /// @notice EIP-712 digest helpers for wallets / relayers.
    function getTreasuryAssetOpDigest(
        address signer,
        address asset,
        TreasuryAssetOp op,
        address account,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(TREASURY_ASSET_OP_TYPEHASH, signer, asset, uint8(op), account, amount, nonce, deadline)
        );
        return MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
    }

    function getPayAndMintDigest(
        address signer,
        address paymentAsset,
        uint256 paymentAmount,
        address mintAsset,
        uint256 mintAmount,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                PAY_AND_MINT_TYPEHASH,
                signer,
                paymentAsset,
                paymentAmount,
                mintAsset,
                mintAmount,
                nonce,
                deadline
            )
        );
        return MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
    }

    function getTransferViaMintBurnDigest(
        address signer,
        address asset,
        address to,
        uint256 amount,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(TRANSFER_VIA_MINT_BURN_TYPEHASH, signer, asset, to, amount, nonce, deadline)
        );
        return MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), structHash);
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
        uint256 nonce,
        address callbackTarget
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
                nonce,
                callbackTarget
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
        uint256 nonce,
        address callbackTarget
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                sourceChainId, destinationChainId, sourceTreasury, sourceAsset,
                destinationAsset, _beneficiariesHash(beneficiaries, amounts), mode, grossAmount, feeAmount,
                sourceTxHash, nonce, callbackTarget
            )
        );
    }

    /// @dev Gap after developerFxIssuer (append-only).
    uint256[31] private __gap;
}

