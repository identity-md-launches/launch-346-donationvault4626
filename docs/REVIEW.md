# Test evidence and independent review handoff

This is an implementation handoff, not an independent audit. The independent review
assignment should inspect accepted source and the separately generated `launch.json`.
Concrete source, authorization, and constructor conflicts remain review findings.
Policy publication and signed artifact linkage are service responsibilities.

## Local test coverage

Local verification on 2026-09-27 with Forge 1.8.3 and Solidity 0.8.26: `forge build`,
`forge test`, and `forge fmt --check` passed. Forge reported 48 passing tests, zero
failures/skips, including its grouped run of three invariants over 8,192 calls with zero
unexpected reverts. A fresh compile and parallel test run also passed using
`env -i PATH=/usr/local/bin:/usr/bin:/bin forge test --offline -j 4` with output and cache
redirected into `test/scratch/`. Vendored file hashes matched their dependency record,
and both exported ABIs matched the build artifacts. Runtime sizes were 1,722 bytes for
LaunchToken and 5,569 bytes for DonationVault4626. These local results carry no independent
review authority.

| Tests | Behavior exercised |
| --- | --- |
| `test/LaunchToken.t.sol` | Supply/metadata, exact transfers (fuzz), approvals, insufficient balances/allowances, zero recipient, dead-address disposal, rejected common admin/mint selectors |
| `test/DonationVault4626.t.sol` | Constructor assumptions, 24-decimal shares, each entry point, previews (fuzz), independent rounding formulas, max limits, start/end/overlap stream arithmetic, zero-share rejection, allowance failures, delegated exits, share transfers, final event values, rejected ETH |
| `test/VaultAdversarial.t.sol` | One-wei attacker with streamed or direct donations (fuzz), victim deposits that must revert when rounded to zero, same-block sandwiches (fuzz), mint/withdraw sandwich, direct-donation capture, cheap stream extension, full-exit conservation |
| `test/VaultTransferSafety.t.sol` | All 25 combinations of outer operation and reentrant operation, burn-before-transfer ordering, false/reverting incoming and outgoing transfers, rollback of shares/allowances/stream state and successful retry |
| `test/VaultInvariant.t.sol` | Sequences of deposit/mint/withdraw/redeem/donate/direct transfers/share transfers/time advances; asset backing, flow conservation, stream model, share supply, fixed token supply, and aggregate redemption solvency |
| `test/FactoryCompatibility.t.sol` | CREATE2 factory deployment, no app initialization/funding, entire supply left in factory, constructor rejects ETH, runtime size and forbidden opcode scan skipping PUSH immediates |

The supplied protected tests describe the platform deployment floor and are inputs only.
The local factory tests exercise equivalent source properties without environment variables.
They do not claim to exercise service attestation, admission, actual pool setup, or the
later manifest. All delivered tests operate independently with fresh deployments.

## Assumptions and known tradeoffs to inspect

1. The asset must be the accepted, immutable, plain PIGY. Decimal checks alone cannot
   establish token identity or guarantee transfer behavior. The constructor must receive
   `$token`; no owner, beneficiary, payable constructor, or initialization call is needed.
2. Every conversion and limit must use vested `totalAssets()`. Inspect all four ERC-4626
   paths, delegated allowances, downward/upward rounding, and zero-share deposit failure.
   Caller-only payout is an explicit restriction on arbitrary ERC-4626 receivers, required
   by the approved pull-payout brief and disclosed in the ABI guide.
3. Review `lockEnd - timestamp` at exact expiry, flooring on each merge, full-supply
   donations, multiple donations in a block, and a full exit leaving a stream behind.
   A positive donation, even one wei, can defer the existing stream repeatedly. This is
   the specified merge/reset rule, not a keeper or administrator failure.
4. Six virtual-share decimals make the tested one-wei inflation attack unprofitable;
   fuzzing is not a universal proof against arbitrary multitransaction economic strategies.
   Direct transfers bypass the stream and can be captured by existing shareholders.
   Vault actions have no minimum-output/deadline arguments. Previews can change between
   signing and execution due to vesting, donations, and other users' activity.
5. The no-share state still owns underlying tokens; subsequent depositors acquire shares
   at a price including already-vested residuals, while later unlocking grows their value.
   Virtual shares retain part of the assets and rounding dust. There is no admin sweep,
   guaranteed full vault drain, protocol fee, or donor refund.
6. Ordinary ETH sends revert, but forced ETH cannot be prevented at EVM level and has no
   recovery route. No contract executes arbitrary code, uses a proxy, or has a privileged
   upgrade/escape path. Token disposal to the dead address differs from ERC-4626 share burns.
7. Timestamp progression determines vesting, without oracles or keepers. Static lint
   warnings about timestamp comparisons are expected for this schedule. Final snapshots
   follow token interactions under the shared reentrancy guard; the hostile-token tests
   exercise attempted callbacks. Production PIGY has no callbacks.

Before release, independently review the final source plus manifest, resolve any findings,
and verify the pinned compiler and exported ABI match the accepted artifacts. Deployment,
publication, attestation, admission, liquidity/rewards, and frontend activation then belong
to services and their assigned contributors.
