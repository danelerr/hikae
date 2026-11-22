// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ReflejoHook} from "../src/ReflejoHook.sol";

contract ReflejoHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    bytes32 constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    uint24 constant BASE_FEE = 3000; // 0.30%
    uint16 constant CAPTURE_BPS = 6000; // LPs keep 60% of the gap above the base fee
    uint24 constant MAX_FEE = 30000; // 3%
    uint32 constant MAX_AGE = 120;

    address callbackProxy = makeAddr("callbackProxy");
    address reactive = makeAddr("reactive");
    ReflejoHook hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address flags = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (0x4444 << 144));
        ReflejoHook.FeeConfig memory config =
            ReflejoHook.FeeConfig({baseFee: BASE_FEE, captureBps: CAPTURE_BPS, maxFee: MAX_FEE, maxAge: MAX_AGE});
        deployCodeTo(
            "ReflejoHook.sol:ReflejoHook", abi.encode(manager, callbackProxy, reactive, address(this), config), flags
        );
        hook = ReflejoHook(payable(flags));

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
    }

    function _pushReference(int24 refTick) internal {
        vm.prank(callbackProxy);
        hook.updateReference(reactive, key.toId(), refTick, 84532, 1234, 0xabc, block.timestamp * 1000);
    }

    /// @dev Swaps a small exact-input amount and returns the LP fee the PoolManager applied.
    function _swapAndReadFee(bool zeroForOne) internal returns (uint24) {
        vm.recordLogs();
        swap(key, zeroForOne, -1e15, ZERO_BYTES);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("Swap event not found");
    }

    function test_rejectsStaticFeePools() public {
        vm.expectRevert();
        initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
    }

    function test_baseFeeWithoutReference() public {
        assertEq(_swapAndReadFee(true), BASE_FEE);
        assertEq(_swapAndReadFee(false), BASE_FEE);
    }

    function test_toxicDirectionPaysMore() public {
        // Reference price is 100 ticks below: selling token0 here closes the gap, so it is the arb leg.
        _pushReference(-100);

        (uint24 quoted, bool toxic, uint256 gap) = hook.quoteFee(key, true);
        assertTrue(toxic);
        assertEq(gap, 100);
        // gap 100 ticks = 10_000 pips -> 3_000 + 60% of 7_000 = 7_200
        assertEq(quoted, 7200);
        assertEq(_swapAndReadFee(true), 7200);
    }

    function test_otherDirectionPaysBaseFee() public {
        _pushReference(-100);
        (uint24 quoted, bool toxic,) = hook.quoteFee(key, false);
        assertFalse(toxic);
        assertEq(quoted, BASE_FEE);
        assertEq(_swapAndReadFee(false), BASE_FEE);
    }

    function test_feeIsCapped() public {
        _pushReference(-5000);
        assertEq(_swapAndReadFee(true), MAX_FEE);
    }

    function test_staleReferenceFallsBackToBaseFee() public {
        _pushReference(-100);
        vm.warp(block.timestamp + MAX_AGE + 1);
        assertEq(_swapAndReadFee(true), BASE_FEE);
    }

    function test_updateReferenceRequiresProxy() public {
        PoolId id = key.toId();
        vm.expectRevert(abi.encodeWithSelector(ReflejoHook.NotCallbackProxy.selector, address(this)));
        hook.updateReference(reactive, id, -100, 84532, 1, 1, 0);
    }

    function test_updateReferenceRequiresReactiveSender() public {
        PoolId id = key.toId();
        address impostor = makeAddr("impostor");
        vm.prank(callbackProxy);
        vm.expectRevert(abi.encodeWithSelector(ReflejoHook.NotReactive.selector, impostor));
        hook.updateReference(impostor, id, -100, 84532, 1, 1, 0);
    }

    function test_updateReferenceStoresTickAndTime() public {
        _pushReference(-42);
        (int24 tick, uint40 updatedAt) = hook.references(key.toId());
        assertEq(tick, -42);
        assertEq(updatedAt, block.timestamp);
    }

    function test_onlyProxyCanPull() public {
        vm.deal(address(hook), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ReflejoHook.NotCallbackProxy.selector, address(this)));
        hook.pay(0.1 ether);

        vm.prank(callbackProxy);
        hook.pay(0.1 ether);
        assertEq(callbackProxy.balance, 0.1 ether);
    }

    function test_invalidFeeConfigReverts() public {
        vm.expectRevert(ReflejoHook.InvalidFeeConfig.selector);
        hook.setFeeConfig(ReflejoHook.FeeConfig({baseFee: 5000, captureBps: 1, maxFee: 4000, maxAge: 60}));
    }

    function test_onlyOwnerSetsFeeConfig() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ReflejoHook.NotOwner.selector);
        hook.setFeeConfig(ReflejoHook.FeeConfig({baseFee: 1000, captureBps: 1, maxFee: 4000, maxAge: 60}));
    }

    function test_maxFeeAboveCeilingReverts() public {
        uint24 ceiling = hook.MAX_FEE_CEILING();
        vm.expectRevert(ReflejoHook.InvalidFeeConfig.selector);
        hook.setFeeConfig(ReflejoHook.FeeConfig({baseFee: 3000, captureBps: 6000, maxFee: ceiling + 1, maxAge: 60}));

        hook.setFeeConfig(ReflejoHook.FeeConfig({baseFee: 3000, captureBps: 6000, maxFee: ceiling, maxAge: 60}));
        (,, uint24 maxFee,) = hook.feeConfig();
        assertEq(maxFee, ceiling);
    }

    function test_smallGapPaysOnlyBaseFee() public {
        // 20 ticks = 0.20%, below the 0.30% base fee: arbitrage is unprofitable anyway, no surcharge.
        _pushReference(-20);
        (uint24 quoted, bool toxic,) = hook.quoteFee(key, true);
        assertTrue(toxic);
        assertEq(quoted, BASE_FEE);
    }

    function test_captureOfFullGapIsRejected() public {
        vm.expectRevert(ReflejoHook.InvalidFeeConfig.selector);
        hook.setFeeConfig(ReflejoHook.FeeConfig({baseFee: 3000, captureBps: 10_000, maxFee: 30000, maxAge: 60}));
    }

    /// @dev The fee on the arbitrage leg must stay below the price gap it closes, so closing it is still
    /// profitable while the reference is fresh. Otherwise arbitrageurs wait for the reference to expire.
    function testFuzz_arbitrageStaysProfitableWhileFresh(uint24 gapTicks) public {
        gapTicks = uint24(bound(gapTicks, 31, 2000));
        // casting to 'int24' is safe because gapTicks is bounded to 2000 above
        // forge-lint: disable-next-line(unsafe-typecast)
        _pushReference(-int24(gapTicks));
        (uint24 quoted, bool toxic, uint256 gap) = hook.quoteFee(key, true);
        assertTrue(toxic);
        assertEq(gap, gapTicks);
        assertLt(uint256(quoted), uint256(gapTicks) * 100);
        assertGt(quoted, BASE_FEE);
    }
}
