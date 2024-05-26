// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

contract Counter {
    uint256 public id;

    function getId() public returns (uint256) {
        return ++id;
    }
}
