// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IWalletDashERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IWalletDashVDR {
    struct NodeBundle {
        address beneficiary;
        uint256[] guardianNodeIds;
        string[] depinNodeIps;
        address[] nodeWallets;
        bytes[] validatorPubkeys;
        bool[] validatorActive;
        uint256 validatorNodeCount;
        uint256 gbMiningNodeCount;
        uint256 claimCount;
        uint256 nativeBalance;
        uint256 gbBalance;
        uint256 usdcBalance;
    }

    function resolveNodeBundle(address maybeWallet, string calldata conetDepinNodeIp)
        external
        view
        returns (NodeBundle memory);

    function referrerExtension() external view returns (address);
}

interface IWalletDashReferrerExt {
    function getReferrerSummary(address referrer)
        external
        view
        returns (
            uint256 referredBeneficiaryCount,
            uint256 referralNodeTotal,
            uint256 rewardMilestonePaid,
            uint256 pendingRewardNodes,
            uint256 referredNodesOwnedTotal
        );

    function REFERRER_NODES_PER_REWARD() external view returns (uint256);
}

interface IWalletDashReferralRegistry {
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

    function merchantQuotas(address merchant)
        external
        view
        returns (
            uint256 starterKetRemaining,
            uint256 paidBunitRemaining,
            uint256 issuedCodeCount,
            uint256 claimedCodeCount
        );
}

/**
 * @title BeamioConsumerWalletDashboard
 * @notice Read-only aggregator for SilentPassUI App Daemon 6s wallet tick.
 * @dev Single eth_call `snapshot(eoa, aaOptional)` returns balances + light VDR profile
 *      + L0 quota + referrer summary. Does NOT include resolveUnifiedIncomeStats (too heavy)
 *      or Discover/Coupon dynamic targets (use Multicall3 instead).
 *
 *      UUPS upgradeable; canonical address = ERC1967 proxy.
 */
contract BeamioConsumerWalletDashboard is Initializable, UUPSUpgradeable {
    uint8 private constant ROLE_L0 = 1;

    address public usdc;
    address public gbToken;
    address public validatorDepositRedeem;
    address public referralRegistry;
    mapping(address => bool) public admins;

    struct WalletSnapshot {
        address eoa;
        address aa;
        uint256 eoaNative;
        uint256 eoaUsdc;
        uint256 eoaGb;
        uint256 aaNative;
        uint256 aaUsdc;
        uint256 aaGb;
        address beneficiary;
        uint256 validatorNodeCount;
        uint256 validatorPendingCount;
        uint256 gbMiningNodeCount;
        uint256 claimCount;
        uint256 vdrNative;
        uint256 vdrGb;
        uint256 vdrUsdc;
        bool isL0;
        uint256 starterKetRemaining;
        uint256 paidBunitRemaining;
        uint256 issuedCodeCount;
        uint256 claimedCodeCount;
        uint256 referredBeneficiaryCount;
        uint256 referralNodeTotal;
        uint256 rewardMilestonePaid;
        uint256 pendingRewardNodes;
        uint256 referredNodesOwnedTotal;
        uint256 nodesPerReward;
    }

    event AdminAdded(address indexed admin);
    event AdminRemoved(address indexed admin);
    event AddressesUpdated(address usdc, address gbToken, address vdr, address referralRegistry);

    modifier onlyAdmin() {
        require(admins[msg.sender], "WalletDashboard: not admin");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialAdmin,
        address usdc_,
        address gbToken_,
        address validatorDepositRedeem_,
        address referralRegistry_
    ) external initializer {
        __UUPSUpgradeable_init();
        address a = initialAdmin == address(0) ? msg.sender : initialAdmin;
        admins[a] = true;
        emit AdminAdded(a);
        _setAddresses(usdc_, gbToken_, validatorDepositRedeem_, referralRegistry_);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}

    function version() external pure returns (uint256) {
        return 1;
    }

    function addAdmin(address admin) external onlyAdmin {
        require(admin != address(0), "WalletDashboard: zero");
        admins[admin] = true;
        emit AdminAdded(admin);
    }

    function removeAdmin(address admin) external onlyAdmin {
        admins[admin] = false;
        emit AdminRemoved(admin);
    }

    function setAddresses(
        address usdc_,
        address gbToken_,
        address validatorDepositRedeem_,
        address referralRegistry_
    ) external onlyAdmin {
        _setAddresses(usdc_, gbToken_, validatorDepositRedeem_, referralRegistry_);
    }

    function _setAddresses(
        address usdc_,
        address gbToken_,
        address validatorDepositRedeem_,
        address referralRegistry_
    ) internal {
        require(
            usdc_ != address(0) && gbToken_ != address(0) && validatorDepositRedeem_ != address(0)
                && referralRegistry_ != address(0),
            "WalletDashboard: zero addr"
        );
        usdc = usdc_;
        gbToken = gbToken_;
        validatorDepositRedeem = validatorDepositRedeem_;
        referralRegistry = referralRegistry_;
        emit AddressesUpdated(usdc_, gbToken_, validatorDepositRedeem_, referralRegistry_);
    }

    /**
     * @notice One-shot dashboard read for consumer EOA (+ optional AA).
     * @param eoa Consumer main wallet
     * @param aaOptional Smart wallet; address(0) skips AA balances
     */
    function snapshot(address eoa, address aaOptional) external view returns (WalletSnapshot memory s) {
        require(eoa != address(0), "WalletDashboard: eoa zero");
        s.eoa = eoa;
        s.aa = aaOptional;
        s.eoaNative = eoa.balance;
        s.eoaUsdc = IWalletDashERC20(usdc).balanceOf(eoa);
        s.eoaGb = IWalletDashERC20(gbToken).balanceOf(eoa);
        if (aaOptional != address(0)) {
            s.aaNative = aaOptional.balance;
            s.aaUsdc = IWalletDashERC20(usdc).balanceOf(aaOptional);
            s.aaGb = IWalletDashERC20(gbToken).balanceOf(aaOptional);
        }

        IWalletDashVDR.NodeBundle memory bundle =
            IWalletDashVDR(validatorDepositRedeem).resolveNodeBundle(eoa, "");
        s.beneficiary = bundle.beneficiary;
        s.validatorNodeCount = bundle.validatorNodeCount;
        s.gbMiningNodeCount = bundle.gbMiningNodeCount;
        s.claimCount = bundle.claimCount;
        s.vdrNative = bundle.nativeBalance;
        s.vdrGb = bundle.gbBalance;
        s.vdrUsdc = bundle.usdcBalance;
        uint256 active;
        uint256 len = bundle.validatorActive.length;
        for (uint256 i = 0; i < len;) {
            if (bundle.validatorActive[i]) {
                unchecked {
                    ++active;
                }
            }
            unchecked {
                ++i;
            }
        }
        s.validatorPendingCount =
            s.validatorNodeCount > active ? s.validatorNodeCount - active : 0;

        (uint8 role,,,,,) = IWalletDashReferralRegistry(referralRegistry).members(eoa);
        if (role == ROLE_L0) {
            s.isL0 = true;
            (s.starterKetRemaining, s.paidBunitRemaining, s.issuedCodeCount, s.claimedCodeCount) =
                IWalletDashReferralRegistry(referralRegistry).merchantQuotas(eoa);
        }

        // VDR may return a sentinel (e.g. address(1)) when extension is unset — require code.
        address ext = IWalletDashVDR(validatorDepositRedeem).referrerExtension();
        if (ext.code.length > 0) {
            (
                s.referredBeneficiaryCount,
                s.referralNodeTotal,
                s.rewardMilestonePaid,
                s.pendingRewardNodes,
                s.referredNodesOwnedTotal
            ) = IWalletDashReferrerExt(ext).getReferrerSummary(eoa);
            s.nodesPerReward = IWalletDashReferrerExt(ext).REFERRER_NODES_PER_REWARD();
        }
    }

    uint256[44] private __gap;
}
