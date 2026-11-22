// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {HikaeReactive} from "../src/HikaeReactive.sol";
import {MockSystem} from "./mocks/MockSystem.sol";

contract HikaeReactiveTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    uint256 constant ORIGIN_CHAIN = 84532; // Base Sepolia
    uint256 constant DESTINATION_CHAIN = 1301; // Unichain Sepolia
    address constant ORIGIN_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    bytes32 constant ORIGIN_POOL_ID = keccak256("reference pool");
    bytes32 constant DESTINATION_POOL_ID = keccak256("protected pool");
    uint24 constant MIN_TICK_MOVE = 10;
    uint256 constant SWAP_TOPIC_0 = uint256(keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"));
    uint64 constant CALLBACK_GAS_LIMIT = 600_000;

    address hook = makeAddr("hook");
    HikaeReactive reactive;

    function setUp() public {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        reactive = new HikaeReactive(
            ORIGIN_CHAIN, ORIGIN_POOL_MANAGER, ORIGIN_POOL_ID, DESTINATION_CHAIN, MIN_TICK_MOVE
        );
        reactive.setDestination(hook, DESTINATION_POOL_ID, false);
    }

    function _swapLog(int24 tick, uint256 blockNumber) internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: ORIGIN_POOL_MANAGER,
            topic0: SWAP_TOPIC_0,
            topic1: uint256(ORIGIN_POOL_ID),
            topic2: uint256(uint160(address(0xA11CE))),
            topic3: 0,
            data: abi.encode(int128(-1e18), int128(2e18), uint160(79228162514264337593543950336), uint128(1e18), tick, uint24(3000)),
            blockNumber: blockNumber,
            opCode: 3,
            blockHash: 0,
            txHash: uint256(keccak256(abi.encode(blockNumber))),
            logIndex: 0
        });
    }

    function _expectedPayload(int24 tick, uint256 blockNumber) internal pure returns (bytes memory) {
        return _expectedPayload(tick, blockNumber, 0);
    }

    function _expectedPayload(int24 tick, uint256 blockNumber, uint256 originTimeMs)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSignature(
            "updateReference(address,bytes32,int24,uint256,uint256,uint256,uint256)",
            address(0),
            DESTINATION_POOL_ID,
            tick,
            ORIGIN_CHAIN,
            blockNumber,
            uint256(keccak256(abi.encode(blockNumber))),
            originTimeMs
        );
    }

    function test_subscribesToReferencePoolSwaps() public {
        vm.expectEmit(SYSTEM);
        emit MockSystem.Subscribed(
            ORIGIN_CHAIN,
            ORIGIN_POOL_MANAGER,
            SWAP_TOPIC_0,
            uint256(ORIGIN_POOL_ID),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        new HikaeReactive(
            ORIGIN_CHAIN, ORIGIN_POOL_MANAGER, ORIGIN_POOL_ID, DESTINATION_CHAIN, MIN_TICK_MOVE
        );
    }

    function test_firstSwapPushesReference() public {
        IReactive.LogRecord memory log_ = _swapLog(-120, 100);
        vm.expectEmit(SYSTEM);
        emit MockSystem.CallbackRequested(DESTINATION_CHAIN, hook, CALLBACK_GAS_LIMIT, _expectedPayload(-120, 100));
        vm.prank(SYSTEM);
        reactive.react(log_);

        assertEq(reactive.lastPushedTick(), -120);
        assertEq(reactive.pushCount(), 1);
    }

    function test_smallMoveIsDebounced() public {
        vm.startPrank(SYSTEM);
        reactive.react(_swapLog(-120, 100));

        vm.recordLogs();
        reactive.react(_swapLog(-125, 101)); // moved 5 < 10
        assertEq(vm.getRecordedLogs().length, 0, "no callback for a small move");
        assertEq(reactive.pushCount(), 1);

        reactive.react(_swapLog(-131, 102)); // moved 11 >= 10
        vm.stopPrank();
        assertEq(reactive.pushCount(), 2);
        assertEq(reactive.lastPushedTick(), -131);
    }

    function test_ignoresOtherPoolsAndChains() public {
        IReactive.LogRecord memory wrongPool = _swapLog(-500, 100);
        wrongPool.topic1 = uint256(keccak256("other pool"));
        IReactive.LogRecord memory wrongChain = _swapLog(-500, 100);
        wrongChain.chainId = 1;

        vm.startPrank(SYSTEM);
        reactive.react(wrongPool);
        reactive.react(wrongChain);
        vm.stopPrank();

        assertEq(reactive.pushCount(), 0);
    }

    function test_noCallbackBeforeHookIsSet() public {
        HikaeReactive fresh = new HikaeReactive(
            ORIGIN_CHAIN, ORIGIN_POOL_MANAGER, ORIGIN_POOL_ID, DESTINATION_CHAIN, MIN_TICK_MOVE
        );
        IReactive.LogRecord memory log_ = _swapLog(-120, 100);
        vm.prank(SYSTEM);
        fresh.react(log_);
        assertEq(fresh.pushCount(), 0);
    }

    function test_onlySystemCanReact() public {
        IReactive.LogRecord memory log_ = _swapLog(-120, 100);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM));
        reactive.react(log_);
    }

    function test_onlyOwnerSetsDestination() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(HikaeReactive.NotOwner.selector);
        reactive.setDestination(address(1), DESTINATION_POOL_ID, false);
    }

    /// @dev Base Sepolia makes a block every 200 ms on a fixed schedule, so the block number gives its time.
    function test_originClockTimesTheOriginBlock() public {
        assertEq(reactive.originTimeMs(1234), 0, "unset clock means unknown");

        reactive.setOriginClock(1000, 1_795_353_716_000, 200);
        assertEq(reactive.originTimeMs(1005), 1_795_353_717_000);
        assertEq(reactive.originTimeMs(995), 1_795_353_715_000);

        IReactive.LogRecord memory log_ = _swapLog(-120, 1005);
        vm.expectEmit(SYSTEM);
        emit MockSystem.CallbackRequested(
            DESTINATION_CHAIN, hook, CALLBACK_GAS_LIMIT, _expectedPayload(-120, 1005, 1_795_353_717_000)
        );
        vm.prank(SYSTEM);
        reactive.react(log_);
    }

    function test_onlyOwnerSetsOriginClock() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(HikaeReactive.NotOwner.selector);
        reactive.setOriginClock(1, 1, 200);
    }

    /// @dev Destination pool lists the pair the other way round: the same price is the opposite tick there.
    function test_invertedPairPushesOppositeTick() public {
        reactive.setDestination(hook, DESTINATION_POOL_ID, true);
        IReactive.LogRecord memory log_ = _swapLog(-120, 100);
        vm.expectEmit(SYSTEM);
        emit MockSystem.CallbackRequested(DESTINATION_CHAIN, hook, CALLBACK_GAS_LIMIT, _expectedPayload(120, 100));
        vm.prank(SYSTEM);
        reactive.react(log_);

        // Debounce keeps working on the origin tick.
        assertEq(reactive.lastPushedTick(), -120);
        assertTrue(reactive.invertTick());
    }
}
