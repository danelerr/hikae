// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HikaeHook} from "../src/HikaeHook.sol";
import {HikaeRetroHook} from "../src/HikaeRetroHook.sol";
import {MsgSenderRouter} from "./mocks/MsgSenderRouter.sol";

contract HikaeRetroHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    uint24 constant BASE_FEE = 3000;
    uint16 constant CAPTURE_BPS = 6000;
    uint24 constant MAX_FEE = 30000;
    uint32 constant MAX_AGE = 120;
    uint16 constant HOLD_BPS = 100; // 1%
    uint32 constant WINDOW = 8; // seconds
    int256 constant AMOUNT = 1e15;

    address callbackProxy = makeAddr("callbackProxy");
    address reactive = makeAddr("reactive");
    address alice = makeAddr("alice");
    HikaeRetroHook hook;
    MsgSenderRouter router;

    function setUp() public {
        vm.warp(1_795_353_716); // a realistic clock, so times before the swap stay positive
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        HikaeHook.FeeConfig memory config =
            HikaeHook.FeeConfig({baseFee: BASE_FEE, captureBps: CAPTURE_BPS, maxFee: MAX_FEE, maxAge: MAX_AGE});
        deployCodeTo(
            "HikaeRetroHook.sol:HikaeRetroHook",
            abi.encode(manager, callbackProxy, reactive, address(this), config, HOLD_BPS, WINDOW, uint32(0)),
            flags
        );
        hook = HikaeRetroHook(payable(flags));

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );

        router = new MsgSenderRouter(manager);
        hook.setTrustedRouter(address(router), true);
        MockERC20(Currency.unwrap(currency0)).transfer(alice, 100 ether);
        MockERC20(Currency.unwrap(currency1)).transfer(alice, 100 ether);
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        vm.prank(alice);
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            })
        );
    }

    /// @param originTimeMs when the price moved on the origin chain
    function _pushReference(int24 refTick, uint256 originTimeMs) internal {
        vm.prank(callbackProxy);
        hook.updateReference(reactive, key.toId(), refTick, 84532, 1, 1, originTimeMs);
    }

    function _claims(Currency currency) internal view returns (uint256) {
        return manager.balanceOf(address(hook), currency.toId());
    }

    function test_holdsShareOfOutputOnExactInput() public {
        uint256 before1 = currency1.balanceOf(alice);
        _swap(true, -AMOUNT);

        HikaeRetroHook.Hold memory h = hook.getHold(0);
        assertEq(h.owner, alice, "refund goes to the account behind the trusted router");
        assertFalse(h.currencyIs0, "exact input zeroForOne holds token1, the output");
        assertEq(h.preTick, 0);
        assertEq(h.feePaid, BASE_FEE);
        assertEq(h.amount, uint256(h.swapAmount) * HOLD_BPS / 10_000);
        assertEq(currency1.balanceOf(alice) - before1, h.swapAmount - h.amount);
        assertEq(_claims(currency1), h.amount, "held as ERC-6909 claims");
    }

    /// @dev The case HikaeHook (and similar oracle-fee hooks) cannot catch: the arbitrage swap lands before
    /// the reference does, so it pays only the base fee. The callback that brings the reference charges it.
    function test_arbitrageAheadOfCallbackPaysRetroactively() public {
        _swap(true, -AMOUNT);
        HikaeRetroHook.Hold memory h = hook.getHold(0);
        assertEq(h.feePaid, BASE_FEE, "the fast bot paid only the base fee");

        uint256 movedAt = uint256(h.time) * 1000 - 500; // Base moved 0.5 s before the swap
        vm.warp(block.timestamp + 3); // typical Reactive loop latency
        (, uint256 growthBefore) = manager.getFeeGrowthGlobals(key.toId());
        uint256 before1 = currency1.balanceOf(alice);
        _pushReference(-100, movedAt);

        // gap 100 ticks -> fee 7_200 pips; already paid 3_000
        uint256 expected = uint256(h.swapAmount) * (7200 - BASE_FEE) / 1_000_000;
        (, uint256 growthAfter) = manager.getFeeGrowthGlobals(key.toId());
        assertTrue(hook.getHold(0).settled, "settled by the callback itself");
        assertEq(currency1.balanceOf(alice) - before1, h.amount - expected, "rest of the hold refunded");
        assertGt(growthAfter, growthBefore, "surcharge donated to LPs");
        assertEq(_claims(currency1), 0);
    }

    function test_otherDirectionIsFullyRefunded() public {
        _swap(false, -AMOUNT);
        HikaeRetroHook.Hold memory h = hook.getHold(0);
        assertTrue(h.currencyIs0);

        vm.warp(block.timestamp + 3);
        uint256 before0 = currency0.balanceOf(alice);
        _pushReference(-100, uint256(h.time) * 1000 - 500);
        assertEq(currency0.balanceOf(alice) - before0, h.amount);
        assertEq(_claims(currency0), 0);
    }

    function test_noReferenceRefundsAfterWindow() public {
        _swap(true, -AMOUNT);
        HikaeRetroHook.Hold memory h = hook.getHold(0);

        vm.expectRevert(HikaeRetroHook.NotSettleable.selector);
        hook.settle(0);

        vm.warp(block.timestamp + WINDOW + 1);
        uint256 before1 = currency1.balanceOf(alice);
        hook.settle(0);
        assertEq(currency1.balanceOf(alice) - before1, h.amount);
    }

    function test_referenceAfterWindowDoesNotCharge() public {
        _swap(true, -AMOUNT);
        HikaeRetroHook.Hold memory h = hook.getHold(0);

        vm.warp(block.timestamp + WINDOW + 1);
        uint256 before1 = currency1.balanceOf(alice);
        _pushReference(-100, uint256(h.time) * 1000 - 500);
        assertEq(currency1.balanceOf(alice) - before1, h.amount);
    }

    function test_exactOutputHoldsInput() public {
        uint256 before0 = currency0.balanceOf(alice);
        uint256 before1 = currency1.balanceOf(alice);
        _swap(true, AMOUNT);

        HikaeRetroHook.Hold memory h = hook.getHold(0);
        assertTrue(h.currencyIs0, "exact output zeroForOne holds token0, the input");
        assertEq(currency1.balanceOf(alice) - before1, uint256(AMOUNT), "exact output is delivered");
        assertEq(before0 - currency0.balanceOf(alice), uint256(h.swapAmount) + h.amount, "hold paid on top");
        assertEq(_claims(currency0), h.amount);
    }

    function test_swapThatAlreadyPaidIsNotChargedTwice() public {
        _pushReference(-100, block.timestamp * 1000 - 3000);
        _swap(true, -AMOUNT);
        HikaeRetroHook.Hold memory h = hook.getHold(0);
        assertEq(h.feePaid, 7200, "fresh reference: dynamic fee charged up front");
        assertFalse(h.settled, "the earlier reference cannot decide a later swap");

        vm.warp(block.timestamp + 2);
        uint256 before1 = currency1.balanceOf(alice);
        _pushReference(-100, uint256(h.time) * 1000);
        assertTrue(hook.getHold(0).settled);
        assertEq(currency1.balanceOf(alice) - before1, h.amount, "nothing more to pay");
    }

    /// @dev The case that decides whether the idea is fair: a swap that happened before the price moved on Base
    /// traded at the right price at the time. Even if it went in the direction of the later move, it pays nothing.
    function test_swapBeforeOriginMoveIsFullyRefunded() public {
        _swap(true, -AMOUNT);
        HikaeRetroHook.Hold memory h = hook.getHold(0);

        uint256 movedAt = uint256(h.time) * 1000 + 400; // Base moved 0.4 s after the swap's block started
        vm.warp(block.timestamp + 3);
        uint256 before1 = currency1.balanceOf(alice);
        _pushReference(-100, movedAt);

        assertTrue(hook.getHold(0).settled);
        assertEq(currency1.balanceOf(alice) - before1, h.amount, "full refund");
    }

    function test_unknownOriginTimeIsRefunded() public {
        _swap(true, -AMOUNT);
        HikaeRetroHook.Hold memory h = hook.getHold(0);
        vm.warp(block.timestamp + 3);
        uint256 before1 = currency1.balanceOf(alice);
        _pushReference(-100, 0);
        assertEq(currency1.balanceOf(alice) - before1, h.amount);
    }

    function test_cannotSettleTwice() public {
        _swap(true, -AMOUNT);
        vm.warp(block.timestamp + WINDOW + 1);
        hook.settle(0);
        vm.expectRevert(HikaeRetroHook.AlreadySettled.selector);
        hook.settle(0);
    }

    /// @dev A callback settles at most MAX_AUTO_SETTLE holds; the next one picks up the rest.
    function test_callbackSettlesAtMostFourHolds() public {
        for (uint256 i; i < 6; i++) {
            _swap(true, -AMOUNT);
        }
        uint256 movedAt = block.timestamp * 1000 - 500;
        vm.warp(block.timestamp + 3);
        _pushReference(-100, movedAt);
        for (uint256 i; i < 6; i++) {
            assertEq(hook.getHold(i).settled, i < 4, "first four settled");
        }
        assertEq(hook.nextToSettle(), 4);

        vm.warp(block.timestamp + 1);
        _pushReference(-100, movedAt + 1000);
        assertTrue(hook.getHold(4).settled);
        assertTrue(hook.getHold(5).settled);
        assertEq(hook.nextToSettle(), 6);
        assertEq(_claims(currency1), 0);
    }

    function test_manualSettleAfterCallbackReverts() public {
        _swap(true, -AMOUNT);
        HikaeRetroHook.Hold memory h = hook.getHold(0);
        vm.warp(block.timestamp + 3);
        _pushReference(-100, uint256(h.time) * 1000 - 500);
        vm.expectRevert(HikaeRetroHook.AlreadySettled.selector);
        hook.settle(0);
    }

    function test_untrustedRouterOwnsItsRefund() public {
        swap(key, true, -AMOUNT, ZERO_BYTES);
        assertEq(hook.getHold(0).owner, address(swapRouter));
    }

    function test_onlyOwnerTrustsRouters() public {
        vm.prank(alice);
        vm.expectRevert(HikaeHook.NotOwner.selector);
        hook.setTrustedRouter(alice, true);
    }

    function test_onlyPoolManagerCallsUnlockCallback() public {
        vm.expectRevert(HikaeHook.NotPoolManager.selector);
        hook.unlockCallback("");
    }
}
