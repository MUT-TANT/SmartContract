// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OctantYieldRouter
 * @notice Programmatic yield donation routing for StackSave
 * @dev Track 2 (Best use of Yield Donating Strategy) submission
 *
 * YIELD ROUTING POLICY:
 * =====================
 * 1. Users deposit assets into savings goals via StackSaveOctant
 * 2. Assets are deployed to Morpho V2 vaults earning yield
 * 3. Users set donation percentage (0-100%) per goal at creation or update
 * 4. On withdrawal:
 *    - Calculate total yield earned since deposit
 *    - Split yield: userAmount = yield × (100 - donationPct) / 100
 *    - Split yield: donationAmount = yield × donationPct / 100
 * 5. User portion transferred to user wallet
 * 6. Donation portion routed to Octant PaymentSplitter
 * 7. Octant distributes donations to public goods projects via quadratic funding
 *
 * FEATURES:
 * - Programmatic allocation based on user-defined percentages
 * - Transparent on-chain tracking of all donations
 * - Supports multiple tokens (USDC, DAI, WETH)
 * - Emergency pause functionality
 * - Comprehensive event emission for transparency
 */
contract OctantYieldRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis points for percentage calculations (100% = 10000)
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Maximum donation percentage (100%)
    uint256 public constant MAX_DONATION_PCT = 10000;

    /*//////////////////////////////////////////////////////////////
                                STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Address of Octant's PaymentSplitter contract
    address public octantPaymentSplitter;

    /// @notice Emergency pause state
    bool public paused;

    /// @notice Total donations per token
    mapping(address => uint256) public totalDonatedByToken;

    /// @notice Total donations per user per token
    mapping(address => mapping(address => uint256)) public donationsByUser;

    /// @notice Whitelisted tokens that can be donated
    mapping(address => bool) public whitelistedTokens;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event YieldDonated(
        address indexed user,
        address indexed token,
        uint256 totalYield,
        uint256 userAmount,
        uint256 donationAmount,
        uint256 donationPercentage
    );

    event OctantRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event TokenWhitelisted(address indexed token, bool status);
    event EmergencyPaused(bool status);
    event DonationRescued(address indexed token, uint256 amount, address indexed recipient);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error InvalidPercentage();
    error TokenNotWhitelisted();
    error ContractPaused();
    error InsufficientYield();

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new OctantYieldRouter
     * @param _octantPaymentSplitter Address of Octant's PaymentSplitter
     * @param _owner Contract owner (typically StackSaveOctant)
     * @param _initialTokens Initial whitelisted tokens (USDC, DAI, WETH)
     */
    constructor(
        address _octantPaymentSplitter,
        address _owner,
        address[] memory _initialTokens
    ) Ownable(_owner) {
        if (_octantPaymentSplitter == address(0)) revert ZeroAddress();

        octantPaymentSplitter = _octantPaymentSplitter;

        // Whitelist initial tokens
        for (uint256 i = 0; i < _initialTokens.length; i++) {
            whitelistedTokens[_initialTokens[i]] = true;
            emit TokenWhitelisted(_initialTokens[i], true);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        YIELD ROUTING CORE LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Routes yield based on user-defined donation percentage
     * @dev This is the core function for Track 2 submission
     *
     * @param token Address of the token being donated
     * @param totalYield Total yield earned by the user
     * @param donationPct Donation percentage in basis points (0-10000)
     * @param user Address of the user
     * @return userAmount Amount sent to user
     * @return donationAmount Amount sent to Octant
     *
     * Example:
     * - totalYield = 100 USDC
     * - donationPct = 3000 (30%)
     * - userAmount = 70 USDC (sent to user)
     * - donationAmount = 30 USDC (sent to Octant)
     */
    function routeYield(
        address token,
        uint256 totalYield,
        uint256 donationPct,
        address user
    ) external nonReentrant returns (uint256 userAmount, uint256 donationAmount) {
        // Validation
        if (paused) revert ContractPaused();
        if (token == address(0) || user == address(0)) revert ZeroAddress();
        if (totalYield == 0) revert ZeroAmount();
        if (donationPct > MAX_DONATION_PCT) revert InvalidPercentage();
        if (!whitelistedTokens[token]) revert TokenNotWhitelisted();

        // Calculate split
        donationAmount = (totalYield * donationPct) / BASIS_POINTS;
        userAmount = totalYield - donationAmount;

        // Verify contract has enough tokens
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < totalYield) revert InsufficientYield();

        // Transfer user portion
        if (userAmount > 0) {
            IERC20(token).safeTransfer(user, userAmount);
        }

        // Transfer donation portion to Octant
        if (donationAmount > 0) {
            IERC20(token).safeTransfer(octantPaymentSplitter, donationAmount);

            // Update tracking
            totalDonatedByToken[token] += donationAmount;
            donationsByUser[user][token] += donationAmount;
        }

        emit YieldDonated(user, token, totalYield, userAmount, donationAmount, donationPct);
    }

    /**
     * @notice Batch route yield for multiple users
     * @dev Gas-efficient batch processing
     *
     * @param tokens Array of token addresses
     * @param yields Array of total yield amounts
     * @param donationPcts Array of donation percentages
     * @param users Array of user addresses
     */
    function batchRouteYield(
        address[] calldata tokens,
        uint256[] calldata yields,
        uint256[] calldata donationPcts,
        address[] calldata users
    ) external nonReentrant {
        if (
            tokens.length != yields.length || yields.length != donationPcts.length
                || donationPcts.length != users.length
        ) {
            revert("Array length mismatch");
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            this.routeYield(tokens[i], yields[i], donationPcts[i], users[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the Octant PaymentSplitter address
     * @param newRecipient New PaymentSplitter address
     */
    function setOctantRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();

        address oldRecipient = octantPaymentSplitter;
        octantPaymentSplitter = newRecipient;

        emit OctantRecipientUpdated(oldRecipient, newRecipient);
    }

    /**
     * @notice Whitelists or blacklists a token
     * @param token Token address
     * @param status Whitelist status
     */
    function setTokenWhitelist(address token, bool status) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();

        whitelistedTokens[token] = status;

        emit TokenWhitelisted(token, status);
    }

    /**
     * @notice Emergency pause toggle
     * @param _paused Pause status
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit EmergencyPaused(_paused);
    }

    /**
     * @notice Emergency rescue of stuck tokens
     * @dev Only callable by owner, for emergency situations
     * @param token Token to rescue
     * @param amount Amount to rescue
     * @param recipient Recipient address
     */
    function rescueTokens(address token, uint256 amount, address recipient) external onlyOwner {
        if (token == address(0) || recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(recipient, amount);

        emit DonationRescued(token, amount, recipient);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculates yield split for a given amount and percentage
     * @param totalYield Total yield amount
     * @param donationPct Donation percentage in basis points
     * @return userAmount Amount for user
     * @return donationAmount Amount for donation
     */
    function calculateSplit(uint256 totalYield, uint256 donationPct)
        external
        pure
        returns (uint256 userAmount, uint256 donationAmount)
    {
        donationAmount = (totalYield * donationPct) / BASIS_POINTS;
        userAmount = totalYield - donationAmount;
    }

    /**
     * @notice Gets total donations for a user across all tokens
     * @param user User address
     * @param tokens Array of token addresses to check
     * @return total Total donations across specified tokens
     */
    function getTotalDonationsByUser(address user, address[] calldata tokens)
        external
        view
        returns (uint256 total)
    {
        for (uint256 i = 0; i < tokens.length; i++) {
            total += donationsByUser[user][tokens[i]];
        }
    }

    /**
     * @notice Gets global donation statistics
     * @param tokens Array of tokens to check
     * @return totalDonations Total donated across all tokens
     * @return donationsByToken Array of donations per token
     */
    function getGlobalStats(address[] calldata tokens)
        external
        view
        returns (uint256 totalDonations, uint256[] memory donationsByToken)
    {
        donationsByToken = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            donationsByToken[i] = totalDonatedByToken[tokens[i]];
            totalDonations += donationsByToken[i];
        }
    }

    /**
     * @notice Checks if a token is whitelisted
     * @param token Token address
     * @return Whitelist status
     */
    function isTokenWhitelisted(address token) external view returns (bool) {
        return whitelistedTokens[token];
    }
}
