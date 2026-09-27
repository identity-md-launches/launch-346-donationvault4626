# Piggy donation vault

This contribution implements the Piggy launch token and donation vault for the Sepolia
contract stage. It includes source, vendored dependencies, ABI exports, and local tests.
The separate manifest author, independent reviewer, deployment services, and frontend
contributor perform the subsequent stages. No deployment or independent audit is claimed here.

## Build and test

Requires Foundry and Solidity **0.8.26** installed by the worker. Dependencies are ordinary
files in `lib/`; building requires no package installation or network once the compiler is
available. `foundry.toml` pins the compiler, Cancun EVM, optimizer (200 runs), and
`bytecode_hash = "none"`. FFI and filesystem cheatcode permissions are disabled.

```sh
forge build
forge test
forge fmt --check
```

Tests require no environment variables, RPC connection, wallet keys, or broadcasts. Fuzz
tests run 512 cases each; stateful invariants run 128 sequences of 64 operations each.
See [the test and review handoff](docs/REVIEW.md) for coverage and design limitations.

OpenZeppelin Contracts **v5.0.2** supplies ERC-20, ERC-4626, SafeERC20, ReentrancyGuard,
and their transitive dependencies. Forge Standard Library **v1.9.6** supplies test helpers.
These are unmodified upstream source files with licenses; versions, upstream URLs, archive
hashes, and per-file hashes are recorded in [dependencies.json](docs/dependencies.json).
The vault uses OpenZeppelin's
[virtual asset/share conversions](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/token/ERC20/extensions/ERC4626.sol).

## Contracts and deployment parameters

| Contract | Source | Nonpayable constructor | Configuration |
| --- | --- | --- | --- |
| LaunchToken | `src/LaunchToken.sol` | `()` | Piggy / PIGY, 18 decimals, fixed supply `1000000000000000000000000000` minor units |
| DonationVault4626 | `src/DonationVault4626.sol` | `(address asset_)` | `asset_ = $token`; Piggy Vault / vPIGY, 24 decimals, seven-day stream |

Deployment target: **Sepolia, chain ID 11155111**, through ProjectFactory. Deploy LaunchToken
first and DonationVault4626 second. The token mints its entire supply to its constructor's
`msg.sender` (the factory). The vault neither receives nor requires PIGY during deployment;
it has no initializer and no privileged address. Its immutable `token()` and ERC-4626
`asset()` both expose the supplied PIGY address. The constructor rejects absent code and
assets whose declared decimals are not 18; this is not an identity check. Services must
resolve `$token` to the accepted LaunchToken, not an arbitrary token with matching decimals.

For the separate manifest assignment: use kind `evm_project`, launch token `LaunchToken`,
and one application named `DonationVault4626` with `constructorArgs: ["$token"]`. There
is no `$owner` argument. Services supply policy, artifact linkage, the actual factory
address, liquidity/reward configuration, and deployed addresses; this contribution does
not write `launch.json`. Service admission enforces Sepolia; the source itself has no
chain-specific lock. It is fully testable on a local EVM.

Users obtain PIGY by swapping Sepolia ETH in the launch pool. The app uses only PIGY.
Neither contract exposes mint, owner, fee, pause, upgrade, or rescue powers. The vault has
no payable function, receive, or fallback. Ordinary ETH sends revert. EVM-level forced
ETH remains possible, is ignored by vault accounting, and has no recovery function.

## Donation accounting

Let `B` be the vault's PIGY balance and `W = 604800` seconds. A successful positive
`donate(amount)` pulls exactly `amount` via SafeERC20 and updates:

```text
remaining    = unvested(now)
lockedAmount = remaining + amount
lockEnd      = now + W
unvested(t)  = 0                                         if t >= lockEnd
              floor(lockedAmount * (lockEnd - t) / W)   otherwise
totalAssets  = B - unvested(now)
```

Previously vested assets stay vested. Overlapping donations merge the unvested remainder
and restart the entire remainder's seven-day clock. A zero donation reverts, but even a
one-wei positive donation can repeatedly extend the remaining stream. This delay/griefing
behavior is inherent in the approved restart rule; there is no admin or keeper to override it.
Unlocking is computed on demand, requires no transaction, and uses block timestamps.
Unvested amounts round down, so elapsed-time rounding can release less than one minor unit
ahead of the exact fractional schedule.

**Direct ERC-20 transfers count immediately** and do not change `lockedAmount` or `lockEnd`.
They bypass streaming and can benefit accounts that enter just before the transfer.
Donors should use `approve` then `donate`, not `transfer` to the vault.

If everyone redeems during vesting, the unvested tokens remain in the vault and keep
unlocking. The vested remainder contributes to the next depositors' starting share price,
and subsequent unlocking accrues to those shareholders. Virtual shares retain part of
pre-existing assets and rounding dust, especially after the supply becomes zero; a new
depositor is not promised ownership of the entire residual balance. There is no sweep.

## Shares, rounding, and payments

With `A = totalAssets()` and `S = totalSupply()`, conversions use the OpenZeppelin virtual
asset/share formula:

```text
assets -> shares: assets * (S + 1_000_000) / (A + 1)
shares -> assets: shares * (A + 1) / (S + 1_000_000)
```

The decimal offset is six: one PIGY initially buys one whole vPIGY (`1e24` share units).
`deposit` and `redeem` round down; `mint` and `withdraw` round up. The conversion views
round down. A deposit or mint yielding zero shares reverts. Zero withdrawals/redemptions
retain the base implementation's behavior. All conversions, previews, and max-withdraw
limits use vested assets. `maxRedeem` returns the owner's share balance; `maxDeposit` and
`maxMint` retain the base unlimited-vault values and do not promise sufficient user
balance/approval. Previews are estimates at the current state, not slippage guarantees.

Deposits, mints, and donations require asset approval to the vault and use SafeERC20
`safeTransferFrom`. PIGY has no fee, callbacks, or rebasing, so the amount pulled is the
amount credited. Other asset behaviors are unsupported even if their decimals are 18.
Every entry/exit/donation operation is protected by the same reentrancy guard. Exits
spend share allowance when delegated, burn shares, then use `safeTransfer`. A failed
transfer rolls back the whole operation, including balances, allowance, and stream state.

**Caller-only payout constraint:** `withdraw(assets, receiver, owner)` and
`redeem(shares, receiver, owner)` require `receiver == msg.sender`, implementing the
approved pull-withdrawal requirement. Self exits use the connected wallet for both
addresses. An approved operator may spend the owner's shares and receive assets itself.
This restricts the usual ERC-4626 arbitrary-receiver behavior; integrations needing a
different payout receiver must first receive the PIGY themselves and forward it. Deposit
and mint receivers remain unrestricted. Token and share allowances are distinct.

The vault does not burn PIGY or charge a fee. ERC-4626 redemption burns **vault shares**
using the standard supply-reducing burn. A voluntary PIGY disposal is a transfer to
`0x000000000000000000000000000000000000dEaD`; it does not reduce the fixed token supply.

## ABI and frontend handoff

Machine-readable exports are [LaunchToken.json](docs/abi/LaunchToken.json) and
[DonationVault4626.json](docs/abi/DonationVault4626.json). See
[ABI usage](docs/ABI.md) for units, views, events, errors, and regeneration commands.

After service deployment, the frontend contributor builds the single static page labeled
`lab-donation-vault`, exporting `dist/index.html`. It must pin Sepolia, obtain PIGY from
`vault.token()`, show wallet PIGY balance/allowance, shares and their current PIGY value,
unvested assets, `lockEnd`, and a Snapshot-based price history. Paying actions have an
Approve step; withdrawals use the caller as receiver. Explain that users swap Sepolia ETH
in the external launch pool; there is no in-page swap. Read views and chunk event-log
queries from the service-provided deployment block, with no backend or indexer.

Manifest authors and the independent reviewer inspect these sources and constructor
parameters before services publish, attest, admit, and deploy. Services then provide
deployment addresses/block numbers for the frontend and handle approved GitHub/IPFS
publication. None of those later service outcomes is a prerequisite of this source task.
