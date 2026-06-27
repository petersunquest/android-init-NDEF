// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Callback on ValidatorDepositRedeem to allocate milestone reward nodes and read beneficiary node counts.
interface IReferrerRewardHost {
    function grantReferrerRewardNodes(address referrer, uint256 count) external;
    function validatorNodeCountOf(address beneficiary) external view returns (uint256);
    function getReferrerRewardNodes(address referrer)
        external
        view
        returns (uint256[] memory guardianNodeIds, address[] memory nodeWallets, string[] memory depinNodeIps);
}

/**
 * @title ValidatorDepositRedeemReferrerExtension
 * @notice Referrer ledger for ValidatorDepositRedeem: bind introducer on claim, track referral nodes,
 *         and report reward milestones. Reward node allocation stays on the main redeem contract.
 * @dev Deployed separately to keep ValidatorDepositRedeem under the EIP-170 size limit.
 */
contract ValidatorDepositRedeemReferrerExtension {
    /// @notice Referral nodes required per auto-reward validator + DePIN bundle.
    uint256 public constant REFERRER_NODES_PER_REWARD = 10;

    address public redeemHost;
    address public admin;

    mapping(address => address) public referrerOfBeneficiary;
    mapping(address => uint256) public referrerReferralNodeTotal;
    mapping(address => uint256) public referrerRewardMilestonePaid;
    mapping(address => address[]) private _referrerReferredBeneficiaries;
    mapping(address => mapping(address => bool)) private _referrerReferredSeen;

    event ReferrerHostConfigured(address indexed redeemHost);
    event BeneficiaryReferrerBound(address indexed beneficiary, address indexed referrer);
    event ReferrerReferralNodesAccrued(
        address indexed referrer,
        address indexed beneficiary,
        uint256 nodeCount,
        uint256 referralNodeTotal
    );
    event ReferrerRewardMilestonePaid(address indexed referrer, uint256 milestonePaid, uint256 rewardNodesGranted);

    /// @notice One reward node granted to a referrer (validator + DePIN bundle).
    struct ReferrerRewardNodeDetail {
        uint256 guardianNodeId;
        address nodeWallet;
        string depinNodeIp;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "ReferrerExt: not admin");
        _;
    }

    modifier onlyRedeemHost() {
        require(msg.sender == redeemHost, "ReferrerExt: not host");
        _;
    }

    constructor(address admin_) {
        require(admin_ != address(0), "ReferrerExt: zero admin");
        admin = admin_;
    }

    function setRedeemHost(address redeemHost_) external onlyAdmin {
        require(redeemHost_ != address(0), "ReferrerExt: zero host");
        redeemHost = redeemHost_;
        emit ReferrerHostConfigured(redeemHost_);
    }

    /// @notice Called by ValidatorDepositRedeem after a successful claim. Returns reward node count to grant on host.
    function onBeneficiaryClaim(address beneficiary, address referrer, uint256 validatorCountFromClaim)
        external
        onlyRedeemHost
        returns (uint256 rewardNodesToGrant)
    {
        if (referrer == address(0)) {
            return 0;
        }
        require(referrer != beneficiary, "ReferrerExt: self referrer");

        address existing = referrerOfBeneficiary[beneficiary];
        if (existing == address(0)) {
            referrerOfBeneficiary[beneficiary] = referrer;
            if (!_referrerReferredSeen[referrer][beneficiary]) {
                _referrerReferredSeen[referrer][beneficiary] = true;
                _referrerReferredBeneficiaries[referrer].push(beneficiary);
            }
            emit BeneficiaryReferrerBound(beneficiary, referrer);
        } else {
            require(existing == referrer, "ReferrerExt: referrer mismatch");
        }

        if (validatorCountFromClaim == 0) {
            return 0;
        }

        referrerReferralNodeTotal[referrer] += validatorCountFromClaim;
        emit ReferrerReferralNodesAccrued(
            referrer, beneficiary, validatorCountFromClaim, referrerReferralNodeTotal[referrer]
        );

        uint256 milestone = referrerReferralNodeTotal[referrer] / REFERRER_NODES_PER_REWARD;
        uint256 paid = referrerRewardMilestonePaid[referrer];
        if (milestone > paid) {
            rewardNodesToGrant = milestone - paid;
            referrerRewardMilestonePaid[referrer] = milestone;
            emit ReferrerRewardMilestonePaid(referrer, milestone, rewardNodesToGrant);
            if (rewardNodesToGrant > 0) {
                IReferrerRewardHost(redeemHost).grantReferrerRewardNodes(referrer, rewardNodesToGrant);
            }
        }
    }

    function getReferrerReferredBeneficiaryCount(address referrer) external view returns (uint256) {
        return _referrerReferredBeneficiaries[referrer].length;
    }

    function getReferrerReferredBeneficiaries(address referrer, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory slice)
    {
        address[] storage all = _referrerReferredBeneficiaries[referrer];
        if (offset >= all.length) {
            return new address[](0);
        }
        uint256 end = offset + limit;
        if (end > all.length) {
            end = all.length;
        }
        slice = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            slice[i - offset] = all[i];
        }
    }

    /// @notice Referrer dashboard: referred wallets, cumulative referral nodes, reward progress, and referred wallets' current node totals.
    function getReferrerSummary(address referrer)
        external
        view
        returns (
            uint256 referredBeneficiaryCount,
            uint256 referralNodeTotal,
            uint256 rewardMilestonePaid,
            uint256 pendingRewardNodes,
            uint256 referredNodesOwnedTotal
        )
    {
        address[] storage refs = _referrerReferredBeneficiaries[referrer];
        referredBeneficiaryCount = refs.length;
        referralNodeTotal = referrerReferralNodeTotal[referrer];
        rewardMilestonePaid = referrerRewardMilestonePaid[referrer];
        uint256 milestone = referralNodeTotal / REFERRER_NODES_PER_REWARD;
        pendingRewardNodes = milestone > rewardMilestonePaid ? milestone - rewardMilestonePaid : 0;
        uint256 owned;
        address host = redeemHost;
        for (uint256 i = 0; i < refs.length; i++) {
            owned += IReferrerRewardHost(host).validatorNodeCountOf(refs[i]);
        }
        referredNodesOwnedTotal = owned;
    }

    /// @notice Full referrer read model: referred wallets, cumulative referral nodes, reward progress, and granted reward node rows.
    /// @param beneficiaryLimit Max referred wallets returned (0 = all).
    function resolveReferrerDetail(address referrer, uint256 beneficiaryOffset, uint256 beneficiaryLimit)
        external
        view
        returns (
            address[] memory referredBeneficiaries,
            uint256 referralNodeTotal,
            uint256 rewardNodesGranted,
            uint256 pendingRewardNodes,
            ReferrerRewardNodeDetail[] memory rewardNodes
        )
    {
        address[] storage refs = _referrerReferredBeneficiaries[referrer];
        referralNodeTotal = referrerReferralNodeTotal[referrer];
        rewardNodesGranted = referrerRewardMilestonePaid[referrer];
        uint256 milestone = referralNodeTotal / REFERRER_NODES_PER_REWARD;
        pendingRewardNodes = milestone > rewardNodesGranted ? milestone - rewardNodesGranted : 0;

        if (beneficiaryOffset >= refs.length) {
            referredBeneficiaries = new address[](0);
        } else {
            uint256 end = beneficiaryLimit == 0 ? refs.length : beneficiaryOffset + beneficiaryLimit;
            if (end > refs.length) {
                end = refs.length;
            }
            referredBeneficiaries = new address[](end - beneficiaryOffset);
            for (uint256 i = beneficiaryOffset; i < end; i++) {
                referredBeneficiaries[i - beneficiaryOffset] = refs[i];
            }
        }

        address host = redeemHost;
        if (host == address(0)) {
            rewardNodes = new ReferrerRewardNodeDetail[](0);
            return (referredBeneficiaries, referralNodeTotal, rewardNodesGranted, pendingRewardNodes, rewardNodes);
        }

        (uint256[] memory ids, address[] memory wallets, string[] memory ips) =
            IReferrerRewardHost(host).getReferrerRewardNodes(referrer);
        uint256 n = ids.length;
        rewardNodes = new ReferrerRewardNodeDetail[](n);
        for (uint256 i = 0; i < n; i++) {
            rewardNodes[i] = ReferrerRewardNodeDetail({guardianNodeId: ids[i], nodeWallet: wallets[i], depinNodeIp: ips[i]});
        }
    }
}
