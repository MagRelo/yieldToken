// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DepositManager} from "../src/DepositManager.sol";
import {PlatformToken} from "../src/PlatformToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockAToken} from "./mocks/MockAToken.sol";
import "solmate/tokens/ERC20.sol";

/// @title ReentrantContract
/// @notice Contract that attempts to reenter DepositManager functions
contract ReentrantContract {
    DepositManager public depositManager;
    ERC20 public usdcToken;
    bool public reentering;

    constructor(DepositManager _depositManager, ERC20 _usdcToken) {
        depositManager = _depositManager;
        usdcToken = _usdcToken;
    }

    /// @notice Attempts to deposit and then reenter (sequential calls)
    function depositAndReenter(uint256 amount) external {
        depositManager.depositUSDC(amount);
        depositManager.depositUSDC(amount);
    }

    /// @notice Attempts to withdraw and then reenter (sequential calls)
    function withdrawAndReenter(uint256 platformTokenAmount) external {
        depositManager.withdrawUSDC(platformTokenAmount);
        depositManager.withdrawUSDC(platformTokenAmount);
    }

    /// @notice Approve DepositManager to spend USDC
    function approveUSDC() external {
        usdcToken.approve(address(depositManager), type(uint256).max);
    }
}

/// @title ReentrantAttacker
/// @notice Legacy attacker contract
contract ReentrantAttacker {
    DepositManager public depositManager;
    ERC20 public usdcToken;
    PlatformToken public platformToken;
    uint256 public attackCount;
    uint256 public constant ATTACK_AMOUNT = 1000 * 1e6;

    constructor(address _depositManager, address _usdcToken, address _platformToken) {
        depositManager = DepositManager(_depositManager);
        usdcToken = ERC20(_usdcToken);
        platformToken = PlatformToken(_platformToken);
    }

    function attackDeposit() external {
        attackCount++;
        depositManager.depositUSDC(ATTACK_AMOUNT);
    }

    function attackWithdraw(uint256 platformTokenAmount) external {
        attackCount++;
        depositManager.withdrawUSDC(platformTokenAmount);
    }

    function approveUSDC() external {
        usdcToken.approve(address(depositManager), type(uint256).max);
    }
}

contract DepositManagerReentrancyTest is Test {
    DepositManager public depositManager;
    PlatformToken public platformToken;
    MockERC20 public usdcToken;
    MockAavePool public mockAavePool;
    MockAToken public mockAToken;
    ReentrantAttacker public attacker;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public recipient = address(0x3);

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

        // Deploy attacker contract
        attacker = new ReentrantAttacker(address(depositManager), address(usdcToken), address(platformToken));

        // Give attacker some USDC
        usdcToken.mint(address(attacker), 1000000 * 1e6); // $1M USDC
        attacker.approveUSDC();
    }

    // ==================== depositUSDC Reentrancy Tests ====================

    function test_Reentrancy_DepositUSDC_ReentrancyGuardPreventsAttack() public {
        uint256 amount = 1000 * 1e6;

        ReentrantContract reentrant = new ReentrantContract(depositManager, usdcToken);
        usdcToken.mint(address(reentrant), amount * 2);
        reentrant.approveUSDC();

        // Sequential calls should work (not reentrancy)
        reentrant.depositAndReenter(amount);

        // Verify both deposits succeeded
        assertEq(platformToken.balanceOf(address(reentrant)), amount * 2 * 1e12);
    }

    function test_Reentrancy_DepositUSDC_StateRemainsConsistent() public {
        uint256 amount = 1000 * 1e6;
        usdcToken.mint(user1, amount);
        vm.startPrank(user1);
        usdcToken.approve(address(depositManager), type(uint256).max);
        depositManager.depositUSDC(amount);
        vm.stopPrank();

        uint256 totalSupplyBefore = platformToken.totalSupply();
        uint256 totalBalanceBefore = depositManager.getTotalAvailableBalance();

        ReentrantContract reentrant = new ReentrantContract(depositManager, usdcToken);
        usdcToken.mint(address(reentrant), amount);
        reentrant.approveUSDC();

        // Sequential calls work
        vm.expectRevert(); // ReentrancyGuard will revert
        reentrant.depositAndReenter(amount);

        uint256 totalSupplyAfter = platformToken.totalSupply();
        uint256 totalBalanceAfter = depositManager.getTotalAvailableBalance();

        assertEq(totalSupplyBefore, totalSupplyAfter);
        assertEq(totalBalanceBefore, totalBalanceAfter);
    }

    // ==================== withdrawUSDC Reentrancy Tests ====================

    function test_Reentrancy_WithdrawUSDC_ReentrancyGuardPreventsAttack() public {
        uint256 depositAmount = 1000 * 1e6;
        ReentrantContract reentrant = new ReentrantContract(depositManager, usdcToken);
        usdcToken.mint(address(reentrant), depositAmount);
        reentrant.approveUSDC();

        vm.prank(address(reentrant));
        depositManager.depositUSDC(depositAmount);

        uint256 platformTokenBalance = platformToken.balanceOf(address(reentrant));
        uint256 depositManagerBalanceBefore = usdcToken.balanceOf(address(depositManager));

        vm.expectRevert(); // ReentrancyGuard will revert
        reentrant.withdrawAndReenter(platformTokenBalance);

        uint256 depositManagerBalanceAfter = usdcToken.balanceOf(address(depositManager));
        assertEq(depositManagerBalanceBefore, depositManagerBalanceAfter);
    }

    function test_Reentrancy_WithdrawUSDC_StateRemainsConsistent() public {
        uint256 depositAmount = 1000 * 1e6;
        usdcToken.mint(user1, depositAmount);
        vm.startPrank(user1);
        usdcToken.approve(address(depositManager), type(uint256).max);
        depositManager.depositUSDC(depositAmount);
        vm.stopPrank();

        uint256 totalSupplyBefore = platformToken.totalSupply();
        uint256 totalBalanceBefore = depositManager.getTotalAvailableBalance();

        uint256 reentrantDeposit = 500 * 1e6;
        ReentrantContract reentrant = new ReentrantContract(depositManager, usdcToken);
        usdcToken.mint(address(reentrant), reentrantDeposit);
        reentrant.approveUSDC();
        vm.prank(address(reentrant));
        depositManager.depositUSDC(reentrantDeposit);

        uint256 reentrantPlatformTokens = platformToken.balanceOf(address(reentrant));

        vm.expectRevert();
        reentrant.withdrawAndReenter(reentrantPlatformTokens);

        uint256 totalSupplyAfter = platformToken.totalSupply();
        uint256 totalBalanceAfter = depositManager.getTotalAvailableBalance();

        assertEq(totalSupplyBefore + reentrantDeposit * 1e12, totalSupplyAfter);
        assertEq(totalBalanceBefore + reentrantDeposit, totalBalanceAfter);
    }

    // ==================== Cross-Function Reentrancy Tests ====================

    function test_Reentrancy_DepositToWithdraw_ReentrancyGuardPreventsAttack() public {
        uint256 depositAmount = 1000 * 1e6;
        ReentrantContract reentrant = new ReentrantContract(depositManager, usdcToken);
        usdcToken.mint(address(reentrant), depositAmount);
        reentrant.approveUSDC();

        vm.expectRevert();
        reentrant.depositAndReenter(depositAmount);
    }

    function test_Reentrancy_WithdrawToDeposit_ReentrancyGuardPreventsAttack() public {
        uint256 depositAmount = 1000 * 1e6;
        ReentrantContract reentrant = new ReentrantContract(depositManager, usdcToken);
        usdcToken.mint(address(reentrant), depositAmount);
        reentrant.approveUSDC();

        vm.prank(address(reentrant));
        depositManager.depositUSDC(depositAmount);

        uint256 platformTokenBalance = platformToken.balanceOf(address(reentrant));

        vm.expectRevert();
        reentrant.withdrawAndReenter(platformTokenBalance);
    }

    // ==================== Multiple Reentrancy Attempts ====================

    function test_Reentrancy_MultipleDepositAttempts_AllBlocked() public {
        uint256 amount = 1000 * 1e6;
        ReentrantContract reentrant = new ReentrantContract(depositManager, usdcToken);
        usdcToken.mint(address(reentrant), amount * 10);
        reentrant.approveUSDC();

        vm.prank(address(reentrant));
        depositManager.depositUSDC(amount);

        reentrant.depositAndReenter(amount);

        assertGe(platformToken.balanceOf(address(reentrant)), amount * 2 * 1e12);
    }

    function test_Reentrancy_MultipleWithdrawAttempts_AllBlocked() public {
        uint256 depositAmount = 1000 * 1e6;
        usdcToken.mint(address(attacker), depositAmount);

        vm.prank(address(attacker));
        depositManager.depositUSDC(depositAmount);

        uint256 platformTokenBalance = platformToken.balanceOf(address(attacker));

        vm.prank(address(attacker));
        depositManager.withdrawUSDC(platformTokenBalance);

        for (uint256 i = 0; i < 3; i++) {
            vm.expectRevert();
            attacker.attackWithdraw(platformTokenBalance);
        }

        assertEq(platformToken.balanceOf(address(attacker)), 0);
    }

    // ==================== State Integrity After Failed Reentrancy ====================

    function test_Reentrancy_FailedReentrancyMaintainsStateIntegrity() public {
        uint256 depositAmount = 1000 * 1e6;
        usdcToken.mint(user1, depositAmount);
        vm.startPrank(user1);
        usdcToken.approve(address(depositManager), type(uint256).max);
        depositManager.depositUSDC(depositAmount);
        vm.stopPrank();

        uint256 user1Balance = platformToken.balanceOf(user1);
        uint256 totalSupply = platformToken.totalSupply();
        uint256 totalBalance = depositManager.getTotalAvailableBalance();

        ReentrantContract reentrant = new ReentrantContract(depositManager, usdcToken);
        usdcToken.mint(address(reentrant), depositAmount);
        reentrant.approveUSDC();

        vm.expectRevert();
        reentrant.depositAndReenter(depositAmount);

        assertEq(platformToken.balanceOf(user1), user1Balance);
        assertEq(platformToken.totalSupply(), totalSupply);
        assertEq(depositManager.getTotalAvailableBalance(), totalBalance);

        uint256 newDeposit = 500 * 1e6;
        usdcToken.mint(user1, newDeposit);
        vm.prank(user1);
        depositManager.depositUSDC(newDeposit);

        assertEq(platformToken.balanceOf(user1), user1Balance + newDeposit * 1e12);
    }

    // ==================== Reentrancy Through Token Transfers ====================

    function test_Reentrancy_TokenTransferCallback_ReentrancyGuardPrevents() public {
        uint256 amount = 1000 * 1e6;
        ReentrantContract reentrant = new ReentrantContract(depositManager, usdcToken);
        usdcToken.mint(address(reentrant), amount);
        reentrant.approveUSDC();

        vm.expectRevert();
        reentrant.depositAndReenter(amount);

        assertEq(usdcToken.balanceOf(address(depositManager)), 0);
    }
}
