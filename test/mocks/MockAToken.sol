// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "solmate/tokens/ERC20.sol";

/// @title MockAToken
/// @notice Mock Aave aToken for testing purposes
/// @dev This is a simplified mock that tracks balances for testing
contract MockAToken is ERC20 {
    address public pool;
    address public underlyingAsset;

    constructor(string memory _name, string memory _symbol, uint8 _decimals, address _pool, address _underlying)
        ERC20(_name, _symbol, _decimals)
    {
        pool = _pool;
        underlyingAsset = _underlying;
    }

    /// @notice Mint aTokens (only callable by pool)
    function mint(address to, uint256 amount) external {
        require(msg.sender == pool, "Only pool can mint");
        _mint(to, amount);
    }

    /// @notice Burn aTokens (only callable by pool)
    function burn(address from, uint256 amount) external {
        require(msg.sender == pool, "Only pool can burn");
        _burn(from, amount);
    }

    /// @notice Simulate yield accrual by minting additional tokens
    function accrueYield(address user, uint256 yieldAmount) external {
        require(msg.sender == pool, "Only pool can accrue yield");
        _mint(user, yieldAmount);
    }
}
