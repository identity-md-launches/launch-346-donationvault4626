// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DonationVault4626} from "../src/DonationVault4626.sol";

/// @dev Test-only hostile token: production is always the immutable plain LaunchToken.
contract CallbackAsset is ERC20 {
    address public target;
    bytes public payload;
    bool public callbackSucceeded;
    bytes public callbackResult;
    uint256 public calls;
    uint256 public observedShares;
    uint256 public observedSupply;
    uint8 public incomingMode;
    uint8 public outgoingMode;

    error TransferRejected();

    constructor() ERC20("Mock", "MOCK") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function configure(address vault, bytes calldata data, uint8 incoming, uint8 outgoing) external {
        target = vault;
        payload = data;
        incomingMode = incoming;
        outgoingMode = outgoing;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (incomingMode == 1) return false;
        if (incomingMode == 2) revert TransferRejected();
        _callback(from);
        return super.transferFrom(from, to, value);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (outgoingMode == 1) return false;
        if (outgoingMode == 2) revert TransferRejected();
        _callback(to);
        return super.transfer(to, value);
    }

    function _callback(address account) private {
        if (target == address(0) || payload.length == 0) return;
        ++calls;
        observedShares = DonationVault4626(target).balanceOf(account);
        observedSupply = DonationVault4626(target).totalSupply();
        (callbackSucceeded, callbackResult) = target.call(payload);
    }
}

contract VaultTransferSafetyTest is Test {
    CallbackAsset internal token;
    DonationVault4626 internal vault;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new CallbackAsset();
        vault = new DonationVault4626(address(token));
        token.approve(address(vault), type(uint256).max);
        vault.deposit(100 ether, address(this));
    }

    function test_everyEntrypointBlocksReentryIntoEveryOtherEntrypoint() public {
        bytes[5] memory calls = [
            abi.encodeCall(vault.deposit, (1 ether, address(token))),
            abi.encodeCall(vault.mint, (1 ether * 1e6, address(token))),
            abi.encodeCall(vault.withdraw, (1 ether, address(token), address(this))),
            abi.encodeCall(vault.redeem, (1 ether * 1e6, address(token), address(this))),
            abi.encodeCall(vault.donate, (1 ether))
        ];
        for (uint256 outer; outer < 5; ++outer) {
            for (uint256 inner; inner < calls.length; ++inner) {
                token.configure(address(vault), calls[inner], 0, 0);
                if (outer == 0) vault.deposit(1 ether, address(this));
                else if (outer == 1) vault.mint(1 ether * 1e6, address(this));
                else if (outer == 2) vault.withdraw(1 ether, address(this), address(this));
                else if (outer == 3) vault.redeem(1 ether * 1e6, address(this), address(this));
                else vault.donate(1 ether);
                assertFalse(token.callbackSucceeded());
                assertEq(
                    token.callbackResult(),
                    abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
                );
                assertEq(token.calls(), outer * 5 + inner + 1);
            }
        }
        assertEq(vault.totalAssets() + vault.unvested(), token.balanceOf(address(vault)));
    }

    function test_shareBurnPrecedesOutgoingTokenCall() public {
        token.configure(address(vault), abi.encodeCall(vault.donate, (1)), 0, 0);
        vault.redeem(10 ether * 1e6, address(this), address(this));
        assertEq(token.observedShares(), 90 ether * 1e6);
        assertEq(token.observedSupply(), 90 ether * 1e6);
    }

    function test_falseIncomingTransfersRevertEveryPaymentAtomically() public {
        _checkIncomingFailure(1, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
    }

    function test_revertingIncomingTransfersRevertEveryPaymentAtomically() public {
        _checkIncomingFailure(2, abi.encodeWithSelector(CallbackAsset.TransferRejected.selector));
    }

    function _checkIncomingFailure(uint8 mode, bytes memory reason) internal {
        vault.donate(70 ether);
        uint256 end = vault.lockEnd();
        vm.warp(vm.getBlockTimestamp() + 3 days);
        token.configure(address(0), "", mode, 0);
        vm.expectRevert(reason);
        vault.deposit(1 ether, address(this));
        vm.expectRevert(reason);
        vault.mint(1 ether * 1e6, address(this));
        vm.expectRevert(reason);
        vault.donate(1 ether);
        assertEq(vault.lockEnd(), end);
        assertEq(vault.lockedAmount(), 70 ether);
        assertEq(vault.unvested(), 40 ether);
        assertEq(vault.totalSupply(), 100 ether * 1e6);
        assertEq(token.balanceOf(address(vault)), 170 ether);
    }

    function test_falseOutgoingTransfersRestoreSharesAndAllowanceAndAllowRetry() public {
        _checkOutgoingFailure(1, abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
    }

    function test_revertingOutgoingTransfersRestoreSharesAndAllowanceAndAllowRetry() public {
        _checkOutgoingFailure(2, abi.encodeWithSelector(CallbackAsset.TransferRejected.selector));
    }

    function _checkOutgoingFailure(uint8 mode, bytes memory reason) internal {
        address operator = address(0xB0B);
        vault.approve(operator, 10 ether * 1e6);
        token.configure(address(0), "", 0, mode);
        vm.expectRevert(reason);
        vm.prank(operator);
        vault.withdraw(10 ether, operator, address(this));
        vm.expectRevert(reason);
        vm.prank(operator);
        vault.redeem(10 ether * 1e6, operator, address(this));
        assertEq(vault.allowance(address(this), operator), 10 ether * 1e6);
        assertEq(vault.balanceOf(address(this)), 100 ether * 1e6);
        assertEq(vault.totalSupply(), 100 ether * 1e6);
        assertEq(token.balanceOf(address(vault)), 100 ether);
        assertEq(token.balanceOf(operator), 0);
        token.configure(address(0), "", 0, 0);
        vm.prank(operator);
        vault.redeem(10 ether * 1e6, operator, address(this));
        assertEq(vault.allowance(address(this), operator), 0);
        assertEq(token.balanceOf(operator), 10 ether);
    }
}
