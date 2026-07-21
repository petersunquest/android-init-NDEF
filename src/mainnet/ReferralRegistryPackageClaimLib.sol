// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

interface IBusinessStartKetPackageClaim {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function mint(address to, uint256 id, uint256 amount, bytes calldata data) external;
}

interface IBUnitAirdropPackageClaim {
    function mintPaidForCreditCashPurchase(address recipient, uint256 amount, bytes32 redeemHash) external;
    function mintFreeForReferralSettlement(address recipient, uint256 amount, bytes32 redeemHash) external;
    function alreadyClaimedFree(address account) external view returns (bool);
}

struct ReferralAdminMerchantPackageCode {
    address issuerAdmin;
    address optionalL0;
    uint256 bunitAmount;
    bool isPaid;
    bool includeStartKet;
    uint8 paymentMethod;
    string description;
    uint64 validAfter;
    uint64 validBefore;
    bool active;
    bool claimed;
    bool cancelled;
}

/**
 * @dev Extracted from ReferralRegistryVaultV1 to stay under the 24KB limit.
 */
library ReferralRegistryPackageClaimLib {
    uint256 internal constant BUSINESS_START_KET_ID = 0;
    uint256 internal constant DESCRIPTION_MAX = 512;
    uint8 internal constant PAYMENT_METHOD_MAX = 4; // PackagePaymentMethod.Compensation

    error AlreadyRegistered();
    error CodeUnavailable();
    error InvalidAmount();
    error CodeExpired();
    error Unauthorized();
    error NotRegistered();

    event AdminMerchantPackageCodeIssued(
        bytes32 indexed redeemHash,
        address indexed admin,
        address indexed optionalL0,
        uint256 bunitAmount,
        bool isPaid,
        bool includeStartKet,
        uint8 paymentMethod
    );
    event AdminMerchantPackageCodeCancelled(bytes32 indexed redeemHash, address indexed admin);
    event AdminMerchantPackageCodeClaimed(
        bytes32 indexed redeemHash,
        address indexed claimer,
        address optionalL0,
        uint256 bunitAmount,
        bool isPaid,
        bool includeStartKet
    );

    function issue(
        mapping(bytes32 => ReferralAdminMerchantPackageCode) storage codes,
        bytes32[] storage hashes,
        address admin,
        bytes32 redeemHash,
        address optionalL0,
        uint256 bunitAmount,
        bool isPaid,
        bool includeStartKet,
        uint8 paymentMethod,
        string calldata description,
        bool optionalL0IsActiveL0
    ) external {
        if (redeemHash == bytes32(0) || bunitAmount == 0) revert InvalidAmount();
        if (paymentMethod > PAYMENT_METHOD_MAX) revert InvalidAmount();
        if (bytes(description).length > DESCRIPTION_MAX) revert InvalidAmount();
        if (optionalL0 != address(0) && !optionalL0IsActiveL0) revert NotRegistered();
        ReferralAdminMerchantPackageCode storage existing = codes[redeemHash];
        if (existing.active || existing.claimed || existing.cancelled) revert CodeUnavailable();

        codes[redeemHash] = ReferralAdminMerchantPackageCode({
            issuerAdmin: admin,
            optionalL0: optionalL0,
            bunitAmount: bunitAmount,
            isPaid: isPaid,
            includeStartKet: includeStartKet,
            paymentMethod: paymentMethod,
            description: description,
            validAfter: 0,
            validBefore: 0,
            active: true,
            claimed: false,
            cancelled: false
        });
        hashes.push(redeemHash);
        emit AdminMerchantPackageCodeIssued(
            redeemHash,
            admin,
            optionalL0,
            bunitAmount,
            isPaid,
            includeStartKet,
            paymentMethod
        );
    }

    function cancel(
        mapping(bytes32 => ReferralAdminMerchantPackageCode) storage codes,
        address admin,
        bytes32 redeemHash
    ) external {
        ReferralAdminMerchantPackageCode storage c = codes[redeemHash];
        if (!c.active || c.claimed || c.cancelled || c.issuerAdmin != admin) revert Unauthorized();
        c.active = false;
        c.cancelled = true;
        emit AdminMerchantPackageCodeCancelled(redeemHash, admin);
    }

    function claim(
        mapping(bytes32 => ReferralAdminMerchantPackageCode) storage codes,
        mapping(address => address) storage claimedMerchantL0,
        mapping(address => bytes32) storage claimedMerchantCode,
        address businessStartKet,
        address bunitAirdrop,
        address claimer,
        bool claimerAlreadyRegistered,
        bytes calldata secret
    ) external {
        if (claimer == address(0)) revert InvalidAmount();
        bytes32 redeemHash = keccak256(bytes(secret));
        ReferralAdminMerchantPackageCode storage c = codes[redeemHash];
        if (!c.active || c.claimed || c.cancelled) revert CodeUnavailable();
        if (c.validAfter != 0 && block.timestamp < c.validAfter) revert CodeExpired();
        if (c.validBefore != 0 && block.timestamp > c.validBefore) revert CodeExpired();
        if (c.includeStartKet) {
            if (claimerAlreadyRegistered || claimedMerchantL0[claimer] != address(0)) {
                revert AlreadyRegistered();
            }
            if (IBusinessStartKetPackageClaim(businessStartKet).balanceOf(claimer, BUSINESS_START_KET_ID) > 0) {
                revert AlreadyRegistered();
            }
        }
        if (!c.isPaid && IBUnitAirdropPackageClaim(bunitAirdrop).alreadyClaimedFree(claimer)) {
            revert InvalidAmount();
        }
        c.claimed = true;
        c.active = false;
        if (c.isPaid) {
            IBUnitAirdropPackageClaim(bunitAirdrop).mintPaidForCreditCashPurchase(claimer, c.bunitAmount, redeemHash);
        } else {
            IBUnitAirdropPackageClaim(bunitAirdrop).mintFreeForReferralSettlement(claimer, c.bunitAmount, redeemHash);
        }
        if (c.includeStartKet) {
            claimedMerchantCode[claimer] = redeemHash;
            if (c.optionalL0 != address(0)) {
                claimedMerchantL0[claimer] = c.optionalL0;
            }
            IBusinessStartKetPackageClaim(businessStartKet).mint(claimer, BUSINESS_START_KET_ID, 1, "");
        }
        emit AdminMerchantPackageCodeClaimed(
            redeemHash,
            claimer,
            c.optionalL0,
            c.bunitAmount,
            c.isPaid,
            c.includeStartKet
        );
    }
}
