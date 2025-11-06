// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../vaults/MorphoVaultAdapter.sol";
import "./OctantYieldRouter.sol";

/**
 * @title StackSaveOctant
 * @notice Main savings contract for StackSave on Octant hackathon
 * @dev Combines savings goals with yield donation to public goods
 *
 * HACKATHON TRACKS:
 * - Track 1: Best Public Goods Projects - Mobile savings app funding public goods
 * - Track 2: Best Yield Donating Strategy - User-controlled donation percentages
 * - Track 3: Most Creative Use - Turn everyday savers into ongoing PG supporters
 * - Track 4: Best Morpho V2 Use - ERC-4626 vaults with proper integration
 *
 * KEY FEATURES:
 * - Create savings goals with target amounts and durations
 * - Lite mode (stablecoins) and Pro mode (WETH) with real Morpho yields
 * - User-selectable donation percentage (0-100% of yield)
 * - Early withdrawal penalty (2%) split between reward pool and treasury
 * - Multi-currency support (USDC, DAI, WETH)
 */
contract StackSaveOctant is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant PENALTY_RATE = 200; // 2%
    uint256 public constant MIN_DURATION = 90 days;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /*//////////////////////////////////////////////////////////////
                                ENUMS
    //////////////////////////////////////////////////////////////*/

    enum Mode {
        Lite, // Stablecoin lending (USDC/DAI)
        Pro // Higher yield assets (WETH)
    }

    enum GoalStatus {
        Active,
        Completed,
        Abandoned
    }

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Goal {
        uint256 id;
        address owner;
        address currency; // USDC, DAI, or WETH
        Mode mode;
        uint256 targetAmount;
        uint256 duration;
        uint256 donationPercentage; // 0-10000 (0-100%)
        uint256 depositedAmount;
        uint256 createdAt;
        uint256 lastDepositTime;
        GoalStatus status;
    }

    struct DepositInfo {
        uint256 principal;
        uint256 vaultShares; // Shares in MorphoVaultAdapter
        uint256 lastUpdateTime;
    }

    /*//////////////////////////////////////////////////////////////
                                STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Yield router for donations
    OctantYieldRouter public yieldRouter;

    /// @notice Reward pool address (receives half of penalties)
    address public rewardPool;

    /// @notice Treasury address (receives half of penalties)
    address public treasury;

    /// @notice Vaults per currency and mode
    mapping(address => mapping(Mode => MorphoVaultAdapter)) public vaults;

    /// @notice Goal counter
    uint256 public goalCounter;

    /// @notice Goals by ID
    mapping(uint256 => Goal) public goals;

    /// @notice User's goal IDs
    mapping(address => uint256[]) public userGoals;

    /// @notice Deposits per goal
    mapping(uint256 => DepositInfo) public deposits;

    /// @notice Supported currencies
    address[] public supportedCurrencies;

    /// @notice Currency support status
    mapping(address => bool) public isCurrencySupported;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event GoalCreated(
        uint256 indexed goalId,
        address indexed owner,
        address currency,
        Mode mode,
        uint256 targetAmount,
        uint256 duration,
        uint256 donationPercentage
    );

    event Deposited(
        uint256 indexed goalId, address indexed user, uint256 amount, uint256 vaultShares
    );

    event WithdrawnCompleted(
        uint256 indexed goalId,
        address indexed user,
        uint256 principal,
        uint256 yield,
        uint256 userYield,
        uint256 donatedYield
    );

    event WithdrawnEarly(
        uint256 indexed goalId,
        address indexed user,
        uint256 amount,
        uint256 penalty,
        uint256 penaltyToRewards,
        uint256 penaltyToTreasury
    );

    event DonationPercentageUpdated(uint256 indexed goalId, uint256 oldPct, uint256 newPct);

    event VaultConfigured(address indexed currency, Mode mode, address vaultAddress);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidDuration();
    error InvalidPercentage();
    error CurrencyNotSupported();
    error GoalNotActive();
    error GoalNotCompleted();
    error VaultNotConfigured();
    error TargetNotReached();

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _yieldRouter, address _rewardPool, address _treasury) Ownable(msg.sender) {
        if (_yieldRouter == address(0) || _rewardPool == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }

        yieldRouter = OctantYieldRouter(_yieldRouter);
        rewardPool = _rewardPool;
        treasury = _treasury;
    }

    /*//////////////////////////////////////////////////////////////
                        GOAL MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new savings goal
     * @param name Goal name (stored off-chain, passed for event)
     * @param currency Token address (USDC, DAI, WETH)
     * @param mode Lite or Pro
     * @param targetAmount Target savings amount
     * @param duration Goal duration in seconds
     * @param donationPct Percentage of yield to donate (0-10000)
     * @return goalId Created goal ID
     */
    function createGoal(
        string calldata name,
        address currency,
        Mode mode,
        uint256 targetAmount,
        uint256 duration,
        uint256 donationPct
    ) external returns (uint256 goalId) {
        // Validation
        if (!isCurrencySupported[currency]) revert CurrencyNotSupported();
        if (targetAmount == 0) revert ZeroAmount();
        if (duration < MIN_DURATION) revert InvalidDuration();
        if (donationPct > BASIS_POINTS) revert InvalidPercentage();
        if (address(vaults[currency][mode]) == address(0)) revert VaultNotConfigured();

        goalId = ++goalCounter;

        Goal storage goal = goals[goalId];
        goal.id = goalId;
        goal.owner = msg.sender;
        goal.currency = currency;
        goal.mode = mode;
        goal.targetAmount = targetAmount;
        goal.duration = duration;
        goal.donationPercentage = donationPct;
        goal.depositedAmount = 0;
        goal.createdAt = block.timestamp;
        goal.lastDepositTime = 0;
        goal.status = GoalStatus.Active;

        userGoals[msg.sender].push(goalId);

        emit GoalCreated(goalId, msg.sender, currency, mode, targetAmount, duration, donationPct);
    }

    /**
     * @notice Deposits into a savings goal
     * @param goalId Goal ID
     * @param amount Amount to deposit
     */
    function deposit(uint256 goalId, uint256 amount) external nonReentrant {
        Goal storage goal = goals[goalId];

        // Validation
        if (goal.owner != msg.sender) revert Unauthorized();
        if (goal.status != GoalStatus.Active) revert GoalNotActive();
        if (amount == 0) revert ZeroAmount();

        // Transfer tokens from user
        IERC20(goal.currency).safeTransferFrom(msg.sender, address(this), amount);

        // Get vault
        MorphoVaultAdapter vault = vaults[goal.currency][goal.mode];

        // Approve vault to spend
        IERC20(goal.currency).forceApprove(address(vault), amount);

        // Deposit to vault and receive shares
        uint256 shares = vault.deposit(amount, address(this));

        // Update deposit info
        DepositInfo storage depositInfo = deposits[goalId];
        depositInfo.principal += amount;
        depositInfo.vaultShares += shares;
        depositInfo.lastUpdateTime = block.timestamp;

        // Update goal
        goal.depositedAmount += amount;
        goal.lastDepositTime = block.timestamp;

        // Check if goal completed
        if (goal.depositedAmount >= goal.targetAmount) {
            goal.status = GoalStatus.Completed;
        }

        emit Deposited(goalId, msg.sender, amount, shares);
    }

    /**
     * @notice Withdraws from a completed goal
     * @param goalId Goal ID
     */
    function withdrawCompleted(uint256 goalId) external nonReentrant {
        Goal storage goal = goals[goalId];

        // Validation
        if (goal.owner != msg.sender) revert Unauthorized();
        if (goal.status != GoalStatus.Completed) revert GoalNotCompleted();

        DepositInfo storage depositInfo = deposits[goalId];
        MorphoVaultAdapter vault = vaults[goal.currency][goal.mode];

        // Calculate total assets from vault shares
        uint256 totalAssets = vault.convertToAssets(depositInfo.vaultShares);
        uint256 principal = depositInfo.principal;
        uint256 yieldEarned = totalAssets > principal ? totalAssets - principal : 0;

        // Redeem from vault
        vault.redeem(depositInfo.vaultShares, address(this), address(this));

        // Route yield through donation router
        uint256 userYield = 0;
        uint256 donatedYield = 0;

        if (yieldEarned > 0 && goal.donationPercentage > 0) {
            // Approve router to spend
            IERC20(goal.currency).forceApprove(address(yieldRouter), yieldEarned);

            // Route yield
            (userYield, donatedYield) =
                yieldRouter.routeYield(goal.currency, yieldEarned, goal.donationPercentage, msg.sender);
        } else {
            userYield = yieldEarned;
        }

        // Transfer principal to user
        IERC20(goal.currency).safeTransfer(msg.sender, principal);

        // Clear deposit info
        delete deposits[goalId];

        emit WithdrawnCompleted(goalId, msg.sender, principal, yieldEarned, userYield, donatedYield);
    }

    /**
     * @notice Early withdrawal with penalty
     * @param goalId Goal ID
     */
    function withdrawEarly(uint256 goalId) external nonReentrant {
        Goal storage goal = goals[goalId];

        // Validation
        if (goal.owner != msg.sender) revert Unauthorized();
        if (goal.status != GoalStatus.Active) revert GoalNotActive();

        DepositInfo storage depositInfo = deposits[goalId];
        MorphoVaultAdapter vault = vaults[goal.currency][goal.mode];

        // Calculate total
        uint256 totalAssets = vault.convertToAssets(depositInfo.vaultShares);

        // Redeem from vault
        vault.redeem(depositInfo.vaultShares, address(this), address(this));

        // Calculate penalty
        uint256 penalty = (totalAssets * PENALTY_RATE) / BASIS_POINTS;
        uint256 amountAfterPenalty = totalAssets - penalty;

        // Split penalty
        uint256 penaltyToRewards = penalty / 2;
        uint256 penaltyToTreasury = penalty - penaltyToRewards;

        // Transfer amounts
        IERC20(goal.currency).safeTransfer(msg.sender, amountAfterPenalty);
        IERC20(goal.currency).safeTransfer(rewardPool, penaltyToRewards);
        IERC20(goal.currency).safeTransfer(treasury, penaltyToTreasury);

        // Mark as abandoned
        goal.status = GoalStatus.Abandoned;

        // Clear deposit info
        delete deposits[goalId];

        emit WithdrawnEarly(
            goalId, msg.sender, amountAfterPenalty, penalty, penaltyToRewards, penaltyToTreasury
        );
    }

    /**
     * @notice Updates donation percentage for a goal
     * @param goalId Goal ID
     * @param newPercentage New donation percentage
     */
    function setDonationPercentage(uint256 goalId, uint256 newPercentage) external {
        Goal storage goal = goals[goalId];

        if (goal.owner != msg.sender) revert Unauthorized();
        if (newPercentage > BASIS_POINTS) revert InvalidPercentage();

        uint256 oldPct = goal.donationPercentage;
        goal.donationPercentage = newPercentage;

        emit DonationPercentageUpdated(goalId, oldPct, newPercentage);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configures a vault for currency/mode combination
     * @param currency Token address
     * @param mode Lite or Pro
     * @param vaultAddress Vault address
     */
    function configureVault(address currency, Mode mode, address vaultAddress) external onlyOwner {
        if (currency == address(0) || vaultAddress == address(0)) revert ZeroAddress();

        vaults[currency][mode] = MorphoVaultAdapter(vaultAddress);

        // Add to supported currencies if not already
        if (!isCurrencySupported[currency]) {
            supportedCurrencies.push(currency);
            isCurrencySupported[currency] = true;
        }

        emit VaultConfigured(currency, mode, vaultAddress);
    }

    /**
     * @notice Updates yield router
     * @param newRouter New router address
     */
    function setYieldRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        yieldRouter = OctantYieldRouter(newRouter);
    }

    /**
     * @notice Updates reward pool address
     * @param newRewardPool New reward pool
     */
    function setRewardPool(address newRewardPool) external onlyOwner {
        if (newRewardPool == address(0)) revert ZeroAddress();
        rewardPool = newRewardPool;
    }

    /**
     * @notice Updates treasury address
     * @param newTreasury New treasury
     */
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets goal details with yield information
     * @param goalId Goal ID
     * @return goal Goal struct
     * @return currentValue Current value including yield
     * @return yieldEarned Total yield earned
     */
    function getGoalDetails(uint256 goalId)
        external
        view
        returns (Goal memory goal, uint256 currentValue, uint256 yieldEarned)
    {
        goal = goals[goalId];
        DepositInfo memory depositInfo = deposits[goalId];

        if (depositInfo.vaultShares > 0) {
            MorphoVaultAdapter vault = vaults[goal.currency][goal.mode];
            currentValue = vault.convertToAssets(depositInfo.vaultShares);
            yieldEarned = currentValue > depositInfo.principal ? currentValue - depositInfo.principal : 0;
        }
    }

    /**
     * @notice Gets all goals for a user
     * @param user User address
     * @return goalIds Array of goal IDs
     */
    function getUserGoals(address user) external view returns (uint256[] memory) {
        return userGoals[user];
    }

    /**
     * @notice Gets vault APY for a currency/mode
     * @param currency Token address
     * @param mode Lite or Pro
     * @return apy APY in basis points
     */
    function getVaultAPY(address currency, Mode mode) external view returns (uint256 apy) {
        MorphoVaultAdapter vault = vaults[currency][mode];
        if (address(vault) != address(0)) {
            apy = vault.getCurrentAPY();
        }
    }

    /**
     * @notice Gets supported currencies
     * @return Array of supported token addresses
     */
    function getSupportedCurrencies() external view returns (address[] memory) {
        return supportedCurrencies;
    }
}
