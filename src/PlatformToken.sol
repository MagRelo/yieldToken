// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "solmate/tokens/ERC20.sol";
import "solmate/auth/Owned.sol";

/**
 * @title PlatformToken
 * @author MagRelo
 * @dev ERC20 token for the Cut platform (CUT)
 *
 * This token implements a simple ERC20 with restricted minting and burning capabilities.
 * Only the designated DepositManager contract can mint and burn tokens.
 *
 * Key Features:
 * - Standard ERC20 functionality
 * - Restricted minting/burning to DepositManager only
 * - Owner-controlled DepositManager assignment
 * - Comprehensive event logging
 *
 * @custom:security This contract uses Solmate's Owned for access control
 */
contract PlatformToken is ERC20, Owned {
    /// @notice Error thrown when DepositManager is not set
    error DepositManagerNotSet();
    /// @notice Error thrown when caller is not the DepositManager
    error OnlyDepositManager();
    /// @notice Error thrown when depositManager address is invalid
    error InvalidDepositManagerAddress();
    /// @notice Error thrown when trying to mint to zero address
    error CannotMintToZeroAddress();
    /// @notice Error thrown when amount is zero or invalid
    error InvalidAmount();
    /// @notice Error thrown when trying to burn from zero address
    error CannotBurnFromZeroAddress();
    /// @notice Error thrown when balance is insufficient for burn
    error InsufficientBalance();
    /// @notice Address of the DepositManager contract that can mint and burn tokens
    address public depositManager;

    /// @notice Emitted when the DepositManager address is set
    /// @param depositManager The new DepositManager address
    event DepositManagerSet(address indexed depositManager);

    /// @notice Emitted when tokens are minted by the DepositManager
    /// @param to The address receiving the minted tokens
    /// @param amount The amount of tokens minted
    event DepositManagerMint(address indexed to, uint256 amount);

    /// @notice Emitted when tokens are burned by the DepositManager
    /// @param from The address having tokens burned
    /// @param amount The amount of tokens burned
    event DepositManagerBurn(address indexed from, uint256 amount);

    /**
     * @dev Constructor initializes the ERC20 token with custom name and symbol
     * Sets the deployer as the owner of the contract
     * @param name The name of the token (defaults to "Cut Platform Token" if empty)
     * @param symbol The symbol of the token (defaults to "CUT" if empty)
     */
    constructor(string memory name, string memory symbol) ERC20(name, symbol, 18) Owned(msg.sender) {}

    /**
     * @dev Modifier to restrict function access to only the DepositManager contract
     * @notice Reverts if DepositManager is not set or caller is not the DepositManager
     */
    modifier onlyDepositManager() {
        if (depositManager == address(0)) revert DepositManagerNotSet();
        if (msg.sender != depositManager) revert OnlyDepositManager();
        _;
    }

    /**
     * @notice Sets the DepositManager contract address
     * @dev Only callable by the contract owner
     * @param _depositManager The address of the DepositManager contract
     *
     * Requirements:
     * - Caller must be the contract owner
     * - _depositManager must not be the zero address
     *
     * Emits a {DepositManagerSet} event
     */
    function setDepositManager(address _depositManager) external onlyOwner {
        if (_depositManager == address(0)) revert InvalidDepositManagerAddress();
        depositManager = _depositManager;
        emit DepositManagerSet(_depositManager);
    }

    /**
     * @notice Mints new tokens to a specified address
     * @dev Only callable by the DepositManager contract
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     *
     * Requirements:
     * - Caller must be the DepositManager contract
     * - to must not be the zero address
     * - amount must be greater than 0
     *
     * Emits a {DepositManagerMint} event
     */
    function mint(address to, uint256 amount) external onlyDepositManager {
        if (to == address(0)) revert CannotMintToZeroAddress();
        if (amount == 0) revert InvalidAmount();

        _mint(to, amount);

        emit DepositManagerMint(to, amount);
    }

    /**
     * @notice Burns tokens from a specified address
     * @dev Only callable by the DepositManager contract
     * @param from The address to burn tokens from
     * @param amount The amount of tokens to burn
     *
     * Requirements:
     * - Caller must be the DepositManager contract
     * - from must not be the zero address
     * - amount must be greater than 0
     * - from must have sufficient balance to burn
     *
     * Emits a {DepositManagerBurn} event
     */
    function burn(address from, uint256 amount) external onlyDepositManager {
        if (from == address(0)) revert CannotBurnFromZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (balanceOf[from] < amount) revert InsufficientBalance();

        _burn(from, amount);

        emit DepositManagerBurn(from, amount);
    }
}
