// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "../contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

interface IReferralVaultMembersV1 {
    function members(address account)
        external
        view
        returns (
            uint8 role,
            address parentAdmin,
            address parentL0,
            uint256 rebateBps,
            uint256 ratioBps,
            bool active
        );

    function admins(address account) external view returns (bool);
}

/**
 * @title ReferralPurchaseSplitV1
 * @notice Fuel Pack purchase USDC split: 60% immediate (Admin + project wallets), 40% escrowed
 *         until paid B-Units burn. Charge / unbacked paid burns stay on BUnitAirdropV2 + Vault.
 *
 * Canonical address = ERC1967 proxy. UUPS-upgradeable.
 */
contract ReferralPurchaseSplitV1 is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    uint256 public constant BPS = 10_000;
    uint256 public constant IMMEDIATE_BPS = 6_000;
    uint256 public constant DEFERRED_BPS = 4_000;
    uint256 public constant MAX_DEFERRED_REBATE_BPS = 4_000;
    uint256 public constant MAX_PROJECT_WALLETS = 16;
    uint8 internal constant ROLE_L0 = 1;
    uint8 internal constant ROLE_L1 = 2;
    uint8 internal constant ROLE_MERCHANT = 3;

    bytes32 private constant _EIP712_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _EIP712_NAME_HASH = keccak256("ReferralPurchaseSplitV1");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("1");
    bytes32 public constant SET_IMMEDIATE_SPLIT_TYPEHASH = keccak256(
        "SetImmediateSplit(address admin,address adminPayout,uint256 adminBps,address[] wallets,uint256[] bps,uint256 nonce,uint256 deadline)"
    );

    address public conetUsdc;
    address public vault;
    address public airdrop;

    address public adminPayout;
    uint256 public adminBps;
    address[] public projectWallets;
    uint256[] public projectBps;

    mapping(address => uint256) public escrowedPaid;
    mapping(bytes32 => bool) public purchaseAllocated;
    mapping(address => uint256) public actionNonces;

    error Unauthorized();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidSplit();
    error SignatureExpired();
    error InvalidSignature();
    error AlreadyAllocated();
    error TransferFailed();

    event ImmediateSplitUpdated(address indexed adminPayout, uint256 adminBps, address[] wallets, uint256[] bps);
    event PurchaseAllocated(
        address indexed beneficiary,
        uint256 usdcAmount,
        uint256 immediateUsdc,
        uint256 deferredUsdc,
        bytes32 indexed sourceHash
    );
    event EscrowTaken(address indexed user, uint256 paidTaken, uint256 remaining);
    event DeferredReleased(
        address indexed user,
        uint256 paidBurned,
        uint256 originalUsdc,
        uint256 l0Pool,
        uint256 adminPart,
        bytes32 indexed sourceHash
    );
    event AirdropUpdated(address indexed airdrop);

    modifier onlyAirdrop() {
        if (msg.sender != airdrop) revert Unauthorized();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address conetUsdc_,
        address vault_,
        address airdrop_,
        address adminPayout_
    ) external initializer {
        if (
            owner_ == address(0) ||
            conetUsdc_ == address(0) ||
            vault_ == address(0) ||
            airdrop_ == address(0) ||
            adminPayout_ == address(0)
        ) revert InvalidAddress();
        __Ownable_init(owner_);
        __UUPSUpgradeable_init();
        conetUsdc = conetUsdc_;
        vault = vault_;
        airdrop = airdrop_;
        adminPayout = adminPayout_;
        adminBps = IMMEDIATE_BPS;
        emit ImmediateSplitUpdated(adminPayout_, IMMEDIATE_BPS, new address[](0), new uint256[](0));
        emit AirdropUpdated(airdrop_);
    }

    function _authorizeUpgrade(address) internal view override onlyOwner {}

    function setAirdrop(address airdrop_) external onlyOwner {
        if (airdrop_ == address(0)) revert InvalidAddress();
        airdrop = airdrop_;
        emit AirdropUpdated(airdrop_);
    }

    function projectWalletCount() external view returns (uint256) {
        return projectWallets.length;
    }

    function immediateSplit()
        external
        view
        returns (address payout, uint256 payoutBps, address[] memory wallets, uint256[] memory bps)
    {
        return (adminPayout, adminBps, projectWallets, projectBps);
    }

    function setImmediateSplit(address adminPayout_, uint256 adminBps_, address[] calldata wallets, uint256[] calldata bps)
        external
        onlyOwner
    {
        _setImmediateSplit(adminPayout_, adminBps_, wallets, bps);
    }

    function setImmediateSplitFor(
        address admin,
        address adminPayout_,
        uint256 adminBps_,
        address[] calldata wallets,
        uint256[] calldata bps,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (!IReferralVaultMembersV1(vault).admins(admin)) revert Unauthorized();
        if (block.timestamp > deadline) revert SignatureExpired();
        if (actionNonces[admin] != nonce) revert InvalidSignature();
        bytes32 structHash = keccak256(
            abi.encode(
                SET_IMMEDIATE_SPLIT_TYPEHASH,
                admin,
                adminPayout_,
                adminBps_,
                _hashAddressArray(wallets),
                _hashUint256Array(bps),
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        if (ECDSA.recover(digest, signature) != admin) revert InvalidSignature();
        actionNonces[admin] = nonce + 1;
        _setImmediateSplit(adminPayout_, adminBps_, wallets, bps);
    }

    function allocatePurchase(address beneficiary, uint256 usdcAmount, bytes32 sourceHash) external onlyAirdrop {
        if (beneficiary == address(0) || usdcAmount == 0) revert InvalidAmount();
        if (purchaseAllocated[sourceHash]) revert AlreadyAllocated();
        purchaseAllocated[sourceHash] = true;

        uint256 immediate = (usdcAmount * IMMEDIATE_BPS) / BPS;
        _payImmediate(immediate);
        escrowedPaid[beneficiary] += usdcAmount * 100;
        emit PurchaseAllocated(beneficiary, usdcAmount, immediate, usdcAmount - immediate, sourceHash);
    }

    function takeEscrowedPaid(address user, uint256 paidBurned) external onlyAirdrop returns (uint256 taken) {
        uint256 escrowed = escrowedPaid[user];
        taken = paidBurned < escrowed ? paidBurned : escrowed;
        if (taken > 0) {
            escrowedPaid[user] = escrowed - taken;
        }
        emit EscrowTaken(user, taken, escrowedPaid[user]);
    }

    function releaseDeferred(address user, uint256 paidBurned, bytes32 sourceHash) external onlyAirdrop {
        if (user == address(0) || paidBurned == 0) revert InvalidAmount();
        uint256 originalUsdc = paidBurned / 100;
        if (originalUsdc == 0) return;
        uint256 deferred = (originalUsdc * DEFERRED_BPS) / BPS;

        (uint8 role, address parentAdmin, address parentL0, , uint256 ratioBps, bool active) =
            IReferralVaultMembersV1(vault).members(user);

        address l0;
        address l1;
        if (role == ROLE_MERCHANT && active) {
            l0 = parentL0;
        } else if (role == ROLE_L1 && active) {
            l0 = parentL0;
            l1 = user;
        }

        if (l0 == address(0)) {
            _transferUsdc(adminPayout, deferred);
            emit DeferredReleased(user, paidBurned, originalUsdc, 0, deferred, sourceHash);
            return;
        }

        (, , , uint256 rebateBps, , bool l0Active) = IReferralVaultMembersV1(vault).members(l0);
        if (!l0Active) {
            _transferUsdc(adminPayout, deferred);
            emit DeferredReleased(user, paidBurned, originalUsdc, 0, deferred, sourceHash);
            return;
        }
        if (rebateBps > MAX_DEFERRED_REBATE_BPS) rebateBps = MAX_DEFERRED_REBATE_BPS;
        uint256 l0Pool = (originalUsdc * rebateBps) / BPS;
        if (l0Pool > deferred) l0Pool = deferred;
        uint256 adminPart = deferred - l0Pool;

        uint256 l1Reward;
        if (role == ROLE_MERCHANT) {
            l1 = parentAdmin;
            if (l1 != address(0)) {
                (uint8 l1Role, , address l1ParentL0, , uint256 l1Ratio, bool l1Active) =
                    IReferralVaultMembersV1(vault).members(l1);
                if (l1Role != ROLE_L1 || !l1Active || l1ParentL0 != l0) l1 = address(0);
                else ratioBps = l1Ratio;
            }
        }
        if (l1 != address(0) && l0Pool > 0) {
            l1Reward = (l0Pool * ratioBps) / BPS;
            if (l1Reward > l0Pool) l1Reward = l0Pool;
            if (l1Reward > 0) _transferUsdc(l1, l1Reward);
        }
        uint256 l0Reward = l0Pool - l1Reward;
        if (l0Reward > 0) _transferUsdc(l0, l0Reward);
        if (adminPart > 0) _transferUsdc(adminPayout, adminPart);
        emit DeferredReleased(user, paidBurned, originalUsdc, l0Pool, adminPart, sourceHash);
    }

    function _setImmediateSplit(
        address adminPayout_,
        uint256 adminBps_,
        address[] calldata wallets,
        uint256[] calldata bps
    ) internal {
        if (adminPayout_ == address(0)) revert InvalidAddress();
        if (wallets.length != bps.length || wallets.length > MAX_PROJECT_WALLETS) revert InvalidSplit();
        uint256 sum = adminBps_;
        for (uint256 i; i < wallets.length; ++i) {
            if (wallets[i] == address(0) || bps[i] == 0) revert InvalidSplit();
            sum += bps[i];
        }
        if (sum != IMMEDIATE_BPS) revert InvalidSplit();
        adminPayout = adminPayout_;
        adminBps = adminBps_;
        delete projectWallets;
        delete projectBps;
        for (uint256 i; i < wallets.length; ++i) {
            projectWallets.push(wallets[i]);
            projectBps.push(bps[i]);
        }
        emit ImmediateSplitUpdated(adminPayout_, adminBps_, wallets, bps);
    }

    function _payImmediate(uint256 immediate) internal {
        if (immediate == 0) return;
        uint256 remaining = immediate;
        uint256 adminShare = (immediate * adminBps) / IMMEDIATE_BPS;
        if (adminShare > remaining) adminShare = remaining;
        if (adminShare > 0) {
            _transferUsdc(adminPayout, adminShare);
            remaining -= adminShare;
        }
        uint256 n = projectWallets.length;
        for (uint256 i; i < n; ++i) {
            uint256 share;
            if (i + 1 == n) {
                share = remaining;
            } else {
                share = (immediate * projectBps[i]) / IMMEDIATE_BPS;
                if (share > remaining) share = remaining;
            }
            if (share > 0) {
                _transferUsdc(projectWallets[i], share);
                remaining -= share;
            }
        }
        if (remaining > 0) _transferUsdc(adminPayout, remaining);
    }

    function _transferUsdc(address to, uint256 amount) internal {
        if (to == address(0) || amount == 0) revert InvalidAddress();
        if (!IERC20(conetUsdc).transfer(to, amount)) revert TransferFailed();
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(_EIP712_TYPE_HASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, address(this))
        );
    }

    function _hashAddressArray(address[] calldata arr) internal pure returns (bytes32) {
        bytes32[] memory encoded = new bytes32[](arr.length);
        for (uint256 i; i < arr.length; ++i) {
            encoded[i] = bytes32(uint256(uint160(arr[i])));
        }
        return keccak256(abi.encodePacked(encoded));
    }

    function _hashUint256Array(uint256[] calldata arr) internal pure returns (bytes32) {
        bytes32[] memory encoded = new bytes32[](arr.length);
        for (uint256 i; i < arr.length; ++i) {
            encoded[i] = bytes32(arr[i]);
        }
        return keccak256(abi.encodePacked(encoded));
    }
}
