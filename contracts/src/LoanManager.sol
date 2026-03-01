//SPDX-License-Identifier:MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ReceiverTemplate} from "./ReceiverTemplate.sol";
// Note: Ownable is inherited via ReceiverTemplate
import {ILendingPool} from "./interfaces/ILendingPool.sol";
import {IPropertyNFT} from "./interfaces/IPropertyNFT.sol";
import {ILienFiAuction} from "./interfaces/ILienFiAuction.sol";

/**
 * @title LoanManager
 * @author LienFi Team
 *
 * The single contract that owns the complete mortgage lifecycle:
 *   Phase 3: submitRequest() + _writeVerdict() — request anchoring + CRE verdict receiving
 *   Phase 4: claimLoan() + repay() + checkDefault() + onAuctionSettled() — full lifecycle
 *
 * Architecture:
 * - Inherits ReceiverTemplate — CRE reports arrive via KeystoneForwarder → onReport()
 * - _processReport() dispatches by workflowName (bytes10) to _writeVerdict()
 * - Same pattern as LienFiAuction.sol for consistency across the protocol
 *
 * Flow:
 * - Borrower anchors a loan request on-chain via requestHash
 * - LoanRequestSubmitted event auto-triggers CRE credit assessment workflow
 * - CRE writes verdict back via KeystoneForwarder → onReport → _processReport → _writeVerdict
 * - Borrower calls claimLoan() to lock NFT collateral and receive USDC
 * - Monthly repayments via repay() — full EMI to pool, exchange rate rises
 * - 3 consecutive missed payments → default → sealed-bid auction
 * - Auction settlement → pool repaid, surplus to borrower
 *
 * Privacy guarantees:
 * - No financial data ever touches this contract
 * - Only requestHash (opaque) and verdict (approve/reject + limit) are on-chain
 * - Credit score, Plaid data, Gemini reasoning all discarded in CRE enclave
 *
 * CRE workflow report encoding (credit-assessment-workflow):
 *   abi.encode(address borrower, bytes32 requestHash, bool approved,
 *              uint256 tokenId, uint256 approvedLimit, uint256 tenureMonths,
 *              uint256 computedEMI, uint256 expiresAt)
 */
contract LoanManager is ReceiverTemplate, ReentrancyGuard {
    using SafeERC20 for IERC20;
    ///////////////////
    // Workflow Name Constants (bytes10)
    ///////////////////
    // Encoding: SHA256("credit") → first 10 hex chars → hex-encode ASCII → bytes10
    // "credit" → SHA256: ecc4873a16... → ASCII hex: 0x65636334383733613136
    bytes10 private constant WORKFLOW_CREDIT = bytes10(0x65636334383733613136);

    /////////////////
    //Errors
    /////////////////
    error LoanManager__NotLienFiAuction();
    error LoanManager__ZeroAddress();
    error LoanManager__ZeroAmount();
    error LoanManager__RequestAlreadyPending();
    error LoanManager__HasActiveLoan();
    error LoanManager__NoApproval();
    error LoanManager__ApprovalExpired();
    error LoanManager__RequestHashMismatch();
    error LoanManager__LoanNotFound();
    error LoanManager__LoanNotActive();
    error LoanManager__NotBorrower();
    error LoanManager__PaymentNotOverdue();
    error LoanManager__LoanNotDefaulted();
    error LoanManager__NoPendingRequest();
    error LoanManager__UnknownWorkflow(bytes10 workflowName);

    ///////////////////
    // Type Declarations
    ////////////////////
    enum LoanStatus {
        ACTIVE,
        DEFAULTED,
        CLOSED
    }

    /**
     * @notice CRE-written approval stored after credit assessment.
     * @dev Consumed by claimLoan() — single-use, cleared after claim.
     *      tokenId is included so claimLoan() reads all values from the approval
     *      with zero user-supplied parameters beyond requestHash.
     */
    struct Approval {
        bytes32 requestHash; // tamper-proof link to exact assessed request
        uint256 tokenId; // PropertyNFT to lock as collateral
        uint256 approvedLimit; // max USDC borrowable (6 decimals)
        uint256 tenureMonths; // approved loan tenure
        uint256 computedEMI; // monthly payment (6 decimals), computed in enclave
        uint256 expiresAt; // approval validity window (unix timestamp)
        bool exists;
    }

    /**
     * @notice On-chain loan record — created by claimLoan(), updated by repay()/checkDefault().
     */
    struct Loan {
        uint256 loanId;
        address borrower;
        uint256 tokenId; // PropertyNFT locked as collateral
        uint256 principal; // USDC disbursed (6 decimals)
        uint256 interestRateBps; // annual rate e.g. 800 = 8%
        uint256 tenureMonths;
        uint256 emiAmount; // fixed monthly payment (6 decimals)
        uint256 nextDueDate; // unix timestamp of next payment due
        uint256 missedPayments; // consecutive missed payment counter
        uint256 remainingPrincipal; // outstanding balance (6 decimals)
        LoanStatus status;
    }

    ///////////////////
    // Constants
    ///////////////////
    uint256 public constant EMI_PERIOD = 30 days; //30days in secs
    uint256 public constant DEFAULT_THRESHOLD = 3; //missed payments before default
    uint256 public constant AUCTION_DURATION = 7 days; //auction duration in secs
    uint256 public constant BPS_DENOMINATOR = 10_000; //basis points denominator for interest rate calculations (10000 = 100%)

    ///////////////////
    // State Variables
    ///////////////////
    ILendingPool public immutable lendingPool;
    IPropertyNFT public immutable propertyNFT;
    ILienFiAuction public immutable lienFiAuction;
    IERC20 public immutable usdc;

    uint256 public interestRateBps; //annual interest rate in basis points (e.g. 800 = 8%)

    mapping(address => bytes32) public pendingRequests;
    mapping(address => Approval) public pendingApprovals;
    mapping(uint256 => Loan) public loans; // loanId → Loan
    mapping(address => uint256) public borrowerActiveLoan; // borrower → active loanId (0 if none)
    mapping(uint256 => uint256) public tokenIdToLoanId;

    uint256 public loanCounter; //Auto-incrementing loan ID counter (starts at 1, 0 = no loan)

    ///////////////////
    // Events
    ///////////////////
    event LoanRequestSubmitted(address indexed borrower, bytes32 requestHash);
    event LoanRequestApproved(
        address indexed borrower,
        bytes32 requestHash,
        uint256 approvedLimit,
        uint256 tenureMonths,
        uint256 computedEMI
    );
    event LoanRequestRejected(address indexed borrower, bytes32 requestHash);
    event LoanOriginated(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 tokenId,
        uint256 principal,
        uint256 emiAmount,
        uint256 tenureMonths
    );
    event RepaymentMade(
        uint256 indexed loanId,
        uint256 emiAmount,
        uint256 remainingPrincipal
    );
    event LoanClosed(uint256 indexed loanId);
    event PaymentMissed(uint256 indexed loanId, uint256 missedPayments);
    event LoanDefaulted(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 tokenId,
        uint256 remainingPrincipal
    );
    event LoanLiquidated(
        uint256 indexed loanId,
        uint256 proceeds,
        uint256 remainingPrincipal
    );

    ///////////////////
    // Modifiers
    ////////////////////

    modifier onlyLienFiAuction() {
        if (msg.sender != address(lienFiAuction))
            revert LoanManager__NotLienFiAuction();
        _;
    }

    //////////////////
    // Constructor
    ///////////////////
    /**
     * @param _forwarder CRE KeystoneForwarder address (passed to ReceiverTemplate)
     * @param _lendingPool LendingPool contract address
     * @param _propertyNFT PropertyNFT contract address
     * @param _lienFiAuction LienFiAuction contract address
     * @param _usdc USDC token address
     * @param _interestRateBps Annual interest rate in basis points (e.g. 800 = 8%)
     */
    constructor(
        address _forwarder,
        address _lendingPool,
        address _propertyNFT,
        address _lienFiAuction,
        address _usdc,
        uint256 _interestRateBps
    ) ReceiverTemplate(_forwarder) {
        if (
            _lendingPool == address(0) ||
            _propertyNFT == address(0) ||
            _lienFiAuction == address(0) ||
            _usdc == address(0)
        ) revert LoanManager__ZeroAddress();

        lendingPool = ILendingPool(_lendingPool);
        propertyNFT = IPropertyNFT(_propertyNFT);
        lienFiAuction = ILienFiAuction(_lienFiAuction);
        usdc = IERC20(_usdc);
        interestRateBps = _interestRateBps;
    }

    /**
     * @notice Dispatches CRE reports to the correct handler using workflowName from metadata.
     * @dev Called by ReceiverTemplate.onReport() after forwarder validation.
     *      Currently handles one workflow:
     *        "credit" → _writeVerdict (credit assessment result)
     *
     *      Encoding matches LienFiAuction pattern:
     *        SHA256("credit") → first 10 hex chars → hex-encode ASCII → bytes10
     */
    function _processReport(
        bytes calldata metadata,
        bytes calldata report
    ) internal override {
        (, bytes10 workflowName, ) = _decodeMetadata(metadata);

        if (workflowName == WORKFLOW_CREDIT) {
            _writeVerdict(report);
        } else {
            revert LoanManager__UnknownWorkflow(workflowName);
        }
    }

    /**
     * @notice Anchor a loan request on-chain. Emits event that triggers CRE assessment.
     * @dev Borrower first POSTs full request to API (gets requestHash back),
     *      then calls this function with that requestHash.
     *
     *      Flow:
     *        1. Borrower → API: POST /loanRequest { plaidToken, tokenId, amount, tenure }
     *        2. API computes requestHash = keccak256(borrower + tokenId + amount + tenure + nonce)
     *        3. API returns requestHash to borrower
     *        4. Borrower → this function: submitRequest(requestHash)
     *        5. Event emitted → CRE auto-triggered → assessment → _writeVerdict()
     *
     *      Rejects if:
     *        - Borrower already has a pending request
     *        - Borrower already has an active loan
     *
     * @param requestHash The hash received from the API, anchoring the off-chain request
     */
    function submitRequest(bytes32 requestHash) external {
        if (pendingRequests[msg.sender] != bytes32(0))
            revert LoanManager__RequestAlreadyPending();
        if (borrowerActiveLoan[msg.sender] != 0)
            revert LoanManager__HasActiveLoan();

        pendingRequests[msg.sender] = requestHash;

        emit LoanRequestSubmitted(msg.sender, requestHash);
    }

    /**
     * @notice Process credit assessment verdict from CRE workflow.
     * @dev Reached via: KeystoneForwarder → onReport → _processReport → _writeVerdict
     *
     *      The CRE credit-assessment-workflow:
     *        1. Fetched request details from API DB using requestHash
     *        2. Verified hash integrity (recomputed and matched on-chain hash)
     *        3. Fetched Plaid financial data via Confidential HTTP
     *        4. Ran hard gates (LTV ≤ 80%, coverage ≥ 3×, no recent defaults)
     *        5. Sent metrics to Gemini for scoring
     *        6. Checked LendingPool.availableLiquidity() ≥ approvedAmount
     *        7. Encoded verdict into this report
     *
     *      All raw financial data is discarded in the enclave. Only the verdict
     *      (approve/reject + limit) reaches the chain.
     *
     *      Report encoding (approved):
     *        abi.encode(borrower, requestHash, true, tokenId, approvedLimit, tenureMonths, computedEMI, expiresAt)
     *      Report encoding (rejected):
     *        abi.encode(borrower, requestHash, false, 0, 0, 0, 0, 0)
     *
     * @param report ABI-encoded verdict from CRE workflow
     */
    function _writeVerdict(bytes calldata report) internal {
        (
            address borrower,
            bytes32 requestHash,
            bool approved,
            uint256 tokenId,
            uint256 approvedLimit,
            uint256 tenureMonths,
            uint256 computedEMI,
            uint256 expiresAt
        ) = abi.decode(
                report,
                (
                    address,
                    bytes32,
                    bool,
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    uint256
                )
            );

        if (pendingRequests[borrower] == bytes32(0))
            revert LoanManager__NoPendingRequest();
        if (pendingRequests[borrower] != requestHash)
            revert LoanManager__RequestHashMismatch();

        delete pendingRequests[borrower];

        if (approved) {
            pendingApprovals[borrower] = Approval({
                requestHash: requestHash,
                tokenId: tokenId,
                approvedLimit: approvedLimit,
                tenureMonths: tenureMonths,
                computedEMI: computedEMI,
                expiresAt: expiresAt,
                exists: true
            });

            emit LoanRequestApproved(
                borrower,
                requestHash,
                approvedLimit,
                tenureMonths,
                computedEMI
            );
        } else {
            emit LoanRequestRejected(borrower, requestHash);
        }
    }

    /**
     * @notice Activate an approved loan. Lock PropertyNFT, receive USDC.
     * @dev Borrower calls this after CRE has written an approval via _writeVerdict().
     *      ALL loan parameters are read from the stored approval — no user-supplied
     *      values beyond requestHash (which acts as a claim ticket).
     *
     *      The liquidity check was already performed by the CRE workflow before
     *      writing the approval. claimLoan() does NOT re-check liquidity.
     *      This is safe because:
     *        - The approval has an expiry window (expiresAt)
     *        - If liquidity dried up between approval and claim, disburse() will revert
     *        - The CRE check prevents most race conditions; disburse() catches the rest
     *
     *      Flow:
     *        1. Load approval — must exist and not be expired
     *        2. Verify requestHash matches (proves borrower is claiming the right approval)
     *        3. Check no active loan
     *        4. Read all values from approval (tokenId, amount, tenure, EMI)
     *        5. Transfer PropertyNFT from borrower → LoanManager (collateral lock)
     *        6. Clear approval (single-use)
     *        7. Disburse USDC from pool to borrower
     *        8. Create loan record
     *
     * @param requestHash The request hash that links to the approval being claimed
     */
    function claimLoan(bytes32 requestHash) external nonReentrant {
        Approval memory approval = pendingApprovals[msg.sender];

        // 1. Approval must exist
        if (!approval.exists) revert LoanManager__NoApproval();

        // 2. Must not be expired
        if (block.timestamp > approval.expiresAt)
            revert LoanManager__ApprovalExpired();

        // 3. RequestHash must match
        if (approval.requestHash != requestHash)
            revert LoanManager__RequestHashMismatch();

        // 4. No active loan
        if (borrowerActiveLoan[msg.sender] != 0)
            revert LoanManager__HasActiveLoan();

        // 5. Read all values from approval
        uint256 tokenId = approval.tokenId;
        uint256 principal = approval.approvedLimit;
        uint256 tenureMonths = approval.tenureMonths;
        uint256 emiAmount = approval.computedEMI;

        // 6. Clear approval — single-use
        delete pendingApprovals[msg.sender];

        // 7. Lock PropertyNFT as collateral (borrower must have approved LoanManager)
        propertyNFT.transferFrom(msg.sender, address(this), tokenId);

        // 8. Create loan record
        loanCounter++;
        uint256 loanId = loanCounter;

        loans[loanId] = Loan({
            loanId: loanId,
            borrower: msg.sender,
            tokenId: tokenId,
            principal: principal,
            interestRateBps: interestRateBps,
            tenureMonths: tenureMonths,
            emiAmount: emiAmount,
            nextDueDate: block.timestamp + EMI_PERIOD,
            missedPayments: 0,
            remainingPrincipal: principal,
            status: LoanStatus.ACTIVE
        });

        borrowerActiveLoan[msg.sender] = loanId;
        tokenIdToLoanId[tokenId] = loanId;

        // 9. Disburse USDC from pool to borrower
        // If pool doesn't have enough liquidity, disburse() reverts — safety net
        lendingPool.disburse(msg.sender, principal);

        emit LoanOriginated(
            loanId,
            msg.sender,
            tokenId,
            principal,
            emiAmount,
            tenureMonths
        );
    }

    /**
     * @notice Make a monthly EMI payment on an active loan.
     * @dev Accepts exactly emiAmount USDC from the borrower.
     *      Computes principal vs interest split for internal accounting.
     *      Full EMI goes to pool — interest portion causes clUSDC exchange rate to rise.
     *
     *      Interest calculation (standard amortization):
     *        interestPortion = remainingPrincipal × (annualRate / 10000 / 12)
     *        principalPortion = emiAmount - interestPortion
     *
     *      The USDC transfer flow (Pattern A from Phase 2):
     *        1. This function transfers USDC from borrower → LendingPool
     *        2. Then calls lendingPool.repayEMI() for accounting only
     *        (Borrower only needs to approve LoanManager, not LendingPool)
     *
     *      On final payment (remainingPrincipal reaches 0):
     *        - Loan status → CLOSED
     *        - PropertyNFT returned to borrower
     *        - borrowerActiveLoan cleared
     *
     * @param loanId The ID of the loan to repay
     */
    function repay(uint256 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];

        if (loan.loanId == 0) revert LoanManager__LoanNotFound();
        if (loan.status != LoanStatus.ACTIVE)
            revert LoanManager__LoanNotActive();
        if (msg.sender != loan.borrower) revert LoanManager__NotBorrower();

        uint256 emiAmount = loan.emiAmount;

        // Compute interest/principal split
        // interestPortion = remainingPrincipal * interestRateBps / (BPS_DENOMINATOR * 12)
        uint256 interestPortion = (loan.remainingPrincipal * interestRateBps) /
            (BPS_DENOMINATOR * 12);
        uint256 principalPortion = emiAmount - interestPortion;

        // Handle final payment — if remaining principal is less than or equal to
        // the computed principal portion, this is the last payment
        if (principalPortion >= loan.remainingPrincipal) {
            principalPortion = loan.remainingPrincipal;
        }

        // Reduce remaining principal
        loan.remainingPrincipal -= principalPortion;

        // Reset missed payments counter (on-time payment)
        loan.missedPayments = 0;

        // Advance next due date
        loan.nextDueDate += EMI_PERIOD;

        // Transfer USDC from borrower → LendingPool (Pattern A)
        usdc.safeTransferFrom(msg.sender, address(lendingPool), emiAmount);

        // Update pool accounting
        lendingPool.repayEMI(emiAmount, principalPortion);

        emit RepaymentMade(loanId, emiAmount, loan.remainingPrincipal);

        // Check if loan is fully repaid
        if (loan.remainingPrincipal == 0) {
            _closeLoan(loanId);
        }
    }

    /**
     * @notice Check if a loan payment is overdue and record missed payment.
     * @dev Callable by anyone (keeper, cron, frontend). Permissionless.
     *
     *      Logic:
     *        - Loan must be ACTIVE and current time must be past nextDueDate
     *        - Increments missedPayments counter
     *        - Advances nextDueDate by 30 days (tracks next potential miss)
     *        - If missedPayments >= 3: triggers default + sealed-bid auction
     *
     *      Can only be called once per overdue period. After incrementing,
     *      nextDueDate advances so the function can't be called again until
     *      another 30 days pass.
     *
     * @param loanId The ID of the loan to check
     */
    function checkDefault(uint256 loanId) external {
        Loan storage loan = loans[loanId];

        if (loan.loanId == 0) revert LoanManager__LoanNotFound();
        if (loan.status != LoanStatus.ACTIVE)
            revert LoanManager__LoanNotActive();
        if (block.timestamp <= loan.nextDueDate)
            revert LoanManager__PaymentNotOverdue();

        // Increment missed payment counter
        loan.missedPayments++;

        // Advance nextDueDate to track next potential miss
        loan.nextDueDate += EMI_PERIOD;

        emit PaymentMissed(loanId, loan.missedPayments);

        // 3 strikes → default
        if (loan.missedPayments >= DEFAULT_THRESHOLD) {
            _triggerDefault(loanId);
        }
    }

    /**
     * @notice Callback from LienFiAuction after auction settles. LienFiAuction only.
     * @dev Called by LienFiAuction._settleAuction() after NFT is transferred to winner.
     *      Handles fund distribution:
     *        - proceeds >= debt: full repayment to pool, surplus to borrower
     *        - proceeds < debt: partial repayment, shortfall absorbed by pool
     *
     *      The USDC transfer flow:
     *        - LienFiAuction transfers `proceeds` USDC to this contract before calling
     *        - This function routes USDC to pool (and surplus to borrower if applicable)
     *
     * @param tokenId The PropertyNFT tokenId that was auctioned
     * @param proceeds The USDC amount from auction settlement (6 decimals)
     */
    function onAuctionSettled(
        uint256 tokenId,
        uint256 proceeds
    ) external onlyLienFiAuction nonReentrant {
        uint256 loanId = tokenIdToLoanId[tokenId];
        Loan storage loan = loans[loanId];

        if (loan.loanId == 0) revert LoanManager__LoanNotFound();
        if (loan.status != LoanStatus.DEFAULTED)
            revert LoanManager__LoanNotDefaulted();

        uint256 debt = loan.remainingPrincipal;

        if (proceeds >= debt) {
            // Full recovery — repay entire debt to pool
            usdc.safeTransfer(address(lendingPool), debt);
            lendingPool.repayEMI(debt, debt);

            uint256 surplus = proceeds - debt;
            if (surplus > 0) {
                usdc.safeTransfer(loan.borrower, surplus);
            }
        } else {
            usdc.safeTransfer(address(lendingPool), proceeds);
            lendingPool.repayEMI(proceeds, proceeds);
        }

        emit LoanLiquidated(loanId, proceeds, debt);

        // Close loan record
        loan.status = LoanStatus.CLOSED;
        loan.remainingPrincipal = 0;
        delete borrowerActiveLoan[loan.borrower];
        delete tokenIdToLoanId[tokenId];
    }

    /// @notice Mint a PropertyNFT for the caller. Called after off-chain property verification.
    /// @dev The borrower first calls POST /verify-property on the API, which:
    ///        1. Verifies property documents inside CRE enclave
    ///        2. Computes commitmentHash = keccak256(address + value + docs + secret)
    ///        3. Stores full details in enclave (never on-chain)
    ///        4. Returns commitmentHash to borrower
    ///      Borrower then calls this function with the commitmentHash.
    ///      The NFT is minted to the borrower — they own it until they lock it via claimLoan().
    /// @param commitmentHash The keccak256 hash of property details (computed by CRE)
    /// @return tokenId The minted PropertyNFT token ID
    function mintPropertyNFT(
        bytes32 commitmentHash
    ) external returns (uint256 tokenId) {
        tokenId = propertyNFT.mint(msg.sender, commitmentHash);
    }

    // ═══════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Trigger default on a loan after 3 missed payments.
     * @dev Transfers PropertyNFT to LienFiAuction and initiates default auction.
     *      Reserve price = remaining principal (minimum acceptable bid).
     *      AuctionId = keccak256(tokenId, loanId) — unique per default event.
     *      Deadline = current time + AUCTION_DURATION (7 days).
     */
    function _triggerDefault(uint256 loanId) internal {
        Loan storage loan = loans[loanId];

        loan.status = LoanStatus.DEFAULTED;

        uint256 tokenId = loan.tokenId;
        uint256 reservePrice = loan.remainingPrincipal;

        propertyNFT.transferFrom(
            address(this),
            address(lienFiAuction),
            tokenId
        );

        bytes32 auctionId = keccak256(abi.encodePacked(tokenId, loanId));

        lienFiAuction.initiateDefaultAuction(
            tokenId,
            reservePrice,
            auctionId,
            block.timestamp + AUCTION_DURATION
        );

        emit LoanDefaulted(loanId, loan.borrower, tokenId, reservePrice);
    }

    /**
     * @notice Close a fully repaid loan — return NFT and clean up state.
     */
    function _closeLoan(uint256 loanId) internal {
        Loan storage loan = loans[loanId];

        loan.status = LoanStatus.CLOSED;
        propertyNFT.transferFrom(address(this), loan.borrower, loan.tokenId);

        delete borrowerActiveLoan[loan.borrower];
        delete tokenIdToLoanId[loan.tokenId];

        emit LoanClosed(loanId);
    }

    // ═══════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Update the interest rate. Owner only.
     * @dev Only affects NEW loans. Existing loans keep their rate.
     */
    function setInterestRate(uint256 _interestRateBps) external onlyOwner {
        interestRateBps = _interestRateBps;
    }

    // ═══════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /**
     * @notice Get full loan details.
     */
    function getLoan(uint256 loanId) external view returns (Loan memory) {
        return loans[loanId];
    }

    /**
     * @notice Get the active loan ID for a borrower (0 = no active loan).
     */
    function getActiveLoanId(address borrower) external view returns (uint256) {
        return borrowerActiveLoan[borrower];
    }

    /**
     * @notice Get pending approval for a borrower.
     */
    function getApproval(
        address borrower
    ) external view returns (Approval memory) {
        return pendingApprovals[borrower];
    }

    /**
     * @notice Check if a borrower has a pending request.
     */
    function hasPendingRequest(address borrower) external view returns (bool) {
        return pendingRequests[borrower] != bytes32(0);
    }
}
