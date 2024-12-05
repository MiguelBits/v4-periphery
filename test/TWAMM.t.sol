pragma solidity ^0.8.15;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {TWAMMImplementation} from "./shared/implementation/TWAMMImplementation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TWAMM} from "../contracts/hooks/examples/TWAMM.sol";
import {ITWAMM} from "../contracts/interfaces/ITWAMM.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract TWAMMTest is Test, Deployers, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    event SubmitOrder(
        PoolId indexed poolId,
        address indexed owner,
        uint160 expiration,
        bool zeroForOne,
        uint256 sellRate,
        uint256 earningsFactorLast
    );

    event UpdateOrder(
        PoolId indexed poolId,
        address indexed owner,
        uint160 expiration,
        bool zeroForOne,
        uint256 sellRate,
        uint256 earningsFactorLast
    );

    TWAMMImplementation twamm = TWAMMImplementation(
        address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG))
    );
    address hookAddress;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        TWAMMImplementation impl = new TWAMMImplementation(manager, 10_000, twamm);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(twamm), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(twamm), slot, vm.load(address(impl), slot));
            }
        }

        // modifyLiquidityRouter = new PoolLiquidityPositionTest(IPoolManager(address(manager)));
        // swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        (poolKey, poolId) = initPool(currency0, currency1, twamm, 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        token0.approve(address(modifyLiquidityRouter), 100 ether);
        token1.approve(address(modifyLiquidityRouter), 100 ether);
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, IPoolManager.ModifyLiquidityParams(-60, 60, 10 ether, 0), ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, IPoolManager.ModifyLiquidityParams(-120, 120, 10 ether, 0), ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10 ether, 0),
            ZERO_BYTES
        );
    }

    function testTWAMM_beforeInitialize_SetsLastVirtualOrderTimestamp() public {
        (PoolKey memory initKey, PoolId initId) = newPoolKeyWithTWAMM(twamm);
        assertEq(twamm.lastVirtualOrderTimestamp(initId), 0);
        vm.warp(10000);
        manager.initialize(initKey, SQRT_PRICE_1_1, ZERO_BYTES);
        assertEq(twamm.lastVirtualOrderTimestamp(initId), 10000);
    }

    function testTWAMM_submitOrder_storesOrderWithCorrectPoolAndOrderPoolInfo() public {
        uint160 expiration = 30000;
        uint160 submitTimestamp = 10000;
        uint160 duration = expiration - submitTimestamp;

        ITWAMM.OrderKey memory orderKey = ITWAMM.OrderKey(address(this), expiration, true);

        ITWAMM.Order memory nullOrder = twamm.getOrder(poolKey, orderKey);
        assertEq(nullOrder.sellRate, 0);
        assertEq(nullOrder.earningsFactorLast, 0);

        vm.warp(10000);
        token0.approve(address(twamm), 100 ether);
        snapStart("TWAMMSubmitOrder");
        twamm.submitOrder(poolKey, orderKey, 1 ether);
        snapEnd();

        ITWAMM.Order memory submittedOrder = twamm.getOrder(poolKey, orderKey);
        (uint256 sellRateCurrent0For1, uint256 earningsFactorCurrent0For1) = twamm.getOrderPool(poolKey, true);
        (uint256 sellRateCurrent1For0, uint256 earningsFactorCurrent1For0) = twamm.getOrderPool(poolKey, false);

        assertEq(submittedOrder.sellRate, 1 ether / duration);
        assertEq(submittedOrder.earningsFactorLast, 0);
        assertEq(sellRateCurrent0For1, 1 ether / duration);
        assertEq(sellRateCurrent1For0, 0);
        assertEq(earningsFactorCurrent0For1, 0);
        assertEq(earningsFactorCurrent1For0, 0);
    }

    function testTWAMM_submitOrder_storesSellRatesEarningsFactorsProperly() public {
        uint160 expiration1 = 30000;
        uint160 expiration2 = 40000;
        uint256 submitTimestamp1 = 10000;
        uint256 submitTimestamp2 = 30000;
        uint256 earningsFactor0For1;
        uint256 earningsFactor1For0;
        uint256 sellRate0For1;
        uint256 sellRate1For0;

        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), expiration1, true);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), expiration2, true);
        ITWAMM.OrderKey memory orderKey3 = ITWAMM.OrderKey(address(this), expiration2, false);

        token0.approve(address(twamm), 100e18);
        token1.approve(address(twamm), 100e18);

        // Submit 2 TWAMM orders and test all information gets updated
        vm.warp(submitTimestamp1);
        twamm.submitOrder(poolKey, orderKey1, 1e18);
        twamm.submitOrder(poolKey, orderKey3, 3e18);

        (sellRate0For1, earningsFactor0For1) = twamm.getOrderPool(poolKey, true);
        (sellRate1For0, earningsFactor1For0) = twamm.getOrderPool(poolKey, false);
        assertEq(sellRate0For1, 1e18 / (expiration1 - submitTimestamp1));
        assertEq(sellRate1For0, 3e18 / (expiration2 - submitTimestamp1));
        assertEq(earningsFactor0For1, 0);
        assertEq(earningsFactor1For0, 0);

        // Warp time and submit 1 TWAMM order. Test that pool information is updated properly as one order expires and
        // another order is added to the pool
        vm.warp(submitTimestamp2);
        twamm.submitOrder(poolKey, orderKey2, 2e18);

        (sellRate0For1, earningsFactor0For1) = twamm.getOrderPool(poolKey, true);
        (sellRate1For0, earningsFactor1For0) = twamm.getOrderPool(poolKey, false);

        assertEq(sellRate0For1, 2e18 / (expiration2 - submitTimestamp2));
        assertEq(sellRate1For0, 3e18 / (expiration2 - submitTimestamp1));
        assertEq(earningsFactor0For1, 1712020976636017581269515821040000);
        assertEq(earningsFactor1For0, 1470157410324350030712806974476955);
    }

    function testTWAMM_submitOrder_emitsEvent() public {
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, true);

        token0.approve(address(twamm), 100e18);
        vm.warp(10000);

        vm.expectEmit(false, false, false, true);
        emit SubmitOrder(poolId, address(this), 30000, true, 1 ether / 20000, 0);
        twamm.submitOrder(poolKey, orderKey1, 1e18);
    }

    function testTWAMM_submitOrder_singleSell_zeroForOne_sellRateAndEarningsFactorGetsUpdatedProperly() public {
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, true);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), 40000, true);

        token0.approve(address(twamm), 100e18);
        vm.warp(10000);
        twamm.submitOrder(poolKey, orderKey1, 1e18);
        vm.warp(30000);
        twamm.submitOrder(poolKey, orderKey2, 1e18);
        vm.warp(40000);

        ITWAMM.Order memory submittedOrder = twamm.getOrder(poolKey, orderKey2);
        (, uint256 earningsFactorCurrent) = twamm.getOrderPool(poolKey, true);
        assertEq(submittedOrder.sellRate, 1 ether / 10000);
        assertEq(submittedOrder.earningsFactorLast, earningsFactorCurrent);
    }

    function testTWAMM_submitOrder_singleSell_OneForZero_sellRateAndEarningsFactorGetsUpdatedProperly() public {
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, false);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), 40000, false);

        token1.approve(address(twamm), 100e18);
        vm.warp(10000);
        twamm.submitOrder(poolKey, orderKey1, 1e18);
        vm.warp(30000);
        twamm.submitOrder(poolKey, orderKey2, 1e18);
        vm.warp(40000);

        ITWAMM.Order memory submittedOrder = twamm.getOrder(poolKey, orderKey2);
        (, uint256 earningsFactorCurrent) = twamm.getOrderPool(poolKey, false);
        assertEq(submittedOrder.sellRate, 1 ether / 10000);
        assertEq(submittedOrder.earningsFactorLast, earningsFactorCurrent);
    }

    function testTWAMM_submitOrder_revertsIfExpiryNotOnInterval() public {
        uint160 invalidTimestamp = 30001;
        ITWAMM.OrderKey memory invalidKey = ITWAMM.OrderKey(address(this), invalidTimestamp, true);
        token0.approve(address(twamm), 100e18);

        vm.expectRevert(abi.encodeWithSelector(ITWAMM.ExpirationNotOnInterval.selector, invalidTimestamp));
        twamm.submitOrder(poolKey, invalidKey, 1e18);
    }

    function testTWAMM_submitOrder_revertsIfPoolNotInitialized() public {
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, true);
        PoolKey memory invalidPoolKey = poolKey;
        invalidPoolKey.fee = 1000;

        token0.approve(address(twamm), 100e18);
        vm.warp(10000);

        vm.expectRevert(ITWAMM.NotInitialized.selector);
        twamm.submitOrder(invalidPoolKey, orderKey1, 1e18);
    }

    function testTWAMM_submitOrder_revertsIfExpiryInThePast() public {
        uint160 prevTimestamp = 10000;
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), prevTimestamp, true);
        token0.approve(address(twamm), 100e18);
        vm.warp(20000);

        vm.expectRevert(abi.encodeWithSelector(ITWAMM.ExpirationLessThanBlocktime.selector, prevTimestamp));
        twamm.submitOrder(poolKey, orderKey1, 1e18);
    }

    function testTWAMM_updateOrder_emitsEvent() public {
        ITWAMM.OrderKey memory orderKey1;
        ITWAMM.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();
        // decrease order amount by 10%
        int256 amountDelta = -1;

        // set timestamp to halfway through the order
        vm.warp(20000);

        vm.expectEmit(true, true, true, true);
        emit UpdateOrder(poolId, address(this), 30000, true, 0, 10000 << 96);
        twamm.updateOrder(poolKey, orderKey1, amountDelta);
    }

    function testTWAMM_updatedOrder_calculateTokensOwedAfterExpiration() public {
        ITWAMM.OrderKey memory orderKey1;
        ITWAMM.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        // submit two more orders that will expire after order1 & order2 so the earningsFactorCurrent will continue growing after they expire
        uint256 extraOrderAmount = 2 ether;
        ITWAMM.OrderKey memory orderKey3 = ITWAMM.OrderKey(address(this), 60000, true);
        ITWAMM.OrderKey memory orderKey4 = ITWAMM.OrderKey(address(this), 60000, false);
        token0.approve(address(twamm), extraOrderAmount);
        token1.approve(address(twamm), extraOrderAmount);
        twamm.submitOrder(poolKey, orderKey3, extraOrderAmount);
        twamm.submitOrder(poolKey, orderKey4, extraOrderAmount);

        // set timestamp to after order1 & order2 expire
        vm.warp(40000);

        // update order1 & order2 after expiration, should use the earningsFactorAtInterval at expiration to settle
        vm.expectEmit(true, true, true, true);
        emit UpdateOrder(poolId, address(this), 30000, true, 0, 20000 << 96);
        twamm.updateOrder(poolKey, orderKey1, 0);

        vm.expectEmit(true, true, true, true);
        emit UpdateOrder(poolId, address(this), 30000, false, 0, 20000 << 96);
        twamm.updateOrder(poolKey, orderKey2, 0);

        uint256 token0Owed = twamm.tokensOwed(poolKey.currency0, orderKey2.owner);
        uint256 token1Owed = twamm.tokensOwed(poolKey.currency1, orderKey2.owner);

        assertEq(token0Owed, orderAmount);
        assertEq(token1Owed, orderAmount);
    }

    function testTWAMM_updateOrder_zeroForOne_decreasesSellrateUpdatesSellTokensOwed() public {
        ITWAMM.OrderKey memory orderKey1;
        ITWAMM.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();
        // decrease order amount by 10%
        int256 amountDelta = -int256(orderAmount) / 10;

        // set timestamp to halfway through the order
        vm.warp(20000);

        (uint256 originalSellRate,) = twamm.getOrderPool(poolKey, true);
        twamm.updateOrder(poolKey, orderKey1, amountDelta);
        (uint256 updatedSellRate,) = twamm.getOrderPool(poolKey, true);

        uint256 token0Owed = twamm.tokensOwed(poolKey.currency0, orderKey1.owner);
        uint256 token1Owed = twamm.tokensOwed(poolKey.currency1, orderKey1.owner);

        // takes 10% off the remaining half amount (so 80% of original sellrate)
        assertEq(updatedSellRate, originalSellRate * 80 / 100);
        assertEq(token0Owed, uint256(-amountDelta));
        assertEq(token1Owed, orderAmount / 2);
    }

    function testTWAMM_updateOrder_oneForZero_decreasesSellrateUpdatesSellTokensOwed() public {
        ITWAMM.OrderKey memory orderKey1;
        ITWAMM.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        // decrease order amount by 10%
        int256 amountDelta = -int256(orderAmount) / 10;

        // set timestamp to halfway through the order
        vm.warp(20000);

        (uint256 originalSellRate,) = twamm.getOrderPool(poolKey, false);
        twamm.updateOrder(poolKey, orderKey2, amountDelta);
        (uint256 updatedSellRate,) = twamm.getOrderPool(poolKey, false);

        uint256 token0Owed = twamm.tokensOwed(poolKey.currency0, orderKey1.owner);
        uint256 token1Owed = twamm.tokensOwed(poolKey.currency1, orderKey1.owner);

        // takes 10% off the remaining half (so 80% of original sellrate)
        assertEq(updatedSellRate, originalSellRate * 80 / 100);
        assertEq(token0Owed, orderAmount / 2);
        assertEq(token1Owed, uint256(-amountDelta));
    }

    function testTWAMM_updatedOrder_zeroForOne_closesOrderIfEliminatingPosition() public {
        ITWAMM.OrderKey memory orderKey1;
        ITWAMM.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        // set timestamp to halfway through the order
        vm.warp(20000);

        twamm.updateOrder(poolKey, orderKey1, -1);
        ITWAMM.Order memory deletedOrder = twamm.getOrder(poolKey, orderKey1);
        uint256 token0Owed = twamm.tokensOwed(poolKey.currency0, orderKey1.owner);
        uint256 token1Owed = twamm.tokensOwed(poolKey.currency1, orderKey1.owner);

        assertEq(deletedOrder.sellRate, 0);
        assertEq(deletedOrder.earningsFactorLast, 0);
        assertEq(token0Owed, orderAmount / 2);
        assertEq(token1Owed, orderAmount / 2);
    }

    function testTWAMM_updatedOrder_oneForZero_closesOrderIfEliminatingPosition() public {
        ITWAMM.OrderKey memory orderKey1;
        ITWAMM.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        // set timestamp to halfway through the order
        vm.warp(20000);

        twamm.updateOrder(poolKey, orderKey2, -1);
        ITWAMM.Order memory deletedOrder = twamm.getOrder(poolKey, orderKey2);
        uint256 token0Owed = twamm.tokensOwed(poolKey.currency0, orderKey2.owner);
        uint256 token1Owed = twamm.tokensOwed(poolKey.currency1, orderKey2.owner);

        assertEq(deletedOrder.sellRate, 0);
        assertEq(deletedOrder.earningsFactorLast, 0);
        assertEq(token0Owed, orderAmount / 2);
        assertEq(token1Owed, orderAmount / 2);
    }

    function testTWAMM_updatedOrder_zeroForOne_increaseOrderAmount() public {
        int256 amountDelta = 1 ether;
        ITWAMM.OrderKey memory orderKey1;
        ITWAMM.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        // set timestamp to halfway through the order
        vm.warp(20000);

        uint256 balance0TWAMMBefore = token0.balanceOf(address(twamm));
        token0.approve(address(twamm), uint256(amountDelta));
        twamm.updateOrder(poolKey, orderKey1, amountDelta);
        uint256 balance0TWAMMAfter = token0.balanceOf(address(twamm));

        ITWAMM.Order memory updatedOrder = twamm.getOrder(poolKey, orderKey1);
        uint256 token0Owed = twamm.tokensOwed(poolKey.currency0, orderKey1.owner);
        uint256 token1Owed = twamm.tokensOwed(poolKey.currency1, orderKey1.owner);

        assertEq(balance0TWAMMAfter - balance0TWAMMBefore, uint256(amountDelta));
        assertEq(updatedOrder.sellRate, 150000000000000);
        assertEq(token0Owed, 0);
        assertEq(token1Owed, orderAmount / 2);
    }

    function testTWAMM_updatedOrder_oneForZero_increaseOrderAmount() public {
        int256 amountDelta = 1 ether;
        ITWAMM.OrderKey memory orderKey1;
        ITWAMM.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        // set timestamp to halfway through the order
        vm.warp(20000);

        uint256 balance0TWAMMBefore = token1.balanceOf(address(twamm));
        token1.approve(address(twamm), uint256(amountDelta));
        twamm.updateOrder(poolKey, orderKey2, amountDelta);
        uint256 balance0TWAMMAfter = token1.balanceOf(address(twamm));

        ITWAMM.Order memory updatedOrder = twamm.getOrder(poolKey, orderKey2);
        uint256 token0Owed = twamm.tokensOwed(poolKey.currency0, orderKey2.owner);
        uint256 token1Owed = twamm.tokensOwed(poolKey.currency1, orderKey2.owner);

        assertEq(balance0TWAMMAfter - balance0TWAMMBefore, uint256(amountDelta));
        assertEq(updatedOrder.sellRate, 150000000000000);
        assertEq(token0Owed, orderAmount / 2);
        assertEq(token1Owed, 0);
    }

    function testTWAMM_updatedOrder_revertsIfDecreasingByAmoungGreaterThanOrder() public {
        ITWAMM.OrderKey memory orderKey1;
        ITWAMM.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();
        // decrease entire order after some has already sold
        int256 amountDelta = -int256(orderAmount);

        // set timestamp to halfway through the order
        vm.warp(20000);

        vm.expectRevert(
            abi.encodeWithSelector(ITWAMM.InvalidAmountDelta.selector, orderKey1, orderAmount / 2, amountDelta)
        );
        twamm.updateOrder(poolKey, orderKey1, amountDelta);
    }

    function testTWAMM_updatedOrder_doesNotRevertIfEliminatingExactAmount() public {
        ITWAMM.OrderKey memory orderKey1;
        ITWAMM.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        // decrease order amount by 10%
        int256 restOfOrder = -int256(orderAmount) / 2;

        // set timestamp to halfway through the order
        vm.warp(20000);

        twamm.updateOrder(poolKey, orderKey2, restOfOrder);
        (uint256 updatedSellRate,) = twamm.getOrderPool(poolKey, false);
        ITWAMM.Order memory deletedOrder = twamm.getOrder(poolKey, orderKey2);

        uint256 token0Owed = twamm.tokensOwed(poolKey.currency0, orderKey2.owner);
        uint256 token1Owed = twamm.tokensOwed(poolKey.currency1, orderKey2.owner);

        // sellRate is 0, tokens owed equal all of order
        assertEq(updatedSellRate, 0);
        assertEq(token0Owed, orderAmount / 2);
        assertEq(token1Owed, orderAmount / 2);
        assertEq(deletedOrder.sellRate, 0);
        assertEq(deletedOrder.earningsFactorLast, 0);
    }

    function testTWAMM_updateOrder_updatesTokensOwedIfCalledAfterExpirationWithNoDelta() public {
        ITWAMM.OrderKey memory orderKey1;
        ITWAMM.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        // set timestamp to halfway through the order
        vm.warp(orderKey2.expiration + 10);

        twamm.updateOrder(poolKey, orderKey2, 0);
        (uint256 updatedSellRate,) = twamm.getOrderPool(poolKey, false);
        ITWAMM.Order memory deletedOrder = twamm.getOrder(poolKey, orderKey2);

        uint256 token0Owed = twamm.tokensOwed(poolKey.currency0, orderKey2.owner);
        uint256 token1Owed = twamm.tokensOwed(poolKey.currency1, orderKey2.owner);

        // sellRate is 0, tokens owed equal all of order
        assertEq(updatedSellRate, 0);
        assertEq(token0Owed, orderAmount);
        assertEq(token1Owed, 0);
        assertEq(deletedOrder.sellRate, 0);
        assertEq(deletedOrder.earningsFactorLast, 0);
    }

    function testTWAMM_updateOrder_revertsIfIncreasingAmountAfterExpiration() public {
        ITWAMM.OrderKey memory orderKey1;
        ITWAMM.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        // set timestamp to after expiration
        vm.warp(orderKey2.expiration + 10);

        vm.expectRevert(abi.encodeWithSelector(ITWAMM.CannotModifyCompletedOrder.selector, orderKey2));
        twamm.updateOrder(poolKey, orderKey2, 1000);
    }

    function testTWAMM_executeTWAMMOrders_updatesAllTheNecessaryEarningsFactorIntervals() public {
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, true);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), 40000, false);
        ITWAMM.OrderKey memory orderKey3 = ITWAMM.OrderKey(address(this), 50000, true);
        ITWAMM.OrderKey memory orderKey4 = ITWAMM.OrderKey(address(this), 50000, false);

        token0.approve(address(twamm), 100 ether);
        token1.approve(address(twamm), 100 ether);

        vm.warp(10000);

        twamm.submitOrder(poolKey, orderKey1, 1 ether);
        twamm.submitOrder(poolKey, orderKey2, 5 ether);
        twamm.submitOrder(poolKey, orderKey3, 2 ether);
        twamm.submitOrder(poolKey, orderKey4, 2 ether);

        assertEq(twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), true, 20000), 0);
        assertEq(twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), false, 20000), 0);
        assertEq(twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), true, 30000), 0);
        assertEq(twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), false, 30000), 0);
        assertEq(twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), true, 40000), 0);
        assertEq(twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), false, 40000), 0);
        assertEq(twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), true, 50000), 0);
        assertEq(twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), false, 50000), 0);

        vm.warp(50000); // go to exact interval to also test when block is exactly on an interval
        snapStart("TWAMM executTWAMMOrders 3 intervals");
        twamm.executeTWAMMOrders(poolKey);
        snapEnd();

        assertEq(twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), true, 20000), 0);
        assertEq(twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), false, 20000), 0);
        assertEq(
            twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), true, 30000), 1903834450064690094904650934081653
        );
        assertEq(
            twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), false, 30000), 1332467160273236668937468324643833
        );
        assertEq(
            twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), true, 40000), 3151779959438527761611322345863307
        );
        assertEq(
            twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), false, 40000), 1837497928424750201261148602165737
        );
        assertEq(
            twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), true, 50000), 4499127981259426598474740139623306
        );
        assertEq(
            twamm.getOrderPoolEarningsFactorAtInterval(poolKey.toId(), false, 50000), 2303495623595701879842493741448458
        );
    }

    function testTWAMM_executeTWAMMOrders_OneIntervalGas() public {
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, true);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), 30000, false);

        token0.approve(address(twamm), 100 ether);
        token1.approve(address(twamm), 100 ether);

        vm.warp(10000);

        twamm.submitOrder(poolKey, orderKey1, 1 ether);
        twamm.submitOrder(poolKey, orderKey2, 5 ether);

        vm.warp(60000);
        snapStart("TWAMM executTWAMMOrders 1 interval");
        twamm.executeTWAMMOrders(poolKey);
        snapEnd();
    }

    function testTWAMM_executeTWAMMOrders_TwoIntervalsGas() public {
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, true);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), 30000, false);
        ITWAMM.OrderKey memory orderKey3 = ITWAMM.OrderKey(address(this), 40000, true);
        ITWAMM.OrderKey memory orderKey4 = ITWAMM.OrderKey(address(this), 40000, false);

        token0.approve(address(twamm), 100 ether);
        token1.approve(address(twamm), 100 ether);

        vm.warp(10000);

        twamm.submitOrder(poolKey, orderKey1, 1 ether);
        twamm.submitOrder(poolKey, orderKey2, 5 ether);
        twamm.submitOrder(poolKey, orderKey3, 2 ether);
        twamm.submitOrder(poolKey, orderKey4, 2 ether);

        vm.warp(60000);
        snapStart("TWAMM executTWAMMOrders 2 intervals");
        twamm.executeTWAMMOrders(poolKey);
        snapEnd();
    }

    function testTWAMM_executeTWAMMOrders_singlePoolSell_zeroForOne_OneIntervalGas() public {
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, true);

        token0.approve(address(twamm), 100 ether);

        vm.warp(10000);

        twamm.submitOrder(poolKey, orderKey1, 1 ether);

        vm.warp(60000);
        snapStart("TWAMM executTWAMMOrders singleSell 1 interval");
        twamm.executeTWAMMOrders(poolKey);
        snapEnd();
    }

    function testTWAMM_executeTWAMMOrders_singlePoolSell_oneForZero_OneIntervalGas() public {
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, false);

        token1.approve(address(twamm), 100 ether);

        vm.warp(10000);

        twamm.submitOrder(poolKey, orderKey1, 1 ether);

        vm.warp(60000);
        snapStart("TWAMM executTWAMMOrders singleSell oneForZero 1 interval");
        twamm.executeTWAMMOrders(poolKey);
        snapEnd();
    }

    function testTWAMM_executeTWAMMOrders_SinglePoolSell_zeroForOne_twoIntervalsGas() public {
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, true);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), 40000, true);

        token0.approve(address(twamm), 100 ether);

        vm.warp(10000);

        twamm.submitOrder(poolKey, orderKey1, 1 ether);
        twamm.submitOrder(poolKey, orderKey2, 5 ether);

        vm.warp(60000);
        snapStart("TWAMM executTWAMMOrders singleSell 2 intervals");
        twamm.executeTWAMMOrders(poolKey);
        snapEnd();
    }

    function testTWAMM_executeTWAMMOrders_SinglePoolSell_oneForZero_twoIntervalsGas() public {
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, false);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), 40000, false);

        token1.approve(address(twamm), 100 ether);

        vm.warp(10000);

        twamm.submitOrder(poolKey, orderKey1, 5 ether);
        twamm.submitOrder(poolKey, orderKey2, 1 ether);

        vm.warp(60000);
        snapStart("TWAMM executTWAMMOrders singleSell oneForZero 2 intervals");
        twamm.executeTWAMMOrders(poolKey);
        snapEnd();
    }

    function testTWAMMEndToEndSimSymmetricalOrderPools() public {
        uint256 orderAmount = 1e18;
        ITWAMM.OrderKey memory orderKey1 = ITWAMM.OrderKey(address(this), 30000, true);
        ITWAMM.OrderKey memory orderKey2 = ITWAMM.OrderKey(address(this), 30000, false);

        token0.approve(address(twamm), 100e18);
        token1.approve(address(twamm), 100e18);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, IPoolManager.ModifyLiquidityParams(-2400, 2400, 10 ether, 0), ZERO_BYTES
        );

        // submit symmetrical orders trading against each other (easy numbers)
        vm.warp(10000);
        twamm.submitOrder(poolKey, orderKey1, orderAmount);
        twamm.submitOrder(poolKey, orderKey2, orderAmount);

        // execute half the orders and update individual order info
        vm.warp(20000);
        twamm.executeTWAMMOrders(poolKey);
        twamm.updateOrder(poolKey, orderKey1, 0);
        twamm.updateOrder(poolKey, orderKey2, 0);

        uint256 earningsToken0 = twamm.tokensOwed(poolKey.currency0, address(this));
        uint256 earningsToken1 = twamm.tokensOwed(poolKey.currency1, address(this));

        // each owner should be owed half the tokens from the opposing order
        assertEq(earningsToken0, orderAmount / 2);
        assertEq(earningsToken1, orderAmount / 2);

        uint256 balance0BeforeTWAMM = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(twamm));
        uint256 balance1BeforeTWAMM = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(twamm));
        uint256 balance0BeforeThis = poolKey.currency0.balanceOfSelf();
        uint256 balance1BeforeThis = poolKey.currency1.balanceOfSelf();

        // conplete order and collect tokens
        vm.warp(30000);
        twamm.executeTWAMMOrders(poolKey);
        twamm.updateOrder(poolKey, orderKey1, 0);
        twamm.updateOrder(poolKey, orderKey2, 0);
        twamm.claimTokens(poolKey.currency0, address(this), 0);
        twamm.claimTokens(poolKey.currency1, address(this), 0);

        assertEq(twamm.tokensOwed(poolKey.currency0, address(this)), 0);
        assertEq(twamm.tokensOwed(poolKey.currency1, address(this)), 0);

        uint256 balance0AfterTWAMM = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(twamm));
        uint256 balance1AfterTWAMM = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(twamm));
        uint256 balance0AfterThis = poolKey.currency0.balanceOfSelf();
        uint256 balance1AfterThis = poolKey.currency1.balanceOfSelf();

        // TWAMM should not have any remaining balance
        assertEq(balance1AfterTWAMM, 0);
        assertEq(balance0AfterTWAMM, 0);
        assertEq(balance0BeforeTWAMM - balance0AfterTWAMM, orderAmount);
        assertEq(balance0AfterThis - balance0BeforeThis, orderAmount);
        assertEq(balance1BeforeTWAMM - balance1AfterTWAMM, orderAmount);
        assertEq(balance1AfterThis - balance1BeforeThis, orderAmount);
    }

    function testTWAMM_isCrossingIinitializedTick_returnsFalseWhenSwappingToSamePrice() public view {
        TWAMM.PoolParamsOnExecute memory poolParams = TWAMM.PoolParamsOnExecute(SQRT_PRICE_1_1, 1000000 ether);

        (bool crossingInitializedTick, int24 nextTickInit) =
            twamm.isCrossingInitializedTick(poolParams, manager, poolKey, SQRT_PRICE_1_1);

        assertEq(crossingInitializedTick, false);
        assertEq(nextTickInit, 60);
    }

    function testTWAMM_isCrossingIinitializedTick_returnsTrueWhenCrossingToTheRight() public view {
        TWAMM.PoolParamsOnExecute memory poolParams = TWAMM.PoolParamsOnExecute(SQRT_PRICE_1_1, 1000000 ether);

        (bool crossingInitializedTick, int24 nextTickInit) =
            twamm.isCrossingInitializedTick(poolParams, manager, poolKey, SQRT_PRICE_2_1);

        assertEq(crossingInitializedTick, true);
        assertEq(nextTickInit, 60);
    }

    function testTWAMM_isCrossingIinitializedTick_returnsTrueWhenCrossingToTheLeft() public view {
        TWAMM.PoolParamsOnExecute memory poolParams = TWAMM.PoolParamsOnExecute(SQRT_PRICE_1_1, 1000000 ether);

        (bool crossingInitializedTick, int24 nextTickInit) =
            twamm.isCrossingInitializedTick(poolParams, manager, poolKey, SQRT_PRICE_1_2);

        assertEq(crossingInitializedTick, true);
        assertEq(nextTickInit, -60);
    }

    function testTWAMM_isCrossingIinitializedTick_returnsFalseWhenSwappingRightBeforeTick() public view {
        TWAMM.PoolParamsOnExecute memory poolParams = TWAMM.PoolParamsOnExecute(SQRT_PRICE_1_1, 1000000 ether);

        (bool crossingInitializedTick, int24 nextTickInit) =
            twamm.isCrossingInitializedTick(poolParams, manager, poolKey, TickMath.getSqrtPriceAtTick(59));

        assertEq(crossingInitializedTick, false);
        assertEq(nextTickInit, 60);
    }

    function testTWAMM_isCrossingIinitializedTick_returnsFalseWhenSwappingRightToInitializeableTick() public view {
        TWAMM.PoolParamsOnExecute memory poolParams = TWAMM.PoolParamsOnExecute(SQRT_PRICE_1_1, 1000000 ether);

        (bool crossingInitializedTick, int24 nextTickInit) =
            twamm.isCrossingInitializedTick(poolParams, manager, poolKey, TickMath.getSqrtPriceAtTick(50));

        assertEq(crossingInitializedTick, false);
        assertEq(nextTickInit, 60);
    }

    function testTWAMM_isCrossingIinitializedTick_returnsFalseWhenSwappingLeftBeforeTick() public view {
        TWAMM.PoolParamsOnExecute memory poolParams = TWAMM.PoolParamsOnExecute(SQRT_PRICE_1_1, 1000000 ether);

        (bool crossingInitializedTick, int24 nextTickInit) =
            twamm.isCrossingInitializedTick(poolParams, manager, poolKey, TickMath.getSqrtPriceAtTick(-59));

        assertEq(crossingInitializedTick, false);
        assertEq(nextTickInit, -60);
    }

    function testTWAMM_isCrossingIinitializedTick_returnsFalseWhenSwappingLeftToInitializeableTick() public view {
        TWAMM.PoolParamsOnExecute memory poolParams = TWAMM.PoolParamsOnExecute(SQRT_PRICE_1_1, 1000000 ether);

        (bool crossingInitializedTick, int24 nextTickInit) =
            twamm.isCrossingInitializedTick(poolParams, manager, poolKey, TickMath.getSqrtPriceAtTick(-50));

        assertEq(crossingInitializedTick, false);
        assertEq(nextTickInit, -60);
    }

    function newPoolKeyWithTWAMM(IHooks hooks) public returns (PoolKey memory, PoolId) {
        MockERC20[] memory tokens = deployTokens(2, 2 ** 255);
        (MockERC20 t0, MockERC20 t1) =
            address(tokens[0]) < address(tokens[0]) ? (tokens[0], tokens[1]) : (tokens[1], tokens[0]);

        PoolKey memory key = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 0, 60, hooks);
        return (key, key.toId());
    }

    function submitOrdersBothDirections()
        internal
        returns (ITWAMM.OrderKey memory key1, ITWAMM.OrderKey memory key2, uint256 amount)
    {
        key1 = ITWAMM.OrderKey(address(this), 30000, true);
        key2 = ITWAMM.OrderKey(address(this), 30000, false);
        amount = 1 ether;

        token0.approve(address(twamm), amount);
        token1.approve(address(twamm), amount);

        vm.warp(10000);
        twamm.submitOrder(poolKey, key1, amount);
        twamm.submitOrder(poolKey, key2, amount);
    }
}
