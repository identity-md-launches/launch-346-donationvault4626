// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {DonationVault4626} from "../src/DonationVault4626.sol";

contract VaultAdversarialTest is VaultTestBase {
    function testFuzz_streamedInflationAttackCannotProfit(
        uint256 donation,
        uint256 victimDeposit,
        uint256 beforeVictim,
        uint256 beforeExit
    ) public {
        donation = bound(donation, 1, 1_000_000 ether);
        victimDeposit = bound(victimDeposit, 1, 1_000_000 ether);
        beforeVictim = bound(beforeVictim, 0, WEEK);
        beforeExit = bound(beforeExit, 0, WEEK);
        uint256 initialBalance = pigy.balanceOf(attacker);
        uint256 attackerShares = _deposit(attacker, 1);
        vm.prank(attacker);
        vault.donate(donation);
        vm.warp(vm.getBlockTimestamp() + beforeVictim);
        _victimDepositOrRevert(victimDeposit);
        vm.warp(vm.getBlockTimestamp() + beforeExit);
        _redeem(attacker, attackerShares);
        assertLe(pigy.balanceOf(attacker), initialBalance, "streamed inflation attacker profited");
        _assertAccounting();
    }

    function testFuzz_directTransferInflationAttackCannotProfit(uint256 donation, uint256 victimDeposit) public {
        donation = bound(donation, 1, 1_000_000 ether);
        victimDeposit = bound(victimDeposit, 1, 1_000_000 ether);
        uint256 initialBalance = pigy.balanceOf(attacker);
        uint256 attackerShares = _deposit(attacker, 1);
        vm.prank(attacker);
        pigy.transfer(address(vault), donation);
        _victimDepositOrRevert(victimDeposit);
        _redeem(attacker, attackerShares);
        assertLe(pigy.balanceOf(attacker), initialBalance, "direct-transfer attacker profited");
        _assertAccounting();
    }

    function _victimDepositOrRevert(uint256 amount) internal {
        if (vault.previewDeposit(amount) == 0) {
            vm.expectRevert(DonationVault4626.ZeroShares.selector);
            vm.prank(alice);
            vault.deposit(amount, alice);
            assertEq(pigy.balanceOf(alice), FUNDING);
        } else {
            _deposit(alice, amount);
        }
    }

    function testFuzz_sameBlockDepositDonationRedemptionHasNoGain(uint256 depositAmount, uint256 donation) public {
        depositAmount = bound(depositAmount, 1, 1_000_000 ether);
        donation = bound(donation, 1, 1_000_000 ether);
        _deposit(alice, 100 ether);
        uint256 shares = _deposit(attacker, depositAmount);
        uint256 redeemBefore = vault.previewRedeem(shares);
        uint256 priceBefore = vault.sharePrice();
        _donate(donation);
        assertEq(vault.sharePrice(), priceBefore);
        assertEq(vault.previewRedeem(shares), redeemBefore);
        assertLe(_redeem(attacker, shares), depositAmount);
        assertLe(pigy.balanceOf(attacker), FUNDING);
        _assertAccounting();
    }

    function test_sameBlockMintDonationWithdrawalHasNoGain() public {
        _deposit(alice, 10 ether);
        vm.prank(attacker);
        uint256 paid = vault.mint(100 ether * OFFSET, attacker);
        _donate(1000 ether);
        uint256 withdrawable = vault.maxWithdraw(attacker);
        vm.prank(attacker);
        vault.withdraw(withdrawable, attacker, attacker);
        assertLe(withdrawable, paid);
        assertLe(pigy.balanceOf(attacker), FUNDING);
        _assertAccounting();
    }

    function test_directDonationCanBeCapturedByExistingShares() public {
        _deposit(alice, 1 ether);
        uint256 shares = _deposit(attacker, 1 ether);
        pigy.transfer(address(vault), 10 ether);
        // The streaming defense intentionally cannot apply to ERC-20 transfer donations.
        assertGt(_redeem(attacker, shares), 1 ether);
    }

    function test_oneWeiDonationCanExtendAnExistingStream() public {
        _donate(700 ether);
        uint256 originalEnd = vault.lockEnd();
        vm.warp(vm.getBlockTimestamp() + 6 days);
        uint256 vestedBefore = vault.totalAssets();
        vm.prank(attacker);
        vault.donate(1);
        assertEq(vault.lockEnd(), originalEnd + 6 days);
        assertEq(vault.lockedAmount(), 100 ether + 1);
        assertEq(vault.totalAssets(), vestedBefore);
        vm.warp(originalEnd);
        assertGt(vault.unvested(), 0);
    }

    function test_fullExitDuringPartialVestingLeavesAllRemainingFundsBacked() public {
        uint256 aliceShares = _deposit(alice, 19 ether);
        uint256 bobShares = _deposit(bob, 23 ether);
        _donate(7 ether);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        uint256 initialVaultBalance = pigy.balanceOf(address(vault));
        uint256 aliceOut = _redeem(alice, aliceShares);
        uint256 bobOut = _redeem(bob, bobShares);
        assertEq(vault.totalSupply(), 0);
        assertEq(initialVaultBalance, aliceOut + bobOut + pigy.balanceOf(address(vault)));
        assertEq(vault.unvested(), 5 ether);
        _assertAccounting();
        vm.warp(vault.lockEnd());
        assertEq(vault.totalAssets(), initialVaultBalance - aliceOut - bobOut);
    }
}
