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
// ATTEMPTS (default 4).
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
function presign(to: string, sig: string, args: string[], nonce: number, gas: number): Hex {
  const out = cast(["mktx", to, sig, ...args, "--rpc-url", UNI_RPC, "--nonce", String(nonce), "--gas-limit", String(gas)]);
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

type Hold = { owner: Hex; time: number; feePaid: number; refSeq: bigint; swapAmount: bigint; amount: bigint; preTick: number };

const refKey = `(${refToken0},${refToken1},3000,60,${ZERO})`;
const swapParams = (zeroForOne: boolean, amount: bigint) => `(${zeroForOne},-${amount},${zeroForOne ? MIN_SQRT : MAX_SQRT})`;

function moveBase(zeroForOne: boolean): Hex {
  return send(BASE_RPC, BASE_SWAP_ROUTER, "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)", [
    refKey,
    swapParams(zeroForOne, raceAmount),
    "(false,false)",
    "0x",
  ]);
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
  const [ready, toLPs] = await read<[boolean, bigint]>("previewSettle", [holdId]);
  const tx = send(UNI_RPC, retroHook, "settle(uint256)", [String(holdId)]);
  const settled = settledEvent(await receipt(uni, tx));
  return { tx, ready, previewToLPs: toLPs, toLPs: settled.toLPs, refund: settled.refund };
}

async function caseA() {
  for (let attempt = 1; attempt <= attempts; attempt++) {
    console.log(`\nCase A, attempt ${attempt}: Base moves down, the bot trades on Unichain before the callback`);
    const holdId = await read<bigint>("holdCount");
    const refBefore = await read<bigint>("refCount", [retroPoolId]);
    const nonce = await retry(() => uni.getTransactionCount({ address: wallet, blockTag: "pending" }));
    const retroKey = `(${destToken0},${destToken1},${DYNAMIC_FEE},60,${retroHook})`;
    const v1Key = `(${destToken0},${destToken1},${DYNAMIC_FEE},60,${v1Hook})`;
    const rawRetro = presign(demoRouter, "swap((address,address,uint24,int24,address),(bool,int256,uint160))", [retroKey, swapParams(true, uniAmount)], nonce, 800_000);
    const rawV1 = presign(UNI_SWAP_ROUTER, "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)", [v1Key, swapParams(true, uniAmount), "(false,false)", "0x"], nonce + 1, 400_000);
    const uniFrom = await retry(() => uni.getBlockNumber());

    const baseTx = moveBase(true);
    const baseRcpt = await receipt(base, baseTx);
    const movedAt = originTimeMs(baseRcpt.blockNumber);
    // Unichain block timestamps are whole seconds: publish just after the next second starts, so the swap's
    // block begins after the move on Base.
    await sleep(Math.max(0, Math.ceil(movedAt / 1000) * 1000 + 150 - Date.now()));
    const retroTx = await uni.sendRawTransaction({ serializedTransaction: rawRetro });
    const v1Tx = await uni.sendRawTransaction({ serializedTransaction: rawV1 });
    const [retroRcpt, v1Rcpt] = await Promise.all([receipt(uni, retroTx), receipt(uni, v1Tx)]);
    const hold = await read<Hold>("getHold", [holdId]);
    const v1Fee = swapFee(v1Rcpt, v1PoolId);
    const ahead = hold.refSeq === refBefore && Number(hold.feePaid) === BASE_FEE;
    console.log(`  Base swap ${baseTx}, v1 swap paid ${v1Fee} pips, retro swap paid ${hold.feePaid} pips`);

    const ref = await waitForReference(retroHook, retroPoolId, baseTx, uniFrom);
    const callbackBlock = ref.blockNumber;
    if (!ahead || retroRcpt.blockNumber >= callbackBlock) {
      console.log("  The callback won this race; resetting Base and trying again.");
      await baseMoveAndSettleIn(false);
      await sleep(9000); // past the hold window: settling now refunds the hold in full
      await settle(holdId).catch(() => undefined);
      continue;
    }
    const result = await settle(holdId);
    console.log(
      `  Reference ${ref.args.tick} landed in block ${callbackBlock}, after the swap (block ${retroRcpt.blockNumber}).\n` +
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
        callbackTx: ref.transactionHash,
        callbackBlock: callbackBlock.toString(),
        refTick: Number(ref.args.tick),
        held: fmt(hold.amount),
        swapAmount: fmt(hold.swapAmount),
        settleTx: result.tx,
        toLPs: fmt(result.toLPs),
        refund: fmt(result.refund),
      },
    };
  }
  throw new Error(`the callback won all ${attempts} races; try again or raise ATTEMPTS`);
}

async function caseB() {
  console.log("\nCase B: a swap on Unichain first, Base moves 1.5 s later");
  const holdId = await read<bigint>("holdCount");
  const retroKey = `(${destToken0},${destToken1},${DYNAMIC_FEE},60,${retroHook})`;
  const uniFrom = await retry(() => uni.getBlockNumber());
  const swapTx = send(UNI_RPC, demoRouter, "swap((address,address,uint24,int24,address),(bool,int256,uint160))", [retroKey, swapParams(true, uniAmount)]);
  const swapRcpt = await receipt(uni, swapTx);
  const hold = await read<Hold>("getHold", [holdId]);
  await sleep(1500);
  const baseTx = moveBase(true);
  const baseRcpt = await receipt(base, baseTx);
  const ref = await waitForReference(retroHook, retroPoolId, baseTx, uniFrom);
  const result = await settle(holdId);
  console.log(
    `  Swap at ${hold.time}, Base moved at ${originTimeMs(baseRcpt.blockNumber) / 1000}, reference ${ref.args.tick}.\n` +
      `  Held ${fmt(hold.amount)}; to LPs ${fmt(result.toLPs)}, refunded ${fmt(result.refund)}.`,
  );
  return {
    swapTx,
    swapBlockTime: Number(hold.time),
    baseTx,
    movedAtMs: originTimeMs(baseRcpt.blockNumber),
    callbackTx: ref.transactionHash,
    refTick: Number(ref.args.tick),
    held: fmt(hold.amount),
    settleTx: result.tx,
    toLPs: fmt(result.toLPs),
    refund: fmt(result.refund),
  };
}

async function main() {
  console.log(`Wallet ${wallet}, retro hook ${retroHook}, v1 hook ${v1Hook}`);
  const a = await caseA();
  console.log("\nResetting: Base moves back up");
  await baseMoveAndSettleIn(false);
  const b = await caseB();
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
