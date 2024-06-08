// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Deployers, MockERC20, SortTokens} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {
    Currency,
    CurrencyLibrary,
    ERC20,
    FixedPointMathLib,
    Hooks,
    IERC20,
    IHooks,
    IPoolManager,
    LPFeeLibrary,
    PoolClaimsTest,
    PoolId,
    PoolIdLibrary,
    PoolKey,
    PoolModifyLiquidityTest,
    PoolSwapTest,
    PortfolioManager,
    StateLibrary
} from "../src/PortfolioManager.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {SigUtils} from "./utils/SigUtils.sol";
import {IERC20Permit} from "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";

contract PortfolioManagerHarness is PortfolioManager {
    constructor(
        IPoolManager manager,
        PoolClaimsTest claimsRouter,
        PoolModifyLiquidityTest modifyLiquidityRouter,
        PoolSwapTest swapRouter
    ) PortfolioManager(manager, claimsRouter, modifyLiquidityRouter, swapRouter) {}

    function exposed_id() external returns (uint256) {
        return _id();
    }
}

contract PortfolioManagerTest is Test, Deployers {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PortfolioManagerHarness public pm;

    Currency public eth = CurrencyLibrary.NATIVE;
    Currency public usdc;
    Currency public wbtc;
    Currency public wsol;
    Currency public uni;

    address user;
    uint256 userPrivateKey;

    uint24 public constant FEE = 3000;
    IHooks public constant NO_HOOK = IHooks(address(0));

    function setUp() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        deployFreshManagerAndRouters();

        deployCodeTo(
            "PortfolioManagerHarness",
            abi.encode(manager, claimsRouter, modifyLiquidityRouter, swapRouter),
            address(flags)
        );
        pm = PortfolioManagerHarness(address(flags));

        // (address hookAddress, bytes32 salt) = HookMiner.find(
        //     address(this),
        //     flags,
        //     type(PortfolioManagerHarness).creationCode,
        //     abi.encode(manager, claimsRouter, modifyLiquidityRouter, swapRouter)
        // );
        // pm = new PortfolioManagerHarness{salt: salt}(manager, claimsRouter, modifyLiquidityRouter, swapRouter);
        // require(address(pm) == hookAddress, "PortfolioManager: hook address mismatch");

        (user, userPrivateKey) = makeAddrAndKey("user");
        vm.deal(user, 10 ether);
        deployTokensAndPools();
    }

    function deployTokensAndPools() public {
        usdc = deployMintAndApproveCurrency();
        wbtc = deployMintAndApproveCurrency();
        wsol = deployMintAndApproveCurrency();
        uni = deployMintAndApproveCurrency();

        ERC20(Currency.unwrap(usdc)).transfer(address(pm), 100 ether);
        ERC20(Currency.unwrap(wbtc)).transfer(address(pm), 100 ether);
        ERC20(Currency.unwrap(wsol)).transfer(address(pm), 100 ether);
        ERC20(Currency.unwrap(uni)).transfer(address(pm), 100 ether);

        ERC20(Currency.unwrap(usdc)).transfer(user, 100 ether);
        ERC20(Currency.unwrap(wbtc)).transfer(user, 100 ether);
        ERC20(Currency.unwrap(wsol)).transfer(user, 100 ether);
        ERC20(Currency.unwrap(uni)).transfer(user, 100 ether);

        Currency currency0;
        Currency currency1;
        PoolKey memory key;
        PoolId id;

        (key,) = initPoolAndAddLiquidityETH(eth, usdc, NO_HOOK, FEE, SQRT_PRICE_1_2, ZERO_BYTES, 10 ether);
        pm._addPair(key);

        (currency0, currency1) = SortTokens.sort(MockERC20(Currency.unwrap(usdc)), MockERC20(Currency.unwrap(wbtc)));
        (key,) = initPoolAndAddLiquidity(currency0, currency1, NO_HOOK, FEE, SQRT_PRICE_1_1, ZERO_BYTES);
        pm._addPair(key);
        (key,) = initPoolAndAddLiquidityETH(eth, wbtc, NO_HOOK, FEE, SQRT_PRICE_1_2, ZERO_BYTES, 10 ether);
        pm._addPair(key);

        (currency0, currency1) = SortTokens.sort(MockERC20(Currency.unwrap(usdc)), MockERC20(Currency.unwrap(wsol)));
        (key,) = initPoolAndAddLiquidity(currency0, currency1, NO_HOOK, FEE, SQRT_PRICE_2_1, ZERO_BYTES);
        pm._addPair(key);
        (key,) = initPoolAndAddLiquidityETH(eth, wsol, NO_HOOK, FEE, SQRT_PRICE_1_4, ZERO_BYTES, 10 ether);
        pm._addPair(key);

        (currency0, currency1) = SortTokens.sort(MockERC20(Currency.unwrap(usdc)), MockERC20(Currency.unwrap(uni)));
        (key,) = initPoolAndAddLiquidity(currency0, currency1, NO_HOOK, FEE, SQRT_PRICE_4_1, ZERO_BYTES);
        pm._addPair(key);
        (key, id) = initPoolAndAddLiquidityETH(eth, uni, NO_HOOK, FEE, SQRT_PRICE_1_1, ZERO_BYTES, 10 ether);
        pm._addPair(key);
    }

    function sortAssets(PortfolioManager.Asset[] memory assets) public pure returns (PortfolioManager.Asset[] memory) {
        for (uint256 i = assets.length - 1; i > 0; i--) {
            for (uint256 j = 0; j < i; j++) {
                if (assets[i].token < assets[j].token) {
                    (assets[i], assets[j]) = (assets[j], assets[i]);
                }
            }
        }
        return assets;
    }

    function sqrtX96(uint256 n) public pure returns (uint256) {
        return FixedPointMathLib.sqrt(n * (2 ** 96));
    }

    // forge test -vvvv --match-test testFuzz_automated_portfolio_erc20

    // create, mint, burn, rebalance, burn, mint, rebalance
    function testFuzz_automated_portfolio_erc20(uint256 inputAmount) public {
        vm.assume(inputAmount > 0.00001 ether);
        vm.assume(inputAmount < 1 ether);
        // create
        PortfolioManager.Asset[] memory assets = new PortfolioManager.Asset[](3);
        assets[0] = PortfolioManager.Asset(Currency.unwrap(eth), 18, 30_000, 0);
        assets[1] = PortfolioManager.Asset(Currency.unwrap(wbtc), 18, 50_000, 0);
        assets[2] = PortfolioManager.Asset(Currency.unwrap(wsol), 18, 20_000, 0);
        uint256 id = pm.create(sortAssets(assets), Currency.unwrap(usdc), 30, false);

        uint256 nav = pm.nav(id, false);
        assertEq(nav, 0);

        // uint256 inputAmount = 0.00011 ether;
        uint256 inputAmountSqrtX96 = sqrtX96(inputAmount);

        // https://book.getfoundry.sh/tutorials/testing-eip712
        IERC20Permit erc20;
        SigUtils sigUtils;
        uint8 v;
        bytes32 r;
        bytes32 s;
        SigUtils.Permit memory permit;
        bytes32 digest;

        // mint
        erc20 = IERC20Permit(Currency.unwrap(usdc));
        sigUtils = new SigUtils(erc20.DOMAIN_SEPARATOR());
        permit = SigUtils.Permit({owner: user, spender: address(pm), value: inputAmount, nonce: 0, deadline: 1000 days});
        digest = sigUtils.getTypedDataHash(permit);
        (v, r, s) = vm.sign(userPrivateKey, digest);

        assertEq(pm.get(id).portfolioToken.balanceOf(user), 0);
        pm.mint(id, ERC20(Currency.unwrap(usdc)), user, address(pm), permit.value, permit.deadline, v, r, s);
        assertApproxEqAbs(pm.get(id).portfolioToken.balanceOf(user), inputAmountSqrtX96, 1 wei);
        nav = pm.nav(id, false);

        // burn
        sigUtils = new SigUtils(pm.get(id).portfolioToken.DOMAIN_SEPARATOR());
        permit = SigUtils.Permit({
            owner: user,
            spender: address(pm),
            value: inputAmountSqrtX96 / 2,
            nonce: 0,
            deadline: 1000 days
        });
        digest = sigUtils.getTypedDataHash(permit);
        (v, r, s) = vm.sign(userPrivateKey, digest);
        pm.burn(id, user, address(pm), permit.value, permit.deadline, v, r, s);
        assertApproxEqAbs(pm.get(id).portfolioToken.balanceOf(user), inputAmountSqrtX96 / 2, 1 wei);
        assertGt(nav, pm.nav(id, false));
        nav = pm.nav(id, false);

        // rebalance
        pm.rebalance(id);
        assertEq(nav, pm.nav(id, false));
        vm.warp(block.timestamp + 31 days);
        pm.rebalance(id);
        assertNotEq(nav, pm.nav(id, false));
        nav = pm.nav(id, false);

        // burn
        sigUtils = new SigUtils(pm.get(id).portfolioToken.DOMAIN_SEPARATOR());
        permit = SigUtils.Permit({
            owner: user,
            spender: address(pm),
            value: inputAmountSqrtX96 / 2,
            nonce: 1,
            deadline: 1000 days
        });
        digest = sigUtils.getTypedDataHash(permit);
        (v, r, s) = vm.sign(userPrivateKey, digest);
        pm.burn(id, user, address(pm), permit.value, permit.deadline, v, r, s);
        assertGt(nav, pm.nav(id, false));
        nav = pm.nav(id, false);

        // mint
        erc20 = IERC20Permit(Currency.unwrap(usdc));
        sigUtils = new SigUtils(erc20.DOMAIN_SEPARATOR());
        permit = SigUtils.Permit({
            owner: user,
            spender: address(pm),
            value: inputAmount / 300,
            nonce: 1,
            deadline: 1000 days
        });
        digest = sigUtils.getTypedDataHash(permit);
        (v, r, s) = vm.sign(userPrivateKey, digest);

        pm.mint(id, ERC20(Currency.unwrap(usdc)), user, address(pm), permit.value, permit.deadline, v, r, s);
        assertLt(nav, pm.nav(id, false));
        nav = pm.nav(id, false);

        // rebalance
        pm.rebalance(id);
        assertEq(nav, pm.nav(id, false));
        vm.warp(block.timestamp + 31 days);
        pm.rebalance(id);
        assertNotEq(nav, pm.nav(id, false));
        nav = pm.nav(id, false);
    }

    // function testFuzz_automated_portfolio_native() public {}
    // function testFuzz_managed_portfolio_erc20() public {}
    // function testFuzz_managed_portfolio_native() public {}

    function test_addPair() public {
        (Currency currency0, Currency currency1) = deployMintAndApprove2Currencies();
        (PoolKey memory poolKey,) =
            initPoolAndAddLiquidity(currency0, currency1, NO_HOOK, FEE, SQRT_PRICE_4_1, ZERO_BYTES);

        pm._addPair(poolKey);

        bytes32 hash = pm._hashPair(Currency.unwrap(currency0), Currency.unwrap(currency1));

        (Currency _currency0, Currency _currency1, uint24 _fee, int24 _tickSpacing, IHooks _hooks) =
            pm._pairToPoolKey(hash);
        PoolKey memory _poolKey = PoolKey(_currency0, _currency1, _fee, _tickSpacing, _hooks);

        assertEq(abi.encode(_poolKey.toId()), abi.encode(poolKey.toId()));
    }

    function testFuzz_hashPair(address a, address b) public view {
        address currency0;
        address currency1;

        if (a < b) {
            currency0 = a;
            currency1 = b;
        } else {
            currency0 = b;
            currency1 = a;
        }

        assertEq(pm._hashPair(a, b), keccak256(abi.encode(currency0, currency1)));
    }

    function test_id() public {
        assertEq(pm.exposed_id(), 1);
        assertEq(pm.exposed_id(), 2);
        assertEq(pm.exposed_id(), 3);
    }
}
