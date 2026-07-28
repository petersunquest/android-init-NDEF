// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface IBUnitAirdropSettlement {
    function reserveClaimable(uint256 amount) external;
    function payoutClaimable(address recipient, uint256 amount) external;
}

interface IReferralMerchantShareModuleSettlement {
    function accrueMerchantShares(address l0, address merchant, uint256 totalRebate, bytes32 sourceHash)
        external
        returns (uint256 distributed);
}

/**
 * @dev Paid B-Unit → CONET-USDC settlement extracted to stay under the 24KB limit.
 * Flow: mint USDC → pay L0/L1 rebate slice (admin-set rebateBps, e.g. 30%) to L0/L1 EOAs →
 * pay remainder to L0's parentAdmin EOA. No claim queue.
 */
library ReferralRegistrySettlementLib {
    uint8 internal constant ROLE_L0 = 1;
    uint8 internal constant ROLE_L1 = 2;
    uint8 internal constant ROLE_MERCHANT = 3;
    uint256 internal constant BPS = 10_000;

    error Unauthorized();
    error InvalidAddress();
    error InvalidAmount();
    error DistributionMismatch();

    struct MemberView {
        uint8 role;
        address parentAdmin;
        address parentL0;
        uint256 rebateBps;
        uint256 ratioBps;
        bool active;
    }

    event ClaimableAccrued(bytes32 indexed settlementId, address indexed account, uint256 amount);
    event ConetUsdcDirectPaid(bytes32 indexed settlementId, address indexed account, uint256 amount);
    event ConetUsdcClaimed(address indexed account, uint256 amount, uint256 nonce);

    function directPayRebate(
        mapping(address => uint256) storage claimedConetUsdc,
        address bunitAirdrop,
        address account,
        uint256 amount,
        bytes32 sourceHash
    ) internal {
        if (account == address(0) || amount == 0) return;
        IBUnitAirdropSettlement(bunitAirdrop).reserveClaimable(amount);
        IBUnitAirdropSettlement(bunitAirdrop).payoutClaimable(account, amount);
        claimedConetUsdc[account] += amount;
        emit ClaimableAccrued(sourceHash, account, amount);
        emit ConetUsdcDirectPaid(sourceHash, account, amount);
    }

    function creditClaimableFromShare(
        mapping(address => uint256) storage claimedConetUsdc,
        address merchantShareModule,
        address bunitAirdrop,
        address account,
        uint256 amount,
        bytes32 sourceHash
    ) external {
        if (msg.sender != merchantShareModule || merchantShareModule == address(0)) revert Unauthorized();
        if (account == address(0) || amount == 0) revert InvalidAmount();
        directPayRebate(claimedConetUsdc, bunitAirdrop, account, amount, sourceHash);
    }

    function flushPendingClaimable(
        mapping(address => uint256) storage claimableConetUsdc,
        mapping(address => uint256) storage claimedConetUsdc,
        mapping(address => uint256) storage claimNonces,
        address bunitAirdrop,
        address account
    ) external {
        if (account == address(0)) revert InvalidAddress();
        uint256 amount = claimableConetUsdc[account];
        if (amount == 0) return;
        claimableConetUsdc[account] = 0;
        claimedConetUsdc[account] += amount;
        IBUnitAirdropSettlement(bunitAirdrop).payoutClaimable(account, amount);
        emit ConetUsdcDirectPaid(bytes32(0), account, amount);
        emit ConetUsdcClaimed(account, amount, claimNonces[account]);
    }

    function onPaidBUnitConsumed(
        mapping(address => MemberView) storage members,
        mapping(address => uint256) storage claimedConetUsdc,
        address bunitAirdrop,
        address merchantShareModule,
        address payer,
        uint256 paidBurned,
        uint256 usdcAmount,
        bytes32 sourceHash
    ) external {
        if (paidBurned / 100 != usdcAmount) revert DistributionMismatch();
        MemberView memory pm = members[payer];
        address l0;
        address l1;
        uint256 l1Reward;
        if (pm.role == ROLE_MERCHANT) l0 = pm.parentL0;
        else if (pm.role == ROLE_L1) {
            l0 = pm.parentL0;
            l1 = payer;
        }
        if (l0 == address(0)) return;

        uint256 totalRebate = (usdcAmount * members[l0].rebateBps) / BPS;
        if (pm.role == ROLE_MERCHANT && merchantShareModule != address(0) && totalRebate > 0) {
            l1Reward = IReferralMerchantShareModuleSettlement(merchantShareModule).accrueMerchantShares(
                l0, payer, totalRebate, sourceHash
            );
            if (l1Reward > totalRebate) revert DistributionMismatch();
        }
        if (l1Reward == 0) {
            if (pm.role == ROLE_MERCHANT) {
                l1 = pm.parentAdmin;
                if (
                    l1 != address(0) &&
                    (members[l1].role != ROLE_L1 || !members[l1].active || members[l1].parentL0 != l0)
                ) l1 = address(0);
            }
            if (l1 != address(0)) {
                l1Reward = (totalRebate * members[l1].ratioBps) / BPS;
                if (l1Reward > 0) {
                    directPayRebate(claimedConetUsdc, bunitAirdrop, l1, l1Reward, sourceHash);
                }
            }
        }

        uint256 l0Reward = totalRebate - l1Reward;
        uint256 adminReward = usdcAmount - totalRebate;
        if (l0Reward + l1Reward + adminReward != usdcAmount) revert DistributionMismatch();
        if (l0Reward > 0) {
            directPayRebate(claimedConetUsdc, bunitAirdrop, l0, l0Reward, sourceHash);
        }
        // Remainder of minted USDC (after L0/L1 rebate) → Admin EOA that owns this L0 tree.
        if (adminReward > 0) {
            address admin = members[l0].parentAdmin;
            if (admin == address(0)) revert InvalidAddress();
            directPayRebate(claimedConetUsdc, bunitAirdrop, admin, adminReward, sourceHash);
        }
    }
}
