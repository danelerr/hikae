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

Scripts sign with a Foundry keystore account, so no private key is stored in the repo or in `.env`. Import one
with `cast wallet import <name> --interactive` if you do not have it yet.

`deploy.ps1` runs the whole sequence and asks for the keystore password once. It writes the password to a temporary
file that forge and cast read through `ETH_PASSWORD`, and deletes it when it finishes:

```powershell
pwsh -File .\deploy.ps1 -Account <keystore name> -Sender <its address>
```

It requests lREACT from the [Reactive faucet](https://dev.reactive.network/reactive-mainnet) on Base Sepolia if the
balance on Lasna is below 2.5, runs the four deploy steps, saves every address in `deployments/testnet.env` (a second
run resumes from there; `-Fresh` starts over) and ends with the latency run below.

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

## Status

- [x] Hook and reactive contract, 25 tests passing
- [x] Retroactive surcharge spike in Foundry, charging only swaps after the origin move (40 tests in total)
- [x] Testnet deploy scripts (dry runs pass on Base Sepolia, Unichain Sepolia and Lasna)
- [ ] Event → callback loop verified on testnet
- [x] Latency script (`latency/measure.ts`)
- [ ] Latency numbers from testnet
- [ ] Demo video (under 3 minutes)
