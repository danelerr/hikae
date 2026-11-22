// Full-loop latency: swap on the Base Sepolia reference pool -> Reactive Lasna -> callback on Unichain Sepolia.
// Each round sends one swap on Base and waits for the hook's ReferenceUpdated event whose originTxHash is that swap.
// Usage (from the project root, after the deploy steps in the README): node latency/measure.ts
// Reads ../.env. Needs PRIVATE_KEY, REF_TOKEN0, REF_TOKEN1, HOOK and DEST_POOL_ID.
// Optional: ROUNDS (10), AMOUNT in wei (50e18), PAUSE_MS between rounds (15000), TIMEOUT_MS per round (60000).
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createPublicClient, createWalletClient, http, parseAbi, parseAbiItem, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia, unichainSepolia } from "viem/chains";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
try {
  process.loadEnvFile(join(root, ".env"));
} catch {
  // no .env: rely on the environment
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

const swapRouterAbi = parseAbi([
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }",
  "struct TestSettings { bool takeClaims; bool settleUsingBurn; }",
  "function swap(PoolKey key, SwapParams params, TestSettings testSettings, bytes hookData) payable returns (int256)",
]);
const referenceUpdated = parseAbiItem(
  "event ReferenceUpdated(bytes32 indexed poolId, int24 tick, uint256 originChainId, uint256 originBlock, uint256 originTxHash, uint256 originTimeMs)",
);

const account = privateKeyToAccount(env("PRIVATE_KEY") as Hex);
const baseTransport = http(env("BASE_SEPOLIA_RPC", "https://sepolia.base.org"));
const uniTransport = http(env("UNICHAIN_SEPOLIA_RPC", "https://sepolia.unichain.org"));
const base = createPublicClient({ chain: baseSepolia, transport: baseTransport });
const baseWallet = createWalletClient({ account, chain: baseSepolia, transport: baseTransport });
const uni = createPublicClient({ chain: unichainSepolia, transport: uniTransport });

const key = {
  currency0: env("REF_TOKEN0") as Hex,
  currency1: env("REF_TOKEN1") as Hex,
  fee: REF_FEE,
  tickSpacing: TICK_SPACING,
  hooks: "0x0000000000000000000000000000000000000000" as Hex,
};
const hook = env("HOOK") as Hex;
const destPoolId = env("DEST_POOL_ID") as Hex;
const rounds = Number(env("ROUNDS", "10"));
const amount = BigInt(env("AMOUNT", (50n * 10n ** 18n).toString()));
const pauseMs = Number(env("PAUSE_MS", "15000"));
const timeoutMs = Number(env("TIMEOUT_MS", "60000"));
const POLL_MS = 250;

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
  missed?: boolean;
};

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitForCallback(baseTx: Hex, fromBlock: bigint) {
  const deadline = Date.now() + timeoutMs;
  let cursor = fromBlock;
  while (Date.now() < deadline) {
    const head = await uni.getBlockNumber();
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
    await sleep(POLL_MS);
  }
  return undefined;
}

function percentile(sorted: number[], p: number) {
  if (sorted.length === 0) return NaN;
  const index = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[Math.max(0, index)];
}

async function main() {
  console.log(`Wallet ${account.address}, ${rounds} rounds, hook ${hook}`);
  const results: Round[] = [];

  for (let i = 0; i < rounds; i++) {
    // Alternate direction so the price oscillates and every swap moves it past the reactive debounce.
    const zeroForOne = i % 2 === 0;
    const uniStart = await uni.getBlockNumber();

    const baseTx = await baseWallet.writeContract({
      address: BASE_SWAP_ROUTER,
      abi: swapRouterAbi,
      functionName: "swap",
      args: [
        key,
        {
          zeroForOne,
          amountSpecified: -amount,
          sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_PLUS_ONE : MAX_SQRT_PRICE_MINUS_ONE,
        },
        { takeClaims: false, settleUsingBurn: false },
        "0x",
      ],
    });
    const receipt = await base.waitForTransactionReceipt({ hash: baseTx, pollingInterval: POLL_MS });
    const receiptSeenAt = Date.now();
    const baseBlock = await base.getBlock({ blockNumber: receipt.blockNumber });

    const round: Round = { round: i + 1, zeroForOne, baseTx, baseBlock: receipt.blockNumber.toString() };
    const found = await waitForCallback(baseTx, uniStart);
    if (!found) {
      round.missed = true;
      console.log(`#${i + 1} no callback within ${timeoutMs} ms (base ${baseTx})`);
    } else {
      const uniBlock = await uni.getBlock({ blockNumber: found.log.blockNumber });
      round.uniTx = found.log.transactionHash;
      round.uniBlock = found.log.blockNumber.toString();
      round.refTick = Number(found.log.args.tick);
      round.chainLatencyS = Number(uniBlock.timestamp - baseBlock.timestamp);
      const originTimeMs = Number(found.log.args.originTimeMs ?? 0n);
      if (originTimeMs > 0) round.onchainLatencyMs = Number(uniBlock.timestamp) * 1000 - originTimeMs;
      round.clockLatencyMs = found.seenAt - receiptSeenAt;
      console.log(
        `#${i + 1} ${zeroForOne ? "0->1" : "1->0"} tick ${round.refTick}: ` +
          `${round.chainLatencyS} s by block time, ${round.onchainLatencyMs ?? "?"} ms on-chain, ` +
          `${round.clockLatencyMs} ms by clock`,
      );
    }
    results.push(round);
    if (i < rounds - 1) await sleep(pauseMs);
  }

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
  };
  console.log(JSON.stringify(summary, null, 2));

  const file = join(root, "latency", `results-${new Date().toISOString().replace(/[:.]/g, "-")}.json`);
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
  console.log(`Saved ${file}`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
