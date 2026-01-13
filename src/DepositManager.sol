// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "solmate/tokens/ERC20.sol";
import "solmate/utils/SafeTransferLib.sol";
import "solmate/utils/ReentrancyGuard.sol";
import "solmate/auth/Owned.sol";
import "./PlatformToken.sol";

/**
 * @title ICErc20
 * @dev Interface for Compound V3 Comet protocol integration
 *
 * This interface defines the core functions needed to interact with Compound V3 Comet
 * for yield generation and lending functionality.
 */
interface ICErc20 {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function balanceOf(address owner) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function isSupplyPaused() external view returns (bool);
    function isWithdrawPaused() external view returns (bool);
}

/**
 * @title DepositManager
 * @author MagRelo
 * @dev Manages USDC deposits, CUT token minting/burning, and yield generation through Compound V3
 *
 * This contract implements a simplified token system where:
 * - Users deposit USDC and receive CUT tokens in a 1:1 ratio
 * - USDC is automatically supplied to Compound V3 for yield generation
 * - If Compound V3 is paused or deposit fails, USDC is stored directly in the contract
 * - Users can withdraw their original deposit amount (1:1 ratio)
 * - All yield generated stays in the contract for platform use
 *
 * Key Features:
 * - 1:1 USDC to CUT token conversion
 * - Automatic Compound V3 integration for yield generation
 * - Fallback to direct USDC storage if Compound is unavailable
 * - Yield retention by platform (no user distribution)
 * - Emergency withdrawal capabilities
 * - Compound V3 pause state handling with graceful fallback
 *
 * @custom:security This contract uses Solmate's ReentrancyGuard and Owned for security
 */
contract DepositManager is ReentrancyGuard, Owned {
    /// @notice The USDC token contract
    ERC20 public immutable usdcToken;

    /// @notice The CUT platform token contract
    PlatformToken public immutable platformToken;

    /// @notice The Compound V3 Comet contract for yield generation
    ICErc20 public immutable cUSDC;

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

    /// @notice Emitted when Compound deposit fails and USDC is stored directly in contract
    /// @param user The address of the user making the deposit
    /// @param usdcAmount The amount of USDC stored directly in contract
    /// @param reason The reason for the fallback (e.g., "Compound supply failed")
    event CompoundDepositFallback(address indexed user, uint256 usdcAmount, string reason);

    /**
     * @notice Constructor initializes the DepositManager with required contract addresses
     * @dev Sets the deployer as the owner and validates all contract addresses
     * @param _usdcToken The address of the USDC token contract
     * @param _platformToken The address of the CUT platform token contract
     * @param _cUSDC The address of the Compound V3 Comet contract
     *
     * Requirements:
     * - All contract addresses must not be zero addresses
     */
    constructor(address _usdcToken, address _platformToken, address _cUSDC) Owned(msg.sender) {
        require(_usdcToken != address(0), "USDC token cannot be zero address");
        require(_platformToken != address(0), "Platform token cannot be zero address");
        require(_cUSDC != address(0), "CUSDC cannot be zero address");

        usdcToken = ERC20(_usdcToken);
        platformToken = PlatformToken(_platformToken);
        cUSDC = ICErc20(_cUSDC);
    }

    /**
     * @notice Deposits USDC and mints CUT tokens in a 1:1 ratio
     * @dev Automatically supplies USDC to Compound V3 for yield generation
     * Falls back to storing USDC directly in contract if Compound deposit fails
     * @param amount The amount of USDC to deposit
     *
     * Requirements:
     * - amount must be greater than 0
     * - User must have approved sufficient USDC allowance
     *
     * Emits a {USDCDeposited} event
     * Emits a {CompoundDepositFallback} event if Compound deposit fails
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

        // Try to deposit USDC to Compound for yield generation
        // If it fails, USDC remains in the contract as a fallback
        if (!cUSDC.isSupplyPaused()) {
            // Approve USDC for Compound - first reset to 0, then approve new amount
            SafeTransferLib.safeApprove(usdcToken, address(cUSDC), 0);
            SafeTransferLib.safeApprove(usdcToken, address(cUSDC), amount);

            try cUSDC.supply(address(usdcToken), amount) {
                // Compound deposit successful
            } catch {
                // Compound deposit failed - USDC stays in contract
                emit CompoundDepositFallback(msg.sender, amount, "Compound supply failed");
            }
        } else {
            // Compound is paused - USDC stays in contract
            emit CompoundDepositFallback(msg.sender, amount, "Compound supply paused");
        }

        emit USDCDeposited(msg.sender, amount, platformTokensToMint);
    }

    /**
     * @notice Withdraws USDC by burning the specified amount of CUT tokens
     * @dev Withdraws from Compound V3 if necessary to fulfill the withdrawal
     * Falls back to contract USDC if Compound is paused and sufficient funds are available
     * @param platformTokenAmount The amount of CUT tokens to burn
     *
     * Requirements:
     * - platformTokenAmount must be greater than 0
     * - User must have sufficient CUT token balance
     * - Either Compound V3 withdraw is not paused OR sufficient USDC is available in contract
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

        // Check if we have sufficient USDC in contract to avoid Compound withdrawal
        uint256 tokenManagerUSDCBalance = usdcToken.balanceOf(address(this));
        bool hasSufficientContractBalance = tokenManagerUSDCBalance >= usdcToReturn;

        // Only require Compound to be unpaused if we need to withdraw from it
        if (!hasSufficientContractBalance) {
            require(!cUSDC.isWithdrawPaused(), "Compound withdraw is paused and insufficient contract balance");
        }

        // Burn platform tokens from user
        platformToken.burn(msg.sender, platformTokenAmount);

        // Withdraw USDC from Compound if needed
        uint256 currentUSDCBalance = usdcToken.balanceOf(address(this));
        if (currentUSDCBalance < usdcToReturn) {
            uint256 neededFromCompound = usdcToReturn - currentUSDCBalance;
            cUSDC.withdraw(address(usdcToken), neededFromCompound);
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
     * @notice Gets the USDC balance supplied to Compound V3
     * @return The USDC balance in Compound V3 (6 decimals)
     */
    function getCompoundUSDCBalance() external view returns (uint256) {
        return cUSDC.balanceOf(address(this));
    }

    /**
     * @notice Gets the total available USDC balance (contract + Compound V3)
     * @return The total USDC balance available (6 decimals)
     */
    function getTotalAvailableBalance() external view returns (uint256) {
        return usdcToken.balanceOf(address(this)) + cUSDC.balanceOf(address(this));
    }

    /**
     * @notice Gets the Compound V3 supply pause status
     * @return True if Compound supply is paused, false otherwise
     */
    function isCompoundSupplyPaused() external view returns (bool) {
        return cUSDC.isSupplyPaused();
    }

    /**
     * @notice Gets the Compound V3 withdraw pause status
     * @return True if Compound withdraw is paused, false otherwise
     */
    function isCompoundWithdrawPaused() external view returns (bool) {
        return cUSDC.isWithdrawPaused();
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
        uint256 compoundBalance = cUSDC.balanceOf(address(this));
        uint256 totalAvailableUSDC = tokenManagerBalance + compoundBalance;

        // Calculate excess (yield) that can be taken
        uint256 excessUSDC = 0;
        if (totalAvailableUSDC > requiredUSDC) {
            excessUSDC = totalAvailableUSDC - requiredUSDC;
        }

        require(excessUSDC > 0, "No excess USDC to withdraw");

        // Withdraw from Compound if needed
        if (tokenManagerBalance < excessUSDC) {
            uint256 neededFromCompound = excessUSDC - tokenManagerBalance;
            cUSDC.withdraw(address(usdcToken), neededFromCompound);
        }

        SafeTransferLib.safeTransfer(usdcToken, to, excessUSDC);

        emit BalanceSupply(msg.sender, to, excessUSDC, block.timestamp);
    }

    /**
     * @notice Emergency withdrawal of all available USDC
     * @dev Only callable by the contract owner in emergency situations
     * @param to The address to receive all USDC
     *
     * This function withdraws all USDC from both the contract and Compound V3,
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

        // Withdraw from Compound if needed
        uint256 tokenManagerBalance = usdcToken.balanceOf(address(this));
        if (tokenManagerBalance < totalBalance) {
            uint256 neededFromCompound = totalBalance - tokenManagerBalance;
            cUSDC.withdraw(address(usdcToken), neededFromCompound);
        }

        SafeTransferLib.safeTransfer(usdcToken, to, totalBalance);

        emit EmergencyWithdrawal(msg.sender, to, totalBalance, block.timestamp);
    }
}
