// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";

import {JB721Distributor} from "../src/JB721Distributor.sol";

contract Deploy is Script {
    function run() public {
        vm.startBroadcast();

        // Configure these values before deploying.
        IJBDirectory directory = IJBDirectory(vm.envAddress("DIRECTORY_ADDRESS"));
        IJBController controller = IJBController(vm.envAddress("CONTROLLER_ADDRESS"));
        IREVLoans revLoans = IREVLoans(vm.envOr("REV_LOANS_ADDRESS", address(0)));
        IREVOwner revOwner = IREVOwner(vm.envOr("REV_OWNER_ADDRESS", address(0)));
        uint256 roundDuration = vm.envUint("ROUND_DURATION");
        uint256 vestingRounds = vm.envUint("VESTING_ROUNDS");
        uint256 rawClaimDuration = vm.envUint("CLAIM_DURATION");

        require(rawClaimDuration <= type(uint48).max, "CLAIM_DURATION_TOO_LARGE");

        // Safe because the explicit bound above rejects values larger than uint48.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 claimDuration = uint48(rawClaimDuration);

        new JB721Distributor({
            directory: directory,
            controller: controller,
            revLoans: revLoans,
            revOwner: revOwner,
            initialRoundDuration: roundDuration,
            initialVestingRounds: vestingRounds,
            initialClaimDuration: claimDuration
        });

        vm.stopBroadcast();
    }
}
