// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DepositManager} from "../src/DepositManager.sol";
import {PlatformToken} from "../src/PlatformToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockAToken} from "./mocks/MockAToken.sol";

contract DepositManagerIntegrationTest is Test {
    DepositManager public depositManager;
    PlatformToken public platformToken;
    MockERC20 public usdcToken;
    MockAavePool public mockAavePool;
    MockAToken public mockAToken;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public recipient = address(0x5);

    uint256 public constant USDC_DECIMALS = 6;

    event USDCDeposited(address indexed user, uint256 usdcAmount, uint256 platformTokensMinted);
    event USDCWithdrawn(address indexed user, uint256 platformTokensBurned, uint256 usdcAmount);
    event AaveSupplySuccess(address indexed user, uint256 amount);
    event AaveDepositFallback(address indexed user, uint256 usdcAmount, string reason);
    event BalanceSupply(address indexed owner, address indexed recipient, uint256 amount, uint256 timestamp);

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

    // ==================== Aave Integration Scenarios ====================

    function test_Integration_FullAaveSupplyWithdrawFlow() public {
        uint256 depositAmount = 1000 * 1e6;

        // Deposit - should go to Aave
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Verify in Aave via aToken balance
        assertEq(mockAToken.balanceOf(address(depositManager)), depositAmount);
        assertEq(usdcToken.balanceOf(address(depositManager)), 0);

        // Withdraw - should withdraw from Aave
        uint256 platformTokenAmount = depositAmount * 1e12;
        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenAmount);

        // Verify withdrawn from Aave
        assertEq(mockAToken.balanceOf(address(depositManager)), 0);
        assertEq(usdcToken.balanceOf(user1), 1000000 * 1e6); // Back to original
    }

    function test_Integration_AavePausedDuringDeposit_FallbackWorks() public {
        uint256 depositAmount = 1000 * 1e6;

        // Pause Aave reserve
        mockAavePool.setReservePaused(address(usdcToken), true);

        // Deposit - should fallback to contract storage
        vm.expectEmit(true, false, false, false);
        emit AaveDepositFallback(user1, depositAmount, "Aave supply paused");

        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Verify USDC stayed in contract
        assertEq(usdcToken.balanceOf(address(depositManager)), depositAmount);
        assertEq(mockAToken.balanceOf(address(depositManager)), 0);

        // Verify tokens still minted
        assertEq(platformToken.balanceOf(user1), depositAmount * 1e12);
    }

    function test_Integration_AaveFrozenDuringDeposit_FallbackWorks() public {
        uint256 depositAmount = 1000 * 1e6;

        // Freeze Aave reserve
        mockAavePool.setReserveFrozen(address(usdcToken), true);

        // Deposit - should fallback to contract storage
        vm.expectEmit(true, false, false, false);
        emit AaveDepositFallback(user1, depositAmount, "Aave supply frozen");

        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Verify USDC stayed in contract
        assertEq(usdcToken.balanceOf(address(depositManager)), depositAmount);
        assertEq(mockAToken.balanceOf(address(depositManager)), 0);
    }

    function test_Integration_AavePausedDuringWithdraw_ContractBalanceUsed() public {
        uint256 depositAmount = 1000 * 1e6;

        // First deposit with Aave paused (stays in contract)
        mockAavePool.setReservePaused(address(usdcToken), true);

        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Verify in contract
        assertEq(usdcToken.balanceOf(address(depositManager)), depositAmount);

        // Withdraw should work even if Aave is paused if contract has balance
        uint256 platformTokenAmount = depositAmount * 1e12;
        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenAmount);

        // Verify withdrawal from contract
        assertEq(usdcToken.balanceOf(address(depositManager)), 0);
        assertEq(usdcToken.balanceOf(user1), 1000000 * 1e6); // Back to original
    }

    function test_Integration_AavePausedDuringWithdraw_InsufficientBalance_Reverts() public {
        uint256 depositAmount = 1000 * 1e6;

        // Deposit to Aave (Aave not paused)
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Verify in Aave
        assertEq(mockAToken.balanceOf(address(depositManager)), depositAmount);
        assertEq(usdcToken.balanceOf(address(depositManager)), 0);

        // Pause Aave
        mockAavePool.setReservePaused(address(usdcToken), true);

        // Withdraw should revert (Aave paused, contract balance insufficient)
        uint256 platformTokenAmount = depositAmount * 1e12;
        vm.prank(user1);
        vm.expectRevert(DepositManager.AaveWithdrawPausedInsufficientBalance.selector);
        depositManager.withdrawUSDC(platformTokenAmount);
    }

    function test_Integration_AaveSupplyFailure_FallbackWorks() public {
        uint256 depositAmount = 1000 * 1e6;

        // Make Aave supply revert
        mockAavePool.setShouldRevertSupply(true);

        vm.expectEmit(true, false, false, false);
        emit AaveDepositFallback(user1, depositAmount, "Aave supply failed");

        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Verify USDC stayed in contract
        assertEq(usdcToken.balanceOf(address(depositManager)), depositAmount);
        assertEq(mockAToken.balanceOf(address(depositManager)), 0);

        // Reset
        mockAavePool.setShouldRevertSupply(false);
    }

    function test_Integration_AaveWithdrawFailure_HandledGracefully() public {
        uint256 depositAmount = 1000 * 1e6;

        // Deposit to Aave
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Verify in Aave
        assertEq(mockAToken.balanceOf(address(depositManager)), depositAmount);
        assertEq(usdcToken.balanceOf(address(depositManager)), 0);

        // Make Aave withdraw revert
        mockAavePool.setShouldRevertWithdraw(true);

        uint256 platformTokenAmount = depositAmount * 1e12;
        uint256 userBalanceBefore = platformToken.balanceOf(user1);
        uint256 userUSDCBefore = usdcToken.balanceOf(user1);

        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenAmount);

        // Tokens are burned but user gets 0 USDC (graceful failure handling)
        assertEq(platformToken.balanceOf(user1), userBalanceBefore - platformTokenAmount);
        assertEq(usdcToken.balanceOf(user1), userUSDCBefore); // No USDC returned

        // Reset
        mockAavePool.setShouldRevertWithdraw(false);
    }

    function test_Integration_PartialAaveOperations() public {
        uint256 depositAmount = 1000 * 1e6;

        // Enable partial amounts
        mockAavePool.setReturnPartialAmounts(true);

        // Deposit - should handle partial supply
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        uint256 aaveBalance = mockAToken.balanceOf(address(depositManager));
        uint256 contractBalance = usdcToken.balanceOf(address(depositManager));

        // MockAavePool records only half as supplied
        uint256 expectedAave = depositAmount / 2;
        uint256 expectedExcess = depositAmount / 2;

        assertEq(aaveBalance, expectedAave, "Aave should have partial amount recorded");
        assertEq(contractBalance, expectedExcess, "Contract should have excess returned from Aave");

        // Verify total backing is maintained
        uint256 totalAvailable = depositManager.getTotalAvailableBalance();
        assertEq(totalAvailable, depositAmount, "Total available should equal deposit amount");

        // Reset
        mockAavePool.setReturnPartialAmounts(false);
    }

    function test_Integration_YieldGenerationOverTime() public {
        uint256 depositAmount = 1000 * 1e6;

        // Deposit
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Simulate yield generation (10% yield)
        mockAavePool.setYieldRateBps(11000); // 110% = 10% yield
        mockAavePool.accrueYield(address(usdcToken), address(depositManager));

        // Mint USDC to pool to back the yield
        uint256 aaveBalance = depositManager.getAaveUSDCBalance();
        usdcToken.mint(address(mockAavePool), aaveBalance - depositAmount);

        // Check accumulated earnings
        uint256 earnings = depositManager.getAccumulatedEarnings();
        assertGt(earnings, 0, "Earnings should be generated");

        // Check yield rate
        uint256 yieldRate = depositManager.getCurrentYieldRate();
        assertGt(yieldRate, 0, "Yield rate should be positive");

        // Balance supply should withdraw excess
        uint256 totalAvailable = depositManager.getTotalAvailableBalance();
        uint256 requiredBacking = depositAmount;
        uint256 excess = totalAvailable - requiredBacking;

        if (excess > 0) {
            uint256 recipientBalanceBefore = usdcToken.balanceOf(recipient);

            vm.prank(owner);
            depositManager.balanceSupply(recipient);

            assertGt(usdcToken.balanceOf(recipient), recipientBalanceBefore, "Excess should be withdrawn");
        }
    }

    // ==================== Multi-Contract Integration ====================

    function test_Integration_PlatformTokenAndDepositManagerWorkTogether() public {
        uint256 depositAmount = 1000 * 1e6;

        // Verify DepositManager is set in PlatformToken
        assertEq(platformToken.depositManager(), address(depositManager));

        // Deposit
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Verify PlatformToken minted correctly
        assertEq(platformToken.balanceOf(user1), depositAmount * 1e12);
        assertEq(platformToken.totalSupply(), depositAmount * 1e12);

        // Withdraw
        uint256 platformTokenAmount = depositAmount * 1e12;
        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenAmount);

        // Verify PlatformToken burned correctly
        assertEq(platformToken.balanceOf(user1), 0);
        assertEq(platformToken.totalSupply(), 0);
    }

    function test_Integration_DepositManagerCallsPlatformTokenMint() public {
        uint256 depositAmount = 1000 * 1e6;

        uint256 totalSupplyBefore = platformToken.totalSupply();

        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Verify mint was called
        assertEq(platformToken.totalSupply(), totalSupplyBefore + depositAmount * 1e12);
    }

    function test_Integration_DepositManagerCallsPlatformTokenBurn() public {
        uint256 depositAmount = 1000 * 1e6;

        // Deposit first
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        uint256 totalSupplyBefore = platformToken.totalSupply();
        uint256 platformTokenAmount = depositAmount * 1e12;

        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenAmount);

        // Verify burn was called
        assertEq(platformToken.totalSupply(), totalSupplyBefore - platformTokenAmount);
    }

    function test_Integration_AccessControlBetweenContracts() public {
        // Verify only DepositManager can mint
        vm.expectRevert(PlatformToken.OnlyDepositManager.selector);
        platformToken.mint(user1, 1000e18);

        // Verify only DepositManager can burn
        vm.expectRevert(PlatformToken.OnlyDepositManager.selector);
        platformToken.burn(user1, 1000e18);

        // Verify DepositManager can mint
        uint256 depositAmount = 1000 * 1e6;
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        assertEq(platformToken.balanceOf(user1), depositAmount * 1e12);
    }

    // ==================== Complex Integration Scenarios ====================

    function test_Integration_MultipleUsersMultipleDeposits() public {
        uint256 deposit1 = 1000 * 1e6;
        uint256 deposit2 = 500 * 1e6;

        // User1 deposits
        vm.prank(user1);
        depositManager.depositUSDC(deposit1);

        // User2 deposits
        vm.prank(user2);
        depositManager.depositUSDC(deposit2);

        // Verify both users have tokens
        assertEq(platformToken.balanceOf(user1), deposit1 * 1e12);
        assertEq(platformToken.balanceOf(user2), deposit2 * 1e12);
        assertEq(platformToken.totalSupply(), (deposit1 + deposit2) * 1e12);

        // Verify total balance
        uint256 totalBalance = depositManager.getTotalAvailableBalance();
        assertEq(totalBalance, deposit1 + deposit2);
    }

    function test_Integration_DepositWithdrawWithAaveStateChanges() public {
        uint256 depositAmount = 1000 * 1e6;

        // Deposit while Aave is active
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Verify in Aave
        assertEq(mockAToken.balanceOf(address(depositManager)), depositAmount);

        // Pause Aave
        mockAavePool.setReservePaused(address(usdcToken), true);

        // Make another deposit (should go to contract)
        uint256 deposit2 = 500 * 1e6;
        vm.prank(user2);
        depositManager.depositUSDC(deposit2);

        // Verify split between Aave and contract
        assertEq(mockAToken.balanceOf(address(depositManager)), depositAmount);
        assertEq(usdcToken.balanceOf(address(depositManager)), deposit2);

        // Unpause Aave
        mockAavePool.setReservePaused(address(usdcToken), false);

        // Withdraw user1 (from Aave)
        uint256 platformTokenAmount1 = depositAmount * 1e12;
        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenAmount1);

        // Withdraw user2 (from contract)
        uint256 platformTokenAmount2 = deposit2 * 1e12;
        vm.prank(user2);
        depositManager.withdrawUSDC(platformTokenAmount2);

        // Verify all withdrawn
        assertEq(mockAToken.balanceOf(address(depositManager)), 0);
        assertEq(usdcToken.balanceOf(address(depositManager)), 0);
    }

    function test_Integration_YieldAccumulationAndWithdrawal() public {
        uint256 depositAmount = 1000 * 1e6;

        // Deposit
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Generate yield multiple times
        mockAavePool.setYieldRateBps(10500); // 5% yield
        for (uint256 i = 0; i < 5; i++) {
            mockAavePool.accrueYield(address(usdcToken), address(depositManager));
        }

        // Mint USDC to pool to back the yield
        uint256 aaveBalance = depositManager.getAaveUSDCBalance();
        usdcToken.mint(address(mockAavePool), aaveBalance - depositAmount);

        // Check earnings accumulated
        uint256 earnings = depositManager.getAccumulatedEarnings();
        assertGt(earnings, 0, "Earnings should accumulate");

        // Withdraw excess
        uint256 recipientBalanceBefore = usdcToken.balanceOf(recipient);
        vm.prank(owner);
        depositManager.balanceSupply(recipient);

        // Verify excess withdrawn
        assertGt(usdcToken.balanceOf(recipient), recipientBalanceBefore, "Excess should be withdrawn");

        // Verify backing maintained
        uint256 remainingBalance = depositManager.getTotalAvailableBalance();
        uint256 requiredBacking = depositAmount;
        assertGe(remainingBalance, requiredBacking - 1, "Backing should be maintained");
    }
}
