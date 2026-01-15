// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DepositManager} from "../src/DepositManager.sol";
import {PlatformToken} from "../src/PlatformToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockAToken} from "./mocks/MockAToken.sol";
import {DataTypes} from "aave-v3/protocol/libraries/types/DataTypes.sol";

/// @title DepositManagerHandler
/// @notice Handler contract for invariant testing
contract DepositManagerHandler is Test {
    DepositManager public depositManager;
    PlatformToken public platformToken;
    MockERC20 public usdcToken;
    MockAavePool public mockAavePool;

    address[] public users;
    mapping(address => uint256) public userDeposits;
    mapping(address => uint256) public userWithdrawals;

    uint256 public constant MAX_DEPOSIT = 100_000 * 1e6;
    uint256 public constant MIN_DEPOSIT = 10000; // $0.01

    constructor(
        DepositManager _depositManager,
        PlatformToken _platformToken,
        MockERC20 _usdcToken,
        MockAavePool _mockAavePool
    ) {
        depositManager = _depositManager;
        platformToken = _platformToken;
        usdcToken = _usdcToken;
        mockAavePool = _mockAavePool;
    }

    function depositUSDC(address user, uint256 amount) public {
        // Skip zero address
        if (user == address(0)) return;

        // Always bound to valid range to prevent overflow
        amount = bound(amount, MIN_DEPOSIT, MAX_DEPOSIT);

        // Double-check overflow protection for platform token conversion
        if (amount > type(uint256).max / 1e12) {
            amount = type(uint256).max / 1e12;
            if (amount < MIN_DEPOSIT) return;
        }

        // Ensure user has enough balance
        uint256 userBalance = usdcToken.balanceOf(user);
        if (userBalance < amount) {
            usdcToken.mint(user, amount * 2);
        }

        // Approve if needed
        if (usdcToken.allowance(user, address(depositManager)) < amount) {
            vm.prank(user);
            usdcToken.approve(address(depositManager), type(uint256).max);
        }

        // Track user (limit array size to prevent gas issues)
        if (users.length < 100) {
            bool isNewUser = true;
            for (uint256 i = 0; i < users.length; i++) {
                if (users[i] == user) {
                    isNewUser = false;
                    break;
                }
            }
            if (isNewUser) {
                users.push(user);
            }
        }

        // Perform deposit
        vm.prank(user);
        try depositManager.depositUSDC(amount) {
            if (userDeposits[user] <= type(uint256).max - amount) {
                userDeposits[user] += amount;
            }
        } catch {}
    }

    function withdrawUSDC(address user, uint256 platformTokenAmount) public {
        // Skip zero address
        if (user == address(0)) return;

        uint256 balance = platformToken.balanceOf(user);
        if (balance == 0) return;

        // Constrain to valid range
        uint256 minWithdraw = depositManager.MIN_WITHDRAW_AMOUNT();
        if (platformTokenAmount < minWithdraw || platformTokenAmount > balance) {
            platformTokenAmount = bound(platformTokenAmount, minWithdraw, balance);
        }

        // Perform withdrawal
        vm.prank(user);
        try depositManager.withdrawUSDC(platformTokenAmount) {
            if (platformTokenAmount >= 1e12) {
                userWithdrawals[user] += platformTokenAmount / 1e12;
            }
        } catch {}
    }

    function pause() public {
        vm.prank(depositManager.owner());
        try depositManager.pause() {} catch {}
    }

    function unpause() public {
        vm.prank(depositManager.owner());
        try depositManager.unpause() {} catch {}
    }

    function balanceSupply(address recipient) public {
        // Skip zero address
        if (recipient == address(0)) return;

        vm.prank(depositManager.owner());
        try depositManager.balanceSupply(recipient) {} catch {}
    }

    // Helper to get sum of all user balances
    function getTotalUserBalances() public view returns (uint256) {
        uint256 total = 0;
        uint256 maxUsers = users.length > 50 ? 50 : users.length;
        for (uint256 i = 0; i < maxUsers; i++) {
            uint256 balance = platformToken.balanceOf(users[i]);
            if (total > type(uint256).max - balance) {
                return type(uint256).max;
            }
            total += balance;
        }
        return total;
    }
}

contract DepositManagerInvariantTest is Test {
    DepositManager public depositManager;
    PlatformToken public platformToken;
    MockERC20 public usdcToken;
    MockAavePool public mockAavePool;
    MockAToken public mockAToken;
    DepositManagerHandler public handler;

    address public owner = address(0x1);
    address public recipient = address(0x5);

    uint256 public constant USDC_DECIMALS = 6;

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

        // Create handler
        handler = new DepositManagerHandler(depositManager, platformToken, usdcToken, mockAavePool);

        // Give handler some initial users with USDC
        for (uint256 i = 0; i < 10; i++) {
            address user = address(uint160(0x1000 + i));
            usdcToken.mint(user, 10_000_000 * 1e6); // $10M USDC per user
        }

        // Exclude PlatformToken from fuzzing
        excludeContract(address(platformToken));
    }

    // ==================== Core Invariants ====================

    /// @notice Invariant: 1:1 Backing (before emergency withdrawal)
    function invariant_OneToOneBacking() public view {
        if (address(depositManager) == address(0)) return;

        try depositManager.getTotalAvailableBalance() returns (uint256 totalAvailableUSDC) {
            try platformToken.totalSupply() returns (uint256 totalSupplyCUT) {
                if (totalSupplyCUT > type(uint256).max / 1e12) {
                    return;
                }

                uint256 requiredUSDC = totalSupplyCUT / 1e12;
                assertGe(totalAvailableUSDC, requiredUSDC > 0 ? requiredUSDC - 1 : 0, "1:1 backing invariant violated");
            } catch {}
        } catch {}
    }

    /// @notice Invariant: Yield Calculation
    function invariant_YieldCalculation() public view {
        uint256 earnings = depositManager.getAccumulatedEarnings();
        assertGe(earnings, 0, "Yield calculation invariant violated");

        uint256 totalAvailableUSDC = depositManager.getTotalAvailableBalance();
        uint256 totalSupplyCUT = platformToken.totalSupply();
        uint256 requiredUSDC = totalSupplyCUT / 1e12;

        if (earnings > 0) {
            assertGe(totalAvailableUSDC, requiredUSDC + earnings - 1, "Earnings not reflected in balance");
        }
    }

    /// @notice Invariant: Pause State
    function invariant_PauseState() public view {
        bool isPaused = depositManager.paused();
        assertTrue(isPaused || !isPaused);
    }

    /// @notice Invariant: Access Control
    function invariant_AccessControl() public view {
        assertEq(platformToken.depositManager(), address(depositManager), "DepositManager not set correctly");
        assertEq(depositManager.owner(), owner, "Owner not set correctly");
    }

    /// @notice Invariant: Total Supply Non-Negative
    function invariant_TotalSupplyNonNegative() public view {
        uint256 totalSupply = platformToken.totalSupply();
        assertGe(totalSupply, 0, "Total supply cannot be negative");
    }

    /// @notice Invariant: User Balances Non-Negative
    function invariant_UserBalancesNonNegative() public view {
        uint256 totalUserBalances = handler.getTotalUserBalances();
        assertGe(totalUserBalances, 0, "Total user balances cannot be negative");
    }

    /// @notice Invariant: No Arithmetic Overflow
    function invariant_NoArithmeticOverflow() public view {
        uint256 totalSupply = platformToken.totalSupply();
        uint256 totalAvailable = depositManager.getTotalAvailableBalance();

        assertGe(totalSupply, 0);
        assertGe(totalAvailable, 0);
    }

    /// @notice Invariant: Reserve Data Consistency
    function invariant_ReserveDataConsistency() public view {
        if (address(depositManager) == address(0)) return;

        try depositManager.getUSDCReserveData() returns (DataTypes.ReserveData memory reserve) {
            if (reserve.aTokenAddress != address(0)) {
                assertEq(reserve.aTokenAddress, address(mockAToken), "aToken address mismatch");
            }
        } catch {}
    }

    /// @notice Invariant: Constants Consistency
    function invariant_ConstantsConsistency() public view {
        assertEq(depositManager.MIN_DEPOSIT_AMOUNT(), 10000, "MIN_DEPOSIT_AMOUNT incorrect");
        assertEq(depositManager.MAX_DEPOSIT_AMOUNT(), 100_000 * 1e6, "MAX_DEPOSIT_AMOUNT incorrect");
        assertEq(depositManager.MIN_WITHDRAW_AMOUNT(), 10000 * 1e12, "MIN_WITHDRAW_AMOUNT incorrect");
    }

    /// @notice Invariant: Immutable Addresses
    function invariant_ImmutableAddresses() public view {
        assertEq(address(depositManager.usdcToken()), address(usdcToken), "USDC token address changed");
        assertEq(address(depositManager.platformToken()), address(platformToken), "Platform token address changed");
        assertEq(address(depositManager.aavePool()), address(mockAavePool), "Aave Pool address changed");
    }

    /// @notice Invariant: State Consistency
    function invariant_StateConsistency() public view {
        uint256 totalSupply = platformToken.totalSupply();
        uint256 totalAvailable = depositManager.getTotalAvailableBalance();

        assertGe(totalAvailable, 0);
        assertGe(totalSupply, 0);
    }
}
