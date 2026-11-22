<img src="assets/logo-black.svg" alt="Hikae" width="88">

# Hikae

A Uniswap v4 hook on Unichain that charges cross-chain arbitrage for the price gap it closes, including the
arbitrage that trades before the new price has arrived. Built for the Reactive Omni Buildathon, track Every Second
Counts. *Hikae* (控え) is Japanese for something kept in reserve.

## The problem

When the price moves on Base, the same pair on Unichain keeps the old price until something tells it otherwise. The
first trader to close that gap takes the difference from the LPs (loss-versus-rebalancing,
[Milionis et al.](https://arxiv.org/abs/2208.06046)). A Reactive contract can relay the Base price to Unichain, and a
hook can then charge the closing trade more. But the relay takes about 1.8 s and Base makes a block every 200 ms, so a
bot watching Base can trade before the update and pay the base fee.

Two other projects in this buildathon, [FeeReflex](https://github.com/parthpawar1117/feereflex) and
[Lagless](https://github.com/thesithunyein/lagless), raise the fee when the callback arrives, and both say in their
READMEs that a bot faster than the loop pays only the base fee. Hikae's first contract, `HikaeHook`, works the same
way. `HikaeRetroHook` is the part that handles the faster bot.

## How Hikae charges the faster bot

- Every swap on the pool leaves 1% of its output (or of its input, on exact-output swaps) as ERC-6909 claims for up
  to 8 seconds.
- When the next Base price arrives, the same Reactive callback settles the holds. A swap that traded toward the new
  price after Base moved pays the part of the dynamic fee it skipped, which is donated to the LPs in range. The rest
  of its hold is refunded.
- A swap made before Base moved traded at the right price, so it gets the whole hold back. To tell the two apart, the
  callback carries the time of the Base block. The Reactive log record has the block number but no timestamp, so the
  reactive contract computes the time from Base Sepolia's fixed 200 ms schedule.
- Refunds go to the account behind routers that expose `IMsgSender`. Holds the callbacks have not reached can be
  settled by anyone.

```
Base Sepolia                    Reactive Lasna                    Unichain Sepolia
reference pool ── Swap event ──▶ HikaeReactive ── callback ───▶ HikaeHook (v1)
(PoolManager)                    filters the pool, skips          fee from the reference
                                 small moves, adds the Base
                                 block time                       HikaeRetroHook
                                                                  v1 fee + 1% hold,
                                                                  settled in the callback
```

## Results on testnet

<!-- testnet:start -->
- Loop latency, from the Base block to the Unichain block with the callback: p50 1.6 s, p95 2.8 s (10 of 10 callbacks delivered). One loop: [0xb8db5d74…](https://sepolia.basescan.org/tx/0xb8db5d745fdc1866fef19700e623f01dc0885cf8a3757a90780167ebfc4b800e) on Base → [0x44e3c74d…](https://lasna.reactscan.net/tx/0x44e3c74dfebc1e42ceabf08539383e1940c0f437808813bac7ad3cf72b8bdfce) on Lasna → [0xbcabbaa4…](https://sepolia.uniscan.xyz/tx/0xbcabbaa42272fa0991e105855a2029edce44bbdbc64830a5809828bbb10bae9d) on Unichain.
- A swap ahead of the callback paid 0.30% on the v1 pool. The same swap on the Hikae pool paid 0.30%, then 0.00419 more to its LPs once the price arrived (settled in the callback); 0.00578 of its hold came back.
- A swap made before the Base move got its whole hold back (0.00997).
<!-- testnet:end -->
- 42 Foundry tests, including the timing rule, exact-output holds and settlement inside the callback.

To check them: open [TESTNET.md](TESTNET.md), which links every contract and transaction. In race case A, the v1 and
Hikae swaps land in the same Unichain block; the Hikae callback that follows emits `Settled` with the amount sent to
LPs. Then run `forge test`.

## Contracts

- `src/HikaeReactive.sol` (Lasna) subscribes to `Swap` events of one pool on the Base Sepolia PoolManager. It ignores
  moves smaller than `minTickMove`, computes the Base block time and requests a callback with the new tick. If the
  destination pool lists the tokens in the other order, `invertTick` sends the opposite tick.
- `src/HikaeHook.sol` (Unichain) only accepts dynamic-fee pools. A swap that moves the price toward a fresh reference
  pays `baseFee + captureBps × (gap − baseFee)`, which leaves closing the gap profitable; `maxFee` caps it and can
  never exceed 10%. Other swaps pay `baseFee`. Only the Reactive callback proxy, acting for the configured reactive
  contract, can update the reference.
- `src/HikaeRetroHook.sol` (Unichain) extends `HikaeHook` with the hold described above. Each callback settles up to
  four holds.

## Known limits

- The hold makes every quote about 1% worse until the refund. Aggregators route on quotes, so ordinary flow could
  go elsewhere. A smaller hold, or holding only after large moves, would reduce this.
- The surcharge goes to the LPs in range at settlement, who are not always the ones in range when the arbitrage
  happened. Just-in-time liquidity could take part of it.
- A swap costs about 165k gas instead of 60k, and a callback that settles four holds about 260k. Storing a hash of
  each hold instead of the full record would cut most of that.
- The Base block time comes from the block number and a fixed 200 ms schedule (checked over 5,000,000 blocks).
  Timers themselves use timestamps, as the rules ask: the hold window runs on Unichain block time. If Base changes its
  block time, `setOriginClock` resets the anchor.
- The Base pool is assumed to lead the price. In production the reference should be wherever price discovery happens.
- Not audited.

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
- by clock, from seeing the Base receipt to seeing the Unichain event. Unichain is polled once a second because the
  public RPC rate-limits by IP.

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
- [x] Full loop on testnet with latency per leg ([TESTNET.md](TESTNET.md))
- [x] Race demo on testnet: a swap ahead of the callback, and a swap before the move
- [x] Holds settled inside the Reactive callback
- [ ] Demo video (under 3 minutes)
