// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DonationVault4626} from "../src/DonationVault4626.sol";

abstract contract VaultTestBase is Test {
    LaunchToken internal pigy;
    DonationVault4626 internal vault;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal donor = address(0xD0);
    address internal attacker = address(0xBAD);
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant OFFSET = 1e6;
    uint256 internal constant FUNDING = 100_000_000 ether;

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        pigy = new LaunchToken();
        vault = new DonationVault4626(address(pigy));
        _fund(alice);
        _fund(bob);
        _fund(donor);
        _fund(attacker);
    }

    function _fund(address account) internal {
        pigy.transfer(account, FUNDING);
        vm.prank(account);
        pigy.approve(address(vault), type(uint256).max);
    }

    function _deposit(address account, uint256 assets) internal returns (uint256 shares) {
        vm.prank(account);
        return vault.deposit(assets, account);
    }

    function _donate(uint256 amount) internal {
        vm.prank(donor);
        vault.donate(amount);
    }

    function _redeem(address account, uint256 shares) internal returns (uint256 assets) {
        vm.prank(account);
        return vault.redeem(shares, account, account);
    }

    function _assertAccounting() internal view {
        assertLe(vault.totalAssets(), pigy.balanceOf(address(vault)));
        assertEq(vault.totalAssets() + vault.unvested(), pigy.balanceOf(address(vault)));
    }
}
