// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "solmate/tokens/ERC20.sol";
import "solmate/utils/SafeTransferLib.sol";
import "solmate/utils/ReentrancyGuard.sol";
import "solmate/auth/Owned.sol";
import "./PlatformToken.sol";
import {ISpoke} from "aave-v4/src/spoke/interfaces/ISpoke.sol";

/**
 * @title DepositManager
 * @author MagRelo
 * @dev Manages USDC deposits, CUT token minting/burning, and yield generation through Aave v4
 *
 * This contract implements a simplified token system where:
 * - Users deposit USDC and receive CUT tokens in a 1:1 ratio
 * - USDC is automatically supplied to Aave v4 for yield generation
 * - If Aave v4 is paused or deposit fails, USDC is stored directly in the contract
 * - Users can withdraw their original deposit amount (1:1 ratio)
 * - All yield generated stays in the contract for platform use
 *
 * Key Features:
 * - 1:1 USDC to CUT token conversion
 * - Automatic Aave v4 integration for yield generation
 * - Fallback to direct USDC storage if Aave is unavailable
 * - Yield retention by platform (no user distribution)
 * - Emergency withdrawal capabilities
 * - Aave v4 pause state handling with graceful fallback
 *
 * @custom:security This contract uses Solmate's ReentrancyGuard and Owned for security
 */
contract DepositManager is ReentrancyGuard, Owned {
    /// @notice The USDC token contract
    ERC20 public immutable usdcToken;

    /// @notice The CUT platform token contract
    PlatformToken public immutable platformToken;

    /// @notice The Aave v4 Spoke contract for yield generation
    ISpoke public immutable aaveSpoke;

    /// @notice The reserve ID for USDC on the Aave Spoke
    uint256 public immutable usdcReserveId;

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
    /// @param owner The address of the contract owner
    /// @param recipient The address receiving the funds
    /// @param amount The total amount withdrawn
    /// @param timestamp The timestamp of the withdrawal
    event EmergencyWithdrawal(address indexed owner, address indexed recipient, uint256 amount, uint256 timestamp);

    /// @notice Emitted when Aave deposit fails and USDC is stored directly in contract
    /// @param user The address of the user making the deposit
    /// @param usdcAmount The amount of USDC stored directly in contract
    /// @param reason The reason for the fallback (e.g., "Aave supply failed")
    event AaveDepositFallback(address indexed user, uint256 usdcAmount, string reason);

    /**
     * @notice Constructor initializes the DepositManager with required contract addresses
     * @dev Sets the deployer as the owner and validates all contract addresses
     * @dev Finds the reserveId for USDC by iterating through reserves
     * @param _usdcToken The address of the USDC token contract
     * @param _platformToken The address of the CUT platform token contract
     * @param _aaveSpoke The address of the Aave v4 Spoke contract
     *
     * Requirements:
     * - All contract addresses must not be zero addresses
     * - USDC must be listed as a reserve on the Aave Spoke
     */
    constructor(address _usdcToken, address _platformToken, address _aaveSpoke) Owned(msg.sender) {
        require(_usdcToken != address(0), "USDC token cannot be zero address");
        require(_platformToken != address(0), "Platform token cannot be zero address");
        require(_aaveSpoke != address(0), "Aave Spoke cannot be zero address");

        usdcToken = ERC20(_usdcToken);
        platformToken = PlatformToken(_platformToken);
        aaveSpoke = ISpoke(_aaveSpoke);

        // Find the reserveId for USDC
        uint256 reserveCount = aaveSpoke.getReserveCount();
        uint256 foundReserveId = type(uint256).max;
        
        for (uint256 i = 0; i < reserveCount; i++) {
            ISpoke.Reserve memory reserve = aaveSpoke.getReserve(i);
            if (reserve.underlying == _usdcToken) {
                foundReserveId = i;
                break;
            }
        }
        
        require(foundReserveId != type(uint256).max, "USDC not found in Aave Spoke reserves");
        usdcReserveId = foundReserveId;
    }

    /**
     * @notice Deposits USDC and mints CUT tokens in a 1:1 ratio
     * @dev Automatically supplies USDC to Aave v4 for yield generation
     * Falls back to storing USDC directly in contract if Aave deposit fails
     * @param amount The amount of USDC to deposit
     *
     * Requirements:
     * - amount must be greater than 0
     * - User must have approved sufficient USDC allowance
     *
     * Emits a {USDCDeposited} event
     * Emits a {AaveDepositFallback} event if Aave deposit fails
     */
    function depositUSDC(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");

        // Calculate platform tokens to mint (1:1 ratio)
        // USDC has 6 decimals, PlatformToken has 18 decimals
        uint256 platformTokensToMint = amount * 1e12; // Convert 6 decimals to 18 decimals

        // Transfer USDC from user to deposit manager
        SafeTransferLib.safeTransferFrom(usdcToken, msg.sender, address(this), amount);

        // Mint platform tokens to user
        platformToken.mint(msg.sender, platformTokensToMint);

        // Check if Aave reserve is paused or frozen
        ISpoke.ReserveConfig memory reserveConfig = aaveSpoke.getReserveConfig(usdcReserveId);
        bool isPaused = reserveConfig.paused;
        bool isFrozen = reserveConfig.frozen;

        // Try to deposit USDC to Aave for yield generation
        // If it fails, USDC remains in the contract as a fallback
        if (!isPaused && !isFrozen) {
            // Approve USDC for Aave - first reset to 0, then approve new amount
            SafeTransferLib.safeApprove(usdcToken, address(aaveSpoke), 0);
            SafeTransferLib.safeApprove(usdcToken, address(aaveSpoke), amount);

            try aaveSpoke.supply(usdcReserveId, amount, address(this)) {
                // Aave deposit successful
            } catch {
                // Aave deposit failed - USDC stays in contract
                emit AaveDepositFallback(msg.sender, amount, "Aave supply failed");
            }
        } else {
            // Aave is paused or frozen - USDC stays in contract
            string memory reason = isPaused ? "Aave supply paused" : "Aave supply frozen";
            emit AaveDepositFallback(msg.sender, amount, reason);
        }

        emit USDCDeposited(msg.sender, amount, platformTokensToMint);
    }

    /**
     * @notice Withdraws USDC by burning the specified amount of CUT tokens
     * @dev Withdraws from Aave v4 if necessary to fulfill the withdrawal
     * Falls back to contract USDC if Aave is paused and sufficient funds are available
     * @param platformTokenAmount The amount of CUT tokens to burn
     *
     * Requirements:
     * - platformTokenAmount must be greater than 0
     * - User must have sufficient CUT token balance
     * - Either Aave v4 withdraw is not paused OR sufficient USDC is available in contract
     *
     * Emits a {USDCWithdrawn} event
     */
    function withdrawUSDC(uint256 platformTokenAmount) external nonReentrant {
        require(platformTokenAmount > 0, "Amount must be greater than 0");
        require(platformToken.balanceOf(msg.sender) >= platformTokenAmount, "Insufficient platform tokens");

        // Calculate USDC to return (1:1 ratio)
        // PlatformToken has 18 decimals, USDC has 6 decimals
        uint256 usdcToReturn = platformTokenAmount / 1e12; // Convert 18 decimals to 6 decimals
        require(usdcToReturn > 0, "No USDC to return");

        // Check if we have sufficient USDC in contract to avoid Aave withdrawal
        uint256 tokenManagerUSDCBalance = usdcToken.balanceOf(address(this));
        bool hasSufficientContractBalance = tokenManagerUSDCBalance >= usdcToReturn;

        // Check if Aave reserve is paused (frozen doesn't block withdrawals)
        ISpoke.ReserveConfig memory reserveConfig = aaveSpoke.getReserveConfig(usdcReserveId);
        bool isPaused = reserveConfig.paused;

        // Only require Aave to be unpaused if we need to withdraw from it
        if (!hasSufficientContractBalance) {
            require(!isPaused, "Aave withdraw is paused and insufficient contract balance");
        }

        // Burn platform tokens from user
        platformToken.burn(msg.sender, platformTokenAmount);

        // Withdraw USDC from Aave if needed
        uint256 currentUSDCBalance = usdcToken.balanceOf(address(this));
        if (currentUSDCBalance < usdcToReturn) {
            uint256 neededFromAave = usdcToReturn - currentUSDCBalance;
            aaveSpoke.withdraw(usdcReserveId, neededFromAave, address(this));
        }

        // Get the actual USDC balance after redemption
        uint256 actualUSDCBalance = usdcToken.balanceOf(address(this));
        uint256 actualUSDCToReturn = actualUSDCBalance < usdcToReturn ? actualUSDCBalance : usdcToReturn;

        // Transfer USDC to user
        SafeTransferLib.safeTransfer(usdcToken, msg.sender, actualUSDCToReturn);

        emit USDCWithdrawn(msg.sender, platformTokenAmount, actualUSDCToReturn);
    }

    /**
     * @notice Gets the USDC balance held directly by this contract
     * @return The USDC balance in the contract (6 decimals)
     */
    function getTokenManagerUSDCBalance() external view returns (uint256) {
        return usdcToken.balanceOf(address(this));
    }

    /**
     * @notice Gets the USDC balance supplied to Aave v4
     * @return The USDC balance in Aave v4 (6 decimals), includes principal + accumulated earnings
     */
    function getAaveUSDCBalance() external view returns (uint256) {
        return aaveSpoke.getUserSuppliedAssets(usdcReserveId, address(this));
    }

    /**
     * @notice Gets the total available USDC balance (contract + Aave v4)
     * @return The total USDC balance available (6 decimals)
     */
    function getTotalAvailableBalance() external view returns (uint256) {
        return usdcToken.balanceOf(address(this)) + aaveSpoke.getUserSuppliedAssets(usdcReserveId, address(this));
    }

    /**
     * @notice Gets the Aave v4 reserve configuration for USDC
     * @return The reserve configuration struct containing paused, frozen, borrowable, etc.
     */
    function getUSDCReserveConfig() external view returns (ISpoke.ReserveConfig memory) {
        return aaveSpoke.getReserveConfig(usdcReserveId);
    }

    /**
     * @notice Gets the Aave v4 reserve data for USDC
     * @return The full reserve struct containing underlying, hub, assetId, etc.
     */
    function getUSDCReserveData() external view returns (ISpoke.Reserve memory) {
        return aaveSpoke.getReserve(usdcReserveId);
    }

    /**
     * @notice Gets the Hub address associated with USDC reserve
     * @dev Rates can be queried from the Hub or its interest rate strategy
     * @return The address of the Hub contract
     */
    function getUSDCHubAddress() external view returns (address) {
        ISpoke.Reserve memory reserve = aaveSpoke.getReserve(usdcReserveId);
        return address(reserve.hub);
    }

    /**
     * @notice Gets the asset ID for USDC in the Hub
     * @return The asset ID used in the Hub
     */
    function getUSDCAssetId() external view returns (uint16) {
        ISpoke.Reserve memory reserve = aaveSpoke.getReserve(usdcReserveId);
        return reserve.assetId;
    }

    /**
     * @notice Gets the Aave v4 supply pause/frozen status
     * @return True if Aave supply is paused or frozen, false otherwise
     * @dev paused blocks all interactions, frozen blocks new supplies/borrows
     */
    function isAaveSupplyPaused() external view returns (bool) {
        ISpoke.ReserveConfig memory config = aaveSpoke.getReserveConfig(usdcReserveId);
        return config.paused || config.frozen;
    }

    /**
     * @notice Gets the Aave v4 withdraw pause status
     * @return True if Aave withdraw is paused, false otherwise
     * @dev Note: frozen state does not block withdrawals, only paused does
     */
    function isAaveWithdrawPaused() external view returns (bool) {
        ISpoke.ReserveConfig memory config = aaveSpoke.getReserveConfig(usdcReserveId);
        return config.paused;
    }

    /**
     * @notice Gets the total accumulated earnings from Aave v4
     * @return The total earnings in USDC (6 decimals)
     * @dev Earnings = current Aave balance - total principal deposited
     * @dev Principal is calculated from total platform tokens minted (1:1 ratio)
     */
    function getAccumulatedEarnings() external view returns (uint256) {
        uint256 currentAaveBalance = aaveSpoke.getUserSuppliedAssets(usdcReserveId, address(this));
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
        require(to != address(0), "Invalid recipient");

        // Calculate required USDC to match token supply
        uint256 totalTokensMinted = platformToken.totalSupply();
        uint256 requiredUSDC = totalTokensMinted / 1e12; // Convert 18 decimals to 6 decimals

        // Calculate current available USDC
        uint256 tokenManagerBalance = usdcToken.balanceOf(address(this));
        uint256 aaveBalance = aaveSpoke.getUserSuppliedAssets(usdcReserveId, address(this));
        uint256 totalAvailableUSDC = tokenManagerBalance + aaveBalance;

        // Calculate excess (yield) that can be taken
        uint256 excessUSDC = 0;
        if (totalAvailableUSDC > requiredUSDC) {
            excessUSDC = totalAvailableUSDC - requiredUSDC;
        }

        require(excessUSDC > 0, "No excess USDC to withdraw");

        // Withdraw from Aave if needed
        if (tokenManagerBalance < excessUSDC) {
            uint256 neededFromAave = excessUSDC - tokenManagerBalance;
            aaveSpoke.withdraw(usdcReserveId, neededFromAave, address(this));
        }

        SafeTransferLib.safeTransfer(usdcToken, to, excessUSDC);

        emit BalanceSupply(msg.sender, to, excessUSDC, block.timestamp);
    }

    /**
     * @notice Emergency withdrawal of all available USDC
     * @dev Only callable by the contract owner in emergency situations
     * @param to The address to receive all USDC
     *
     * This function withdraws all USDC from both the contract and Aave v4,
     * regardless of token supply backing. Use only in emergency situations.
     *
     * Requirements:
     * - Caller must be the contract owner
     * - to must not be the zero address
     * - There must be funds available to withdraw
     *
     * Emits an {EmergencyWithdrawal} event
     */
    function emergencyWithdrawAll(address to) external onlyOwner {
        require(to != address(0), "Invalid recipient");

        uint256 totalBalance = this.getTotalAvailableBalance();
        require(totalBalance > 0, "No funds to withdraw");

        // Withdraw from Aave if needed
        uint256 tokenManagerBalance = usdcToken.balanceOf(address(this));
        if (tokenManagerBalance < totalBalance) {
            uint256 neededFromAave = totalBalance - tokenManagerBalance;
            aaveSpoke.withdraw(usdcReserveId, neededFromAave, address(this));
        }

        SafeTransferLib.safeTransfer(usdcToken, to, totalBalance);

        emit EmergencyWithdrawal(msg.sender, to, totalBalance, block.timestamp);
    }
}
