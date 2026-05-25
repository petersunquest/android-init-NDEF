// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "./GB.sol";

contract ConetGB_total {
    ConetGB1155 public conetgb = ConetGB1155(0x4641Eb3055A891E6D3109e441aA8b931738A48b5);

    function getDashboard () public view returns (
        uint256 todayTotalIssued, 
        uint256 yestodayTotalIssued,
        uint256 monthlyTotalIssued,
        uint256 lastMonthlyTotalIssued,
        uint256 yearlyTotalIssued,
        uint256 totalIssued
        ) {
        todayTotalIssued = conetgb.dayTotalIssued(0);
        yestodayTotalIssued = conetgb.dayTotalIssued(1);
        monthlyTotalIssued = conetgb.monthlyTotalIssued(0);
        lastMonthlyTotalIssued = conetgb.monthlyTotalIssued(1);
        yearlyTotalIssued = conetgb.yearlyTotalIssued(0);
        totalIssued = conetgb.totalSupply(0);
    }

    function getDaylyHistory () public view returns (
        uint256 yestoday_1,
        uint256 yestoday_2,
        uint256 yestoday_3,
        uint256 yestoday_4,
        uint256 yestoday_5,
        uint256 yestoday_6,
        uint256 yestoday_7,
        uint256 yestoday_8,
        uint256 yestoday_9,
        uint256 yestoday_10,
        uint256 yestoday_11,
        uint256 yestoday_12
    ) {
        yestoday_1 = conetgb.dayTotalIssued(2);
        yestoday_2 = conetgb.dayTotalIssued(3);
        yestoday_3 = conetgb.dayTotalIssued(4);
        yestoday_4 = conetgb.dayTotalIssued(5);
        yestoday_5 = conetgb.dayTotalIssued(6);
        yestoday_6 = conetgb.dayTotalIssued(7);
        yestoday_7 = conetgb.dayTotalIssued(8);
        yestoday_8 = conetgb.dayTotalIssued(9);
        yestoday_9 = conetgb.dayTotalIssued(10);
        yestoday_10 = conetgb.dayTotalIssued(11);
        yestoday_11 = conetgb.dayTotalIssued(12);
        yestoday_12 = conetgb.dayTotalIssued(13);

    }

    
}