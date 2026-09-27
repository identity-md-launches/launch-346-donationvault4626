// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        token = new LaunchToken();
    }

    function test_fixedSupplyAndMetadata() public view {
        assertEq(token.name(), "Piggy");
        assertEq(token.symbol(), "PIGY");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transferHasNoFee(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_approvalAndTransferFrom() public {
        token.approve(alice, 10 ether);
        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), bob, 4 ether));
        assertEq(token.allowance(address(this), alice), 6 ether);
        assertEq(token.balanceOf(bob), 4 ether);
    }

    function test_infiniteAllowanceIsNotSpent() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 10 ether);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
    }

    function test_insufficientAllowanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(address(this), bob, 1);
    }

    function test_insufficientBalanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_zeroRecipientReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_deadAddressTransferDoesNotChangeSupply() public {
        token.transfer(address(0xdead), 5 ether);
        assertEq(token.balanceOf(address(0xdead)), 5 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_noAdminOrMintEntrypointsEvenForDeployer() public {
        string[12] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "burn(uint256)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            bytes memory data = abi.encodeWithSignature(selectors[i], alice, uint256(1 ether));
            (bool success,) = address(token).call(data);
            assertFalse(success);
            vm.prank(alice);
            (success,) = address(token).call(data);
            assertFalse(success);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }
}
