// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "aave-v3/interfaces/IPoolAddressesProvider.sol";
import {DataTypes} from "aave-v3/protocol/libraries/types/DataTypes.sol";
import {ReserveConfiguration} from "aave-v3/protocol/libraries/configuration/ReserveConfiguration.sol";
import "solmate/tokens/ERC20.sol";
import {MockAToken} from "./MockAToken.sol";

/// @title MockAavePool
/// @notice Mock Aave v3 Pool contract for testing purposes
contract MockAavePool is IPool {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    /// @notice Reserve data storage
    struct MockReserveData {
        address aTokenAddress;
        DataTypes.ReserveConfigurationMap configuration;
        bool exists;
    }

    /// @notice Mapping of asset address to reserve data
    mapping(address => MockReserveData) public reserves;

    /// @notice Mapping of asset to its aToken contract
    mapping(address => MockAToken) public aTokens;

    /// @notice Whether supply should revert
    bool public shouldRevertSupply;

    /// @notice Whether withdraw should revert
    bool public shouldRevertWithdraw;

    /// @notice Whether to return partial amounts
    bool public returnPartialAmounts;

    /// @notice Yield rate (multiplier for balance, in basis points, 10000 = 1.0 = no yield)
    uint256 public yieldRateBps = 10000;

    /// @notice Add a reserve to the mock (helper function, not part of interface)
    function setupReserve(address asset, address aToken, bool isPaused, bool isFrozen) external {
        DataTypes.ReserveConfigurationMap memory config;
        config.setActive(true);
        config.setPaused(isPaused);
        config.setFrozen(isFrozen);

        reserves[asset] = MockReserveData({aTokenAddress: aToken, configuration: config, exists: true});
        aTokens[asset] = MockAToken(aToken);
    }

    /// @notice Set reserve paused state
    function setReservePaused(address asset, bool isPaused) external {
        require(reserves[asset].exists, "Reserve does not exist");
        DataTypes.ReserveConfigurationMap memory config = reserves[asset].configuration;
        config.setPaused(isPaused);
        reserves[asset].configuration = config;
    }

    /// @notice Set reserve frozen state
    function setReserveFrozen(address asset, bool isFrozen) external {
        require(reserves[asset].exists, "Reserve does not exist");
        DataTypes.ReserveConfigurationMap memory config = reserves[asset].configuration;
        config.setFrozen(isFrozen);
        reserves[asset].configuration = config;
    }

    /// @notice Set whether supply should revert
    function setShouldRevertSupply(bool _shouldRevert) external {
        shouldRevertSupply = _shouldRevert;
    }

    /// @notice Set whether withdraw should revert
    function setShouldRevertWithdraw(bool _shouldRevert) external {
        shouldRevertWithdraw = _shouldRevert;
    }

    /// @notice Set whether to return partial amounts
    function setReturnPartialAmounts(bool _returnPartial) external {
        returnPartialAmounts = _returnPartial;
    }

    /// @notice Set yield rate in basis points (10000 = 1.0 = no yield)
    function setYieldRateBps(uint256 _yieldRateBps) external {
        yieldRateBps = _yieldRateBps;
    }

    /// @notice Simulate yield generation by adding to user balance
    function accrueYield(address asset, address user) external {
        MockAToken aToken = aTokens[asset];
        uint256 balance = aToken.balanceOf(user);
        if (balance > 0 && yieldRateBps > 10000) {
            uint256 yield = (balance * (yieldRateBps - 10000)) / 10000;
            aToken.accrueYield(user, yield);
        }
    }

    /// @notice Get aToken balance for a user (for mock purposes)
    function getATokenBalance(address asset, address user) external view returns (uint256) {
        return aTokens[asset].balanceOf(user);
    }

    // ============ IPool Implementation ============

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        require(reserves[asset].exists, "Reserve does not exist");
        require(!shouldRevertSupply, "Supply reverted");

        DataTypes.ReserveConfigurationMap memory config = reserves[asset].configuration;
        require(!config.getPaused(), "Reserve paused");
        require(!config.getFrozen(), "Reserve frozen");

        // Transfer tokens from caller
        ERC20 token = ERC20(asset);
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        uint256 supplied = amount;
        if (returnPartialAmounts) {
            supplied = amount / 2; // Return half for testing partial supply
            // Return excess to caller
            if (supplied < amount) {
                require(token.transfer(msg.sender, amount - supplied), "Excess transfer failed");
            }
        }

        // Mint aTokens to the onBehalfOf address
        aTokens[asset].mint(onBehalfOf, supplied);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        require(reserves[asset].exists, "Reserve does not exist");
        require(!shouldRevertWithdraw, "Withdraw reverted");

        DataTypes.ReserveConfigurationMap memory config = reserves[asset].configuration;
        require(!config.getPaused(), "Reserve paused");

        MockAToken aToken = aTokens[asset];
        uint256 available = aToken.balanceOf(msg.sender);
        uint256 withdrawn = amount > available ? available : amount;

        if (returnPartialAmounts && withdrawn > 0) {
            withdrawn = withdrawn / 2; // Return half for testing partial withdraw
        }

        // Burn aTokens from caller
        aToken.burn(msg.sender, withdrawn);

        // Transfer tokens back to recipient
        ERC20 token = ERC20(asset);
        require(token.transfer(to, withdrawn), "Transfer failed");

        return withdrawn;
    }

    function getConfiguration(address asset)
        external
        view
        override
        returns (DataTypes.ReserveConfigurationMap memory)
    {
        require(reserves[asset].exists, "Reserve does not exist");
        return reserves[asset].configuration;
    }

    function getReserveData(address asset) external view override returns (DataTypes.ReserveData memory data) {
        require(reserves[asset].exists, "Reserve does not exist");
        data.aTokenAddress = reserves[asset].aTokenAddress;
        data.configuration = reserves[asset].configuration;
    }

    // ============ Stub implementations for other IPool methods ============

    function mintUnbacked(address, uint256, address, uint16) external pure override {
        revert("Not implemented");
    }

    function backUnbacked(address, uint256, uint256) external pure override returns (uint256) {
        revert("Not implemented");
    }

    function supplyWithPermit(address, uint256, address, uint16, uint256, uint8, bytes32, bytes32)
        external
        pure
        override
    {
        revert("Not implemented");
    }

    function borrow(address, uint256, uint256, uint16, address) external pure override {
        revert("Not implemented");
    }

    function repay(address, uint256, uint256, address) external pure override returns (uint256) {
        revert("Not implemented");
    }

    function repayWithPermit(address, uint256, uint256, address, uint256, uint8, bytes32, bytes32)
        external
        pure
        override
        returns (uint256)
    {
        revert("Not implemented");
    }

    function repayWithATokens(address, uint256, uint256) external pure override returns (uint256) {
        revert("Not implemented");
    }

    function swapBorrowRateMode(address, uint256) external pure override {
        revert("Not implemented");
    }

    function rebalanceStableBorrowRate(address, address) external pure override {
        revert("Not implemented");
    }

    function setUserUseReserveAsCollateral(address, bool) external pure override {
        revert("Not implemented");
    }

    function liquidationCall(address, address, address, uint256, bool) external pure override {
        revert("Not implemented");
    }

    function flashLoan(address, address[] calldata, uint256[] calldata, uint256[] calldata, address, bytes calldata, uint16)
        external
        pure
        override
    {
        revert("Not implemented");
    }

    function flashLoanSimple(address, address, uint256, bytes calldata, uint16) external pure override {
        revert("Not implemented");
    }

    function getUserAccountData(address)
        external
        pure
        override
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        revert("Not implemented");
    }

    function initReserve(address, address, address, address, address) external pure override {
        revert("Not implemented");
    }

    function dropReserve(address) external pure override {
        revert("Not implemented");
    }

    function setReserveInterestRateStrategyAddress(address, address) external pure override {
        revert("Not implemented");
    }

    function setConfiguration(address, DataTypes.ReserveConfigurationMap calldata) external pure override {
        revert("Not implemented");
    }

    function getUserConfiguration(address) external pure override returns (DataTypes.UserConfigurationMap memory) {
        revert("Not implemented");
    }

    function getReserveNormalizedIncome(address) external pure override returns (uint256) {
        revert("Not implemented");
    }

    function getReserveNormalizedVariableDebt(address) external pure override returns (uint256) {
        revert("Not implemented");
    }

    function finalizeTransfer(address, address, address, uint256, uint256, uint256) external pure override {
        revert("Not implemented");
    }

    function getReservesList() external pure override returns (address[] memory) {
        revert("Not implemented");
    }

    function getReserveAddressById(uint16) external pure override returns (address) {
        revert("Not implemented");
    }

    function ADDRESSES_PROVIDER() external pure override returns (IPoolAddressesProvider) {
        revert("Not implemented");
    }

    function updateBridgeProtocolFee(uint256) external pure override {
        revert("Not implemented");
    }

    function updateFlashloanPremiums(uint128, uint128) external pure override {
        revert("Not implemented");
    }

    function configureEModeCategory(uint8, DataTypes.EModeCategory memory) external pure override {
        revert("Not implemented");
    }

    function getEModeCategoryData(uint8) external pure override returns (DataTypes.EModeCategory memory) {
        revert("Not implemented");
    }

    function setUserEMode(uint8) external pure override {
        revert("Not implemented");
    }

    function getUserEMode(address) external pure override returns (uint256) {
        revert("Not implemented");
    }

    function resetIsolationModeTotalDebt(address) external pure override {
        revert("Not implemented");
    }

    function MAX_STABLE_RATE_BORROW_SIZE_PERCENT() external pure override returns (uint256) {
        revert("Not implemented");
    }

    function FLASHLOAN_PREMIUM_TOTAL() external pure override returns (uint128) {
        revert("Not implemented");
    }

    function BRIDGE_PROTOCOL_FEE() external pure override returns (uint256) {
        revert("Not implemented");
    }

    function FLASHLOAN_PREMIUM_TO_PROTOCOL() external pure override returns (uint128) {
        revert("Not implemented");
    }

    function MAX_NUMBER_RESERVES() external pure override returns (uint16) {
        revert("Not implemented");
    }

    function mintToTreasury(address[] calldata) external pure override {
        revert("Not implemented");
    }

    function rescueTokens(address, address, uint256) external pure override {
        revert("Not implemented");
    }

    function deposit(address, uint256, address, uint16) external pure override {
        revert("Not implemented");
    }
}
