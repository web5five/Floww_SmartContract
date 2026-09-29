// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FlowwTaskAccount} from "../src/FlowwTaskAccount.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract FlowwTaskAccountTest is Test {
    uint256 private constant USDC = 1e6;
    uint256 private constant MAX_SPEND = 60 * USDC;
    uint64 private constant EXPIRY = 2_000_000_000;

    address private owner;
    address private executor;
    address private recipient;
    address private reporter;
    address private stranger;
    MockUSDC private token;
    FlowwTaskAccount private account;

    bytes32 private taskId = keccak256("floww-task-1");
    bytes32 private reviewSnapshotDigest = keccak256("reviewed-mandate-v1");

    function setUp() public {
        vm.chainId(11155111);
        owner = makeAddr("owner");
        executor = makeAddr("executor");
        recipient = makeAddr("merchant");
        reporter = makeAddr("merchant-reporter");
        stranger = makeAddr("stranger");

        token = new MockUSDC();
        token.faucet(owner, 1_000 * USDC);
        account = _deploy(owner, _mandate());
    }

    function testOwnerFundsAndExecutorMakesOneBoundedPayment() public {
        _fund(MAX_SPEND);
        bytes32 id = keccak256("payment-1");
        uint256 amount = 43 * USDC;

        vm.prank(executor);
        account.executePayment(id, amount);

        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(account)), MAX_SPEND - amount);
        assertEq(account.paymentId(), id);
        assertEq(account.paidAmount(), amount);
        assertTrue(account.paymentExecuted());
        assertFalse(account.isActive());
    }

    function testMandateHashBindsChainAndImmutableTerms() public view {
        assertEq(account.reviewSnapshotDigest(), reviewSnapshotDigest);
        assertEq(account.mandateHash(), account.hashMandate(owner, _mandate(), 11155111));
        assertNotEq(account.mandateHash(), account.hashMandate(owner, _mandate(), 1));
    }

    function testPaymentCannotBeRepeated() public {
        _fund(MAX_SPEND);
        vm.prank(executor);
        account.executePayment(keccak256("payment-1"), 1 * USDC);

        vm.expectRevert(FlowwTaskAccount.PaymentAlreadyExecuted.selector);
        vm.prank(executor);
        account.executePayment(keccak256("payment-2"), 1 * USDC);
    }

    function testOutOfBudgetPaymentIsDeniedWithoutTransfer() public {
        _fund(MAX_SPEND);

        vm.expectRevert(FlowwTaskAccount.InvalidPayment.selector);
        vm.prank(executor);
        account.executePayment(keccak256("payment-over-budget"), MAX_SPEND + 1);

        assertEq(token.balanceOf(recipient), 0);
        assertFalse(account.paymentExecuted());
    }

    function testOnlyConfiguredExecutorCanPay() public {
        _fund(MAX_SPEND);

        vm.expectRevert(FlowwTaskAccount.Unauthorized.selector);
        vm.prank(stranger);
        account.executePayment(keccak256("payment-1"), 1 * USDC);

        assertEq(token.balanceOf(recipient), 0);
    }

    function testInsufficientFundingIsDenied() public {
        vm.expectRevert(abi.encodeWithSelector(FlowwTaskAccount.InsufficientAccountBalance.selector, USDC, 0));
        vm.prank(executor);
        account.executePayment(keccak256("payment-1"), USDC);
    }

    function testOwnerCanRevokeAndRecoverFunds() public {
        _fund(MAX_SPEND);

        vm.prank(owner);
        account.revoke();
        assertFalse(account.isActive());

        vm.prank(owner);
        assertEq(account.refund(), MAX_SPEND);
        assertEq(token.balanceOf(owner), 1_000 * USDC);
        assertEq(token.balanceOf(address(account)), 0);
    }

    function testCannotRefundWhileAuthorityIsActive() public {
        _fund(MAX_SPEND);

        vm.expectRevert(FlowwTaskAccount.AuthorityStillActive.selector);
        vm.prank(owner);
        account.refund();
    }

    function testExpiryBlocksExecutionAndAllowsRefund() public {
        _fund(MAX_SPEND);
        vm.warp(EXPIRY);
        assertFalse(account.isActive());

        vm.expectRevert(FlowwTaskAccount.AuthorityInactive.selector);
        vm.prank(executor);
        account.executePayment(keccak256("payment-after-expiry"), USDC);

        vm.prank(owner);
        assertEq(account.refund(), MAX_SPEND);
    }

    function testFulfillmentIsSeparateAndRestrictedToReporter() public {
        bytes32 id = keccak256("payment-1");
        bytes32 evidence = keccak256("merchant-delivery-evidence");

        vm.expectRevert(FlowwTaskAccount.PaymentNotFound.selector);
        vm.prank(reporter);
        account.confirmFulfillment(id, evidence);

        _fund(MAX_SPEND);
        vm.prank(executor);
        account.executePayment(id, 43 * USDC);

        vm.expectRevert(FlowwTaskAccount.Unauthorized.selector);
        vm.prank(stranger);
        account.confirmFulfillment(id, evidence);

        vm.prank(reporter);
        account.confirmFulfillment(id, evidence);
        assertTrue(account.fulfillmentConfirmed());
        assertEq(account.fulfillmentEvidenceHash(), evidence);

        vm.expectRevert(FlowwTaskAccount.FulfillmentAlreadyConfirmed.selector);
        vm.prank(reporter);
        account.confirmFulfillment(id, evidence);
    }

    function testRejectsDeploymentOutsideSepolia() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(FlowwTaskAccount.UnsupportedChain.selector, 1));
        vm.prank(owner);
        new FlowwTaskAccount(owner, _mandate());
    }

    function testOnlyOwnerCanDeployItsTaskAccount() public {
        vm.expectRevert(FlowwTaskAccount.Unauthorized.selector);
        vm.prank(stranger);
        new FlowwTaskAccount(owner, _mandate());
    }

    function _fund(uint256 amount) private {
        vm.startPrank(owner);
        token.approve(address(account), amount);
        account.fund(amount);
        vm.stopPrank();
    }

    function _deploy(address accountOwner, FlowwTaskAccount.Mandate memory terms)
        private
        returns (FlowwTaskAccount deployed)
    {
        vm.prank(accountOwner);
        deployed = new FlowwTaskAccount(accountOwner, terms);
    }

    function _mandate() private view returns (FlowwTaskAccount.Mandate memory) {
        return FlowwTaskAccount.Mandate({
            taskId: taskId,
            reviewSnapshotDigest: reviewSnapshotDigest,
            token: address(token),
            recipient: recipient,
            executor: executor,
            fulfillmentReporter: reporter,
            maxSpend: MAX_SPEND,
            expiresAt: EXPIRY
        });
    }
}
