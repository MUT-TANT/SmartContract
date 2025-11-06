// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/core/StackSaveOctant.sol";
import "../src/core/OctantYieldRouter.sol";
import "../src/vaults/MorphoVaultAdapter.sol";
import "../src/utils/TokenFaucet.sol";
import "@morpho-blue/interfaces/IMorpho.sol";

/**
 * @title DeployStackSave
 * @notice Deployment script for StackSave on Octant
 * @dev Deploys all contracts and configures them for the hackathon
 *
 * Usage:
 * forge script script/Deploy.s.sol:DeployStackSave --rpc-url tenderly_fork --broadcast -vvvv
 */
contract DeployStackSave is Script {
    // Morpho Blue mainnet address
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // Placeholder for Octant PaymentSplitter (update with actual address)
    address constant OCTANT_PAYMENT_SPLITTER = 0x00d1e028A70ee8D422bFD1132B50464E2D21FBcD;

    // Reward pool and treasury addresses (can be multisigs)
    address rewardPool;
    address treasury;

    // Token addresses on mainnet
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Deployed contracts
    StackSaveOctant public stackSave;
    OctantYieldRouter public yieldRouter;
    MorphoVaultAdapter public usdcVaultLite;
    MorphoVaultAdapter public daiVaultLite;
    MorphoVaultAdapter public wethVaultPro;
    TokenFaucet public faucet;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying StackSave contracts...");
        console.log("Deployer:", deployer);

        // Set reward pool and treasury to deployer initially (can transfer later)
        rewardPool = deployer;
        treasury = deployer;

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy OctantYieldRouter
        console.log("\n1. Deploying OctantYieldRouter...");
        address[] memory initialTokens = new address[](3);
        initialTokens[0] = USDC;
        initialTokens[1] = DAI;
        initialTokens[2] = WETH;

        yieldRouter = new OctantYieldRouter(
            OCTANT_PAYMENT_SPLITTER,
            deployer,
            initialTokens
        );
        console.log("YieldRouter deployed at:", address(yieldRouter));

        // 2. Deploy StackSaveOctant
        console.log("\n2. Deploying StackSaveOctant...");
        stackSave = new StackSaveOctant(
            address(yieldRouter),
            rewardPool,
            treasury
        );
        console.log("StackSave deployed at:", address(stackSave));

        // 3. Deploy MorphoVaultAdapter for USDC (Lite mode)
        console.log("\n3. Deploying USDC Vault (Lite)...");
        MarketParams memory usdcMarket = _getUSDCMarket();
        usdcVaultLite = new MorphoVaultAdapter(
            MORPHO,
            USDC,
            usdcMarket,
            address(stackSave),
            OCTANT_PAYMENT_SPLITTER,
            "StackSave USDC Vault",
            "ssUSDC"
        );
        console.log("USDC Vault deployed at:", address(usdcVaultLite));

        // 4. Deploy MorphoVaultAdapter for DAI (Lite mode)
        console.log("\n4. Deploying DAI Vault (Lite)...");
        MarketParams memory daiMarket = _getDAIMarket();
        daiVaultLite = new MorphoVaultAdapter(
            MORPHO,
            DAI,
            daiMarket,
            address(stackSave),
            OCTANT_PAYMENT_SPLITTER,
            "StackSave DAI Vault",
            "ssDAI"
        );
        console.log("DAI Vault deployed at:", address(daiVaultLite));

        // 5. Deploy MorphoVaultAdapter for WETH (Pro mode)
        console.log("\n5. Deploying WETH Vault (Pro)...");
        MarketParams memory wethMarket = _getWETHMarket();
        wethVaultPro = new MorphoVaultAdapter(
            MORPHO,
            WETH,
            wethMarket,
            address(stackSave),
            OCTANT_PAYMENT_SPLITTER,
            "StackSave WETH Vault",
            "ssWETH"
        );
        console.log("WETH Vault deployed at:", address(wethVaultPro));

        // 6. Deploy TokenFaucet
        console.log("\n6. Deploying TokenFaucet...");
        faucet = new TokenFaucet(deployer);
        console.log("TokenFaucet deployed at:", address(faucet));

        // Configure faucet with claim amounts
        faucet.configureToken(USDC, 100e6);  // 100 USDC
        faucet.configureToken(DAI, 500e18);  // 500 DAI
        faucet.configureToken(WETH, 0.1e18); // 0.1 WETH
        console.log("Faucet configured");

        // 7. Configure vaults in StackSave
        console.log("\n7. Configuring vaults in StackSave...");
        stackSave.configureVault(USDC, StackSaveOctant.Mode.Lite, address(usdcVaultLite));
        stackSave.configureVault(DAI, StackSaveOctant.Mode.Lite, address(daiVaultLite));
        stackSave.configureVault(WETH, StackSaveOctant.Mode.Pro, address(wethVaultPro));
        console.log("Vaults configured");

        vm.stopBroadcast();

        // Print deployment summary
        _printDeploymentSummary();
    }

    /**
     * @notice Returns USDC market params for Morpho Blue
     * @dev Using WETH as collateral - adjust based on actual markets
     */
    function _getUSDCMarket() internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: USDC,
            collateralToken: WETH,
            oracle: 0x48F7E36EB6B826B2dF4B2E630B62Cd25e89E40e2, // Chainlink USDC/ETH oracle (example)
            irm: 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC, // Adaptive Curve IRM (example)
            lltv: 0.86e18 // 86% LLTV
        });
    }

    /**
     * @notice Returns DAI market params for Morpho Blue
     * @dev Using WETH as collateral
     */
    function _getDAIMarket() internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: DAI,
            collateralToken: WETH,
            oracle: 0x773616E4d11A78F511299002da57A0a94577F1f4, // Chainlink DAI/ETH oracle (example)
            irm: 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC, // Adaptive Curve IRM (example)
            lltv: 0.86e18 // 86% LLTV
        });
    }

    /**
     * @notice Returns WETH market params for Morpho Blue
     * @dev Using USDC as collateral
     */
    function _getWETHMarket() internal pure returns (MarketParams memory) {
        return MarketParams({
            loanToken: WETH,
            collateralToken: USDC,
            oracle: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, // Chainlink ETH/USD oracle (example)
            irm: 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC, // Adaptive Curve IRM (example)
            lltv: 0.80e18 // 80% LLTV
        });
    }

    /**
     * @notice Prints deployment summary
     */
    function _printDeploymentSummary() internal view {
        console.log("\n========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("StackSaveOctant:", address(stackSave));
        console.log("OctantYieldRouter:", address(yieldRouter));
        console.log("USDC Vault (Lite):", address(usdcVaultLite));
        console.log("DAI Vault (Lite):", address(daiVaultLite));
        console.log("WETH Vault (Pro):", address(wethVaultPro));
        console.log("TokenFaucet:", address(faucet));
        console.log("========================================");
        console.log("\nConfiguration:");
        console.log("Morpho Blue:", MORPHO);
        console.log("Octant Recipient:", OCTANT_PAYMENT_SPLITTER);
        console.log("Reward Pool:", rewardPool);
        console.log("Treasury:", treasury);
        console.log("========================================");
        console.log("\nNext Steps:");
        console.log("1. Verify contracts on Etherscan");
        console.log("2. Update Octant PaymentSplitter address if needed");
        console.log("3. Transfer ownership if required");
        console.log("4. Refill faucet with test tokens");
        console.log("5. Test complete flow on frontend");
        console.log("========================================");
    }
}
