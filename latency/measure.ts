// Full-loop latency: swap on the Base Sepolia reference pool -> Reactive Lasna -> callback on Unichain Sepolia.
// Each round sends one swap on Base and waits for the hook's ReferenceUpdated event whose originTxHash is that swap.
// Usage (from the project root, after the deploy steps in the README): node latency/measure.ts
// Reads ../.env. Needs REF_TOKEN0, REF_TOKEN1, HOOK and DEST_POOL_ID. Swaps are signed by `cast send` with the
// Foundry keystore account in ETH_KEYSTORE_ACCOUNT and the password file in ETH_PASSWORD (deploy.ps1 sets both),
// so no private key goes through this script.
// Optional: ROUNDS (10), AMOUNT in wei (50e18), PAUSE_MS between rounds (15000), TIMEOUT_MS per round (60000).
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createPublicClient, http, parseAbiItem, type Hex } from "viem";
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
    console.error(`Missing ${name}. Set it in .env (see .env.example and the README deploy steps).`);
    process.exit(1);
  }
  return value;
}

const BASE_SWAP_ROUTER = "0x8B5bcC363ddE2614281aD875bad385E0A785D3B9";
const MIN_SQRT_PRICE_PLUS_ONE = 4295128740n;
const MAX_SQRT_PRICE_MINUS_ONE = 1461446703485210103287273052203988822378723970341n;
const TICK_SPACING = 60;
const REF_FEE = 3000;

const referenceUpdated = parseAbiItem(
  "event ReferenceUpdated(bytes32 indexed poolId, int24 tick, uint256 originChainId, uint256 originBlock, uint256 originTxHash, uint256 originTimeMs)",
);

env("ETH_KEYSTORE_ACCOUNT");
env("ETH_PASSWORD");
const wallet = process.env.WALLET ?? process.env.ETH_KEYSTORE_ACCOUNT;
const baseRpc = env("BASE_SEPOLIA_RPC", "https://sepolia.base.org");
const baseTransport = http(baseRpc);
const uniTransport = http(env("UNICHAIN_SEPOLIA_RPC", "https://sepolia.unichain.org"));
const base = createPublicClient({ chain: baseSepolia, transport: baseTransport });
const uni = createPublicClient({ chain: unichainSepolia, transport: uniTransport });

const key = {
  currency0: env("REF_TOKEN0") as Hex,
  currency1: env("REF_TOKEN1") as Hex,
  fee: REF_FEE,
  tickSpacing: TICK_SPACING,
  hooks: "0x0000000000000000000000000000000000000000" as Hex,
};
const hook = env("HOOK") as Hex;
const reactive = env("REACTIVE") as Hex;
const destPoolId = env("DEST_POOL_ID") as Hex;
const rounds = Number(env("ROUNDS", "10"));
const amount = BigInt(env("AMOUNT", (50n * 10n ** 18n).toString()));
const pauseMs = Number(env("PAUSE_MS", "15000"));
const timeoutMs = Number(env("TIMEOUT_MS", "60000"));
const POLL_MS = 250; // Base receipts
// Unichain makes a block per second and its public RPC rate-limits by IP. Polling faster adds nothing: the on-chain
// latency comes from block timestamps, not from when the script notices the event.
const UNI_POLL_MS = Number(env("UNI_POLL_MS", "1000"));

type Round = {
  round: number;
  zeroForOne: boolean;
  baseTx: Hex;
  baseBlock: string;
  uniTx?: Hex;
  uniBlock?: string;
  refTick?: number;
  // Seconds between the two block timestamps: what the chains themselves record.
  chainLatencyS?: number;
  // Milliseconds from the origin block (time computed on-chain from its number, 200 ms resolution) to the start of
  // the Unichain block that carried the callback (1 s resolution).
  onchainLatencyMs?: number;
  // Milliseconds from seeing the Base receipt to seeing the Unichain event (includes up to POLL_MS of polling).
  clockLatencyMs?: number;
  // The leg in the middle: the reactive transaction on Lasna, and how long each leg took.
  lasnaTx?: Hex;
  lasnaBlock?: string;
  baseToLasnaMs?: number;
  lasnaToUnichainS?: number;
  missed?: boolean;
};

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

/// Signs and sends one swap on the reference pool with cast and the keystore account; returns the tx hash.
function sendSwap(zeroForOne: boolean): Hex {
  const limit = zeroForOne ? MIN_SQRT_PRICE_PLUS_ONE : MAX_SQRT_PRICE_MINUS_ONE;
  const out = execFileSync(
    "cast",
    [
      "send",
      BASE_SWAP_ROUTER,
      "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)",
      `(${key.currency0},${key.currency1},${key.fee},${key.tickSpacing},${key.hooks})`,
      `(${zeroForOne},-${amount},${limit})`,
      "(false,false)",
      "0x",
      "--rpc-url",
      baseRpc,
      "--async",
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] },
  ).trim();
  const hash = out.split(/\s+/).find((word) => /^0x[0-9a-fA-F]{64}$/.test(word));
  if (!hash) throw new Error(`cast send did not return a transaction hash: ${out}`);
  return hash as Hex;
}

/// Public RPCs balance requests across nodes that can lag a block behind each other, so a read can fail even with
/// valid parameters. Retry instead of aborting the run.
async function retry<T>(read: () => Promise<T>, attempts = 8): Promise<T> {
  for (let i = 1; ; i++) {
    try {
      return await read();
    } catch (error) {
      if (i >= attempts) throw error;
      await sleep(1000 * i); // back off: rate limits (HTTP 429) need seconds, not milliseconds
    }
  }
}

async function waitForCallback(baseTx: Hex, fromBlock: bigint) {
  const deadline = Date.now() + timeoutMs;
  let cursor = fromBlock;
  while (Date.now() < deadline) {
    try {
      // Stay one block behind the reported head: another node behind the same URL may not have it yet.
      const head = (await uni.getBlockNumber()) - 1n;
      if (head >= cursor) {
        const logs = await uni.getLogs({
          address: hook,
          event: referenceUpdated,
          args: { poolId: destPoolId },
          fromBlock: cursor,
          toBlock: head,
        });
        const match = logs.find((log) => log.args.originTxHash === BigInt(baseTx));
        if (match) return { log: match, seenAt: Date.now() };
        cursor = head + 1n;
      }
    } catch {
      // transient RPC error or rate limit: poll again
    }
    await sleep(UNI_POLL_MS);
  }
  return undefined;
}

function legStats(values: (number | undefined)[]) {
  const sorted = values.filter((v): v is number => v !== undefined).sort((a, b) => a - b);
  return { p50: percentile(sorted, 50), p95: percentile(sorted, 95), max: sorted.at(-1) };
}

function percentile(sorted: number[], p: number) {
  if (sorted.length === 0) return NaN;
  const index = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[Math.max(0, index)];
}

async function main() {
  console.log(`Wallet ${wallet}, ${rounds} rounds, hook ${hook}`);
  const results: Round[] = [];

  for (let i = 0; i < rounds; i++) {
    // Alternate direction so the price oscillates and every swap moves it past the reactive debounce.
    const zeroForOne = i % 2 === 0;
    const uniStart = await retry(() => uni.getBlockNumber());
    const lasnaStart = await retry(() => lasna.getBlockNumber());

    const baseTx = sendSwap(zeroForOne);
    const receipt = await retry(() => base.waitForTransactionReceipt({ hash: baseTx, pollingInterval: POLL_MS }));
    const receiptSeenAt = Date.now();
    const baseBlock = await retry(() => base.getBlock({ blockNumber: receipt.blockNumber }));

    const round: Round = { round: i + 1, zeroForOne, baseTx, baseBlock: receipt.blockNumber.toString() };
    const found = await waitForCallback(baseTx, uniStart);
    if (!found) {
      round.missed = true;
      console.log(`#${i + 1} no callback within ${timeoutMs} ms (base ${baseTx})`);
    } else {
      const uniBlock = await retry(() => uni.getBlock({ blockNumber: found.log.blockNumber }));
      round.uniTx = found.log.transactionHash;
      round.uniBlock = found.log.blockNumber.toString();
      round.refTick = Number(found.log.args.tick);
      round.chainLatencyS = Number(uniBlock.timestamp - baseBlock.timestamp);
      const originTimeMs = Number(found.log.args.originTimeMs ?? 0n);
      if (originTimeMs > 0) round.onchainLatencyMs = Number(uniBlock.timestamp) * 1000 - originTimeMs;
      round.clockLatencyMs = found.seenAt - receiptSeenAt;
      const relayed = await findReactiveTx(reactive, baseTx, lasnaStart);
      if (relayed) {
        round.lasnaTx = relayed.hash;
        round.lasnaBlock = relayed.block.toString();
        if (originTimeMs > 0) round.baseToLasnaMs = relayed.timestamp * 1000 - originTimeMs;
        round.lasnaToUnichainS = Number(uniBlock.timestamp) - relayed.timestamp;
      }
      console.log(
        `#${i + 1} ${zeroForOne ? "0->1" : "1->0"} tick ${round.refTick}: ` +
          `${round.chainLatencyS} s by block time, ${round.onchainLatencyMs ?? "?"} ms on-chain, ` +
          `${round.clockLatencyMs} ms by clock; Lasna ${round.lasnaTx ?? "?"}`,
      );
    }
    results.push(round);
    save(results, false);
    if (i < rounds - 1) await sleep(pauseMs);
  }
  save(results, true);
}

const file = join(root, "latency", `results-${new Date().toISOString().replace(/[:.]/g, "-")}.json`);

/// Written after every round, so an interrupted run keeps what it measured.
function save(results: Round[], final: boolean) {
  const delivered = results.filter((r) => !r.missed);
  const chain = delivered.map((r) => r.chainLatencyS!).sort((a, b) => a - b);
  const clock = delivered.map((r) => r.clockLatencyMs!).sort((a, b) => a - b);
  const onchain = delivered
    .filter((r) => r.onchainLatencyMs !== undefined)
    .map((r) => r.onchainLatencyMs!)
    .sort((a, b) => a - b);
  const summary = {
    rounds: results.length,
    delivered: delivered.length,
    chainLatencyS: { p50: percentile(chain, 50), p95: percentile(chain, 95), max: chain.at(-1) },
    clockLatencyMs: { p50: percentile(clock, 50), p95: percentile(clock, 95), max: clock.at(-1) },
    onchainLatencyMs: { p50: percentile(onchain, 50), p95: percentile(onchain, 95), max: onchain.at(-1) },
    baseToLasnaMs: legStats(delivered.map((r) => r.baseToLasnaMs)),
    lasnaToUnichainS: legStats(delivered.map((r) => r.lasnaToUnichainS)),
  };
  if (final) console.log(JSON.stringify(summary, null, 2));
  writeFileSync(
    file,
    JSON.stringify(
      {
        summary,
        explorers: { base: "https://sepolia.basescan.org/tx/", unichain: "https://sepolia.uniscan.xyz/tx/" },
        results,
      },
      null,
      2,
    ),
  );
  if (final) console.log(`Saved ${file}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
