// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";
import {
    ValidatorDepositRedeemStatsLib,
    UnifiedIncomeStats
} from "./ValidatorDepositRedeemStatsLib.sol";
import {ValidatorDepositRedeemRewardLib} from "./ValidatorDepositRedeemRewardLib.sol";
import {ValidatorDepositRedeemBundleLib} from "./ValidatorDepositRedeemBundleLib.sol";
import {NodeBundle, AirdropState, ValidatorBinding} from "./ValidatorDepositRedeemTypes.sol";
import {ValidatorDepositRedeemTransferLib} from "./ValidatorDepositRedeemTransferLib.sol";
import {ValidatorDepositRedeemDepositLib} from "./ValidatorDepositRedeemDepositLib.sol";
import {ValidatorDepositRedeemExitLib} from "./ValidatorDepositRedeemExitLib.sol";

/// @dev Minimal balance interface for the CoNET USDC ERC20 token.
interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @dev Read-only slice of the transfer market (node listing guard, keyed by Guardian node id).
interface IValidatorDepositRedeemTransferMarket {
    function nodeOrder(uint256 guardianId) external view returns (uint256);
}

/// @dev Minimal balance interface for the CoNET GB ERC1155 token (ConetGB1155).
interface IERC1155Balance {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @dev Read-only slice of GuardianNodesInfoV6 used for auto node allocation.
interface IGuardianNodesInfoV6 {
    function id2ip(uint256 id) external view returns (string memory);
    function idOwner(uint256 id) external view returns (address);
    function ipaddressExisting(string memory ipaddress) external view returns (bool);
    function ipaddress2owner(string memory ipaddress) external view returns (address);
}

/// @dev Standard ETH2 beacon deposit contract (CoNET L1 0x4242…4242). This contract is the depositor and the
///      sole 0x01 withdrawal target so exited 32-CNET principal always returns to this contract for custody.
interface IBeaconDeposit {
    function deposit(
        bytes calldata pubkey,
        bytes calldata withdrawal_credentials,
        bytes calldata signature,
        bytes32 deposit_data_root
    ) external payable;
}

/// @dev Referrer extension (separate contract for EIP-170 size).
interface IValidatorDepositRedeemReferrerExtension {
    function REFERRER_NODES_PER_REWARD() external view returns (uint256);
    function referrerOfBeneficiary(address beneficiary) external view returns (address);
    function referrerReferralNodeTotal(address referrer) external view returns (uint256);
    function referrerRewardMilestonePaid(address referrer) external view returns (uint256);
    function onBeneficiaryClaim(address beneficiary, address referrer, uint256 validatorCountFromClaim)
        external
        returns (uint256 rewardNodesToGrant);
    function getReferrerReferredBeneficiaryCount(address referrer) external view returns (uint256);
    function getReferrerReferredBeneficiaries(address referrer, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory);
}

/**
 * @title ValidatorDepositRedeem
 * @notice Admin issues one-time redeem codes that authorize a specific validator node IP to add validators.
 * @dev The contract does not custody funds or run deposits. Local geth/beacon/validator nodes listen for
 *      ValidatorRedeemClaimed and execute the node-local workflow with their own dedicated deposit key file.
 *      In addition, every successful claim accrues per-beneficiary ownership state (validator node count,
 *      GB mining node count and the CoNET DePIN node IP list) so a wallet can be queried for its node profile
 *      alongside live CoNET native, GB and USDC balances via {getWalletNodeProfile}.
 */
contract ValidatorDepositRedeem is Initializable, UUPSUpgradeable {
    uint256 private constant _MAX_REDEEM_CODE_LEN = 512;
    uint256 private constant _MAX_IP_LEN = 64;

    bytes32 private constant _EIP712_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("ValidatorDepositRedeem");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("1");
    bytes32 private _eip712CachedChainId;
    bytes32 private _eip712CachedSeparator;

    /// @notice GB net-total token id on ConetGB1155 (id=0 is cumulative net GB, 18 decimals).
    uint256 public constant CONET_GB_TOTAL_TOKEN_ID = 0;

    mapping(address => bool) public redeemAdmins;
    mapping(address => uint256) public redeemAdminNonces;
    /// @notice Contract admins — sole role allowed to call {withdrawNative} / {withdrawNativeBatch} (not redeem admins).
    mapping(address => bool) public admins;
    /// @notice Per-account EIP-712 nonce for {transferNodes} and transfer-order create/cancel/fulfill signatures.
    mapping(address => uint256) public beneficiaryNonces;

    // ---- CNET airdrop (accrued on airdrop-flagged redeem claims; paid from this contract's CNET balance) -----
    /// @notice CNET granted per validator node on an airdrop-flagged claim (18 decimals).
    uint256 public constant AIRDROP_CNET_PER_NODE = 100 ether;
    /// @notice Linear vesting window for accrued CNET airdrops: tokens unlock linearly from {airdropClaimableAt}
    ///         over this duration (6 months = 180 days). Before the start nothing is claimable; after start + this
    ///         duration the full accrued amount is claimable. Fixed protocol constant (kept internal for EIP-170;
    ///         clients render the 180-day schedule against the on-chain {airdropClaimableAt} start).
    uint64 internal constant AIRDROP_VESTING_DURATION = 180 days;
    /// @dev Airdrop ledger; claim/settle logic lives in {ValidatorDepositRedeemStatsLib} (EIP-170 offload).
    AirdropState private _air;

    /// @notice CoNET GB ERC1155 token (ConetGB1155); GB balance is read at id {CONET_GB_TOTAL_TOKEN_ID}.
    IERC1155Balance public gbToken;
    /// @notice CoNET USDC ERC20 token (ConetTreasury FactoryERC20).
    IERC20Balance public usdcToken;

    /// @notice Per-beneficiary cumulative validator node count claimed through this contract.
    mapping(address => uint256) public validatorNodeCountOf;
    /// @notice Per-beneficiary cumulative GB mining node count claimed through this contract.
    mapping(address => uint256) public gbMiningNodeCountOf;
    /// @notice Per-beneficiary number of successful redeem claims.
    mapping(address => uint256) public walletClaimCountOf;
    /// @dev Per-beneficiary, deduplicated CoNET DePIN node IP list accrued across claims.
    mapping(address => string[]) private _walletDepinNodeIps;
    /// @dev Per-beneficiary seen marker (keccak of normalized IP) to keep the IP list unique.
    mapping(address => mapping(bytes32 => bool)) private _walletDepinIpSeen;
    /// @dev CoNET DePIN node IP (keccak of the stored IP string) => beneficiary. Permanent 1:1: an IP can
    ///      only ever belong to a single beneficiary (a node cannot have two beneficiaries).
    mapping(bytes32 => address) private _depinIpBeneficiary;
    /// @dev Node operator wallet (Guardian idOwner) => beneficiary. Set on first allocation; an operator
    ///      wallet maps to the beneficiary of the first Guardian node assigned under it. Reverse lookup helper.
    mapping(address => address) private _nodeWalletBeneficiary;

    /// @notice GuardianNodesInfoV6 — source of truth for node id / IP / node wallet.
    IGuardianNodesInfoV6 public guardianNodes;
    /// @notice First Guardian node id eligible for auto allocation (e.g. 100).
    uint256 public guardianAllocStartId;
    /// @notice Next Guardian node id to assign on auto-allocate claim (monotonic, no skip).
    uint256 public nextGuardianAllocId;
    /// @dev Guardian node id => beneficiary; permanent once set (no beneficiary revoke).
    mapping(uint256 => address) public guardianIdBeneficiary;
    /// @dev Guardian node id => participates in GB mining (first {gbMiningNodeCount} ids per claim batch).
    mapping(uint256 => bool) public guardianIdGbMining;
    /// @dev Per-beneficiary Guardian node ids assigned via auto allocation (append-only).
    mapping(address => uint256[]) private _beneficiaryGuardianIds;
    /// @dev Guardian node ids granted to a referrer as milestone rewards (append-only).
    mapping(address => uint256[]) private _referrerRewardGuardianIds;
    /// @dev Parallel node operator wallets (Guardian idOwner) for {_beneficiaryGuardianIds}.
    mapping(address => address[]) private _beneficiaryGuardianNodeWallets;

    /// @notice A deployed validator bound to a single Guardian node id (1:1). The validator pubkey is the
    ///         identity used for a future exit / withdrawal; {withdrawalBeneficiary} is the current withdrawal
    ///         target. The (Guardian node id + validator) pair is the transferable unit. Binding is keyed by
    ///         Guardian node id (NOT operator wallet) so multiple nodes owned by the same operator EOA each
    ///         carry their own distinct validator.
    /// @dev Guardian node id => its current validator binding (1:1).
    mapping(uint256 => ValidatorBinding) private _nodeValidator;
    /// @dev keccak256(validator pubkey) => Guardian node id (reverse lookup; permanent identity). 0 = unbound
    ///      (Guardian ids start at {guardianAllocStartId} >= 1, so 0 is a safe sentinel).
    mapping(bytes32 => uint256) private _validatorPubkeyGuardian;

    // ---- Staking custody (CoNET L1) --------------------------------------------------------------------
    /// @notice CoNET L1 beacon deposit contract (0x4242…4242). This contract is the depositor + 0x01 target.
    IBeaconDeposit public depositContract;
    /// @notice Native CNET staked per validator (ETH2 standard 32).
    uint256 public constant VALIDATOR_STAKE_WEI = 32 ether;
    /// @notice Per-beneficiary count of currently staked validators funded by this contract.
    mapping(address => uint256) public stakedValidatorCountOf;
    /// @notice Cumulative native CNET principal this contract has deposited into the beacon contract.
    uint256 public fundedDepositTotal;
    /// @dev keccak256(validator pubkey) => true once its 32-CNET principal has been paid out on full exit
    ///      (replay guard: the auto-returned 32 from the beacon chain must never trigger a second payout).
    mapping(bytes32 => bool) public exitSettledPubkey;

    /// @notice Global count of validators currently staked via {fundAndDepositValidators} (principal reserve guard).
    uint256 public totalStakedValidatorCount;
    /// @notice Cumulative CL skim rewards paid to beneficiaries via {settleNodeRewards}.
    uint256 public totalRewardPaid;
    /// @notice Per-beneficiary cumulative CL skim paid via {settleNodeRewards}.
    mapping(address => uint256) public clRewardPaid;
    /// @dev Listener-supplied idempotency keys for {settleNodeRewards} (mirrors RewardIndexer eventKey dedup).
    mapping(bytes32 => bool) public consumedRewardEventKey;

    /// @notice Companion contract holding the per-node / per-beneficiary hourly CNET reward ledger and
    ///         day/week/month/year period statistics (BeamioIndexerDiamond-style). Kept OUT of this contract
    ///         to stay within the EVM contract size limit. Dashboards read it directly via RPC.
    address public rewardIndexer;

    /// @notice Referrer ledger extension (deploy separately; keeps this contract under EIP-170).
    IValidatorDepositRedeemReferrerExtension public referrerExtension;

    /// @notice Transfer-order marketplace (deploy separately; EIP-712 domain name matches this contract).
    address public transferMarket;

    /// @dev All redeems are Guardian auto-allocated: DePIN node IPs + node wallets are resolved from
    ///      GuardianNodesInfoV6 by consecutive node id at claim time (no manual IP list, no revoke).
    struct Redeem {
        address allowedClaimer;
        address referrer;
        uint128 validatorCount;
        uint128 gbMiningNodeCount;
        uint64 validAfter;
        uint64 validBefore;
        bool active;
        bool consumed;
        /// @dev When true, claiming this redeem accrues a CNET airdrop entitlement of
        ///      {AIRDROP_CNET_PER_NODE} * validatorCount to the beneficiary, vesting linearly over
        ///      {AIRDROP_VESTING_DURATION} from {airdropClaimableAt}.
        bool airdrop;
        string targetNodeIp;
    }

    mapping(bytes32 => Redeem) private _redeems;

    /// @dev See {NodeBundle} in ValidatorDepositRedeemTypes.sol (shared with stats library).

    bytes32 private constant CREATE_REDEEM_TYPEHASH = keccak256(
        "CreateRedeem(address admin,bytes32 codeHash,address allowedClaimer,address referrer,uint256 validatorCount,string targetNodeIp,uint256 gbMiningNodeCount,bool airdrop,uint256 validAfter,uint256 validBefore,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant CANCEL_REDEEM_TYPEHASH =
        keccak256("CancelRedeem(address admin,bytes32 codeHash,uint256 nonce,uint256 deadline)");
    bytes32 private constant ADD_REDEEM_ADMIN_TYPEHASH =
        keccak256("AddRedeemAdmin(address admin,address account,uint256 nonce,uint256 deadline)");
    bytes32 private constant REMOVE_REDEEM_ADMIN_TYPEHASH =
        keccak256("RemoveRedeemAdmin(address admin,address account,uint256 nonce,uint256 deadline)");
    bytes32 private constant CLAIM_REDEEM_TYPEHASH = keccak256(
        "ClaimRedeem(address claimer,bytes32 codeHash,address beneficiary,address referrer,uint256 validatorCount,string targetNodeIp,uint256 gbMiningNodeCount,uint256 deadline)"
    );
    bytes32 private constant REGISTER_NODE_VALIDATORS_TYPEHASH = keccak256(
        "RegisterNodeValidators(address admin,bytes32 guardianIdsHash,bytes32 pubkeysHash,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant TRANSFER_NODES_TYPEHASH = keccak256(
        "TransferNodes(address fromBeneficiary,address toBeneficiary,uint256[] guardianIds,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant REQUEST_FULL_EXIT_TYPEHASH = keccak256(
        "RequestFullExit(address beneficiary,uint256[] guardianIds,uint256 nonce,uint256 deadline)"
    );

    event RedeemAdminAdded(address indexed account);
    event RedeemAdminRemoved(address indexed account);
    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);
    event TokensConfigured(address indexed gbToken, address indexed usdcToken);
    event GuardianNodesConfigured(address indexed guardianNodes, uint256 allocStartId, uint256 nextAllocId);
    event GuardianNodeAllocated(
        uint256 indexed nodeId,
        address indexed beneficiary,
        string ip,
        address nodeWallet
    );
    event ValidatorRedeemCreated(
        bytes32 indexed codeHash,
        address indexed allowedClaimer,
        uint256 validatorCount,
        string targetNodeIp,
        uint256 gbMiningNodeCount,
        uint64 validAfter,
        uint64 validBefore,
        address referrer
    );
    event ValidatorRedeemCancelled(bytes32 indexed codeHash);
    /// @notice A CoNET DePIN node (IP + node wallet) is permanently bound to its beneficiary (1:1, set once).
    event DepinNodeBeneficiaryAssigned(bytes32 indexed ipHash, address indexed beneficiary, string conetDepinNodeIp);
    /// @notice A deployed validator is registered to a Guardian node id, withdrawal pointing to the beneficiary.
    event NodeValidatorRegistered(
        uint256 indexed guardianId,
        address indexed withdrawalBeneficiary,
        bytes32 indexed pubkeyHash,
        bytes pubkey
    );
    /// @notice A validator's exit was recorded on chain (transfer step 1: withdraw, then redeploy elsewhere).
    event NodeValidatorExited(uint256 indexed guardianId, bytes32 indexed pubkeyHash, address indexed withdrawalBeneficiary);
    /// @notice The current beneficiary transferred selected Guardian node ids to a new beneficiary.
    event NodesTransferred(address indexed fromBeneficiary, address indexed toBeneficiary, uint256[] guardianIds);
    /// @notice A node's existing validator must be exited so it can be redeployed with withdrawal -> new beneficiary.
    event NativeReceived(address indexed from, uint256 amount);
    /// @notice An admin transferred native CoNET (CNET) out of the contract.
    event NativeWithdrawn(address indexed to, uint256 amount);
    /// @notice The CoNET L1 beacon deposit contract address was configured.
    event DepositContractConfigured(address indexed depositContract);
    /// @notice This contract funded + deposited 32 CNET for a validator (0x01 withdrawal target = this contract).
    event ValidatorDeposited(uint256 indexed guardianId, address indexed beneficiary, bytes32 indexed pubkeyHash, uint256 amount);
    /// @notice A node's validator economic beneficiary changed via transfer (fee_recipient hot-update; NO exit).
    ///         The owning validator node listens for this and hot-updates the validator's fee_recipient.
    event NodeValidatorBeneficiaryUpdated(
        uint256 indexed guardianId,
        bytes32 indexed pubkeyHash,
        address indexed fromBeneficiary,
        address toBeneficiary
    );
    /// @notice A beneficiary requested a full exit of the listed nodes' validators (withdraw 32 CNET each).
    event FullExitRequested(address indexed beneficiary, uint256[] guardianIds);
    /// @notice The contract advanced {amount} CNET ({validatorCount}×32) to a beneficiary on full exit settle.
    event FullExitSettled(address indexed beneficiary, uint256 validatorCount, uint256 amount);
    /// @notice CL consensus-layer skim paid to the current node beneficiary via {settleNodeRewards}.
    event NodeRewardSettled(
        uint256 indexed guardianId,
        address indexed beneficiary,
        uint256 amount,
        bytes32 indexed eventKey
    );
    /// @notice The companion reward indexer contract address was configured.
    event RewardIndexerConfigured(address indexed rewardIndexer);
    /// @notice Referrer extension contract configured.
    event ReferrerExtensionConfigured(address indexed referrerExtension);
    /// @notice Transfer marketplace contract configured.
    event TransferMarketConfigured(address indexed transferMarket);
    /// @notice An airdrop-flagged redeem claim accrued CNET airdrop entitlement to a beneficiary.
    event AirdropAccrued(address indexed beneficiary, bytes32 indexed codeHash, uint256 added, uint256 newTotal);
    /// @notice A beneficiary claimed (received) part/all of their CNET airdrop entitlement.
    event AirdropClaimed(address indexed beneficiary, uint256 amount);
    /// @notice Admin set/changed the global airdrop claimable-from time.
    event AirdropClaimableAtSet(uint64 claimableAt);
    /// @notice Referrer earned auto-allocated validator + DePIN reward nodes on this contract.
    event ReferrerRewardNodesGranted(
        address indexed referrer,
        uint256 rewardNodeCount,
        uint256 referralNodeTotal,
        string[] conetDepinNodeIps
    );
    event ValidatorRedeemClaimed(
        bytes32 indexed requestId,
        bytes32 indexed codeHash,
        address indexed claimer,
        address beneficiary,
        uint256 validatorCount,
        string targetNodeIp,
        string[] conetDepinNodeIps,
        uint256 gbMiningNodeCount
    );

    modifier onlyRedeemAdmin() {
        require(redeemAdmins[msg.sender], "ValidatorRedeem: not redeem admin");
        _;
    }

    modifier onlyAdmin() {
        require(admins[msg.sender], "ValidatorRedeem: not admin");
        _;
    }

    /// @dev Minimal non-reentrancy guard for native CNET withdrawals (1 = unlocked, 2 = locked).
    uint256 private _nativeLock = 1;
    modifier nonReentrantNative() {
        require(_nativeLock == 1, "ValidatorRedeem: reentrant");
        _nativeLock = 2;
        _;
        _nativeLock = 1;
    }

    /// @notice Accept native CoNET (CNET) deposits (e.g. to fund admin batch payouts).
    receive() external payable {
        if (msg.value > 0) emit NativeReceived(msg.sender, msg.value);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice One-time initializer for the ERC1967 proxy (not for the implementation contract).
    function initialize(
        address initialRedeemAdmin,
        address initialContractAdmin,
        address gbToken_,
        address usdcToken_,
        address guardianNodes_,
        uint256 guardianAllocStartId_
    ) external initializer {
        __UUPSUpgradeable_init();
        _initEip712Domain();
        address redeemAdmin = initialRedeemAdmin == address(0) ? msg.sender : initialRedeemAdmin;
        redeemAdmins[redeemAdmin] = true;
        emit RedeemAdminAdded(redeemAdmin);
        address contractAdmin = initialContractAdmin == address(0) ? msg.sender : initialContractAdmin;
        admins[contractAdmin] = true;
        emit AdminAdded(contractAdmin);
        gbToken = IERC1155Balance(gbToken_);
        usdcToken = IERC20Balance(usdcToken_);
        if (gbToken_ != address(0) || usdcToken_ != address(0)) {
            emit TokensConfigured(gbToken_, usdcToken_);
        }
        if (guardianNodes_ != address(0)) {
            guardianNodes = IGuardianNodesInfoV6(guardianNodes_);
            guardianAllocStartId = guardianAllocStartId_;
            nextGuardianAllocId = guardianAllocStartId_;
            emit GuardianNodesConfigured(guardianNodes_, guardianAllocStartId_, guardianAllocStartId_);
        }
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    function _initEip712Domain() private {
        _eip712CachedChainId = bytes32(block.chainid);
        _eip712CachedSeparator = keccak256(
            abi.encode(_EIP712_TYPE_HASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function _domainSeparatorV4() internal view returns (bytes32) {
        if (bytes32(block.chainid) == _eip712CachedChainId) {
            return _eip712CachedSeparator;
        }
        return keccak256(
            abi.encode(_EIP712_TYPE_HASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), structHash));
    }

    /// @notice Configure (or update) the CoNET GB ERC1155 and USDC ERC20 token addresses used by {getWalletNodeProfile}.
    /// @dev Pass {address(0)} for a token to disable that balance read (returns 0 in the profile).
    function setTokens(address gbToken_, address usdcToken_) external onlyRedeemAdmin {
        gbToken = IERC1155Balance(gbToken_);
        usdcToken = IERC20Balance(usdcToken_);
        emit TokensConfigured(gbToken_, usdcToken_);
    }

    /// @notice Configure the CoNET L1 beacon deposit contract (0x4242…4242) used by {fundAndDepositValidators}.
    function setDepositContract(address depositContract_) external onlyRedeemAdmin {
        depositContract = IBeaconDeposit(depositContract_);
        emit DepositContractConfigured(depositContract_);
    }

    /// @notice The 0x01 withdrawal credentials that point back to THIS contract (1 byte 0x01 + 11 zero + 20 addr).
    function selfWithdrawalCredentials() public view returns (bytes32) {
        return bytes32(uint256(0x01) << 248) | bytes32(uint256(uint160(address(this))));
    }

    /// @notice Admin-only: transfer native CoNET (CNET) held by the contract to a recipient.
    function withdrawNative(address to, uint256 amount) external onlyAdmin nonReentrantNative {
        require(to != address(0), "ValidatorRedeem: zero recipient");
        require(amount > 0, "ValidatorRedeem: zero amount");
        require(address(this).balance >= amount, "ValidatorRedeem: insufficient balance");
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "ValidatorRedeem: native transfer failed");
        emit NativeWithdrawn(to, amount);
    }

    /// @notice Admin-only: batch transfer native CoNET (CNET) to many recipients in one transaction.
    /// @param recipients Parallel recipient addresses (must be non-zero).
    /// @param amounts    Parallel CNET amounts (wei, 18 decimals); each must be > 0.
    function withdrawNativeBatch(address[] calldata recipients, uint256[] calldata amounts)
        external
        onlyAdmin
        nonReentrantNative
    {
        require(recipients.length == amounts.length, "ValidatorRedeem: length mismatch");
        require(recipients.length > 0, "ValidatorRedeem: empty");
        uint256 total = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
        require(address(this).balance >= total, "ValidatorRedeem: insufficient balance");
        for (uint256 i = 0; i < recipients.length; i++) {
            address to = recipients[i];
            uint256 amount = amounts[i];
            require(to != address(0), "ValidatorRedeem: zero recipient");
            require(amount > 0, "ValidatorRedeem: zero amount");
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "ValidatorRedeem: native transfer failed");
            emit NativeWithdrawn(to, amount);
        }
    }

    // -------------------------------------- CNET airdrop claims --------------------------------------

    /// @notice Admin-only: set/change the time from which accrued CNET airdrops can be claimed (0 = closed).
    function setAirdropClaimableAt(uint64 claimableAt) external onlyRedeemAdmin {
        _air.claimableAt = claimableAt;
        emit AirdropClaimableAtSet(claimableAt);
    }

    /// @notice Airdrop ledger for a beneficiary: cumulative accrued, already claimed, currently releasable
    ///         (vested − claimed, per {AIRDROP_VESTING_DURATION} linear schedule), and the vesting start time
    ///         (0 = not open). Single multi-return view to conserve bytecode (EIP-170).
    function airdropInfoOf(address beneficiary)
        external
        view
        returns (uint256 accrued, uint256 claimed, uint256 claimable, uint64 claimableAt)
    {
        accrued = _air.accrued[beneficiary];
        claimed = _air.claimed[beneficiary];
        claimableAt = _air.claimableAt;
        uint256 vested;
        if (claimableAt != 0 && block.timestamp >= uint256(claimableAt)) {
            uint256 elapsed = block.timestamp - uint256(claimableAt);
            uint256 dur = uint256(AIRDROP_VESTING_DURATION);
            vested = elapsed >= dur ? accrued : (accrued * elapsed) / dur;
        }
        claimable = vested > claimed ? vested - claimed : 0;
    }

    /// @notice Airdrop claim: the beneficiary signs EIP-712 {ClaimAirdrop}; the tx may be self-submitted by the
    ///         beneficiary (they pay gas) or relayed by anyone (gas-sponsored). Only the vested-and-unclaimed
    ///         portion (linear over {AIRDROP_VESTING_DURATION} from {airdropClaimableAt}) is payable.
    /// @dev    Reuses {beneficiaryNonces} (shared beneficiary nonce space). Verify + payout offloaded to the stats lib.
    function claimAirdropFor(
        address beneficiary,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrantNative {
        ValidatorDepositRedeemStatsLib.claimAirdrop(
            _air,
            beneficiaryNonces,
            _domainSeparatorV4(),
            beneficiary,
            amount,
            nonce,
            deadline,
            signature,
            AIRDROP_VESTING_DURATION
        );
    }

    /// @notice Wire GuardianNodesInfoV6 and the auto-allocation id pool (e.g. start id 100 → ids 100,101,…).
    /// @dev Does not reset {nextGuardianAllocId} if already past start; admin may call before first claim only.
    function setGuardianNodes(address guardianNodes_, uint256 guardianAllocStartId_) external onlyRedeemAdmin {
        require(guardianNodes_ != address(0), "ValidatorRedeem: zero guardian");
        guardianNodes = IGuardianNodesInfoV6(guardianNodes_);
        guardianAllocStartId = guardianAllocStartId_;
        if (nextGuardianAllocId < guardianAllocStartId_) {
            nextGuardianAllocId = guardianAllocStartId_;
        }
        emit GuardianNodesConfigured(guardianNodes_, guardianAllocStartId_, nextGuardianAllocId);
    }

    function addRedeemAdmin(address account) external onlyRedeemAdmin {
        require(account != address(0), "ValidatorRedeem: zero admin");
        redeemAdmins[account] = true;
        emit RedeemAdminAdded(account);
    }

    function addAdmin(address account) external onlyAdmin {
        require(account != address(0), "ValidatorRedeem: zero admin");
        admins[account] = true;
        emit AdminAdded(account);
    }

    function removeAdmin(address account) external onlyAdmin {
        require(account != msg.sender, "ValidatorRedeem: cannot remove self");
        admins[account] = false;
        emit AdminRemoved(account);
    }

    function addRedeemAdminFor(
        address admin,
        address account,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(redeemAdmins[admin], "ValidatorRedeem: not admin");
        require(account != address(0), "ValidatorRedeem: zero admin");
        require(redeemAdminNonces[admin] == nonce, "ValidatorRedeem: bad nonce");

        bytes32 structHash = keccak256(abi.encode(ADD_REDEEM_ADMIN_TYPEHASH, admin, account, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "ValidatorRedeem: bad sig");

        redeemAdminNonces[admin]++;
        redeemAdmins[account] = true;
        emit RedeemAdminAdded(account);
    }

    function removeRedeemAdmin(address account) external onlyRedeemAdmin {
        require(account != msg.sender, "ValidatorRedeem: cannot remove self");
        redeemAdmins[account] = false;
        emit RedeemAdminRemoved(account);
    }

    function removeRedeemAdminFor(
        address admin,
        address account,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(redeemAdmins[admin], "ValidatorRedeem: not admin");
        require(redeemAdminNonces[admin] == nonce, "ValidatorRedeem: bad nonce");

        bytes32 structHash = keccak256(abi.encode(REMOVE_REDEEM_ADMIN_TYPEHASH, admin, account, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "ValidatorRedeem: bad sig");

        redeemAdminNonces[admin]++;
        redeemAdmins[account] = false;
        emit RedeemAdminRemoved(account);
    }

    // ----------------------------------------------------------------------------------------------------
    //  Validator registration — the deployment node, after deploying validators for a claimed beneficiary,
    //  records each deployed validator (BLS pubkey) against its paired DePIN node wallet. Withdrawal points
    //  to the node's beneficiary. Stored so a validator can later be exited and the (node + validator) pair
    //  transferred to a new beneficiary.
    // ----------------------------------------------------------------------------------------------------

    /// @notice Register deployed validators (admin/relayer is a redeem admin). One validator per Guardian node id.
    /// @param guardianIds Guardian node ids that already have a beneficiary (from a claim).
    /// @param pubkeys     Parallel BLS validator pubkeys (48 bytes each) deployed for those nodes.
    function registerNodeValidators(uint256[] calldata guardianIds, bytes[] calldata pubkeys)
        external
        onlyRedeemAdmin
    {
        _registerNodeValidators(guardianIds, pubkeys);
    }

    /// @notice EIP-712 signed variant: signed by a redeem admin, relayable by any gas sponsor (x402sdk Master).
    function registerNodeValidatorsFor(
        address admin,
        uint256[] calldata guardianIds,
        bytes[] calldata pubkeys,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(redeemAdmins[admin], "ValidatorRedeem: not admin");
        require(redeemAdminNonces[admin] == nonce, "ValidatorRedeem: bad nonce");

        bytes32 structHash = keccak256(
            abi.encode(
                REGISTER_NODE_VALIDATORS_TYPEHASH,
                admin,
                keccak256(abi.encodePacked(guardianIds)),
                _hashPubkeyArray(pubkeys),
                nonce,
                deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "ValidatorRedeem: bad sig");

        redeemAdminNonces[admin]++;
        _registerNodeValidators(guardianIds, pubkeys);
    }

    /// @notice Record that a validator has been exited (transfer step 1). Marks the node's binding inactive
    ///         so the (node + validator) pair can be redeployed and re-pointed to a new beneficiary later.
    function recordNodeValidatorExit(uint256 guardianId) external onlyRedeemAdmin {
        ValidatorBinding storage b = _nodeValidator[guardianId];
        require(b.pubkey.length != 0, "ValidatorRedeem: no validator");
        require(b.active, "ValidatorRedeem: already exited");
        b.active = false;
        b.exitedAt = uint64(block.timestamp);
        emit NodeValidatorExited(guardianId, keccak256(b.pubkey), b.withdrawalBeneficiary);
    }

    // ----------------------------------------------------------------------------------------------------
    //  Staking custody — this contract is the depositor AND the immutable 0x01 withdrawal target. The
    //  deployment node assembles validators off chain (withdrawal_credentials = THIS contract) and the
    //  relayer funds + deposits 32 CNET each from this contract's balance. Exited principal auto-returns
    //  here; transfers only hot-update fee_recipient; full exit advances 32 CNET to the beneficiary.
    // ----------------------------------------------------------------------------------------------------

    /// @notice Fund + deposit 32 CNET per validator from this contract's balance. Withdrawal credentials MUST
    ///         point to THIS contract (validated per entry). Binds each validator to its node wallet and the
    ///         node's existing beneficiary, and credits the staked-validator ledger.
    /// @param guardianIds Guardian node ids (each must already have a beneficiary from a claim).
    /// @param pubkeys Parallel 48-byte BLS validator pubkeys.
    /// @param withdrawalCredentials Parallel 32-byte withdrawal credentials; each MUST equal {selfWithdrawalCredentials}.
    /// @param signatures Parallel BLS deposit signatures (96 bytes).
    /// @param depositDataRoots Parallel deposit data roots.
    function fundAndDepositValidators(
        uint256[] calldata guardianIds,
        bytes[] calldata pubkeys,
        bytes[] calldata withdrawalCredentials,
        bytes[] calldata signatures,
        bytes32[] calldata depositDataRoots
    ) external onlyRedeemAdmin nonReentrantNative {
        require(address(depositContract) != address(0), "ValidatorRedeem: deposit unset");
        (uint256 stakedDelta, uint256 fundedDelta) = ValidatorDepositRedeemDepositLib.fundAndDepositValidators(
            address(depositContract),
            selfWithdrawalCredentials(),
            VALIDATOR_STAKE_WEI,
            guardianIdBeneficiary,
            _nodeValidator,
            _validatorPubkeyGuardian,
            stakedValidatorCountOf,
            guardianIds,
            pubkeys,
            withdrawalCredentials,
            signatures,
            depositDataRoots
        );
        totalStakedValidatorCount += stakedDelta;
        fundedDepositTotal += fundedDelta;
    }

    // ----------------------------------------------------------------------------------------------------
    //  Full exit — the beneficiary signs (offline, EIP-712) a full exit of selected node wallets. The
    //  relayer submits the signature; the owning validator node exits each validator (principal returns
    //  to this contract). After the exit is broadcast, the relayer/admin calls {settleFullExitPayout},
    //  which ADVANCES 32×count CNET from this contract's pool to the beneficiary (replenished by the
    //  auto-returning principal). The advance recipient MUST equal the on-chain economic beneficiary.
    // ----------------------------------------------------------------------------------------------------

    /// @notice Beneficiary requests a full exit of the listed nodes' validators. Signed by {beneficiary}, relayable.
    function requestFullExit(
        address beneficiary,
        uint256[] calldata guardianIds,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(guardianIds.length > 0, "ValidatorRedeem: empty");
        require(beneficiaryNonces[beneficiary] == nonce, "ValidatorRedeem: bad nonce");

        bytes32 structHash = keccak256(
            abi.encode(REQUEST_FULL_EXIT_TYPEHASH, beneficiary, _hashUint256Array(guardianIds), nonce, deadline)
        );
        require(ECDSA.recover(_hashTypedDataV4(structHash), signature) == beneficiary, "ValidatorRedeem: bad sig");
        beneficiaryNonces[beneficiary]++;

        for (uint256 i = 0; i < guardianIds.length; i++) {
            uint256 guardianId = guardianIds[i];
            require(guardianIdBeneficiary[guardianId] == beneficiary, "ValidatorRedeem: not your node");
            _requireGuardianNotListedInMarket(guardianId);
            ValidatorBinding storage b = _nodeValidator[guardianId];
            require(b.pubkey.length != 0 && b.active, "ValidatorRedeem: no active validator");
            require(b.withdrawalBeneficiary == beneficiary, "ValidatorRedeem: beneficiary mismatch");
            b.active = false;
            b.exitedAt = uint64(block.timestamp);
            emit NodeValidatorExited(guardianId, keccak256(b.pubkey), beneficiary);
        }
        emit FullExitRequested(beneficiary, guardianIds);
    }

    /// @notice Advance 32×count CNET to {beneficiary} for exited validators. Admin/relayer-only, called after
    ///         the off-chain exit is broadcast. Reverts if the pool can't cover the advance (relayer retries
    ///         once the auto-returned principal lands). Each pubkey is settled at most once (replay guard).
    function settleFullExitPayout(address beneficiary, uint256[] calldata guardianIds)
        external
        onlyRedeemAdmin
        nonReentrantNative
    {
        uint256 settledCount = ValidatorDepositRedeemExitLib.settleFullExitPayout(
            guardianIdBeneficiary,
            _nodeValidator,
            exitSettledPubkey,
            stakedValidatorCountOf,
            VALIDATOR_STAKE_WEI,
            beneficiary,
            guardianIds
        );
        if (totalStakedValidatorCount >= settledCount) {
            totalStakedValidatorCount -= settledCount;
        } else {
            totalStakedValidatorCount = 0;
        }
    }

    /**
     * @notice Pay CL consensus-layer skim (already received by this contract via 0x01 withdrawal credentials)
     *         to each node's **current** beneficiary EOA. Relayer-only; idempotent per {eventKey}.
     * @dev Principal reserve: never pay rewards from the 32×{totalStakedValidatorCount} CNET custody pool.
     *      Ownership transfer hot-updates {guardianIdBeneficiary} so rewards automatically follow the buyer.
     */
    function settleNodeRewards(
        uint256[] calldata guardianIds,
        uint256[] calldata amounts,
        bytes32[] calldata eventKeys
    ) external onlyRedeemAdmin nonReentrantNative {
        uint256 batchPaid = ValidatorDepositRedeemRewardLib.settleNodeRewards(
            consumedRewardEventKey,
            clRewardPaid,
            guardianIdBeneficiary,
            totalStakedValidatorCount,
            guardianIds,
            amounts,
            eventKeys
        );
        totalRewardPaid += batchPaid;
    }

    /// @notice Aggregate CL reward payout stats for dashboards / reconciliation.
    function getRewardPayoutStats()
        external
        view
        returns (uint256 stakedCount, uint256 rewardPaidTotal, uint256 contractBalance, uint256 principalReserve)
    {
        stakedCount = totalStakedValidatorCount;
        rewardPaidTotal = totalRewardPaid;
        contractBalance = address(this).balance;
        principalReserve = VALIDATOR_STAKE_WEI * totalStakedValidatorCount;
    }

    /// @notice EIP-712 digest the beneficiary must sign for {requestFullExit}.
    function getRequestFullExitDigest(
        address beneficiary,
        uint256[] calldata guardianIds,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(REQUEST_FULL_EXIT_TYPEHASH, beneficiary, _hashUint256Array(guardianIds), nonce, deadline)
        );
        return _hashTypedDataV4(structHash);
    }

    /// @notice Configure the companion {ValidatorNodeRewardIndexer} contract address (per-node/per-beneficiary
    ///         hourly CNET reward ledger + period stats). Kept external to respect the EVM contract size limit.
    function setRewardIndexer(address rewardIndexer_) external onlyRedeemAdmin {
        rewardIndexer = rewardIndexer_;
        emit RewardIndexerConfigured(rewardIndexer_);
    }

    /// @notice Configure the companion referrer extension (bind introducer on claim + referral ledger).
    function setReferrerExtension(address referrerExtension_) external onlyRedeemAdmin {
        referrerExtension = IValidatorDepositRedeemReferrerExtension(referrerExtension_);
        emit ReferrerExtensionConfigured(referrerExtension_);
    }

    /// @notice Configure the transfer-order marketplace companion contract.
    function setTransferMarket(address transferMarket_) external onlyRedeemAdmin {
        transferMarket = transferMarket_;
        emit TransferMarketConfigured(transferMarket_);
    }

    /// @notice USDC token address for the transfer marketplace (EIP-3009 fulfil).
    function usdcTokenAddress() external view returns (address) {
        return address(usdcToken);
    }

    /// @notice Node operator wallet => beneficiary (transfer marketplace read).
    function nodeWalletBeneficiary(address nodeWallet) external view returns (address) {
        return _nodeWalletBeneficiary[nodeWallet];
    }

    /// @notice Consume a beneficiary EIP-712 nonce after the transfer marketplace verifies a signature.
    function consumeBeneficiaryNonceForMarket(address account, uint256 nonce) external {
        require(msg.sender == transferMarket, "ValidatorRedeem: not market");
        require(beneficiaryNonces[account] == nonce, "ValidatorRedeem: bad nonce");
        beneficiaryNonces[account]++;
    }

    /// @notice Execute a node transfer on behalf of the transfer marketplace (order fulfilment).
    function transferOneGuardianIdForMarket(address from, address to, uint256 guardianId) external {
        require(msg.sender == transferMarket, "ValidatorRedeem: not market");
        _transferOneGuardianId(from, to, guardianId);
    }

    function _requireGuardianNotListedInMarket(uint256 guardianId) internal view {
        if (transferMarket == address(0)) return;
        require(
            IValidatorDepositRedeemTransferMarket(transferMarket).nodeOrder(guardianId) == 0,
            "ValidatorRedeem: node listed in order"
        );
    }

    /// @dev Load a 32-byte calldata bytes value as bytes32 (caller guarantees length == 32).
    function _bytes32FromCalldata(bytes calldata b) internal pure returns (bytes32 word) {
        assembly {
            word := calldataload(b.offset)
        }
    }

    function _registerNodeValidators(uint256[] calldata guardianIds, bytes[] calldata pubkeys) internal {
        require(guardianIds.length == pubkeys.length, "ValidatorRedeem: length mismatch");
        require(guardianIds.length > 0, "ValidatorRedeem: empty");
        for (uint256 i = 0; i < guardianIds.length; i++) {
            _registerOneNodeValidator(guardianIds[i], pubkeys[i]);
        }
    }

    function _registerOneNodeValidator(uint256 guardianId, bytes calldata pubkey) internal {
        require(guardianId != 0, "ValidatorRedeem: zero guardian id");
        address beneficiary = guardianIdBeneficiary[guardianId];
        require(beneficiary != address(0), "ValidatorRedeem: node has no beneficiary");
        bytes32 pkHash = keccak256(pubkey);
        uint256 boundId = _validatorPubkeyGuardian[pkHash];
        require(boundId == 0 || boundId == guardianId, "ValidatorRedeem: pubkey bound elsewhere");
        ValidatorDepositRedeemDepositLib.registerOneNodeValidator(
            _nodeValidator,
            _validatorPubkeyGuardian,
            guardianId,
            beneficiary,
            pubkey
        );
    }

    function _hashPubkeyArray(bytes[] calldata pubkeys) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](pubkeys.length);
        for (uint256 i = 0; i < pubkeys.length; i++) {
            hashes[i] = keccak256(pubkeys[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }

    // ----------------------------------------------------------------------------------------------------
    //  Transfer — the CURRENT beneficiary selects some of its own DePIN node wallets and signs (offline,
    //  EIP-712) a transfer to a NEW beneficiary. A gas-sponsoring relayer (API server) submits the signature.
    //  Effect on chain: node→beneficiary, IP→beneficiary and the per-beneficiary node tables are re-pointed to
    //  the new beneficiary (so the GB-distribution gossip service automatically credits GB to the new wallet),
    //  and an exit is requested for each node's validator so the validator node can withdraw + redeploy with
    //  the withdrawal address pointing to the new beneficiary.
    // ----------------------------------------------------------------------------------------------------

    /// @notice Transfer selected node wallets (with their DePIN nodes + validators) to a new beneficiary.
    /// @dev Signed by {fromBeneficiary}; relayable by anyone (gas sponsor). Each node must currently belong
    ///      to {fromBeneficiary}. Validators are flagged for exit (off-chain) + redeploy under {toBeneficiary}.
    function transferNodes(
        address fromBeneficiary,
        address toBeneficiary,
        uint256[] calldata guardianIds,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(toBeneficiary != address(0), "ValidatorRedeem: zero to beneficiary");
        require(toBeneficiary != fromBeneficiary, "ValidatorRedeem: same beneficiary");
        require(guardianIds.length > 0, "ValidatorRedeem: empty");
        require(beneficiaryNonces[fromBeneficiary] == nonce, "ValidatorRedeem: bad nonce");

        bytes32 structHash = keccak256(
            abi.encode(
                TRANSFER_NODES_TYPEHASH,
                fromBeneficiary,
                toBeneficiary,
                _hashUint256Array(guardianIds),
                nonce,
                deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == fromBeneficiary, "ValidatorRedeem: bad sig");

        beneficiaryNonces[fromBeneficiary]++;

        for (uint256 i = 0; i < guardianIds.length; i++) {
            _requireGuardianNotListedInMarket(guardianIds[i]);
            _transferOneGuardianId(fromBeneficiary, toBeneficiary, guardianIds[i]);
        }
        emit NodesTransferred(fromBeneficiary, toBeneficiary, guardianIds);
    }

    /// @notice EIP-712 digest the current beneficiary must sign for {transferNodes}.
    function getTransferNodesDigest(
        address fromBeneficiary,
        address toBeneficiary,
        uint256[] calldata guardianIds,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                TRANSFER_NODES_TYPEHASH,
                fromBeneficiary,
                toBeneficiary,
                _hashUint256Array(guardianIds),
                nonce,
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function _hashUint256Array(uint256[] calldata arr) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(arr));
    }

    /// @dev Transfer a single Guardian node id (with its DePIN node + validator) from {from} to {to}.
    ///      The Guardian id is the transferable unit; multiple ids sharing one operator wallet move independently.
    function _transferOneGuardianId(address from, address to, uint256 guardianId) internal {
        ValidatorDepositRedeemTransferLib.transferOneGuardianId(
            guardianIdBeneficiary,
            _beneficiaryGuardianIds,
            _beneficiaryGuardianNodeWallets,
            guardianIdGbMining,
            _depinIpBeneficiary,
            _nodeWalletBeneficiary,
            _walletDepinIpSeen,
            _walletDepinNodeIps,
            validatorNodeCountOf,
            gbMiningNodeCountOf,
            stakedValidatorCountOf,
            _nodeValidator,
            address(guardianNodes),
            from,
            to,
            guardianId
        );
    }

    /// @notice Create a redeem code (gas-sponsored meta-tx; admin signs EIP-712 {CreateRedeem}). ALL redeems
    ///         auto-assign consecutive Guardian node ids at claim time (IPs + node wallets read from
    ///         GuardianNodesInfoV6). No manual IP list is accepted.
    /// @dev    The same beneficiary may be the target of many redeems; each claim appends a fresh
    ///         consecutive block of Guardian nodes (see {_allocateGuardianNodesFromGuardian}).
    function createRedeemFor(
        address admin,
        bytes32 codeHash,
        address allowedClaimer,
        address referrer,
        uint256 validatorCount,
        string calldata targetNodeIp,
        uint256 gbMiningNodeCount,
        bool airdrop,
        uint256 validAfter,
        uint256 validBefore,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(redeemAdmins[admin], "ValidatorRedeem: not admin");
        require(redeemAdminNonces[admin] == nonce, "ValidatorRedeem: bad nonce");
        require(validAfter <= type(uint64).max && validBefore <= type(uint64).max, "ValidatorRedeem: time overflow");

        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_REDEEM_TYPEHASH,
                admin,
                codeHash,
                allowedClaimer,
                referrer,
                validatorCount,
                keccak256(bytes(targetNodeIp)),
                gbMiningNodeCount,
                airdrop,
                validAfter,
                validBefore,
                nonce,
                deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "ValidatorRedeem: bad sig");

        redeemAdminNonces[admin]++;
        _applyCreateRedeem(
            codeHash,
            allowedClaimer,
            referrer,
            validatorCount,
            targetNodeIp,
            gbMiningNodeCount,
            airdrop,
            uint64(validAfter),
            uint64(validBefore)
        );
    }

    function cancelRedeem(bytes32 codeHash) external onlyRedeemAdmin {
        _applyCancelRedeem(codeHash);
    }

    function cancelRedeemFor(
        address admin,
        bytes32 codeHash,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(redeemAdmins[admin], "ValidatorRedeem: not admin");
        require(redeemAdminNonces[admin] == nonce, "ValidatorRedeem: bad nonce");

        bytes32 structHash = keccak256(abi.encode(CANCEL_REDEEM_TYPEHASH, admin, codeHash, nonce, deadline));
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "ValidatorRedeem: bad sig");

        redeemAdminNonces[admin]++;
        _applyCancelRedeem(codeHash);
    }

    function claimRedeemFor(
        address claimer,
        address beneficiary,
        string calldata code,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bytes32 requestId) {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(claimer != address(0), "ValidatorRedeem: zero claimer");
        require(beneficiary != address(0), "ValidatorRedeem: zero beneficiary");
        bytes memory b = bytes(code);
        require(b.length > 0 && b.length <= _MAX_REDEEM_CODE_LEN, "ValidatorRedeem: bad code len");
        bytes32 codeHash = keccak256(b);

        Redeem storage r = _redeems[codeHash];
        require(r.active, "ValidatorRedeem: inactive");
        require(!r.consumed, "ValidatorRedeem: consumed");
        require(_timeOk(r.validAfter, r.validBefore), "ValidatorRedeem: time window");
        require(r.allowedClaimer == address(0) || r.allowedClaimer == claimer, "ValidatorRedeem: claimer not allowed");

        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_REDEEM_TYPEHASH,
                claimer,
                codeHash,
                beneficiary,
                r.referrer,
                uint256(r.validatorCount),
                keccak256(bytes(r.targetNodeIp)),
                uint256(r.gbMiningNodeCount),
                deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == claimer, "ValidatorRedeem: bad sig");

        requestId = _consumeAndEmit(codeHash, claimer, beneficiary, r.referrer, r);
    }

    function claimRedeem(string calldata code, address beneficiary) external returns (bytes32 requestId) {
        require(beneficiary != address(0), "ValidatorRedeem: zero beneficiary");
        bytes memory b = bytes(code);
        require(b.length > 0 && b.length <= _MAX_REDEEM_CODE_LEN, "ValidatorRedeem: bad code len");
        bytes32 codeHash = keccak256(b);

        Redeem storage r = _redeems[codeHash];
        require(r.active, "ValidatorRedeem: inactive");
        require(!r.consumed, "ValidatorRedeem: consumed");
        require(_timeOk(r.validAfter, r.validBefore), "ValidatorRedeem: time window");
        require(r.allowedClaimer == address(0) || r.allowedClaimer == msg.sender, "ValidatorRedeem: claimer not allowed");

        requestId = _consumeAndEmit(codeHash, msg.sender, beneficiary, r.referrer, r);
    }

    function getClaimRedeemDigest(
        address claimer,
        bytes32 codeHash,
        address beneficiary,
        uint256 deadline
    ) external view returns (bytes32) {
        Redeem storage r = _redeems[codeHash];
        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_REDEEM_TYPEHASH,
                claimer,
                codeHash,
                beneficiary,
                r.referrer,
                uint256(r.validatorCount),
                keccak256(bytes(r.targetNodeIp)),
                uint256(r.gbMiningNodeCount),
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function getCancelRedeemDigest(address admin, bytes32 codeHash, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(CANCEL_REDEEM_TYPEHASH, admin, codeHash, nonce, deadline));
        return _hashTypedDataV4(structHash);
    }

    function getRedeem(bytes32 codeHash)
        external
        view
        returns (
            address allowedClaimer,
            address referrer,
            uint256 validatorCount,
            string memory targetNodeIp,
            uint256 gbMiningNodeCount,
            uint64 validAfter,
            uint64 validBefore,
            bool active,
            bool consumed,
            bool airdrop
        )
    {
        Redeem storage r = _redeems[codeHash];
        return (
            r.allowedClaimer,
            r.referrer,
            uint256(r.validatorCount),
            r.targetNodeIp,
            uint256(r.gbMiningNodeCount),
            r.validAfter,
            r.validBefore,
            r.active,
            r.consumed,
            r.airdrop
        );
    }

    /// @notice Resolve node operator wallet for a Guardian node id (0 if unset on Guardian).
    function guardianNodeWalletOf(uint256 nodeId) external view returns (address) {
        return guardianNodes.idOwner(nodeId);
    }

    /// @notice Resolve DePIN IP for a Guardian node id (empty if unset on Guardian).
    function guardianNodeIpOf(uint256 nodeId) external view returns (string memory) {
        return guardianNodes.id2ip(nodeId);
    }

    /// @notice Per-beneficiary, deduplicated CoNET DePIN node IP list accrued across all successful claims.
    function getWalletDepinNodeIps(address wallet) external view returns (string[] memory) {
        return _walletDepinNodeIps[wallet];
    }

    /**
     * @notice Reverse lookup: the beneficiary a CoNET DePIN node IP was last assigned to during a redeem claim.
     * @param conetDepinNodeIp The DePIN node IP string (must match the stored on-chain value, normally lowercased).
     * @return beneficiary The assigned beneficiary; {address(0)} if the IP was never assigned.
     */
    function getDepinBeneficiaryByIp(string calldata conetDepinNodeIp) external view returns (address beneficiary) {
        return _depinIpBeneficiary[keccak256(bytes(conetDepinNodeIp))];
    }

    /// @notice Reverse lookup: the beneficiary a node operator wallet belongs to ({address(0)} if none).
    function getBeneficiaryByNodeWallet(address nodeWallet) external view returns (address beneficiary) {
        return _nodeWalletBeneficiary[nodeWallet];
    }

    /// @notice The validator binding registered to a Guardian node id ({active}=false once exited).
    function getNodeValidator(uint256 guardianId)
        external
        view
        returns (bytes memory pubkey, address withdrawalBeneficiary, uint64 registeredAt, uint64 exitedAt, bool active)
    {
        ValidatorBinding storage b = _nodeValidator[guardianId];
        return (b.pubkey, b.withdrawalBeneficiary, b.registeredAt, b.exitedAt, b.active);
    }

    /// @notice Reverse lookup by precomputed pubkey hash (keccak256 of the 48-byte BLS pubkey). 0 = unbound.
    function getNodeByValidatorPubkeyHash(bytes32 pubkeyHash) external view returns (uint256 guardianId) {
        return _validatorPubkeyGuardian[pubkeyHash];
    }

    /**
     * @notice One-shot: full beneficiary node dataset (Guardian node ids, DePIN IP list, node wallet list,
     *         node counts and live CNET / GB / USDC balances) for a beneficiary wallet.
     * @dev Works regardless of how nodes were spread across the Guardian pool (non-contiguous claims are fine,
     *      the per-beneficiary arrays are append-only). Returns an empty bundle for {address(0)}.
     */
    function getBeneficiaryNodeBundle(address beneficiary) external view returns (NodeBundle memory) {
        return _buildNodeBundle(beneficiary);
    }

    /**
     * @notice Universal resolver — accepts ANY of: beneficiary wallet, node operator wallet, or DePIN IP, and
     *         returns the same full beneficiary node dataset. Empty/zero inputs are ignored.
     */
    function resolveNodeBundle(address maybeWallet, string calldata conetDepinNodeIp)
        external
        view
        returns (NodeBundle memory)
    {
        if (bytes(conetDepinNodeIp).length != 0) {
            address byIp = _depinIpBeneficiary[keccak256(bytes(conetDepinNodeIp))];
            if (byIp != address(0)) return _buildNodeBundle(byIp);
        }
        if (maybeWallet != address(0)) {
            address byNodeWallet = _nodeWalletBeneficiary[maybeWallet];
            if (byNodeWallet != address(0)) return _buildNodeBundle(byNodeWallet);
            return _buildNodeBundle(maybeWallet);
        }
        return _buildNodeBundle(address(0));
    }

    /**
     * @notice Unified on-chain income stats: GB (ConetGB1155) + CNET (ValidatorNodeRewardIndexer) for the
     *         resolved beneficiary and each owned node. Single eth_call to this contract; internally reads
     *         {gbToken} + {rewardIndexer} via the linked stats library (no centralized API).
     * @param anchorTs CNET period anchor unix seconds (0 = block.timestamp).
     */
    function resolveUnifiedIncomeStats(address maybeWallet, string calldata conetDepinNodeIp, uint256 anchorTs)
        external
        view
        returns (UnifiedIncomeStats memory stats)
    {
        return
            ValidatorDepositRedeemStatsLib.resolveUnifiedFromRedeem(
                address(this),
                maybeWallet,
                conetDepinNodeIp,
                anchorTs
            );
    }

    /// @dev Assemble the full {NodeBundle} for a beneficiary (linked {ValidatorDepositRedeemBundleLib}).
    function _buildNodeBundle(address beneficiary) internal view returns (NodeBundle memory b) {
        return ValidatorDepositRedeemBundleLib.buildNodeBundle(
            address(this),
            address(guardianNodes),
            address(gbToken),
            address(usdcToken),
            beneficiary,
            _beneficiaryGuardianIds[beneficiary]
        );
    }

    function nodeValidatorBinding(uint256 guardianId)
        external
        view
        returns (bytes memory pubkey, bool active)
    {
        ValidatorBinding storage vb = _nodeValidator[guardianId];
        return (vb.pubkey, vb.active);
    }

    /// @dev All redeems are auto-allocation: no IP list is stored at create; consecutive Guardian
    ///      node ids (and their IPs + node wallets) are resolved at claim time.
    function _applyCreateRedeem(
        bytes32 codeHash,
        address allowedClaimer,
        address referrer,
        uint256 validatorCount,
        string calldata targetNodeIp,
        uint256 gbMiningNodeCount,
        bool airdrop,
        uint64 validAfter,
        uint64 validBefore
    ) internal {
        require(address(guardianNodes) != address(0), "ValidatorRedeem: guardian unset");
        require(codeHash != bytes32(0), "ValidatorRedeem: invalid hash");
        require(validatorCount > 0 && validatorCount <= type(uint128).max, "ValidatorRedeem: invalid validators");
        require(gbMiningNodeCount <= type(uint128).max, "ValidatorRedeem: gb overflow");
        if (referrer != address(0)) {
            require(address(referrerExtension) != address(0), "ValidatorRedeem: referrer ext unset");
        }
        _requireValidIpString(targetNodeIp);

        Redeem storage r = _redeems[codeHash];
        require(!r.consumed, "ValidatorRedeem: hash consumed");
        require(!r.active, "ValidatorRedeem: already active");

        r.allowedClaimer = allowedClaimer;
        r.referrer = referrer;
        r.validatorCount = uint128(validatorCount);
        r.gbMiningNodeCount = uint128(gbMiningNodeCount);
        r.validAfter = validAfter;
        r.validBefore = validBefore;
        r.active = true;
        r.airdrop = airdrop;
        r.targetNodeIp = targetNodeIp;

        emit ValidatorRedeemCreated(
            codeHash,
            allowedClaimer,
            validatorCount,
            targetNodeIp,
            gbMiningNodeCount,
            validAfter,
            validBefore,
            referrer
        );
    }

    function _applyCancelRedeem(bytes32 codeHash) internal {
        require(codeHash != bytes32(0), "ValidatorRedeem: invalid hash");
        Redeem storage r = _redeems[codeHash];
        require(r.active, "ValidatorRedeem: not active");
        r.active = false;
        emit ValidatorRedeemCancelled(codeHash);
    }

    function _consumeAndEmit(
        bytes32 codeHash,
        address claimer,
        address beneficiary,
        address referrer,
        Redeem storage r
    ) internal returns (bytes32 requestId) {
        r.active = false;
        r.consumed = true;

        // Accrue per-beneficiary node ownership so {getWalletNodeProfile} can report a wallet's CoNET node profile.
        // A beneficiary may claim many redeems over time; each claim appends a fresh block of nodes.
        walletClaimCountOf[beneficiary] += 1;
        string[] memory claimIps =
            _appendAllocatedNodes(beneficiary, uint256(r.validatorCount), uint256(r.gbMiningNodeCount));

        // Airdrop-flagged redeem: accrue 100 CNET per validator node claimed (claimable after {airdropClaimableAt}).
        if (r.airdrop) {
            uint256 added = uint256(r.validatorCount) * AIRDROP_CNET_PER_NODE;
            if (added > 0) {
                uint256 newTotal = _air.accrued[beneficiary] + added;
                _air.accrued[beneficiary] = newTotal;
                emit AirdropAccrued(beneficiary, codeHash, added, newTotal);
            }
        }

        requestId = keccak256(
            abi.encode(codeHash, claimer, beneficiary, uint256(r.validatorCount), keccak256(bytes(r.targetNodeIp)))
        );
        emit ValidatorRedeemClaimed(
            requestId,
            codeHash,
            claimer,
            beneficiary,
            uint256(r.validatorCount),
            r.targetNodeIp,
            claimIps,
            uint256(r.gbMiningNodeCount)
        );

        if (referrer != address(0)) {
            require(address(referrerExtension) != address(0), "ValidatorRedeem: referrer ext unset");
            IValidatorDepositRedeemReferrerExtension(address(referrerExtension)).onBeneficiaryClaim(
                beneficiary, referrer, uint256(r.validatorCount)
            );
        }
    }

    /// @notice Called by {referrerExtension} to grant milestone reward nodes on this contract.
    function grantReferrerRewardNodes(address referrer, uint256 count) external {
        require(msg.sender == address(referrerExtension), "ValidatorRedeem: not referrer ext");
        if (count == 0) {
            return;
        }
        uint256[] storage rewardIds = _referrerRewardGuardianIds[referrer];
        uint256[] storage allIds = _beneficiaryGuardianIds[referrer];
        uint256 idStart = allIds.length;
        string[] memory ips = _appendAllocatedNodes(referrer, count, count);
        require(allIds.length == idStart + count, "ValidatorRedeem: reward alloc mismatch");
        for (uint256 i = 0; i < count; i++) {
            rewardIds.push(allIds[idStart + i]);
        }
        uint256 referralTotal =
            IValidatorDepositRedeemReferrerExtension(msg.sender).referrerReferralNodeTotal(referrer);
        emit ReferrerRewardNodesGranted(referrer, count, referralTotal, ips);
    }

    /// @notice Milestone reward nodes granted to {referrer} (validator node wallet + DePIN IP per row).
    function getReferrerRewardNodes(address referrer)
        external
        view
        returns (uint256[] memory guardianNodeIds, address[] memory nodeWallets, string[] memory depinNodeIps)
    {
        uint256[] storage ids = _referrerRewardGuardianIds[referrer];
        uint256 n = ids.length;
        guardianNodeIds = new uint256[](n);
        nodeWallets = new address[](n);
        depinNodeIps = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 nodeId = ids[i];
            guardianNodeIds[i] = nodeId;
            if (address(guardianNodes) == address(0)) {
                continue;
            }
            string memory ip = guardianNodes.id2ip(nodeId);
            depinNodeIps[i] = ip;
            address w = guardianNodes.idOwner(nodeId);
            if (w == address(0) && bytes(ip).length != 0) {
                w = guardianNodes.ipaddress2owner(ip);
            }
            nodeWallets[i] = w;
        }
    }

    /// @dev Append Guardian allocation + ownership counters for {beneficiary}.
    function _appendAllocatedNodes(address beneficiary, uint256 validatorCount, uint256 gbMiningCount)
        internal
        returns (string[] memory ips)
    {
        validatorNodeCountOf[beneficiary] += validatorCount;
        gbMiningNodeCountOf[beneficiary] += gbMiningCount;
        ips = _allocateGuardianNodesFromGuardian(beneficiary, validatorCount);
        _markGbMiningOnLatestNodes(beneficiary, validatorCount, gbMiningCount);
        _accrueWalletDepinNodeIpsMemory(beneficiary, ips);
    }

    /// @dev Mark the first {gbCount} guardian ids in the latest {validatorCount} allocation batch as GB mining nodes.
    function _markGbMiningOnLatestNodes(address beneficiary, uint256 validatorCount, uint256 gbCount) internal {
        if (gbCount == 0 || validatorCount == 0) return;
        uint256[] storage ids = _beneficiaryGuardianIds[beneficiary];
        require(ids.length >= validatorCount, "ValidatorRedeem: alloc mismatch");
        uint256 start = ids.length - validatorCount;
        uint256 mark = gbCount > validatorCount ? validatorCount : gbCount;
        for (uint256 j = 0; j < mark; j++) {
            guardianIdGbMining[ids[start + j]] = true;
        }
    }

    /// @dev Assign the next {count} consecutive Guardian node ids; permanent, no beneficiary revoke.
    function _allocateGuardianNodesFromGuardian(address beneficiary, uint256 count)
        internal
        returns (string[] memory ips)
    {
        require(address(guardianNodes) != address(0), "ValidatorRedeem: guardian unset");
        ips = new string[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 nodeId = nextGuardianAllocId;
            nextGuardianAllocId++;
            require(nodeId >= guardianAllocStartId, "ValidatorRedeem: before pool start");
            require(guardianIdBeneficiary[nodeId] == address(0), "ValidatorRedeem: id taken");

            string memory ip = guardianNodes.id2ip(nodeId);
            require(bytes(ip).length != 0, "ValidatorRedeem: guardian id missing ip");
            require(guardianNodes.ipaddressExisting(ip), "ValidatorRedeem: ip not on guardian");

            address nodeWallet = guardianNodes.idOwner(nodeId);
            if (nodeWallet == address(0)) {
                nodeWallet = guardianNodes.ipaddress2owner(ip);
            }
            require(nodeWallet != address(0), "ValidatorRedeem: no node wallet");

            // DePIN uniqueness is per-IP in {_accrueOneDepinIp}. Many Guardian ids may share one
            // operator EOA; do not block a new beneficiary when the operator wallet is already bound.
            if (_nodeWalletBeneficiary[nodeWallet] == address(0)) {
                _nodeWalletBeneficiary[nodeWallet] = beneficiary;
            }

            guardianIdBeneficiary[nodeId] = beneficiary;
            _beneficiaryGuardianIds[beneficiary].push(nodeId);
            _beneficiaryGuardianNodeWallets[beneficiary].push(nodeWallet);

            ips[i] = ip;
            emit GuardianNodeAllocated(nodeId, beneficiary, ip, nodeWallet);
        }
    }

    function _accrueWalletDepinNodeIpsMemory(address beneficiary, string[] memory ips) internal {
        for (uint256 i = 0; i < ips.length; i++) {
            _accrueOneDepinIp(beneficiary, ips[i]);
        }
    }

    function _accrueOneDepinIp(address beneficiary, string memory ip) internal {
        bytes32 key = keccak256(bytes(ip));
        address previous = _depinIpBeneficiary[key];
        // Permanent 1:1 — an IP belongs to exactly one beneficiary forever (no reassignment).
        require(previous == address(0) || previous == beneficiary, "ValidatorRedeem: ip other beneficiary");
        if (previous == address(0)) {
            _depinIpBeneficiary[key] = beneficiary;
            emit DepinNodeBeneficiaryAssigned(key, beneficiary, ip);
        }
        if (_walletDepinIpSeen[beneficiary][key]) return;
        _walletDepinIpSeen[beneficiary][key] = true;
        _walletDepinNodeIps[beneficiary].push(ip);
    }

    function _safeGbBalance(address wallet) internal view returns (uint256) {
        if (address(gbToken) == address(0)) return 0;
        try gbToken.balanceOf(wallet, CONET_GB_TOTAL_TOKEN_ID) returns (uint256 b) {
            return b;
        } catch {
            return 0;
        }
    }

    function _safeUsdcBalance(address wallet) internal view returns (uint256) {
        if (address(usdcToken) == address(0)) return 0;
        try usdcToken.balanceOf(wallet) returns (uint256 b) {
            return b;
        } catch {
            return 0;
        }
    }

    function _timeOk(uint64 validAfter, uint64 validBefore) internal view returns (bool) {
        uint256 ts = block.timestamp;
        if (validAfter != 0 && ts < validAfter) return false;
        if (validBefore != 0 && ts > validBefore) return false;
        return true;
    }

    function _requireValidIpString(string memory ip) internal pure {
        bytes memory b = bytes(ip);
        require(b.length > 0 && b.length <= _MAX_IP_LEN, "ValidatorRedeem: bad ip len");
    }

    /// @dev Reserved storage gap for future UUPS upgrades (do not shrink without a storage layout audit).
    uint256[46] private __gap;
}
