// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";

/// @dev Minimal swap router that, like Uniswap's periphery routers, exposes the account behind the swap.
contract MsgSenderRouter is IUnlockCallback, IMsgSender {
    using CurrencySettler for Currency;

    IPoolManager public immutable manager;
    address public msgSender;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta delta) {
        msgSender = msg.sender;
        delta = abi.decode(manager.unlock(abi.encode(msg.sender, key, params)), (BalanceDelta));
        msgSender = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (address user, PoolKey memory key, SwapParams memory params) =
            abi.decode(data, (address, PoolKey, SwapParams));
        BalanceDelta delta = manager.swap(key, params, "");
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 < 0) key.currency0.settle(manager, user, uint128(-a0), false);
        if (a1 < 0) key.currency1.settle(manager, user, uint128(-a1), false);
        if (a0 > 0) key.currency0.take(manager, user, uint128(a0), false);
        if (a1 > 0) key.currency1.take(manager, user, uint128(a1), false);
        return abi.encode(delta);
    }
}
