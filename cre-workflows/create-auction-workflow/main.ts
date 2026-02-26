import {
  HTTPCapability,
  ConfidentialHTTPClient,
  EVMClient,
  getNetwork,
  hexToBase64,
  bytesToHex,
  TxStatus,
  handler,
  consensusIdenticalAggregation,
  ok,
  json,
  type ConfidentialHTTPSendRequester,
  type Runtime,
  Runner,
  type HTTPPayload,
} from "@chainlink/cre-sdk"
import {
  encodeAbiParameters,
  parseAbiParameters,
  getAddress,
} from "viem"
import { z } from "zod"

const configSchema = z.object({
  url: z.string(),
  owner: z.string(),
  evms: z.array(
    z.object({
      chainSelectorName: z.string(),
      consumerAddress: z.string(),
      gasLimit: z.string(),
    })
  ),
})
type Config = z.infer<typeof configSchema>

// Payload sent by the property owner to trigger auction creation
const createAuctionPayloadSchema = z.object({
  propertyId: z.string(),                    // e.g. "PROP-001"
  fractionBps: z.number().min(1).max(10000), // basis points of property to tokenize (2500 = 25%)
  sellerAddress: z.string(),                 // Ethereum address of property owner / seller
  deadline: z.number(),                      // auction end timestamp (unix seconds)
  reservePrice: z.string(),                  // minimum bid in USDC (6-decimal string, e.g. "200000000000" = $200k)
  tokenName: z.string(),                     // e.g. "123 Main St Share"
  tokenSymbol: z.string(),                   // e.g. "MAIN123"
  auctionId: z.string(),                     // bytes32 hex auction identifier
})
type CreateAuctionPayload = z.infer<typeof createAuctionPayloadSchema>

type VerifyResult = {
  valid: boolean
  shareAmount: string    // uint256 decimal string, 18-decimal scaled (e.g. "250000000000000000000000")
  appraisedValue: string // total property appraised value in USD
  message: string
}

// Verify property via Confidential HTTP.
// The API checks: property exists, owner verified, not already tokenized, fractionBps valid.
// Returns shareAmount = floor(appraisedValueUsd * fractionBps / 10000) * 1e18
const verifyProperty = (
  sendRequester: ConfidentialHTTPSendRequester,
  config: Config,
  body: string
): VerifyResult => {
  const response = sendRequester
    .sendRequest({
      request: {
        url: `${config.url}/verify-property`,
        method: "POST",
        bodyString: body,
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
    throw new Error(`Property verification API failed: ${response.statusCode}`)
  }
  return json(response) as VerifyResult
}

const onCreateAuction = (runtime: Runtime<Config>, payload: HTTPPayload): string => {
  const { consumerAddress, chainSelectorName, gasLimit } = runtime.config.evms[0]

  // 1. Parse payload
  if (!payload.input || payload.input.length === 0) {
    throw new Error("HTTP trigger payload is required")
  }

  const payloadJson = JSON.parse(payload.input.toString())
  const data = createAuctionPayloadSchema.parse(payloadJson)

  runtime.log(`Create auction request: property=${data.propertyId} fraction=${data.fractionBps}bps seller=${data.sellerAddress}`)

  // 2. Verify property via Confidential HTTP
  //    Bid amounts and seller details stay private — verification runs inside CRE enclave.
  const verifyBody = JSON.stringify({
    propertyId: data.propertyId,
    fractionBps: data.fractionBps,
    sellerAddress: data.sellerAddress,
  })

  const confHTTPClient = new ConfidentialHTTPClient()
  const verifyResult = confHTTPClient
    .sendRequest(
      runtime,
      verifyProperty,
      consensusIdenticalAggregation<VerifyResult>()
    )(runtime.config, verifyBody)
    .result()

  if (!verifyResult.valid) {
    throw new Error(`Property verification failed: ${verifyResult.message}`)
  }

  runtime.log(`Property ${data.propertyId} verified. Shares: ${verifyResult.shareAmount}. Appraised: $${verifyResult.appraisedValue}`)

  // 3. Encode report for contract:
  //    _createPropertyAuction(propertyId, seller, shareAmount, tokenName, tokenSymbol,
  //                            auctionId, deadline, reservePrice)
  const checksummedSeller = getAddress(data.sellerAddress)

  // Convert propertyId string to bytes32
  const propertyIdBytes = data.propertyId.padEnd(32, "\0").slice(0, 32)
  const propertyIdHex = `0x${Buffer.from(propertyIdBytes).toString("hex")}` as `0x${string}`

  const reportData = encodeAbiParameters(
    parseAbiParameters(
      "bytes32 propertyId, address seller, uint256 shareAmount, string tokenName, string tokenSymbol, bytes32 auctionId, uint256 deadline, uint256 reservePrice"
    ),
    [
      propertyIdHex,
      checksummedSeller,
      BigInt(verifyResult.shareAmount),
      data.tokenName,
      data.tokenSymbol,
      data.auctionId as `0x${string}`,
      BigInt(data.deadline),
      BigInt(data.reservePrice),
    ]
  )

  // 4. Get DON-signed report
  const reportResponse = runtime
    .report({
      encodedPayload: hexToBase64(reportData),
      encoderName: "evm",
      signingAlgo: "ecdsa",
      hashingAlgo: "keccak256",
    })
    .result()

  // 5. Submit via EVMClient → KeystoneForwarder → onReport → _createPropertyAuction
  const network = getNetwork({ chainFamily: "evm", chainSelectorName, isTestnet: true })
  if (!network) throw new Error(`Network not found: ${chainSelectorName}`)
  const evmClient = new EVMClient(network.chainSelector.selector)

  const writeResult = evmClient
    .writeReport(runtime, {
      receiver: consumerAddress,
      report: reportResponse,
      gasConfig: { gasLimit },
    })
    .result()

  if (writeResult.txStatus !== TxStatus.SUCCESS) {
    throw new Error(`createPropertyAuction tx failed: ${writeResult.txStatus}`)
  }

  const txHash = bytesToHex(writeResult.txHash || new Uint8Array(32))
  runtime.log(`createPropertyAuction submitted: ${txHash}`)
  runtime.log(`Token deployed: ${data.tokenName} (${data.tokenSymbol}), Shares: ${verifyResult.shareAmount}`)
  return txHash
}

const initWorkflow = (config: Config) => [
  handler(
    new HTTPCapability().trigger({}),
    onCreateAuction
  ),
]

export async function main() {
  const runner = await Runner.newRunner<Config>({ configSchema })
  await runner.run(initWorkflow)
}
