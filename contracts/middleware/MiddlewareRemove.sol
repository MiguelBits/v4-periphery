// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {BaseMiddleware} from "./BaseMiddleware.sol";
import {BaseHook} from "../BaseHook.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {NonZeroDeltaCount} from "@uniswap/v4-core/src/libraries/NonZeroDeltaCount.sol";
import {IExttload} from "@uniswap/v4-core/src/interfaces/IExttload.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {console} from "../../lib/forge-std/src/console.sol";

contract MiddlewareRemoveNoDeltas is BaseMiddleware {
    using CustomRevert for bytes4;
    using Hooks for IHooks;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    error HookPermissionForbidden(address hooks);
    error HookModifiedPrice();
    error HookModifiedDeltas();
    error FailedImplementationCall();
    error MaxFeeBipsTooHigh();

    bytes internal constant ZERO_BYTES = bytes("");
    uint256 public constant GAS_LIMIT = 10_000_000;
    uint256 public constant MAX_BIPS = 10_000;

    uint256 public immutable maxFeeBips;

    // todo: use tstore
    BalanceDelta private quote;

    constructor(IPoolManager _manager, address _impl) BaseMiddleware(_manager, _impl) {
        // if (_maxFeeBips > MAX_BIPS) revert MaxFeeBipsTooHigh();
        // maxFeeBips = _maxFeeBips;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        try this._quoteRemove(key, params) {}
        catch (bytes memory reason) {
            quote = abi.decode(reason, (BalanceDelta));
        }
        address(this).delegatecall{gas: GAS_LIMIT}(
            abi.encodeWithSelector(this._callAndEnsureNoDeltas.selector, msg.data)
        );
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _quoteRemove(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        external
        returns (bytes memory)
    {
        (BalanceDelta callerDelta,) = manager.modifyLiquidity(key, params, ZERO_BYTES);
        bytes memory result = abi.encode(callerDelta);
        assembly {
            revert(add(0x20, result), mload(result))
        }
    }

    function _callAndEnsureNoDeltas(bytes calldata data) external {
        (bool success,) = address(implementation).delegatecall(data);
        if (!success) {
            revert FailedImplementationCall();
        }
        if (manager.getNonzeroDeltaCount() != 0) {
            revert HookModifiedDeltas();
        }
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        address(this).delegatecall{gas: GAS_LIMIT}(
            abi.encodeWithSelector(this._callAndEnsureNormalDeltas.selector, sender, key, params, delta, hookData)
        );
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _callAndEnsureNormalDeltas(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external {
        (bool success, bytes memory returnData) = address(implementation).delegatecall(
            abi.encodeWithSelector(this.afterRemoveLiquidity.selector, sender, key, params, delta, hookData)
        );
        if (!success) {
            revert FailedImplementationCall();
        }
        if (manager.getNonzeroDeltaCount() != 0) {
            revert HookModifiedDeltas();
        }
    }

    function _ensureNormalDeltas(address sender, PoolKey calldata key) internal view {
        console.log(sender);
        uint256 nonzeroDeltaCount = manager.getNonzeroDeltaCount();
        if (nonzeroDeltaCount > 2) {
            console.log(nonzeroDeltaCount);
            revert HookModifiedDeltas();
        }
        console.log(nonzeroDeltaCount);
        uint256 senderNonzeroDeltaCount;
        console.logInt(manager.currencyDelta(address(this), key.currency0));
        if (manager.currencyDelta(sender, key.currency0) != 0) {
            senderNonzeroDeltaCount++;
        }
        if (manager.currencyDelta(sender, key.currency1) != 0) {
            senderNonzeroDeltaCount++;
        }
        console.log(senderNonzeroDeltaCount);
        if (senderNonzeroDeltaCount != nonzeroDeltaCount) {
            // there is a non-zero delta for not the sender
            revert HookModifiedDeltas();
        }
    }

    function _ensureValidFlags(address _impl) internal view virtual override {
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != uint160(_impl) & Hooks.ALL_HOOK_MASK) {
            revert FlagsMismatch();
        }
        if (IHooks(address(this)).hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)) {
            HookPermissionForbidden.selector.revertWith(address(this));
        }
    }
}
