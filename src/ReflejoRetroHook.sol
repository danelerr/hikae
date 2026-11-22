// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";
import {ReflejoHook} from "./ReflejoHook.sol";

/// @title ReflejoRetroHook
/// @notice ReflejoHook only charges arbitrage once the reference price has arrived. A bot that sees the move on
/// the origin chain and trades here before the Reactive callback lands pays the base fee. This extension holds
/// back a small share of every swap's unspecified amount (the output on exact-input swaps, the input on
/// exact-output swaps) for a short window. If the next reference lands inside the window, a swap that traded
/// toward it pays, out of what was held, the surcharge it skipped: that part is donated to in-range LPs and the
/// rest is refunded. With no reference in the window, or a swap in the other direction, all of it is refunded.
/// @dev Spike for the Reactive Omni buildathon, not audited. Holds are kept as ERC-6909 claims on the
/// PoolManager and settled one by one through `settle`, so no callback ever loops over holds.
contract ReflejoRetroHook is ReflejoHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    struct Hold {
        address owner; // receives the refund
        uint40 time; // when the swap happened
        bool zeroForOne;
        bool currencyIs0; // held currency is token0
        bool settled;
        int24 preTick; // pool tick before the swap
        uint24 feePaid; // LP fee the swap paid in beforeSwap
        uint64 refSeq; // references received by the pool before this swap
        PoolId poolId;
        uint128 swapAmount; // absolute unspecified amount of the swap, before the hold
        uint128 amount; // held amount
    }

    struct RefPoint {
        int24 tick;
        uint40 time; // when the callback landed here
        uint64 originTimeMs; // when the price moved on the origin chain (0 if unknown)
    }

    /// @dev References kept per pool. A hold whose first reference was overwritten is refunded in full.
    uint256 internal constant RING_SIZE = 64;
    uint256 internal constant MAX_HOLD_BPS = 1000;

    // Transient slots that carry beforeSwap context into afterSwap.
    bytes32 internal constant PRE_TICK_SLOT = keccak256("reflejo.retro.preTick");
    bytes32 internal constant FEE_PAID_SLOT = keccak256("reflejo.retro.feePaid");

    /// @notice Share of the unspecified amount held back, in bps. Must cover maxFee - baseFee to be fully effective.
    uint16 public immutable holdBps;
    /// @notice Seconds after a swap during which a new reference can still charge it.
    uint32 public immutable window;
    /// @notice Margin for clock differences between the origin chain and this one. A swap is only charged if the
    /// origin move happened at least this long before the start of the swap's block.
    uint32 public immutable originSkewMs;

    mapping(address router => bool) public trustedRouter;
    mapping(PoolId => PoolKey) internal poolKeys;
    mapping(PoolId => uint64) public refCount;
    mapping(PoolId => RefPoint[RING_SIZE]) internal refRing;
    Hold[] internal holds;

    event Held(uint256 indexed holdId, PoolId indexed poolId, address indexed owner, bool currencyIs0, uint256 amount);
    event Settled(uint256 indexed holdId, uint256 toLPs, uint256 refund);
    event TrustedRouterSet(address indexed router, bool trusted);

    error InvalidHoldConfig();
    error AlreadySettled();
    error NotSettleable();

    constructor(
        IPoolManager poolManager_,
        address callbackProxy_,
        address reactive_,
        address owner_,
        FeeConfig memory config_,
        uint16 holdBps_,
        uint32 window_,
        uint32 originSkewMs_
    ) ReflejoHook(poolManager_, callbackProxy_, reactive_, owner_, config_) {
        if (holdBps_ == 0 || holdBps_ > MAX_HOLD_BPS || window_ == 0) revert InvalidHoldConfig();
        holdBps = holdBps_;
        window = window_;
        originSkewMs = originSkewMs_;
    }

    function _permissions() internal pure override returns (Hooks.Permissions memory p) {
        p = super._permissions();
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    /// @notice Routers that implement IMsgSender, so refunds go to the person behind them and not the router.
    function setTrustedRouter(address router, bool trusted) external onlyOwner {
        trustedRouter[router] = trusted;
        emit TrustedRouterSet(router, trusted);
    }

    // ---------------------------------------------------------------------
    // Extension points
    // ---------------------------------------------------------------------

    function _onInitialize(PoolKey calldata key) internal override {
        poolKeys[key.toId()] = key;
    }

    function _onReference(PoolId poolId, int24 refTick, uint256 originTimeMs) internal override {
        uint64 seq = refCount[poolId];
        // casting to 'uint64' is safe for any millisecond timestamp before year 584 million
        // forge-lint: disable-next-line(unsafe-typecast)
        refRing[poolId][seq % RING_SIZE] =
            RefPoint({tick: refTick, time: uint40(block.timestamp), originTimeMs: uint64(originTimeMs)});
        refCount[poolId] = seq + 1;
    }

    function _onBeforeSwap(PoolKey calldata key, SwapParams calldata, uint24 fee) internal override {
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        bytes32 tickSlot = PRE_TICK_SLOT;
        bytes32 feeSlot = FEE_PAID_SLOT;
        assembly ("memory-safe") {
            tstore(tickSlot, tick)
            tstore(feeSlot, fee)
        }
    }

    // ---------------------------------------------------------------------
    // Hold
    // ---------------------------------------------------------------------

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        uint256 amount = _hold(sender, key, params, delta);
        return (IHooks.afterSwap.selector, amount.toInt128());
    }

    /// @dev Mints the held share as claims to this hook and records who gets it back.
    function _hold(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        internal
        returns (uint256 amount)
    {
        // Same convention as v4-core's FeeTakingHook: the hook delta is in the unspecified currency.
        bool currencyIs0 = !(params.amountSpecified < 0 == params.zeroForOne);
        int128 unspecified = currencyIs0 ? delta.amount0() : delta.amount1();
        if (unspecified < 0) unspecified = -unspecified;
        // casting to 'uint128' is safe because unspecified is non-negative here
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 swapAmount = uint128(unspecified);
        amount = (uint256(swapAmount) * holdBps) / 10_000;
        if (amount == 0) return 0;

        poolManager.mint(address(this), (currencyIs0 ? key.currency0 : key.currency1).toId(), amount);

        PoolId poolId = key.toId();
        uint256 holdId = holds.length;
        Hold storage h = holds.push();
        h.owner = _refundOwner(sender);
        h.time = uint40(block.timestamp);
        h.zeroForOne = params.zeroForOne;
        h.currencyIs0 = currencyIs0;
        (h.preTick, h.feePaid) = _loadSwapContext();
        h.refSeq = refCount[poolId];
        h.poolId = poolId;
        h.swapAmount = swapAmount;
        // casting to 'uint128' is safe because amount <= swapAmount (a uint128)
        // forge-lint: disable-next-line(unsafe-typecast)
        h.amount = uint128(amount);
        emit Held(holdId, poolId, h.owner, currencyIs0, amount);
    }

    function _loadSwapContext() internal view returns (int24 preTick, uint24 feePaid) {
        bytes32 tickSlot = PRE_TICK_SLOT;
        bytes32 feeSlot = FEE_PAID_SLOT;
        assembly ("memory-safe") {
            preTick := tload(tickSlot)
            feePaid := tload(feeSlot)
        }
    }

    function _refundOwner(address sender) internal view returns (address) {
        if (trustedRouter[sender]) {
            try IMsgSender(sender).msgSender() returns (address original) {
                if (original != address(0)) return original;
            } catch {}
        }
        return sender;
    }

    // ---------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------

    /// @notice Anyone can settle a hold once its outcome is known: the first reference after the swap has
    /// landed, or the window has passed without one.
    function settle(uint256 holdId) external {
        Hold storage h = holds[holdId];
        if (h.settled) revert AlreadySettled();
        (bool ready, uint256 toLPs) = _assess(h);
        if (!ready) revert NotSettleable();
        // donate reverts without in-range liquidity: refund everything instead of locking the hold.
        if (toLPs > 0 && poolManager.getLiquidity(h.poolId) == 0) toLPs = 0;

        h.settled = true;
        uint256 refund = h.amount - toLPs;
        poolManager.unlock(abi.encode(holdId, toLPs, refund));
        emit Settled(holdId, toLPs, refund);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 holdId, uint256 toLPs, uint256 refund) = abi.decode(data, (uint256, uint256, uint256));
        Hold memory h = holds[holdId];
        PoolKey memory key = poolKeys[h.poolId];
        Currency currency = h.currencyIs0 ? key.currency0 : key.currency1;

        // Credit from burning the claims pays for the donation and the refund: the deltas net to zero.
        poolManager.burn(address(this), currency.toId(), h.amount);
        if (toLPs > 0) {
            if (h.currencyIs0) poolManager.donate(key, toLPs, 0, "");
            else poolManager.donate(key, 0, toLPs, "");
        }
        if (refund > 0) poolManager.take(currency, h.owner, refund);
        return "";
    }

    /// @notice Outcome of a hold: whether it can be settled now and how much would go to LPs.
    function previewSettle(uint256 holdId) external view returns (bool ready, uint256 toLPs) {
        Hold memory h = holds[holdId];
        if (h.settled) return (false, 0);
        return _assess(h);
    }

    function getHold(uint256 holdId) external view returns (Hold memory) {
        return holds[holdId];
    }

    function holdCount() external view returns (uint256) {
        return holds.length;
    }

    function _assess(Hold memory h) internal view returns (bool ready, uint256 toLPs) {
        uint64 count = refCount[h.poolId];
        if (count > h.refSeq) {
            // The first reference after the swap was overwritten: no reliable outcome, refund.
            if (count - h.refSeq > RING_SIZE) return (true, 0);
            RefPoint memory r = refRing[h.poolId][h.refSeq % RING_SIZE];
            // It landed after the window closed: the swap is not charged.
            if (uint256(r.time) > uint256(h.time) + window) return (true, 0);
            // The swap only traded against a stale price if the origin price had already moved when the swap's
            // block started. Otherwise it came first (or the time is unknown) and must not pay. References arrive
            // in origin order, so no later one can show an earlier move.
            if (r.originTimeMs == 0 || uint256(r.originTimeMs) + originSkewMs > uint256(h.time) * 1000) {
                return (true, 0);
            }
            return (true, _surcharge(h, r.tick));
        }
        // No reference yet: wait until the window closes, then refund.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > uint256(h.time) + window) return (true, 0);
        return (false, 0);
    }

    /// @dev The fee the swap would have paid had the reference already been here, minus what it paid, on the
    /// swap's unspecified amount. Capped at the held amount.
    function _surcharge(Hold memory h, int24 refTick) internal view returns (uint256) {
        bool toxic = h.zeroForOne ? refTick < h.preTick : refTick > h.preTick;
        if (!toxic) return 0;
        uint24 fee = _feeForGap(feeConfig, _absDiff(h.preTick, refTick));
        if (fee <= h.feePaid) return 0;
        uint256 s = (uint256(h.swapAmount) * (fee - h.feePaid)) / 1_000_000;
        return s > h.amount ? h.amount : s;
    }
}
