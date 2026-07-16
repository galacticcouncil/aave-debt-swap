import "dotenv/config";
import { ApiPromise, WsProvider } from "@polkadot/api";
import { Keyring } from "@polkadot/keyring";
import { blake2AsHex } from "@polkadot/util-crypto";
import { ethers } from "ethers";

const NETWORK = process.env.HYDRA_NETWORK || "lark";

const WS_URLS: Record<string, string> = {
  zombie: "ws://localhost:8000",
  lark: "wss://node.lark.hydration.cloud",
  nice: "wss://rpc.nice.hydration.cloud",
  hydration: "wss://rpc.hydradx.cloud",
};

const POOL_ADMIN: Record<string, string> = {
  zombie: "0x52341e77341788Ebda44C8BcB4C8BD1B1913B204",
  lark: "0xaa7e0000000000000000000000000000000aa7e0",
  nice: "0x52341e77341788Ebda44C8BcB4C8BD1B1913B204",
  hydration: "0xaa7e0000000000000000000000000000000aa7e0",
};

const POOL_CONFIGURATOR = "0xE64C38E2Fa00DFe4F1d0B92f75B8E44eBDF292e4";

const WETH_ASSET_ID = 20;

const ASSETS_TO_ENABLE = [
  { symbol: "DOT", address: "0x0000000000000000000000000000000100000005" },
  { symbol: "USDT", address: "0x000000000000000000000000000000010000000a" },
  { symbol: "WETH", address: "0x0000000000000000000000000000000100000014" },
  { symbol: "USDC", address: "0x0000000000000000000000000000000100000016" },
];

const CONFIGURATOR_ABI = [
  "function setReserveFlashLoaning(address asset, bool enabled)",
];

const FULL_FLOW = process.argv.includes("--full-flow");
const FUND_EVM = process.argv.includes("--fund-evm");

function evmTruncatedAccount(evmAddress: string): string {
  const prefix = Buffer.from("ETH\0");
  const addrBuf = Buffer.from(evmAddress.replace("0x", ""), "hex");
  const padding = Buffer.alloc(32 - prefix.length - addrBuf.length);
  return "0x" + Buffer.concat([prefix, addrBuf, padding]).toString("hex");
}

function buildEvmCalldata(asset: string): string {
  const iface = new ethers.utils.Interface(CONFIGURATOR_ABI);
  return iface.encodeFunctionData("setReserveFlashLoaning", [asset, true]);
}

async function buildCalls(api: ApiPromise): Promise<any[]> {
  const admin = POOL_ADMIN[NETWORK];
  const calls: any[] = [];

  for (const asset of ASSETS_TO_ENABLE) {
    const data = buildEvmCalldata(asset.address);
    const evmCall = api.tx.evm.call(
      admin,
      POOL_CONFIGURATOR,
      data,
      "0",
      "600000",
      "600000000",
      undefined,
      undefined,
      [],
      []
    );
    calls.push(api.tx.dispatcher.dispatchAsAaveManager(evmCall));
  }

  if (FUND_EVM) {
    const evmAddress = process.env.EVM_ADDRESS;
    if (!evmAddress) {
      throw new Error("Set EVM_ADDRESS env var when using --fund-evm");
    }
    const truncated = evmTruncatedAccount(evmAddress);
    const amount = process.env.FUND_AMOUNT || "10000000000000000000";
    console.log(`\n  Will mint ${amount} WETH (asset ${WETH_ASSET_ID}) to:`);
    console.log(`    EVM address: ${evmAddress}`);
    console.log(`    Substrate account: ${truncated}`);
    calls.push(
      api.tx.currencies.updateBalance(truncated, WETH_ASSET_ID, amount)
    );
    calls.push(
      api.tx.evmAccounts.addContractDeployer(evmAddress)
    );
    console.log(`  Will whitelist ${evmAddress} as contract deployer`);
  }

  return calls;
}

async function generatePreimage(api: ApiPromise) {
  const calls = await buildCalls(api);
  const batch = api.tx.utility.batchAll(calls);
  return batch.method;
}

async function submitWithRetry(
  tx: any,
  signer: any,
  api: ApiPromise,
  label: string,
  timeoutMs = 300_000
): Promise<void> {
  console.log(`  ${label}: submitting...`);

  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`${label} timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    tx.signAndSend(
      signer,
      { nonce: -1, era: 0 },
      (result: any) => {
        const { status, dispatchError } = result;

        if (status.isInBlock) {
          clearTimeout(timer);
          console.log(`  ${label}: included in ${status.asInBlock.toHex()}`);

          if (dispatchError) {
            if (dispatchError.isModule) {
              const decoded = api.registry.findMetaError(
                dispatchError.asModule
              );
              reject(
                new Error(
                  `${label}: ${decoded.section}.${decoded.name}: ${decoded.docs.join(" ")}`
                )
              );
            } else {
              reject(new Error(`${label}: ${dispatchError.toString()}`));
            }
          } else {
            resolve();
          }
        }
      }
    );
  });
}

async function executeFullFlow(api: ApiPromise, preimage: any) {
  console.log("\n[Full Flow] Executing governance proposal...\n");

  const keyring = new Keyring({ type: "sr25519" });
  const signer = keyring.addFromUri("//Alice");
  console.log(`  Signer: ${signer.address}`);

  const encodedCall = preimage.toHex();
  const encodedHash = blake2AsHex(encodedCall);
  const encodedLen = encodedCall.length / 2 - 1;

  console.log(`  Preimage hash: ${encodedHash}`);
  console.log(`  Preimage length: ${encodedLen}`);

  console.log("\n  Step 1: Note preimage...");
  const notePreimageTx = api.tx.preimage.notePreimage(encodedCall);
  await submitWithRetry(notePreimageTx, signer, api, "notePreimage");

  console.log("\n  Step 2: Submit referendum with Root origin...");
  const submitTx = api.tx.referenda.submit(
    { system: "Root" },
    { Lookup: { hash: encodedHash, len: encodedLen } },
    { After: 1 }
  );
  await submitWithRetry(submitTx, signer, api, "submitReferendum");

  const referendumIndex =
    parseInt((await api.query.referenda.referendumCount()).toString()) - 1;
  console.log(`  Referendum index: ${referendumIndex}`);

  console.log("\n  Step 3: Place decision deposit...");
  const depositTx = api.tx.referenda.placeDecisionDeposit(referendumIndex);
  await submitWithRetry(depositTx, signer, api, "placeDecisionDeposit");

  console.log("\n  Step 4: Vote AYE...");
  const { data } = (await api.query.system.account(signer.address)) as any;
  const free = data.free.toBigInt();
  const voteAmount = (free * 5n) / 10n;
  console.log(
    `  Free balance: ${free.toString()}, voting with: ${voteAmount.toString()}`
  );

  const voteTx = api.tx.convictionVoting.vote(referendumIndex, {
    Standard: {
      balance: voteAmount,
      vote: { aye: true, conviction: "Locked1x" },
    },
  });
  await submitWithRetry(voteTx, signer, api, "vote");

  console.log("\n  Step 5: Advancing blocks...");
  try {
    await (api.rpc as any)("dev_newBlock", { count: 10 });
    const info = await api.query.referenda.referendumInfoFor(referendumIndex);
    console.log(`  Referendum status: ${JSON.stringify(info.toHuman())}`);
  } catch {
    console.log(
      "  dev_newBlock not available (not a dev node). Referendum will pass after voting period ends."
    );
  }

  console.log("\n  Governance proposal submitted and voted on.");
  console.log(`  Referendum index: ${referendumIndex}`);
}

async function main() {
  const wsUrl = WS_URLS[NETWORK];
  if (!wsUrl) throw new Error(`Unknown network: ${NETWORK}`);

  console.log(`Network: ${NETWORK} (${wsUrl})`);
  console.log("=".repeat(60));

  const provider = new WsProvider(wsUrl);
  const api = await ApiPromise.create({ provider, noInitWarn: true });

  console.log(
    `Chain: ${(await api.rpc.system.chain()).toString()}, spec: ${api.runtimeVersion.specVersion.toString()}`
  );

  console.log("\n[Preimage] Building governance call...\n");

  const admin = POOL_ADMIN[NETWORK];
  console.log(`  PoolAdmin: ${admin}`);
  console.log(`  PoolConfigurator: ${POOL_CONFIGURATOR}`);
  console.log(`  Flash loans for:`);
  for (const asset of ASSETS_TO_ENABLE) {
    console.log(`    ${asset.symbol}: ${asset.address}`);
  }

  const preimage = await generatePreimage(api);

  console.log("\n[Preimage] Call structure:");
  console.log(JSON.stringify(preimage.toHuman(), null, 2));

  console.log("\n[Preimage] Hex:");
  console.log(preimage.toHex());

  console.log(`\n[Preimage] Hash: ${preimage.hash.toHex()}`);
  console.log(`[Preimage] Length: ${preimage.toHex().length / 2 - 1}`);

  if (FULL_FLOW) {
    await executeFullFlow(api, preimage);
  } else {
    console.log(
      "\nTo execute the full governance flow (note preimage, submit referendum, vote):"
    );
    console.log(
      `  HYDRA_NETWORK=${NETWORK} npx ts-node scripts/governance-flash-loans.ts --full-flow`
    );
  }

  await api.disconnect();
  process.exit(0);
}

main().catch((err) => {
  console.error("\nFATAL:", err.message || err);
  process.exit(1);
});
