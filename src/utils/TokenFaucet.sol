// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TokenFaucet
 * @notice Distributes test tokens for StackSave demo
 * @dev Allows users to claim test USDC/DAI/WETH for trying the savings app
 *
 * FEATURES:
 * - Rate limiting: Users can claim once per 24 hours per token
 * - Configurable claim amounts per token
 * - Emergency pause functionality
 * - Owner can refill faucet
 */
contract TokenFaucet is Ownable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant CLAIM_INTERVAL = 24 hours;

    /*//////////////////////////////////////////////////////////////
                                STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim amount per token
    mapping(address => uint256) public claimAmounts;

    /// @notice Last claim time per user per token
    mapping(address => mapping(address => uint256)) public lastClaimTime;

    /// @notice Total claimed per user per token
    mapping(address => mapping(address => uint256)) public totalClaimed;

    /// @notice Supported tokens
    address[] public supportedTokens;

    /// @notice Token support status
    mapping(address => bool) public isTokenSupported;

    /// @notice Pause state
    bool public paused;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event TokensClaimed(
        address indexed user, address indexed token, uint256 amount, uint256 nextClaimTime
    );

    event TokenConfigured(address indexed token, uint256 claimAmount);

    event FaucetRefilled(address indexed token, uint256 amount);

    event PauseToggled(bool paused);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error TokenNotSupported();
    error ClaimTooSoon();
    error InsufficientBalance();
    error ContractPaused();

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner) Ownable(_owner) {}

    /*//////////////////////////////////////////////////////////////
                        CLAIM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claims test tokens
     * @param token Token address to claim
     */
    function claimTokens(address token) external {
        _claimTokensInternal(msg.sender, token);
    }

    /**
     * @notice Claims multiple tokens at once
     * @param tokens Array of token addresses
     */
    function claimMultiple(address[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            _claimTokensInternal(msg.sender, tokens[i]);
        }
    }

    /**
     * @notice Internal function to claim tokens
     * @param user User address claiming tokens
     * @param token Token address to claim
     */
    function _claimTokensInternal(address user, address token) internal {
        if (paused) revert ContractPaused();
        if (!isTokenSupported[token]) revert TokenNotSupported();

        uint256 lastClaim = lastClaimTime[user][token];
        if (lastClaim != 0 && block.timestamp < lastClaim + CLAIM_INTERVAL) {
            revert ClaimTooSoon();
        }

        uint256 amount = claimAmounts[token];
        if (amount == 0) revert ZeroAmount();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();

        // Update state
        lastClaimTime[user][token] = block.timestamp;
        totalClaimed[user][token] += amount;

        // Transfer tokens
        IERC20(token).safeTransfer(user, amount);

        uint256 nextClaimTime = block.timestamp + CLAIM_INTERVAL;

        emit TokensClaimed(user, token, amount, nextClaimTime);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configures a token for the faucet
     * @param token Token address
     * @param amount Amount to distribute per claim
     */
    function configureToken(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();

        if (!isTokenSupported[token]) {
            supportedTokens.push(token);
            isTokenSupported[token] = true;
        }

        claimAmounts[token] = amount;

        emit TokenConfigured(token, amount);
    }

    /**
     * @notice Refills the faucet with tokens
     * @param token Token address
     * @param amount Amount to deposit
     */
    function refill(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit FaucetRefilled(token, amount);
    }

    /**
     * @notice Toggles pause state
     * @param _paused New pause state
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PauseToggled(_paused);
    }

    /**
     * @notice Emergency withdraw
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     * @param recipient Recipient address
     */
    function emergencyWithdraw(address token, uint256 amount, address recipient) external onlyOwner {
        if (token == address(0) || recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(recipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if user can claim a token
     * @param user User address
     * @param token Token address
     * @return claimable Whether user can claim
     * @return nextClaimTime When user can next claim
     */
    function canClaim(address user, address token)
        external
        view
        returns (bool claimable, uint256 nextClaimTime)
    {
        if (!isTokenSupported[token] || paused) {
            return (false, 0);
        }

        uint256 lastClaim = lastClaimTime[user][token];

        // If never claimed before, can claim immediately
        if (lastClaim == 0) {
            nextClaimTime = 0;
            claimable = IERC20(token).balanceOf(address(this)) >= claimAmounts[token];
        } else {
            nextClaimTime = lastClaim + CLAIM_INTERVAL;
            claimable = block.timestamp >= nextClaimTime
                && IERC20(token).balanceOf(address(this)) >= claimAmounts[token];
        }
    }

    /**
     * @notice Gets faucet balance for a token
     * @param token Token address
     * @return balance Faucet balance
     */
    function getFaucetBalance(address token) external view returns (uint256 balance) {
        balance = IERC20(token).balanceOf(address(this));
    }

    /**
     * @notice Gets all supported tokens
     * @return Array of supported token addresses
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    /**
     * @notice Gets user stats for a token
     * @param user User address
     * @param token Token address
     * @return claimed Total amount claimed
     * @return lastClaim Last claim timestamp
     * @return canClaimNow Whether user can claim now
     */
    function getUserStats(address user, address token)
        external
        view
        returns (uint256 claimed, uint256 lastClaim, bool canClaimNow)
    {
        claimed = totalClaimed[user][token];
        lastClaim = lastClaimTime[user][token];

        canClaimNow = isTokenSupported[token] && !paused
            && block.timestamp >= lastClaim + CLAIM_INTERVAL
            && IERC20(token).balanceOf(address(this)) >= claimAmounts[token];
    }
}
