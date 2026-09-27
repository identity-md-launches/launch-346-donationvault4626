// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DonationVault4626} from "../src/DonationVault4626.sol";

contract VaultHandler is Test {
    LaunchToken public immutable token;
    DonationVault4626 public immutable vault;
    address[4] public actors = [address(0xA), address(0xB), address(0xC), address(0xD)];
    uint256 public totalIn;
    uint256 public totalOut;
    uint256 public modelLocked;
    uint256 public modelStart;

    constructor(LaunchToken token_, DonationVault4626 vault_) {
        token = token_;
        vault = vault_;
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            token.approve(address(vault), type(uint256).max);
        }
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 4];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        uint256 shares = vault.previewDeposit(amount);
        if (shares == 0) {
            vm.expectRevert(DonationVault4626.ZeroShares.selector);
            vm.prank(actor);
            vault.deposit(amount, actor);
        } else {
            vm.prank(actor);
            assertEq(vault.deposit(amount, actor), shares);
            totalIn += amount;
        }
    }

    function mint(uint256 actorSeed, uint256 shares) external {
        address actor = actors[actorSeed % 4];
        uint256 affordableShares = vault.convertToShares(token.balanceOf(actor));
        if (affordableShares == 0) return;
        shares = bound(shares, 1, affordableShares);
        uint256 assets = vault.previewMint(shares);
        vm.prank(actor);
        assertEq(vault.mint(shares, actor), assets);
        totalIn += assets;
    }

    function withdraw(uint256 actorSeed, uint256 assets) external {
        address actor = actors[actorSeed % 4];
        uint256 max = vault.maxWithdraw(actor);
        assets = bound(assets, 0, max);
        uint256 shares = vault.previewWithdraw(assets);
        vm.prank(actor);
        assertEq(vault.withdraw(assets, actor, actor), shares);
        totalOut += assets;
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address actor = actors[actorSeed % 4];
        shares = bound(shares, 0, vault.maxRedeem(actor));
        uint256 assets = vault.previewRedeem(shares);
        vm.prank(actor);
        assertEq(vault.redeem(shares, actor, actor), assets);
        totalOut += assets;
    }

    function donate(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 4];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        modelLocked = modelUnvested() + amount;
        modelStart = vm.getBlockTimestamp();
        vm.prank(actor);
        vault.donate(amount);
        totalIn += amount;
    }

    function directTransfer(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 4];
        amount = bound(amount, 0, token.balanceOf(actor));
        vm.prank(actor);
        token.transfer(address(vault), amount);
        totalIn += amount;
    }

    function transferShares(uint256 actorSeed, uint256 receiverSeed, uint256 shares) external {
        address actor = actors[actorSeed % 4];
        address receiver = actors[receiverSeed % 4];
        shares = bound(shares, 0, vault.balanceOf(actor));
        vm.prank(actor);
        vault.transfer(receiver, shares);
    }

    function advance(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 0, 14 days));
    }

    function modelUnvested() public view returns (uint256) {
        uint256 elapsed = vm.getBlockTimestamp() - modelStart;
        if (elapsed >= 7 days) return 0;
        return modelLocked * (7 days - elapsed) / 7 days;
    }
}

contract VaultInvariantTest is Test {
    LaunchToken internal token;
    DonationVault4626 internal vault;
    VaultHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new LaunchToken();
        vault = new DonationVault4626(address(token));
        handler = new VaultHandler(token, vault);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), 200_000_000 ether);
        }
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.mint.selector;
        selectors[2] = handler.withdraw.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.directTransfer.selector;
        selectors[6] = handler.transferShares.selector;
        selectors[7] = handler.advance.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_assetsAreBackedAndInflowsEqualOutflowsPlusBalance() public view {
        uint256 balance = token.balanceOf(address(vault));
        assertLe(vault.totalAssets(), balance);
        assertEq(vault.totalAssets() + vault.unvested(), balance);
        assertEq(handler.totalIn(), handler.totalOut() + balance);
    }

    function invariant_streamMatchesIndependentClockModel() public view {
        assertEq(vault.unvested(), handler.modelUnvested());
        assertEq(vault.lockedAmount(), handler.modelLocked());
        if (handler.modelStart() == 0) assertEq(vault.lockEnd(), 0);
        else assertEq(vault.lockEnd(), handler.modelStart() + 7 days);
    }

    function invariant_shareAndTokenConservationAndRedemptionSolvency() public view {
        uint256 allShares;
        uint256 allTokens = token.balanceOf(address(this)) + token.balanceOf(address(vault));
        uint256 allRedeemable;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            allShares += vault.balanceOf(actor);
            allTokens += token.balanceOf(actor);
            allRedeemable += vault.maxWithdraw(actor);
            assertEq(vault.maxRedeem(actor), vault.balanceOf(actor));
            assertEq(vault.maxWithdraw(actor), vault.previewRedeem(vault.balanceOf(actor)));
        }
        assertEq(allShares, vault.totalSupply());
        assertEq(allTokens, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertLe(allRedeemable, vault.totalAssets());
    }
}
