import {
  EVMClient,
  ConfidentialHTTPClient,
  getNetwork,
  encodeCallMsg,
  hexToBase64,
  bytesToHex,
  LAST_FINALIZED_BLOCK_NUMBER,
  TxStatus,
  handler,
  consensusIdenticalAggregation,
  ok,
  json,
  type ConfidentialHTTPSendRequester,
  type Runtime,
  Runner,
  type EVMLog,
} from "@chainlink/cre-sdk"
import {
  encodeAbiParameters,
  parseAbiParameters,
  encodeFunctionData,
  decodeFunctionResult,
  keccak256,
  toBytes,
  getAddress,
  type Address,
  type Abi,
  zeroAddress,
} from "viem"
import { z } from "zod"

// ─── Config ──────────────────────────────────────────────────────────────────

const configSchema = z.object({
  url: z.string(),
  owner: z.string(),
  evms: z.array(
    z.object({
      chainSelectorName: z.string(),
      loanManagerAddress: z.string(),
      lendingPoolAddress: z.string(),
      gasLimit: z.string(),
    })
  ),
  interestRateBps: z.number(), // e.g. 800 = 8% annual
})
type Config = z.infer<typeof configSchema>

// ─── Event signature ─────────────────────────────────────────────────────────

const LOAN_REQUEST_SUBMITTED_TOPIC = keccak256(
  toBytes("LoanRequestSubmitted(address,bytes32)")
)

// ─── LendingPool ABI (minimal — read only) ──────────────────────────────────

const LendingPoolABI: Abi = [
  {
    type: "function",
    name: "availableLiquidity",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
]

// ─── Types ───────────────────────────────────────────────────────────────────

type LoanRequestDetails = {
  requestHash: string
  borrowerAddress: string
  plaidToken: string
  tokenId: number
  requestedAmount: string
  tenureMonths: number
  nonce: number
  timestamp: number
  appraisedValueUsd: number
}

type PlaidMetrics = {
  monthlyIncome: number
  dti: number
  stabilityScore: number
  overdraftRate: number
  hasRecentDefaults: boolean
}

type AnthropicVerdict = {
  creditScore: number
  verdict: "approve" | "reject"
  approvedAmount: string
  reason: string
}

// ─── Confidential HTTP helpers ───────────────────────────────────────────────

/**
 * Fetch loan request details from LienFi API via Confidential HTTP.
 */
const fetchLoanRequest = (
  sendRequester: ConfidentialHTTPSendRequester,
  config: Config,
  requestHash: string
): LoanRequestDetails => {
  const response = sendRequester
    .sendRequest({
      request: {
        url: `${config.url}/loan-request/${requestHash}`,
        method: "GET",
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
    throw new Error(`Loan request API failed: ${response.statusCode}`)
  }
  return json(response) as LoanRequestDetails
}

/**
 * Fetch financial data from Plaid Sandbox API via Confidential HTTP.
 * Returns pre-processed metrics only — raw data is never persisted.
 */
const fetchPlaidData = (
  sendRequester: ConfidentialHTTPSendRequester,
  config: Config,
  plaidToken: string
): PlaidMetrics => {
  // Step 1: Fetch transactions from Plaid Sandbox
  const txnBody = JSON.stringify({
    client_id: "{{.plaidClientId}}",
    secret: "{{.plaidSecret}}",
    access_token: plaidToken,
    start_date: new Date(Date.now() - 365 * 24 * 60 * 60 * 1000).toISOString().split("T")[0],
    end_date: new Date().toISOString().split("T")[0],
  })

  const txnResponse = sendRequester
    .sendRequest({
      request: {
        url: "https://sandbox.plaid.com/transactions/get",
        method: "POST",
        bodyString: txnBody,
        multiHeaders: {
          "Content-Type": { values: ["application/json"] },
        },
      },
      vaultDonSecrets: [
        { key: "plaidClientId", owner: config.owner },
        { key: "plaidSecret", owner: config.owner },
        { key: "san_marino_aes_gcm_encryption_key", owner: config.owner },
      ],
    })
    .result()

  if (!ok(txnResponse)) {
    throw new Error(`Plaid transactions API failed: ${txnResponse.statusCode}`)
  }

  const txnData = json(txnResponse) as {
    transactions: Array<{ amount: number; date: string; category: string[] }>
    accounts: Array<{ balances: { current: number } }>
  }

  // Step 2: Pre-process into clean metrics
  const transactions = txnData.transactions
  const totalIncome = transactions
    .filter((t) => t.amount < 0) // Plaid: negative = income
    .reduce((sum, t) => sum + Math.abs(t.amount), 0)

  const months = 12
  const monthlyIncome = totalIncome / months

  const totalDebt = transactions
    .filter((t) => t.category?.includes("Loan") || t.category?.includes("Credit Card"))
    .reduce((sum, t) => sum + t.amount, 0)
  const dti = monthlyIncome > 0 ? (totalDebt / months) / monthlyIncome : 1

  const overdraftTxns = transactions.filter((t) =>
    t.category?.includes("Overdraft")
  )
  const overdraftRate = transactions.length > 0 ? overdraftTxns.length / transactions.length : 0

  const hasRecentDefaults = transactions.some(
    (t) => t.category?.includes("Default") || t.category?.includes("Collection")
  )

  // Stability: consistent income across months (simplified)
  const stabilityScore = monthlyIncome > 0 ? Math.min(1, monthlyIncome / 5000) : 0

  return {
    monthlyIncome,
    dti,
    stabilityScore,
    overdraftRate,
    hasRecentDefaults,
  }
}

/**
 * Call Anthropic Messages API for credit scoring via Confidential HTTP.
 * Sends only pre-processed metrics — never raw financial data.
 */
const callAnthropicScoring = (
  sendRequester: ConfidentialHTTPSendRequester,
  config: Config,
  metrics: {
    monthlyIncome: number
    emi: number
    coverage: number
    dti: number
    ltv: number
    stabilityScore: number
    overdraftRate: number
    requestedAmount: string
  }
): AnthropicVerdict => {
  const prompt = `You are a mortgage credit scoring AI. Based on these financial metrics, provide a credit assessment.

Metrics:
- Monthly Income: $${metrics.monthlyIncome.toFixed(2)}
- Monthly EMI: $${metrics.emi.toFixed(2)}
- Income Coverage Ratio: ${metrics.coverage.toFixed(2)}×
- Debt-to-Income Ratio: ${(metrics.dti * 100).toFixed(1)}%
- Loan-to-Value Ratio: ${(metrics.ltv * 100).toFixed(1)}%
- Income Stability Score: ${(metrics.stabilityScore * 100).toFixed(0)}%
- Overdraft Rate: ${(metrics.overdraftRate * 100).toFixed(1)}%
- Requested Amount: $${(Number(metrics.requestedAmount) / 1e6).toFixed(2)}

Respond ONLY with valid JSON (no markdown, no explanation):
{
  "creditScore": <number 300-850>,
  "verdict": "approve" or "reject",
  "approvedAmount": "<USDC 6-decimal string, 0 if rejected>",
  "reason": "<one sentence>"
}`

  const body = JSON.stringify({
    model: "claude-sonnet-4-6",
    max_tokens: 256,
    messages: [
      {
        role: "user",
        content: prompt,
      },
    ],
  })

  const response = sendRequester
    .sendRequest({
      request: {
        url: "https://api.anthropic.com/v1/messages",
        method: "POST",
        bodyString: body,
        multiHeaders: {
          "Content-Type": { values: ["application/json"] },
          "x-api-key": { values: ["{{.anthropicApiKey}}"] },
          "anthropic-version": { values: ["2023-06-01"] },
        },
      },
      vaultDonSecrets: [
        { key: "anthropicApiKey", owner: config.owner },
        { key: "san_marino_aes_gcm_encryption_key", owner: config.owner },
      ],
    })
    .result()

  if (!ok(response)) {
    throw new Error(`Anthropic API failed: ${response.statusCode}`)
  }

  const apiResult = json(response) as {
    content: Array<{ type: string; text: string }>
  }
  const textContent = apiResult.content.find((c) => c.type === "text")
  if (!textContent) {
    throw new Error("Anthropic response missing text content")
  }

  return JSON.parse(textContent.text) as AnthropicVerdict
}

// ─── EMI computation ─────────────────────────────────────────────────────────

/**
 * EMI = P × r × (1+r)^n / ((1+r)^n - 1)
 * @param principal USDC 6-decimal string
 * @param annualBps annual interest rate in bps (e.g. 800 = 8%)
 * @param tenureMonths loan tenure in months
 * @returns EMI as a number (USDC 6-decimal scale)
 */
function computeEMI(principal: string, annualBps: number, tenureMonths: number): number {
  const P = Number(principal)
  const r = annualBps / 10000 / 12
  if (r === 0) return P / tenureMonths
  const factor = Math.pow(1 + r, tenureMonths)
  return (P * r * factor) / (factor - 1)
}

// ─── Main handler ────────────────────────────────────────────────────────────

const onLoanRequestSubmitted = (runtime: Runtime<Config>, log: EVMLog): string => {
  const { loanManagerAddress, lendingPoolAddress, chainSelectorName, gasLimit } =
    runtime.config.evms[0]

  // 1. DECODE EVENT from EVMLog
  //    topics[0] = event signature (already matched by trigger)
  //    topics[1] = borrower address (indexed, left-padded to 32 bytes)
  //    topics[2] = requestHash (indexed, bytes32)
  const borrower = getAddress(
    bytesToHex(log.topics[1].slice(12)) // last 20 bytes = address
  )
  const requestHash = bytesToHex(log.topics[2])

  runtime.log(`LoanRequestSubmitted: borrower=${borrower} requestHash=${requestHash}`)

  // 2. FETCH LOAN REQUEST via Confidential HTTP
  const confHTTPClient = new ConfidentialHTTPClient()

  const details = confHTTPClient
    .sendRequest(
      runtime,
      fetchLoanRequest,
      consensusIdenticalAggregation<LoanRequestDetails>()
    )(runtime.config, requestHash)
    .result()

  runtime.log(
    `Fetched request: tokenId=${details.tokenId} amount=${details.requestedAmount} tenure=${details.tenureMonths}`
  )

  // 3. VERIFY HASH INTEGRITY — recompute and compare
  const recomputed = keccak256(
    encodeAbiParameters(
      parseAbiParameters("address, uint256, uint256, uint256, uint256"),
      [
        details.borrowerAddress as Address,
        BigInt(details.tokenId),
        BigInt(details.requestedAmount),
        BigInt(details.tenureMonths),
        BigInt(details.nonce),
      ]
    )
  )

  if (recomputed !== requestHash) {
    throw new Error(
      `Hash mismatch: computed=${recomputed} vs on-chain=${requestHash}`
    )
  }

  runtime.log("Hash integrity verified")

  // 4. COMPUTE EMI
  const emi = computeEMI(
    details.requestedAmount,
    runtime.config.interestRateBps,
    details.tenureMonths
  )

  runtime.log(`Computed EMI: ${emi.toFixed(0)} (${(emi / 1e6).toFixed(2)} USDC/mo)`)

  // 5. HARD RULE GATE: LTV ≤ 80%
  const appraisedValueUsdc = details.appraisedValueUsd * 1e6 // convert USD to USDC 6-decimal
  const ltv = Number(details.requestedAmount) / appraisedValueUsdc

  if (ltv > 0.8) {
    runtime.log(`REJECTED: LTV ${(ltv * 100).toFixed(1)}% exceeds 80% limit`)
    return writeVerdict(runtime, {
      borrower,
      requestHash,
      tokenId: details.tokenId,
      approvedLimit: "0",
      tenureMonths: details.tenureMonths,
      computedEMI: Math.floor(emi).toString(),
      approved: false,
    })
  }

  // 6. FETCH PLAID DATA via Confidential HTTP
  const plaidMetrics = confHTTPClient
    .sendRequest(
      runtime,
      fetchPlaidData,
      consensusIdenticalAggregation<PlaidMetrics>()
    )(runtime.config, details.plaidToken)
    .result()

  runtime.log(
    `Plaid metrics: income=$${plaidMetrics.monthlyIncome.toFixed(0)}/mo DTI=${(plaidMetrics.dti * 100).toFixed(1)}% stability=${(plaidMetrics.stabilityScore * 100).toFixed(0)}%`
  )

  // 7. HARD RULE GATES (post-Plaid)
  const incomeCoverage = plaidMetrics.monthlyIncome / emi

  if (incomeCoverage < 3) {
    runtime.log(`REJECTED: Income coverage ${incomeCoverage.toFixed(2)}× below 3× minimum`)
    return writeVerdict(runtime, {
      borrower,
      requestHash,
      tokenId: details.tokenId,
      approvedLimit: "0",
      tenureMonths: details.tenureMonths,
      computedEMI: Math.floor(emi).toString(),
      approved: false,
    })
  }

  if (plaidMetrics.hasRecentDefaults) {
    runtime.log("REJECTED: Defaults detected in last 12 months")
    return writeVerdict(runtime, {
      borrower,
      requestHash,
      tokenId: details.tokenId,
      approvedLimit: "0",
      tenureMonths: details.tenureMonths,
      computedEMI: Math.floor(emi).toString(),
      approved: false,
    })
  }

  // 8. CALL ANTHROPIC AI for credit scoring via Confidential HTTP
  const aiVerdict = confHTTPClient
    .sendRequest(
      runtime,
      callAnthropicScoring,
      consensusIdenticalAggregation<AnthropicVerdict>()
    )(runtime.config, {
      monthlyIncome: plaidMetrics.monthlyIncome,
      emi,
      coverage: incomeCoverage,
      dti: plaidMetrics.dti,
      ltv,
      stabilityScore: plaidMetrics.stabilityScore,
      overdraftRate: plaidMetrics.overdraftRate,
      requestedAmount: details.requestedAmount,
    })
    .result()

  runtime.log(
    `Anthropic verdict: score=${aiVerdict.creditScore} verdict=${aiVerdict.verdict} approved=${aiVerdict.approvedAmount} reason="${aiVerdict.reason}"`
  )

  if (aiVerdict.verdict === "reject") {
    return writeVerdict(runtime, {
      borrower,
      requestHash,
      tokenId: details.tokenId,
      approvedLimit: "0",
      tenureMonths: details.tenureMonths,
      computedEMI: Math.floor(emi).toString(),
      approved: false,
    })
  }

  // 9. LIQUIDITY CHECK — EVM Read on LendingPool
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName,
    isTestnet: true,
  })
  if (!network) throw new Error(`Network not found: ${chainSelectorName}`)

  const evmClient = new EVMClient(network.chainSelector.selector)

  const liquidityCallData = encodeFunctionData({
    abi: LendingPoolABI,
    functionName: "availableLiquidity",
  })

  const liquidityResult = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: zeroAddress,
        to: lendingPoolAddress as Address,
        data: liquidityCallData,
      }),
      blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
    })
    .result()

  const availableLiquidity = decodeFunctionResult({
    abi: LendingPoolABI,
    functionName: "availableLiquidity",
    data: bytesToHex(liquidityResult.data),
  }) as bigint

  const approvedAmountBn = BigInt(aiVerdict.approvedAmount)

  if (availableLiquidity < approvedAmountBn) {
    runtime.log(
      `REJECTED: Insufficient liquidity. Available=${availableLiquidity.toString()} Required=${aiVerdict.approvedAmount}`
    )
    return writeVerdict(runtime, {
      borrower,
      requestHash,
      tokenId: details.tokenId,
      approvedLimit: "0",
      tenureMonths: details.tenureMonths,
      computedEMI: Math.floor(emi).toString(),
      approved: false,
    })
  }

  // 10. ALL CHECKS PASSED — write approval verdict
  runtime.log("All checks passed. Writing approval verdict on-chain.")

  return writeVerdict(runtime, {
    borrower,
    requestHash,
    tokenId: details.tokenId,
    approvedLimit: aiVerdict.approvedAmount,
    tenureMonths: details.tenureMonths,
    computedEMI: Math.floor(emi).toString(),
    approved: true,
  })
}

// ─── Verdict writer ──────────────────────────────────────────────────────────

function writeVerdict(
  runtime: Runtime<Config>,
  params: {
    borrower: string
    requestHash: string
    tokenId: number
    approvedLimit: string
    tenureMonths: number
    computedEMI: string
    approved: boolean
  }
): string {
  const { loanManagerAddress, chainSelectorName, gasLimit } = runtime.config.evms[0]

  // Approval expires in 7 days
  const expiresAt = Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60

  const reportData = encodeAbiParameters(
    parseAbiParameters(
      "address borrower, bytes32 requestHash, uint256 tokenId, uint256 approvedLimit, uint256 tenureMonths, uint256 computedEMI, uint256 expiresAt, bool approved"
    ),
    [
      params.borrower as Address,
      params.requestHash as `0x${string}`,
      BigInt(params.tokenId),
      BigInt(params.approvedLimit),
      BigInt(params.tenureMonths),
      BigInt(params.computedEMI),
      BigInt(expiresAt),
      params.approved,
    ]
  )

  const reportResponse = runtime
    .report({
      encodedPayload: hexToBase64(reportData),
      encoderName: "evm",
      signingAlgo: "ecdsa",
      hashingAlgo: "keccak256",
    })
    .result()

  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName,
    isTestnet: true,
  })
  if (!network) throw new Error(`Network not found: ${chainSelectorName}`)

  const evmClient = new EVMClient(network.chainSelector.selector)

  const writeResult = evmClient
    .writeReport(runtime, {
      receiver: loanManagerAddress,
      report: reportResponse,
      gasConfig: { gasLimit },
    })
    .result()

  if (writeResult.txStatus !== TxStatus.SUCCESS) {
    throw new Error(`writeVerdict tx failed: ${writeResult.txStatus}`)
  }

  const txHash = bytesToHex(writeResult.txHash || new Uint8Array(32))
  runtime.log(
    `Verdict written: approved=${params.approved} txHash=${txHash}`
  )
  return txHash
}

// ─── Workflow init ───────────────────────────────────────────────────────────

const initWorkflow = (config: Config) => {
  const { loanManagerAddress, chainSelectorName } = config.evms[0]

  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName,
    isTestnet: true,
  })
  if (!network) throw new Error(`Network not found: ${chainSelectorName}`)

  const evmClient = new EVMClient(network.chainSelector.selector)

  return [
    handler(
      evmClient.logTrigger({
        addresses: [hexToBase64(loanManagerAddress)],
        topics: [
          { values: [hexToBase64(LOAN_REQUEST_SUBMITTED_TOPIC)] },
        ],
      }),
      onLoanRequestSubmitted
    ),
  ]
}

export async function main() {
  const runner = await Runner.newRunner<Config>({ configSchema })
  await runner.run(initWorkflow)
}
