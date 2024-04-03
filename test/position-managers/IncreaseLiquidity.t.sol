// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "../../contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {PoolStateLibrary} from "../../contracts/libraries/PoolStateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {INonfungiblePositionManager} from "../../contracts/interfaces/INonfungiblePositionManager.sol";
import {NonfungiblePositionManager} from "../../contracts/NonfungiblePositionManager.sol";
import {LiquidityRange, LiquidityRangeId, LiquidityRangeIdLibrary} from "../../contracts/types/LiquidityRange.sol";

import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";

contract FeeCollectionTest is Test, Deployers, GasSnapshot, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using CurrencyLibrary for Currency;
    using LiquidityRangeIdLibrary for LiquidityRange;
    using PoolIdLibrary for PoolKey;

    NonfungiblePositionManager lpm;

    PoolId poolId;
    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    uint256 constant STARTING_USER_BALANCE = 10_000_000 ether;

    // unused value for the fuzz helper functions
    uint128 constant DEAD_VALUE = 6969.6969 ether;

    // expresses the fee as a wad (i.e. 3000 = 0.003e18 = 0.30%)
    uint256 FEE_WAD;

    LiquidityRange range;

    function setUp() public {
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), 3000, SQRT_RATIO_1_1, ZERO_BYTES);
        FEE_WAD = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);

        lpm = new NonfungiblePositionManager(manager);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);

        // Give tokens to Alice and Bob, with approvals
        IERC20(Currency.unwrap(currency0)).transfer(alice, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(alice, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency0)).transfer(bob, STARTING_USER_BALANCE);
        IERC20(Currency.unwrap(currency1)).transfer(bob, STARTING_USER_BALANCE);
        vm.startPrank(alice);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        IERC20(Currency.unwrap(currency0)).approve(address(lpm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(lpm), type(uint256).max);
        vm.stopPrank();

        // define a reusable range
        range = LiquidityRange({key: key, tickLower: -300, tickUpper: 300});
    }

    function test_increaseLiquidity_withExactFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her exact fees to increase liquidity (compounding)

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.prank(alice);
        (uint256 tokenIdAlice,) = lpm.mint(range, liquidityAlice, block.timestamp + 1, alice, ZERO_BYTES);

        // bob provides liquidity
        vm.prank(bob);
        lpm.mint(range, liquidityBob, block.timestamp + 1, bob, ZERO_BYTES);

        // swap to create fees
        uint256 swapAmount = 0.001e18;
        swap(key, true, -int256(swapAmount), ZERO_BYTES);
        swap(key, false, -int256(swapAmount), ZERO_BYTES); // move the price back

        // alice uses her exact fees to increase liquidity
        (uint256 token0Owed, uint256 token1Owed) = lpm.feesOwed(tokenIdAlice);
        console2.log("token0Owed", token0Owed);
        console2.log("token1Owed", token1Owed);

        (uint160 sqrtPriceX96,,,) = PoolStateLibrary.getSlot0(manager, range.key.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(range.tickLower),
            TickMath.getSqrtRatioAtTick(range.tickUpper),
            token0Owed,
            token1Owed
        );

        vm.prank(alice);
        lpm.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenIdAlice,
                liquidityDelta: uint128(liquidityDelta),
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1
            }),
            ZERO_BYTES,
            false
        );
    }

    function test_increaseLiquidity_withExcessFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her fees to increase liquidity. Excess fees are returned to her as 6909
    }
    function test_increaseLiquidity_withInsufficientFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her fees to increase liquidity. Additional funds are used by alice to increase liquidity
    }
}
