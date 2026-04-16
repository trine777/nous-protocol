// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/NousToken.sol";
import "../src/NousVesting.sol";
import "../src/NousCore.sol";
import "../src/RewardDistributor.sol";
import "../src/NousLPLock.sol";

/// @notice Deploy all Nous contracts to Base (Sepolia or mainnet).
/// @dev Run: forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
contract DeployNous is Script {
    function run() external {
        address deployer = msg.sender;
        address founder = vm.envAddress("FOUNDER_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        vm.startBroadcast();

        // 1. Deploy NousToken (100M minted to deployer)
        NousToken token = new NousToken();
        console.log("NousToken:", address(token));

        // 2. Deploy NousVesting (founder vesting: 6mo cliff, 12mo linear)
        NousVesting vesting = new NousVesting(founder);
        console.log("NousVesting:", address(vesting));

        // 3. Deploy RewardDistributor
        RewardDistributor distributor = new RewardDistributor(address(token));
        console.log("RewardDistributor:", address(distributor));

        // 4. Deploy NousCore
        NousCore core = new NousCore(address(token), address(distributor), treasury);
        console.log("NousCore:", address(core));

        // 5. Wire: set NousCore as authorized caller on RewardDistributor
        distributor.setCore(address(core));

        // 6. Distribute tokens
        // 20% founder (20M) → vesting contract
        token.transfer(address(vesting), 20_000_000e18);
        // 40% reward pool (40M) → distributor
        token.transfer(address(distributor), 40_000_000e18);
        // 20% treasury (20M) → treasury multisig
        token.transfer(treasury, 20_000_000e18);
        // 20% LP (20M) stays with deployer for Uniswap pool creation

        console.log("Token distribution complete:");
        console.log("  Vesting:", token.balanceOf(address(vesting)));
        console.log("  Rewards:", token.balanceOf(address(distributor)));
        console.log("  Treasury:", token.balanceOf(treasury));
        console.log("  LP (deployer):", token.balanceOf(deployer));

        vm.stopBroadcast();

        // LP lock + Uniswap pool creation are manual steps after deployment:
        // 1. Create Uniswap V3 pool: NOUS/ETH
        // 2. Add liquidity: 2M NOUS + 0.5 ETH
        // 3. Deploy NousLPLock with LP token address
        // 4. Transfer LP tokens to lock contract
        console.log("\nManual steps remaining:");
        console.log("  1. Create Uniswap V3 NOUS/ETH pool");
        console.log("  2. Add liquidity (2M NOUS + 0.5 ETH)");
        console.log("  3. Deploy NousLPLock + lock LP tokens");
    }
}
