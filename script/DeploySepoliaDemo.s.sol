// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {FlowwTaskAccount} from "../src/FlowwTaskAccount.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

contract DeploySepoliaDemo is Script {
    uint256 private constant SEPOLIA_CHAIN_ID = 11155111;

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");

        uint256 ownerPrivateKey = vm.envUint("SEPOLIA_DEPLOYER_PRIVATE_KEY");
        address owner = vm.addr(ownerPrivateKey);
        FlowwTaskAccount.Mandate memory mandate = FlowwTaskAccount.Mandate({
            taskId: vm.envBytes32("FLOWW_TASK_ID"),
            reviewSnapshotDigest: vm.envBytes32("FLOWW_REVIEW_SNAPSHOT_DIGEST"),
            token: address(0),
            recipient: vm.envAddress("FLOWW_MERCHANT_RECIPIENT"),
            executor: vm.envAddress("FLOWW_EXECUTOR"),
            fulfillmentReporter: vm.envAddress("FLOWW_FULFILLMENT_REPORTER"),
            maxSpend: vm.envUint("FLOWW_MAX_SPEND_BASE_UNITS"),
            expiresAt: uint64(vm.envUint("FLOWW_EXPIRES_AT"))
        });

        vm.startBroadcast(ownerPrivateKey);
        MockUSDC mockToken = new MockUSDC();
        mockToken.faucet(owner, vm.envUint("FLOWW_TEST_MINT_BASE_UNITS"));
        mandate.token = address(mockToken);
        FlowwTaskAccount account = new FlowwTaskAccount(owner, mandate);

        bytes32 approvalDigest = account.mandateApprovalDigest();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, approvalDigest);
        account.approveMandate(abi.encodePacked(r, s, v));

        mockToken.approve(address(account), mandate.maxSpend);
        account.fund(mandate.maxSpend);
        vm.stopBroadcast();

        require(address(mockToken) != address(0) && address(account) != address(0), "Deployment failed");
    }
}
