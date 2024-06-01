// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract PortfolioManager {
    struct Asset {
        address token;
        uint8 targetWeight;
        uint256 amountHeld;
    }

    struct Portfolio {
        address inputToken;
        address outputToken;
        PoolId poolId;
        Asset[] assets;
        uint8 rebalanceFrequency; // n days
        uint256 rebalancedAt; // timestamp
    }

    struct ManagedPortfolio {
        address inputToken;
        address outputToken;
        address manager;
        PoolId poolId;
        Asset[] currentAssets;
        Asset[] targetAssets;
        uint8 managementFeeBasisPoints;
        uint8 rebalanceFrequency; // n days
        uint256 rebalancedAt; // timestamp
    }

    uint256 internal id;
    mapping(bytes32 hash => uint256 id) internal hashToId;
    mapping(uint256 id => bool isManaged) internal idToIsManaged;

    mapping(uint256 id => Portfolio) internal portfolios;
    mapping(uint256 id => ManagedPortfolio) internal managedPortfolios;

    function createPortfolio(Asset[] memory assets) public {
        // deploy ERC20
        // create LP
        // assets must be ordered by weight; large to small
        // assets weights must total 100
    }
    function createManagedPortfolio(Asset[] memory assets) public {
        // deploy ERC20
        // create LP
        // assets weights must total 100
    }

    function updateManagedPortfolio(bytes32 portfolioId, Asset[] memory assets) public {}

    // function rebalancePortfolio(uint256 id) public {
    //     // do not rebalance if this was triggered by a recursive portfolio
    //     bool isManaged = idToIsManaged[id];

    //     if (isManaged) {
    //         ManagedPortfolio storage p = managedPortfolios[id];
    //     } else {
    //         Portfolio storage p = portfolios[id];
    //     }
    // }

    function _getId() internal returns (uint256) {
        return ++id;
    }

    function _getHash(Asset[] memory assets, uint256 rebalanceFrequency) internal returns (bytes32) {}
}
