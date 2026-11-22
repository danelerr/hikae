# Reflejo

A Uniswap v4 hook on Unichain that charges a higher fee only to the swaps that arbitrage a stale price.
The reference price comes from a pool on Base, relayed by a Reactive Network contract in about a second.

Built for the Reactive Omni Buildathon, track **Every Second Counts**.

## Why

When the price moves on one chain, the same pool on another chain keeps the old price for a while. The first
trader to close that gap takes value from the LPs (loss-versus-rebalancing). The faster the pool learns about the
move, the less the LPs lose. Reflejo uses Reactive to learn about it fast, and the hook charges the trade that
closes the gap a fee that grows with its size. Swaps in the other direction keep paying the base fee.

## How it works

```
Base Sepolia                    Reactive Lasna                    Unichain Sepolia
reference pool ── Swap event ──▶ ReflejoReactive ── callback ───▶ ReflejoHook
(PoolManager)                    subscribes to the pool's         stores the reference tick
                                 Swap events, debounces small     and prices each swap in
                                 moves, requests a callback       beforeSwap
```

- `src/ReflejoReactive.sol` (Reactive Lasna): subscribes to `Swap` events of one PoolId on the Base Sepolia
  PoolManager. When the tick moved at least `minTickMove` since the last push, it requests a callback to the hook
  with the new tick and the origin block and tx hash. If the destination pool lists the pair the other way round,
  `invertTick` sends the opposite tick, which is the same price there. The deploy scripts always put rUSD as token0
  on both chains, so the demo does not need it.
- `src/ReflejoHook.sol` (Unichain Sepolia): only works with dynamic-fee pools. In `beforeSwap` it compares the
  pool's current tick with the reference tick:
  - The swap moves the price toward the reference (arbitrage leg): `fee = baseFee + captureBps × (gap − baseFee)`, so closing the gap stays profitable and part of it goes to LPs,
    capped at `maxFee`, which can never exceed 10% (`MAX_FEE_CEILING`).
  - The swap moves the price away from the reference, or there is no fresh reference (`maxAge`): `baseFee`.
- Only the Reactive callback proxy can call `updateReference`, and only on behalf of the configured reactive
  contract.
- `src/ReflejoRetroHook.sol` (spike): covers the arbitrage that lands before the callback, which the fee above
  cannot see. It holds back `holdBps` of every swap's unspecified amount (output on exact input, input on exact
  output) as ERC-6909 claims. Anyone can call `settle(holdId)`: if the first reference after the swap landed within
  `window` seconds and the swap traded toward it, the fee the swap skipped is donated to in-range LPs and the rest
  is refunded; otherwise everything is refunded. Refunds go to the account behind routers that implement
  `IMsgSender`, or to the router itself. A swap is charged only if the price had already moved on Base when the
  swap's block started: a swap that came before the move traded at the right price and gets everything back. The
  callback carries the time of the Base block, computed by the reactive contract from its number (Base Sepolia
  makes a block every 200 ms on a fixed schedule; the log record has the block number but no timestamp). Measured in Foundry: a swap goes from ~60k to ~165k gas, and a settlement
  costs ~43k. Storing a hash of the hold instead of the full record is the next optimization.

## Run the tests

```sh
forge test
```

The reactive tests etch a mock of the system contract at `0x8888…8888`. The hook tests use Uniswap v4's
`Deployers` with a real PoolManager.

## Deploy (testnet)

Use a dedicated testnet wallet. Copy `.env.example` to `.env`, fill `PRIVATE_KEY`, then `source .env` (or export
the variables) before each step. Every script prints the values the next step needs.

Funds needed (from dry runs on 21 Nov 2026):

| Chain | For | Amount |
|---|---|---|
| Base Sepolia | steps 1 and 5, plus lREACT from the faucet | ~0.06 ETH |
| Unichain Sepolia | step 3 and prepaying the hook's callbacks | ~0.02 ETH |
| Reactive Lasna | step 2 deploy (~0.23 lREACT of gas) + funding + reserves | ~2.5 lREACT |

lREACT comes from the faucet contract on Base Sepolia (1 ETH = 100 lREACT, max 5 ETH per tx):

```sh
cast send 0x2afaFD298b23b62760711756088F75B7409f5967 "request(address)" $WALLET   --value 0.05ether --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY
```

Steps:

```sh
# 1. Base Sepolia: reference pool          -> REF_TOKEN0, REF_TOKEN1, REF_POOL_ID
forge script script/01_ReferencePool.s.sol --rpc-url base_sepolia --broadcast
# 2. Lasna: reactive contract              -> REACTIVE
forge script script/02_Reactive.s.sol --rpc-url lasna --broadcast
# 3. Unichain Sepolia: hook + dynamic pool -> HOOK, DEST_POOL_ID
forge script script/03_HookAndPool.s.sol --rpc-url unichain_sepolia --broadcast
# 4. Lasna: point the reactive contract at the hook and add reserves
forge script script/04_Wire.s.sol --rpc-url lasna --broadcast
# 5. Base Sepolia: move the reference price, then watch ReferenceUpdated on Unichain
forge script script/05_MovePrice.s.sol --rpc-url base_sepolia --broadcast
```

Order follows the Reactive docs: reactive contract first, then the callback contract (the hook) with the reactive
address, then point the reactive contract at it. The pool id depends on the hook address, which is why it is set in
step 4 and not in the constructor.

Addresses used:

| | Chain ID | Address |
|---|---|---|
| Base Sepolia PoolManager | 84532 | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` |
| Unichain Sepolia PoolManager | 1301 | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| Unichain Sepolia callback proxy | 1301 | `0x775c9B990ADe401060B78D0e98684eEf8d2466C1` |
| Reactive system contract | 5318007 | `0x8888888888888888888888888888888888888888` |

Sources: [Uniswap v4 deployments](https://docs.uniswap.org/contracts/v4/deployments) ·
[Reactive origins and destinations](https://dev.reactive.network/origins-and-destinations) ·
[Reactive faucet](https://dev.reactive.network/reactive-mainnet).

## Measuring latency

The callback carries the origin chain ID, block and tx hash, and the hook emits them in `ReferenceUpdated`.
`latency/measure.ts` sends a swap on the Base Sepolia reference pool, waits for the `ReferenceUpdated` event on
Unichain Sepolia whose `originTxHash` is that swap, and reports the full loop (origin event → Reactive → callback):

- by block timestamps (1 s resolution; Base Sepolia makes a block every 0.2 s and Unichain Sepolia every 1 s);
- by clock, from seeing the Base receipt to seeing the Unichain event (polled every 250 ms).

```bash
cd latency && npm install && cd ..
node latency/measure.ts   # reads .env; ROUNDS=10 by default, alternating swap direction
```

Each run saves `latency/results-<time>.json` with p50, p95, max and every transaction hash. It needs Node 23.6 or
later, which runs TypeScript directly.

## Status

- [x] Hook and reactive contract, 25 tests passing
- [x] Retroactive surcharge spike in Foundry, charging only swaps after the origin move (40 tests in total)
- [x] Testnet deploy scripts (dry runs pass on Base Sepolia, Unichain Sepolia and Lasna)
- [ ] Event → callback loop verified on testnet
- [x] Latency script (`latency/measure.ts`)
- [ ] Latency numbers from testnet
- [ ] Demo video (under 3 minutes)
