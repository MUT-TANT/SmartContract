// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/OctantYieldRouter.sol";
import "../../src/mocks/MockERC20.sol";

contract OctantYieldRouterTest is Test {
    OctantYieldRouter public router;
    MockERC20 public usdc;
    MockERC20 public dai;

    address public owner = address(this);
    address public octantRecipient = address(0x1234);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    event YieldDonated(
        address indexed user,
        address indexed token,
        uint256 totalYield,
        uint256 userAmount,
        uint256 donationAmount,
        uint256 donationPercentage
    );

    function setUp() public {
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);

        // Deploy router
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(dai);

        router = new OctantYieldRouter(octantRecipient, owner, tokens);

        // Label addresses for better trace output
        vm.label(address(router), "OctantYieldRouter");
        vm.label(address(usdc), "USDC");
        vm.label(address(dai), "DAI");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(octantRecipient, "OctantRecipient");
    }

    function testRouteYieldWithZeroDonation() public {
        uint256 yieldAmount = 100e6; // 100 USDC

        // Mint yield to router
        usdc.mint(address(router), yieldAmount);

        // Route with 0% donation
        (uint256 userAmount, uint256 donationAmount) = router.routeYield(
            address(usdc),
            yieldAmount,
            0, // 0% donation
            alice
        );

        assertEq(userAmount, yieldAmount);
        assertEq(donationAmount, 0);
        assertEq(usdc.balanceOf(alice), yieldAmount);
        assertEq(usdc.balanceOf(octantRecipient), 0);
    }

    function testRouteYieldWith50PercentDonation() public {
        uint256 yieldAmount = 100e6; // 100 USDC

        // Mint yield to router
        usdc.mint(address(router), yieldAmount);

        // Route with 50% donation
        (uint256 userAmount, uint256 donationAmount) = router.routeYield(
            address(usdc),
            yieldAmount,
            5000, // 50% donation
            alice
        );

        assertEq(userAmount, 50e6);
        assertEq(donationAmount, 50e6);
        assertEq(usdc.balanceOf(alice), 50e6);
        assertEq(usdc.balanceOf(octantRecipient), 50e6);
    }

    function testRouteYieldWith100PercentDonation() public {
        uint256 yieldAmount = 100e6; // 100 USDC

        // Mint yield to router
        usdc.mint(address(router), yieldAmount);

        // Route with 100% donation
        (uint256 userAmount, uint256 donationAmount) = router.routeYield(
            address(usdc),
            yieldAmount,
            10000, // 100% donation
            alice
        );

        assertEq(userAmount, 0);
        assertEq(donationAmount, yieldAmount);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(octantRecipient), yieldAmount);
    }

    function testRouteYieldEmitsEvent() public {
        uint256 yieldAmount = 100e6;
        usdc.mint(address(router), yieldAmount);

        vm.expectEmit(true, true, false, true);
        emit YieldDonated(alice, address(usdc), yieldAmount, 70e6, 30e6, 3000);

        router.routeYield(address(usdc), yieldAmount, 3000, alice); // 30%
    }

    function testRouteYieldTracksUserDonations() public {
        uint256 yieldAmount = 100e6;
        usdc.mint(address(router), yieldAmount);

        router.routeYield(address(usdc), yieldAmount, 3000, alice); // 30%

        assertEq(router.donationsByUser(alice, address(usdc)), 30e6);
        assertEq(router.totalDonatedByToken(address(usdc)), 30e6);
    }

    function testRouteYieldMultipleUsers() public {
        // Alice donates
        usdc.mint(address(router), 100e6);
        router.routeYield(address(usdc), 100e6, 5000, alice); // 50%

        // Bob donates
        usdc.mint(address(router), 200e6);
        router.routeYield(address(usdc), 200e6, 2500, bob); // 25%

        assertEq(router.donationsByUser(alice, address(usdc)), 50e6);
        assertEq(router.donationsByUser(bob, address(usdc)), 50e6);
        assertEq(router.totalDonatedByToken(address(usdc)), 100e6);
    }

    function testRouteYieldRevertsWhenPaused() public {
        router.setPaused(true);

        usdc.mint(address(router), 100e6);

        vm.expectRevert(OctantYieldRouter.ContractPaused.selector);
        router.routeYield(address(usdc), 100e6, 5000, alice);
    }

    function testRouteYieldRevertsWithInvalidPercentage() public {
        usdc.mint(address(router), 100e6);

        vm.expectRevert(OctantYieldRouter.InvalidPercentage.selector);
        router.routeYield(address(usdc), 100e6, 10001, alice); // Over 100%
    }

    function testRouteYieldRevertsWithZeroAmount() public {
        vm.expectRevert(OctantYieldRouter.ZeroAmount.selector);
        router.routeYield(address(usdc), 0, 5000, alice);
    }

    function testRouteYieldRevertsForNonWhitelistedToken() public {
        MockERC20 unknownToken = new MockERC20("Unknown", "UNK", 18);
        unknownToken.mint(address(router), 100e18);

        vm.expectRevert(OctantYieldRouter.TokenNotWhitelisted.selector);
        router.routeYield(address(unknownToken), 100e18, 5000, alice);
    }

    function testCalculateSplit() public view {
        (uint256 userAmount, uint256 donationAmount) = router.calculateSplit(1000e6, 3000);

        assertEq(userAmount, 700e6);
        assertEq(donationAmount, 300e6);
    }

    function testSetOctantRecipient() public {
        address newRecipient = address(0x5678);
        router.setOctantRecipient(newRecipient);

        assertEq(router.octantPaymentSplitter(), newRecipient);
    }

    function testSetOctantRecipientRevertsForZeroAddress() public {
        vm.expectRevert(OctantYieldRouter.ZeroAddress.selector);
        router.setOctantRecipient(address(0));
    }

    function testSetTokenWhitelist() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);

        router.setTokenWhitelist(address(newToken), true);
        assertTrue(router.isTokenWhitelisted(address(newToken)));

        router.setTokenWhitelist(address(newToken), false);
        assertFalse(router.isTokenWhitelisted(address(newToken)));
    }

    function testGetTotalDonationsByUser() public {
        // Alice donates USDC
        usdc.mint(address(router), 100e6);
        router.routeYield(address(usdc), 100e6, 5000, alice);

        // Alice donates DAI
        dai.mint(address(router), 50e18);
        router.routeYield(address(dai), 50e18, 3000, alice);

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(dai);

        uint256 total = router.getTotalDonationsByUser(alice, tokens);
        assertEq(total, 50e6 + 15e18);
    }

    function testGetGlobalStats() public {
        // Multiple donations
        usdc.mint(address(router), 100e6);
        router.routeYield(address(usdc), 100e6, 5000, alice);

        dai.mint(address(router), 200e18);
        router.routeYield(address(dai), 200e18, 2500, bob);

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(dai);

        (uint256 totalDonations, uint256[] memory donationsByToken) = router.getGlobalStats(tokens);

        assertEq(totalDonations, 50e6 + 50e18);
        assertEq(donationsByToken[0], 50e6);
        assertEq(donationsByToken[1], 50e18);
    }

    function testRescueTokens() public {
        usdc.mint(address(router), 100e6);

        router.rescueTokens(address(usdc), 100e6, alice);

        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function testOnlyOwnerCanSetOctantRecipient() public {
        vm.prank(alice);
        vm.expectRevert();
        router.setOctantRecipient(address(0x5678));
    }

    function testOnlyOwnerCanSetPaused() public {
        vm.prank(alice);
        vm.expectRevert();
        router.setPaused(true);
    }

    function testOnlyOwnerCanSetTokenWhitelist() public {
        vm.prank(alice);
        vm.expectRevert();
        router.setTokenWhitelist(address(usdc), false);
    }
}
