// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISpoke, ReserveFlags} from "aave-v4/src/spoke/interfaces/ISpoke.sol";
import {IHubBase} from "aave-v4/src/hub/interfaces/IHubBase.sol";
import "solmate/tokens/ERC20.sol";

/// @title MockAaveSpoke
/// @notice Mock Aave v4 Spoke contract for testing purposes
contract MockAaveSpoke is ISpoke {
    /// @notice Reserve data storage
    struct ReserveData {
        address underlying;
        address hub; // Store as address to avoid type issues
        uint16 assetId;
        uint8 decimals;
        ISpoke.ReserveConfig config;
        bool exists;
    }

    /// @notice Mapping of reserveId to reserve data
    mapping(uint256 => ReserveData) public reserves;

    /// @notice Mapping of (reserveId, user) to supplied balance
    mapping(uint256 => mapping(address => uint256)) public userSuppliedAssets;

    /// @notice Total number of reserves
    uint256 public reserveCount;

    /// @notice Whether supply should revert
    bool public shouldRevertSupply;

    /// @notice Whether withdraw should revert
    bool public shouldRevertWithdraw;

    /// @notice Whether to return partial amounts
    bool public returnPartialAmounts;

    /// @notice Yield rate (multiplier for balance, in basis points, 10000 = 1.0 = no yield)
    uint256 public yieldRateBps = 10000;

    /// @notice Accumulated yield per reserve per user
    mapping(uint256 => mapping(address => uint256)) public yieldAccumulated;

    /// @notice Add a reserve to the mock (helper function, not part of interface)
    function setupReserve(
        uint256 reserveId,
        address underlying,
        address hub,
        uint16 assetId,
        uint8 decimals,
        ISpoke.ReserveConfig memory config
    ) external {
        reserves[reserveId] = ReserveData({
            underlying: underlying,
            hub: hub,
            assetId: assetId,
            decimals: decimals,
            config: config,
            exists: true
        });
        if (reserveId >= reserveCount) {
            reserveCount = reserveId + 1;
        }
    }

    /// @notice Set reserve configuration
    function setReserveConfig(uint256 reserveId, ISpoke.ReserveConfig memory config) external {
        require(reserves[reserveId].exists, "Reserve does not exist");
        reserves[reserveId].config = config;
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
    function accrueYield(uint256 reserveId, address user) external {
        uint256 balance = userSuppliedAssets[reserveId][user];
        if (balance > 0 && yieldRateBps > 10000) {
            uint256 yield = (balance * (yieldRateBps - 10000)) / 10000;
            yieldAccumulated[reserveId][user] += yield;
            userSuppliedAssets[reserveId][user] += yield;
        }
    }

    /// @notice ISpoke.getReserveCount
    function getReserveCount() external view override returns (uint256) {
        return reserveCount;
    }

    /// @notice ISpoke.getReserve
    /// @dev Note: There's a Solidity type system limitation where IHubBase imported directly
    ///      is treated as a different type than IHubBase used in ISpoke.Reserve, even though
    ///      they're the same interface. This requires the hub field to be set via assembly.
    function getReserve(uint256 reserveId) external view override returns (ISpoke.Reserve memory reserve) {
        require(reserves[reserveId].exists, "Reserve does not exist");
        ReserveData memory data = reserves[reserveId];

        // Initialize struct fields
        reserve.underlying = data.underlying;
        reserve.assetId = data.assetId;
        reserve.decimals = data.decimals;
        reserve.dynamicConfigKey = 0;
        reserve.collateralRisk = data.config.collateralRisk;
        reserve.flags = ReserveFlags.wrap(0);

        // Use assembly to set hub field to avoid type system issue
        // Interfaces are just addresses at runtime, so this is safe
        assembly {
            mstore(add(reserve, 0x20), mload(add(data, 0x20))) // Set hub from data.hub (address)
        }
    }

    /// @notice ISpoke.getReserveConfig
    function getReserveConfig(uint256 reserveId) external view override returns (ISpoke.ReserveConfig memory) {
        require(reserves[reserveId].exists, "Reserve does not exist");
        return reserves[reserveId].config;
    }

    /// @notice ISpoke.supply
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        override
        returns (uint256, uint256)
    {
        require(reserves[reserveId].exists, "Reserve does not exist");
        require(!shouldRevertSupply, "Supply reverted");

        ISpoke.ReserveConfig memory config = reserves[reserveId].config;
        require(!config.paused && !config.frozen, "Reserve paused or frozen");

        // Transfer tokens from caller
        ERC20 token = ERC20(reserves[reserveId].underlying);
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        uint256 supplied = amount;
        if (returnPartialAmounts) {
            supplied = amount / 2; // Return half for testing partial supply
        }

        userSuppliedAssets[reserveId][onBehalfOf] += supplied;

        // If partial amounts are enabled, return excess USDC to caller (like real Aave would)
        if (returnPartialAmounts && supplied < amount) {
            uint256 excess = amount - supplied;
            require(token.transfer(msg.sender, excess), "Excess transfer failed");
        }

        // Return shares (for mock, 1:1 with amount) and supplied amount
        return (supplied, supplied);
    }

    /// @notice ISpoke.withdraw
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        override
        returns (uint256, uint256)
    {
        require(reserves[reserveId].exists, "Reserve does not exist");
        require(!shouldRevertWithdraw, "Withdraw reverted");

        ISpoke.ReserveConfig memory config = reserves[reserveId].config;
        require(!config.paused, "Reserve paused");

        uint256 available = userSuppliedAssets[reserveId][onBehalfOf];
        uint256 withdrawn = amount > available ? available : amount;

        if (returnPartialAmounts && withdrawn > 0) {
            withdrawn = withdrawn / 2; // Return half for testing partial withdraw
        }

        userSuppliedAssets[reserveId][onBehalfOf] -= withdrawn;

        // Transfer tokens back to caller
        ERC20 token = ERC20(reserves[reserveId].underlying);
        require(token.transfer(msg.sender, withdrawn), "Transfer failed");

        // Return shares (for mock, 1:1 with amount) and withdrawn amount
        return (withdrawn, withdrawn);
    }

    /// @notice ISpoke.getUserSuppliedAssets
    function getUserSuppliedAssets(uint256 reserveId, address user) external view override returns (uint256) {
        require(reserves[reserveId].exists, "Reserve does not exist");
        return userSuppliedAssets[reserveId][user];
    }

    // Minimal implementations of other required interface methods
    function updateLiquidationConfig(ISpoke.LiquidationConfig calldata) external pure override {
        revert("Not implemented in mock");
    }

    function addReserve(address, uint256, address, ISpoke.ReserveConfig calldata, ISpoke.DynamicReserveConfig calldata)
        external
        override
        returns (uint256)
    {
        revert("Not implemented in mock");
    }

    function updateReserveConfig(uint256, ISpoke.ReserveConfig calldata) external pure override {
        revert("Not implemented in mock");
    }

    function updateReservePriceSource(uint256, address) external pure override {
        revert("Not implemented in mock");
    }

    function addDynamicReserveConfig(uint256, ISpoke.DynamicReserveConfig calldata)
        external
        pure
        override
        returns (uint24)
    {
        revert("Not implemented in mock");
    }

    function updateDynamicReserveConfig(uint256, uint24, ISpoke.DynamicReserveConfig calldata) external pure override {
        revert("Not implemented in mock");
    }

    function borrow(uint256, uint256, address) external override returns (uint256, uint256) {
        revert("Not implemented in mock");
    }

    function repay(uint256, uint256, address) external override returns (uint256, uint256) {
        revert("Not implemented in mock");
    }

    // ISpokeBase methods not used by DepositManager (stubs)

    function liquidationCall(uint256, uint256, address, uint256, bool) external pure override {
        revert("Not implemented in mock");
    }

    function getReserveSuppliedAssets(uint256) external pure override returns (uint256) {
        revert("Not implemented in mock");
    }

    function getReserveSuppliedShares(uint256) external pure override returns (uint256) {
        revert("Not implemented in mock");
    }

    function getReserveDebt(uint256) external pure override returns (uint256, uint256) {
        revert("Not implemented in mock");
    }

    function getReserveTotalDebt(uint256) external pure override returns (uint256) {
        revert("Not implemented in mock");
    }

    function getUserSuppliedShares(uint256, address) external pure override returns (uint256) {
        revert("Not implemented in mock");
    }

    function getUserDebt(uint256, address) external pure override returns (uint256, uint256) {
        revert("Not implemented in mock");
    }

    function getUserTotalDebt(uint256, address) external pure override returns (uint256) {
        revert("Not implemented in mock");
    }

    function getUserPremiumDebtRay(uint256, address) external pure override returns (uint256) {
        revert("Not implemented in mock");
    }

    // ISpoke methods not used by DepositManager (stubs)

    function updatePositionManager(address, bool) external pure override {
        revert("Not implemented in mock");
    }

    function setUsingAsCollateral(uint256, bool, address) external pure override {
        revert("Not implemented in mock");
    }

    function updateUserRiskPremium(address) external pure override {
        revert("Not implemented in mock");
    }

    function updateUserDynamicConfig(address) external pure override {
        revert("Not implemented in mock");
    }

    function setUserPositionManager(address, bool) external pure override {
        revert("Not implemented in mock");
    }

    function setUserPositionManagerWithSig(address, address, bool, uint256, uint256, bytes calldata)
        external
        pure
        override
    {
        revert("Not implemented in mock");
    }

    function renouncePositionManagerRole(address) external pure override {
        revert("Not implemented in mock");
    }

    function permitReserve(uint256, address, uint256, uint256, uint8, bytes32, bytes32) external pure override {
        revert("Not implemented in mock");
    }

    function getLiquidationConfig() external pure override returns (ISpoke.LiquidationConfig memory) {
        revert("Not implemented in mock");
    }

    function getDynamicReserveConfig(uint256, uint24)
        external
        pure
        override
        returns (ISpoke.DynamicReserveConfig memory)
    {
        revert("Not implemented in mock");
    }

    function getUserReserveStatus(uint256, address) external pure override returns (bool, bool) {
        revert("Not implemented in mock");
    }

    function getUserPosition(uint256, address) external pure override returns (ISpoke.UserPosition memory) {
        revert("Not implemented in mock");
    }

    function getUserAccountData(address) external pure override returns (ISpoke.UserAccountData memory) {
        revert("Not implemented in mock");
    }

    function getUserLastRiskPremium(address) external pure override returns (uint256) {
        revert("Not implemented in mock");
    }

    function getLiquidationBonus(uint256, address, uint256) external pure override returns (uint256) {
        revert("Not implemented in mock");
    }

    function isPositionManagerActive(address) external pure override returns (bool) {
        revert("Not implemented in mock");
    }

    function isPositionManager(address, address) external pure override returns (bool) {
        revert("Not implemented in mock");
    }

    function DOMAIN_SEPARATOR() external pure override returns (bytes32) {
        revert("Not implemented in mock");
    }

    function getLiquidationLogic() external pure override returns (address) {
        revert("Not implemented in mock");
    }

    function SET_USER_POSITION_MANAGER_TYPEHASH() external pure override returns (bytes32) {
        revert("Not implemented in mock");
    }

    function ORACLE() external pure override returns (address) {
        revert("Not implemented in mock");
    }

    // IMulticall
    function multicall(bytes[] calldata) external pure override returns (bytes[] memory) {
        revert("Not implemented in mock");
    }

    // INoncesKeyed
    function useNonce(uint192) external pure override returns (uint256) {
        revert("Not implemented in mock");
    }

    function nonces(address, uint192) external pure override returns (uint256) {
        revert("Not implemented in mock");
    }

    // IAccessManaged
    function authority() external pure override returns (address) {
        revert("Not implemented in mock");
    }

    function setAuthority(address) external pure override {
        revert("Not implemented in mock");
    }

    function isConsumingScheduledOp() external pure override returns (bytes4) {
        revert("Not implemented in mock");
    }
}
