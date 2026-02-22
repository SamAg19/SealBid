import {
  CronCapability,
  ConfidentialHTTPClient,
  EVMClient,
  getNetwork,
  encodeCallMsg,
  bytesToHex,
  hexToBase64,
  LAST_FINALIZED_BLOCK_NUMBER,
  TxStatus,
  handler,
  consensusIdenticalAggregation,
  ok,
  json,
  type ConfidentialHTTPSendRequester,
  type Runtime,
  Runner,
} from "@chainlink/cre-sdk"
import { encodeFunctionData, decodeFunctionResult, encodeAbiParameters, parseAbiParameters, type Address, type Abi, zeroAddress } from "viem"
import { z } from "zod"
import SealBidAuctionABI from "../abis/SealBidAuctionABI.json"

const ABI = SealBidAuctionABI as Abi
const ZERO_BYTES32 = "0x0000000000000000000000000000000000000000000000000000000000000000"

const configSchema = z.object({
  evms: z.array(
    z.object({
      chainSelectorName: z.string(),
      contractAddress: z.string(),
      gasLimit: z.string(),
    })
  ),
  schedule: z.string(),
  url: z.string(),
  owner: z.string(),
})
type Config = z.infer<typeof configSchema>
type SettlementResult = {
  auctionId: string  // bytes32 hex string
  winner: string     // address
  price: string      // uint256 decimal string
}

const submitSettlementToApi = (
  sendRequester: ConfidentialHTTPSendRequester,
  config: Config,
  auctionId: string
): SettlementResult => {
  const response = sendRequester
    .sendRequest({
      request: {
        url: `${config.url}/settle`,
        method: "POST",
        bodyString: JSON.stringify({ auctionId }),
        multiHeaders: {
          "X-Api-Key": { values: ["{{.apiKey}}"] },
          "Content-Type": { values: ["application/json"] },
        },
      },
      vaultDonSecrets: [
        { key: "apiKey", owner: config.owner },
        { key: "san_marino_aes_gcm_encryption_key", owner: config.owner },
      ],
    })
    .result()

  if (!ok(response)) {
    throw new Error(`Settlement API failed: ${response.statusCode}`)
  }
  return json(response) as SettlementResult
}

const onCronTrigger = (runtime: Runtime<Config>): string => {
  const { contractAddress, chainSelectorName } = runtime.config.evms[0]

  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName,
    isTestnet: true,
  })
  if (!network) {
    throw new Error(`Network not found: ${chainSelectorName}`)
  }

  const evmClient = new EVMClient(network.chainSelector.selector)

  // 1. Read activeAuctionId from the contract
  const callData = encodeFunctionData({ abi: ABI, functionName: "activeAuctionId" })
  const contractCall = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: zeroAddress,
        to: contractAddress as Address,
        data: callData,
      }),
      blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
    })
    .result()

  const activeAuctionId = decodeFunctionResult({
    abi: ABI,
    functionName: "activeAuctionId",
    data: bytesToHex(contractCall.data),
  }) as `0x${string}`

  if (activeAuctionId === ZERO_BYTES32) {
    runtime.log("No active auction, skipping settlement")
    return "no-op"
  }

  runtime.log(`Active auction detected: ${activeAuctionId}`)

  // 2. Call private API with auctionId to determine winner
  const confHTTPClient = new ConfidentialHTTPClient()
  const result = confHTTPClient
    .sendRequest(
      runtime,
      submitSettlementToApi,
      consensusIdenticalAggregation<SettlementResult>()
    )(runtime.config, activeAuctionId)
    .result()

  runtime.log(`Settlement result: auctionId=${result.auctionId} winner=${result.winner} price=${result.price}`)

  // 3. Encode settleAuction args and submit via DON-signed report
  const { gasLimit } = runtime.config.evms[0]

  const reportData = encodeAbiParameters(
    parseAbiParameters("bytes32 auctionId, address winner, uint256 price"),
    [result.auctionId as `0x${string}`, result.winner as Address, BigInt(result.price)]
  )

  const reportResponse = runtime
    .report({
      encodedPayload: hexToBase64(reportData),
      encoderName: "evm",
      signingAlgo: "ecdsa",
      hashingAlgo: "keccak256",
    })
    .result()

  const writeResult = evmClient
    .writeReport(runtime, {
      receiver: contractAddress,
      report: reportResponse,
      gasConfig: { gasLimit },
    })
    .result()

  if (writeResult.txStatus !== TxStatus.SUCCESS) {
    throw new Error(`settleAuction tx failed: ${writeResult.txStatus}`)
  }

  const txHash = bytesToHex(writeResult.txHash || new Uint8Array(32))
  runtime.log(`settleAuction submitted: ${txHash}`)
  return txHash
}

const initWorkflow = (config: Config) => {
  const cron = new CronCapability()
  return [
    handler(
      cron.trigger({ schedule: config.schedule }),
      onCronTrigger
    ),
  ]
}

export async function main() {
  const runner = await Runner.newRunner<Config>()
  await runner.run(initWorkflow)
}