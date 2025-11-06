// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/StackSaveOctant.sol";
import "../../src/core/OctantYieldRouter.sol";
import "../../src/vaults/MorphoVaultAdapter.sol";
import "../../src/mocks/MockERC20.sol";
import "@morpho-blue/interfaces/IMorpho.sol";
import "@morpho-blue/mocks/OracleMock.sol";
import "@morpho-blue/mocks/IrmMock.sol";
import {Morpho} from "@morpho-blue/Morpho.sol";

/**
 * @title StackSaveIntegrationTest
 * @notice Integration tests for StackSave with mock Morpho
 */
contract StackSaveIntegrationTest is Test {
    StackSaveOctant public stackSave;
    OctantYieldRouter public yieldRouter;
    MorphoVaultAdapter public usdcVault;
    MorphoVaultAdapter public wethVault;

    MockERC20 public usdc;
    MockERC20 public weth;

    IMorpho public morpho;
    OracleMock public oracle;
    IrmMock public irm;

    address public owner = address(this);
    address public octantRecipient = address(0x1234);
    address public rewardPool = address(0x5678);
    address public treasury = address(0x9ABC);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    MarketParams public usdcMarket;
    MarketParams public wethMarket;

    function setUp() public {
        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Deploy Morpho Blue
        morpho = IMorpho(address(new Morpho(owner)));

        // Deploy oracle and IRM mocks
        oracle = new OracleMock();
        oracle.setPrice(1e36); // 1:1 price

        irm = new IrmMock();
        // IrmMock calculates rate based on utilization automatically

        // Enable IRM and LLTV
        morpho.enableIrm(address(irm));
        morpho.enableLltv(0.8e18); // 80% LLTV

        // Create markets
        usdcMarket = MarketParams({
            loanToken: address(usdc),
            collateralToken: address(weth),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.8e18
        });

        wethMarket = MarketParams({
            loanToken: address(weth),
            collateralToken: address(usdc),
            oracle: address(oracle),
            irm: address(irm),
            lltv: 0.8e18
        });

        morpho.createMarket(usdcMarket);
        morpho.createMarket(wethMarket);

        // Deploy yield router
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);

        yieldRouter = new OctantYieldRouter(octantRecipient, owner, tokens);

        // Deploy StackSave
        stackSave = new StackSaveOctant(address(yieldRouter), rewardPool, treasury);

        // Deploy vaults
        usdcVault = new MorphoVaultAdapter(
            address(morpho),
            address(usdc),
            usdcMarket,
            address(stackSave),
            octantRecipient,
            "StackSave USDC Vault",
            "ssUSDC"
        );

        wethVault = new MorphoVaultAdapter(
            address(morpho),
            address(weth),
            wethMarket,
            address(stackSave),
            octantRecipient,
            "StackSave WETH Vault",
            "ssWETH"
        );

        // Configure vaults in StackSave
        stackSave.configureVault(address(usdc), StackSaveOctant.Mode.Lite, address(usdcVault));
        stackSave.configureVault(address(weth), StackSaveOctant.Mode.Pro, address(wethVault));

        // Mint tokens to users
        usdc.mint(alice, 10000e6);
        weth.mint(bob, 100e18);

        // Labels
        vm.label(address(stackSave), "StackSave");
        vm.label(address(yieldRouter), "YieldRouter");
        vm.label(address(usdcVault), "USDCVault");
        vm.label(address(wethVault), "WETHVault");
        vm.label(address(morpho), "Morpho");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");

        // Add initial liquidity to Morpho markets so withdrawals work
        // This simulates existing liquidity in the markets
        usdc.mint(address(this), 1000000e6); // 1M USDC
        weth.mint(address(this), 1000e18);   // 1000 WETH

        usdc.approve(address(morpho), type(uint256).max);
        weth.approve(address(morpho), type(uint256).max);

        // Supply to USDC market
        morpho.supply(usdcMarket, 1000000e6, 0, address(this), "");
        // Supply to WETH market
        morpho.supply(wethMarket, 1000e18, 0, address(this), "");
    }

    function testCreateGoal() public {
        vm.startPrank(alice);

        uint256 goalId = stackSave.createGoal(
            "Emergency Fund",
            address(usdc),
            StackSaveOctant.Mode.Lite,
            1000e6, // Target: 1000 USDC
            90 days,
            3000 // 30% donation
        );

        assertEq(goalId, 1);

        (
            uint256 id,
            address goalOwner,
            address currency,
            StackSaveOctant.Mode mode,
            uint256 targetAmount,
            uint256 duration,
            uint256 donationPct,
            ,
            ,
            ,
            StackSaveOctant.GoalStatus status
        ) = stackSave.goals(goalId);

        assertEq(id, 1);
        assertEq(goalOwner, alice);
        assertEq(currency, address(usdc));
        assertTrue(mode == StackSaveOctant.Mode.Lite);
        assertEq(targetAmount, 1000e6);
        assertEq(duration, 90 days);
        assertEq(donationPct, 3000);
        assertTrue(status == StackSaveOctant.GoalStatus.Active);

        vm.stopPrank();
    }

    function testDepositToGoal() public {
        // Create goal
        vm.startPrank(alice);
        uint256 goalId = stackSave.createGoal(
            "Vacation Fund",
            address(usdc),
            StackSaveOctant.Mode.Lite,
            1000e6,
            90 days,
            5000 // 50% donation
        );

        // Approve and deposit
        usdc.approve(address(stackSave), 500e6);
        stackSave.deposit(goalId, 500e6);

        // Check deposit
        (,,,,,,, uint256 depositedAmount,,,) = stackSave.goals(goalId);
        assertEq(depositedAmount, 500e6);

        // Check vault has shares
        (uint256 principal, uint256 vaultShares,) = stackSave.deposits(goalId);
        assertEq(principal, 500e6);
        assertGt(vaultShares, 0);

        vm.stopPrank();
    }

    function testCompleteGoalAndWithdraw() public {
        // Create and fully fund goal
        vm.startPrank(alice);

        uint256 goalId = stackSave.createGoal(
            "New Laptop",
            address(usdc),
            StackSaveOctant.Mode.Lite,
            1000e6,
            90 days,
            0 // 0% donation for simplicity
        );

        usdc.approve(address(stackSave), 1000e6);
        stackSave.deposit(goalId, 1000e6);

        // Check goal is completed
        (,,,,,,,,,, StackSaveOctant.GoalStatus status) = stackSave.goals(goalId);
        assertTrue(status == StackSaveOctant.GoalStatus.Completed);

        // Withdraw
        uint256 balanceBefore = usdc.balanceOf(alice);
        stackSave.withdrawCompleted(goalId);
        uint256 balanceAfter = usdc.balanceOf(alice);

        // Should get back at least principal (may have some yield)
        assertGe(balanceAfter - balanceBefore, 1000e6);

        vm.stopPrank();
    }

    function testEarlyWithdrawalPenalty() public {
        vm.startPrank(alice);

        // Create and deposit
        uint256 goalId = stackSave.createGoal(
            "House Down Payment",
            address(usdc),
            StackSaveOctant.Mode.Lite,
            5000e6,
            90 days,
            2000 // 20% donation
        );

        usdc.approve(address(stackSave), 1000e6);
        stackSave.deposit(goalId, 1000e6);

        // Early withdrawal
        uint256 balanceBefore = usdc.balanceOf(alice);
        stackSave.withdrawEarly(goalId);
        uint256 balanceAfter = usdc.balanceOf(alice);

        uint256 received = balanceAfter - balanceBefore;

        // Should get 98% (2% penalty)
        assertApproxEqRel(received, 980e6, 0.01e18); // Within 1%

        // Check penalty was distributed
        assertGt(usdc.balanceOf(rewardPool), 0);
        assertGt(usdc.balanceOf(treasury), 0);

        vm.stopPrank();
    }

    function testUpdateDonationPercentage() public {
        vm.startPrank(alice);

        uint256 goalId = stackSave.createGoal(
            "Education Fund",
            address(usdc),
            StackSaveOctant.Mode.Lite,
            2000e6,
            90 days,
            2000 // 20% donation
        );

        // Update to 50%
        stackSave.setDonationPercentage(goalId, 5000);

        (,,,,,, uint256 donationPct,,,,) = stackSave.goals(goalId);
        assertEq(donationPct, 5000);

        vm.stopPrank();
    }

    function testMultipleGoalsSameUser() public {
        vm.startPrank(alice);

        // Create multiple goals
        uint256 goalId1 = stackSave.createGoal("Goal 1", address(usdc), StackSaveOctant.Mode.Lite, 1000e6, 90 days, 1000);
        uint256 goalId2 = stackSave.createGoal("Goal 2", address(usdc), StackSaveOctant.Mode.Lite, 2000e6, 90 days, 2000);
        uint256 goalId3 = stackSave.createGoal("Goal 3", address(weth), StackSaveOctant.Mode.Pro, 5e18, 90 days, 3000);

        // Check all goals are tracked
        uint256[] memory goals = stackSave.getUserGoals(alice);
        assertEq(goals.length, 3);
        assertEq(goals[0], goalId1);
        assertEq(goals[1], goalId2);
        assertEq(goals[2], goalId3);

        vm.stopPrank();
    }

    function testProModeWithWETH() public {
        vm.startPrank(bob);

        uint256 goalId = stackSave.createGoal(
            "Crypto Portfolio",
            address(weth),
            StackSaveOctant.Mode.Pro,
            10e18,
            90 days,
            5000 // 50% donation
        );

        weth.approve(address(stackSave), 5e18);
        stackSave.deposit(goalId, 5e18);

        (,,,,,,, uint256 depositedAmount,,,) = stackSave.goals(goalId);
        assertEq(depositedAmount, 5e18);

        vm.stopPrank();
    }

    function testCannotDepositToOthersGoal() public {
        vm.prank(alice);
        uint256 goalId = stackSave.createGoal("Alice's Goal", address(usdc), StackSaveOctant.Mode.Lite, 1000e6, 90 days, 1000);

        // Bob tries to deposit to Alice's goal
        vm.startPrank(bob);
        usdc.mint(bob, 1000e6);
        usdc.approve(address(stackSave), 1000e6);

        vm.expectRevert(StackSaveOctant.Unauthorized.selector);
        stackSave.deposit(goalId, 100e6);

        vm.stopPrank();
    }

    function testCannotWithdrawIncompleteGoal() public {
        vm.startPrank(alice);

        uint256 goalId = stackSave.createGoal("Big Goal", address(usdc), StackSaveOctant.Mode.Lite, 5000e6, 90 days, 0);

        usdc.approve(address(stackSave), 1000e6);
        stackSave.deposit(goalId, 1000e6); // Only 20% of target

        vm.expectRevert(StackSaveOctant.GoalNotCompleted.selector);
        stackSave.withdrawCompleted(goalId);

        vm.stopPrank();
    }

    function testGetGoalDetails() public {
        vm.startPrank(alice);

        uint256 goalId = stackSave.createGoal("Test Goal", address(usdc), StackSaveOctant.Mode.Lite, 1000e6, 90 days, 3000);

        usdc.approve(address(stackSave), 500e6);
        stackSave.deposit(goalId, 500e6);

        (
            StackSaveOctant.Goal memory goal,
            uint256 currentValue,
            uint256 yieldEarned
        ) = stackSave.getGoalDetails(goalId);

        assertEq(goal.id, goalId);
        assertEq(goal.owner, alice);
        assertGe(currentValue, 500e6);
        // Yield might be 0 in this simple test without time passing

        vm.stopPrank();
    }

    function testGetSupportedCurrencies() public view {
        address[] memory currencies = stackSave.getSupportedCurrencies();
        assertEq(currencies.length, 2);
        assertEq(currencies[0], address(usdc));
        assertEq(currencies[1], address(weth));
    }
}
