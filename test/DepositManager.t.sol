// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DepositManager} from "../src/DepositManager.sol";
import {PlatformToken} from "../src/PlatformToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockAToken} from "./mocks/MockAToken.sol";
import {DataTypes} from "aave-v3/protocol/libraries/types/DataTypes.sol";

contract DepositManagerTest is Test {
    DepositManager public depositManager;
    PlatformToken public platformToken;
    MockERC20 public usdcToken;
    MockAavePool public mockAavePool;
    MockAToken public mockAToken;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public nonOwner = address(0x4);
    address public recipient = address(0x5);

    uint256 public constant USDC_DECIMALS = 6;
    uint256 public constant PLATFORM_TOKEN_DECIMALS = 18;

    event USDCDeposited(address indexed user, uint256 usdcAmount, uint256 platformTokensMinted);
    event USDCWithdrawn(address indexed user, uint256 platformTokensBurned, uint256 usdcAmount);
    event BalanceSupply(address indexed owner, address indexed recipient, uint256 amount, uint256 timestamp);
    event EmergencyWithdrawal(
        address indexed owner,
        address indexed recipient,
        uint256 amount,
        uint256 totalTokensMinted,
        uint256 requiredBacking,
        uint256 backingRatio,
        uint256 timestamp
    );
    event PauseStateChanged(address indexed owner, bool paused);
    event AaveSupplySuccess(address indexed user, uint256 amount);
    event AaveDepositFallback(address indexed user, uint256 usdcAmount, string reason);

    function setUp() public {
        // Deploy tokens
        usdcToken = new MockERC20("USD Coin", "USDC", uint8(USDC_DECIMALS));

        // Deploy mock Aave Pool and aToken
        mockAavePool = new MockAavePool();
        mockAToken = new MockAToken("Aave USDC", "aUSDC", uint8(USDC_DECIMALS), address(mockAavePool), address(usdcToken));

        // Setup Aave reserve for USDC
        mockAavePool.setupReserve(address(usdcToken), address(mockAToken), false, false);

        // Deploy PlatformToken and DepositManager as owner
        vm.startPrank(owner);
        platformToken = new PlatformToken("Cut Platform Token", "CUT");
        depositManager = new DepositManager(address(usdcToken), address(platformToken), address(mockAavePool));

        // Set DepositManager in PlatformToken
        platformToken.setDepositManager(address(depositManager));
        vm.stopPrank();

        // Give users some USDC
        usdcToken.mint(user1, 1000000 * 1e6); // $1M USDC
        usdcToken.mint(user2, 1000000 * 1e6); // $1M USDC

        // Approve DepositManager to spend USDC
        vm.startPrank(user1);
        usdcToken.approve(address(depositManager), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        usdcToken.approve(address(depositManager), type(uint256).max);
        vm.stopPrank();
    }

    // ==================== Constructor Tests ====================

    function test_Constructor_ValidInitialization() public view {
        assertEq(address(depositManager.usdcToken()), address(usdcToken));
        assertEq(address(depositManager.platformToken()), address(platformToken));
        assertEq(address(depositManager.aavePool()), address(mockAavePool));
        assertEq(depositManager.aUsdcToken(), address(mockAToken));
        assertEq(depositManager.owner(), owner);
        assertEq(depositManager.paused(), false);
    }

    function test_Constructor_RevertsWithZeroUSDCAddress() public {
        vm.expectRevert(DepositManager.ZeroUSDCAddress.selector);
        new DepositManager(address(0), address(platformToken), address(mockAavePool));
    }

    function test_Constructor_RevertsWithZeroPlatformTokenAddress() public {
        vm.expectRevert(DepositManager.ZeroPlatformTokenAddress.selector);
        new DepositManager(address(usdcToken), address(0), address(mockAavePool));
    }

    function test_Constructor_RevertsWithZeroAavePoolAddress() public {
        vm.expectRevert(DepositManager.ZeroAavePoolAddress.selector);
        new DepositManager(address(usdcToken), address(platformToken), address(0));
    }

    function test_Constructor_SetsOwnerCorrectly() public {
        address deployer = address(0x999);
        vm.prank(deployer);
        DepositManager newManager =
            new DepositManager(address(usdcToken), address(platformToken), address(mockAavePool));
        assertEq(newManager.owner(), deployer);
    }

    function test_Constructor_InitialPausedStateIsFalse() public view {
        assertEq(depositManager.paused(), false);
    }

    // ==================== pause/unpause Tests ====================

    function test_Pause_OwnerCanPause() public {
        vm.prank(owner);
        depositManager.pause();

        assertEq(depositManager.paused(), true);
    }

    function test_Pause_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit PauseStateChanged(owner, true);

        vm.prank(owner);
        depositManager.pause();
    }

    function test_Pause_NonOwnerCannotPause() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        depositManager.pause();

        assertEq(depositManager.paused(), false);
    }

    function test_Unpause_OwnerCanUnpause() public {
        vm.startPrank(owner);
        depositManager.pause();
        depositManager.unpause();
        vm.stopPrank();

        assertEq(depositManager.paused(), false);
    }

    function test_Unpause_EmitsEvent() public {
        vm.startPrank(owner);
        depositManager.pause();

        vm.expectEmit(true, false, false, true);
        emit PauseStateChanged(owner, false);

        depositManager.unpause();
        vm.stopPrank();
    }

    function test_Unpause_NonOwnerCannotUnpause() public {
        vm.startPrank(owner);
        depositManager.pause();
        vm.stopPrank();

        vm.prank(nonOwner);
        vm.expectRevert();
        depositManager.unpause();

        assertEq(depositManager.paused(), true);
    }

    function test_PausedState_BlocksDeposits() public {
        vm.prank(owner);
        depositManager.pause();

        uint256 amount = 1000 * 1e6;
        vm.prank(user1);
        vm.expectRevert(DepositManager.ContractPaused.selector);
        depositManager.depositUSDC(amount);
    }

    function test_PausedState_BlocksWithdrawals() public {
        // First deposit some USDC
        uint256 depositAmount = 1000 * 1e6;
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Pause and try to withdraw
        vm.prank(owner);
        depositManager.pause();

        uint256 withdrawAmount = depositAmount * 1e12; // Convert to platform tokens
        vm.prank(user1);
        vm.expectRevert(DepositManager.ContractPaused.selector);
        depositManager.withdrawUSDC(withdrawAmount);
    }

    // ==================== depositUSDC Tests ====================

    function test_DepositUSDC_TransfersUSDCFromUser() public {
        uint256 amount = 1000 * 1e6;
        uint256 userBalanceBefore = usdcToken.balanceOf(user1);

        vm.prank(user1);
        depositManager.depositUSDC(amount);

        assertEq(usdcToken.balanceOf(user1), userBalanceBefore - amount);
    }

    function test_DepositUSDC_MintsPlatformTokens() public {
        uint256 amount = 1000 * 1e6;
        uint256 expectedPlatformTokens = amount * 1e12;

        vm.prank(user1);
        depositManager.depositUSDC(amount);

        assertEq(platformToken.balanceOf(user1), expectedPlatformTokens);
        assertEq(platformToken.totalSupply(), expectedPlatformTokens);
    }

    function test_DepositUSDC_EmitsUSDCDepositedEvent() public {
        uint256 amount = 1000 * 1e6;
        uint256 expectedPlatformTokens = amount * 1e12;

        vm.expectEmit(true, false, false, true);
        emit USDCDeposited(user1, amount, expectedPlatformTokens);

        vm.prank(user1);
        depositManager.depositUSDC(amount);
    }

    function test_DepositUSDC_SuccessfulAaveSupply() public {
        uint256 amount = 1000 * 1e6;

        vm.expectEmit(true, false, false, false);
        emit AaveSupplySuccess(user1, amount);

        vm.prank(user1);
        depositManager.depositUSDC(amount);

        // Check USDC was supplied to Aave (via aToken balance)
        assertEq(mockAToken.balanceOf(address(depositManager)), amount);
        assertEq(usdcToken.balanceOf(address(depositManager)), 0);
    }

    function test_DepositUSDC_AavePausedFallback() public {
        uint256 amount = 1000 * 1e6;

        // Pause Aave reserve
        mockAavePool.setReservePaused(address(usdcToken), true);

        vm.expectEmit(true, false, false, false);
        emit AaveDepositFallback(user1, amount, "Aave supply paused");

        vm.prank(user1);
        depositManager.depositUSDC(amount);

        // Check USDC stayed in contract
        assertEq(usdcToken.balanceOf(address(depositManager)), amount);
        assertEq(mockAToken.balanceOf(address(depositManager)), 0);
    }

    function test_DepositUSDC_AaveFrozenFallback() public {
        uint256 amount = 1000 * 1e6;

        // Freeze Aave reserve
        mockAavePool.setReserveFrozen(address(usdcToken), true);

        vm.expectEmit(true, false, false, false);
        emit AaveDepositFallback(user1, amount, "Aave supply frozen");

        vm.prank(user1);
        depositManager.depositUSDC(amount);

        // Check USDC stayed in contract
        assertEq(usdcToken.balanceOf(address(depositManager)), amount);
    }

    function test_DepositUSDC_RevertsWithContractPaused() public {
        vm.prank(owner);
        depositManager.pause();

        uint256 amount = 1000 * 1e6;
        vm.prank(user1);
        vm.expectRevert(DepositManager.ContractPaused.selector);
        depositManager.depositUSDC(amount);
    }

    function test_DepositUSDC_RevertsWithInvalidAmount() public {
        vm.prank(user1);
        vm.expectRevert(DepositManager.InvalidAmount.selector);
        depositManager.depositUSDC(0);
    }

    function test_DepositUSDC_RevertsWithAmountBelowMinimum() public {
        uint256 amount = depositManager.MIN_DEPOSIT_AMOUNT() - 1;
        vm.prank(user1);
        vm.expectRevert(DepositManager.AmountBelowMinimum.selector);
        depositManager.depositUSDC(amount);
    }

    function test_DepositUSDC_RevertsWithAmountExceedsMaximum() public {
        uint256 amount = depositManager.MAX_DEPOSIT_AMOUNT() + 1;
        vm.prank(user1);
        vm.expectRevert(DepositManager.AmountExceedsMaximum.selector);
        depositManager.depositUSDC(amount);
    }

    function test_DepositUSDC_MinimumAmount() public {
        uint256 amount = depositManager.MIN_DEPOSIT_AMOUNT();

        vm.prank(user1);
        depositManager.depositUSDC(amount);

        assertEq(platformToken.balanceOf(user1), amount * 1e12);
    }

    function test_DepositUSDC_MaximumAmount() public {
        uint256 amount = depositManager.MAX_DEPOSIT_AMOUNT();

        vm.prank(user1);
        depositManager.depositUSDC(amount);

        assertEq(platformToken.balanceOf(user1), amount * 1e12);
    }

    function test_DepositUSDC_MultipleDepositsAccumulate() public {
        uint256 amount1 = 1000 * 1e6;
        uint256 amount2 = 500 * 1e6;

        vm.startPrank(user1);
        depositManager.depositUSDC(amount1);
        depositManager.depositUSDC(amount2);
        vm.stopPrank();

        assertEq(platformToken.balanceOf(user1), (amount1 + amount2) * 1e12);
        assertEq(platformToken.totalSupply(), (amount1 + amount2) * 1e12);
    }

    function test_DepositUSDC_DecimalConversion() public {
        // Test 1 USDC (1e6) converts to 1e18 platform tokens
        uint256 usdcAmount = 1 * 1e6;
        uint256 expectedPlatformTokens = 1 * 1e18;

        vm.prank(user1);
        depositManager.depositUSDC(usdcAmount);

        assertEq(platformToken.balanceOf(user1), expectedPlatformTokens);
    }

    function test_DepositUSDC_AaveSupplyFailure() public {
        uint256 amount = 1000 * 1e6;

        // Make Aave supply revert
        mockAavePool.setShouldRevertSupply(true);

        vm.expectEmit(true, false, false, false);
        emit AaveDepositFallback(user1, amount, "Aave supply failed");

        vm.prank(user1);
        depositManager.depositUSDC(amount);

        // Check USDC stayed in contract
        assertEq(usdcToken.balanceOf(address(depositManager)), amount);
    }

    // ==================== withdrawUSDC Tests ====================

    function test_WithdrawUSDC_BurnsPlatformTokens() public {
        uint256 depositAmount = 1000 * 1e6;
        uint256 platformTokenAmount = depositAmount * 1e12;

        // First deposit
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        uint256 balanceBefore = platformToken.balanceOf(user1);

        // Withdraw
        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenAmount);

        assertEq(platformToken.balanceOf(user1), balanceBefore - platformTokenAmount);
        assertEq(platformToken.totalSupply(), 0);
    }

    function test_WithdrawUSDC_TransfersUSDCToUser() public {
        uint256 depositAmount = 1000 * 1e6;
        uint256 platformTokenAmount = depositAmount * 1e12;

        // First deposit
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        uint256 userBalanceBefore = usdcToken.balanceOf(user1);

        // Withdraw
        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenAmount);

        assertEq(usdcToken.balanceOf(user1), userBalanceBefore + depositAmount);
    }

    function test_WithdrawUSDC_EmitsUSDCWithdrawnEvent() public {
        uint256 depositAmount = 1000 * 1e6;
        uint256 platformTokenAmount = depositAmount * 1e12;

        // First deposit
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        vm.expectEmit(true, false, false, true);
        emit USDCWithdrawn(user1, platformTokenAmount, depositAmount);

        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenAmount);
    }

    function test_WithdrawUSDC_WithdrawsFromAaveWhenNeeded() public {
        uint256 depositAmount = 1000 * 1e6;
        uint256 platformTokenAmount = depositAmount * 1e12;

        // First deposit (goes to Aave)
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Verify in Aave via aToken balance
        assertEq(mockAToken.balanceOf(address(depositManager)), depositAmount);

        // Withdraw
        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenAmount);

        // Should withdraw from Aave
        assertEq(mockAToken.balanceOf(address(depositManager)), 0);
    }

    function test_WithdrawUSDC_ContractBalanceSufficient() public {
        uint256 depositAmount = 1000 * 1e6;
        uint256 platformTokenAmount = depositAmount * 1e12;

        // Deposit with Aave paused (stays in contract)
        mockAavePool.setReservePaused(address(usdcToken), true);

        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Unpause for withdraw
        mockAavePool.setReservePaused(address(usdcToken), false);

        // Withdraw
        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenAmount);

        // Should use contract balance
        assertEq(usdcToken.balanceOf(address(depositManager)), 0);
    }

    function test_WithdrawUSDC_RevertsWithContractPaused() public {
        uint256 depositAmount = 1000 * 1e6;
        uint256 platformTokenAmount = depositAmount * 1e12;

        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        vm.prank(owner);
        depositManager.pause();

        vm.prank(user1);
        vm.expectRevert(DepositManager.ContractPaused.selector);
        depositManager.withdrawUSDC(platformTokenAmount);
    }

    function test_WithdrawUSDC_RevertsWithInvalidAmount() public {
        vm.prank(user1);
        vm.expectRevert(DepositManager.InvalidAmount.selector);
        depositManager.withdrawUSDC(0);
    }

    function test_WithdrawUSDC_RevertsWithAmountBelowMinimum() public {
        uint256 minWithdraw = depositManager.MIN_WITHDRAW_AMOUNT();
        uint256 amount = minWithdraw - 1;

        vm.prank(user1);
        vm.expectRevert(DepositManager.AmountBelowMinimum.selector);
        depositManager.withdrawUSDC(amount);
    }

    function test_WithdrawUSDC_RevertsWithInsufficientPlatformTokens() public {
        uint256 amount = 1000 * 1e18; // More than user has

        vm.prank(user1);
        vm.expectRevert(DepositManager.InsufficientPlatformTokens.selector);
        depositManager.withdrawUSDC(amount);
    }

    function test_WithdrawUSDC_RevertsWithAavePausedInsufficientBalance() public {
        uint256 depositAmount = 1000 * 1e6;
        uint256 platformTokenAmount = depositAmount * 1e12;

        // Deposit (goes to Aave)
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Pause Aave
        mockAavePool.setReservePaused(address(usdcToken), true);

        // Contract balance is 0, Aave is paused
        vm.prank(user1);
        vm.expectRevert(DepositManager.AaveWithdrawPausedInsufficientBalance.selector);
        depositManager.withdrawUSDC(platformTokenAmount);
    }

    function test_WithdrawUSDC_MinimumAmount() public {
        uint256 depositAmount = 1000 * 1e6;
        uint256 minWithdraw = depositManager.MIN_WITHDRAW_AMOUNT();

        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        vm.prank(user1);
        depositManager.withdrawUSDC(minWithdraw);

        assertEq(platformToken.balanceOf(user1), depositAmount * 1e12 - minWithdraw);
    }

    function test_WithdrawUSDC_DecimalConversion() public {
        // Deposit 1 USDC
        uint256 depositAmount = 1 * 1e6;
        uint256 platformTokenAmount = 1 * 1e18;

        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenAmount);

        // Should get back 1 USDC (1e6)
        assertEq(usdcToken.balanceOf(user1), 1000000 * 1e6); // Original balance
    }

    function test_WithdrawUSDC_MaximumWithdrawal() public {
        uint256 depositAmount = 1000 * 1e6;
        uint256 platformTokenAmount = depositAmount * 1e12;

        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenAmount);

        assertEq(platformToken.balanceOf(user1), 0);
        assertEq(platformToken.totalSupply(), 0);
    }

    // ==================== balanceSupply Tests ====================

    function test_BalanceSupply_WithdrawsExcessUSDC() public {
        uint256 depositAmount = 1000 * 1e6;

        // Deposit (goes to Aave)
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Accrue yield via mock
        mockAavePool.setYieldRateBps(11000); // 10% yield
        mockAavePool.accrueYield(address(usdcToken), address(depositManager));

        // Mint tokens to mock pool to match the increased balance
        uint256 aaveBalance = depositManager.getAaveUSDCBalance();
        usdcToken.mint(address(mockAavePool), aaveBalance - depositAmount);

        // Calculate excess
        uint256 totalAvailable = depositManager.getTotalAvailableBalance();
        uint256 requiredBacking = depositAmount;
        uint256 expectedExcess = totalAvailable - requiredBacking;

        require(expectedExcess > 0, "No excess generated");

        uint256 recipientBalanceBefore = usdcToken.balanceOf(recipient);

        vm.expectEmit(true, true, false, true);
        emit BalanceSupply(owner, recipient, expectedExcess, block.timestamp);

        vm.prank(owner);
        depositManager.balanceSupply(recipient);

        assertEq(usdcToken.balanceOf(recipient), recipientBalanceBefore + expectedExcess);
    }

    function test_BalanceSupply_RevertsWithOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        depositManager.balanceSupply(recipient);
    }

    function test_BalanceSupply_RevertsWithInvalidRecipient() public {
        vm.prank(owner);
        vm.expectRevert(DepositManager.InvalidRecipient.selector);
        depositManager.balanceSupply(address(0));
    }

    function test_BalanceSupply_RevertsWithNoExcessUSDC() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        vm.prank(owner);
        vm.expectRevert(DepositManager.NoExcessUSDC.selector);
        depositManager.balanceSupply(recipient);
    }

    // ==================== emergencyWithdrawAll Tests ====================

    function test_EmergencyWithdrawAll_WithdrawsAllUSDC() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        uint256 totalBalance = depositManager.getTotalAvailableBalance();
        uint256 recipientBalanceBefore = usdcToken.balanceOf(recipient);

        vm.expectEmit(true, true, false, false);
        emit EmergencyWithdrawal(
            owner, recipient, totalBalance, depositAmount * 1e12, depositAmount, 0, block.timestamp
        );

        vm.prank(owner);
        depositManager.emergencyWithdrawAll(recipient);

        assertEq(usdcToken.balanceOf(recipient), recipientBalanceBefore + totalBalance);
        assertEq(depositManager.getTotalAvailableBalance(), 0);
    }

    function test_EmergencyWithdrawAll_RevertsWithOnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        depositManager.emergencyWithdrawAll(recipient);
    }

    function test_EmergencyWithdrawAll_RevertsWithInvalidRecipient() public {
        vm.prank(owner);
        vm.expectRevert(DepositManager.InvalidRecipient.selector);
        depositManager.emergencyWithdrawAll(address(0));
    }

    function test_EmergencyWithdrawAll_RevertsWithNoFundsToWithdraw() public {
        // No deposits made
        vm.prank(owner);
        vm.expectRevert(DepositManager.NoFundsToWithdraw.selector);
        depositManager.emergencyWithdrawAll(recipient);
    }

    function test_EmergencyWithdrawAll_WithdrawsFromContractAndAave() public {
        uint256 depositAmount1 = 500 * 1e6;
        uint256 depositAmount2 = 500 * 1e6;

        // First deposit goes to Aave
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount1);

        // Second deposit with Aave paused (stays in contract)
        mockAavePool.setReservePaused(address(usdcToken), true);

        vm.prank(user2);
        depositManager.depositUSDC(depositAmount2);

        // Unpause for emergency withdrawal
        mockAavePool.setReservePaused(address(usdcToken), false);

        uint256 totalBalance = depositAmount1 + depositAmount2;
        uint256 recipientBalanceBefore = usdcToken.balanceOf(recipient);

        vm.prank(owner);
        depositManager.emergencyWithdrawAll(recipient);

        assertEq(usdcToken.balanceOf(recipient), recipientBalanceBefore + totalBalance);
    }

    // ==================== View Function Tests ====================

    function test_GetTokenManagerUSDCBalance() public {
        assertEq(depositManager.getTokenManagerUSDCBalance(), 0);

        // Deposit with Aave paused (stays in contract)
        mockAavePool.setReservePaused(address(usdcToken), true);

        uint256 amount = 1000 * 1e6;
        vm.prank(user1);
        depositManager.depositUSDC(amount);

        assertEq(depositManager.getTokenManagerUSDCBalance(), amount);
    }

    function test_GetAaveUSDCBalance() public {
        assertEq(depositManager.getAaveUSDCBalance(), 0);

        uint256 amount = 1000 * 1e6;
        vm.prank(user1);
        depositManager.depositUSDC(amount);

        assertEq(depositManager.getAaveUSDCBalance(), amount);
    }

    function test_GetTotalAvailableBalance() public {
        assertEq(depositManager.getTotalAvailableBalance(), 0);

        uint256 amount = 1000 * 1e6;
        vm.prank(user1);
        depositManager.depositUSDC(amount);

        assertEq(depositManager.getTotalAvailableBalance(), amount);
    }

    function test_GetUSDCReserveConfig() public view {
        DataTypes.ReserveConfigurationMap memory config = depositManager.getUSDCReserveConfig();
        // Config exists and is not paused/frozen by default
        assert(config.data != 0); // Has some configuration
    }

    function test_GetUSDCReserveData() public view {
        DataTypes.ReserveData memory reserve = depositManager.getUSDCReserveData();
        assertEq(reserve.aTokenAddress, address(mockAToken));
    }

    function test_GetATokenAddress() public view {
        assertEq(depositManager.getATokenAddress(), address(mockAToken));
    }

    function test_IsAaveSupplyPaused() public {
        assertEq(depositManager.isAaveSupplyPaused(), false);

        mockAavePool.setReservePaused(address(usdcToken), true);
        assertEq(depositManager.isAaveSupplyPaused(), true);

        mockAavePool.setReservePaused(address(usdcToken), false);
        mockAavePool.setReserveFrozen(address(usdcToken), true);
        assertEq(depositManager.isAaveSupplyPaused(), true);
    }

    function test_IsAaveWithdrawPaused() public {
        assertEq(depositManager.isAaveWithdrawPaused(), false);

        mockAavePool.setReservePaused(address(usdcToken), true);
        assertEq(depositManager.isAaveWithdrawPaused(), true);

        mockAavePool.setReservePaused(address(usdcToken), false);
        mockAavePool.setReserveFrozen(address(usdcToken), true);
        assertEq(depositManager.isAaveWithdrawPaused(), false); // Frozen doesn't block withdraw
    }

    function test_GetAccumulatedEarnings() public {
        // No deposits yet
        assertEq(depositManager.getAccumulatedEarnings(), 0);

        uint256 depositAmount = 1000 * 1e6;
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // No yield yet
        assertEq(depositManager.getAccumulatedEarnings(), 0);
    }

    function test_GetCurrentYieldRate() public {
        // No deposits yet
        assertEq(depositManager.getCurrentYieldRate(), 0);

        uint256 depositAmount = 1000 * 1e6;
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // No yield yet
        assertEq(depositManager.getCurrentYieldRate(), 0);
    }

    function test_Constants() public view {
        assertEq(depositManager.MIN_DEPOSIT_AMOUNT(), 10000); // $0.01 USDC
        assertEq(depositManager.MAX_DEPOSIT_AMOUNT(), 100_000 * 1e6); // $100,000 USDC
        assertEq(depositManager.MIN_WITHDRAW_AMOUNT(), 10000 * 1e12); // $0.01 USDC equivalent
    }
}
