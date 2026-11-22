<img src="assets/logo-black.svg" alt="Hikae" width="88">

# Hikae

*Hikae* (控え) is Japanese for what you keep back in reserve.

A Uniswap v4 hook that makes cross-chain arbitrage pay the LPs it takes from, including the arbitrage that lands
before the price update does.

Reactive Network relays the price of a Base pool to a Unichain pool in about 1.8 seconds. Hooks that raise the fee
when that update arrives cannot touch the bot that trades in the meantime. Hikae holds back 1% of every swap for a
few seconds; when the update lands, swaps that traded against the stale price pay the fee they skipped, which goes
to the LPs, and everyone else gets the hold back.

Built for the Reactive Omni Buildathon, track **Every Second Counts**. Everything below runs on Base Sepolia,
Reactive Lasna and Unichain Sepolia, with the transactions linked.

## Results on testnet

<!-- testnet:start -->
- **Loop latency**, Base block to the Unichain block with the callback: p50 1.8 s, p95 2.4 s, 10 of 10 callbacks delivered. One loop: [0xee78907c…](https://sepolia.basescan.org/tx/0xee78907c050cec430deb8178cacbe3ecacdce9dc6bd50bc2e3de787033beb62c) on Base → — on Lasna → [0x17a0df59…](https://sepolia.uniscan.xyz/tx/0x17a0df59df8f3192a40d1701ef33d5138d98a7d413fc06e91f6017fbcb616aa9) on Unichain.
- **Arbitrage ahead of the callback**: the same swap paid 0.30% on the v1 pool and 0.30% on the Hikae pool, which then sent 0.00419 to its LPs and refunded 0.00578.
- **A swap before the move** got its whole hold back (0.00997).
- Every contract and transaction, with explorer links: [TESTNET.md](TESTNET.md).
<!-- testnet:end -->
- 42 Foundry tests, including the timing rule, exact-output holds and settlement inside the callback.

## How a judge can check it in two minutes

1. Open [TESTNET.md](TESTNET.md): every contract with its explorer and Sourcify link, ten full loops with the swap on
   Base, the reactive transaction on Lasna and the callback on Unichain, and both race cases.
2. In case A, compare the two swaps in the same Unichain block: the v1 pool charged the base fee; the Hikae callback
   that followed shows the `Settled` event with the amount sent to LPs.
3. Run `forge test`.

## Why

When the price moves on one chain, the same pool on another chain keeps the old price for a while. The first trader
to close that gap takes value from the LPs: loss-versus-rebalancing
([Milionis et al.](https://arxiv.org/abs/2208.06046)). A hook can charge that trade more, but only once it knows the
new price. Base Sepolia makes a block every 200 ms and the Reactive loop takes about 1.8 s, so a bot watching Base
directly gets several chances to trade first and pay the base fee.

## Prior work and what is new

Two projects built for this buildathon already raise a Unichain pool's fee when a Reactive callback reports a price
move on Base: [FeeReflex](https://github.com/parthpawar1117/feereflex) and
[Lagless](https://github.com/thesithunyein/lagless). Both document the same limit: an arbitrageur faster than the
loop pays only the base fee. Hikae's first contract, `HikaeHook`, is the same idea, with a fee of the same shape
(base fee plus a share of the gap above it). It is the base this project builds on, not its contribution.

What Hikae adds is `HikaeRetroHook`, which charges the arbitrage that beats the callback:

- **Retroactive surcharge, settled by Reactive.** Every swap leaves 1% of its unspecified amount as ERC-6909
  claims for up to 8 s. The callback that brings the next reference settles the holds it decided: it donates the
  skipped fee to in-range LPs and refunds the rest, so nobody has to send a second transaction. Anyone can still
  settle a hold the callbacks have not reached.
- **Timing rule.** Only swaps that happened after the Base price moved are charged. The callback carries the exact
  time of the Base block, computed by the reactive contract from its number, since the Reactive log record has no
  timestamp. A swap that came first traded at the right price and gets everything back.
- **No way around the hold.** It applies to exact-input and exact-output swaps alike, and refunds reach the account
  behind routers that expose `IMsgSender`.

## Known limits

- **Quotes.** The hold makes every swap quote about 1% worse until it is refunded. Aggregators route on quotes, so
  benign flow could go to other pools. A smaller hold, or holding only after large moves, would soften this.
- **Who receives the surcharge.** It goes to the LPs in range at settlement, not necessarily those who were in range
  when the arbitrage happened, which leaves room for just-in-time liquidity.
- **Gas.** A swap goes from about 60k to 165k gas. A callback that settles four holds uses about 260k, paid by
  the hook's deposit with the callback proxy. Storing a hash of the hold instead of the full record is the next
  optimization.
- **Price leader.** The reference pool is assumed to lead the price. In production the reference should be the pool
  where price discovery happens.
- Not audited.

## How it works

```
Base Sepolia                    Reactive Lasna                    Unichain Sepolia
reference pool ── Swap event ──▶ HikaeReactive ── callback ───▶ HikaeHook (v1)
(PoolManager)                    subscribes to the pool's         fee from the reference
                                 Swap events, debounces small
                                 moves, adds the Base block       HikaeRetroHook
                                 time, requests a callback        v1 fee + 1% hold, settled
                                                                  once the reference lands
```

- `src/HikaeReactive.sol` (Reactive Lasna): subscribes to `Swap` events of one PoolId on the Base Sepolia
  PoolManager. When the tick moved at least `minTickMove` since the last push, it requests a callback to the hook
  with the new tick and the origin block and tx hash. If the destination pool lists the pair the other way round,
  `invertTick` sends the opposite tick, which is the same price there. The deploy scripts always put hUSD as token0
  on both chains, so the demo does not need it.
- `src/HikaeHook.sol` (Unichain Sepolia): only works with dynamic-fee pools. In `beforeSwap` it compares the
  pool's current tick with the reference tick:
  - The swap moves the price toward the reference (arbitrage leg): `fee = baseFee + captureBps × (gap − baseFee)`, so closing the gap stays profitable and part of it goes to LPs,
    capped at `maxFee`, which can never exceed 10% (`MAX_FEE_CEILING`).
  - The swap moves the price away from the reference, or there is no fresh reference (`maxAge`): `baseFee`.
- Only the Reactive callback proxy can call `updateReference`, and only on behalf of the configured reactive
  contract.
- `src/HikaeRetroHook.sol`: covers the arbitrage that lands before the callback, which the fee above
  cannot see. It holds back `holdBps` of every swap's unspecified amount (output on exact input, input on exact
  output) as ERC-6909 claims. Each callback settles up to four decided holds, and anyone can call
  `settle(holdId)` for the rest: if the first reference after the swap landed within
  `window` seconds and the swap traded toward it, the fee the swap skipped is donated to in-range LPs and the rest
  is refunded; otherwise everything is refunded. Refunds go to the account behind routers that implement
  `IMsgSender`, or to the router itself. A swap is charged only if the price had already moved on Base when the
  swap's block started: a swap that came before the move traded at the right price and gets everything back. The
  callback carries the time of the Base block, computed by the reactive contract from its number (Base Sepolia
  makes a block every 200 ms on a fixed schedule; the log record has the block number but no timestamp). Measured in Foundry: a swap goes from ~60k to ~165k gas, and a settlement
  costs ~43k.

## Run the tests

```sh
forge test
```

The reactive tests etch a mock of the system contract at `0x8888…8888`. The hook tests use Uniswap v4's
`Deployers` with a real PoolManager.

## Deploy (testnet)

Scripts sign with a Foundry keystore account, so no private key is stored in the repo or in `.env`. Import one
with `cast wallet import <name> --interactive` if you do not have it yet.

`deploy.ps1` runs the whole sequence and asks for the keystore password once. It writes the password to a temporary
file that forge and cast read through `ETH_PASSWORD`, and deletes it when it finishes:

```powershell
pwsh -File .\deploy.ps1 -Account <keystore name> -Sender <its address>
```

It requests lREACT from the [Reactive faucet](https://dev.reactive.network/reactive-mainnet) on Base Sepolia if the
balance on Lasna is below 2.5, runs the four deploy steps, saves every address in `deployments/testnet.env` (a second
run resumes from there; `-Fresh` starts over) and ends with the latency run below. `-Retro` then adds a second
reactive contract, the retro hook with its pool and a demo router, and runs `latency/race.ts` (cases A and B; `CASE=B`
runs one). At the end it writes [TESTNET.md](TESTNET.md) with every contract and transaction.

Funds needed (from dry runs on 21 Nov 2026):

| Chain | For | Amount |
|---|---|---|
| Base Sepolia | steps 1 and 5, plus 0.05 ETH for 5 lREACT from the faucet | ~0.11 ETH |
| Unichain Sepolia | step 3 and prepaying the hook's callbacks | ~0.02 ETH |
| Reactive Lasna | step 2 deploy (~0.23 lREACT of gas) + funding + reserves | ~2.5 lREACT |

The same steps one by one:

```sh
SIGNER="--account <keystore name> --sender <its address>"
# 1. Base Sepolia: reference pool          -> REF_TOKEN0, REF_TOKEN1, REF_POOL_ID
forge script script/01_ReferencePool.s.sol --rpc-url base_sepolia --broadcast $SIGNER
# 2. Lasna: reactive contract              -> REACTIVE
forge script script/02_Reactive.s.sol --rpc-url lasna --broadcast $SIGNER
# 3. Unichain Sepolia: hook + dynamic pool -> HOOK, DEST_POOL_ID
forge script script/03_HookAndPool.s.sol --rpc-url unichain_sepolia --broadcast $SIGNER
# 4. Lasna: point the reactive contract at the hook, set the Base clock and add reserves
forge script script/04_Wire.s.sol --rpc-url lasna --broadcast $SIGNER
# 5. Base Sepolia: move the reference price, then watch ReferenceUpdated on Unichain
forge script script/05_MovePrice.s.sol --rpc-url base_sepolia --broadcast $SIGNER
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
- by clock, from seeing the Base receipt to seeing the Unichain event (Unichain polled every second, the public RPC rate-limits by IP).

```bash
cd latency && npm install && cd ..
node latency/measure.ts   # reads deployments/testnet.env; ROUNDS=10 by default, alternating direction
```

Swaps are signed by `cast send` with the keystore account in `ETH_KEYSTORE_ACCOUNT` and the password file in
`ETH_PASSWORD` (`deploy.ps1` sets both). Each run saves `latency/results-<time>.json` with p50, p95, max and every
transaction hash. It needs Node 23.6 or later, which runs TypeScript directly.

Results from the latest run are written to [TESTNET.md](TESTNET.md) by `latency/report.ts`.

## Status

- [x] Hook, retro hook and reactive contract, 42 Foundry tests
- [x] Deployed on Base Sepolia, Reactive Lasna and Unichain Sepolia with `deploy.ps1`
- [x] Full loop verified on testnet with latency per leg ([TESTNET.md](TESTNET.md))
- [x] Race demo on testnet: arbitrage ahead of the callback (v1 vs Hikae) and a swap before the move
- [x] Holds settled inside the Reactive callback
- [ ] Demo video (under 3 minutes)
