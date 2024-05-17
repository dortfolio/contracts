// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

contract PortfolioManager {
    struct Asset {
        address token;
        uint8 targetWeight;
        uint256 amountHeld;
    }

    struct Portfolio {
        address token;
        // poolId
        Asset[] assets;
        uint8 rebalanceFrequency; // n days
        uint256 rebalancedAt; // timestamp
    }

    struct ManagedPortfolio {
        address token;
        address manager;
        // poolId
        Asset[] currentAssets;
        Asset[] targetAssets;
        uint8 managementFee;
        uint8 rebalanceFrequency; // n days
        uint256 rebalancedAt; // timestamp
    }

    mapping(bytes32 portfolioId => Portfolio) internal portfolios;
    mapping(bytes32 portfolioId => ManagedPortfolio) internal managedPortfolios;

    function createPortfolio(Asset[] memory assets) public {}
    function modifyPortfolio(bytes32 portfolioId, Asset[] memory assets) public {}
    function rebalancePortfolio(bytes32 portfolioId) public {}
}
