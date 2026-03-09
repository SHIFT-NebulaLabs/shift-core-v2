# Audit — Solidity

> Load alongside `.claude/commands/audit-report.md` and `.claude/dev/solidity.md`.

---

## Solidity — Security Checklist

### Access Control
- [ ] Every admin/privileged function has an access modifier
- [ ] No missing `onlyOwner` / `onlyRole` on state-changing admin functions
- [ ] Every `grantRole` / `rely` has a matching revoke/deny path
- [ ] No `tx.origin` used for authentication
- [ ] Initializer functions protected (`initializer` modifier, not callable twice)

### Reentrancy
- [ ] CEI order respected in all state-changing functions (Checks → Effects → Interactions)
- [ ] `ReentrancyGuard` on all functions making external calls
- [ ] No cross-function reentrancy (state changes visible to re-entered function)
- [ ] Pull-over-push pattern used where applicable

### Integer Arithmetic
- [ ] No overflow risk (0.8+ built-in, but verify custom math)
- [ ] Division truncation documented and deliberate
- [ ] No phantom overflow: `a * b / c` where `a * b` can overflow before division
- [ ] Rounding direction documented and correct per ERC (4626 rounds down for user-facing)

### External Calls
- [ ] Return values checked on all `call`, `transfer`, `send`
- [ ] `SafeERC20` used for token transfers (handles non-compliant ERC20s)
- [ ] No unbounded external calls inside loops
- [ ] Untrusted external contracts treated as adversarial

### Oracle / Price
- [ ] No spot price used as on-chain oracle
- [ ] TWAP with appropriate window used
- [ ] Chainlink feeds have staleness checks
- [ ] Price manipulation via flash loan considered

### Upgradability (if applicable)
- [ ] Storage layout unchanged between versions
- [ ] `_authorizeUpgrade` properly gated
- [ ] `_disableInitializers()` in implementation constructor
- [ ] Storage gaps in base contracts

### Other
- [ ] No hardcoded addresses (use immutables or constructor params)
- [ ] Events emitted for all state changes
- [ ] No self-destruct
- [ ] No `delegatecall` to untrusted contracts
- [ ] Slither output reviewed — no unaddressed high/medium findings

---

## ERC Compliance Checklist (if applicable)

### ERC-4626 (sync vault)
- [ ] `deposit` and `mint` round shares down
- [ ] `withdraw` and `redeem` round assets up (against user)
- [ ] `previewDeposit`, `previewMint`, `previewWithdraw`, `previewRedeem` match actual behavior
- [ ] `maxDeposit`, `maxMint`, `maxWithdraw`, `maxRedeem` return correct limits
- [ ] `totalAssets` includes all protocol-owned assets, not just idle balance

### ERC-7540 (async vault)
- [ ] Three-phase lifecycle intact: REQUEST → PROCESS → CLAIM
- [ ] Phases not collapsed without explicit specification
- [ ] `pendingDepositRequest` and `claimableDepositRequest` correctly separated
- [ ] Shares not minted at request time — only at claim
- [ ] Operator pattern implemented if required

### ERC-4337 (account abstraction)
- [ ] Canonical EntryPoint used — no custom implementation
- [ ] `validateUserOp` returns correct magic value
- [ ] Paymaster logic audited separately

---

## Invariant Analysis (Solidity)

Before reviewing line by line, identify the protocol's core invariants — properties that must always hold regardless of execution path. These are the highest-value audit targets.

**FREI-PI pattern** — Function Requirements-Effects-Interactions + Protocol Invariants:
- Identify O(1) invariants (e.g. `totalAssets >= totalDebt`, `sum(balances) == totalSupply`)
- Check whether invariants are enforced inside core functions, not just in tests
- Any code path that can violate an invariant without reverting is a critical finding

**Multi-fuzzer setup with Chimera:**
- Run the same invariant suite across Foundry, Echidna, and Medusa — different fuzzers find different bugs
- If invariant tests are absent, flag it as a finding

---

## Governance Review (if applicable)

- [ ] Admin is a multisig — never an EOA on mainnet
- [ ] Governance proposals have fork tests that verify expected state post-execution
- [ ] `safe-utils` or equivalent used for proposal testing — not manual UI
- [ ] Time locks present on sensitive parameter changes
- [ ] No single point of failure in the upgrade path

```solidity
// ✅ Fork test verifying governance proposal outcome
function testGovernanceProposal_UpdatesPriceFeed() public {
    vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    _executeProposal(proposalId);
    address newFeed = oracle.priceFeed(market);
    assertEq(newFeed, EXPECTED_CHAINLINK_FEED);
    (, int256 price,,,) = AggregatorV3Interface(newFeed).latestRoundData();
    assertGt(price, 0);
}
```

---