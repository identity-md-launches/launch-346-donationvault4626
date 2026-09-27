// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {DonationVault4626} from "../src/DonationVault4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract VaultAdversarialTest is VaultTestBase {
    function testFuzz_repeatedVictimInflationCannotRepayAttacker(
        uint256 donation,
        uint256 victimSeed,
        uint256 count,
        uint256 elapsed,
        bool direct,
        bool victimsExitFirst
    ) public {
        donation = bound(donation, 1, 1_000_000 ether);
        count = bound(count, 1, 16);
        elapsed = bound(elapsed, 0, 2 * WEEK);
        uint256 initialBalance = pigy.balanceOf(attacker);
        uint256 attackerShares = _deposit(attacker, 1);
        vm.prank(attacker);
        if (direct) pigy.transfer(address(vault), donation);
        else vault.donate(donation);
        vm.warp(vm.getBlockTimestamp() + elapsed);

        for (uint256 i; i < count; ++i) {
            // Exercise both sides of the zero-share threshold, plus large deposits.
            uint256 threshold = Math.ceilDiv(vault.totalAssets() + 1, vault.totalSupply() + OFFSET);
            uint256 assets;
            uint256 mode = (victimSeed % 3 + i) % 3;
            if (mode == 0) assets = threshold;
            else if (mode == 1) assets = threshold > 1 ? threshold - 1 : 1;
            else assets = bound(victimSeed, 1, 1_000_000 ether);
            uint256 preview = vault.previewDeposit(assets);
            uint256 balanceBefore = pigy.balanceOf(alice);
            uint256 sharesBefore = vault.balanceOf(alice);
            if (preview == 0) {
                vm.expectRevert(DonationVault4626.ZeroShares.selector);
                vm.prank(alice);
                vault.deposit(assets, alice);
                assertEq(pigy.balanceOf(alice), balanceBefore);
                assertEq(vault.balanceOf(alice), sharesBefore);
            } else {
                assertEq(_deposit(alice, assets), preview);
                assertEq(pigy.balanceOf(alice), balanceBefore - assets);
                assertEq(vault.balanceOf(alice), sharesBefore + preview);
            }
        }
        vm.warp(vm.getBlockTimestamp() + elapsed);
        if (victimsExitFirst) _redeem(alice, vault.balanceOf(alice));
        uint256 expectedExit = vault.previewRedeem(attackerShares);
        assertEq(_redeem(attacker, attackerShares), expectedExit);
        assertLe(pigy.balanceOf(attacker), initialBalance, "repeated victims made inflation profitable");
        if (!victimsExitFirst) _redeem(alice, vault.balanceOf(alice));
        assertEq(vault.totalSupply(), 0);
        _assertAccounting();
    }

    function testFuzz_sandwichAcrossAllEntryAndExitModes(
        uint256 seedDeposit,
        uint256 attackerAmount,
        uint256 donation,
        uint256 elapsed,
        bool mintEntry,
        bool withdrawExit
    ) public {
        seedDeposit = bound(seedDeposit, 1, 1_000_000 ether);
        attackerAmount = bound(attackerAmount, 1, 1_000_000 ether);
        donation = bound(donation, 1, 1_000_000 ether);
        elapsed = bound(elapsed, 0, WEEK);
        _deposit(alice, seedDeposit);
        _donate(donation);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        uint256 initialBalance = pigy.balanceOf(attacker);
        uint256 shares;
        if (mintEntry) {
            shares = vault.convertToShares(attackerAmount);
            if (shares == 0) shares = 1;
            uint256 assets = vault.previewMint(shares);
            vm.prank(attacker);
            assertEq(vault.mint(shares, attacker), assets);
        } else {
            shares = vault.previewDeposit(attackerAmount);
            if (shares == 0) {
                vm.expectRevert(DonationVault4626.ZeroShares.selector);
                vm.prank(attacker);
                vault.deposit(attackerAmount, attacker);
                assertEq(pigy.balanceOf(attacker), initialBalance);
                return;
            }
            assertEq(_deposit(attacker, attackerAmount), shares);
        }
        uint256 spent = initialBalance - pigy.balanceOf(attacker);
        uint256 quoteBefore = vault.previewRedeem(shares);
        uint256 assetsBefore = vault.totalAssets();
        _donate(donation); // Merge an existing stream between entry and exit, without advancing time.
        assertEq(vault.totalAssets(), assetsBefore);
        assertEq(vault.previewRedeem(shares), quoteBefore);
        if (withdrawExit) {
            uint256 assets = vault.maxWithdraw(attacker);
            uint256 expectedBurn = vault.previewWithdraw(assets);
            vm.prank(attacker);
            assertEq(vault.withdraw(assets, attacker, attacker), expectedBurn);
            assertEq(vault.balanceOf(attacker), shares - expectedBurn);
        }
        uint256 remainingShares = vault.balanceOf(attacker);
        uint256 expectedAssets = vault.previewRedeem(remainingShares);
        assertEq(_redeem(attacker, remainingShares), expectedAssets);
        assertLe(pigy.balanceOf(attacker), initialBalance, "same-block sandwich earned unvested yield");
        assertLe(quoteBefore, spent);
        assertEq(vault.balanceOf(attacker), 0);
        _assertAccounting();
    }

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
