// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract FlowwTaskAccount is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    bytes32 public constant MANDATE_TYPEHASH = keccak256(
        "FlowwTaskMandateV1(uint256 chainId,bytes32 taskId,bytes32 reviewSnapshotDigest,address owner,address token,address recipient,address executor,address fulfillmentReporter,uint256 maxSpend,uint64 expiresAt)"
    );
    bytes32 public constant APPROVAL_TYPEHASH = keccak256(
        "MandateApproval(address owner,bytes32 taskId,bytes32 reviewSnapshotDigest,address token,address recipient,address executor,address fulfillmentReporter,uint256 maxSpend,uint64 expiresAt,uint256 nonce)"
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
    bool public mandateApproved;
    bool public paymentExecuted;
    bool public fulfillmentConfirmed;
    uint256 public authorizationNonce;
    bytes32 public approvedDigest;
    bytes32 public paymentId;
    bytes32 public fulfillmentEvidenceHash;
    uint256 public paidAmount;

    error UnsupportedChain(uint256 actualChainId);
    error Unauthorized();
    error InvalidMandate();
    error AuthorityInactive();
    error MandateNotApproved();
    error MandateAlreadyApproved();
    error InvalidApprovalSignature();
    error InvalidPayment();
    error PaymentAlreadyExecuted();
    error InsufficientAccountBalance(uint256 requested, uint256 available);
    error UnsupportedTokenBehavior();
    error PaymentNotFound();
    error InvalidFulfillmentEvidence();
    error FulfillmentAlreadyConfirmed();
    error AuthorityStillActive();

    event MandateCreated(
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
    event MandateApproved(bytes32 indexed taskId, bytes32 indexed mandateHash, bytes32 approvalDigest, uint256 nonce);
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

    constructor(address owner_, Mandate memory mandate) EIP712("FlowwTaskAccount", "1") {
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

        emit MandateCreated(
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
        return mandateApproved && !revoked && !paymentExecuted && block.timestamp < expiresAt;
    }

    function mandateApprovalDigest() public view returns (bytes32) {
        return _hashTypedDataV4(_mandateApprovalStructHash(authorizationNonce));
    }

    function approveMandate(bytes calldata signature) external nonReentrant {
        if (mandateApproved) revert MandateAlreadyApproved();
        if (revoked || paymentExecuted || block.timestamp >= expiresAt) revert AuthorityInactive();
        if (block.chainid != SEPOLIA_CHAIN_ID) revert UnsupportedChain(block.chainid);

        bytes32 digest = mandateApprovalDigest();
        if (!SignatureChecker.isValidSignatureNow(owner, digest, signature)) revert InvalidApprovalSignature();

        uint256 consumedNonce = authorizationNonce;
        authorizationNonce = consumedNonce + 1;
        approvedDigest = digest;
        mandateApproved = true;
        emit MandateApproved(taskId, mandateHash, digest, consumedNonce);
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

    function _mandateApprovalStructHash(uint256 nonce) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                APPROVAL_TYPEHASH,
                owner,
                taskId,
                reviewSnapshotDigest,
                address(token),
                recipient,
                executor,
                fulfillmentReporter,
                maxSpend,
                expiresAt,
                nonce
            )
        );
    }

    function fund(uint256 amount) external nonReentrant onlyOwner {
        if (!mandateApproved) revert MandateNotApproved();
        if (!isActive()) revert AuthorityInactive();
        uint256 balanceBefore = token.balanceOf(address(this));
        if (amount == 0 || balanceBefore > maxSpend || amount > maxSpend - balanceBefore) {
            revert InvalidPayment();
        }

        token.safeTransferFrom(owner, address(this), amount);
        if (token.balanceOf(address(this)) - balanceBefore != amount) revert UnsupportedTokenBehavior();
        emit AccountFunded(owner, amount);
    }

    function revoke() external nonReentrant onlyOwner {
        if (revoked || paymentExecuted) revert AuthorityInactive();
        revoked = true;
        emit AuthorityRevoked(taskId, owner);
    }

    function executePayment(bytes32 paymentId_, uint256 amount) external nonReentrant onlyExecutor {
        if (!mandateApproved) revert MandateNotApproved();
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
