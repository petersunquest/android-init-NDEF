// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library LibActionStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("beamio.action.storage.v1");

    // ===== Blockchain-ready transaction schema =====
    enum AssetType { ERC20, ERC1155 }
    enum RouteSource {
        MainUSDC,
        UserCardPoint,
        UserCardCoupon,
        UserCardCashVoucher,
        TipAppend
    }
    enum GasChainType { ETH, SOLANA }

    struct RouteItem {
        address asset;
        uint256 amountE6;
        AssetType assetType;
        RouteSource source;
        uint256 tokenId;
        uint8 itemCurrencyType;
        uint256 offsetInRequestCurrencyE6;
    }

    struct FeeInfo {
        uint16 gasChainType;
        uint256 gasWei;
        uint256 gasUSDC6;
        uint256 serviceUSDC6;
        uint256 bServiceUSDC6;
        uint256 bServiceUnits6;
        address feePayer;
    }

    struct TransactionMeta {
        uint256 requestAmountFiat6;
        uint256 requestAmountUSDC6;
        uint8 currencyFiat;
        uint256 discountAmountFiat6;
        uint16 discountRateBps;
        uint256 taxAmountFiat6;
        uint16 taxRateBps;
        string afterNotePayer;
        string afterNotePayee;
    }

    struct TransactionRecord {
        bytes32 id;
        bytes32 originalPaymentHash;
        uint256 chainId;
        bytes32 txCategory;
        string displayJson;
        uint64 timestamp;
        address payer;
        address payee;
        uint256 finalRequestAmountFiat6;
        uint256 finalRequestAmountUSDC6;
        bool isAAAccount;
        FeeInfo fees;
        TransactionMeta meta;
        bool exists;
        // Appended for upgrade compatibility - existing records read as address(0)
        address topAdmin;      // top-level admin (owner or direct admin) for this tx
        address subordinate;  // terminal/subordinate that processed this tx
    }

    struct BalanceCheckpoint {
        uint64 hourIndex;
        uint256 balanceE6;
    }

    struct Layout {
        uint256 txCount; // actionId = 0..txCount-1

        // actionId => blockchain-ready transaction data
        mapping(uint256 => TransactionRecord) txRecordByActionId;
        // tx id(bytes32) => actionId + 1
        mapping(bytes32 => uint256) actionIdPlusOneByTxId;
        // dynamic route data kept separate for simpler storage copying
        mapping(uint256 => RouteItem[]) routeByActionId;

        // account(payer/payee) => [actionId...]
        mapping(address => uint256[]) accountActionIds;

        // asset(route item address) => [actionId...]
        mapping(address => uint256[]) assetActionIds;
        // de-dup index per (asset, actionId)
        mapping(address => mapping(uint256 => bool)) assetActionIndexed;

        // asset + tokenId => [actionId...]
        mapping(address => mapping(uint256 => uint256[])) assetTokenActionIds;
        // de-dup index per (asset, tokenId, actionId)
        mapping(address => mapping(uint256 => mapping(uint256 => bool))) assetTokenActionIndexed;

        // asset + tokenId + account => indexed balance (E6)
        mapping(address => mapping(uint256 => mapping(address => uint256))) indexedBalanceByAssetTokenAccount;
        // asset + tokenId => holder address count (balance > 0)
        mapping(address => mapping(uint256 => uint256)) indexedHolderCountByAssetToken;
        // asset + tokenId => seen accounts (for historical top-N scan)
        mapping(address => mapping(uint256 => address[])) assetTokenSeenAccounts;
        // dedup seen account
        mapping(address => mapping(uint256 => mapping(address => bool))) assetTokenSeenAccountIndexed;
        // asset + tokenId + account => hourly balance checkpoints
        mapping(address => mapping(uint256 => mapping(address => BalanceCheckpoint[]))) assetTokenBalanceCheckpoints;

        // feePayer => [actionId...]
        mapping(address => uint256[]) feePayerActionIds;
        // seen feePayer accounts for bService top-N scan
        address[] bServiceSeenAccounts;
        mapping(address => bool) bServiceSeenAccountIndexed;

        // topAdmin => [actionId...] for reporting by top admin
        mapping(address => uint256[]) topAdminActionIds;
        // subordinate => [actionId...] for reporting by terminal/subordinate
        mapping(address => uint256[]) subordinateActionIds;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_POSITION;
        assembly { l.slot := slot }
    }
}
