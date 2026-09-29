# Floww Task Smart Account

Sepolia-only task wallet for a single bounded ERC-20 payment. The owner deploys the account directly, fixing the token, recipient, executor, fulfillment reporter, maximum spend and expiry in immutable contract state. The contract derives the mandate hash from the Sepolia chain ID, owner, task ID, review snapshot digest and every immutable execution term. The configured executor can pay the fixed recipient once; the owner can revoke before payment and recover remaining tokens after revocation, payment or expiry.

This is a task-scoped contract wallet, not an ERC-4337 account, a general-purpose wallet, a production USDC deployment or a claim that the existing Floww server/frontend are integrated. The user must review the exact terms in a trusted UI before signing the account deployment. Deployment by the owner is the on-chain approval boundary in this slice.

## Trust and evidence boundaries

- The contract rejects chains other than Ethereum Sepolia (`11155111`). Token amounts are integer base units; the included test token uses 6 decimals.
- `MockUSDC` is a faucet-enabled test fixture deployed by the demo script. It has no real value and must never be presented as Circle USDC. Verify any separately configured test token address from a trusted source.
- Sepolia ETH pays deployment, approval, funding and execution gas. This demo does not sponsor gas.
- The recipient and executor cannot be changed after deployment. A payment event proves the ERC-20 transfer succeeded on-chain, not that an order was accepted or delivered.
- Only the immutable fulfillment reporter can attach a nonzero evidence hash to the matching payment. That hash is an audit reference, not cryptographic proof of delivery; the reporter and evidence-verification process remain trust assumptions.
- The account permits one payment only. A payment or owner revocation ends spending authority; expiry blocks execution even before a cleanup transaction.
- The contract does not hold or expose a user's main private key. Each task account is funded separately by its owner.

## Build and test

Install Foundry, then install the pinned Solidity dependencies:

```sh
forge install OpenZeppelin/openzeppelin-contracts@v5.4.0
forge install foundry-rs/forge-std@v1.9.7
forge test -vvv
forge fmt --check
```

The tests run locally on Anvil's EVM with the chain ID set to Sepolia. They cover authorization, one-time payment, amount limits, expiry, revocation, refunds, and separate fulfillment reporting. They do not constitute a Sepolia deployment or live transaction proof.

## Sepolia demo deployment

Use a fresh test-only deployer key. Fund the deployer and the executor with faucet Sepolia ETH. Keep `.env` and all private keys out of Git; `.env.example` contains placeholders only.

```sh
cp .env.example .env
# Replace every placeholder in .env, including a future expiry timestamp.
set -a
source .env
set +a
forge script script/DeploySepoliaDemo.s.sol:DeploySepoliaDemo \
	--rpc-url "$SEPOLIA_RPC_URL" --broadcast
```

The script deploys a new faucet-enabled `MockUSDC`, mints the configured test amount to the deployer, then deploys the task account from that same owner address. `FLOWW_REVIEW_SNAPSHOT_DIGEST` must identify the exact server-side reviewed snapshot; the account derives its on-chain mandate hash from that reference and the deployed terms. Record the token/account addresses and deployment transaction from Foundry output. The owner must separately approve and call `fund`; the executor must call `executePayment(paymentId, amount)`; the configured reporter must call `confirmFulfillment(paymentId, evidenceHash)` only after the simulated merchant has fulfilled the order. Read `paymentExecuted`, `fulfillmentConfirmed`, `paymentId`, and emitted events independently from the chain before reporting a result.

## Recorded Sepolia deployment

The 2026-09-29 demo deployment has independently checked transaction receipts and read-only contract state in [the deployment evidence record](evidence/sepolia-2026-09-29.json). It deployed only the faucet-enabled `fUSDC` fixture and a task account; no payment or fulfillment was executed.

The repository does not deploy contracts automatically; the separately executed demo deployment is recorded above. The backend's F010/F012 routes, production authentication, mandate-hash generation, wallet UI, executor key management, merchant fixture and end-to-end evidence linkage still require integration. Do not use this contract with real funds.
