// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/utils/TokenFaucet.sol";
import "../../src/mocks/MockERC20.sol";

contract TokenFaucetTest is Test {
    TokenFaucet public faucet;
    MockERC20 public usdc;
    MockERC20 public dai;

    address public owner = address(this);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    uint256 public constant CLAIM_AMOUNT_USDC = 100e6; // 100 USDC
    uint256 public constant CLAIM_AMOUNT_DAI = 500e18; // 500 DAI

    function setUp() public {
        // Deploy faucet
        faucet = new TokenFaucet(owner);

        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);

        // Configure tokens
        faucet.configureToken(address(usdc), CLAIM_AMOUNT_USDC);
        faucet.configureToken(address(dai), CLAIM_AMOUNT_DAI);

        // Refill faucet
        usdc.mint(owner, 10000e6);
        dai.mint(owner, 50000e18);

        usdc.approve(address(faucet), 10000e6);
        dai.approve(address(faucet), 50000e18);

        faucet.refill(address(usdc), 10000e6);
        faucet.refill(address(dai), 50000e18);

        // Label addresses
        vm.label(address(faucet), "TokenFaucet");
        vm.label(address(usdc), "USDC");
        vm.label(address(dai), "DAI");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
    }

    function testClaimTokens() public {
        vm.prank(alice);
        faucet.claimTokens(address(usdc));

        assertEq(usdc.balanceOf(alice), CLAIM_AMOUNT_USDC);
    }

    function testClaimMultipleTokens() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(dai);

        vm.prank(alice);
        faucet.claimMultiple(tokens);

        assertEq(usdc.balanceOf(alice), CLAIM_AMOUNT_USDC);
        assertEq(dai.balanceOf(alice), CLAIM_AMOUNT_DAI);
    }

    function testCannotClaimTwiceWithin24Hours() public {
        // First claim
        vm.prank(alice);
        faucet.claimTokens(address(usdc));

        // Try to claim again immediately
        vm.prank(alice);
        vm.expectRevert(TokenFaucet.ClaimTooSoon.selector);
        faucet.claimTokens(address(usdc));
    }

    function testCanClaimAfter24Hours() public {
        // First claim
        vm.prank(alice);
        faucet.claimTokens(address(usdc));

        assertEq(usdc.balanceOf(alice), CLAIM_AMOUNT_USDC);

        // Fast forward 24 hours + 1 second
        vm.warp(block.timestamp + 24 hours + 1);

        // Second claim should work
        vm.prank(alice);
        faucet.claimTokens(address(usdc));

        assertEq(usdc.balanceOf(alice), CLAIM_AMOUNT_USDC * 2);
    }

    function testDifferentUsersCanClaimSimultaneously() public {
        vm.prank(alice);
        faucet.claimTokens(address(usdc));

        vm.prank(bob);
        faucet.claimTokens(address(usdc));

        assertEq(usdc.balanceOf(alice), CLAIM_AMOUNT_USDC);
        assertEq(usdc.balanceOf(bob), CLAIM_AMOUNT_USDC);
    }

    function testTracksTotalClaimed() public {
        vm.prank(alice);
        faucet.claimTokens(address(usdc));

        (uint256 claimed,,) = faucet.getUserStats(alice, address(usdc));
        assertEq(claimed, CLAIM_AMOUNT_USDC);

        // Claim again after 24 hours
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(alice);
        faucet.claimTokens(address(usdc));

        (claimed,,) = faucet.getUserStats(alice, address(usdc));
        assertEq(claimed, CLAIM_AMOUNT_USDC * 2);
    }

    function testCannotClaimWhenPaused() public {
        faucet.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(TokenFaucet.ContractPaused.selector);
        faucet.claimTokens(address(usdc));
    }

    function testCannotClaimUnsupportedToken() public {
        MockERC20 unknownToken = new MockERC20("Unknown", "UNK", 18);

        vm.prank(alice);
        vm.expectRevert(TokenFaucet.TokenNotSupported.selector);
        faucet.claimTokens(address(unknownToken));
    }

    function testCanClaimView() public {
        // Initially can claim
        (bool canClaim, uint256 nextClaimTime) = faucet.canClaim(alice, address(usdc));
        assertTrue(canClaim);
        assertEq(nextClaimTime, 0);

        // After claiming, cannot claim
        vm.prank(alice);
        faucet.claimTokens(address(usdc));

        (canClaim, nextClaimTime) = faucet.canClaim(alice, address(usdc));
        assertFalse(canClaim);
        assertEq(nextClaimTime, block.timestamp + 24 hours);

        // After 24 hours, can claim again
        vm.warp(block.timestamp + 24 hours + 1);
        (canClaim, nextClaimTime) = faucet.canClaim(alice, address(usdc));
        assertTrue(canClaim);
    }

    function testGetFaucetBalance() public view {
        uint256 balance = faucet.getFaucetBalance(address(usdc));
        assertEq(balance, 10000e6);
    }

    function testGetSupportedTokens() public view {
        address[] memory tokens = faucet.getSupportedTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(usdc));
        assertEq(tokens[1], address(dai));
    }

    function testGetUserStats() public {
        vm.prank(alice);
        faucet.claimTokens(address(usdc));

        (uint256 claimed, uint256 lastClaim, bool canClaimNow) =
            faucet.getUserStats(alice, address(usdc));

        assertEq(claimed, CLAIM_AMOUNT_USDC);
        assertEq(lastClaim, block.timestamp);
        assertFalse(canClaimNow);
    }

    function testConfigureToken() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        uint256 newAmount = 1000e18;

        faucet.configureToken(address(newToken), newAmount);

        assertEq(faucet.claimAmounts(address(newToken)), newAmount);
        assertTrue(faucet.isTokenSupported(address(newToken)));
    }

    function testRefill() public {
        usdc.mint(owner, 1000e6);
        usdc.approve(address(faucet), 1000e6);

        uint256 balanceBefore = faucet.getFaucetBalance(address(usdc));
        faucet.refill(address(usdc), 1000e6);
        uint256 balanceAfter = faucet.getFaucetBalance(address(usdc));

        assertEq(balanceAfter - balanceBefore, 1000e6);
    }

    function testEmergencyWithdraw() public {
        uint256 amount = 1000e6;

        faucet.emergencyWithdraw(address(usdc), amount, alice);

        assertEq(usdc.balanceOf(alice), amount);
    }

    function testOnlyOwnerCanConfigure() public {
        vm.prank(alice);
        vm.expectRevert();
        faucet.configureToken(address(usdc), 200e6);
    }

    function testOnlyOwnerCanSetPaused() public {
        vm.prank(alice);
        vm.expectRevert();
        faucet.setPaused(true);
    }

    function testOnlyOwnerCanRefill() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(faucet), 1000e6);
        vm.expectRevert();
        faucet.refill(address(usdc), 1000e6);
        vm.stopPrank();
    }

    function testOnlyOwnerCanEmergencyWithdraw() public {
        vm.prank(alice);
        vm.expectRevert();
        faucet.emergencyWithdraw(address(usdc), 100e6, alice);
    }

    function testCannotClaimWhenInsufficientBalance() public {
        // Empty the faucet
        faucet.emergencyWithdraw(address(usdc), faucet.getFaucetBalance(address(usdc)), owner);

        vm.prank(alice);
        vm.expectRevert(TokenFaucet.InsufficientBalance.selector);
        faucet.claimTokens(address(usdc));
    }
}
