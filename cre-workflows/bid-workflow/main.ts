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
} from "viem"
import { z } from "zod"

const configSchema = z.object({
  url: z.string(),
  owner: z.string(),
  evms: z.array(
    z.object({
      chainSelectorName: z.string(),
      contractAddress: z.string(),
      gasLimit: z.string(),
    })
  ),
})
type Config = z.infer<typeof configSchema>
type BidResult = { auctionId: string; bidHash: string; }

const submitBidToApi = (
  sendRequester: ConfidentialHTTPSendRequester,
  config: Config,
  bidPayload: string
): BidResult => {
  const response = sendRequester
    .sendRequest({
      request: {
        url: `${config.url}/bid`,
        method: "POST",
        bodyString: bidPayload,
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
    throw new Error(`Bid API failed: ${response.statusCode}`)
  }
  return json(response) as BidResult
}

const onBidSubmit = (runtime: Runtime<Config>, payload: HTTPPayload): string => {
  const { contractAddress, chainSelectorName, gasLimit } = runtime.config.evms[0]

  // 1. Forward raw payload to private API via Confidential HTTP.
  //    The API performs all eligibility checks:
  //      - auctionId matches active auction on-chain
  //      - poolBalance[bidder][token] >= bidAmount
  //      - lockExpiry[bidder] >= auction.deadline
  //      - bidAmount >= auction.reservePrice
  //      - block.timestamp < auction.deadline
  //    The API stores the bid securely and returns the opaque bidHash.
  //    No payload fields are inspected in the workflow to preserve bid privacy.
  const bidPayload = payload.input.toString()
  const confHTTPClient = new ConfidentialHTTPClient()
  const result = confHTTPClient
    .sendRequest(
      runtime,
      submitBidToApi,
      consensusIdenticalAggregation<BidResult>()
    )(runtime.config, bidPayload)
    .result()

  runtime.log(`Bid accepted: ${result.bidHash}`)

  // 2. Encode auctionId + bidHash for on-chain registration
  const reportData = encodeAbiParameters(
    parseAbiParameters("bytes32 auctionId, bytes32 bidHash"),
    [result.auctionId as `0x${string}`, result.bidHash as `0x${string}`]
  )

  // 3. Get DON-signed report
  const reportResponse = runtime
    .report({
      encodedPayload: hexToBase64(reportData),
      encoderName: "evm",
      signingAlgo: "ecdsa",
      hashingAlgo: "keccak256",
    })
    .result()

  // 4. Submit via EVMClient.writeReport → KeystoneForwarder → onReport → _registerBid
  const network = getNetwork({ chainFamily: "evm", chainSelectorName, isTestnet: true })
  if (!network) throw new Error(`Network not found: ${chainSelectorName}`)
  const evmClient = new EVMClient(network.chainSelector.selector)

  const writeResult = evmClient
    .writeReport(runtime, {
      receiver: contractAddress,
      report: reportResponse,
      gasConfig: { gasLimit },
    })
    .result()

  if (writeResult.txStatus !== TxStatus.SUCCESS) {
    throw new Error(`registerBid tx failed: ${writeResult.txStatus}`)
  }

  const txHash = bytesToHex(writeResult.txHash || new Uint8Array(32))
  runtime.log(`registerBid submitted: ${txHash}`)
  return txHash
}

const initWorkflow = (config: Config) => [
  handler(
    new HTTPCapability().trigger({}),
    onBidSubmit
  ),
]

export async function main() {
  const runner = await Runner.newRunner<Config>({ configSchema })
  await runner.run(initWorkflow)
}
