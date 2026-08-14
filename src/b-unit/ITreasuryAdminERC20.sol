// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITreasuryAdminERC20
 * @notice Standard mint/burn surface for any ERC20 that connects to TreasuryBridgeV3.
 * @dev Treasury is granted the token's admin / TREASURY_ROLE / BRIDGE_ROLE and calls these
 *      from offline-signed relays (`executeTreasuryAssetOpWithSignature`).
 *
 * Token families:
 *   - TreasuryCanonicalERC20V3: role-gated `mint` / `burnFrom` (no allowance).
 *   - GBToken: register as `GbPaid` → treasury calls `mintPaid` / `burnPaidFrom`.
 *   - BUint: register as `BUnitPaid` → treasury calls `mintPaid` / `consumePaidFuel`.
 *   - Future developer tokens: implement this interface + grant treasury TREASURY_ROLE.
 */
interface ITreasuryAdminERC20 {
    function mint(address to, uint256 amount) external;

    /// @dev Admin/treasury burn — must NOT require ERC20 allowance when caller is treasury.
    function burnFrom(address account, uint256 amount) external;
}

interface ITreasuryGbPaidAdmin {
    function mintPaid(address to, uint256 amount) external;

    function burnPaidFrom(address account, uint256 amount) external;
}

interface ITreasuryBUnitPaidAdmin {
    function mintPaid(address to, uint256 amount) external;

    function consumePaidFuel(address user, uint256 amount) external returns (uint256 paidBurned);
}

interface ITreasuryEip3009 {
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}
