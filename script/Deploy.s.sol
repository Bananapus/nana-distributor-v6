// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";

import {JB721Distributor} from "../src/JB721Distributor.sol";

contract Deploy is Script {
    function run() public {
        vm.startBroadcast();

        // Configure these values before deploying.
        IJBDirectory directory = IJBDirectory(vm.envAddress("DIRECTORY_ADDRESS"));
        uint256 roundDuration = vm.envUint("ROUND_DURATION");
        uint256 vestingRounds = vm.envUint("VESTING_ROUNDS");

        new JB721Distributor(directory, roundDuration, vestingRounds);

        vm.stopBroadcast();
    }
}
