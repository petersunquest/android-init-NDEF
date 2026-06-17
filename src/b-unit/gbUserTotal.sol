// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "./GB.sol";

contract ConetGB_userTotal {
    ConetGB1155 public immutable conetgb;

    constructor(address gb_) {
        require(gb_ != address(0), "zero gb");
        conetgb = ConetGB1155(gb_);
    }

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
