// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IBeamioUserCardForFactory.sol";
import "./Errors.sol";

/// @dev 从 Factory 拆出的 calldata 变换逻辑（external library，不内联进 Factory bytecode）
library BeamioUserCardFactoryExecuteLib {
    bytes4 private constant MINT_POINTS_BY_ADMIN_SELECTOR = bytes4(keccak256("mintPointsByAdmin(address,uint256)"));
    bytes4 private constant ADMIN_MANAGER_SELECTOR = bytes4(keccak256("adminManager(address,bool,uint256,string)"));
    bytes4 private constant ADMIN_MANAGER_WITH_LIMIT_SELECTOR = bytes4(keccak256("adminManager(address,bool,uint256,string,uint256)"));
    bytes4 private constant ADMIN_MANAGER_BY_ADMIN_SELECTOR = bytes4(keccak256("adminManagerByAdmin(address,bool,uint256,string,address)"));
    bytes4 private constant ADMIN_MANAGER_BY_ADMIN_WITH_LIMIT_SELECTOR =
        bytes4(keccak256("adminManagerByAdmin(address,bool,uint256,string,address,uint256)"));
    bytes4 private constant SET_ADMIN_AIRDROP_LIMIT_SELECTOR = bytes4(keccak256("setAdminAirdropLimit(address,uint256)"));
    bytes4 private constant SET_ADMIN_AIRDROP_LIMIT_BY_ADMIN_SELECTOR =
        bytes4(keccak256("setAdminAirdropLimitByAdmin(address,uint256,address)"));
    bytes4 private constant CLEAR_ADMIN_MINT_COUNTER_SELECTOR =
        bytes4(keccak256("clearAdminMintCounterForSubordinate(address,address)"));
    bytes4 private constant RESET_ADMIN_LIMIT_SELECTOR = bytes4(keccak256("resetAdminLimit(address)"));
    bytes4 private constant CLEAR_ADMIN_MINT_COUNTER_ON_CARD_SELECTOR =
        bytes4(keccak256("clearAdminMintCounterForSubordinate(address,address)"));
    bytes4 private constant RESET_ADMIN_LIMIT_BY_ADMIN_SELECTOR = bytes4(keccak256("resetAdminLimitByAdmin(address,address)"));
    bytes4 private constant MINT_POINTS_BY_ADMIN_WITH_OPERATOR_SELECTOR =
        bytes4(keccak256("mintPointsByAdminWithOperator(address,uint256,address)"));

    bytes4 private constant CREATE_REDEEM_SELECTOR =
        bytes4(keccak256("createRedeem(bytes32,uint256,uint256,uint64,uint64,uint256[],uint256[])"));
    bytes4 private constant CREATE_REDEEM_WITH_RECOMMENDER_SELECTOR =
        bytes4(keccak256("createRedeem(bytes32,uint256,uint256,uint64,uint64,uint256[],uint256[],address)"));
    bytes4 private constant CREATE_REDEEM_WITH_CREATOR_SELECTOR =
        bytes4(keccak256("createRedeemWithCreator(bytes32,uint256,uint256,uint64,uint64,uint256[],uint256[],address)"));
    bytes4 private constant CREATE_REDEEM_WITH_CREATOR_AND_RECOMMENDER_SELECTOR =
        bytes4(
            keccak256(
                "createRedeemWithCreatorAndRecommender(bytes32,uint256,uint256,uint64,uint64,uint256[],uint256[],address,address)"
            )
        );
    bytes4 private constant CREATE_REDEEM_BATCH_SELECTOR =
        bytes4(keccak256("createRedeemBatch(bytes32[],uint256,uint256,uint64,uint64,uint256[],uint256[])"));
    bytes4 private constant CREATE_REDEEM_BATCH_WITH_RECOMMENDER_SELECTOR =
        bytes4(keccak256("createRedeemBatch(bytes32[],uint256,uint256,uint64,uint64,uint256[],uint256[],address)"));
    bytes4 private constant CREATE_REDEEM_BATCH_WITH_CREATOR_SELECTOR =
        bytes4(keccak256("createRedeemBatchWithCreator(bytes32[],uint256,uint256,uint64,uint64,uint256[],uint256[],address)"));
    bytes4 private constant CREATE_REDEEM_BATCH_WITH_CREATOR_AND_RECOMMENDER_SELECTOR =
        bytes4(
            keccak256(
                "createRedeemBatchWithCreatorAndRecommender(bytes32[],uint256,uint256,uint64,uint64,uint256[],uint256[],address,address)"
            )
        );
    bytes4 private constant CREATE_REDEEM_POOL_SELECTOR =
        bytes4(keccak256("createRedeemPool(bytes32,uint64,uint64,uint256[][],uint256[][],uint32[])"));
    bytes4 private constant CREATE_REDEEM_POOL_WITH_RECOMMENDER_SELECTOR =
        bytes4(keccak256("createRedeemPool(bytes32,uint64,uint64,uint256[][],uint256[][],uint32[],address)"));
    bytes4 private constant CREATE_REDEEM_POOL_WITH_CREATOR_SELECTOR =
        bytes4(keccak256("createRedeemPoolWithCreator(bytes32,uint64,uint64,uint256[][],uint256[][],uint32[],address)"));
    bytes4 private constant CREATE_REDEEM_POOL_WITH_CREATOR_AND_RECOMMENDER_SELECTOR =
        bytes4(
            keccak256(
                "createRedeemPoolWithCreatorAndRecommender(bytes32,uint64,uint64,uint256[][],uint256[][],uint32[],address,address)"
            )
        );

    function transformOwnerExecuteCalldata(bytes memory data, address signer) external pure returns (bytes memory callData) {
        callData = data;
        if (data.length < 4) return callData;

        bytes4 sel;
        assembly {
            sel := shr(224, mload(add(data, 32)))
        }

        if (sel == CREATE_REDEEM_SELECTOR) {
            bytes memory tail = new bytes(data.length - 4);
            for (uint256 i = 0; i < tail.length; i++) tail[i] = data[i + 4];
            (bytes32 hash, uint256 points6, uint256 attr, uint64 validAfter, uint64 validBefore, uint256[] memory tokenIds, uint256[] memory amounts) =
                abi.decode(tail, (bytes32, uint256, uint256, uint64, uint64, uint256[], uint256[]));
            return abi.encodeWithSelector(
                CREATE_REDEEM_WITH_CREATOR_SELECTOR,
                hash,
                points6,
                attr,
                validAfter,
                validBefore,
                tokenIds,
                amounts,
                signer
            );
        }
        if (sel == CREATE_REDEEM_WITH_RECOMMENDER_SELECTOR) {
            bytes memory tail = new bytes(data.length - 4);
            for (uint256 i = 0; i < tail.length; i++) tail[i] = data[i + 4];
            (
                bytes32 hash,
                uint256 points6,
                uint256 attr,
                uint64 validAfter,
                uint64 validBefore,
                uint256[] memory tokenIds,
                uint256[] memory amounts,
                address recommender
            ) = abi.decode(tail, (bytes32, uint256, uint256, uint64, uint64, uint256[], uint256[], address));
            return abi.encodeWithSelector(
                CREATE_REDEEM_WITH_CREATOR_AND_RECOMMENDER_SELECTOR,
                hash,
                points6,
                attr,
                validAfter,
                validBefore,
                tokenIds,
                amounts,
                signer,
                recommender
            );
        }
        if (sel == CREATE_REDEEM_BATCH_SELECTOR) {
            bytes memory tail = new bytes(data.length - 4);
            for (uint256 i = 0; i < tail.length; i++) tail[i] = data[i + 4];
            (
                bytes32[] memory hashes,
                uint256 points6,
                uint256 attr,
                uint64 validAfter,
                uint64 validBefore,
                uint256[] memory tokenIds,
                uint256[] memory amounts
            ) = abi.decode(tail, (bytes32[], uint256, uint256, uint64, uint64, uint256[], uint256[]));
            return abi.encodeWithSelector(
                CREATE_REDEEM_BATCH_WITH_CREATOR_SELECTOR,
                hashes,
                points6,
                attr,
                validAfter,
                validBefore,
                tokenIds,
                amounts,
                signer
            );
        }
        if (sel == CREATE_REDEEM_BATCH_WITH_RECOMMENDER_SELECTOR) {
            bytes memory tail = new bytes(data.length - 4);
            for (uint256 i = 0; i < tail.length; i++) tail[i] = data[i + 4];
            (
                bytes32[] memory hashes,
                uint256 points6,
                uint256 attr,
                uint64 validAfter,
                uint64 validBefore,
                uint256[] memory tokenIds,
                uint256[] memory amounts,
                address recommender
            ) = abi.decode(tail, (bytes32[], uint256, uint256, uint64, uint64, uint256[], uint256[], address));
            return abi.encodeWithSelector(
                CREATE_REDEEM_BATCH_WITH_CREATOR_AND_RECOMMENDER_SELECTOR,
                hashes,
                points6,
                attr,
                validAfter,
                validBefore,
                tokenIds,
                amounts,
                signer,
                recommender
            );
        }
        if (sel == CREATE_REDEEM_POOL_SELECTOR) {
            bytes memory tail = new bytes(data.length - 4);
            for (uint256 i = 0; i < tail.length; i++) tail[i] = data[i + 4];
            (
                bytes32 poolHash,
                uint64 validAfter,
                uint64 validBefore,
                uint256[][] memory tokenIdsList,
                uint256[][] memory amountsList,
                uint32[] memory counts
            ) = abi.decode(tail, (bytes32, uint64, uint64, uint256[][], uint256[][], uint32[]));
            return abi.encodeWithSelector(
                CREATE_REDEEM_POOL_WITH_CREATOR_SELECTOR,
                poolHash,
                validAfter,
                validBefore,
                tokenIdsList,
                amountsList,
                counts,
                signer
            );
        }
        if (sel == CREATE_REDEEM_POOL_WITH_RECOMMENDER_SELECTOR) {
            bytes memory tail = new bytes(data.length - 4);
            for (uint256 i = 0; i < tail.length; i++) tail[i] = data[i + 4];
            (
                bytes32 poolHash,
                uint64 validAfter,
                uint64 validBefore,
                uint256[][] memory tokenIdsList,
                uint256[][] memory amountsList,
                uint32[] memory counts,
                address recommender
            ) = abi.decode(tail, (bytes32, uint64, uint64, uint256[][], uint256[][], uint32[], address));
            return abi.encodeWithSelector(
                CREATE_REDEEM_POOL_WITH_CREATOR_AND_RECOMMENDER_SELECTOR,
                poolHash,
                validAfter,
                validBefore,
                tokenIdsList,
                amountsList,
                counts,
                signer,
                recommender
            );
        }
    }

    function transformAdminExecuteCalldata(
        bytes4 selector,
        bytes calldata data,
        address cardAddr,
        address signer
    ) external view returns (bytes memory callData) {
        if (selector == ADMIN_MANAGER_SELECTOR) {
            (address to, bool admin, uint256 newThreshold, string memory metadata) =
                abi.decode(data[4:], (address, bool, uint256, string));
            return abi.encodeWithSelector(ADMIN_MANAGER_BY_ADMIN_SELECTOR, to, admin, newThreshold, metadata, signer);
        }
        if (selector == ADMIN_MANAGER_WITH_LIMIT_SELECTOR) {
            (address to, bool admin, uint256 newThreshold, string memory metadata, uint256 mintLimit) =
                abi.decode(data[4:], (address, bool, uint256, string, uint256));
            return abi.encodeWithSelector(
                ADMIN_MANAGER_BY_ADMIN_WITH_LIMIT_SELECTOR,
                to,
                admin,
                newThreshold,
                metadata,
                signer,
                mintLimit
            );
        }
        if (selector == SET_ADMIN_AIRDROP_LIMIT_SELECTOR) {
            (address subordinate, uint256 mintLimit) = abi.decode(data[4:], (address, uint256));
            IBeamioUserCardForFactory card = IBeamioUserCardForFactory(cardAddr);
            if (card.adminParent(subordinate) != signer) revert UC_NotAdmin();
            if (card.adminParent(signer) != address(0)) revert UC_AdminDepthExceeded(signer);
            return abi.encodeWithSelector(SET_ADMIN_AIRDROP_LIMIT_BY_ADMIN_SELECTOR, subordinate, mintLimit, signer);
        }
        if (selector == CLEAR_ADMIN_MINT_COUNTER_SELECTOR) {
            (address subordinate, address authorizer) = abi.decode(data[4:], (address, address));
            IBeamioUserCardForFactory card = IBeamioUserCardForFactory(cardAddr);
            if (authorizer != signer) revert UC_NotAdmin();
            if (card.adminParent(subordinate) != authorizer) revert UC_NotAdmin();
            if (card.adminParent(signer) != address(0)) revert UC_AdminDepthExceeded(signer);
            return abi.encodeWithSelector(CLEAR_ADMIN_MINT_COUNTER_ON_CARD_SELECTOR, subordinate, authorizer);
        }
        if (selector == RESET_ADMIN_LIMIT_SELECTOR) {
            (address adminAddr) = abi.decode(data[4:], (address));
            return abi.encodeWithSelector(RESET_ADMIN_LIMIT_BY_ADMIN_SELECTOR, adminAddr, signer);
        }
        if (selector == MINT_POINTS_BY_ADMIN_SELECTOR) {
            (address user, uint256 points6) = abi.decode(data[4:], (address, uint256));
            return abi.encodeWithSelector(MINT_POINTS_BY_ADMIN_WITH_OPERATOR_SELECTOR, user, points6, signer);
        }
        return bytes(data);
    }
}
