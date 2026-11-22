// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";

/// @title HikaeReactive
/// @notice Lives on Reactive Network. Listens to Uniswap v4 `Swap` events of a reference pool on the
/// origin chain and relays the new tick to HikaeHook on the destination chain. It only sends a
/// callback when the tick moved at least `minTickMove` since the last push, so it does not pay for a
/// callback on every swap.
contract HikaeReactive is AbstractReactive {
    /// @dev keccak256 of the Uniswap v4 PoolManager `Swap` event. PoolId is encoded as bytes32.
    uint256 public constant SWAP_TOPIC_0 =
        uint256(keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"));

    /// @dev Callbacks below 100k gas are ignored by the network. updateReference uses well under this.
    uint64 public constant CALLBACK_GAS_LIMIT = 250_000;

    uint256 public immutable originChainId;
    address public immutable originPoolManager;
    bytes32 public immutable originPoolId;
    uint256 public immutable destinationChainId;

    address public owner;
    /// @dev The hook and its pool are set after deployment: the pool id depends on the hook address, and the
    /// hook needs this contract's address, so neither can be a constructor argument here.
    address public hook;
    bytes32 public destinationPoolId;
    /// @dev True when the destination pool lists the pair in the opposite order (token0 and token1 swapped).
    /// Then the same price is the opposite tick there.
    bool public invertTick;
    uint24 public minTickMove;

    /// @dev Origin block time = anchorTimeMs + (block - anchorBlock) * blockTimeMs. OP Stack chains such as Base
    /// produce blocks on a fixed schedule, so this is exact while the block time does not change. The log record
    /// carries the origin block number but not its timestamp. Unset (blockTimeMs == 0) means unknown, sent as 0.
    uint64 public originAnchorBlock;
    uint64 public originAnchorTimeMs;
    uint32 public originBlockTimeMs;

    int24 public lastPushedTick;
    bool public hasPushed;
    uint256 public pushCount;

    event DestinationSet(address indexed hook, bytes32 indexed poolId, bool invertTick);
    event MinTickMoveSet(uint24 minTickMove);
    event OriginClockSet(uint64 anchorBlock, uint64 anchorTimeMs, uint32 blockTimeMs);
    event ReferencePushed(int24 tick, uint256 originBlock, uint256 originTxHash);

    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        uint256 originChainId_,
        address originPoolManager_,
        bytes32 originPoolId_,
        uint256 destinationChainId_,
        uint24 minTickMove_
    ) payable {
        originChainId = originChainId_;
        originPoolManager = originPoolManager_;
        originPoolId = originPoolId_;
        destinationChainId = destinationChainId_;
        minTickMove = minTickMove_;
        owner = msg.sender;

        // Only Swap events of the reference pool: topic1 is the indexed PoolId.
        SYSTEM.subscribe(
            originChainId_, originPoolManager_, SWAP_TOPIC_0, uint256(originPoolId_), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        // Anything that does not match passes through without reverting: reverts are charged.
        if (
            log_.chainId != originChainId || log_.contractAddress != originPoolManager
                || log_.topic0 != SWAP_TOPIC_0 || log_.topic1 != uint256(originPoolId)
        ) return;

        address target = hook;
        if (target == address(0)) return;

        (,,,, int24 tick,) = abi.decode(log_.data, (int128, int128, uint160, uint128, int24, uint24));
        if (hasPushed && _absDiff(tick, lastPushedTick) < minTickMove) return;

        lastPushedTick = tick;
        hasPushed = true;
        unchecked {
            ++pushCount;
        }
        // Valid ticks are within +-887272, so negating cannot overflow int24.
        int24 refTick = invertTick ? -tick : tick;

        bytes memory payload = abi.encodeWithSignature(
            "updateReference(address,bytes32,int24,uint256,uint256,uint256,uint256)",
            address(0), // replaced by the callback proxy with this contract's address
            destinationPoolId,
            refTick,
            log_.chainId,
            log_.blockNumber,
            log_.txHash,
            originTimeMs(log_.blockNumber)
        );

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: target,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );

        emit ReferencePushed(refTick, log_.blockNumber, log_.txHash);
    }

    function setDestination(address hook_, bytes32 poolId_, bool invertTick_) external onlyOwner {
        hook = hook_;
        destinationPoolId = poolId_;
        invertTick = invertTick_;
        emit DestinationSet(hook_, poolId_, invertTick_);
    }

    function setOriginClock(uint64 anchorBlock, uint64 anchorTimeMs, uint32 blockTimeMs) external onlyOwner {
        originAnchorBlock = anchorBlock;
        originAnchorTimeMs = anchorTimeMs;
        originBlockTimeMs = blockTimeMs;
        emit OriginClockSet(anchorBlock, anchorTimeMs, blockTimeMs);
    }

    /// @notice When an origin block was produced, in ms since the epoch. 0 if the clock is not set.
    function originTimeMs(uint256 blockNumber) public view returns (uint256) {
        uint256 step = originBlockTimeMs;
        if (step == 0) return 0;
        uint256 anchor = originAnchorBlock;
        if (blockNumber >= anchor) return originAnchorTimeMs + (blockNumber - anchor) * step;
        uint256 back = (anchor - blockNumber) * step;
        return back > originAnchorTimeMs ? 0 : originAnchorTimeMs - back;
    }

    function setMinTickMove(uint24 minTickMove_) external onlyOwner {
        minTickMove = minTickMove_;
        emit MinTickMoveSet(minTickMove_);
    }

    /// @notice Settles debt with the system contract. Any debt stops `react()` from being called.
    function coverDebt() external {
        _coverDebt();
    }

    function withdraw(address payable to, uint256 amount) external onlyOwner {
        _pay(to, amount);
    }

    function _absDiff(int24 a, int24 b) internal pure returns (uint256) {
        int256 d = int256(a) - int256(b);
        return uint256(d >= 0 ? d : -d);
    }
}
