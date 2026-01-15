// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DepositManager} from "../src/DepositManager.sol";
import {PlatformToken} from "../src/PlatformToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockAToken} from "./mocks/MockAToken.sol";

contract DepositManagerFuzzTest is Test {
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
    uint256 public constant PLATFORM_TOKEN_DECIMALS = 18;

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
        usdcToken.mint(user1, 100_000_000 * 1e6); // $100M USDC
        usdcToken.mint(user2, 100_000_000 * 1e6); // $100M USDC

        // Approve DepositManager to spend USDC
        vm.startPrank(user1);
        usdcToken.approve(address(depositManager), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        usdcToken.approve(address(depositManager), type(uint256).max);
        vm.stopPrank();
    }

    // ==================== depositUSDC Fuzzing ====================

    function testFuzz_depositUSDC(uint256 amount) public {
        // Constrain amount to valid range
        amount = bound(amount, depositManager.MIN_DEPOSIT_AMOUNT(), depositManager.MAX_DEPOSIT_AMOUNT());

        uint256 userBalanceBefore = usdcToken.balanceOf(user1);
        uint256 totalSupplyBefore = platformToken.totalSupply();
        uint256 contractBalanceBefore = depositManager.getTotalAvailableBalance();

        vm.prank(user1);
        depositManager.depositUSDC(amount);

        // Property: 1:1 mint ratio maintained
        uint256 expectedPlatformTokens = amount * 1e12;
        assertEq(platformToken.balanceOf(user1), expectedPlatformTokens);
        assertEq(platformToken.totalSupply(), totalSupplyBefore + expectedPlatformTokens);

        // Property: User balance decreased
        assertEq(usdcToken.balanceOf(user1), userBalanceBefore - amount);

        // Property: Total available balance increased
        assertGe(depositManager.getTotalAvailableBalance(), contractBalanceBefore + amount);
    }

    function testFuzz_depositUSDC_MultipleDeposits(uint256 amount1, uint256 amount2) public {
        // Constrain amounts to valid range
        amount1 = bound(amount1, depositManager.MIN_DEPOSIT_AMOUNT(), depositManager.MAX_DEPOSIT_AMOUNT());
        amount2 = bound(amount2, depositManager.MIN_DEPOSIT_AMOUNT(), depositManager.MAX_DEPOSIT_AMOUNT());

        // Ensure user has enough balance
        uint256 totalNeeded = amount1 + amount2;
        if (usdcToken.balanceOf(user1) < totalNeeded) {
            usdcToken.mint(user1, totalNeeded - usdcToken.balanceOf(user1));
        }

        vm.startPrank(user1);
        depositManager.depositUSDC(amount1);
        depositManager.depositUSDC(amount2);
        vm.stopPrank();

        // Property: Total platform tokens = sum of deposits
        uint256 expectedTotal = (amount1 + amount2) * 1e12;
        assertEq(platformToken.balanceOf(user1), expectedTotal);
        assertEq(platformToken.totalSupply(), expectedTotal);
    }

    function testFuzz_depositUSDC_DecimalConversion(uint256 usdcAmount) public {
        // Constrain to valid range
        usdcAmount = bound(usdcAmount, depositManager.MIN_DEPOSIT_AMOUNT(), depositManager.MAX_DEPOSIT_AMOUNT());

        vm.prank(user1);
        depositManager.depositUSDC(usdcAmount);

        // Property: Decimal conversion is correct (6 decimals -> 18 decimals)
        uint256 expectedPlatformTokens = usdcAmount * 1e12;
        assertEq(platformToken.balanceOf(user1), expectedPlatformTokens);
    }

    function testFuzz_depositUSDC_AmountBelowMinimum(uint256 amount) public {
        // Constrain to below minimum, but skip 0 (which reverts with InvalidAmount)
        if (amount == 0) return; // Skip zero case
        amount = bound(amount, 1, depositManager.MIN_DEPOSIT_AMOUNT() - 1);

        vm.prank(user1);
        vm.expectRevert(DepositManager.AmountBelowMinimum.selector);
        depositManager.depositUSDC(amount);
    }

    function testFuzz_depositUSDC_AmountExceedsMaximum(uint256 amount) public {
        // Constrain to above maximum, but avoid overflow
        uint256 maxAmount = depositManager.MAX_DEPOSIT_AMOUNT();
        // Use a safe upper bound to avoid arithmetic overflow
        uint256 safeMax = type(uint256).max / 2; // Safe upper bound
        amount = bound(amount, maxAmount + 1, safeMax > maxAmount + 1 ? safeMax : maxAmount + 1000);

        // Ensure user has enough balance (but don't mint if amount would overflow)
        if (amount <= type(uint256).max / 2 && usdcToken.balanceOf(user1) < amount) {
            usdcToken.mint(user1, amount);
        }

        vm.prank(user1);
        vm.expectRevert(DepositManager.AmountExceedsMaximum.selector);
        depositManager.depositUSDC(amount);
    }

    // ==================== withdrawUSDC Fuzzing ====================

    function testFuzz_withdrawUSDC(uint256 depositAmount, uint256 withdrawAmount) public {
        // Constrain deposit amount to valid range
        depositAmount = bound(depositAmount, depositManager.MIN_DEPOSIT_AMOUNT(), depositManager.MAX_DEPOSIT_AMOUNT());

        // Ensure user has enough balance
        if (usdcToken.balanceOf(user1) < depositAmount) {
            usdcToken.mint(user1, depositAmount);
        }

        // Make deposit
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        uint256 platformTokenBalance = platformToken.balanceOf(user1);

        // Constrain withdraw amount to valid range and not exceed balance
        uint256 minWithdraw = depositManager.MIN_WITHDRAW_AMOUNT();
        withdrawAmount = bound(withdrawAmount, minWithdraw, platformTokenBalance);

        // Convert to platform token amount
        uint256 platformTokenWithdraw = withdrawAmount;

        uint256 userUSDCBefore = usdcToken.balanceOf(user1);
        uint256 totalSupplyBefore = platformToken.totalSupply();

        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenWithdraw);

        // Property: Platform tokens burned
        assertEq(platformToken.balanceOf(user1), platformTokenBalance - platformTokenWithdraw);
        assertEq(platformToken.totalSupply(), totalSupplyBefore - platformTokenWithdraw);

        // Property: USDC returned (within rounding)
        uint256 expectedUSDC = platformTokenWithdraw / 1e12;
        uint256 actualUSDC = usdcToken.balanceOf(user1) - userUSDCBefore;
        // Allow for rounding differences
        assertGe(actualUSDC, expectedUSDC - 1);
        assertLe(actualUSDC, expectedUSDC);
    }

    function testFuzz_withdrawUSDC_CannotWithdrawMoreThanDeposited(uint256 depositAmount, uint256 withdrawAmount)
        public
    {
        // Constrain deposit amount to valid range
        depositAmount = bound(depositAmount, depositManager.MIN_DEPOSIT_AMOUNT(), depositManager.MAX_DEPOSIT_AMOUNT());

        // Ensure user has enough balance
        if (usdcToken.balanceOf(user1) < depositAmount) {
            usdcToken.mint(user1, depositAmount);
        }

        // Make deposit
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        uint256 platformTokenBalance = platformToken.balanceOf(user1);

        // Constrain withdraw amount to exceed balance
        withdrawAmount = bound(withdrawAmount, platformTokenBalance + 1, type(uint256).max);

        vm.prank(user1);
        vm.expectRevert(DepositManager.InsufficientPlatformTokens.selector);
        depositManager.withdrawUSDC(withdrawAmount);
    }

    function testFuzz_withdrawUSDC_MaintainsOneToOneRatio(uint256 depositAmount) public {
        // Constrain deposit amount to valid range
        depositAmount = bound(depositAmount, depositManager.MIN_DEPOSIT_AMOUNT(), depositManager.MAX_DEPOSIT_AMOUNT());

        // Ensure user has enough balance
        if (usdcToken.balanceOf(user1) < depositAmount) {
            usdcToken.mint(user1, depositAmount);
        }

        // Make deposit
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        uint256 platformTokenBalance = platformToken.balanceOf(user1);
        uint256 userUSDCBefore = usdcToken.balanceOf(user1);

        // Withdraw all
        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenBalance);

        // Property: Withdrawal maintains 1:1 ratio (within rounding)
        uint256 usdcReturned = usdcToken.balanceOf(user1) - userUSDCBefore;
        // Allow for rounding differences
        assertGe(usdcReturned, depositAmount - 1);
        assertLe(usdcReturned, depositAmount);
    }

    // ==================== Multiple Operations Fuzzing ====================

    function testFuzz_multipleDeposits(uint256[5] memory amounts) public {
        uint256 totalDeposited = 0;

        // Constrain and sum amounts
        for (uint256 i = 0; i < amounts.length; i++) {
            amounts[i] = bound(amounts[i], depositManager.MIN_DEPOSIT_AMOUNT(), depositManager.MAX_DEPOSIT_AMOUNT() / 5);
            totalDeposited += amounts[i];
        }

        // Ensure user has enough balance
        if (usdcToken.balanceOf(user1) < totalDeposited) {
            usdcToken.mint(user1, totalDeposited - usdcToken.balanceOf(user1));
        }

        // Make all deposits
        vm.startPrank(user1);
        for (uint256 i = 0; i < amounts.length; i++) {
            depositManager.depositUSDC(amounts[i]);
        }
        vm.stopPrank();

        // Property: Total supply matches sum of deposits
        uint256 expectedTotal = totalDeposited * 1e12;
        assertEq(platformToken.balanceOf(user1), expectedTotal);
        assertEq(platformToken.totalSupply(), expectedTotal);
    }

    function testFuzz_depositWithdrawCycle(uint256 amount) public {
        // Constrain amount to valid range
        amount = bound(amount, depositManager.MIN_DEPOSIT_AMOUNT(), depositManager.MAX_DEPOSIT_AMOUNT());

        // Ensure user has enough balance
        if (usdcToken.balanceOf(user1) < amount) {
            usdcToken.mint(user1, amount);
        }

        uint256 userUSDCBefore = usdcToken.balanceOf(user1);

        // Deposit
        vm.prank(user1);
        depositManager.depositUSDC(amount);

        uint256 platformTokenBalance = platformToken.balanceOf(user1);

        // Withdraw same amount
        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenBalance);

        // Property: Net zero change (within rounding)
        uint256 userUSDCAfter = usdcToken.balanceOf(user1);
        assertGe(userUSDCAfter, userUSDCBefore - 1);
        assertLe(userUSDCAfter, userUSDCBefore);
        assertEq(platformToken.balanceOf(user1), 0);
        assertEq(platformToken.totalSupply(), 0);
    }

    function testFuzz_complexScenario(uint256[3] memory deposits, uint256[3] memory withdrawals) public {
        // Constrain deposits
        for (uint256 i = 0; i < deposits.length; i++) {
            deposits[i] =
                bound(deposits[i], depositManager.MIN_DEPOSIT_AMOUNT(), depositManager.MAX_DEPOSIT_AMOUNT() / 3);
        }

        // Make deposits
        uint256 totalDeposited = 0;
        vm.startPrank(user1);
        for (uint256 i = 0; i < deposits.length; i++) {
            if (usdcToken.balanceOf(user1) < deposits[i]) {
                usdcToken.mint(user1, deposits[i] - usdcToken.balanceOf(user1));
            }
            depositManager.depositUSDC(deposits[i]);
            totalDeposited += deposits[i];
        }
        vm.stopPrank();

        uint256 platformTokenBalance = platformToken.balanceOf(user1);

        // Constrain withdrawals to not exceed balance
        for (uint256 i = 0; i < withdrawals.length; i++) {
            uint256 maxWithdraw = platformTokenBalance / withdrawals.length;
            withdrawals[i] = bound(withdrawals[i], depositManager.MIN_WITHDRAW_AMOUNT(), maxWithdraw);
        }

        // Make withdrawals
        vm.startPrank(user1);
        for (uint256 i = 0; i < withdrawals.length; i++) {
            if (withdrawals[i] <= platformToken.balanceOf(user1)) {
                depositManager.withdrawUSDC(withdrawals[i]);
            }
        }
        vm.stopPrank();

        // Property: Total supply always matches deposits minus withdrawals
        uint256 totalWithdrawn = 0;
        for (uint256 i = 0; i < withdrawals.length; i++) {
            totalWithdrawn += withdrawals[i];
        }

        // Allow for rounding
        uint256 expectedSupply = (totalDeposited * 1e12) - totalWithdrawn;
        assertGe(platformToken.totalSupply(), expectedSupply - 1000); // Allow rounding
        assertLe(platformToken.totalSupply(), expectedSupply + 1000);
    }

    // ==================== balanceSupply Fuzzing ====================

    function testFuzz_balanceSupply(uint256 depositAmount, uint256 yieldBps) public {
        // Constrain deposit amount to valid range
        depositAmount = bound(depositAmount, depositManager.MIN_DEPOSIT_AMOUNT(), depositManager.MAX_DEPOSIT_AMOUNT());

        // Constrain yield rate (10000 = 1.0 = no yield, 11000 = 1.1 = 10% yield)
        yieldBps = bound(yieldBps, 10001, 20000); // 0.01% to 100% yield

        // Ensure user has enough balance
        if (usdcToken.balanceOf(user1) < depositAmount) {
            usdcToken.mint(user1, depositAmount);
        }

        // Make deposit
        vm.prank(user1);
        depositManager.depositUSDC(depositAmount);

        // Simulate yield
        mockAavePool.setYieldRateBps(yieldBps);
        mockAavePool.accrueYield(address(usdcToken), address(depositManager));

        // Mint extra USDC to the pool to back the yield
        uint256 aaveBalance = depositManager.getAaveUSDCBalance();
        if (aaveBalance > depositAmount) {
            usdcToken.mint(address(mockAavePool), aaveBalance - depositAmount);
        }

        // Calculate expected excess
        uint256 requiredBacking = depositAmount;
        uint256 excess = aaveBalance > requiredBacking ? aaveBalance - requiredBacking : 0;

        if (excess > 0) {
            uint256 recipientBalanceBefore = usdcToken.balanceOf(recipient);

            vm.prank(owner);
            depositManager.balanceSupply(recipient);

            // Property: Only excess withdrawn
            uint256 recipientBalanceAfter = usdcToken.balanceOf(recipient);
            assertGe(recipientBalanceAfter - recipientBalanceBefore, excess - 1); // Allow rounding

            // Property: Backing maintained for remaining tokens
            uint256 remainingBalance = depositManager.getTotalAvailableBalance();
            assertGe(remainingBalance, requiredBacking - 1); // Allow rounding
        }
    }

    // ==================== Edge Case Fuzzing ====================

    function testFuzz_DecimalBoundaryCases(uint256 amount) public {
        // Test amounts near 1e12 multiples (decimal conversion boundaries)
        // Constrain to valid range
        amount = bound(amount, depositManager.MIN_DEPOSIT_AMOUNT(), depositManager.MAX_DEPOSIT_AMOUNT());

        // Round to nearest 1e12 multiple
        uint256 roundedAmount = (amount / 1e12) * 1e12;
        if (roundedAmount < depositManager.MIN_DEPOSIT_AMOUNT()) {
            roundedAmount = depositManager.MIN_DEPOSIT_AMOUNT();
        }

        // Ensure user has enough balance
        if (usdcToken.balanceOf(user1) < roundedAmount) {
            usdcToken.mint(user1, roundedAmount);
        }

        vm.prank(user1);
        depositManager.depositUSDC(roundedAmount);

        // Property: Decimal conversion works correctly
        uint256 expectedPlatformTokens = roundedAmount * 1e12;
        assertEq(platformToken.balanceOf(user1), expectedPlatformTokens);
    }

    function testFuzz_LargeAmounts(uint256 amount) public {
        // Test amounts near MAX_DEPOSIT_AMOUNT
        uint256 maxAmount = depositManager.MAX_DEPOSIT_AMOUNT();
        amount = bound(amount, maxAmount - 1000 * 1e6, maxAmount);

        // Ensure user has enough balance
        if (usdcToken.balanceOf(user1) < amount) {
            usdcToken.mint(user1, amount);
        }

        vm.prank(user1);
        depositManager.depositUSDC(amount);

        // Property: Large amounts handled correctly
        uint256 expectedPlatformTokens = amount * 1e12;
        assertEq(platformToken.balanceOf(user1), expectedPlatformTokens);
    }

    function testFuzz_SmallAmounts(uint256 amount) public {
        // Test amounts near MIN_DEPOSIT_AMOUNT
        uint256 minAmount = depositManager.MIN_DEPOSIT_AMOUNT();
        amount = bound(amount, minAmount, minAmount + 1000);

        // Ensure user has enough balance
        if (usdcToken.balanceOf(user1) < amount) {
            usdcToken.mint(user1, amount);
        }

        vm.prank(user1);
        depositManager.depositUSDC(amount);

        // Property: Small amounts handled correctly
        uint256 expectedPlatformTokens = amount * 1e12;
        assertEq(platformToken.balanceOf(user1), expectedPlatformTokens);
    }

    function testFuzz_RoundingScenarios(uint256 amount) public {
        // Test amounts that may cause rounding issues
        // Constrain to valid range
        amount = bound(amount, depositManager.MIN_DEPOSIT_AMOUNT(), depositManager.MAX_DEPOSIT_AMOUNT());

        // Ensure user has enough balance
        if (usdcToken.balanceOf(user1) < amount) {
            usdcToken.mint(user1, amount);
        }

        // Deposit
        vm.prank(user1);
        depositManager.depositUSDC(amount);

        uint256 platformTokenBalance = platformToken.balanceOf(user1);

        // Withdraw
        vm.prank(user1);
        depositManager.withdrawUSDC(platformTokenBalance);

        // Property: Rounding doesn't break invariants
        // User should get back approximately the same amount (within rounding)
        assertLe(platformToken.balanceOf(user1), 1); // Allow for rounding dust
    }
}
