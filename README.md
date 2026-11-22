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

### Measured on testnet (22 Nov 2026)

10 rounds, 10 callbacks delivered. From the Base Sepolia block (time computed on-chain from its number) to the start
of the Unichain Sepolia block that carried the callback: **p50 1.8 s, p95 2.6 s, max 2.6 s**. By block timestamps
alone (1 s resolution): p50 2 s, p95 3 s. Raw data: `latency/results-2026-11-22T14-04-23-907Z.json`.

| Round | Swap on Base | Callback on Unichain | Latency |
|---|---|---|---|
| 1 | [0xde9099de…](https://sepolia.basescan.org/tx/0xde9099de79be244e83b79415219bf12a47c0dc4c32cf0e86263f4712e1c52a94) | [0x9bd649b3…](https://sepolia.uniscan.xyz/tx/0x9bd649b3609a6ee7b20ae93161cc7bfd567447f126a7682765aa40164224f482) | 2.6 s |
| 2 | [0x0afc0c17…](https://sepolia.basescan.org/tx/0x0afc0c173fb81b143376210ccc77019a34ad40af2cde822a12dd3a7542d0a253) | [0x18007ddd…](https://sepolia.uniscan.xyz/tx/0x18007ddd8a6db141ccccad192a2e5fd46f098787112d1fe889d616cd9142654f) | 1.8 s |
| 3 | [0xc7fb8750…](https://sepolia.basescan.org/tx/0xc7fb87501b9716f642a92bd6ad718846a58ddec6079863e8c81c60807168b1a0) | [0xd977cd87…](https://sepolia.uniscan.xyz/tx/0xd977cd87ea53ab656f18b5d846ff8f9f59c905aa4d2028f84457ff5772518cd4) | 1.6 s |
| 4 | [0x3db7b792…](https://sepolia.basescan.org/tx/0x3db7b792c7c507fac42b425ab81f97c936fbfc9bced85d2402f01a1894133512) | [0x6523d680…](https://sepolia.uniscan.xyz/tx/0x6523d680530c7e09a2aa808f0a05809d49cdf9a183272282d4d5e3ce8fb7abcb) | 2.4 s |
| 5 | [0xadbfd053…](https://sepolia.basescan.org/tx/0xadbfd053639c1846dbabbee390c2fe5cb88748b9c10fd2e3ba69c473314b9840) | [0x022cd928…](https://sepolia.uniscan.xyz/tx/0x022cd92825b58ad4ad139994575724315e140659630c1c4f758b6f9dd940bdc4) | 1.6 s |
| 6 | [0xf7d96d04…](https://sepolia.basescan.org/tx/0xf7d96d04aabc3e0cb4ad359201ead19dd8f9fbc8a84b87ccdd0e97729879115d) | [0x426eac79…](https://sepolia.uniscan.xyz/tx/0x426eac79e07e832993e6feb9ba0eb4e1d865e46be869e2336042bd32bfc0a622) | 2.2 s |
| 7 | [0xcbc4574a…](https://sepolia.basescan.org/tx/0xcbc4574a39bb66f35ac2825e75b59503a6acef4bb992d952343c21b4db89e991) | [0x2e50e505…](https://sepolia.uniscan.xyz/tx/0x2e50e505041f88ef77962c08d0e43be2e065bee489dca0435e171582ab2e820a) | 1.8 s |
| 8 | [0x0924dc9d…](https://sepolia.basescan.org/tx/0x0924dc9d5571b04b697101074b51accec82a0b66229c1990f973c2ddffa991b0) | [0xdbb47d6e…](https://sepolia.uniscan.xyz/tx/0xdbb47d6e3853c71fc83afe1b717e97923ec6edfefd506f0b146811ebd1486b63) | 2.6 s |
| 9 | [0x37a77237…](https://sepolia.basescan.org/tx/0x37a772372fe4b1bb1df1ce45f0b1f43620b622176e475fedcccca7877aea44e9) | [0xc5ea3fb1…](https://sepolia.uniscan.xyz/tx/0xc5ea3fb1c501c3b57911e77a3d130eb89ad83593c57e341ebfc41395c800be48) | 1.8 s |
| 10 | [0xa39287a2…](https://sepolia.basescan.org/tx/0xa39287a23e7108ac83849e618e00df83a51f3cef9815cd71474c72b267742983) | [0xcd5ddd72…](https://sepolia.uniscan.xyz/tx/0xcd5ddd72dee27dc3949c2059b901a12e0e97f34f12414b4060922058313a139d) | 2.4 s |

Contracts: reactive `0x900Cd8B955d88fD7b805eDcA939f0BFB069946bd` (Lasna), hook
`0x5C7C47e0eA8c509cABF647D13B831b2554c0A080` (Unichain Sepolia). All addresses in `deployments/testnet.env`.

### Retroactive surcharge on testnet (22 Nov 2026)

Retro hook `0xF2B55986DbAbFDEfe9a453379c242A58F88C60c4` (Unichain Sepolia), fed by a second reactive contract
`0xae77c3F3db27F688431372B41CFcdDd4916386f0` (Lasna) that watches the same Base pool. Each round moves the Base price
about 100 ticks, then swaps 1 token on Unichain before the callback lands. In all four rounds the swap ran earlier in
the same Unichain block than the reference, so it paid only the 0.30% base fee. With the reference in place the
dynamic fee for a ~100 tick gap is 0.72%, so settlement charged the 0.42% the swap skipped out of its 1% hold,
donated it to in-range LPs and refunded the rest. Amounts in tokens:

| Round | Swap and hold | Reference | Tick | Settlement | To LPs | Refunded |
|---|---|---|---|---|---|---|
| 1 | [0xd9f20ca8…](https://sepolia.uniscan.xyz/tx/0xd9f20ca8a403c17a03f3152a9ef5c915cf5bb595a4c968f61ccb075cd6a16d8a) | [0x17ad6a0e…](https://sepolia.uniscan.xyz/tx/0x17ad6a0eb3acd7aa77ee92b7b818ad4a449025df3057979349e2c441dbabd3ca) | -100 | [0xcc0423c3…](https://sepolia.uniscan.xyz/tx/0xcc0423c34b4e400302fdc668b3a518c1121758c0759669a414ba64a1f21e91ed) | 0.00419 | 0.00578 |
| 2 | [0x4d1c50fc…](https://sepolia.uniscan.xyz/tx/0x4d1c50fcca2fd49cf77d91641bfb3741f88686f822ffdeffbdca2b26391495a9) | [0x646fe6d0…](https://sepolia.uniscan.xyz/tx/0x646fe6d07e6e0ed2896a36a897731b22b2df655c2bb1ccb549754757ca1dfda5) | -99 | [0xe3311b77…](https://sepolia.uniscan.xyz/tx/0xe3311b777f54e95bdaa28a0a2e50ffae0d7d460e9124bc671b7433f10e72e307) | 0.00407 | 0.00590 |
| 3 | [0x5d88c0f9…](https://sepolia.uniscan.xyz/tx/0x5d88c0f9d4e2343a63d1b0a90348949624bd54f279138a894a2ca499229d9d9a) | [0x0501cd06…](https://sepolia.uniscan.xyz/tx/0x0501cd060d5730d6cc81b3ce918ca47eb5450d2298f3535de5fb745a8fe1c170) | -99 | [0xc0c451f6…](https://sepolia.uniscan.xyz/tx/0xc0c451f6e3113cadbe36e9f3fed5b64515fd5774104c64b04c39cdff762941e5) | 0.00407 | 0.00590 |
| 4 | [0xb1b2e39a…](https://sepolia.uniscan.xyz/tx/0xb1b2e39a501a0ffa7e43908652869cdc5cb9d809fe188358d67851ef8d962575) | [0xb2b5ce63…](https://sepolia.uniscan.xyz/tx/0xb2b5ce636cf730ccf72b20faa811867dac2bfa7d4db87ff80ecd319a29c3a0aa) | -98 | [0x42f0d006…](https://sepolia.uniscan.xyz/tx/0x42f0d0065809d64d009935841b725b4cc5cecc535981244a77f130c6ad118971) | 0.00401 | 0.00596 |

#### Race demo, case A (`latency/race-2026-11-22T14-36-52-258Z.json`)

Base moved ([swap](https://sepolia.basescan.org/tx/0x638bc98c6db27cd158b728d49beba64e54156ae789f64a344290c620ffec71d1)); 1.6 s later the same 1-token swap hit both Unichain pools, before either
callback landed:

- **v1 pool:** [swap](https://sepolia.uniscan.xyz/tx/0x9f09aa6de0a6b4677a159a2363d7d2f9caebc37d86aafafd309cdfd2404e84dd) paid 3000 pips, the base fee. Nothing else happens: the arbitrage beat the reference.
- **Retro pool:** [swap](https://sepolia.uniscan.xyz/tx/0x7544bb96ea18532e286c174d99de0101fdcecbd8d19aa5067a98eba0a2e247aa) paid 3000 pips and held 0.009969105452348999. The [reference](https://sepolia.uniscan.xyz/tx/0x98fce5249f0f49992847c239a0824c9c3e082bdedcb809493772e0b2848035fc) (-98) landed one block later; [settlement](https://sepolia.uniscan.xyz/tx/0x918b3d388e65fca1768c36ccd7380c04e7d1f0aa4cfd89991c32350c82382bab) sent **0.004007** to LPs and refunded 0.005961.

`latency/race.ts` reproduces this and also runs the opposite case: a swap made before the Base move, which gets its
whole hold back.

## Status

- [x] Hook and reactive contract, 25 tests passing
- [x] Retroactive surcharge spike in Foundry, charging only swaps after the origin move (40 tests in total)
- [x] Testnet deploy scripts (dry runs pass on Base Sepolia, Unichain Sepolia and Lasna)
- [x] Event → callback loop verified on testnet (22 Nov 2026)
- [x] Latency script (`latency/measure.ts`)
- [x] Latency numbers from testnet: p50 1.8 s, p95 2.6 s over 10 rounds
- [x] Retroactive surcharge charged on testnet, 4 of 4 rounds (22 Nov 2026)
- [ ] Race demo with the before-the-move case on testnet
- [ ] Demo video (under 3 minutes)
