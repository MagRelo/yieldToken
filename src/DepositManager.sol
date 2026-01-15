// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "solmate/tokens/ERC20.sol";
import "solmate/utils/SafeTransferLib.sol";
import "solmate/utils/ReentrancyGuard.sol";
import "solmate/auth/Owned.sol";
import "./PlatformToken.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {DataTypes} from "aave-v3/protocol/libraries/types/DataTypes.sol";
import {ReserveConfiguration} from "aave-v3/protocol/libraries/configuration/ReserveConfiguration.sol";

/**
 * @title DepositManager
 * @author MagRelo
 * @dev Manages USDC deposits, CUT token minting/burning, and yield generation through Aave v3
 *
 * This contract implements a simplified token system where:
 * - Users deposit USDC and receive CUT tokens in a 1:1 ratio
 * - USDC is automatically supplied to Aave v3 for yield generation
 * - If Aave v3 is paused or deposit fails, USDC is stored directly in the contract
 * - Users can withdraw their original deposit amount (1:1 ratio)
 * - All yield generated stays in the contract for platform use
 *
 * Key Features:
 * - 1:1 USDC to CUT token conversion
 * - Automatic Aave v3 integration for yield generation
 * - Fallback to direct USDC storage if Aave is unavailable
 * - Yield retention by platform (no user distribution)
 * - Emergency withdrawal capabilities
 * - Aave v3 pause state handling with graceful fallback
 *
 * @custom:security This contract uses Solmate's ReentrancyGuard and Owned for security
 */
contract DepositManager is ReentrancyGuard, Owned {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    /// @notice Minimum deposit amount: $0.01 USDC (0.01e6 = 10000)
    uint256 public constant MIN_DEPOSIT_AMOUNT = 10000; // $0.01 USDC

    /// @notice Maximum deposit amount: $100,000 USDC (100000e6 = 100_000_000_000)
    /// @dev Set to prevent griefing attacks and gas limit issues
    uint256 public constant MAX_DEPOSIT_AMOUNT = 100_000 * 1e6; // $100,000 USDC

    /// @notice Minimum withdrawal amount in CUT tokens: equivalent to $0.01 USDC (10000 * 1e12)
    uint256 public constant MIN_WITHDRAW_AMOUNT = 10000 * 1e12; // $0.01 USDC equivalent in CUT

    /// @notice Paused state - when true, deposits and withdrawals are disabled
    bool public paused;

    /// @notice Error thrown when USDC token address is zero
    error ZeroUSDCAddress();
    /// @notice Error thrown when platform token address is zero
    error ZeroPlatformTokenAddress();
    /// @notice Error thrown when Aave Pool address is zero
    error ZeroAavePoolAddress();
    /// @notice Error thrown when amount is zero or invalid
    error InvalidAmount();
    /// @notice Error thrown when amount is below minimum
    error AmountBelowMinimum();
    /// @notice Error thrown when amount exceeds maximum
    error AmountExceedsMaximum();
    /// @notice Error thrown when user has insufficient platform tokens
    error InsufficientPlatformTokens();
    /// @notice Error thrown when no USDC can be returned
    error NoUSDCToReturn();
    /// @notice Error thrown when Aave withdraw is paused and contract balance is insufficient
    error AaveWithdrawPausedInsufficientBalance();
    /// @notice Error thrown when recipient address is zero
    error InvalidRecipient();
    /// @notice Error thrown when there is no excess USDC to withdraw
    error NoExcessUSDC();
    /// @notice Error thrown when there are no funds to withdraw
    error NoFundsToWithdraw();
    /// @notice Error thrown when contract is paused
    error ContractPaused();

    /// @notice The USDC token contract
    ERC20 public immutable usdcToken;

    /// @notice The CUT platform token contract
    PlatformToken public immutable platformToken;

    /// @notice The Aave v3 Pool contract for yield generation
    IPool public immutable aavePool;

    /// @notice The aToken address for USDC (for balance queries)
    address public immutable aUsdcToken;

    /// @notice Emitted when a user deposits USDC and receives CUT tokens
    /// @param user The address of the user making the deposit
    /// @param usdcAmount The amount of USDC deposited
    /// @param platformTokensMinted The amount of CUT tokens minted
    event USDCDeposited(address indexed user, uint256 usdcAmount, uint256 platformTokensMinted);

    /// @notice Emitted when a user withdraws USDC by burning CUT tokens
    /// @param user The address of the user making the withdrawal
    /// @param platformTokensBurned The amount of CUT tokens burned
    /// @param usdcAmount The amount of USDC withdrawn
    event USDCWithdrawn(address indexed user, uint256 platformTokensBurned, uint256 usdcAmount);

    /// @notice Emitted when the owner withdraws excess USDC (yield)
    /// @param owner The address of the contract owner
    /// @param recipient The address receiving the excess USDC
    /// @param amount The amount of excess USDC withdrawn
    /// @param timestamp The timestamp of the withdrawal
    event BalanceSupply(address indexed owner, address indexed recipient, uint256 amount, uint256 timestamp);

    /// @notice Emitted when the owner performs an emergency withdrawal of all funds
    /// @dev WARNING: This breaks the 1:1 backing guarantee. All CUT tokens become unbacked after this call.
    /// @param owner The address of the contract owner
    /// @param recipient The address receiving the funds
    /// @param amount The total amount withdrawn
    /// @param totalTokensMinted Total CUT tokens minted at time of withdrawal
    /// @param requiredBacking USDC amount required to back all minted tokens
    /// @param backingRatio Backing ratio in basis points before withdrawal (10000 = 100%)
    /// @param timestamp The timestamp of the withdrawal
    event EmergencyWithdrawal(
        address indexed owner,
        address indexed recipient,
        uint256 amount,
        uint256 totalTokensMinted,
        uint256 requiredBacking,
        uint256 backingRatio,
        uint256 timestamp
    );

    /// @notice Emitted when the contract is paused or unpaused
    /// @param owner The address of the contract owner
    /// @param paused True if paused, false if unpaused
    event PauseStateChanged(address indexed owner, bool paused);

    /// @notice Emitted when Aave supply succeeds
    /// @param user The address of the user making the deposit
    /// @param amount The amount of USDC supplied to Aave
    event AaveSupplySuccess(address indexed user, uint256 amount);

    /// @notice Emitted when Aave deposit fails and USDC is stored directly in contract
    /// @param user The address of the user making the deposit
    /// @param usdcAmount The amount of USDC stored directly in contract
    /// @param reason The reason for the fallback (e.g., "Aave supply failed")
    event AaveDepositFallback(address indexed user, uint256 usdcAmount, string reason);

    /**
     * @notice Constructor initializes the DepositManager with required contract addresses
     * @dev Sets the deployer as the owner and validates all contract addresses
     * @param _usdcToken The address of the USDC token contract
     * @param _platformToken The address of the CUT platform token contract
     * @param _aavePool The address of the Aave v3 Pool contract
     *
     * Requirements:
     * - All contract addresses must not be zero addresses
     */
    constructor(address _usdcToken, address _platformToken, address _aavePool) Owned(msg.sender) {
        if (_usdcToken == address(0)) revert ZeroUSDCAddress();
        if (_platformToken == address(0)) revert ZeroPlatformTokenAddress();
        if (_aavePool == address(0)) revert ZeroAavePoolAddress();

        usdcToken = ERC20(_usdcToken);
        platformToken = PlatformToken(_platformToken);
        aavePool = IPool(_aavePool);

        // Get the aToken address for USDC from the pool
        DataTypes.ReserveData memory reserveData = aavePool.getReserveData(_usdcToken);
        aUsdcToken = reserveData.aTokenAddress;
    }

    /**
     * @notice Pauses deposits and withdrawals
     * @dev Only callable by the contract owner
     */
    function pause() external onlyOwner {
        paused = true;
        emit PauseStateChanged(msg.sender, true);
    }

    /**
     * @notice Unpauses deposits and withdrawals
     * @dev Only callable by the contract owner
     */
    function unpause() external onlyOwner {
        paused = false;
        emit PauseStateChanged(msg.sender, false);
    }

    /**
     * @notice Deposits USDC and mints CUT tokens in a 1:1 ratio
     * @dev Automatically supplies USDC to Aave v3 for yield generation
     * Falls back to storing USDC directly in contract if Aave deposit fails
     * @param amount The amount of USDC to deposit
     *
     * Requirements:
     * - Contract must not be paused
     * - amount must be >= $0.01 USDC (MIN_DEPOSIT_AMOUNT) and <= $100,000 USDC (MAX_DEPOSIT_AMOUNT)
     * - User must have approved sufficient USDC allowance
     *
     * Emits a {USDCDeposited} event
     * Emits a {AaveSupplySuccess} event if Aave deposit succeeds
     * Emits a {AaveDepositFallback} event if Aave deposit fails
     */
    function depositUSDC(uint256 amount) external nonReentrant {
        if (paused) revert ContractPaused();
        if (amount == 0) revert InvalidAmount();
        if (amount < MIN_DEPOSIT_AMOUNT) revert AmountBelowMinimum();
        if (amount > MAX_DEPOSIT_AMOUNT) revert AmountExceedsMaximum();

        // Calculate platform tokens to mint (1:1 ratio)
        // USDC has 6 decimals, PlatformToken has 18 decimals
        uint256 platformTokensToMint = amount * 1e12; // Convert 6 decimals to 18 decimals

        // Transfer USDC from user to deposit manager
        SafeTransferLib.safeTransferFrom(usdcToken, msg.sender, address(this), amount);

        // Mint platform tokens to user
        platformToken.mint(msg.sender, platformTokensToMint);

        // Delegate Aave supply logic to internal function
        _supplyToAave(amount, msg.sender);

        emit USDCDeposited(msg.sender, amount, platformTokensToMint);
    }

    /**
     * @notice Withdraws USDC by burning the specified amount of CUT tokens
     * @dev Withdraws from Aave v3 if necessary to fulfill the withdrawal
     * Falls back to contract USDC if Aave is paused and sufficient funds are available
     * @param platformTokenAmount The amount of CUT tokens to burn
     *
     * Requirements:
     * - Contract must not be paused
     * - platformTokenAmount must be >= MIN_WITHDRAW_AMOUNT (equivalent to $0.01 USDC)
     * - User must have sufficient CUT token balance
     * - Either Aave v3 withdraw is not paused OR sufficient USDC is available in contract
     *
     * Emits a {USDCWithdrawn} event
     */
    function withdrawUSDC(uint256 platformTokenAmount) external nonReentrant {
        if (paused) revert ContractPaused();
        if (platformTokenAmount == 0) revert InvalidAmount();
        if (platformTokenAmount < MIN_WITHDRAW_AMOUNT) revert AmountBelowMinimum();
        if (platformToken.balanceOf(msg.sender) < platformTokenAmount) revert InsufficientPlatformTokens();

        // Calculate USDC to return (1:1 ratio)
        // PlatformToken has 18 decimals, USDC has 6 decimals
        uint256 usdcToReturn = platformTokenAmount / 1e12; // Convert 18 decimals to 6 decimals
        if (usdcToReturn == 0) revert NoUSDCToReturn();

        // Check if we have sufficient USDC in contract to avoid Aave withdrawal
        uint256 tokenManagerUSDCBalance = usdcToken.balanceOf(address(this));
        bool hasSufficientContractBalance = tokenManagerUSDCBalance >= usdcToReturn;

        // Check if Aave reserve is paused (frozen doesn't block withdrawals)
        // Only require Aave to be unpaused if we need to withdraw from it
        if (!hasSufficientContractBalance) {
            DataTypes.ReserveConfigurationMap memory config = aavePool.getConfiguration(address(usdcToken));
            if (config.getPaused()) revert AaveWithdrawPausedInsufficientBalance();
        }

        // Burn platform tokens from user
        platformToken.burn(msg.sender, platformTokenAmount);

        // Withdraw USDC from Aave if needed using internal function
        uint256 currentUSDCBalance = tokenManagerUSDCBalance; // Use cached value
        if (currentUSDCBalance < usdcToReturn) {
            uint256 neededFromAave = usdcToReturn - currentUSDCBalance;
            uint256 amountWithdrawn = _withdrawFromAave(neededFromAave);

            // Check if we got the full amount requested
            if (amountWithdrawn < neededFromAave) {
                // Partial withdrawal - adjust usdcToReturn to what we actually got
                usdcToReturn = currentUSDCBalance + amountWithdrawn;
            }
        }

        // Get the actual USDC balance after redemption
        uint256 actualUSDCBalance = usdcToken.balanceOf(address(this));
        uint256 actualUSDCToReturn = actualUSDCBalance < usdcToReturn ? actualUSDCBalance : usdcToReturn;

        // Transfer USDC to user
        SafeTransferLib.safeTransfer(usdcToken, msg.sender, actualUSDCToReturn);

        emit USDCWithdrawn(msg.sender, platformTokenAmount, actualUSDCToReturn);
    }

    /**
     * @notice Internal function to supply USDC to Aave v3 for yield generation
     * @dev Handles all Aave supply logic including approvals, pause checks, and error handling
     * @param amount The amount of USDC to supply to Aave
     * @param user The address making the deposit (for event logging)
     */
    function _supplyToAave(uint256 amount, address user) internal {
        // Check if Aave reserve is paused or frozen
        DataTypes.ReserveConfigurationMap memory config = aavePool.getConfiguration(address(usdcToken));
        bool isPaused = config.getPaused();
        bool isFrozen = config.getFrozen();

        // If paused/frozen, skip Aave and keep USDC in contract
        if (isPaused || isFrozen) {
            string memory reason = isPaused ? "Aave supply paused" : "Aave supply frozen";
            emit AaveDepositFallback(user, amount, reason);
            return;
        }

        // Approve USDC for Aave - first reset to 0, then approve new amount
        SafeTransferLib.safeApprove(usdcToken, address(aavePool), 0);
        SafeTransferLib.safeApprove(usdcToken, address(aavePool), amount);

        // Try to supply to Aave (V3 supply doesn't return values)
        try aavePool.supply(address(usdcToken), amount, address(this), 0) {
            emit AaveSupplySuccess(user, amount);
        } catch {
            // Aave deposit failed - USDC stays in contract
            emit AaveDepositFallback(user, amount, "Aave supply failed");
        }
    }

    /**
     * @notice Internal function to withdraw USDC from Aave v3
     * @dev Handles all Aave withdraw logic including pause checks and error handling
     * @param amount The amount of USDC to withdraw from Aave
     * @return amountWithdrawn The amount actually withdrawn from Aave (0 if paused or failed)
     */
    function _withdrawFromAave(uint256 amount) internal returns (uint256 amountWithdrawn) {
        // Check if Aave reserve is paused (frozen doesn't block withdrawals)
        DataTypes.ReserveConfigurationMap memory config = aavePool.getConfiguration(address(usdcToken));
        bool isPaused = config.getPaused();

        if (isPaused) {
            return 0; // Can't withdraw if paused
        }

        // Try to withdraw from Aave (V3 withdraw returns the amount withdrawn)
        try aavePool.withdraw(address(usdcToken), amount, address(this)) returns (uint256 withdrawn) {
            return withdrawn;
        } catch {
            // Aave withdrawal failed
            return 0;
        }
    }

    /**
     * @notice Gets the USDC balance held directly by this contract
     * @return The USDC balance in the contract (6 decimals)
     */
    function getTokenManagerUSDCBalance() external view returns (uint256) {
        return usdcToken.balanceOf(address(this));
    }

    /**
     * @notice Gets the USDC balance supplied to Aave v3
     * @return The USDC balance in Aave v3 (6 decimals), includes principal + accumulated earnings
     */
    function getAaveUSDCBalance() external view returns (uint256) {
        return ERC20(aUsdcToken).balanceOf(address(this));
    }

    /**
     * @notice Gets the total available USDC balance (contract + Aave v3)
     * @return The total USDC balance available (6 decimals)
     */
    function getTotalAvailableBalance() external view returns (uint256) {
        return usdcToken.balanceOf(address(this)) + ERC20(aUsdcToken).balanceOf(address(this));
    }

    /**
     * @notice Gets the Aave v3 reserve configuration for USDC
     * @return The reserve configuration map containing paused, frozen, etc. flags
     */
    function getUSDCReserveConfig() external view returns (DataTypes.ReserveConfigurationMap memory) {
        return aavePool.getConfiguration(address(usdcToken));
    }

    /**
     * @notice Gets the Aave v3 reserve data for USDC
     * @return The full reserve data struct
     */
    function getUSDCReserveData() external view returns (DataTypes.ReserveData memory) {
        return aavePool.getReserveData(address(usdcToken));
    }

    /**
     * @notice Gets the aToken address for USDC
     * @return The address of the aUSDC token
     */
    function getATokenAddress() external view returns (address) {
        return aUsdcToken;
    }

    /**
     * @notice Gets the Aave v3 supply pause/frozen status
     * @return True if Aave supply is paused or frozen, false otherwise
     * @dev paused blocks all interactions, frozen blocks new supplies/borrows
     */
    function isAaveSupplyPaused() external view returns (bool) {
        DataTypes.ReserveConfigurationMap memory config = aavePool.getConfiguration(address(usdcToken));
        return config.getPaused() || config.getFrozen();
    }

    /**
     * @notice Gets the Aave v3 withdraw pause status
     * @return True if Aave withdraw is paused, false otherwise
     * @dev Note: frozen state does not block withdrawals, only paused does
     */
    function isAaveWithdrawPaused() external view returns (bool) {
        DataTypes.ReserveConfigurationMap memory config = aavePool.getConfiguration(address(usdcToken));
        return config.getPaused();
    }

    /**
     * @notice Gets the total accumulated earnings from Aave v3
     * @return The total earnings in USDC (6 decimals)
     * @dev Earnings = current Aave balance - total principal deposited
     * @dev Principal is calculated from total platform tokens minted (1:1 ratio)
     */
    function getAccumulatedEarnings() external view returns (uint256) {
        uint256 currentAaveBalance = ERC20(aUsdcToken).balanceOf(address(this));
        uint256 totalTokensMinted = platformToken.totalSupply();
        uint256 totalPrincipalDeposited = totalTokensMinted / 1e12; // Convert 18 decimals to 6 decimals

        if (currentAaveBalance > totalPrincipalDeposited) {
            return currentAaveBalance - totalPrincipalDeposited;
        }
        return 0;
    }

    /**
     * @notice Gets the current yield rate (earnings as percentage of principal)
     * @return The yield rate in basis points (BPS), where 10000 = 100%
     * @dev Returns 0 if no principal has been deposited
     */
    function getCurrentYieldRate() external view returns (uint256) {
        uint256 totalTokensMinted = platformToken.totalSupply();
        uint256 totalPrincipalDeposited = totalTokensMinted / 1e12; // Convert 18 decimals to 6 decimals

        if (totalPrincipalDeposited == 0) {
            return 0;
        }

        uint256 earnings = this.getAccumulatedEarnings();
        // Calculate in basis points: (earnings * 10000) / principal
        return (earnings * 10000) / totalPrincipalDeposited;
    }

    /**
     * @notice Withdraws excess USDC (yield) while ensuring token supply remains backed
     * @dev Only callable by the contract owner
     * @param to The address to receive the excess USDC
     *
     * This function calculates the excess USDC (yield) that can be withdrawn while
     * maintaining sufficient backing for all minted CUT tokens.
     *
     * Requirements:
     * - Caller must be the contract owner
     * - to must not be the zero address
     * - There must be excess USDC available (yield generated)
     *
     * Emits a {BalanceSupply} event
     */
    function balanceSupply(address to) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();

        // Calculate required USDC to match token supply
        uint256 totalTokensMinted = platformToken.totalSupply();
        uint256 requiredUSDC = totalTokensMinted / 1e12; // Convert 18 decimals to 6 decimals

        // Calculate current available USDC
        uint256 tokenManagerBalance = usdcToken.balanceOf(address(this));
        uint256 aaveBalance = ERC20(aUsdcToken).balanceOf(address(this));
        uint256 totalAvailableUSDC = tokenManagerBalance + aaveBalance;

        // Calculate excess (yield) that can be taken
        uint256 excessUSDC = 0;
        if (totalAvailableUSDC > requiredUSDC) {
            excessUSDC = totalAvailableUSDC - requiredUSDC;
        }

        if (excessUSDC == 0) revert NoExcessUSDC();

        // Withdraw from Aave if needed using internal function
        if (tokenManagerBalance < excessUSDC) {
            uint256 neededFromAave = excessUSDC - tokenManagerBalance;
            _withdrawFromAave(neededFromAave);
        }

        SafeTransferLib.safeTransfer(usdcToken, to, excessUSDC);

        emit BalanceSupply(msg.sender, to, excessUSDC, block.timestamp);
    }

    /**
     * @notice Emergency withdrawal of all available USDC
     * @dev WARNING: This breaks the 1:1 backing guarantee permanently. All CUT tokens become unbacked after this call.
     * @dev Only callable by the contract owner. Owner can call at any time for true emergencies.
     * @param to The address to receive all USDC
     *
     * This function withdraws all USDC from both the contract and Aave v3,
     * regardless of token supply backing. Use only in emergency situations.
     *
     * Requirements:
     * - Caller must be the contract owner
     * - to must not be the zero address
     * - There must be funds available to withdraw
     *
     * Emits an {EmergencyWithdrawal} event with comprehensive state information
     */
    function emergencyWithdrawAll(address to) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();

        // Get state before withdrawal for comprehensive logging
        uint256 totalBalance = this.getTotalAvailableBalance();
        uint256 totalTokensMinted = platformToken.totalSupply();
        uint256 requiredBacking = totalTokensMinted / 1e12; // Convert 18 decimals to 6 decimals
        uint256 backingRatio = 0;

        if (totalBalance == 0) revert NoFundsToWithdraw();

        // Calculate backing ratio before withdrawal (in basis points, where 10000 = 100%)
        if (totalTokensMinted > 0 && requiredBacking > 0) {
            backingRatio = (totalBalance * 10000) / requiredBacking;
        }

        // Withdraw from Aave if needed using internal function
        uint256 tokenManagerBalance = usdcToken.balanceOf(address(this));
        if (tokenManagerBalance < totalBalance) {
            uint256 neededFromAave = totalBalance - tokenManagerBalance;
            uint256 amountWithdrawn = _withdrawFromAave(neededFromAave);

            // If partial withdrawal or failure, adjust totalBalance to what we actually have
            if (amountWithdrawn < neededFromAave) {
                totalBalance = tokenManagerBalance + amountWithdrawn;
            } else {
                // Full withdrawal - update totalBalance to current state
                totalBalance = this.getTotalAvailableBalance();
            }
        }

        SafeTransferLib.safeTransfer(usdcToken, to, totalBalance);

        // Comprehensive event with all state information
        emit EmergencyWithdrawal(
            msg.sender, to, totalBalance, totalTokensMinted, requiredBacking, backingRatio, block.timestamp
        );
    }
}
