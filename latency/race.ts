// Demo of the retroactive surcharge on testnet, with real transactions.
//
// Case A, arbitrage ahead of the callback: the price moves on Base and a swap on Unichain trades toward the new
// price before Reactive delivers it. The same swap goes to the v1 pool and to the retro pool. v1 can only charge
// the base fee. The retro hook charges the skipped fee once the reference lands and donates it to LPs.
// Case B, a swap before the move: the swap on Unichain happens first and Base moves 1.5 s later. When the reference
// lands, the swap gets its whole hold back, because it traded at the right price at the time.
//
// Usage (after deploy.ps1 -Retro): node latency/race.ts
// Reads deployments/testnet.env. Signs with cast and the keystore in ETH_KEYSTORE_ACCOUNT / ETH_PASSWORD.
// Optional: RACE_AMOUNT (Base swap, default 500e18, about 100 ticks), UNI_AMOUNT (Unichain swaps, default 1e18),
// ATTEMPTS (default 4), CASE (A, B or AB, default AB).
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  createPublicClient,
  decodeEventLog,
  formatUnits,
  http,
  parseAbi,
  parseAbiItem,
  type Hex,
  type TransactionReceipt,
} from "viem";
import { baseSepolia, unichainSepolia } from "viem/chains";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
for (const file of [join(root, "deployments", "testnet.env"), join(root, ".env")]) {
  try {
    process.loadEnvFile(file);
  } catch {
    // missing file: rely on the environment
  }
}

function env(name: string, fallback?: string): string {
  const value = process.env[name] ?? fallback;
  if (value === undefined || value === "") {
    console.error(`Missing ${name}. Run deploy.ps1 -Retro first.`);
    process.exit(1);
  }
  return value;
}

const BASE_RPC = env("BASE_SEPOLIA_RPC", "https://sepolia.base.org");
const UNI_RPC = env("UNICHAIN_SEPOLIA_RPC", "https://sepolia.unichain.org");
const BASE_SWAP_ROUTER = "0x8B5bcC363ddE2614281aD875bad385E0A785D3B9";
const UNI_SWAP_ROUTER = "0x9140a78c1A137c7fF1c151EC8231272aF78a99A4";
const DYNAMIC_FEE = 8388608; // LPFeeLibrary.DYNAMIC_FEE_FLAG
const BASE_FEE = 3000;
const MIN_SQRT = 4295128740n;
const MAX_SQRT = 1461446703485210103287273052203988822378723970341n;
const ZERO = "0x0000000000000000000000000000000000000000";

env("ETH_KEYSTORE_ACCOUNT");
env("ETH_PASSWORD");
const wallet = env("WALLET") as Hex;
const refToken0 = env("REF_TOKEN0");
const refToken1 = env("REF_TOKEN1");
const destToken0 = env("DEST_TOKEN0");
const destToken1 = env("DEST_TOKEN1");
const v1Hook = env("HOOK") as Hex;
const v1PoolId = env("DEST_POOL_ID") as Hex;
const retroHook = env("RETRO_HOOK") as Hex;
const retroReactive = env("RETRO_REACTIVE") as Hex;
const retroPoolId = env("RETRO_POOL_ID") as Hex;
const demoRouter = env("DEMO_ROUTER");
const raceAmount = BigInt(env("RACE_AMOUNT", (500n * 10n ** 18n).toString()));
const uniAmount = BigInt(env("UNI_AMOUNT", (10n ** 18n).toString()));
const attempts = Number(env("ATTEMPTS", "4"));
// Base Sepolia block time from its number, same clock the reactive contract uses (see script/04_Wire.s.sol).
const anchorBlock = BigInt(env("ORIGIN_ANCHOR_BLOCK", "62159236"));
const anchorTimeMs = Number(env("ORIGIN_ANCHOR_TIME_MS", "1795353716000"));
const blockTimeMs = Number(env("ORIGIN_BLOCK_TIME_MS", "200"));

const base = createPublicClient({ chain: baseSepolia, transport: http(BASE_RPC) });
const uni = createPublicClient({ chain: unichainSepolia, transport: http(UNI_RPC) });

const retroAbi = parseAbi([
  "function holdCount() view returns (uint256)",
  "function refCount(bytes32) view returns (uint64)",
  "function previewSettle(uint256) view returns (bool ready, uint256 toLPs)",
  "function getHold(uint256) view returns ((address owner, uint40 time, bool zeroForOne, bool currencyIs0, bool settled, int24 preTick, uint24 feePaid, uint64 refSeq, bytes32 poolId, uint128 swapAmount, uint128 amount))",
  "event Settled(uint256 indexed holdId, uint256 toLPs, uint256 refund)",
]);
const referenceUpdated = parseAbiItem(
  "event ReferenceUpdated(bytes32 indexed poolId, int24 tick, uint256 originChainId, uint256 originBlock, uint256 originTxHash, uint256 originTimeMs)",
);
const swapEvent = parseAbiItem(
  "event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)",
);

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// Reactive Lasna: the reactive contract emits ReferencePushed with the origin tx hash, which links the three legs.
const lasna = createPublicClient({ transport: http(process.env.LASNA_RPC ?? "https://lasna-rpc.rnk.dev/") });
const referencePushed = parseAbiItem("event ReferencePushed(int24 tick, uint256 originBlock, uint256 originTxHash)");

/// The reactive transaction on Lasna that relayed `baseTx`, with its block time.
async function findReactiveTx(reactive: Hex, baseTx: Hex, fromBlock: bigint) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    try {
      const head = await lasna.getBlockNumber();
      const logs = await lasna.getLogs({ address: reactive, event: referencePushed, fromBlock, toBlock: head });
      const match = logs.find((log) => log.args.originTxHash === BigInt(baseTx));
      if (match) {
        const block = await lasna.getBlock({ blockNumber: match.blockNumber });
        return { hash: match.transactionHash, block: match.blockNumber, timestamp: Number(block.timestamp) };
      }
    } catch {
      // transient RPC error
    }
    await sleep(1000);
  }
  return undefined;
}
const fmt = (amount: bigint) => formatUnits(amount, 18);

async function retry<T>(read: () => Promise<T>, tries = 8): Promise<T> {
  for (let i = 1; ; i++) {
    try {
      return await read();
    } catch (error) {
      if (i >= tries) throw error;
      await sleep(1000 * i);
    }
  }
}

function cast(args: string[]): string {
  return execFileSync("cast", args, { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }).trim();
}

function firstHex(out: string, length: number): Hex {
  const match = out.split(/\s+/).find((word) => new RegExp(`^0x[0-9a-fA-F]{${length}}$`).test(word));
  if (!match) throw new Error(`unexpected cast output: ${out}`);
  return match as Hex;
}

/// Sends with the keystore and returns the hash without waiting.
function send(rpc: string, to: string, sig: string, args: string[]): Hex {
  return firstHex(cast(["send", to, sig, ...args, "--rpc-url", rpc, "--async"]), 64);
}

/// Signs now and returns the raw transaction, to publish later in an instant (keystore decryption takes ~1 s).
function presign(rpc: string, to: string, sig: string, args: string[], nonce: number, gas: number): Hex {
  const out = cast(["mktx", to, sig, ...args, "--rpc-url", rpc, "--nonce", String(nonce), "--gas-limit", String(gas)]);
  const raw = out.split(/\s+/).find((word) => /^0x[0-9a-fA-F]+$/.test(word) && word.length > 200);
  if (!raw) throw new Error(`cast mktx returned no transaction: ${out}`);
  return raw as Hex;
}

const receipt = (client: typeof uni | typeof base, hash: Hex) =>
  retry(() => client.waitForTransactionReceipt({ hash, pollingInterval: 250, timeout: 60_000 }));

function originTimeMs(blockNumber: bigint) {
  return anchorTimeMs + Number(blockNumber - anchorBlock) * blockTimeMs;
}

function swapFee(r: TransactionReceipt, poolId: Hex): number | undefined {
  for (const log of r.logs) {
    try {
      const decoded = decodeEventLog({ abi: [swapEvent], data: log.data, topics: log.topics });
      if (decoded.args.id.toLowerCase() === poolId.toLowerCase()) return Number(decoded.args.fee);
    } catch {
      // other event
    }
  }
  return undefined;
}

function settledEvent(r: TransactionReceipt) {
  for (const log of r.logs) {
    try {
      const decoded = decodeEventLog({ abi: retroAbi, data: log.data, topics: log.topics });
      if (decoded.eventName === "Settled") return decoded.args;
    } catch {
      // other event
    }
  }
  throw new Error("no Settled event");
}

async function waitForReference(hook: Hex, poolId: Hex, baseTx: Hex, fromBlock: bigint) {
  const deadline = Date.now() + 90_000;
  let cursor = fromBlock;
  while (Date.now() < deadline) {
    try {
      const head = (await uni.getBlockNumber()) - 1n;
      if (head >= cursor) {
        const logs = await uni.getLogs({ address: hook, event: referenceUpdated, args: { poolId }, fromBlock: cursor, toBlock: head });
        const match = logs.find((log) => log.args.originTxHash === BigInt(baseTx));
        if (match) return match;
        cursor = head + 1n;
      }
    } catch {
      // transient RPC error
    }
    await sleep(1000);
  }
  throw new Error(`no reference for ${baseTx} within 90 s`);
}

const read = <T>(functionName: string, args: unknown[] = []) =>
  retry(() => uni.readContract({ address: retroHook, abi: retroAbi, functionName: functionName as never, args: args as never }) as Promise<T>);

type Hold = {
  owner: Hex;
  time: number;
  feePaid: number;
  refSeq: bigint;
  swapAmount: bigint;
  amount: bigint;
  preTick: number;
  settled: boolean;
};

const refKey = `(${refToken0},${refToken1},3000,60,${ZERO})`;
const swapParams = (zeroForOne: boolean, amount: bigint) => `(${zeroForOne},-${amount},${zeroForOne ? MIN_SQRT : MAX_SQRT})`;

const BASE_SWAP_SIG = "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)";
const baseSwapArgs = (zeroForOne: boolean) => [refKey, swapParams(zeroForOne, raceAmount), "(false,false)", "0x"];

function moveBase(zeroForOne: boolean): Hex {
  return send(BASE_RPC, BASE_SWAP_ROUTER, BASE_SWAP_SIG, baseSwapArgs(zeroForOne));
}

/// Moves Base and waits until the retro hook has the matching reference, so the next case starts clean.
async function baseMoveAndSettleIn(zeroForOne: boolean) {
  const from = await retry(() => uni.getBlockNumber());
  const tx = moveBase(zeroForOne);
  await receipt(base, tx);
  const ref = await waitForReference(retroHook, retroPoolId, tx, from);
  return { tx, refTick: Number(ref.args.tick) };
}

async function settle(holdId: bigint) {
  const tx = send(UNI_RPC, retroHook, "settle(uint256)", [String(holdId)]);
  const settled = settledEvent(await receipt(uni, tx));
  return { tx, auto: false, toLPs: settled.toLPs, refund: settled.refund };
}

/// The callback that brings the reference settles the hold itself; fall back to a manual settle otherwise.
async function outcome(holdId: bigint, callbackTx: Hex) {
  const hold = await read<Hold>("getHold", [holdId]);
  if (!hold.settled) return settle(holdId);
  const settled = settledEvent(await receipt(uni, callbackTx));
  return { tx: callbackTx, auto: true, toLPs: settled.toLPs, refund: settled.refund };
}

async function caseA() {
  for (let attempt = 1; attempt <= attempts; attempt++) {
    console.log(`\nCase A, attempt ${attempt}: Base moves down, the bot trades on Unichain before the callback`);
    const holdId = await read<bigint>("holdCount");
    const refBefore = await read<bigint>("refCount", [retroPoolId]);
    // Everything is signed before the race starts, so nothing waits on keystore decryption once Base moves.
    const uniNonce = await retry(() => uni.getTransactionCount({ address: wallet, blockTag: "pending" }));
    const baseNonce = await retry(() => base.getTransactionCount({ address: wallet, blockTag: "pending" }));
    const retroKey = `(${destToken0},${destToken1},${DYNAMIC_FEE},60,${retroHook})`;
    const v1Key = `(${destToken0},${destToken1},${DYNAMIC_FEE},60,${v1Hook})`;
    const rawRetro = presign(UNI_RPC, demoRouter, "swap((address,address,uint24,int24,address),(bool,int256,uint160))", [retroKey, swapParams(true, uniAmount)], uniNonce, 800_000);
    const rawV1 = presign(UNI_RPC, UNI_SWAP_ROUTER, BASE_SWAP_SIG, [v1Key, swapParams(true, uniAmount), "(false,false)", "0x"], uniNonce + 1, 400_000);
    const rawBase = presign(BASE_RPC, BASE_SWAP_ROUTER, BASE_SWAP_SIG, baseSwapArgs(true), baseNonce, 400_000);
    const uniFrom = await retry(() => uni.getBlockNumber());
    const lasnaFrom = await retry(() => lasna.getBlockNumber());

    const sentAt = Date.now();
    const baseTx = await base.sendRawTransaction({ serializedTransaction: rawBase });
    // Base includes it within ~0.5 s. Unichain block timestamps are whole seconds, so publish just after the next
    // second starts: the swap's block then begins after the move, which is what the hook checks.
    await sleep(Math.max(0, Math.ceil((sentAt + 450) / 1000) * 1000 + 120 - Date.now()));
    const [retroTx, v1Tx] = await Promise.all([
      uni.sendRawTransaction({ serializedTransaction: rawRetro }),
      uni.sendRawTransaction({ serializedTransaction: rawV1 }),
    ]);
    const [baseRcpt, retroRcpt, v1Rcpt] = await Promise.all([receipt(base, baseTx), receipt(uni, retroTx), receipt(uni, v1Tx)]);
    const movedAt = originTimeMs(baseRcpt.blockNumber);
    const hold = await read<Hold>("getHold", [holdId]);
    const v1Fee = swapFee(v1Rcpt, v1PoolId);
    // Ahead of the callback: the retro hook had not stored the new reference when the swap ran (same-block order
    // included). After the move: the swap's block started after the Base block, so the hook may charge it.
    const ahead = hold.refSeq === refBefore && Number(hold.feePaid) === BASE_FEE;
    const afterMove = Number(hold.time) * 1000 >= movedAt;
    console.log(
      `  Base swap ${baseTx}, swap ${((Number(hold.time) * 1000 - movedAt) / 1000).toFixed(1)} s after the move; ` +
        `v1 paid ${v1Fee} pips, retro paid ${hold.feePaid} pips`,
    );

    const ref = await waitForReference(retroHook, retroPoolId, baseTx, uniFrom);
    const callbackBlock = ref.blockNumber;
    if (!ahead || !afterMove) {
      console.log(
        !ahead
          ? "  The callback won this race; resetting Base and trying again."
          : "  The swap landed before the Base block; resetting Base and trying again.",
      );
      await baseMoveAndSettleIn(false);
      await sleep(9000); // past the hold window: settling now refunds the hold in full
      await settle(holdId).catch(() => undefined);
      continue;
    }
    const result = await outcome(holdId, ref.transactionHash);
    const relayed = await findReactiveTx(retroReactive, baseTx, lasnaFrom);
    console.log(
      `  Reactive tx on Lasna ${relayed?.hash ?? "?"}; settled ${result.auto ? "by the callback itself" : "manually"}.\n` +
        `  Reference ${ref.args.tick} landed in block ${callbackBlock} after the swap (block ${retroRcpt.blockNumber}, index ${retroRcpt.transactionIndex}).\n` +
        `  Held ${fmt(hold.amount)} of ${fmt(hold.swapAmount)}; to LPs ${fmt(result.toLPs)}, refunded ${fmt(result.refund)}.`,
    );
    return {
      baseTx,
      movedAtMs: movedAt,
      v1: { tx: v1Tx, feePips: v1Fee },
      retro: {
        tx: retroTx,
        feePaidPips: Number(hold.feePaid),
        swapBlock: retroRcpt.blockNumber.toString(),
        reactiveTx: relayed?.hash,
        callbackTx: ref.transactionHash,
        callbackBlock: callbackBlock.toString(),
        settledByCallback: result.auto,
        refTick: Number(ref.args.tick),
        held: fmt(hold.amount),
        swapAmount: fmt(hold.swapAmount),
        settleTx: result.tx,
        toLPs: fmt(result.toLPs),
        refund: fmt(result.refund),
      },
    };
  }
  throw new Error(`no race met both conditions in ${attempts} attempts; run it again or raise ATTEMPTS`);
}

async function caseB() {
  console.log("\nCase B: a swap on Unichain first, Base moves 1.5 s later");
  const holdId = await read<bigint>("holdCount");
  const retroKey = `(${destToken0},${destToken1},${DYNAMIC_FEE},60,${retroHook})`;
  // Presign the Base move so it follows the swap by 1.5 s, not by the seconds keystore decryption takes. The
  // reference then lands well inside the hold window, and only the timing rule decides the outcome.
  const baseNonce = await retry(() => base.getTransactionCount({ address: wallet, blockTag: "pending" }));
  const rawBase = presign(BASE_RPC, BASE_SWAP_ROUTER, BASE_SWAP_SIG, baseSwapArgs(true), baseNonce, 400_000);
  const uniFrom = await retry(() => uni.getBlockNumber());
  const lasnaFrom = await retry(() => lasna.getBlockNumber());
  const swapTx = send(UNI_RPC, demoRouter, "swap((address,address,uint24,int24,address),(bool,int256,uint160))", [retroKey, swapParams(true, uniAmount)]);
  await receipt(uni, swapTx);
  const hold = await read<Hold>("getHold", [holdId]);
  await sleep(1500);
  const baseTx = await base.sendRawTransaction({ serializedTransaction: rawBase });
  const baseRcpt = await receipt(base, baseTx);
  const movedAt = originTimeMs(baseRcpt.blockNumber);
  const ref = await waitForReference(retroHook, retroPoolId, baseTx, uniFrom);
  const landedAt = Number((await retry(() => uni.getBlock({ blockNumber: ref.blockNumber }))).timestamp);
  const window = 8;
  const insideWindow = landedAt <= Number(hold.time) + window;
  const moveAfterSwap = movedAt > Number(hold.time) * 1000;
  const result = await outcome(holdId, ref.transactionHash);
  const relayed = await findReactiveTx(retroReactive, baseTx, lasnaFrom);
  const reason = !insideWindow
    ? "the reference landed after the hold window"
    : moveAfterSwap
      ? "Base moved after the swap's block started: the swap traded at the right price"
      : "the swap was not charged for another reason";
  console.log(
    `  Swap block at ${hold.time}, Base moved at ${movedAt / 1000}, reference ${ref.args.tick} landed at ${landedAt}` +
      ` (window ends ${Number(hold.time) + window}).\n` +
      `  Held ${fmt(hold.amount)}; to LPs ${fmt(result.toLPs)}, refunded ${fmt(result.refund)}. Why: ${reason}.`,
  );
  return {
    swapTx,
    swapBlockTime: Number(hold.time),
    baseTx,
    movedAtMs: movedAt,
    reactiveTx: relayed?.hash,
    callbackTx: ref.transactionHash,
    callbackLandedAt: landedAt,
    settledByCallback: result.auto,
    insideWindow,
    moveAfterSwap,
    refTick: Number(ref.args.tick),
    held: fmt(hold.amount),
    settleTx: result.tx,
    toLPs: fmt(result.toLPs),
    refund: fmt(result.refund),
    reason,
  };
}

async function main() {
  console.log(`Wallet ${wallet}, retro hook ${retroHook}, v1 hook ${v1Hook}`);
  const which = env("CASE", "AB").toUpperCase();
  const a = which.includes("A") ? await caseA() : undefined;
  let b;
  if (which.includes("B")) {
    // Bring Base back near the Unichain pools first, so case B starts without a price gap.
    console.log("\nResetting: Base moves back up");
    await baseMoveAndSettleIn(false);
    b = await caseB();
  }
  const file = join(root, "latency", `race-${new Date().toISOString().replace(/[:.]/g, "-")}.json`);
  writeFileSync(
    file,
    JSON.stringify(
      { explorers: { base: "https://sepolia.basescan.org/tx/", unichain: "https://sepolia.uniscan.xyz/tx/" }, caseA: a, caseB: b },
      null,
      2,
    ),
  );
  console.log(`\nSaved ${file}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
