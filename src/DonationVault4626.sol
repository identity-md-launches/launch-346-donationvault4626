// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice PIGY vault whose donate() inflows vest linearly over seven days.
/// @dev Direct token transfers are immediately vested. Intended only for the plain 18-decimal
///      LaunchToken; fee-on-transfer and rebasing assets are unsupported. No privileged role exists.
contract DonationVault4626 is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant UNLOCK_DURATION = 7 days;
    IERC20 public immutable token;
    uint256 public lockedAmount;
    uint256 public lockEnd;

    error InvalidAsset();
    error ZeroDonation();
    error ZeroShares();
    error ReceiverMustBeCaller();

    event Donated(address indexed donor, uint256 amount, uint256 lockEnd);
    event Snapshot(uint256 totalAssets, uint256 totalSupply);

    /// @param asset_ The already-deployed PIGY launch token ($token in the manifest).
    constructor(address asset_) ERC20("Piggy Vault", "vPIGY") ERC4626(IERC20(asset_)) {
        if (asset_.code.length == 0 || IERC20Metadata(asset_).decimals() != 18) revert InvalidAsset();
        token = IERC20(asset_);
    }

    /// @notice Remaining locked PIGY, rounded down to a whole minor unit.
    function unvested() public view returns (uint256) {
        if (block.timestamp >= lockEnd) return 0;
        return Math.mulDiv(lockedAmount, lockEnd - block.timestamp, UNLOCK_DURATION);
    }

    /// @notice Only vested PIGY participates in every inherited ERC-4626 conversion and limit.
    function totalAssets() public view override returns (uint256) {
        return token.balanceOf(address(this)) - unvested();
    }

    /// @notice PIGY minor units redeemable for one whole 24-decimal vault share, rounded down.
    function sharePrice() external view returns (uint256) {
        return convertToAssets(10 ** 24);
    }

    /// @notice Merge the remaining stream with a new donation and restart the seven-day unlock.
    /// @dev Requires a positive amount and token approval. Even a small donation extends the stream.
    function donate(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroDonation();
        uint256 remaining = unvested();
        token.safeTransferFrom(msg.sender, address(this), amount);
        lockedAmount = remaining + amount;
        lockEnd = block.timestamp + UNLOCK_DURATION;
        emit Donated(msg.sender, amount, lockEnd);
        _snapshot();
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    /// @dev Pull payout: receiver must be msg.sender. An approved caller may spend an owner's shares.
    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    /// @dev Pull payout: receiver must be msg.sender. Shares are burned before the PIGY transfer.
    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (shares == 0) revert ZeroShares();
        super._deposit(caller, receiver, assets, shares);
        _snapshot();
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (receiver != caller) revert ReceiverMustBeCaller();
        super._withdraw(caller, receiver, owner, assets, shares);
        _snapshot();
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _snapshot() private {
        emit Snapshot(totalAssets(), totalSupply());
    }
}
