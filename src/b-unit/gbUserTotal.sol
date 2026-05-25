// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "./GB.sol";

contract ConetGB_userTotal {
    ConetGB1155 public conetgb = ConetGB1155(0x4641Eb3055A891E6D3109e441aA8b931738A48b5);

    function getDashboard (address to) public view returns (
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
}