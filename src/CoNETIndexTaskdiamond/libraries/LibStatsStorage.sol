// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library LibStatsStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("beamio.stats.storage.v1");

    struct HourlyStats {
        uint256 nftMinted;
        uint256 tokenMinted;
        uint256 tokenBurned;
        uint256 transferCount;
        bool hasData;
    }

    struct Layout {
        mapping(uint256 => HourlyStats) hourlyData;
        mapping(address => mapping(uint256 => HourlyStats)) cardHourlyData;
        mapping(address => mapping(uint256 => HourlyStats)) userHourlyData;
        /// @dev admin 维度：token #0 (points) 的 mint/burn 统计，可按时/日/周/月聚合
        mapping(address => mapping(uint256 => HourlyStats)) adminHourlyData;
        /// @dev admin  cumulative mint token 0，按 (card, admin) 维度；parent admin 可清零 subordinate 的计数
        mapping(address => mapping(address => uint256)) adminMintCounterByCard;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_POSITION;
        assembly { l.slot := slot }
    }
}
