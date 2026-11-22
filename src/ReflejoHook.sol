// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @dev Minimal view of the Reactive Network callback proxy used to settle callback costs.
interface ICallbackProxy {
    function debt(address contract_) external view returns (uint256);
}

/// @title ReflejoHook
/// @notice Dynamic-fee hook that charges more only to swaps that trade against a stale price.
/// A Reactive Network contract watches a reference pool on another chain and pushes its tick here
/// through a callback. Swaps that move this pool toward the reference price (the arbitrage leg that
/// extracts value from LPs) pay a fee that grows with the price gap. Swaps in the other direction pay
/// the base fee.
contract ReflejoHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Reference {
        int24 tick;
        uint40 updatedAt;
    }

    struct FeeConfig {
        uint24 baseFee; // fee in pips (1e6 = 100%) for normal flow
        uint16 captureBps; // share of the gap above baseFee kept for LPs, in bps (must be < 10_000)
        uint24 maxFee; // cap in pips
        uint32 maxAge; // seconds after which a reference is ignored
    }

    /// @dev Hard ceiling for maxFee (10%), so the owner cannot turn the pool into a trap for swappers.
    uint24 public constant MAX_FEE_CEILING = 100_000;

    IPoolManager public immutable poolManager;
    address public immutable callbackProxy;
    address public immutable reactive;

    address public owner;
    FeeConfig public feeConfig;
    mapping(PoolId => Reference) public references;

    event ReferenceUpdated(
        PoolId indexed poolId,
        int24 tick,
        uint256 originChainId,
        uint256 originBlock,
        uint256 originTxHash,
        uint256 originTimeMs
    );
    event ToxicFlowCharged(PoolId indexed poolId, uint256 gapTicks, uint24 fee);
    event FeeConfigUpdated(FeeConfig config);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotPoolManager();
    error NotCallbackProxy(address caller);
    error NotReactive(address sender);
    error NotOwner();
    error MustUseDynamicFee();
    error InvalidFeeConfig();
    error HookNotImplemented();
    error TransferFailed();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        IPoolManager poolManager_,
        address callbackProxy_,
        address reactive_,
        address owner_,
        FeeConfig memory config_
    ) payable {
        poolManager = poolManager_;
        callbackProxy = callbackProxy_;
        reactive = reactive_;
        owner = owner_;
        _setFeeConfig(config_);

        Hooks.validateHookPermissions(IHooks(address(this)), _permissions());
    }

    /// @dev Hook flags this contract's address must carry. Extensions that add entry points override it.
    function _permissions() internal pure virtual returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // Reactive Network callback
    // ---------------------------------------------------------------------

    /// @notice Called by the Reactive callback proxy. The proxy overwrites `sender` with the address of
    /// the reactive contract that requested the callback, so it can be authenticated here.
    function updateReference(
        address sender,
        PoolId poolId,
        int24 refTick,
        uint256 originChainId,
        uint256 originBlock,
        uint256 originTxHash,
        uint256 originTimeMs
    ) external {
        if (msg.sender != callbackProxy) revert NotCallbackProxy(msg.sender);
        if (sender != reactive) revert NotReactive(sender);

        references[poolId] = Reference({tick: refTick, updatedAt: uint40(block.timestamp)});
        _onReference(poolId, refTick, originTimeMs);
        emit ReferenceUpdated(poolId, refTick, originChainId, originBlock, originTxHash, originTimeMs);
    }

    /// @dev Extension point: runs after a new reference is stored. `originTimeMs` is when the price moved on the
    /// origin chain, as computed by the reactive contract from the origin block number (0 if unknown).
    function _onReference(PoolId poolId, int24 refTick, uint256 originTimeMs) internal virtual {}

    // ---------------------------------------------------------------------
    // Fee logic
    // ---------------------------------------------------------------------

    /// @notice Fee a swap would pay right now, and whether it counts as toxic flow.
    function quoteFee(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint24 fee, bool toxic, uint256 gapTicks)
    {
        return _quote(key, zeroForOne);
    }

    function _quote(PoolKey calldata key, bool zeroForOne)
        internal
        view
        returns (uint24 fee, bool toxic, uint256 gapTicks)
    {
        FeeConfig memory config = feeConfig;
        PoolId poolId = key.toId();
        Reference memory ref = references[poolId];

        // Staleness check on purpose: a reference older than maxAge is ignored.
        // forge-lint: disable-next-line(block-timestamp)
        if (ref.updatedAt == 0 || block.timestamp > uint256(ref.updatedAt) + config.maxAge) {
            return (config.baseFee, false, 0);
        }

        (, int24 tick,,) = poolManager.getSlot0(poolId);

        // zeroForOne pushes the tick down. If the reference is below, the swap closes the gap: that is
        // the arbitrage leg against LPs. The same logic mirrored applies for oneForZero.
        toxic = zeroForOne ? ref.tick < tick : ref.tick > tick;
        if (!toxic) return (config.baseFee, false, 0);

        gapTicks = _absDiff(tick, ref.tick);
        fee = _feeForGap(config, gapTicks);
    }

    /// @dev One tick moves the price by ~1 bp (= 100 pips). The surcharge takes a share of the gap above the
    /// base fee, so closing the gap stays profitable for the arbitrageur and part of it goes to LPs.
    /// Charging the full gap or more would just make arbitrageurs wait until the reference expires.
    function _feeForGap(FeeConfig memory config, uint256 gapTicks) internal pure returns (uint24) {
        uint256 gapPips = gapTicks * 100;
        if (gapPips <= config.baseFee) return config.baseFee;
        uint256 raw = uint256(config.baseFee) + ((gapPips - config.baseFee) * config.captureBps) / 10_000;
        // casting to 'uint24' is safe because raw <= maxFee (a uint24) in this branch
        // forge-lint: disable-next-line(unsafe-typecast)
        return raw > config.maxFee ? config.maxFee : uint24(raw);
    }

    // ---------------------------------------------------------------------
    // Hook entry points
    // ---------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert MustUseDynamicFee();
        _onInitialize(key);
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Extension point: runs when a pool using this hook is created.
    function _onInitialize(PoolKey calldata key) internal virtual {}

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint24 fee, bool toxic, uint256 gapTicks) = _quote(key, params.zeroForOne);
        if (toxic) emit ToxicFlowCharged(key.toId(), gapTicks, fee);
        _onBeforeSwap(key, params, fee);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Extension point: runs in beforeSwap with the LP fee this swap will pay.
    function _onBeforeSwap(PoolKey calldata key, SwapParams calldata params, uint24 fee) internal virtual {}

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @dev Not enabled in this contract's flags; extensions may override it.
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ---------------------------------------------------------------------
    // Callback payments (same contract surface as Reactive's AbstractPayer)
    // ---------------------------------------------------------------------

    /// @notice The callback proxy pulls the cost of delivered callbacks from here.
    function pay(uint256 amount) external {
        if (msg.sender != callbackProxy) revert NotCallbackProxy(msg.sender);
        _send(payable(callbackProxy), amount);
    }

    /// @notice Settles any outstanding debt with the callback proxy. Debt blocks further callbacks.
    function coverDebt() external {
        _send(payable(callbackProxy), ICallbackProxy(callbackProxy).debt(address(this)));
    }

    receive() external payable {}

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setFeeConfig(FeeConfig calldata config_) external onlyOwner {
        _setFeeConfig(config_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function withdraw(address payable to, uint256 amount) external onlyOwner {
        _send(to, amount);
    }

    function _setFeeConfig(FeeConfig memory config_) internal {
        if (
            config_.baseFee > config_.maxFee || config_.maxFee > MAX_FEE_CEILING || config_.maxAge == 0
                || config_.captureBps >= 10_000
        ) revert InvalidFeeConfig();
        feeConfig = config_;
        emit FeeConfigUpdated(config_);
    }

    function _send(address payable to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _absDiff(int24 a, int24 b) internal pure returns (uint256) {
        int256 d = int256(a) - int256(b);
        return uint256(d >= 0 ? d : -d);
    }
}
