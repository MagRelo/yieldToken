// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PlatformToken} from "../src/PlatformToken.sol";

contract PlatformTokenTest is Test {
    PlatformToken public token;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public nonOwner = address(0x4);
    address public depositManagerAddress;

    string public constant TOKEN_NAME = "Cut Platform Token";
    string public constant TOKEN_SYMBOL = "CUT";
    uint8 public constant TOKEN_DECIMALS = 18;

    event DepositManagerSet(address indexed depositManager);
    event DepositManagerMint(address indexed to, uint256 amount);
    event DepositManagerBurn(address indexed from, uint256 amount);

    function setUp() public {
        vm.startPrank(owner);
        token = new PlatformToken(TOKEN_NAME, TOKEN_SYMBOL);
        vm.stopPrank();
    }

    // ==================== Constructor Tests ====================

    function test_Constructor_SetsNameSymbolDecimals() public {
        assertEq(token.name(), TOKEN_NAME);
        assertEq(token.symbol(), TOKEN_SYMBOL);
        assertEq(token.decimals(), TOKEN_DECIMALS);
    }

    function test_Constructor_SetsOwner() public {
        assertEq(token.owner(), owner);
    }

    function test_Constructor_InitialTotalSupplyIsZero() public {
        assertEq(token.totalSupply(), 0);
    }

    // ==================== setDepositManager Tests ====================

    function test_SetDepositManager_OwnerCanSet() public {
        address newDepositManager = address(0x100);

        vm.expectEmit(true, false, false, true);
        emit DepositManagerSet(newDepositManager);

        vm.prank(owner);
        token.setDepositManager(newDepositManager);

        assertEq(token.depositManager(), newDepositManager);
    }

    function test_SetDepositManager_NonOwnerCannotSet() public {
        address newDepositManager = address(0x100);

        vm.prank(nonOwner);
        vm.expectRevert();
        token.setDepositManager(newDepositManager);

        assertEq(token.depositManager(), address(0));
    }

    function test_SetDepositManager_EmitsEvent() public {
        address newDepositManager = address(0x100);

        vm.expectEmit(true, false, false, true);
        emit DepositManagerSet(newDepositManager);

        vm.prank(owner);
        token.setDepositManager(newDepositManager);
    }

    function test_SetDepositManager_RevertsWithInvalidDepositManagerAddress() public {
        vm.prank(owner);
        vm.expectRevert(PlatformToken.InvalidDepositManagerAddress.selector);
        token.setDepositManager(address(0));
    }

    function test_SetDepositManager_CanSetMultipleTimes() public {
        address firstManager = address(0x100);
        address secondManager = address(0x200);

        vm.startPrank(owner);
        token.setDepositManager(firstManager);
        assertEq(token.depositManager(), firstManager);

        token.setDepositManager(secondManager);
        assertEq(token.depositManager(), secondManager);
        vm.stopPrank();
    }

    // ==================== mint Tests ====================

    function test_Mint_OnlyDepositManagerCanCall() public {
        _setupDepositManager();
        uint256 amount = 1000e18;

        vm.prank(depositManagerAddress);
        token.mint(user1, amount);

        assertEq(token.balanceOf(user1), amount);
        assertEq(token.totalSupply(), amount);
    }

    function test_Mint_NonDepositManagerReverts() public {
        _setupDepositManager();
        uint256 amount = 1000e18;

        vm.prank(nonOwner);
        vm.expectRevert(PlatformToken.OnlyDepositManager.selector);
        token.mint(user1, amount);
    }

    function test_Mint_RevertsWithDepositManagerNotSet() public {
        uint256 amount = 1000e18;

        vm.prank(address(0x100));
        vm.expectRevert(PlatformToken.DepositManagerNotSet.selector);
        token.mint(user1, amount);
    }

    function test_Mint_RevertsWithCannotMintToZeroAddress() public {
        _setupDepositManager();
        uint256 amount = 1000e18;

        vm.prank(depositManagerAddress);
        vm.expectRevert(PlatformToken.CannotMintToZeroAddress.selector);
        token.mint(address(0), amount);
    }

    function test_Mint_RevertsWithInvalidAmount() public {
        _setupDepositManager();

        vm.prank(depositManagerAddress);
        vm.expectRevert(PlatformToken.InvalidAmount.selector);
        token.mint(user1, 0);
    }

    function test_Mint_MintsTokensCorrectly() public {
        _setupDepositManager();
        uint256 amount = 1000e18;

        vm.prank(depositManagerAddress);
        token.mint(user1, amount);

        assertEq(token.balanceOf(user1), amount);
        assertEq(token.totalSupply(), amount);
    }

    function test_Mint_EmitsDepositManagerMintEvent() public {
        _setupDepositManager();
        uint256 amount = 1000e18;

        vm.expectEmit(true, false, false, true);
        emit DepositManagerMint(user1, amount);

        vm.prank(depositManagerAddress);
        token.mint(user1, amount);
    }

    function test_Mint_MultipleMintsAccumulate() public {
        _setupDepositManager();
        uint256 amount1 = 1000e18;
        uint256 amount2 = 500e18;

        vm.startPrank(depositManagerAddress);
        token.mint(user1, amount1);
        token.mint(user1, amount2);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), amount1 + amount2);
        assertEq(token.totalSupply(), amount1 + amount2);
    }

    function test_Mint_MultipleUsers() public {
        _setupDepositManager();
        uint256 amount1 = 1000e18;
        uint256 amount2 = 500e18;

        vm.startPrank(depositManagerAddress);
        token.mint(user1, amount1);
        token.mint(user2, amount2);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), amount1);
        assertEq(token.balanceOf(user2), amount2);
        assertEq(token.totalSupply(), amount1 + amount2);
    }

    function test_Mint_MaxUint256() public {
        _setupDepositManager();
        uint256 maxAmount = type(uint256).max;

        vm.prank(depositManagerAddress);
        token.mint(user1, maxAmount);

        assertEq(token.balanceOf(user1), maxAmount);
        assertEq(token.totalSupply(), maxAmount);
    }

    // ==================== burn Tests ====================

    function test_Burn_OnlyDepositManagerCanCall() public {
        _setupDepositManager();
        uint256 mintAmount = 1000e18;
        uint256 burnAmount = 300e18;

        vm.startPrank(depositManagerAddress);
        token.mint(user1, mintAmount);
        token.burn(user1, burnAmount);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function test_Burn_NonDepositManagerReverts() public {
        _setupDepositManager();
        uint256 mintAmount = 1000e18;
        uint256 burnAmount = 300e18;

        vm.startPrank(depositManagerAddress);
        token.mint(user1, mintAmount);
        vm.stopPrank();

        vm.prank(nonOwner);
        vm.expectRevert(PlatformToken.OnlyDepositManager.selector);
        token.burn(user1, burnAmount);
    }

    function test_Burn_RevertsWithDepositManagerNotSet() public {
        uint256 amount = 1000e18;

        vm.prank(address(0x100));
        vm.expectRevert(PlatformToken.DepositManagerNotSet.selector);
        token.burn(user1, amount);
    }

    function test_Burn_RevertsWithCannotBurnFromZeroAddress() public {
        _setupDepositManager();
        uint256 amount = 1000e18;

        vm.prank(depositManagerAddress);
        vm.expectRevert(PlatformToken.CannotBurnFromZeroAddress.selector);
        token.burn(address(0), amount);
    }

    function test_Burn_RevertsWithInvalidAmount() public {
        _setupDepositManager();
        uint256 mintAmount = 1000e18;

        vm.startPrank(depositManagerAddress);
        token.mint(user1, mintAmount);

        vm.expectRevert(PlatformToken.InvalidAmount.selector);
        token.burn(user1, 0);
        vm.stopPrank();
    }

    function test_Burn_RevertsWithInsufficientBalance() public {
        _setupDepositManager();
        uint256 mintAmount = 1000e18;
        uint256 burnAmount = 1500e18;

        vm.startPrank(depositManagerAddress);
        token.mint(user1, mintAmount);

        vm.expectRevert(PlatformToken.InsufficientBalance.selector);
        token.burn(user1, burnAmount);
        vm.stopPrank();
    }

    function test_Burn_BurnsTokensCorrectly() public {
        _setupDepositManager();
        uint256 mintAmount = 1000e18;
        uint256 burnAmount = 300e18;

        vm.startPrank(depositManagerAddress);
        token.mint(user1, mintAmount);
        token.burn(user1, burnAmount);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function test_Burn_EmitsDepositManagerBurnEvent() public {
        _setupDepositManager();
        uint256 mintAmount = 1000e18;
        uint256 burnAmount = 300e18;

        vm.startPrank(depositManagerAddress);
        token.mint(user1, mintAmount);
        vm.stopPrank();

        vm.expectEmit(true, false, false, true);
        emit DepositManagerBurn(user1, burnAmount);

        vm.prank(depositManagerAddress);
        token.burn(user1, burnAmount);
    }

    function test_Burn_CannotBurnMoreThanBalance() public {
        _setupDepositManager();
        uint256 mintAmount = 1000e18;
        uint256 burnAmount = 1000e18 + 1;

        vm.startPrank(depositManagerAddress);
        token.mint(user1, mintAmount);

        vm.expectRevert(PlatformToken.InsufficientBalance.selector);
        token.burn(user1, burnAmount);
        vm.stopPrank();
    }

    function test_Burn_FullBalance() public {
        _setupDepositManager();
        uint256 mintAmount = 1000e18;

        vm.startPrank(depositManagerAddress);
        token.mint(user1, mintAmount);
        token.burn(user1, mintAmount);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_Burn_MultipleBurns() public {
        _setupDepositManager();
        uint256 mintAmount = 1000e18;
        uint256 burnAmount1 = 300e18;
        uint256 burnAmount2 = 200e18;

        vm.startPrank(depositManagerAddress);
        token.mint(user1, mintAmount);
        token.burn(user1, burnAmount1);
        token.burn(user1, burnAmount2);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), mintAmount - burnAmount1 - burnAmount2);
        assertEq(token.totalSupply(), mintAmount - burnAmount1 - burnAmount2);
    }

    function test_Burn_MultipleUsers() public {
        _setupDepositManager();
        uint256 mintAmount1 = 1000e18;
        uint256 mintAmount2 = 500e18;
        uint256 burnAmount1 = 300e18;
        uint256 burnAmount2 = 200e18;

        vm.startPrank(depositManagerAddress);
        token.mint(user1, mintAmount1);
        token.mint(user2, mintAmount2);
        token.burn(user1, burnAmount1);
        token.burn(user2, burnAmount2);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), mintAmount1 - burnAmount1);
        assertEq(token.balanceOf(user2), mintAmount2 - burnAmount2);
        assertEq(token.totalSupply(), (mintAmount1 - burnAmount1) + (mintAmount2 - burnAmount2));
    }

    // ==================== Edge Cases ====================

    function test_MintThenBurnSameAmount_NetZero() public {
        _setupDepositManager();
        uint256 amount = 1000e18;

        vm.startPrank(depositManagerAddress);
        token.mint(user1, amount);
        token.burn(user1, amount);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_MultipleUsersMintBurnOperations() public {
        _setupDepositManager();
        uint256 amount1 = 1000e18;
        uint256 amount2 = 500e18;
        uint256 burn1 = 300e18;
        uint256 burn2 = 200e18;

        vm.startPrank(depositManagerAddress);
        token.mint(user1, amount1);
        token.mint(user2, amount2);
        token.burn(user1, burn1);
        token.burn(user2, burn2);
        token.mint(user1, amount2);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), amount1 - burn1 + amount2);
        assertEq(token.balanceOf(user2), amount2 - burn2);
        assertEq(token.totalSupply(), (amount1 - burn1 + amount2) + (amount2 - burn2));
    }

    function test_SettingDepositManagerMultipleTimes() public {
        address manager1 = address(0x100);
        address manager2 = address(0x200);
        address manager3 = address(0x300);

        vm.startPrank(owner);
        token.setDepositManager(manager1);
        assertEq(token.depositManager(), manager1);

        token.setDepositManager(manager2);
        assertEq(token.depositManager(), manager2);

        token.setDepositManager(manager3);
        assertEq(token.depositManager(), manager3);
        vm.stopPrank();
    }

    // ==================== Helper Functions ====================

    function _setupDepositManager() internal {
        // Set a mock deposit manager address for testing
        // In integration tests, we'll use the actual DepositManager contract
        depositManagerAddress = address(0xDEAD);
        vm.prank(owner);
        token.setDepositManager(depositManagerAddress);
    }
}
