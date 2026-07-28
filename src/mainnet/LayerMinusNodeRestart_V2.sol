// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract LayerMinusNodeRestart_V2 {
    mapping(address => bool) public adminList;

    modifier onlyAdmin() {
        require(adminList[msg.sender] == true, "NOT_ADMIN");
        _;
    }

    uint256 public restartBlockNumber = 0;

    constructor() {
        adminList[msg.sender] = true;
    }

    function changeAddressInAdminlist(address addr, bool status) public onlyAdmin {
        adminList[addr] = status;
    }

    function setRestart() public onlyAdmin {
        restartBlockNumber = block.number;
    }
}