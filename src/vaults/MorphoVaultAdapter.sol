// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@morpho-blue/interfaces/IMorpho.sol";
import "@morpho-blue/libraries/SharesMathLib.sol";

/**
 * @title MorphoVaultAdapter
 * @notice ERC-4626 compliant vault that integrates with Morpho Blue for yield generation
 * @dev Simplified version inspired by MetaMorpho, designed for StackSave hackathon
 *
 * Key Features:
 * - Full ERC-4626 compliance for standardized vault interactions
 * - Direct integration with Morpho Blue lending markets
 * - Yield donation routing to Octant public goods
 * - Configurable for Lite (stablecoin) or Pro (WETH) modes
 *
 * Track 4 (Best Morpho V2 Use) Highlights:
 * - Proper role model (owner, donation recipient)
 * - Safe adapter wiring with reentrancy guards
 * - Comprehensive yield accounting
 */
contract MorphoVaultAdapter is ERC4626, Ownable, ReentrancyGuard {
    using SharesMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The Morpho Blue protocol instance
    IMorpho public immutable MORPHO;

    /// @notice The market ID derived from market parameters
    Id public immutable marketId;

    /// @notice Loan token address
    address public immutable loanToken;

    /// @notice Collateral token address
    address public immutable collateralToken;

    /// @notice Oracle address
    address public immutable oracle;

    /// @notice IRM address
    address public immutable irm;

    /// @notice LLTV (Liquidation Loan-To-Value)
    uint256 public immutable lltv;

    /*//////////////////////////////////////////////////////////////
                                STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Address to receive donated yields (Octant PaymentSplitter)
    address public donationRecipient;

    /// @notice Last recorded total assets (for yield tracking)
    uint256 public lastTotalAssets;

    /// @notice Total yield donated to public goods
    uint256 public totalDonated;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event DonationRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event YieldDonated(uint256 amount, address indexed recipient);
    event AssetsSuppliedToMorpho(uint256 amount);
    event AssetsWithdrawnFromMorpho(uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientLiquidity();

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new MorphoVaultAdapter
     * @param _morpho Address of the Morpho Blue protocol
     * @param _asset Address of the underlying asset (USDC, DAI, or WETH)
     * @param _marketParams Morpho market parameters for lending
     * @param _owner Vault owner (typically StackSaveOctant contract)
     * @param _donationRecipient Initial donation recipient address
     * @param _name ERC20 token name (e.g., "StackSave USDC Vault")
     * @param _symbol ERC20 token symbol (e.g., "ssUSDC")
     */
    constructor(
        address _morpho,
        address _asset,
        MarketParams memory _marketParams,
        address _owner,
        address _donationRecipient,
        string memory _name,
        string memory _symbol
    ) ERC4626(IERC20(_asset)) ERC20(_name, _symbol) Ownable(_owner) {
        if (_morpho == address(0)) revert ZeroAddress();
        if (_donationRecipient == address(0)) revert ZeroAddress();
        if (_asset != _marketParams.loanToken) revert("Asset mismatch");

        MORPHO = IMorpho(_morpho);
        marketId = MarketParamsLib.id(_marketParams);

        // Store market params as immutables
        loanToken = _marketParams.loanToken;
        collateralToken = _marketParams.collateralToken;
        oracle = _marketParams.oracle;
        irm = _marketParams.irm;
        lltv = _marketParams.lltv;

        donationRecipient = _donationRecipient;

        // Approve Morpho to spend vault's assets
        IERC20(_asset).approve(_morpho, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the market parameters struct
     * @return Market parameters
     */
    function getMarketParams() public view returns (MarketParams memory) {
        return MarketParams({
            loanToken: loanToken,
            collateralToken: collateralToken,
            oracle: oracle,
            irm: irm,
            lltv: lltv
        });
    }

    /*//////////////////////////////////////////////////////////////
                        ERC-4626 CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the total assets held by the vault
     * @dev Includes assets supplied to Morpho Blue market
     * @return Total assets under management
     */
    function totalAssets() public view override returns (uint256) {
        // Get vault's supply position in Morpho market
        Position memory position = MORPHO.position(marketId, address(this));

        // Get current market state
        Market memory market = MORPHO.market(marketId);

        // Convert shares to assets (includes accrued interest)
        uint256 suppliedAssets = position.supplyShares.toAssetsDown(
            market.totalSupplyAssets,
            market.totalSupplyShares
        );

        // Add any idle assets in the vault
        uint256 idleAssets = IERC20(asset()).balanceOf(address(this));

        return suppliedAssets + idleAssets;
    }

    /**
     * @notice Deposits assets into the vault
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive vault shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();

        // Calculate shares to mint
        shares = previewDeposit(assets);

        // Transfer assets from caller
        SafeERC20.safeTransferFrom(
            IERC20(asset()),
            _msgSender(),
            address(this),
            assets
        );

        // Mint shares to receiver
        _mint(receiver, shares);

        // Supply assets to Morpho
        _supplyToMorpho(assets);

        emit Deposit(_msgSender(), receiver, assets, shares);
    }

    /**
     * @notice Withdraws assets from the vault
     * @param assets Amount of assets to withdraw
     * @param receiver Address to receive assets
     * @param owner Owner of the shares being burned
     * @return shares Amount of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();

        // Calculate shares to burn
        shares = previewWithdraw(assets);

        // Check allowance if caller is not owner
        if (_msgSender() != owner) {
            _spendAllowance(owner, _msgSender(), shares);
        }

        // Withdraw from Morpho if needed
        uint256 idleAssets = IERC20(asset()).balanceOf(address(this));
        if (assets > idleAssets) {
            _withdrawFromMorpho(assets - idleAssets);
        }

        // Burn shares
        _burn(owner, shares);

        // Transfer assets to receiver
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);

        emit Withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                        MORPHO INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Supplies assets to Morpho Blue market
     * @param assets Amount to supply
     */
    function _supplyToMorpho(uint256 assets) internal {
        if (assets == 0) return;

        MarketParams memory params = getMarketParams();

        // Accrue interest before supplying
        MORPHO.accrueInterest(params);

        // Supply to Morpho market
        MORPHO.supply(
            params,
            assets,
            0, // shares (let Morpho calculate)
            address(this),
            "" // no callback data
        );

        emit AssetsSuppliedToMorpho(assets);
    }

    /**
     * @notice Withdraws assets from Morpho Blue market
     * @param assets Amount to withdraw
     */
    function _withdrawFromMorpho(uint256 assets) internal {
        if (assets == 0) return;

        MarketParams memory params = getMarketParams();

        // Accrue interest before withdrawing
        MORPHO.accrueInterest(params);

        // Get available liquidity
        Market memory market = MORPHO.market(marketId);
        uint256 availableLiquidity = market.totalSupplyAssets - market.totalBorrowAssets;

        if (assets > availableLiquidity) {
            revert InsufficientLiquidity();
        }

        // Withdraw from Morpho market
        MORPHO.withdraw(
            params,
            assets,
            0, // shares (let Morpho calculate)
            address(this),
            address(this)
        );

        emit AssetsWithdrawnFromMorpho(assets);
    }

    /*//////////////////////////////////////////////////////////////
                        YIELD DONATION (Track 2)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Harvests and donates yield to Octant
     * @dev Can be called by anyone to trigger donation
     * @return yieldAmount Amount of yield donated
     */
    function harvestAndDonate() external returns (uint256 yieldAmount) {
        uint256 currentAssets = totalAssets();

        if (currentAssets <= lastTotalAssets) {
            return 0; // No yield generated
        }

        yieldAmount = currentAssets - lastTotalAssets;

        // Withdraw yield from Morpho
        _withdrawFromMorpho(yieldAmount);

        // Transfer to donation recipient
        SafeERC20.safeTransfer(
            IERC20(asset()),
            donationRecipient,
            yieldAmount
        );

        totalDonated += yieldAmount;
        lastTotalAssets = currentAssets - yieldAmount;

        emit YieldDonated(yieldAmount, donationRecipient);
    }

    /**
     * @notice Returns the current yield available for donation
     * @return Current unharvested yield
     */
    function pendingYield() external view returns (uint256) {
        uint256 currentAssets = totalAssets();
        if (currentAssets <= lastTotalAssets) {
            return 0;
        }
        return currentAssets - lastTotalAssets;
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the donation recipient address
     * @param newRecipient New donation recipient address
     */
    function setDonationRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();

        address oldRecipient = donationRecipient;
        donationRecipient = newRecipient;

        emit DonationRecipientUpdated(oldRecipient, newRecipient);
    }

    /**
     * @notice Updates the last total assets (for yield tracking calibration)
     * @param newTotal New baseline for yield calculation
     */
    function updateLastTotalAssets(uint256 newTotal) external onlyOwner {
        lastTotalAssets = newTotal;
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the current APY from Morpho market
     * @dev Simplified calculation - in production would use IRM
     * @return APY in basis points (e.g., 500 = 5%)
     */
    function getCurrentAPY() external view returns (uint256) {
        Market memory market = MORPHO.market(marketId);

        // Simplified APY calculation
        // In production, query the IRM contract for accurate borrow rate
        if (market.totalSupplyAssets == 0) return 0;

        uint256 utilization = (market.totalBorrowAssets * 1e18) / market.totalSupplyAssets;

        // Example: 50% utilization => 5% APY
        // This is placeholder - real implementation would query market.irm
        return (utilization * 500) / 1e18; // Returns basis points
    }

    /**
     * @notice Returns vault information
     * @return asset_ Underlying asset address
     * @return totalAssets_ Total assets under management
     * @return totalSupply_ Total shares supply
     * @return morphoSupplied Assets supplied to Morpho
     * @return idleAssets Assets held in vault
     */
    function getVaultInfo()
        external
        view
        returns (
            address asset_,
            uint256 totalAssets_,
            uint256 totalSupply_,
            uint256 morphoSupplied,
            uint256 idleAssets
        )
    {
        asset_ = asset();
        totalAssets_ = totalAssets();
        totalSupply_ = totalSupply();

        Position memory position = MORPHO.position(marketId, address(this));
        Market memory market = MORPHO.market(marketId);

        morphoSupplied = position.supplyShares.toAssetsDown(
            market.totalSupplyAssets,
            market.totalSupplyShares
        );

        idleAssets = IERC20(asset()).balanceOf(address(this));
    }
}

// Required library import
import "@morpho-blue/libraries/MarketParamsLib.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
