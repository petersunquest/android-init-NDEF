// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "../contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";
import {
    ValidatorDepositRedeemStatsLib,
    UnifiedIncomeStats
} from "./ValidatorDepositRedeemStatsLib.sol";
import {NodeBundle} from "./ValidatorDepositRedeemTypes.sol";

/// @dev Minimal balance interface for the CoNET USDC ERC20 token.
interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @dev Read-only slice of the transfer market (node listing guard).
interface IValidatorDepositRedeemTransferMarket {
    function nodeOrder(address nodeWallet) external view returns (uint256);
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
contract ValidatorDepositRedeem is EIP712 {
    uint256 private constant _MAX_REDEEM_CODE_LEN = 512;
    uint256 private constant _MAX_IP_LEN = 64;

    /// @notice GB net-total token id on ConetGB1155 (id=0 is cumulative net GB, 18 decimals).
    uint256 public constant CONET_GB_TOTAL_TOKEN_ID = 0;

    mapping(address => bool) public redeemAdmins;
    mapping(address => uint256) public redeemAdminNonces;
    /// @notice Per-account EIP-712 nonce for {transferNodes} and transfer-order create/cancel/fulfill signatures.
    mapping(address => uint256) public beneficiaryNonces;

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

    /// @notice A deployed validator bound to a single DePIN node wallet (1:1). The validator pubkey is the
    ///         identity used for a future exit / withdrawal; {withdrawalBeneficiary} is the current withdrawal
    ///         target. The (DePIN node + validator) pair is the transferable unit.
    struct ValidatorBinding {
        bytes pubkey;                 // BLS validator pubkey (48 bytes); identity for exit/withdrawal
        address withdrawalBeneficiary; // current withdrawal target = node's beneficiary at registration
        uint64 registeredAt;
        uint64 exitedAt;              // 0 until an exit is recorded (transfer step 1)
        bool active;                  // true while running; false after exit (awaiting redeploy/transfer)
    }
    /// @dev DePIN node wallet => its current validator binding (1:1).
    mapping(address => ValidatorBinding) private _nodeValidator;
    /// @dev keccak256(validator pubkey) => DePIN node wallet (reverse lookup; permanent identity).
    mapping(bytes32 => address) private _validatorPubkeyNode;

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
        uint128 validatorCount;
        uint128 gbMiningNodeCount;
        uint64 validAfter;
        uint64 validBefore;
        bool active;
        bool consumed;
        string targetNodeIp;
    }

    mapping(bytes32 => Redeem) private _redeems;

    /// @dev See {NodeBundle} in ValidatorDepositRedeemTypes.sol (shared with stats library).

    bytes32 private constant CREATE_REDEEM_TYPEHASH = keccak256(
        "CreateRedeem(address admin,bytes32 codeHash,address allowedClaimer,uint256 validatorCount,string targetNodeIp,uint256 gbMiningNodeCount,uint256 validAfter,uint256 validBefore,uint256 nonce,uint256 deadline)"
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
        "RegisterNodeValidators(address admin,bytes32 nodeWalletsHash,bytes32 pubkeysHash,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant TRANSFER_NODES_TYPEHASH = keccak256(
        "TransferNodes(address fromBeneficiary,address toBeneficiary,address[] nodeWallets,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant REQUEST_FULL_EXIT_TYPEHASH = keccak256(
        "RequestFullExit(address beneficiary,address[] nodeWallets,uint256 nonce,uint256 deadline)"
    );

    event RedeemAdminAdded(address indexed account);
    event RedeemAdminRemoved(address indexed account);
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
        uint64 validBefore
    );
    event ValidatorRedeemCancelled(bytes32 indexed codeHash);
    /// @notice A CoNET DePIN node (IP + node wallet) is permanently bound to its beneficiary (1:1, set once).
    event DepinNodeBeneficiaryAssigned(bytes32 indexed ipHash, address indexed beneficiary, string conetDepinNodeIp);
    /// @notice A deployed validator is registered to a DePIN node wallet, withdrawal pointing to the beneficiary.
    event NodeValidatorRegistered(
        address indexed nodeWallet,
        address indexed withdrawalBeneficiary,
        bytes32 indexed pubkeyHash,
        bytes pubkey
    );
    /// @notice A validator's exit was recorded on chain (transfer step 1: withdraw, then redeploy elsewhere).
    event NodeValidatorExited(address indexed nodeWallet, bytes32 indexed pubkeyHash, address indexed withdrawalBeneficiary);
    /// @notice The current beneficiary transferred selected DePIN node wallets to a new beneficiary.
    event NodesTransferred(address indexed fromBeneficiary, address indexed toBeneficiary, address[] nodeWallets);
    /// @notice A node's existing validator must be exited so it can be redeployed with withdrawal -> new beneficiary.
    event NativeReceived(address indexed from, uint256 amount);
    /// @notice An admin transferred native CoNET (CNET) out of the contract.
    event NativeWithdrawn(address indexed to, uint256 amount);
    /// @notice The CoNET L1 beacon deposit contract address was configured.
    event DepositContractConfigured(address indexed depositContract);
    /// @notice This contract funded + deposited 32 CNET for a validator (0x01 withdrawal target = this contract).
    event ValidatorDeposited(address indexed nodeWallet, address indexed beneficiary, bytes32 indexed pubkeyHash, uint256 amount);
    /// @notice A node's validator economic beneficiary changed via transfer (fee_recipient hot-update; NO exit).
    ///         The owning validator node listens for this and hot-updates the validator's fee_recipient.
    event NodeValidatorBeneficiaryUpdated(
        address indexed nodeWallet,
        bytes32 indexed pubkeyHash,
        address indexed fromBeneficiary,
        address toBeneficiary
    );
    /// @notice A beneficiary requested a full exit of the listed nodes' validators (withdraw 32 CNET each).
    event FullExitRequested(address indexed beneficiary, address[] nodeWallets);
    /// @notice The contract advanced {amount} CNET ({validatorCount}×32) to a beneficiary on full exit settle.
    event FullExitSettled(address indexed beneficiary, uint256 validatorCount, uint256 amount);
    /// @notice The companion reward indexer contract address was configured.
    event RewardIndexerConfigured(address indexed rewardIndexer);
    /// @notice Referrer extension contract configured.
    event ReferrerExtensionConfigured(address indexed referrerExtension);
    /// @notice Transfer marketplace contract configured.
    event TransferMarketConfigured(address indexed transferMarket);
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
        require(redeemAdmins[msg.sender], "ValidatorRedeem: not admin");
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

    constructor(
        address initialRedeemAdmin,
        address gbToken_,
        address usdcToken_,
        address guardianNodes_,
        uint256 guardianAllocStartId_
    ) EIP712("ValidatorDepositRedeem", "1") {
        address admin = initialRedeemAdmin == address(0) ? msg.sender : initialRedeemAdmin;
        redeemAdmins[admin] = true;
        emit RedeemAdminAdded(admin);
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
    function withdrawNative(address to, uint256 amount) external onlyRedeemAdmin nonReentrantNative {
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
        onlyRedeemAdmin
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

    /// @notice Register deployed validators (admin/relayer is a redeem admin). One validator per node wallet.
    /// @param nodeWallets DePIN node operator wallets that already have a beneficiary (from a claim).
    /// @param pubkeys     Parallel BLS validator pubkeys (48 bytes each) deployed for those nodes.
    function registerNodeValidators(address[] calldata nodeWallets, bytes[] calldata pubkeys)
        external
        onlyRedeemAdmin
    {
        _registerNodeValidators(nodeWallets, pubkeys);
    }

    /// @notice EIP-712 signed variant: signed by a redeem admin, relayable by any gas sponsor (x402sdk Master).
    function registerNodeValidatorsFor(
        address admin,
        address[] calldata nodeWallets,
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
                keccak256(abi.encodePacked(nodeWallets)),
                _hashPubkeyArray(pubkeys),
                nonce,
                deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == admin, "ValidatorRedeem: bad sig");

        redeemAdminNonces[admin]++;
        _registerNodeValidators(nodeWallets, pubkeys);
    }

    /// @notice Record that a validator has been exited (transfer step 1). Marks the node's binding inactive
    ///         so the (node + validator) pair can be redeployed and re-pointed to a new beneficiary later.
    function recordNodeValidatorExit(address nodeWallet) external onlyRedeemAdmin {
        ValidatorBinding storage b = _nodeValidator[nodeWallet];
        require(b.pubkey.length != 0, "ValidatorRedeem: no validator");
        require(b.active, "ValidatorRedeem: already exited");
        b.active = false;
        b.exitedAt = uint64(block.timestamp);
        emit NodeValidatorExited(nodeWallet, keccak256(b.pubkey), b.withdrawalBeneficiary);
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
    /// @param nodeWallets DePIN node operator wallets (each must already have a beneficiary from a claim).
    /// @param pubkeys Parallel 48-byte BLS validator pubkeys.
    /// @param withdrawalCredentials Parallel 32-byte withdrawal credentials; each MUST equal {selfWithdrawalCredentials}.
    /// @param signatures Parallel BLS deposit signatures (96 bytes).
    /// @param depositDataRoots Parallel deposit data roots.
    function fundAndDepositValidators(
        address[] calldata nodeWallets,
        bytes[] calldata pubkeys,
        bytes[] calldata withdrawalCredentials,
        bytes[] calldata signatures,
        bytes32[] calldata depositDataRoots
    ) external onlyRedeemAdmin nonReentrantNative {
        require(address(depositContract) != address(0), "ValidatorRedeem: deposit unset");
        uint256 n = nodeWallets.length;
        require(n > 0, "ValidatorRedeem: empty");
        require(
            pubkeys.length == n &&
            withdrawalCredentials.length == n &&
            signatures.length == n &&
            depositDataRoots.length == n,
            "ValidatorRedeem: length mismatch"
        );
        require(address(this).balance >= VALIDATOR_STAKE_WEI * n, "ValidatorRedeem: insufficient stake balance");

        bytes32 selfCred = selfWithdrawalCredentials();
        for (uint256 i = 0; i < n; i++) {
            // Command of the custody model: withdrawal_credentials MUST point to this contract, else the
            // 32-CNET principal could be withdrawn elsewhere and lost from custody.
            require(withdrawalCredentials[i].length == 32, "ValidatorRedeem: bad wc length");
            require(_bytes32FromCalldata(withdrawalCredentials[i]) == selfCred, "ValidatorRedeem: withdrawal not self");

            address nodeWallet = nodeWallets[i];
            address beneficiary = _nodeWalletBeneficiary[nodeWallet];
            require(beneficiary != address(0), "ValidatorRedeem: node has no beneficiary");

            depositContract.deposit{value: VALIDATOR_STAKE_WEI}(
                pubkeys[i],
                withdrawalCredentials[i],
                signatures[i],
                depositDataRoots[i]
            );

            // Bind validator → node (withdrawalBeneficiary = node's current beneficiary) and credit ledger.
            _registerOneNodeValidator(nodeWallet, pubkeys[i]);
            stakedValidatorCountOf[beneficiary] += 1;
            fundedDepositTotal += VALIDATOR_STAKE_WEI;
            emit ValidatorDeposited(nodeWallet, beneficiary, keccak256(pubkeys[i]), VALIDATOR_STAKE_WEI);
        }
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
        address[] calldata nodeWallets,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(nodeWallets.length > 0, "ValidatorRedeem: empty");
        require(beneficiaryNonces[beneficiary] == nonce, "ValidatorRedeem: bad nonce");

        bytes32 structHash = keccak256(
            abi.encode(REQUEST_FULL_EXIT_TYPEHASH, beneficiary, _hashAddressArray(nodeWallets), nonce, deadline)
        );
        require(ECDSA.recover(_hashTypedDataV4(structHash), signature) == beneficiary, "ValidatorRedeem: bad sig");
        beneficiaryNonces[beneficiary]++;

        for (uint256 i = 0; i < nodeWallets.length; i++) {
            address nodeWallet = nodeWallets[i];
            require(_nodeWalletBeneficiary[nodeWallet] == beneficiary, "ValidatorRedeem: not your node");
            _requireNodeNotListedInMarket(nodeWallet);
            ValidatorBinding storage b = _nodeValidator[nodeWallet];
            require(b.pubkey.length != 0 && b.active, "ValidatorRedeem: no active validator");
            require(b.withdrawalBeneficiary == beneficiary, "ValidatorRedeem: beneficiary mismatch");
            b.active = false;
            b.exitedAt = uint64(block.timestamp);
            emit NodeValidatorExited(nodeWallet, keccak256(b.pubkey), beneficiary);
        }
        emit FullExitRequested(beneficiary, nodeWallets);
    }

    /// @notice Advance 32×count CNET to {beneficiary} for exited validators. Admin/relayer-only, called after
    ///         the off-chain exit is broadcast. Reverts if the pool can't cover the advance (relayer retries
    ///         once the auto-returned principal lands). Each pubkey is settled at most once (replay guard).
    function settleFullExitPayout(address beneficiary, address[] calldata nodeWallets)
        external
        onlyRedeemAdmin
        nonReentrantNative
    {
        require(beneficiary != address(0), "ValidatorRedeem: zero beneficiary");
        require(nodeWallets.length > 0, "ValidatorRedeem: empty");

        uint256 count = 0;
        for (uint256 i = 0; i < nodeWallets.length; i++) {
            address nodeWallet = nodeWallets[i];
            require(_nodeWalletBeneficiary[nodeWallet] == beneficiary, "ValidatorRedeem: not beneficiary node");
            ValidatorBinding storage b = _nodeValidator[nodeWallet];
            require(b.pubkey.length != 0, "ValidatorRedeem: no validator");
            require(b.withdrawalBeneficiary == beneficiary, "ValidatorRedeem: beneficiary mismatch");
            require(b.exitedAt != 0, "ValidatorRedeem: exit not requested");
            bytes32 pkHash = keccak256(b.pubkey);
            require(!exitSettledPubkey[pkHash], "ValidatorRedeem: already settled");
            exitSettledPubkey[pkHash] = true;
            count++;
        }

        uint256 amount = VALIDATOR_STAKE_WEI * count;
        require(address(this).balance >= amount, "ValidatorRedeem: insufficient balance");

        if (stakedValidatorCountOf[beneficiary] >= count) {
            stakedValidatorCountOf[beneficiary] -= count;
        } else {
            stakedValidatorCountOf[beneficiary] = 0;
        }

        (bool ok, ) = payable(beneficiary).call{value: amount}("");
        require(ok, "ValidatorRedeem: native transfer failed");
        emit NativeWithdrawn(beneficiary, amount);
        emit FullExitSettled(beneficiary, count, amount);
    }

    /// @notice EIP-712 digest the beneficiary must sign for {requestFullExit}.
    function getRequestFullExitDigest(
        address beneficiary,
        address[] calldata nodeWallets,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(REQUEST_FULL_EXIT_TYPEHASH, beneficiary, _hashAddressArray(nodeWallets), nonce, deadline)
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
    function transferOneNodeWalletForMarket(address from, address to, address nodeWallet) external {
        require(msg.sender == transferMarket, "ValidatorRedeem: not market");
        _transferOneNodeWallet(from, to, nodeWallet);
    }

    function _requireNodeNotListedInMarket(address nodeWallet) internal view {
        if (transferMarket == address(0)) return;
        require(
            IValidatorDepositRedeemTransferMarket(transferMarket).nodeOrder(nodeWallet) == 0,
            "ValidatorRedeem: node listed in order"
        );
    }

    /// @dev Load a 32-byte calldata bytes value as bytes32 (caller guarantees length == 32).
    function _bytes32FromCalldata(bytes calldata b) internal pure returns (bytes32 word) {
        assembly {
            word := calldataload(b.offset)
        }
    }

    function _registerNodeValidators(address[] calldata nodeWallets, bytes[] calldata pubkeys) internal {
        require(nodeWallets.length == pubkeys.length, "ValidatorRedeem: length mismatch");
        require(nodeWallets.length > 0, "ValidatorRedeem: empty");
        for (uint256 i = 0; i < nodeWallets.length; i++) {
            _registerOneNodeValidator(nodeWallets[i], pubkeys[i]);
        }
    }

    function _registerOneNodeValidator(address nodeWallet, bytes calldata pubkey) internal {
        require(nodeWallet != address(0), "ValidatorRedeem: zero node wallet");
        require(pubkey.length == 48, "ValidatorRedeem: bad pubkey length");
        address beneficiary = _nodeWalletBeneficiary[nodeWallet];
        require(beneficiary != address(0), "ValidatorRedeem: node has no beneficiary");

        bytes32 pkHash = keccak256(pubkey);
        address boundNode = _validatorPubkeyNode[pkHash];
        require(boundNode == address(0) || boundNode == nodeWallet, "ValidatorRedeem: pubkey bound elsewhere");

        ValidatorBinding storage b = _nodeValidator[nodeWallet];
        // 1:1 node↔validator: only (re)register when no active validator, or idempotent same pubkey.
        require(
            !b.active || keccak256(b.pubkey) == pkHash,
            "ValidatorRedeem: node already has active validator"
        );

        b.pubkey = pubkey;
        b.withdrawalBeneficiary = beneficiary;
        b.registeredAt = uint64(block.timestamp);
        b.exitedAt = 0;
        b.active = true;
        _validatorPubkeyNode[pkHash] = nodeWallet;

        emit NodeValidatorRegistered(nodeWallet, beneficiary, pkHash, pubkey);
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
        address[] calldata nodeWallets,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "ValidatorRedeem: expired");
        require(toBeneficiary != address(0), "ValidatorRedeem: zero to beneficiary");
        require(toBeneficiary != fromBeneficiary, "ValidatorRedeem: same beneficiary");
        require(nodeWallets.length > 0, "ValidatorRedeem: empty");
        require(beneficiaryNonces[fromBeneficiary] == nonce, "ValidatorRedeem: bad nonce");

        bytes32 structHash = keccak256(
            abi.encode(
                TRANSFER_NODES_TYPEHASH,
                fromBeneficiary,
                toBeneficiary,
                _hashAddressArray(nodeWallets),
                nonce,
                deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == fromBeneficiary, "ValidatorRedeem: bad sig");

        beneficiaryNonces[fromBeneficiary]++;

        for (uint256 i = 0; i < nodeWallets.length; i++) {
            _requireNodeNotListedInMarket(nodeWallets[i]);
            _transferOneNodeWallet(fromBeneficiary, toBeneficiary, nodeWallets[i]);
        }
        emit NodesTransferred(fromBeneficiary, toBeneficiary, nodeWallets);
    }

    /// @notice EIP-712 digest the current beneficiary must sign for {transferNodes}.
    function getTransferNodesDigest(
        address fromBeneficiary,
        address toBeneficiary,
        address[] calldata nodeWallets,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                TRANSFER_NODES_TYPEHASH,
                fromBeneficiary,
                toBeneficiary,
                _hashAddressArray(nodeWallets),
                nonce,
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function _hashAddressArray(address[] calldata arr) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            h[i] = bytes32(uint256(uint160(arr[i])));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _transferOneNodeWallet(address from, address to, address nodeWallet) internal {
        require(nodeWallet != address(0), "ValidatorRedeem: zero node wallet");
        require(_nodeWalletBeneficiary[nodeWallet] == from, "ValidatorRedeem: not from beneficiary node");

        uint256[] storage fromIds = _beneficiaryGuardianIds[from];
        address[] storage fromWallets = _beneficiaryGuardianNodeWallets[from];
        uint256 moved = 0;
        uint256 gbMoved = 0;
        uint256 i = 0;
        while (i < fromWallets.length) {
            if (fromWallets[i] != nodeWallet) {
                i++;
                continue;
            }
            uint256 nodeId = fromIds[i];
            guardianIdBeneficiary[nodeId] = to;
            _beneficiaryGuardianIds[to].push(nodeId);
            _beneficiaryGuardianNodeWallets[to].push(nodeWallet);
            if (guardianIdGbMining[nodeId]) {
                gbMoved++;
            }

            if (address(guardianNodes) != address(0)) {
                string memory ip = guardianNodes.id2ip(nodeId);
                if (bytes(ip).length != 0) {
                    bytes32 ipKey = keccak256(bytes(ip));
                    _depinIpBeneficiary[ipKey] = to;
                    _removeDepinIpFromWallet(from, ipKey);
                    _addDepinIpToWallet(to, ip, ipKey);
                    emit DepinNodeBeneficiaryAssigned(ipKey, to, ip);
                }
            }

            uint256 last = fromWallets.length - 1;
            fromIds[i] = fromIds[last];
            fromWallets[i] = fromWallets[last];
            fromIds.pop();
            fromWallets.pop();
            moved++;
            // do not advance i: a new element was swapped into slot i
        }
        require(moved > 0, "ValidatorRedeem: node not owned");

        _nodeWalletBeneficiary[nodeWallet] = to;

        // Legacy allocations (pre guardianIdGbMining): when every owned node was a GB node, move GB count 1:1.
        if (gbMoved == 0 && moved > 0 && gbMiningNodeCountOf[from] > 0 && gbMiningNodeCountOf[from] == validatorNodeCountOf[from]) {
            gbMoved = moved;
        }

        // Each guardian id ~ one validator node (auto-allocation assigns one id per validator).
        if (validatorNodeCountOf[from] >= moved) {
            validatorNodeCountOf[from] -= moved;
        } else {
            validatorNodeCountOf[from] = 0;
        }
        validatorNodeCountOf[to] += moved;

        if (gbMiningNodeCountOf[from] >= gbMoved) {
            gbMiningNodeCountOf[from] -= gbMoved;
        } else {
            gbMiningNodeCountOf[from] = 0;
        }
        gbMiningNodeCountOf[to] += gbMoved;

        // Hot-update the validator's economic beneficiary WITHOUT exiting. The 32-CNET principal stays in this
        // contract's custody (withdrawal_credentials 0x01 = this contract, immutable). Only the off-chain
        // fee_recipient is hot-updated by the owning validator node (no exit, no redeploy, same BLS pubkey).
        // Invariant: ValidatorBinding.withdrawalBeneficiary == fee_recipient == full-exit payout recipient.
        ValidatorBinding storage b = _nodeValidator[nodeWallet];
        if (b.pubkey.length != 0 && b.active) {
            b.withdrawalBeneficiary = to;
            emit NodeValidatorBeneficiaryUpdated(nodeWallet, keccak256(b.pubkey), from, to);
        }

        // Carry the staked-validator ledger with the node (one staked validator per active binding moved).
        if (b.pubkey.length != 0 && b.active) {
            if (stakedValidatorCountOf[from] > 0) {
                stakedValidatorCountOf[from] -= 1;
            }
            stakedValidatorCountOf[to] += 1;
        }
    }

    function _removeDepinIpFromWallet(address beneficiary, bytes32 ipKey) internal {
        if (!_walletDepinIpSeen[beneficiary][ipKey]) return;
        _walletDepinIpSeen[beneficiary][ipKey] = false;
        string[] storage arr = _walletDepinNodeIps[beneficiary];
        for (uint256 i = 0; i < arr.length; i++) {
            if (keccak256(bytes(arr[i])) == ipKey) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                break;
            }
        }
    }

    function _addDepinIpToWallet(address beneficiary, string memory ip, bytes32 ipKey) internal {
        if (_walletDepinIpSeen[beneficiary][ipKey]) return;
        _walletDepinIpSeen[beneficiary][ipKey] = true;
        _walletDepinNodeIps[beneficiary].push(ip);
    }

    /// @notice Create a redeem code. ALL redeems auto-assign consecutive Guardian node ids at claim
    ///         time (IPs + node wallets read from GuardianNodesInfoV6). No manual IP list is accepted.
    /// @dev    The same beneficiary may be the target of many redeems; each claim appends a fresh
    ///         consecutive block of Guardian nodes (see {_allocateGuardianNodesFromGuardian}).
    function createRedeem(
        bytes32 codeHash,
        address allowedClaimer,
        uint256 validatorCount,
        string calldata targetNodeIp,
        uint256 gbMiningNodeCount,
        uint64 validAfter,
        uint64 validBefore
    ) external onlyRedeemAdmin {
        _applyCreateRedeem(
            codeHash,
            allowedClaimer,
            validatorCount,
            targetNodeIp,
            gbMiningNodeCount,
            validAfter,
            validBefore
        );
    }

    /// @notice Gas-sponsored (meta-tx) variant of {createRedeem}. Auto-allocation only.
    function createRedeemFor(
        address admin,
        bytes32 codeHash,
        address allowedClaimer,
        uint256 validatorCount,
        string calldata targetNodeIp,
        uint256 gbMiningNodeCount,
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
                validatorCount,
                keccak256(bytes(targetNodeIp)),
                gbMiningNodeCount,
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
            validatorCount,
            targetNodeIp,
            gbMiningNodeCount,
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
        address referrer,
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
                referrer,
                uint256(r.validatorCount),
                keccak256(bytes(r.targetNodeIp)),
                uint256(r.gbMiningNodeCount),
                deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == claimer, "ValidatorRedeem: bad sig");

        requestId = _consumeAndEmit(codeHash, claimer, beneficiary, referrer, r);
    }

    function claimRedeem(string calldata code, address beneficiary) external returns (bytes32 requestId) {
        return _claimRedeemWithReferrer(code, beneficiary, address(0));
    }

    function _claimRedeemWithReferrer(string calldata code, address beneficiary, address referrer)
        internal
        returns (bytes32 requestId)
    {
        require(beneficiary != address(0), "ValidatorRedeem: zero beneficiary");
        bytes memory b = bytes(code);
        require(b.length > 0 && b.length <= _MAX_REDEEM_CODE_LEN, "ValidatorRedeem: bad code len");
        bytes32 codeHash = keccak256(b);

        Redeem storage r = _redeems[codeHash];
        require(r.active, "ValidatorRedeem: inactive");
        require(!r.consumed, "ValidatorRedeem: consumed");
        require(_timeOk(r.validAfter, r.validBefore), "ValidatorRedeem: time window");
        require(r.allowedClaimer == address(0) || r.allowedClaimer == msg.sender, "ValidatorRedeem: claimer not allowed");

        requestId = _consumeAndEmit(codeHash, msg.sender, beneficiary, referrer, r);
    }

    function getCreateRedeemDigest(
        address admin,
        bytes32 codeHash,
        address allowedClaimer,
        uint256 validatorCount,
        string calldata targetNodeIp,
        uint256 gbMiningNodeCount,
        uint256 validAfter,
        uint256 validBefore,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_REDEEM_TYPEHASH,
                admin,
                codeHash,
                allowedClaimer,
                validatorCount,
                keccak256(bytes(targetNodeIp)),
                gbMiningNodeCount,
                validAfter,
                validBefore,
                nonce,
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function getClaimRedeemDigest(
        address claimer,
        bytes32 codeHash,
        address beneficiary,
        address referrer,
        uint256 deadline
    ) external view returns (bytes32) {
        Redeem storage r = _redeems[codeHash];
        bytes32 structHash = keccak256(
            abi.encode(
                CLAIM_REDEEM_TYPEHASH,
                claimer,
                codeHash,
                beneficiary,
                referrer,
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
            uint256 validatorCount,
            string memory targetNodeIp,
            uint256 gbMiningNodeCount,
            uint64 validAfter,
            uint64 validBefore,
            bool active,
            bool consumed
        )
    {
        Redeem storage r = _redeems[codeHash];
        return (
            r.allowedClaimer,
            uint256(r.validatorCount),
            r.targetNodeIp,
            uint256(r.gbMiningNodeCount),
            r.validAfter,
            r.validBefore,
            r.active,
            r.consumed
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

    /// @notice Reverse lookup by the precomputed keccak256(bytes(ip)) hash.
    function getDepinBeneficiaryByIpHash(bytes32 ipHash) external view returns (address beneficiary) {
        return _depinIpBeneficiary[ipHash];
    }

    /**
     * @notice Whether a wallet is the current beneficiary owner of the given DePIN node IP.
     * @dev Lets callers resolve a beneficiary either from a DePIN node IP or by confirming a wallet address.
     */
    function isDepinBeneficiaryOfIp(string calldata conetDepinNodeIp, address wallet) external view returns (bool) {
        return _depinIpBeneficiary[keccak256(bytes(conetDepinNodeIp))] == wallet;
    }

    /// @notice Reverse lookup: the beneficiary a node operator wallet belongs to ({address(0)} if none).
    function getBeneficiaryByNodeWallet(address nodeWallet) external view returns (address beneficiary) {
        return _nodeWalletBeneficiary[nodeWallet];
    }

    /// @notice The validator binding registered to a DePIN node wallet ({active}=false once exited).
    function getNodeValidator(address nodeWallet)
        external
        view
        returns (bytes memory pubkey, address withdrawalBeneficiary, uint64 registeredAt, uint64 exitedAt, bool active)
    {
        ValidatorBinding storage b = _nodeValidator[nodeWallet];
        return (b.pubkey, b.withdrawalBeneficiary, b.registeredAt, b.exitedAt, b.active);
    }

    /// @notice Reverse lookup: the DePIN node wallet a validator pubkey was registered to ({address(0)} if none).
    function getNodeByValidatorPubkey(bytes calldata pubkey) external view returns (address nodeWallet) {
        return _validatorPubkeyNode[keccak256(pubkey)];
    }

    /// @notice Reverse lookup by precomputed pubkey hash (keccak256 of the 48-byte BLS pubkey).
    function getNodeByValidatorPubkeyHash(bytes32 pubkeyHash) external view returns (address nodeWallet) {
        return _validatorPubkeyNode[pubkeyHash];
    }

    /// @notice EIP-712 digest a redeem admin must sign for {registerNodeValidatorsFor}.
    function getRegisterNodeValidatorsDigest(
        address admin,
        address[] calldata nodeWallets,
        bytes[] calldata pubkeys,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                REGISTER_NODE_VALIDATORS_TYPEHASH,
                admin,
                keccak256(abi.encodePacked(nodeWallets)),
                _hashPubkeyArray(pubkeys),
                nonce,
                deadline
            )
        );
        return _hashTypedDataV4(structHash);
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

    /// @dev Assemble the full {NodeBundle} for a beneficiary. Live IP / node wallet are read from Guardian.
    function _buildNodeBundle(address beneficiary) internal view returns (NodeBundle memory b) {
        b.beneficiary = beneficiary;
        if (beneficiary == address(0)) {
            b.guardianNodeIds = new uint256[](0);
            b.depinNodeIps = new string[](0);
            b.nodeWallets = new address[](0);
            b.validatorPubkeys = new bytes[](0);
            b.validatorActive = new bool[](0);
            return b;
        }
        uint256[] memory ids = _beneficiaryGuardianIds[beneficiary];
        uint256 n = ids.length;
        b.guardianNodeIds = ids;
        b.depinNodeIps = new string[](n);
        b.nodeWallets = new address[](n);
        b.validatorPubkeys = new bytes[](n);
        b.validatorActive = new bool[](n);
        if (address(guardianNodes) != address(0)) {
            for (uint256 i = 0; i < n; i++) {
                uint256 nodeId = ids[i];
                string memory ip = guardianNodes.id2ip(nodeId);
                b.depinNodeIps[i] = ip;
                address w = guardianNodes.idOwner(nodeId);
                if (w == address(0) && bytes(ip).length != 0) {
                    w = guardianNodes.ipaddress2owner(ip);
                }
                b.nodeWallets[i] = w;
                if (w != address(0)) {
                    ValidatorBinding storage vb = _nodeValidator[w];
                    b.validatorPubkeys[i] = vb.pubkey;
                    b.validatorActive[i] = vb.active;
                }
            }
        }
        b.validatorNodeCount = validatorNodeCountOf[beneficiary];
        b.gbMiningNodeCount = gbMiningNodeCountOf[beneficiary];
        b.claimCount = walletClaimCountOf[beneficiary];
        b.nativeBalance = beneficiary.balance;
        b.gbBalance = _safeGbBalance(beneficiary);
        b.usdcBalance = _safeUsdcBalance(beneficiary);
    }

    /// @dev All redeems are auto-allocation: no IP list is stored at create; consecutive Guardian
    ///      node ids (and their IPs + node wallets) are resolved at claim time.
    function _applyCreateRedeem(
        bytes32 codeHash,
        address allowedClaimer,
        uint256 validatorCount,
        string calldata targetNodeIp,
        uint256 gbMiningNodeCount,
        uint64 validAfter,
        uint64 validBefore
    ) internal {
        require(address(guardianNodes) != address(0), "ValidatorRedeem: guardian unset");
        require(codeHash != bytes32(0), "ValidatorRedeem: invalid hash");
        require(validatorCount > 0 && validatorCount <= type(uint128).max, "ValidatorRedeem: invalid validators");
        require(gbMiningNodeCount <= type(uint128).max, "ValidatorRedeem: gb overflow");
        _requireValidIpString(targetNodeIp);

        Redeem storage r = _redeems[codeHash];
        require(!r.consumed, "ValidatorRedeem: hash consumed");
        require(!r.active, "ValidatorRedeem: already active");

        r.allowedClaimer = allowedClaimer;
        r.validatorCount = uint128(validatorCount);
        r.gbMiningNodeCount = uint128(gbMiningNodeCount);
        r.validAfter = validAfter;
        r.validBefore = validBefore;
        r.active = true;
        r.targetNodeIp = targetNodeIp;

        emit ValidatorRedeemCreated(
            codeHash,
            allowedClaimer,
            validatorCount,
            targetNodeIp,
            gbMiningNodeCount,
            validAfter,
            validBefore
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

            // Strict 1:1 — a node operator wallet must not serve two beneficiaries.
            address nodeWalletBen = _nodeWalletBeneficiary[nodeWallet];
            require(
                nodeWalletBen == address(0) || nodeWalletBen == beneficiary,
                "ValidatorRedeem: node wallet other beneficiary"
            );
            if (nodeWalletBen == address(0)) {
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
}
