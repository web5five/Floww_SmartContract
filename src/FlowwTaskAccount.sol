// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract FlowwTaskAccount is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    bytes32 public constant MANDATE_TYPEHASH = keccak256(
        "FlowwTaskMandateV1(uint256 chainId,bytes32 taskId,bytes32 reviewSnapshotDigest,address owner,address token,address recipient,address executor,address fulfillmentReporter,uint256 maxSpend,uint64 expiresAt)"
    );

    struct Mandate {
        bytes32 taskId;
        bytes32 reviewSnapshotDigest;
        address token;
        address recipient;
        address executor;
        address fulfillmentReporter;
        uint256 maxSpend;
        uint64 expiresAt;
    }

    address public immutable owner;
    bytes32 public immutable taskId;
    bytes32 public immutable reviewSnapshotDigest;
    bytes32 public immutable mandateHash;
    IERC20 public immutable token;
    address public immutable recipient;
    address public immutable executor;
    address public immutable fulfillmentReporter;
    uint256 public immutable maxSpend;
    uint64 public immutable expiresAt;

    bool public revoked;
    bool public paymentExecuted;
    bool public fulfillmentConfirmed;
    bytes32 public paymentId;
    bytes32 public fulfillmentEvidenceHash;
    uint256 public paidAmount;

    error UnsupportedChain(uint256 actualChainId);
    error Unauthorized();
    error InvalidMandate();
    error AuthorityInactive();
    error InvalidPayment();
    error PaymentAlreadyExecuted();
    error InsufficientAccountBalance(uint256 requested, uint256 available);
    error UnsupportedTokenBehavior();
    error PaymentNotFound();
    error InvalidFulfillmentEvidence();
    error FulfillmentAlreadyConfirmed();
    error AuthorityStillActive();

    event MandateActivated(
        bytes32 indexed taskId,
        bytes32 indexed mandateHash,
        address indexed owner,
        address token,
        address recipient,
        address executor,
        address fulfillmentReporter,
        uint256 maxSpend,
        uint64 expiresAt
    );
    event AccountFunded(address indexed owner, uint256 amount);
    event AuthorityRevoked(bytes32 indexed taskId, address indexed owner);
    event PaymentExecuted(
        bytes32 indexed taskId,
        bytes32 indexed mandateHash,
        bytes32 indexed paymentId,
        address token,
        address recipient,
        uint256 amount
    );
    event FulfillmentConfirmed(
        bytes32 indexed taskId, bytes32 indexed paymentId, bytes32 evidenceHash, address indexed reporter
    );
    event FundsRefunded(address indexed owner, uint256 amount);

    constructor(address owner_, Mandate memory mandate) {
        if (block.chainid != SEPOLIA_CHAIN_ID) revert UnsupportedChain(block.chainid);
        if (msg.sender != owner_) revert Unauthorized();
        if (
            owner_ == address(0) || mandate.taskId == bytes32(0) || mandate.reviewSnapshotDigest == bytes32(0)
                || mandate.token == address(0) || mandate.token.code.length == 0 || mandate.recipient == address(0)
                || mandate.executor == address(0) || mandate.executor == owner_
                || mandate.fulfillmentReporter == address(0) || mandate.fulfillmentReporter == owner_
                || mandate.fulfillmentReporter == mandate.executor || mandate.maxSpend == 0
                || mandate.expiresAt <= block.timestamp
        ) revert InvalidMandate();

        owner = owner_;
        taskId = mandate.taskId;
        reviewSnapshotDigest = mandate.reviewSnapshotDigest;
        mandateHash = hashMandate(owner_, mandate, block.chainid);
        token = IERC20(mandate.token);
        recipient = mandate.recipient;
        executor = mandate.executor;
        fulfillmentReporter = mandate.fulfillmentReporter;
        maxSpend = mandate.maxSpend;
        expiresAt = mandate.expiresAt;

        emit MandateActivated(
            mandate.taskId,
            mandateHash,
            owner_,
            mandate.token,
            mandate.recipient,
            mandate.executor,
            mandate.fulfillmentReporter,
            mandate.maxSpend,
            mandate.expiresAt
        );
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert Unauthorized();
        _;
    }

    modifier onlyFulfillmentReporter() {
        if (msg.sender != fulfillmentReporter) revert Unauthorized();
        _;
    }

    function isActive() public view returns (bool) {
        return !revoked && !paymentExecuted && block.timestamp < expiresAt;
    }

    function hashMandate(address owner_, Mandate memory mandate, uint256 chainId_) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                MANDATE_TYPEHASH,
                chainId_,
                mandate.taskId,
                mandate.reviewSnapshotDigest,
                owner_,
                mandate.token,
                mandate.recipient,
                mandate.executor,
                mandate.fulfillmentReporter,
                mandate.maxSpend,
                mandate.expiresAt
            )
        );
    }

    function fund(uint256 amount) external nonReentrant onlyOwner {
        if (!isActive()) revert AuthorityInactive();
        uint256 balanceBefore = token.balanceOf(address(this));
        if (amount == 0 || balanceBefore > maxSpend || amount > maxSpend - balanceBefore) {
            revert InvalidPayment();
        }

        token.safeTransferFrom(owner, address(this), amount);
        if (token.balanceOf(address(this)) - balanceBefore != amount) revert UnsupportedTokenBehavior();
        emit AccountFunded(owner, amount);
    }

    function revoke() external onlyOwner {
        if (revoked || paymentExecuted) revert AuthorityInactive();
        revoked = true;
        emit AuthorityRevoked(taskId, owner);
    }

    function executePayment(bytes32 paymentId_, uint256 amount) external nonReentrant onlyExecutor {
        if (paymentExecuted) revert PaymentAlreadyExecuted();
        if (!isActive()) revert AuthorityInactive();
        if (paymentId_ == bytes32(0) || amount == 0 || amount > maxSpend) revert InvalidPayment();

        uint256 available = token.balanceOf(address(this));
        if (amount > available) revert InsufficientAccountBalance(amount, available);

        paymentExecuted = true;
        paymentId = paymentId_;
        paidAmount = amount;

        uint256 recipientBalanceBefore = token.balanceOf(recipient);
        token.safeTransfer(recipient, amount);
        if (token.balanceOf(recipient) - recipientBalanceBefore != amount) revert UnsupportedTokenBehavior();

        emit PaymentExecuted(taskId, mandateHash, paymentId_, address(token), recipient, amount);
    }

    function confirmFulfillment(bytes32 paymentId_, bytes32 evidenceHash) external onlyFulfillmentReporter {
        if (!paymentExecuted || paymentId_ != paymentId) revert PaymentNotFound();
        if (evidenceHash == bytes32(0)) revert InvalidFulfillmentEvidence();
        if (fulfillmentConfirmed) revert FulfillmentAlreadyConfirmed();

        fulfillmentConfirmed = true;
        fulfillmentEvidenceHash = evidenceHash;
        emit FulfillmentConfirmed(taskId, paymentId_, evidenceHash, msg.sender);
    }

    function refund() external nonReentrant onlyOwner returns (uint256 amount) {
        if (isActive()) revert AuthorityStillActive();
        amount = token.balanceOf(address(this));
        if (amount == 0) return 0;

        uint256 ownerBalanceBefore = token.balanceOf(owner);
        token.safeTransfer(owner, amount);
        if (token.balanceOf(owner) - ownerBalanceBefore != amount) revert UnsupportedTokenBehavior();
        emit FundsRefunded(owner, amount);
    }
}
