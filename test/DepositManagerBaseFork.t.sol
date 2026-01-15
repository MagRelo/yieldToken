// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DepositManager} from "../src/DepositManager.sol";
import {PlatformToken} from "../src/PlatformToken.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {DataTypes} from "aave-v3/protocol/libraries/types/DataTypes.sol";
import "solmate/tokens/ERC20.sol";

/**
 * @title DepositManagerBaseForkTest
 * @notice Fork tests against Base mainnet to verify USDC and Aave V3 integration
 * @dev Run with: forge test --match-contract DepositManagerBaseForkTest --fork-url $BASE_RPC_URL -vvv
 * @dev If tests fail, try with a specific block: --fork-block-number 20000000
 */
contract DepositManagerBaseForkTest is Test {
    // Base Mainnet addresses
    // USDC: https://basescan.org/token/0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    // Aave V3 Pool: https://basescan.org/address/0xA238Dd80C259a72e81d7e4664a9801593F98d1c5
    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

    DepositManager public depositManager;
    PlatformToken public platformToken;
    ERC20 public usdc;
    IPool public aavePool;

    address public owner;
    address public user;

    function setUp() public {
        // Skip if not forking
        if (block.chainid != 8453) {
            return;
        }

        owner = makeAddr("owner");
        user = makeAddr("user");

        usdc = ERC20(USDC);
        aavePool = IPool(AAVE_POOL);

        // Deploy contracts
        vm.startPrank(owner);
        platformToken = new PlatformToken("Cut Platform Token", "CUT");
        depositManager = new DepositManager(USDC, address(platformToken), AAVE_POOL);
        platformToken.setDepositManager(address(depositManager));
        vm.stopPrank();

        // Fund user with USDC (deal works on forked networks)
        deal(USDC, user, 10_000 * 1e6); // $10,000 USDC

        // Approve
        vm.prank(user);
        usdc.approve(address(depositManager), type(uint256).max);
    }

    modifier onlyFork() {
        if (block.chainid != 8453) {
            console.log("Skipping fork test - not on Base mainnet");
            return;
        }
        _;
    }

    // ==================== USDC Tests ====================

    function test_Fork_USDCExists() public onlyFork {
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
    }

    function test_Fork_UserHasUSDC() public onlyFork {
        assertEq(usdc.balanceOf(user), 10_000 * 1e6);
    }

    // ==================== Aave Pool Tests ====================

    function test_Fork_AavePoolExists() public onlyFork {
        // Verify pool has USDC reserve
        DataTypes.ReserveData memory reserve = aavePool.getReserveData(USDC);
        assertTrue(reserve.aTokenAddress != address(0), "aToken should exist");
    }

    function test_Fork_AaveUSDCReserveActive() public onlyFork {
        DataTypes.ReserveConfigurationMap memory config = aavePool.getConfiguration(USDC);
        // If we can get config, reserve exists and is queryable
        assertTrue(config.data != 0, "Reserve config should have data");
    }

    // ==================== DepositManager Integration Tests ====================

    function test_Fork_DepositUSDC() public onlyFork {
        uint256 depositAmount = 100 * 1e6; // $100 USDC

        uint256 userUSDCBefore = usdc.balanceOf(user);
        uint256 userPlatformTokensBefore = platformToken.balanceOf(user);

        vm.prank(user);
        depositManager.depositUSDC(depositAmount);

        // Verify USDC transferred
        assertEq(usdc.balanceOf(user), userUSDCBefore - depositAmount);

        // Verify platform tokens minted
        assertEq(platformToken.balanceOf(user), userPlatformTokensBefore + depositAmount * 1e12);

        // Verify USDC went to Aave
        uint256 aaveBalance = depositManager.getAaveUSDCBalance();
        assertGe(aaveBalance, depositAmount - 1, "USDC should be in Aave");
    }

    function test_Fork_WithdrawUSDC() public onlyFork {
        uint256 depositAmount = 100 * 1e6; // $100 USDC

        // Deposit first
        vm.prank(user);
        depositManager.depositUSDC(depositAmount);

        uint256 platformTokenBalance = platformToken.balanceOf(user);
        uint256 userUSDCBefore = usdc.balanceOf(user);

        // Withdraw
        vm.prank(user);
        depositManager.withdrawUSDC(platformTokenBalance);

        // Verify platform tokens burned
        assertEq(platformToken.balanceOf(user), 0);

        // Verify USDC returned (may be slightly more due to yield)
        uint256 userUSDCAfter = usdc.balanceOf(user);
        assertGe(userUSDCAfter, userUSDCBefore + depositAmount - 1);
    }

    function test_Fork_DepositWithdrawCycle() public onlyFork {
        uint256 depositAmount = 1000 * 1e6; // $1000 USDC
        uint256 initialBalance = usdc.balanceOf(user);

        // Deposit
        vm.prank(user);
        depositManager.depositUSDC(depositAmount);

        // Verify state after deposit
        assertEq(platformToken.balanceOf(user), depositAmount * 1e12);
        assertGe(depositManager.getTotalAvailableBalance(), depositAmount);

        // Withdraw all
        uint256 platformTokenBalance = platformToken.balanceOf(user);
        vm.prank(user);
        depositManager.withdrawUSDC(platformTokenBalance);

        // Verify final state
        assertEq(platformToken.balanceOf(user), 0);
        assertEq(platformToken.totalSupply(), 0);

        // User should have approximately the same USDC (may be slightly more due to yield)
        uint256 finalBalance = usdc.balanceOf(user);
        assertGe(finalBalance, initialBalance - 1);
    }

    function test_Fork_MultipleDeposits() public onlyFork {
        uint256 deposit1 = 500 * 1e6;
        uint256 deposit2 = 300 * 1e6;
        uint256 deposit3 = 200 * 1e6;

        vm.startPrank(user);
        depositManager.depositUSDC(deposit1);
        depositManager.depositUSDC(deposit2);
        depositManager.depositUSDC(deposit3);
        vm.stopPrank();

        uint256 totalDeposited = deposit1 + deposit2 + deposit3;

        // Verify platform tokens
        assertEq(platformToken.balanceOf(user), totalDeposited * 1e12);

        // Verify Aave balance
        assertGe(depositManager.getTotalAvailableBalance(), totalDeposited);
    }

    function test_Fork_PartialWithdraw() public onlyFork {
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user);
        depositManager.depositUSDC(depositAmount);

        // Withdraw half
        uint256 withdrawAmount = (depositAmount * 1e12) / 2;
        vm.prank(user);
        depositManager.withdrawUSDC(withdrawAmount);

        // Verify remaining balance
        assertEq(platformToken.balanceOf(user), depositAmount * 1e12 - withdrawAmount);
        assertGe(depositManager.getTotalAvailableBalance(), depositAmount / 2);
    }

    // ==================== View Function Tests ====================

    function test_Fork_ViewFunctions() public onlyFork {
        uint256 depositAmount = 100 * 1e6;

        vm.prank(user);
        depositManager.depositUSDC(depositAmount);

        // Test all view functions work correctly
        uint256 tokenManagerBalance = depositManager.getTokenManagerUSDCBalance();
        uint256 aaveBalance = depositManager.getAaveUSDCBalance();
        uint256 totalBalance = depositManager.getTotalAvailableBalance();

        assertEq(totalBalance, tokenManagerBalance + aaveBalance);
        assertGe(aaveBalance, depositAmount - 1);
    }

    function test_Fork_AaveReserveConfig() public onlyFork {
        DataTypes.ReserveConfigurationMap memory config = depositManager.getUSDCReserveConfig();
        assertTrue(config.data != 0, "Config should have data");
    }

    function test_Fork_AaveReserveData() public onlyFork {
        DataTypes.ReserveData memory data = depositManager.getUSDCReserveData();
        assertTrue(data.aTokenAddress != address(0), "aToken address should be set");
    }
}
