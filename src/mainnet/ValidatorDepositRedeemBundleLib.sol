// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {NodeBundle} from "./ValidatorDepositRedeemTypes.sol";

interface IGuardianNodesBundleReader {
    function id2ip(uint256 id) external view returns (string memory);
    function idOwner(uint256 id) external view returns (address);
    function ipaddress2owner(string memory ipaddress) external view returns (address);
}

interface IERC1155BundleBalance {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface IERC20BundleBalance {
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Read-only bundle assembly callbacks on {ValidatorDepositRedeem}.
interface IRedeemBundleStorageReader {
    function nodeValidatorBinding(uint256 guardianId)
        external
        view
        returns (bytes memory pubkey, bool active);
    function validatorNodeCountOf(address beneficiary) external view returns (uint256);
    function gbMiningNodeCountOf(address beneficiary) external view returns (uint256);
    function walletClaimCountOf(address beneficiary) external view returns (uint256);
}

/**
 * @title ValidatorDepositRedeemBundleLib
 * @notice External library: assemble {NodeBundle} for RPC reads. Linked from {ValidatorDepositRedeem}.
 */
library ValidatorDepositRedeemBundleLib {
    uint256 internal constant GB_NET_TOTAL_ID = 0;

    function buildNodeBundle(
        address host,
        address guardianNodesAddr,
        address gbTokenAddr,
        address usdcTokenAddr,
        address beneficiary,
        uint256[] memory ids
    ) external view returns (NodeBundle memory b) {
        b.beneficiary = beneficiary;
        if (beneficiary == address(0)) {
            b.guardianNodeIds = new uint256[](0);
            b.depinNodeIps = new string[](0);
            b.nodeWallets = new address[](0);
            b.validatorPubkeys = new bytes[](0);
            b.validatorActive = new bool[](0);
            return b;
        }

        IRedeemBundleStorageReader reader = IRedeemBundleStorageReader(host);
        uint256 n = ids.length;
        b.guardianNodeIds = ids;
        b.depinNodeIps = new string[](n);
        b.nodeWallets = new address[](n);
        b.validatorPubkeys = new bytes[](n);
        b.validatorActive = new bool[](n);

        IGuardianNodesBundleReader guardian = IGuardianNodesBundleReader(guardianNodesAddr);
        if (guardianNodesAddr != address(0)) {
            for (uint256 i = 0; i < n; i++) {
                uint256 nodeId = ids[i];
                string memory ip = guardian.id2ip(nodeId);
                b.depinNodeIps[i] = ip;
                address w = guardian.idOwner(nodeId);
                if (w == address(0) && bytes(ip).length != 0) {
                    w = guardian.ipaddress2owner(ip);
                }
                b.nodeWallets[i] = w;
                (bytes memory pk, bool active) = reader.nodeValidatorBinding(nodeId);
                b.validatorPubkeys[i] = pk;
                b.validatorActive[i] = active;
            }
        }

        b.validatorNodeCount = reader.validatorNodeCountOf(beneficiary);
        b.gbMiningNodeCount = reader.gbMiningNodeCountOf(beneficiary);
        b.claimCount = reader.walletClaimCountOf(beneficiary);
        b.nativeBalance = beneficiary.balance;
        b.gbBalance = _safeGbBalance(gbTokenAddr, beneficiary);
        b.usdcBalance = _safeUsdcBalance(usdcTokenAddr, beneficiary);
    }

    function _safeGbBalance(address gbToken, address wallet) private view returns (uint256) {
        if (gbToken == address(0)) return 0;
        try IERC1155BundleBalance(gbToken).balanceOf(wallet, GB_NET_TOTAL_ID) returns (uint256 bal) {
            return bal;
        } catch {
            return 0;
        }
    }

    function _safeUsdcBalance(address usdcToken, address wallet) private view returns (uint256) {
        if (usdcToken == address(0)) return 0;
        try IERC20BundleBalance(usdcToken).balanceOf(wallet) returns (uint256 bal) {
            return bal;
        } catch {
            return 0;
        }
    }
}
