// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DonationVault4626} from "../src/DonationVault4626.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract VaultHandler is Test {
    LaunchToken public immutable token;
    DonationVault4626 public immutable vault;
    address[4] public actors = [address(0xA), address(0xB), address(0xC), address(0xD)];
    uint256 public totalIn;
    uint256 public totalOut;
    uint256 public modelLocked;
    uint256 public modelStart;
    uint256 public modelSupply;
    mapping(address => uint256) public modelShares;
    mapping(address => uint256) public principal;
    mapping(address => uint256) public donationsPaid;
    mapping(address => uint256) public paidOut;
    mapping(address => uint256) public vestedCredit;
    mapping(address => uint256) public roundingCredit;
    mapping(address => uint256) public transferCreditIn;
    mapping(address => uint256) public transferCreditOut;
    uint256 public rejectedCalls;
    uint256 public streamedDonations;
    uint256 public directDonations;
    uint256 public principalIn;

    uint256 internal constant OFFSET = 1e6;

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
        assertEq(shares, amount * (modelSupply + OFFSET) / (modelAssets() + 1), "deposit quote");
        if (shares == 0) {
            bytes32 beforeState = stateDigest();
            vm.expectRevert(DonationVault4626.ZeroShares.selector);
            vm.prank(actor);
            vault.deposit(amount, actor);
            assertEq(stateDigest(), beforeState, "zero shares changed state");
            ++rejectedCalls;
        } else {
            vm.prank(actor);
            assertEq(vault.deposit(amount, actor), shares);
            _accountEntry(actor, amount, shares);
            totalIn += amount;
        }
    }

    function mint(uint256 actorSeed, uint256 shares) external {
        address actor = actors[actorSeed % 4];
        uint256 affordableShares = vault.convertToShares(token.balanceOf(actor));
        if (affordableShares == 0) return;
        shares = bound(shares, 1, affordableShares);
        uint256 assets = vault.previewMint(shares);
        assertEq(assets, Math.ceilDiv(shares * (modelAssets() + 1), modelSupply + OFFSET), "mint quote");
        vm.prank(actor);
        assertEq(vault.mint(shares, actor), assets);
        _accountEntry(actor, assets, shares);
        totalIn += assets;
    }

    function withdraw(uint256 actorSeed, uint256 assets) external {
        address actor = actors[actorSeed % 4];
        uint256 max = vault.maxWithdraw(actor);
        assets = bound(assets, 0, max);
        uint256 shares = vault.previewWithdraw(assets);
        assertEq(shares, Math.ceilDiv(assets * (modelSupply + OFFSET), modelAssets() + 1), "withdraw quote");
        vm.prank(actor);
        assertEq(vault.withdraw(assets, actor, actor), shares);
        _accountExit(actor, assets, shares);
        totalOut += assets;
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address actor = actors[actorSeed % 4];
        shares = bound(shares, 0, vault.maxRedeem(actor));
        uint256 assets = vault.previewRedeem(shares);
        assertEq(assets, shares * (modelAssets() + 1) / (modelSupply + OFFSET), "redeem quote");
        vm.prank(actor);
        assertEq(vault.redeem(shares, actor, actor), assets);
        _accountExit(actor, assets, shares);
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
        streamedDonations += amount;
        donationsPaid[actor] += amount;
    }

    function directTransfer(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % 4];
        amount = bound(amount, 0, token.balanceOf(actor));
        vm.prank(actor);
        token.transfer(address(vault), amount);
        _creditYield(amount);
        totalIn += amount;
        directDonations += amount;
        donationsPaid[actor] += amount;
    }

    function transferShares(uint256 actorSeed, uint256 receiverSeed, uint256 shares) external {
        address actor = actors[actorSeed % 4];
        address receiver = actors[receiverSeed % 4];
        shares = bound(shares, 0, vault.balanceOf(actor));
        vm.prank(actor);
        vault.transfer(receiver, shares);
        if (actor != receiver && shares != 0) {
            // Transfer the entitlement with the shares. Rounding outward leaves both holders
            // an upper bound and introduces at most one asset wei of credit per transfer.
            uint256 numerator = budget(actor) * shares;
            transferCreditOut[actor] += numerator / modelShares[actor];
            transferCreditIn[receiver] += Math.ceilDiv(numerator, modelShares[actor]);
            modelShares[actor] -= shares;
            modelShares[receiver] += shares;
        }
    }

    function advance(uint256 seconds_) external {
        uint256 lockedBefore = modelUnvested();
        // Bias toward exact stream boundaries as well as arbitrary elapsed times.
        uint256 remaining =
            modelStart + 7 days > vm.getBlockTimestamp() ? modelStart + 7 days - vm.getBlockTimestamp() : 0;
        uint256 elapsed = bound(seconds_, 0, 14 days);
        if (seconds_ % 5 == 0) elapsed = remaining;
        else if (seconds_ % 5 == 1) elapsed = remaining == 0 ? 0 : remaining - 1;
        else if (seconds_ % 5 == 2) elapsed = remaining + 1;
        vm.warp(vm.getBlockTimestamp() + elapsed);
        _creditYield(lockedBefore - modelUnvested());
    }

    function modelAssets() public view returns (uint256) {
        return totalIn - totalOut - modelUnvested();
    }

    function budget(address actor) public view returns (uint256) {
        return principal[actor] + vestedCredit[actor] + roundingCredit[actor] + transferCreditIn[actor] - paidOut[actor]
            - transferCreditOut[actor];
    }

    function _accountEntry(address actor, uint256 assets, uint256 shares) internal {
        uint256 supply = modelSupply + OFFSET;
        uint256 dust = assets * supply - shares * (modelAssets() + 1);
        _creditRounding(dust, supply * (supply + shares));
        modelShares[actor] += shares;
        modelSupply += shares;
        principal[actor] += assets;
        principalIn += assets;
    }

    function _accountExit(address actor, uint256 assets, uint256 shares) internal {
        assertLe(assets, budget(actor), "user spent another holder's principal or locked yield");
        uint256 supply = modelSupply + OFFSET;
        uint256 dust = shares * (modelAssets() + 1) - assets * supply;
        modelShares[actor] -= shares;
        modelSupply -= shares;
        paidOut[actor] += assets;
        _creditRounding(dust, supply * (supply - shares));
    }

    function _creditYield(uint256 amount) internal {
        for (uint256 i; i < actors.length; ++i) {
            vestedCredit[actors[i]] += Math.ceilDiv(amount * modelShares[actors[i]], modelSupply + OFFSET);
        }
    }

    function _creditRounding(uint256 dust, uint256 denominator) internal {
        // An entry raises (A+1)/(S+offset) by dust/[S*(S+newShares)]; an exit
        // raises it by dust/[S*(S-burnedShares)]. Only that price increment can
        // benefit other holders. mulDiv keeps the intermediate product full precision.
        for (uint256 i; i < actors.length; ++i) {
            roundingCredit[actors[i]] += Math.mulDiv(modelShares[actors[i]], dust, denominator, Math.Rounding.Ceil);
        }
    }

    /// @dev Failures are deliberately part of the random history, including after partial vesting.
    function rejectInvalid(uint256 actorSeed, uint256 actionSeed) external {
        address actor = actors[actorSeed % 4];
        address other = actors[(actorSeed % 4 + 1) % 4];
        uint256 action = actionSeed % 8;
        bytes memory callData;
        bytes memory errorData;
        if (action == 0) {
            callData = abi.encodeCall(vault.deposit, (0, actor));
            errorData = abi.encodeWithSelector(DonationVault4626.ZeroShares.selector);
        } else if (action == 1) {
            callData = abi.encodeCall(vault.mint, (0, actor));
            errorData = abi.encodeWithSelector(DonationVault4626.ZeroShares.selector);
        } else if (action == 2) {
            callData = abi.encodeCall(vault.donate, (0));
            errorData = abi.encodeWithSelector(DonationVault4626.ZeroDonation.selector);
        } else if (action == 3) {
            uint256 max = vault.maxWithdraw(actor);
            callData = abi.encodeCall(vault.withdraw, (max + 1, actor, actor));
            errorData = abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, actor, max + 1, max);
        } else if (action == 4) {
            uint256 max = vault.maxRedeem(actor);
            callData = abi.encodeCall(vault.redeem, (max + 1, actor, actor));
            errorData = abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, actor, max + 1, max);
        } else if (action == 5 || action == 6) {
            callData = action == 5
                ? abi.encodeCall(vault.withdraw, (0, other, actor))
                : abi.encodeCall(vault.redeem, (0, other, actor));
            errorData = abi.encodeWithSelector(DonationVault4626.ReceiverMustBeCaller.selector);
        } else {
            uint256 shares = vault.balanceOf(actor);
            callData = abi.encodeCall(vault.transfer, (other, shares + 1));
            errorData =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, actor, shares, shares + 1);
        }
        bytes32 beforeState = stateDigest();
        vm.prank(actor);
        (bool success, bytes memory returned) = address(vault).call(callData);
        assertFalse(success, "invalid action succeeded");
        assertEq(returned, errorData, "wrong rejection");
        assertEq(stateDigest(), beforeState, "failed action changed state");
        ++rejectedCalls;
    }

    function stateDigest() public view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                token.balanceOf(address(vault)),
                vault.totalSupply(),
                vault.totalAssets(),
                vault.unvested(),
                vault.lockedAmount(),
                vault.lockEnd()
            )
        );
        for (uint256 i; i < actors.length; ++i) {
            digest = keccak256(
                abi.encode(
                    digest,
                    token.balanceOf(actors[i]),
                    vault.balanceOf(actors[i]),
                    token.allowance(actors[i], address(vault))
                )
            );
        }
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
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.mint.selector;
        selectors[2] = handler.withdraw.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.directTransfer.selector;
        selectors[6] = handler.transferShares.selector;
        selectors[7] = handler.advance.selector;
        selectors[8] = handler.rejectInvalid.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_assetsAreBackedAndInflowsEqualOutflowsPlusBalance() public view {
        uint256 balance = token.balanceOf(address(vault));
        assertLe(vault.totalAssets(), balance);
        assertEq(vault.totalAssets() + vault.unvested(), balance);
        assertEq(handler.totalIn(), handler.totalOut() + balance);
        assertEq(vault.totalAssets(), handler.modelAssets());
        assertLe(
            handler.totalOut(),
            handler.principalIn() + handler.directDonations() + handler.streamedDonations() - handler.modelUnvested(),
            "locked donations were paid out"
        );
    }

    function invariant_usersOnlySpendTheirPrincipalTransferredRightsAndEarnedYield() public view {
        assertEq(vault.totalSupply(), handler.modelSupply());
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(vault.balanceOf(actor), handler.modelShares(actor), "share ledger mismatch");
            assertLe(vault.maxWithdraw(actor), handler.budget(actor), "user claim exceeds earned entitlement");
            assertEq(
                token.balanceOf(actor),
                200_000_000 ether + handler.paidOut(actor) - handler.principal(actor) - handler.donationsPaid(actor)
            );
        }
    }

    function afterInvariant() public {
        uint256 locked = vault.unvested();
        for (uint256 i; i < 4; ++i) {
            handler.redeem(i, vault.balanceOf(handler.actors(i)));
        }
        assertEq(vault.totalSupply(), 0, "all modeled holders must be able to exit");
        assertEq(vault.unvested(), locked, "exiting unlocked donations");
        invariant_usersOnlySpendTheirPrincipalTransferredRightsAndEarnedYield();
        invariant_assetsAreBackedAndInflowsEqualOutflowsPlusBalance();
    }

    function test_accountingAcrossTransfersOverlappingStreamsFailuresAndFullExit() public {
        handler.deposit(0, 19 ether);
        handler.mint(1, 23 ether * 1e6);
        handler.donate(2, 70 ether);
        handler.advance(2 days + 3);
        handler.transferShares(0, 3, vault.balanceOf(handler.actors(0)) / 2);
        handler.directTransfer(2, 13);
        handler.donate(3, 7 ether);
        handler.withdraw(1, 1 ether);
        handler.redeem(3, 1e6);
        for (uint256 action; action < 8; ++action) {
            handler.rejectInvalid(0, action);
        }
        assertEq(handler.rejectedCalls(), 8);
        invariant_usersOnlySpendTheirPrincipalTransferredRightsAndEarnedYield();
        invariant_assetsAreBackedAndInflowsEqualOutflowsPlusBalance();
        invariant_streamMatchesIndependentClockModel();
        afterInvariant();
        handler.advance(1 days + 3);
        handler.deposit(1, 1 ether);
        handler.advance(0); // Exactly the restarted stream's end.
        afterInvariant();
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
