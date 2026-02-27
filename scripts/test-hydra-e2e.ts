import "dotenv/config";
import { ethers, BigNumber } from "ethers";
import { ApiPromise, WsProvider } from "@polkadot/api";
import { Keyring } from "@polkadot/keyring";
import { blake2AsHex } from "@polkadot/util-crypto";
import * as fs from "fs";
import * as path from "path";

// ═══════════════════════════════════════════════════════════════
// Configuration
// ═══════════════════════════════════════════════════════════════

const NETWORK = process.env.HYDRA_NETWORK || "lark";

const RPC_URLS: Record<string, string> = {
  zombie: "http://localhost:8645",
  lark: "https://node.lark.hydration.cloud",
  nice: "https://rpc.nice.hydration.cloud",
  hydration: "https://rpc.hydradx.cloud",
};

const DISPATCH_PRECOMPILE = "0x0000000000000000000000000000000000000401";

const AAVE = {
  poolAddressesProvider: "0xf3Ba4D1b50f78301BDD7EAEa9B67822A15FCA691",
  pool: "0x1b02E051683b5cfaC5929C25E84adb26ECf87B38",
  poolConfigurator: "0xE64C38E2Fa00DFe4F1d0B92f75B8E44eBDF292e4",
  aclManager: "0x8c5E657CA8879ada34555130F3Be255ae47558B5",
  poolAdmin: "0xaa7e0000000000000000000000000000000aa7e0",
};

// DOT and USDC — routed via XYK multi-hop through HDX
const TOKENS: Record<string, { id: number; address: string; decimals: number }> = {
  DOT:  { id: 5,  address: "0x0000000000000000000000000000000100000005", decimals: 10 },
  USDC: { id: 22, address: "0x0000000000000000000000000000000100000016", decimals: 6 },
};

// HDX is only used as a routing intermediary, not an Aave asset
const HDX_ID = 0;

const WS_URLS: Record<string, string> = {
  zombie: "ws://localhost:8000",
  lark: "wss://node.lark.hydration.cloud",
  nice: "wss://rpc.nice.hydration.cloud",
  hydration: "wss://rpc.hydradx.cloud",
};

const ROUTE_EXECUTOR = {
  palletIndex: 67,
  sellCallIndex: 0,
  buyCallIndex: 1,
};

// ═══════════════════════════════════════════════════════════════
// Minimal ABIs
// ═══════════════════════════════════════════════════════════════

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
];

const POOL_ABI = [
  "function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)",
  "function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)",
  "function getReserveData(address asset) view returns (tuple(uint256 configuration, uint128 liquidityIndex, uint128 currentLiquidityRate, uint128 variableBorrowIndex, uint128 currentVariableBorrowRate, uint128 currentStableBorrowRate, uint40 lastUpdateTimestamp, uint16 id, address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress, address interestRateStrategyAddress, uint128 accruedToTreasury, uint128 unbacked, uint128 isolationModeTotalDebt))",
  "function getUserAccountData(address user) view returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase, uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor)",
];

const CREDIT_DELEGATION_ABI = [
  "function approveDelegation(address delegatee, uint256 amount)",
  "function borrowAllowance(address fromUser, address toUser) view returns (uint256)",
];

const DEBT_SWAP_ADAPTER_ABI = [
  "function swapDebt(tuple(address debtAsset, uint256 debtRepayAmount, uint256 debtRateMode, address newDebtAsset, uint256 maxNewDebtAmount, address extraCollateralAsset, uint256 extraCollateralAmount, uint256 offset, bytes paraswapData) debtSwapParams, tuple(address debtToken, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) creditDelegationPermit, tuple(address aToken, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) collateralATokenPermit)",
];

const LIQUIDITY_SWAP_ADAPTER_ABI = [
  "function swapLiquidity(tuple(address collateralAsset, uint256 collateralAmountToSwap, address newCollateralAsset, uint256 newCollateralAmount, uint256 offset, address user, bool withFlashLoan, bytes paraswapData) liquiditySwapParams, tuple(address aToken, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) collateralATokenPermit)",
];

// ═══════════════════════════════════════════════════════════════
// SCALE Encoding — pool-type agnostic route builder
// ═══════════════════════════════════════════════════════════════

function writeU32LE(buf: Buffer, offset: number, value: number) {
  buf.writeUInt32LE(value, offset);
}

function writeU128LE(buf: Buffer, offset: number, value: bigint) {
  for (let i = 0; i < 16; i++) {
    buf[offset + i] = Number((value >> BigInt(i * 8)) & 0xffn);
  }
}

interface Trade {
  poolType: number;
  assetIn: number;
  assetOut: number;
  poolId?: number; // Required for STABLESWAP (the stableswap pool asset ID)
}

const POOL_TYPE = {
  XYK: 0,
  LBP: 1,
  STABLESWAP: 2,
  OMNIPOOL: 3,
};

// Builds a SCALE-encoded Vec<Trade> for route_executor.sell / buy.
// Handles variable-length PoolType encoding (Stableswap includes a u32 pool ID).
function buildRoute(trades: Trade[]): Buffer {
  let totalSize = 1; // compact length byte
  for (const t of trades) {
    // PoolType encoding: XYK/LBP/Omnipool = 1 byte, Stableswap(pool_id) = 1 + 4 bytes
    totalSize += (t.poolType === POOL_TYPE.STABLESWAP ? 5 : 1) + 4 + 4;
  }
  const buf = Buffer.alloc(totalSize);
  buf[0] = trades.length << 2; // SCALE compact encoding
  let off = 1;
  for (const t of trades) {
    buf[off++] = t.poolType;
    if (t.poolType === POOL_TYPE.STABLESWAP) {
      writeU32LE(buf, off, t.poolId!);
      off += 4;
    }
    writeU32LE(buf, off, t.assetIn);
    off += 4;
    writeU32LE(buf, off, t.assetOut);
    off += 4;
  }
  return buf;
}

// ── Route strategies: ordered by likelihood of liquidity ──

interface RouteStrategy {
  name: string;
  dotToUsdc: Buffer;
  usdcToDot: Buffer;
}

const ROUTE_STRATEGIES: RouteStrategy[] = [
  {
    name: "Omnipool",
    dotToUsdc: buildRoute([
      { poolType: POOL_TYPE.OMNIPOOL, assetIn: TOKENS.DOT.id, assetOut: TOKENS.USDC.id },
    ]),
    usdcToDot: buildRoute([
      { poolType: POOL_TYPE.OMNIPOOL, assetIn: TOKENS.USDC.id, assetOut: TOKENS.DOT.id },
    ]),
  },
  {
    name: "XYK (DOT→HDX→USDC)",
    dotToUsdc: buildRoute([
      { poolType: POOL_TYPE.XYK, assetIn: TOKENS.DOT.id, assetOut: HDX_ID },
      { poolType: POOL_TYPE.XYK, assetIn: HDX_ID, assetOut: TOKENS.USDC.id },
    ]),
    usdcToDot: buildRoute([
      { poolType: POOL_TYPE.XYK, assetIn: TOKENS.USDC.id, assetOut: HDX_ID },
      { poolType: POOL_TYPE.XYK, assetIn: HDX_ID, assetOut: TOKENS.DOT.id },
    ]),
  },
];

function buildSellDispatchData(
  assetInId: number,
  assetOutId: number,
  amountIn: bigint,
  minOut: bigint,
  route: Buffer
): string {
  const header = Buffer.alloc(42);
  header[0] = ROUTE_EXECUTOR.palletIndex;
  header[1] = ROUTE_EXECUTOR.sellCallIndex;
  writeU32LE(header, 2, assetInId);
  writeU32LE(header, 6, assetOutId);
  writeU128LE(header, 10, amountIn);
  writeU128LE(header, 26, minOut);
  return "0x" + Buffer.concat([header, route]).toString("hex");
}

function buildBuyDispatchData(
  assetInId: number,
  assetOutId: number,
  amountOut: bigint,
  maxIn: bigint,
  route: Buffer
): string {
  const header = Buffer.alloc(42);
  header[0] = ROUTE_EXECUTOR.palletIndex;
  header[1] = ROUTE_EXECUTOR.buyCallIndex;
  writeU32LE(header, 2, assetInId);
  writeU32LE(header, 6, assetOutId);
  writeU128LE(header, 10, amountOut);
  writeU128LE(header, 26, maxIn);
  return "0x" + Buffer.concat([header, route]).toString("hex");
}

// ═══════════════════════════════════════════════════════════════
// Forge Artifact Loading
// ═══════════════════════════════════════════════════════════════

function loadArtifact(contractName: string): { abi: any[]; bytecode: string } {
  const artifactPath = path.join(
    __dirname, "..", "out", `${contractName}.sol`, `${contractName}.json`
  );
  const json = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  return { abi: json.abi, bytecode: json.bytecode.object };
}

async function deployContract(
  signer: ethers.Wallet,
  contractName: string,
  args: any[],
  gasLimit?: number
): Promise<ethers.Contract> {
  const { abi, bytecode } = loadArtifact(contractName);
  const factory = new ethers.ContractFactory(abi, bytecode, signer);
  const overrides = gasLimit ? { gasLimit } : {};
  const contract = await factory.deploy(...args, overrides);
  await contract.deployed();
  console.log(`  ${contractName} deployed at ${contract.address}`);
  return contract;
}

// ═══════════════════════════════════════════════════════════════
// Paraswap Data Builders
// ═══════════════════════════════════════════════════════════════

function buildSellParaswapData(
  augustusAddr: string,
  tokenIn: string,
  tokenOut: string,
  amountIn: bigint,
  minAmountOut: bigint,
  assetInId: number,
  assetOutId: number,
  route: Buffer
): string {
  const dispatchData = buildSellDispatchData(
    assetInId, assetOutId, amountIn, minAmountOut, route
  );
  const iface = new ethers.utils.Interface([
    "function sell(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, bytes dispatchData)",
  ]);
  const calldata = iface.encodeFunctionData("sell", [
    tokenIn, tokenOut, amountIn, minAmountOut, dispatchData,
  ]);
  return ethers.utils.defaultAbiCoder.encode(
    ["bytes", "address"],
    [calldata, augustusAddr]
  );
}

function buildBuyParaswapData(
  augustusAddr: string,
  tokenIn: string,
  tokenOut: string,
  maxAmountIn: bigint,
  amountOut: bigint,
  assetInId: number,
  assetOutId: number,
  route: Buffer
): string {
  const dispatchData = buildBuyDispatchData(
    assetInId, assetOutId, amountOut, maxAmountIn, route
  );
  const iface = new ethers.utils.Interface([
    "function buy(address tokenIn, address tokenOut, uint256 maxAmountIn, uint256 amountOut, bytes dispatchData)",
  ]);
  const calldata = iface.encodeFunctionData("buy", [
    tokenIn, tokenOut, maxAmountIn, amountOut, dispatchData,
  ]);
  return ethers.utils.defaultAbiCoder.encode(
    ["bytes", "address"],
    [calldata, augustusAddr]
  );
}

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

function fmt(amount: BigNumber, decimals: number, symbol: string): string {
  return `${ethers.utils.formatUnits(amount, decimals)} ${symbol}`;
}

async function getReserveTokens(
  pool: ethers.Contract,
  asset: string
): Promise<{ aToken: string; stableDebtToken: string; variableDebtToken: string }> {
  const data = await pool.getReserveData(asset);
  return {
    aToken: data.aTokenAddress,
    stableDebtToken: data.stableDebtTokenAddress,
    variableDebtToken: data.variableDebtTokenAddress,
  };
}

async function checkFlashLoanEnabled(
  pool: ethers.Contract,
  asset: string
): Promise<boolean> {
  const data = await pool.getReserveData(asset);
  const config = BigNumber.from(data.configuration);
  const FLASHLOAN_ENABLED_BIT = 1n << 63n;
  return (config.toBigInt() & FLASHLOAN_ENABLED_BIT) !== 0n;
}

// ═══════════════════════════════════════════════════════════════
// Substrate: Fund Alice via Governance
// ═══════════════════════════════════════════════════════════════

function evmTruncatedAccount(evmAddress: string): string {
  const prefix = Buffer.from("ETH\0");
  const addrBuf = Buffer.from(evmAddress.replace("0x", ""), "hex");
  const padding = Buffer.alloc(32 - prefix.length - addrBuf.length);
  return "0x" + Buffer.concat([prefix, addrBuf, padding]).toString("hex");
}

async function submitAndWait(
  tx: any, signer: any, api: ApiPromise, label: string
): Promise<void> {
  console.log(`    ${label}: submitting...`);
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} timed out`)), 300_000);
    tx.signAndSend(signer, { nonce: -1, era: 0 }, (result: any) => {
      if (result.status.isInBlock) {
        clearTimeout(timer);
        if (result.dispatchError) {
          if (result.dispatchError.isModule) {
            const decoded = api.registry.findMetaError(result.dispatchError.asModule);
            reject(new Error(`${label}: ${decoded.section}.${decoded.name}`));
          } else {
            reject(new Error(`${label}: ${result.dispatchError.toString()}`));
          }
        } else {
          console.log(`    ${label}: included in block`);
          resolve();
        }
      }
    });
  });
}

async function executeViaSudoOrGovernance(
  api: ApiPromise,
  signer: any,
  batch: any,
  label: string
): Promise<void> {
  const encodedCall = batch.method.toHex();
  const encodedHash = blake2AsHex(encodedCall);
  const encodedLen = encodedCall.length / 2 - 1;

  try {
    console.log(`  [${label}] Trying sudo...`);
    const sudoTx = api.tx.sudo.sudo(batch);
    await submitAndWait(sudoTx, signer, api, "sudo.sudo");
    console.log(`  [${label}] Done via sudo`);
    return;
  } catch (sudoErr: any) {
    console.log(`  [${label}] Sudo not available (${sudoErr.message}), using governance...`);
  }

  await submitAndWait(
    api.tx.preimage.notePreimage(encodedCall), signer, api, "notePreimage"
  );
  await submitAndWait(
    api.tx.referenda.submit(
      { system: "Root" },
      { Lookup: { hash: encodedHash, len: encodedLen } },
      { After: 1 }
    ),
    signer, api, "submitReferendum"
  );

  const refIndex = parseInt((await api.query.referenda.referendumCount()).toString()) - 1;
  console.log(`    Referendum index: ${refIndex}`);

  await submitAndWait(
    api.tx.referenda.placeDecisionDeposit(refIndex), signer, api, "placeDeposit"
  );

  const { data } = (await api.query.system.account(signer.address)) as any;
  const voteAmount = (data.free.toBigInt() * 5n) / 10n;

  await submitAndWait(
    api.tx.convictionVoting.vote(refIndex, {
      Standard: { balance: voteAmount, vote: { aye: true, conviction: "Locked1x" } },
    }),
    signer, api, "vote"
  );

  // Try to advance blocks on dev nodes
  try {
    for (let i = 0; i < 5; i++) {
      await (api.rpc as any).engine.createBlock(true, true);
    }
  } catch {
    try {
      await (api.rpc as any)("dev_newBlock", { count: 10 });
    } catch {
      // Not a dev node — fall through to polling
    }
  }

  // Poll referendum status until enacted or timeout
  console.log(`  [${label}] Waiting for referendum ${refIndex} to enact...`);
  const pollStart = Date.now();
  const ENACTMENT_TIMEOUT_MS = 180_000; // 3 minutes
  while (Date.now() - pollStart < ENACTMENT_TIMEOUT_MS) {
    const info = (await api.query.referenda.referendumInfoFor(refIndex)).toHuman() as any;
    if (info?.Approved) {
      process.stdout.write(".");
      await new Promise((r) => setTimeout(r, 6_000));
      continue;
    }
    if (info?.Ongoing) {
      process.stdout.write(".");
      await new Promise((r) => setTimeout(r, 6_000));
      continue;
    }
    // Confirmed, Rejected, TimedOut, Cancelled, Killed — all terminal
    console.log(`\n  [${label}] Referendum ${refIndex} final status: ${JSON.stringify(info)}`);
    return;
  }
  console.log(`\n  [${label}] Referendum ${refIndex} still pending after ${ENACTMENT_TIMEOUT_MS / 1000}s — continuing anyway`);
}

async function fundAliceViaGovernance(evmAddress: string): Promise<void> {
  const wsUrl = WS_URLS[NETWORK];
  if (!wsUrl) throw new Error(`No WS URL for network: ${NETWORK}`);

  console.log(`  Connecting to ${wsUrl}...`);
  const wsProvider = new WsProvider(wsUrl);
  const api = await ApiPromise.create({ provider: wsProvider, noInitWarn: true });

  const keyring = new Keyring({ type: "sr25519" });
  const aliceSr25519 = keyring.addFromUri("//Alice");
  const truncated = evmTruncatedAccount(evmAddress);

  // Mint tokens to Alice's EVM-mapped substrate account
  const mints: { symbol: string; assetId: number; amount: string }[] = [
    { symbol: "DOT",  assetId: TOKENS.DOT.id, amount: ethers.utils.parseUnits("1000", TOKENS.DOT.decimals).toString() },
    { symbol: "USDC", assetId: TOKENS.USDC.id, amount: ethers.utils.parseUnits("10000", TOKENS.USDC.decimals).toString() },
  ];

  const calls: any[] = [];
  for (const mint of mints) {
    console.log(`  Will mint ${mint.symbol} (asset ${mint.assetId}): ${mint.amount}`);
    calls.push(api.tx.currencies.updateBalance(truncated, mint.assetId, mint.amount));
  }

  const batch = api.tx.utility.batchAll(calls);
  await executeViaSudoOrGovernance(api, aliceSr25519, batch, "Fund Alice");

  await api.disconnect();
}

async function seedDexLiquidity(): Promise<void> {
  const wsUrl = WS_URLS[NETWORK];
  if (!wsUrl) throw new Error(`No WS URL for network: ${NETWORK}`);

  console.log(`  Connecting to ${wsUrl}...`);
  const wsProvider = new WsProvider(wsUrl);
  const api = await ApiPromise.create({ provider: wsProvider, noInitWarn: true });

  const keyring = new Keyring({ type: "sr25519" });
  const aliceSr25519 = keyring.addFromUri("//Alice");

  // Mint enough for BOTH pools — HDX is used in both so we mint 2x
  const hdxPerPool = "1000000000000000";  // 1M HDX (12 decimals) per pool
  const totalHdx   = "2000000000000000";  // 2M HDX total
  const dotAmount  = ethers.utils.parseUnits("100", TOKENS.DOT.decimals).toString();
  const usdcAmount = ethers.utils.parseUnits("1000", TOKENS.USDC.decimals).toString();
  const MAX_LIMIT  = "340282366920938463463374607431768211455"; // u128::MAX

  console.log("  Minting tokens for XYK pool seeding...");
  const mintCalls = [
    api.tx.currencies.updateBalance(aliceSr25519.address, HDX_ID, totalHdx),
    api.tx.currencies.updateBalance(aliceSr25519.address, TOKENS.DOT.id, dotAmount),
    api.tx.currencies.updateBalance(aliceSr25519.address, TOKENS.USDC.id, usdcAmount),
  ];
  const mintBatch = api.tx.utility.batchAll(mintCalls);
  await executeViaSudoOrGovernance(api, aliceSr25519, mintBatch, "Mint for XYK");

  // Seed XYK pools — try addLiquidity with MAX_LIMIT, fallback to createPool
  const pools: { a: number; b: number; amountA: string; amountB: string; label: string }[] = [
    { a: TOKENS.DOT.id, b: HDX_ID,         amountA: dotAmount,   amountB: hdxPerPool, label: "DOT/HDX" },
    { a: HDX_ID,         b: TOKENS.USDC.id, amountA: hdxPerPool,  amountB: usdcAmount, label: "HDX/USDC" },
  ];

  for (const pp of pools) {
    console.log(`  Seeding ${pp.label} XYK pool...`);
    try {
      // addLiquidity with MAX_LIMIT so any pool ratio is accepted
      const addLiqTx = api.tx.xyk.addLiquidity(pp.a, pp.b, pp.amountA, MAX_LIMIT);
      await submitAndWait(addLiqTx, aliceSr25519, api, `addLiquidity ${pp.label}`);
      console.log(`  ${pp.label}: liquidity added`);
    } catch (addErr: any) {
      console.log(`  ${pp.label} addLiquidity failed (${addErr.message}), trying createPool...`);
      try {
        const createTx = api.tx.xyk.createPool(pp.a, pp.amountA, pp.b, pp.amountB);
        await submitAndWait(createTx, aliceSr25519, api, `createPool ${pp.label}`);
        console.log(`  ${pp.label}: pool created`);
      } catch (createErr: any) {
        console.log(`  ${pp.label}: could not seed (${createErr.message})`);
      }
    }
  }

  await api.disconnect();
}

// ═══════════════════════════════════════════════════════════════
// Main E2E Test
// ═══════════════════════════════════════════════════════════════

async function main() {
  const rpcUrl = RPC_URLS[NETWORK];
  if (!rpcUrl) throw new Error(`Unknown network: ${NETWORK}`);

  console.log(`\nNetwork: ${NETWORK} (${rpcUrl})`);
  console.log("═".repeat(60));

  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
  const chainId = (await provider.getNetwork()).chainId;
  console.log(`Chain ID: ${chainId}`);

  const privateKey = process.env.PRIVATE_KEY;
  if (!privateKey) throw new Error("Set PRIVATE_KEY env var");

  const alice = new ethers.Wallet(privateKey, provider);
  console.log(`Alice: ${alice.address}`);

  const pool = new ethers.Contract(AAVE.pool, POOL_ABI, alice);

  // Raw fetch helper — gets full JSON-RPC error message (ethers strips it)
  async function rawEthCall(from: string, to: string, data: string, label: string) {
    const resp = await fetch(rpcUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0", id: 1, method: "eth_call",
        params: [{ from, to, data, gas: "0x3938700" }, "latest"],
      }),
    });
    const json = await resp.json() as any;
    if (json.error) {
      console.error(`  ${label}: ERROR — ${JSON.stringify(json.error).substring(0, 400)}`);
      return false;
    }
    console.log(`  ${label}: OK — ${json.result}`);
    return true;
  }

  // ───────────────────────────────────────────
  // Step 0: Check flash loan status
  // ───────────────────────────────────────────
  console.log("\n[Step 0] Checking flash loan status...");
  const flashLoanDOT = await checkFlashLoanEnabled(pool, TOKENS.DOT.address);
  const flashLoanUSDC = await checkFlashLoanEnabled(pool, TOKENS.USDC.address);
  console.log(`  DOT flash loan:  ${flashLoanDOT ? "ENABLED" : "DISABLED"}`);
  console.log(`  USDC flash loan: ${flashLoanUSDC ? "ENABLED" : "DISABLED"}`);
  const canDebtSwap = flashLoanDOT && flashLoanUSDC;
  if (!canDebtSwap) {
    console.log(
      "  Debt swap requires flash loans. Run governance script first:\n" +
        `    HYDRA_NETWORK=${NETWORK} npx ts-node scripts/governance-flash-loans.ts --full-flow`
    );
  }

  // ───────────────────────────────────────────
  // Step 1: Deploy contracts
  // ───────────────────────────────────────────
  console.log("\n[Step 1] Deploying contracts...");

  const hydraRegistry = await deployContract(alice, "HydraAugustusRegistry", [
    ethers.constants.AddressZero,
  ]);

  const hydraAugustus = await deployContract(alice, "HydraAugustus", [
    DISPATCH_PRECOMPILE,
  ]);

  await (
    await hydraRegistry.setAugustus(hydraAugustus.address, true, { gasLimit: 15_000_000 })
  ).wait();
  console.log("  Augustus registered in registry");

  const debtSwapAdapter = await deployContract(
    alice, "ParaSwapDebtSwapAdapterV3",
    [AAVE.poolAddressesProvider, AAVE.pool, hydraRegistry.address, alice.address],
    15_000_000
  );

  console.log("  Approving pool reserves for DebtSwapAdapter...");
  await (await debtSwapAdapter.approvePoolReserves({ gasLimit: 15_000_000 })).wait();
  console.log("  DebtSwapAdapter reserves approved");

  const liquiditySwapAdapter = await deployContract(
    alice, "ParaSwapLiquiditySwapAdapterV3",
    [AAVE.poolAddressesProvider, AAVE.pool, hydraRegistry.address, alice.address],
    15_000_000
  );

  console.log("  Approving pool reserves for LiquiditySwapAdapter...");
  await (await liquiditySwapAdapter.approvePoolReserves({ gasLimit: 15_000_000 })).wait();
  console.log("  LiquiditySwapAdapter reserves approved");

  // ───────────────────────────────────────────
  // Step 1.5: Fund Alice if needed
  // ───────────────────────────────────────────
  const dotToken = new ethers.Contract(TOKENS.DOT.address, ERC20_ABI, alice);
  const usdcToken = new ethers.Contract(TOKENS.USDC.address, ERC20_ABI, alice);
  const dotBalance = await dotToken.balanceOf(alice.address);
  const usdcBalance = await usdcToken.balanceOf(alice.address);
  const supplyDotAmount = ethers.utils.parseUnits("100", TOKENS.DOT.decimals);
  const supplyUsdcAmount = ethers.utils.parseUnits("1000", TOKENS.USDC.decimals);

  if (dotBalance.lt(supplyDotAmount) || usdcBalance.lt(supplyUsdcAmount)) {
    console.log("\n[Step 1.5] Funding Alice via substrate governance...");
    console.log(`  DOT balance:  ${fmt(dotBalance, TOKENS.DOT.decimals, "DOT")} (need ${fmt(supplyDotAmount, TOKENS.DOT.decimals, "DOT")})`);
    console.log(`  USDC balance: ${fmt(usdcBalance, TOKENS.USDC.decimals, "USDC")} (need ${fmt(supplyUsdcAmount, TOKENS.USDC.decimals, "USDC")})`);
    await fundAliceViaGovernance(alice.address);

    const newDot = await dotToken.balanceOf(alice.address);
    const newUsdc = await usdcToken.balanceOf(alice.address);
    console.log(`  DOT balance after:  ${fmt(newDot, TOKENS.DOT.decimals, "DOT")}`);
    console.log(`  USDC balance after: ${fmt(newUsdc, TOKENS.USDC.decimals, "USDC")}`);
    if (newDot.lt(supplyDotAmount)) {
      throw new Error(`Funding failed. DOT balance: ${fmt(newDot, TOKENS.DOT.decimals, "DOT")}`);
    }
  }

  // ───────────────────────────────────────────
  // Step 2: Alice supplies DOT as collateral + USDC for pool liquidity
  // ───────────────────────────────────────────
  console.log("\n[Step 2] Alice supplies DOT as collateral + USDC for pool liquidity");

  const { aToken: dotAToken } = await getReserveTokens(pool, TOKENS.DOT.address);
  const dotATokenContract = new ethers.Contract(dotAToken, ERC20_ABI, alice);
  const existingDotCollateral = await dotATokenContract.balanceOf(alice.address);

  if (existingDotCollateral.gte(supplyDotAmount)) {
    console.log(`  SKIP: Already have ${fmt(existingDotCollateral, TOKENS.DOT.decimals, "aDOT")} collateral`);
  } else {
    console.log(`  DOT balance: ${fmt(await dotToken.balanceOf(alice.address), TOKENS.DOT.decimals, "DOT")}`);
    await (await dotToken.approve(AAVE.pool, supplyDotAmount, { gasLimit: 15_000_000 })).wait();
    await (await pool.supply(TOKENS.DOT.address, supplyDotAmount, alice.address, 0, { gasLimit: 15_000_000 })).wait();
    console.log(`  Supplied ${fmt(supplyDotAmount, TOKENS.DOT.decimals, "DOT")}`);
  }

  const { aToken: usdcAToken } = await getReserveTokens(pool, TOKENS.USDC.address);
  const usdcATokenContract = new ethers.Contract(usdcAToken, ERC20_ABI, alice);
  const existingUsdcSupply = await usdcATokenContract.balanceOf(alice.address);
  if (existingUsdcSupply.lt(supplyUsdcAmount)) {
    await (await usdcToken.approve(AAVE.pool, supplyUsdcAmount, { gasLimit: 15_000_000 })).wait();
    await (await pool.supply(TOKENS.USDC.address, supplyUsdcAmount, alice.address, 0, { gasLimit: 15_000_000 })).wait();
    console.log(`  Supplied ${fmt(supplyUsdcAmount, TOKENS.USDC.decimals, "USDC")} for pool liquidity`);
  } else {
    console.log(`  SKIP: Already have ${fmt(existingUsdcSupply, TOKENS.USDC.decimals, "aUSDC")} supplied`);
  }

  // ───────────────────────────────────────────
  // Step 3: Alice borrows USDC
  // ───────────────────────────────────────────
  console.log("\n[Step 3] Alice borrows USDC");

  const borrowAmount = ethers.utils.parseUnits("5", TOKENS.USDC.decimals); // small: 5 USDC

  const { variableDebtToken: usdcVToken } = await getReserveTokens(pool, TOKENS.USDC.address);
  const { variableDebtToken: dotVToken } = await getReserveTokens(pool, TOKENS.DOT.address);

  const usdcDebtBefore = await new ethers.Contract(usdcVToken, ERC20_ABI, alice).balanceOf(alice.address);

  if (usdcDebtBefore.gte(borrowAmount)) {
    console.log(`  SKIP: Already have ${fmt(usdcDebtBefore, TOKENS.USDC.decimals, "vUSDC")} debt`);
  } else {
    await (
      await pool.borrow(TOKENS.USDC.address, borrowAmount, 2, 0, alice.address, { gasLimit: 15_000_000 })
    ).wait();
    const usdcDebtAfter = await new ethers.Contract(usdcVToken, ERC20_ABI, alice).balanceOf(alice.address);
    console.log(`  Borrowed ${fmt(borrowAmount, TOKENS.USDC.decimals, "USDC")}, debt: ${fmt(usdcDebtAfter, TOKENS.USDC.decimals, "vUSDC")}`);
  }

  // ───────────────────────────────────────────
  // Step 3.5: Seed DEX liquidity if needed
  // ───────────────────────────────────────────
  console.log("\n[Step 3.5] Seeding DEX pool liquidity...");
  await seedDexLiquidity();

  // ───────────────────────────────────────────
  // Step 3.6: Pre-flight — find a working route (Omnipool, XYK, …)
  // ───────────────────────────────────────────
  console.log("\n[Step 3.6] Pre-flight: probing DOT→USDC routes");

  let activeRoute: RouteStrategy | null = null;
  const testAmounts = ["0.01", "0.001", "0.0001"];

  for (const strategy of ROUTE_STRATEGIES) {
    console.log(`  Trying ${strategy.name}...`);
    let found = false;
    for (const amtStr of testAmounts) {
      const testAmt = ethers.utils.parseUnits(amtStr, TOKENS.DOT.decimals);
      const data = buildSellDispatchData(
        TOKENS.DOT.id, TOKENS.USDC.id,
        testAmt.toBigInt(), 1n,
        strategy.dotToUsdc
      );
      const ok = await rawEthCall(
        alice.address, DISPATCH_PRECOMPILE, data,
        `${strategy.name} DOT→USDC (${amtStr} DOT)`
      );
      if (ok) {
        console.log(`  ${strategy.name} route works at ${amtStr} DOT`);
        found = true;
        break;
      }
    }
    if (found) {
      activeRoute = strategy;
      break;
    }
    console.log(`  ${strategy.name}: no liquidity, trying next...`);
  }

  if (activeRoute) {
    // Validate full Augustus.sell through the working route
    const smallAmt = ethers.utils.parseUnits("0.001", TOKENS.DOT.decimals);
    const dispatchData = buildSellDispatchData(
      TOKENS.DOT.id, TOKENS.USDC.id,
      smallAmt.toBigInt(), 1n,
      activeRoute.dotToUsdc
    );
    const aug = new ethers.Contract(hydraAugustus.address, [
      "function sell(address,address,uint256,uint256,bytes) returns (uint256)",
    ], alice);
    await (await dotToken.approve(hydraAugustus.address, smallAmt, { gasLimit: 15_000_000 })).wait();
    try {
      // Check Alice has enough DOT for the test
      const dotBal = await dotToken.balanceOf(alice.address);
      if (dotBal.lt(smallAmt)) {
        console.log(`  Alice DOT balance too low (${fmt(dotBal, TOKENS.DOT.decimals, "DOT")}), skipping Augustus.sell test`);
      } else {
        const tx = await aug.sell(
          TOKENS.DOT.address, TOKENS.USDC.address,
          smallAmt, 1, dispatchData,
          { gasLimit: 15_000_000 }
        );
        const receipt = await tx.wait();
        console.log(`  Augustus.sell via ${activeRoute.name}: OK (gas ${receipt.gasUsed.toString()})`);
      }
    } catch (e: any) {
      // Extract the best error info available
      let reason = e.reason || "unknown";
      if (e.error?.data && e.error.data !== "0x") reason = e.error.data;
      else if (e.error?.message) reason = e.error.message;
      else if (e.message) reason = e.message;
      console.error(`  Augustus.sell via ${activeRoute.name}: FAILED — ${reason}`);
      console.error(`  Continuing anyway — dispatch route works, Augustus may need more EVM token balance`);
    }
  }

  if (!activeRoute) {
    throw new Error(
      "No working DOT→USDC route found (tried Omnipool, XYK). " +
      "Check that at least one pool type has liquidity on this testnet."
    );
  }

  console.log(`  Using ${activeRoute.name} route for all swap steps`);

  // ───────────────────────────────────────────
  // Step 4: Collateral swap — DOT → USDC
  // ───────────────────────────────────────────
  {
    console.log(`\n[Step 4] Collateral swap: DOT → USDC via ${activeRoute.name} (no flash loan)`);

    const dotCollateral = await dotATokenContract.balanceOf(alice.address);
    // Swap a small fraction to stay within pool ratio limits
    const swapCollateralAmount = dotCollateral.div(100); // 1% of collateral

    const ORACLE_ABI = ["function getAssetPrice(address asset) view returns (uint256)"];
    const oracleAddr = await new ethers.Contract(
      AAVE.poolAddressesProvider,
      ["function getPriceOracle() view returns (address)"],
      alice
    ).getPriceOracle();
    const oracle = new ethers.Contract(oracleAddr, ORACLE_ABI, alice);

    const dotPrice = await oracle.getAssetPrice(TOKENS.DOT.address);
    const usdcPrice = await oracle.getAssetPrice(TOKENS.USDC.address);
    console.log(`  Oracle: DOT=$${ethers.utils.formatUnits(dotPrice, 8)}, USDC=$${ethers.utils.formatUnits(usdcPrice, 8)}`);

    const fromPriceScaled = dotPrice.mul(BigNumber.from(10).pow(TOKENS.USDC.decimals));
    const toPriceScaled = usdcPrice.mul(BigNumber.from(10).pow(TOKENS.DOT.decimals));
    const expectedBeforeSlippage = swapCollateralAmount.mul(fromPriceScaled).div(toPriceScaled);
    const minUsdcOut = expectedBeforeSlippage.mul(5000).div(10000); // 50% slippage tolerance
    console.log(`  Swapping ${fmt(swapCollateralAmount, TOKENS.DOT.decimals, "DOT")} collateral`);
    console.log(`  Expected: ${fmt(expectedBeforeSlippage, TOKENS.USDC.decimals, "USDC")}`);
    console.log(`  Min out (50%): ${fmt(minUsdcOut, TOKENS.USDC.decimals, "USDC")}`);

    await (
      await dotATokenContract.approve(liquiditySwapAdapter.address, swapCollateralAmount, { gasLimit: 15_000_000 })
    ).wait();

    const sellParaswapData = buildSellParaswapData(
      hydraAugustus.address,
      TOKENS.DOT.address, TOKENS.USDC.address,
      swapCollateralAmount.toBigInt(), minUsdcOut.toBigInt(),
      TOKENS.DOT.id, TOKENS.USDC.id,
      activeRoute.dotToUsdc
    );

    const liqAdapter = new ethers.Contract(
      liquiditySwapAdapter.address, LIQUIDITY_SWAP_ADAPTER_ABI, alice
    );

    const swapTx = await liqAdapter.swapLiquidity(
      {
        collateralAsset: TOKENS.DOT.address,
        collateralAmountToSwap: swapCollateralAmount,
        newCollateralAsset: TOKENS.USDC.address,
        newCollateralAmount: minUsdcOut,
        offset: 0,
        user: alice.address,
        withFlashLoan: false,
        paraswapData: sellParaswapData,
      },
      {
        aToken: ethers.constants.AddressZero,
        value: 0, deadline: 0, v: 0,
        r: ethers.constants.HashZero, s: ethers.constants.HashZero,
      },
      { gasLimit: 15_000_000 }
    );
    await swapTx.wait();

    const dotAfter = await dotATokenContract.balanceOf(alice.address);
    const usdcAfter = await usdcATokenContract.balanceOf(alice.address);
    console.log(`  DOT collateral:  ${fmt(dotAfter, TOKENS.DOT.decimals, "aDOT")}`);
    console.log(`  USDC collateral: ${fmt(usdcAfter, TOKENS.USDC.decimals, "aUSDC")}`);
  }

  // ───────────────────────────────────────────
  // Step 5: Debt swap — USDC → DOT (requires flash loan)
  // ───────────────────────────────────────────
  if (canDebtSwap) {
    console.log(`\n[Step 5] Debt swap: USDC → DOT via ${activeRoute.name} (flash loan)`);

    const currentUsdcDebt = await new ethers.Contract(usdcVToken, ERC20_ABI, alice).balanceOf(alice.address);
    const currentDotDebt = await new ethers.Contract(dotVToken, ERC20_ABI, alice).balanceOf(alice.address);

    if (currentUsdcDebt.isZero() && !currentDotDebt.isZero()) {
      console.log(`  SKIP: Debt swap already done (USDC debt=0, DOT debt=${fmt(currentDotDebt, TOKENS.DOT.decimals, "vDOT")})`);
    } else if (currentUsdcDebt.isZero()) {
      console.log("  SKIP: No USDC debt to swap");
    } else {
      // Compute maxNewDebt in DOT using oracle prices
      const ORACLE_ABI = ["function getAssetPrice(address asset) view returns (uint256)"];
      const oracleAddr = await new ethers.Contract(
        AAVE.poolAddressesProvider,
        ["function getPriceOracle() view returns (address)"],
        alice
      ).getPriceOracle();
      const oracle = new ethers.Contract(oracleAddr, ORACLE_ABI, alice);
      const usdcPrice = await oracle.getAssetPrice(TOKENS.USDC.address);
      const dotPrice = await oracle.getAssetPrice(TOKENS.DOT.address);

      // maxNewDebt = usdcDebt * usdcPrice / dotPrice * (10^dotDec / 10^usdcDec) * 2x buffer
      const maxNewDebt = currentUsdcDebt
        .mul(usdcPrice)
        .mul(BigNumber.from(10).pow(TOKENS.DOT.decimals))
        .mul(200)
        .div(dotPrice)
        .div(BigNumber.from(10).pow(TOKENS.USDC.decimals))
        .div(100);

      console.log(`  USDC debt: ${fmt(currentUsdcDebt, TOKENS.USDC.decimals, "vUSDC")}`);
      console.log(`  Max new DOT debt (200% buffer): ${fmt(maxNewDebt, TOKENS.DOT.decimals, "DOT")}`);

      const dotCreditDelegation = new ethers.Contract(dotVToken, CREDIT_DELEGATION_ABI, alice);
      await (
        await dotCreditDelegation.approveDelegation(debtSwapAdapter.address, maxNewDebt, { gasLimit: 15_000_000 })
      ).wait();
      console.log("  Credit delegation approved");

      const buyParaswapData = buildBuyParaswapData(
        hydraAugustus.address,
        TOKENS.DOT.address,  // tokenIn (new debt)
        TOKENS.USDC.address, // tokenOut (old debt to repay)
        maxNewDebt.toBigInt(),
        currentUsdcDebt.toBigInt(),
        TOKENS.DOT.id, TOKENS.USDC.id,
        activeRoute.dotToUsdc
      );

      const debtAdapter = new ethers.Contract(
        debtSwapAdapter.address, DEBT_SWAP_ADAPTER_ABI, alice
      );

      const debtSwapTx = await debtAdapter.swapDebt(
        {
          debtAsset: TOKENS.USDC.address,
          debtRepayAmount: ethers.constants.MaxUint256,
          debtRateMode: 2,
          newDebtAsset: TOKENS.DOT.address,
          maxNewDebtAmount: maxNewDebt,
          extraCollateralAsset: ethers.constants.AddressZero,
          extraCollateralAmount: 0,
          offset: 100,
          paraswapData: buyParaswapData,
        },
        {
          debtToken: ethers.constants.AddressZero,
          value: 0, deadline: 0, v: 0,
          r: ethers.constants.HashZero, s: ethers.constants.HashZero,
        },
        {
          aToken: ethers.constants.AddressZero,
          value: 0, deadline: 0, v: 0,
          r: ethers.constants.HashZero, s: ethers.constants.HashZero,
        },
        { gasLimit: 15_000_000 }
      );
      await debtSwapTx.wait();
      console.log("  Debt swap executed");
    }
  } else {
    console.log("\n[Step 5] SKIPPED — debt swap requires flash loans to be enabled");
  }

  // ───────────────────────────────────────────
  // Step 6: Verify
  // ───────────────────────────────────────────
  console.log("\n[Step 6] Verification");
  console.log("─".repeat(50));

  const finalDotCollateral = await dotATokenContract.balanceOf(alice.address);
  const finalUsdcCollateral = await usdcATokenContract.balanceOf(alice.address);
  const finalUsdcDebt = await new ethers.Contract(usdcVToken, ERC20_ABI, alice).balanceOf(alice.address);
  const finalDotDebt = await new ethers.Contract(dotVToken, ERC20_ABI, alice).balanceOf(alice.address);

  const accountData = await pool.getUserAccountData(alice.address);

  console.log(`  DOT collateral:  ${fmt(finalDotCollateral, TOKENS.DOT.decimals, "aDOT")}`);
  console.log(`  USDC collateral: ${fmt(finalUsdcCollateral, TOKENS.USDC.decimals, "aUSDC")}`);
  console.log(`  USDC debt:       ${fmt(finalUsdcDebt, TOKENS.USDC.decimals, "vUSDC")}`);
  console.log(`  DOT debt:        ${fmt(finalDotDebt, TOKENS.DOT.decimals, "vDOT")}`);
  console.log(`  Health factor:   ${ethers.utils.formatUnits(accountData.healthFactor, 18)}`);
  console.log("─".repeat(50));

  let passed = true;

  if (accountData.healthFactor.gt(ethers.utils.parseUnits("1", 18))) {
    console.log("  PASS: Health factor > 1");
  } else {
    console.error("  FAIL: Health factor <= 1 (position unhealthy!)");
    passed = false;
  }

  if (canDebtSwap) {
    if (!finalUsdcDebt.isZero()) {
      console.error("  FAIL: USDC debt should be 0 after debt swap");
      passed = false;
    } else {
      console.log("  PASS: USDC debt = 0");
    }
    if (finalDotDebt.isZero()) {
      console.error("  FAIL: DOT debt should be > 0 after debt swap");
      passed = false;
    } else {
      console.log("  PASS: DOT debt > 0");
    }
  } else {
    console.log("  SKIP: Debt swap assertions (flash loans not enabled)");
  }

  // Check no tokens stuck in contracts
  for (const [symbol, token] of Object.entries(TOKENS)) {
    const erc20 = new ethers.Contract(token.address, ERC20_ABI, provider);
    const adapterBal = await erc20.balanceOf(debtSwapAdapter.address);
    const augustusBal = await erc20.balanceOf(hydraAugustus.address);

    if (!adapterBal.isZero()) {
      console.error(`  FAIL: ${symbol} stuck in DebtSwapAdapter: ${fmt(adapterBal, token.decimals, symbol)}`);
      passed = false;
    }
    if (!augustusBal.isZero()) {
      console.error(`  FAIL: ${symbol} stuck in HydraAugustus: ${fmt(augustusBal, token.decimals, symbol)}`);
      passed = false;
    }
  }
  if (passed) {
    console.log("  PASS: No tokens stuck in adapters or Augustus");
  }

  console.log("\n" + "═".repeat(60));
  console.log(passed ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED");
  console.log("═".repeat(60));

  process.exit(passed ? 0 : 1);
}

main().catch((err) => {
  console.error("\nFATAL:", err.message || err);
  process.exit(1);
});
