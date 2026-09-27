// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {DonationVault4626} from "../src/DonationVault4626.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";

contract WrongDecimals is ERC20 {
    constructor() ERC20("Wrong", "WRONG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract DonationVaultTest is VaultTestBase {
    function test_constructorNeedsNoFundingAndSetsMetadata() public view {
        assertEq(address(vault.token()), address(pigy));
        assertEq(vault.asset(), address(pigy));
        assertEq(vault.name(), "Piggy Vault");
        assertEq(vault.symbol(), "vPIGY");
        assertEq(vault.decimals(), 24);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.unvested(), 0);
        assertEq(vault.lockEnd(), 0);
        assertEq(vault.sharePrice(), 1 ether);
        assertEq(vault.convertToShares(1), OFFSET);
    }

    function test_invalidConstructorAssetsRevert() public {
        vm.expectRevert(DonationVault4626.InvalidAsset.selector);
        new DonationVault4626(address(0));
        vm.expectRevert(DonationVault4626.InvalidAsset.selector);
        new DonationVault4626(alice);
        WrongDecimals wrong = new WrongDecimals();
        vm.expectRevert(DonationVault4626.InvalidAsset.selector);
        new DonationVault4626(address(wrong));
    }

    function test_depositAndFullRedemption() public {
        uint256 shares = _deposit(alice, 10 ether);
        assertEq(shares, 10 ether * OFFSET);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalAssets(), 10 ether);
        assertEq(_redeem(alice, shares), 10 ether);
        assertEq(pigy.balanceOf(alice), FUNDING);
        assertEq(vault.totalSupply(), 0);
        assertEq(pigy.balanceOf(address(vault)), 0);
    }

    function test_depositAndMintMayGiveSharesToAnotherWallet() public {
        vm.prank(alice);
        vault.deposit(2 ether, bob);
        vm.prank(alice);
        assertEq(vault.mint(3 ether * OFFSET, bob), 3 ether);
        assertEq(vault.balanceOf(bob), 5 ether * OFFSET);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(pigy.balanceOf(alice), FUNDING - 5 ether);
    }

    function test_linearStreamAtStartMiddleAndEnd() public {
        _deposit(alice, 100 ether);
        uint256 start = vm.getBlockTimestamp();
        _donate(700 ether);
        assertEq(vault.lockedAmount(), 700 ether);
        assertEq(vault.lockEnd(), start + WEEK);
        assertEq(vault.unvested(), 700 ether);
        assertEq(vault.totalAssets(), 100 ether);
        vm.warp(start + WEEK / 2);
        assertEq(vault.unvested(), 350 ether);
        assertEq(vault.totalAssets(), 450 ether);
        vm.warp(start + WEEK - 1);
        assertEq(vault.unvested(), 700 ether / WEEK);
        _assertAccounting();
        vm.warp(start + WEEK);
        assertEq(vault.unvested(), 0);
        assertEq(vault.totalAssets(), 800 ether);
        vm.warp(start + WEEK + 1);
        assertEq(vault.unvested(), 0);
        _assertAccounting();
    }

    function test_overlappingDonationsMergeOnlyUnvestedAndRestartClock() public {
        uint256 start = vm.getBlockTimestamp();
        _donate(700 ether);
        vm.warp(start + 3 days);
        assertEq(vault.unvested(), 400 ether);
        assertEq(vault.totalAssets(), 300 ether);
        _donate(300 ether);
        assertEq(vault.lockedAmount(), 700 ether);
        assertEq(vault.unvested(), 700 ether);
        assertEq(vault.lockEnd(), start + 10 days);
        assertEq(vault.totalAssets(), 300 ether);
        vm.warp(start + 3 days + WEEK / 2);
        assertEq(vault.unvested(), 350 ether);
        assertEq(vault.totalAssets(), 650 ether);
        vm.warp(start + 10 days);
        assertEq(vault.unvested(), 0);
        assertEq(vault.totalAssets(), 1000 ether);
    }

    function test_tinyDonationRoundingAndMerge() public {
        _donate(7);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(vault.unvested(), 6);
        assertEq(vault.totalAssets(), 1);
        _donate(1);
        assertEq(vault.lockedAmount(), 7);
        assertEq(vault.totalAssets(), 1);
        vm.warp(vault.lockEnd());
        assertEq(vault.totalAssets(), 8);
    }

    function test_donationAtOldLockEndStartsFreshStream() public {
        _donate(100 ether);
        vm.warp(vault.lockEnd());
        _donate(5 ether);
        assertEq(vault.lockedAmount(), 5 ether);
        assertEq(vault.totalAssets(), 100 ether);
        assertEq(vault.lockEnd(), vm.getBlockTimestamp() + WEEK);
    }

    function test_donationWithoutShareholdersAndSubsequentDepositor() public {
        uint256 shares = _deposit(alice, 10 ether);
        _donate(70 ether);
        _redeem(alice, shares);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.unvested(), 70 ether);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertEq(vault.totalAssets(), 30 ether);
        uint256 bobShares = _deposit(bob, 10 ether);
        uint256 initialValue = vault.previewRedeem(bobShares);
        vm.warp(vault.lockEnd());
        uint256 received = _redeem(bob, bobShares);
        assertGt(received, initialValue);
        assertEq(vault.totalSupply(), 0);
        // Virtual shares retain part of pre-existing assets when supply was empty.
        assertGt(vault.totalAssets(), 0);
        _assertAccounting();
    }

    function test_directTransferIsImmediatelyCountedWithoutChangingStream() public {
        _deposit(alice, 10 ether);
        _donate(70 ether);
        uint256 end = vault.lockEnd();
        uint256 beforePrice = vault.sharePrice();
        pigy.transfer(address(vault), 20 ether);
        assertEq(vault.totalAssets(), 30 ether);
        assertEq(vault.unvested(), 70 ether);
        assertEq(vault.lockEnd(), end);
        assertGt(vault.sharePrice(), beforePrice);
        assertEq(vault.sharePrice(), vault.convertToAssets(1e24));
        _assertAccounting();
    }

    function test_maxViewsAndLockedAssetsCannotBeWithdrawn() public {
        uint256 shares = _deposit(alice, 10 ether);
        _donate(70 ether);
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxMint(alice), type(uint256).max);
        assertEq(vault.maxWithdraw(alice), 10 ether);
        assertEq(vault.maxRedeem(alice), shares);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, alice, 10 ether + 1, 10 ether)
        );
        vm.prank(alice);
        vault.withdraw(10 ether + 1, alice, alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, alice, shares + 1, shares));
        vm.prank(alice);
        vault.redeem(shares + 1, alice, alice);
        assertEq(_redeem(alice, shares), 10 ether);
        assertEq(pigy.balanceOf(address(vault)), vault.unvested());
    }

    function testFuzz_previewsMatchAllFourResults(uint256 assets, uint256 donation, uint256 elapsed) public {
        assets = bound(assets, 1, 1_000_000 ether);
        donation = bound(donation, 1, 1_000_000 ether);
        elapsed = bound(elapsed, 0, WEEK + 1);
        _deposit(alice, 100 ether);
        _donate(donation);
        vm.warp(vm.getBlockTimestamp() + elapsed);

        uint256 expectedShares = vault.previewDeposit(assets);
        uint256 receivedShares = _deposit(bob, assets);
        assertEq(receivedShares, expectedShares);
        assertLe(vault.convertToAssets(receivedShares), assets);

        uint256 mintShares = assets * OFFSET;
        uint256 expectedAssets = vault.previewMint(mintShares);
        // The chosen price can make a full assets*OFFSET mint exceed Bob's funds.
        if (expectedAssets > pigy.balanceOf(bob)) {
            mintShares = vault.convertToShares(pigy.balanceOf(bob) / 2);
            expectedAssets = vault.previewMint(mintShares);
        }
        vm.prank(bob);
        assertEq(vault.mint(mintShares, bob), expectedAssets);
        assertGe(expectedAssets, vault.convertToAssets(mintShares));

        uint256 withdrawAssets = vault.maxWithdraw(bob) / 2;
        expectedShares = vault.previewWithdraw(withdrawAssets);
        vm.prank(bob);
        assertEq(vault.withdraw(withdrawAssets, bob, bob), expectedShares);

        uint256 redeemShares = vault.balanceOf(bob);
        expectedAssets = vault.previewRedeem(redeemShares);
        assertEq(_redeem(bob, redeemShares), expectedAssets);
        _assertAccounting();
    }

    function test_roundingDirectionsAgainstIndependentFormula() public {
        _deposit(alice, 11);
        pigy.transfer(address(vault), 7);
        _donate(13);
        vm.warp(vm.getBlockTimestamp() + 12345);
        uint256 numerator = vault.totalSupply() + OFFSET;
        uint256 denominator = vault.totalAssets() + 1;
        assertEq(vault.previewDeposit(5), 5 * numerator / denominator);
        assertEq(vault.previewWithdraw(5), Math.ceilDiv(5 * numerator, denominator));
        assertEq(vault.previewMint(999999), Math.ceilDiv(999999 * denominator, numerator));
        assertEq(vault.previewRedeem(999999), 999999 * denominator / numerator);
        assertEq(vault.maxWithdraw(alice), vault.balanceOf(alice) * denominator / numerator);
        assertEq(vault.maxRedeem(alice), vault.balanceOf(alice));
    }

    function test_depositWithZeroSharesRevertsBeforePayment() public {
        pigy.transfer(address(vault), 1 ether);
        assertEq(vault.previewDeposit(1), 0);
        vm.expectRevert(DonationVault4626.ZeroShares.selector);
        vm.prank(alice);
        vault.deposit(1, alice);
        assertEq(pigy.balanceOf(alice), FUNDING);
        assertEq(vault.totalSupply(), 0);
    }

    function test_zeroDepositMintAndDonationRevert() public {
        vm.expectRevert(DonationVault4626.ZeroShares.selector);
        vault.deposit(0, alice);
        vm.expectRevert(DonationVault4626.ZeroShares.selector);
        vault.mint(0, alice);
        _donate(10 ether);
        uint256 end = vault.lockEnd();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(DonationVault4626.ZeroDonation.selector);
        vault.donate(0);
        assertEq(vault.lockEnd(), end);
    }

    function test_paymentsRequireAssetApprovalAndBalance() public {
        vm.prank(bob);
        pigy.approve(address(vault), 0);
        bytes memory noAllowance =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 1 ether);
        vm.expectRevert(noAllowance);
        vm.prank(bob);
        vault.deposit(1 ether, bob);
        vm.expectRevert(noAllowance);
        vm.prank(bob);
        vault.mint(1 ether * OFFSET, bob);
        vm.expectRevert(noAllowance);
        vm.prank(bob);
        vault.donate(1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, FUNDING, FUNDING + 1)
        );
        vm.prank(alice);
        vault.donate(FUNDING + 1);
        assertEq(vault.lockEnd(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function test_depositToZeroRevertsAndRollsBackPayment() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        vault.deposit(1 ether, address(0));
        assertEq(pigy.balanceOf(alice), FUNDING);
        assertEq(pigy.balanceOf(address(vault)), 0);
    }

    function test_delegatedWithdrawAndRedeemSpendShareApproval() public {
        _deposit(alice, 10 ether);
        vm.prank(alice);
        vault.approve(bob, 4 ether * OFFSET);
        vm.prank(bob);
        assertEq(vault.withdraw(1 ether, bob, alice), 1 ether * OFFSET);
        vm.prank(bob);
        assertEq(vault.redeem(3 ether * OFFSET, bob, alice), 3 ether);
        assertEq(vault.allowance(alice, bob), 0);
        assertEq(pigy.balanceOf(bob), FUNDING + 4 ether);
        assertEq(vault.balanceOf(alice), 6 ether * OFFSET);
    }

    function test_unapprovedCallerCannotWithdrawOrRedeemOthersShares() public {
        _deposit(alice, 10 ether);
        bytes memory noAllowance =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, OFFSET);
        vm.expectRevert(noAllowance);
        vm.prank(bob);
        vault.withdraw(1, bob, alice);
        vm.expectRevert(noAllowance);
        vm.prank(bob);
        vault.redeem(OFFSET, bob, alice);
        assertEq(vault.totalAssets(), 10 ether);
    }

    function test_payoutReceiverMustBeCaller() public {
        _deposit(alice, 10 ether);
        vm.expectRevert(DonationVault4626.ReceiverMustBeCaller.selector);
        vm.prank(alice);
        vault.withdraw(1 ether, bob, alice);
        vm.expectRevert(DonationVault4626.ReceiverMustBeCaller.selector);
        vm.prank(alice);
        vault.redeem(1 ether * OFFSET, bob, alice);
        assertEq(vault.totalAssets(), 10 ether);
    }

    function test_sharesAreTransferableAndNewHolderCanRedeem() public {
        uint256 shares = _deposit(alice, 10 ether);
        vm.prank(alice);
        vault.transfer(bob, shares);
        assertEq(_redeem(bob, shares), 10 ether);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_eachOperationEmitsOneFinalSnapshotAndDonationDetails() public {
        vm.recordLogs();
        _deposit(alice, 10 ether);
        _assertSnapshot(vm.getRecordedLogs());
        vm.recordLogs();
        vm.prank(alice);
        vault.mint(1 ether * OFFSET, alice);
        _assertSnapshot(vm.getRecordedLogs());
        vm.recordLogs();
        _donate(70 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertSnapshot(logs);
        uint256 donationEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == keccak256("Donated(address,uint256,uint256)"))
            {
                ++donationEvents;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(donor))));
                (uint256 amount, uint256 end) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(amount, 70 ether);
                assertEq(end, vault.lockEnd());
            }
        }
        assertEq(donationEvents, 1);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.recordLogs();
        vm.prank(alice);
        vault.withdraw(1 ether, alice, alice);
        _assertSnapshot(vm.getRecordedLogs());
        vm.recordLogs();
        _redeem(alice, vault.balanceOf(alice));
        _assertSnapshot(vm.getRecordedLogs());
    }

    function _assertSnapshot(Vm.Log[] memory logs) internal view {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == keccak256("Snapshot(uint256,uint256)")) {
                ++count;
                (uint256 assets, uint256 shares) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(assets, vault.totalAssets());
                assertEq(shares, vault.totalSupply());
                assertEq(i, logs.length - 1);
            }
        }
        assertEq(count, 1);
    }

    function test_ethAndUnknownSelectorsAreRejected() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(vault).call{value: 1}("");
        assertFalse(success);
        (success,) = address(vault).call{value: 1}(abi.encodeCall(vault.donate, (1)));
        assertFalse(success);
        (success,) = address(vault).call(abi.encodeWithSignature("pause()"));
        assertFalse(success);
        assertEq(address(vault).balance, 0);
    }
}
