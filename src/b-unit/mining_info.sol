// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

struct epoch_mining{
    uint256 epoch;
    uint256 totalMiners;
    uint256 minerRate;
    uint256 totalUsrs;
}

contract epoch_mining_info {
    mapping(address => bool) public adminList;
    modifier requireAddressInAdminlist {
        require(adminList[msg.sender] == true);             //          check sender in whiteList
        _;
    }
    
    mapping(uint256 => epoch_mining) public epochInfo;
    epoch_mining public currentInfo;

    function changeAddressInAdminlist (address addr, bool status) requireAddressInAdminlist public {
        adminList[addr] = status;
    }

    constructor() {
        adminList[msg.sender] = true;
    }

    function updateInfo (uint256 totalMiners, uint256 minerRate, uint256 totalUsrs) requireAddressInAdminlist public {
       currentInfo = epoch_mining(block.number, totalMiners, minerRate, totalUsrs);
       epochInfo[block.number] = currentInfo;
    }
}