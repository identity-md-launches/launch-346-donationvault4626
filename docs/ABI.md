# ABI integration

Exports are JSON ABI arrays generated from Solidity 0.8.26 build artifacts, including
inherited ERC-20/ERC-4626 methods, events, and errors. Regenerate from repository root:

```sh
forge build
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect src/DonationVault4626.sol:DonationVault4626 abi --json > docs/abi/DonationVault4626.json
```

All amounts are integers. PIGY has 18 decimals, vPIGY has 24. Every state-changing method
is nonpayable. Asset and vault-share `approve` are separate approvals.

| Operation | Meaning / result |
| --- | --- |
| `token()` / `asset()` | Immutable PIGY address |
| `totalAssets()` | Vested PIGY backing shares, excluding the current stream |
| `totalSupply()` / `balanceOf(wallet)` | Total / wallet share minor units |
| `unvested()` | Remaining stream in PIGY minor units, rounded down |
| `lockedAmount()` | Amount scheduled at the most recent donation; not the current remainder |
| `lockEnd()` | Last stream end as Unix seconds; initially zero, unchanged after expiry |
| `UNLOCK_DURATION()` | `604800` seconds |
| `sharePrice()` | `convertToAssets(1e24)`, PIGY minor units per whole vPIGY |
| `deposit(assets, receiver)` | Pull assets from caller, issue shares to receiver, return shares |
| `mint(shares, receiver)` | Pull upward-rounded assets from caller, return asset cost |
| `withdraw(assets, receiver, owner)` | Spend/burn upward-rounded owner shares, return shares spent |
| `redeem(shares, receiver, owner)` | Spend/burn owner shares, return downward-rounded assets |
| `donate(amount)` | Pull positive PIGY amount and merge/restart the stream; no return value |

On both exits `receiver` **must equal the caller**, including an approved operator.
When `owner != caller`, the owner must have approved that caller to spend vault shares.
Deposits and mints may issue shares to another account. PIGY approvals are required for
deposit, mint, and donate. A preview does not check these authorizations or guarantee a
minimum output at execution time. Estimate and refresh immediately before submission.

`convertToShares` / `convertToAssets`, `previewDeposit` / `previewMint` /
`previewWithdraw` / `previewRedeem`, and `maxDeposit` / `maxMint` / `maxWithdraw` /
`maxRedeem` are inherited, using the overridden vested `totalAssets`. The connected
wallet's current value is `convertToAssets(balanceOf(wallet))`, not shares times a
floating-point price. A positive deposit with a zero-share preview reverts.

| Event | When / fields |
| --- | --- |
| `Snapshot(uint256 totalAssets, uint256 totalSupply)` | Last event from each successful deposit, mint, withdraw, redeem, and donate; both fields unindexed |
| `Donated(address indexed donor, uint256 amount, uint256 lockEnd)` | Immediately before that donation's Snapshot |
| `Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)` | Standard entry event |
| `Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)` | Standard exit event |
| `Transfer` / `Approval` | Standard ERC-20 events, emitted by token or vault share contract respectively |

A Snapshot with `(A,S)` implies price `floor(1e24 * (A+1) / (S+1e6))` in PIGY
minor units. Use integer arithmetic. Query the vault's logs in bounded block ranges from
its deployment block and order by block/transaction/log index. Event timestamps come
from their block headers. Snapshots are action samples: passive vesting and direct token
transfers do not emit Snapshot. Refresh live views to show current values, and label the
chart accordingly; it is not a continuous record of every price change.

Additional errors are `InvalidAsset()`, `ZeroDonation()`, `ZeroShares()`, and
`ReceiverMustBeCaller()`. The ABI also includes the base ERC-20 insufficient balance/
allowance/invalid-address errors, ERC-4626 exceeded-maximum errors, SafeERC20 failure,
and the reentrancy error. A token failure can bubble its own revert data. No operation
needs native ETH value beyond the transaction's network gas fee.
