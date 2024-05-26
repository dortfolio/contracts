// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Counter} from "../src/Counter.sol";

contract CounterTest is Test {
    Counter public counter;

    function setUp() public {
        counter = new Counter();
    }

    function test_Increment() public {
        assertEq(counter.id(), 0);

        uint256 id1 = counter.getId();
        assertEq(counter.id(), 1);
        assertEq(counter.id(), id1);

        uint256 id2 = counter.getId();
        assertEq(counter.id(), 2);
        assertEq(counter.id(), id2);
    }
}
