# Solidity Testing Standards

> Load when writing or reviewing Solidity tests.
> Read alongside `.claude/dev/solidity.md` for naming and code style rules.

---

## Philosophy

Prefer **stateless fuzz tests** over plain unit tests. For every test that would use a hardcoded value, make it a fuzz input instead.

```solidity
// ✅ fuzz — covers the entire input space
function testDeposit(uint256 amount) public {
    amount = bound(amount, 1, type(uint128).max);
    vault.deposit(amount, user);
}

// ❌ unit — only tests one point
function testDeposit() public {
    vault.deposit(1000e18, user);
}
```

---

## Branching Tree Technique

For complex functions, map all execution paths before writing tests.
Credit: [Paul R Berg](https://x.com/PaulRBerg/status/1682346315806539776)

1. Create a `.tree` file for the target function
2. Define nodes: "given state is X" → "when param is Y" → "it should Z"
3. Each leaf becomes one test function with a modifier chain

```
deposit.tree

├── when amount is zero
│   └── it should revert with Vault__ZeroAmount
└── when amount is non-zero
    ├── given user has insufficient balance
    │   └── it should revert with Vault__InsufficientBalance
    └── given user has sufficient balance
        ├── given vault is paused
        │   └── it should revert with Vault__Paused
        └── given vault is active
            └── it should transfer assets and emit Deposited
```

```solidity
function test_RevertWhen_ZeroAmount() external {
    vm.expectRevert(Vault__ZeroAmount.selector);
    vault.deposit(0, user);
}

modifier whenAmountNonZero() {
    vm.assume(amount > 0);
    _;
}

function test_Deposit()
    external
    whenAmountNonZero
    givenUserHasSufficientBalance
    givenVaultIsActive
{
    vault.deposit(amount, user);
    assertEq(vault.balanceOf(user), expectedShares);
}
```

---

## Test Types

### Stateless Fuzz
- Default for any function with numeric inputs
- Use `bound()` to constrain to valid ranges
- Target: math, rounding, state transitions

```solidity
function testConvertToShares(uint256 assets) public {
    assets = bound(assets, 1, type(uint128).max);
    uint256 shares = vault.convertToShares(assets);
    assertLe(shares, assets); // shares never exceed assets at 1:1
}
```

### Invariant (Stateful Fuzz)
- Define O(1) properties that must **always** hold
- Use [Chimera](https://github.com/Recon-Fuzz/chimera) to run the same suite across Foundry, Echidna, and Medusa — different fuzzers find different bugs
- Encode invariants in the contract itself where possible ([FREI-PI pattern](https://www.nascent.xyz/idea/youre-writing-require-statements-wrong))

```solidity
// Invariant: sum of all balances == totalSupply
function invariant_totalSupplyMatchesBalances() public {
    assertEq(token.totalSupply(), ghost_sumBalances);
}

// Invariant: totalAssets >= totalDebt at all times
function invariant_solvency() public {
    assertGe(vault.totalAssets(), vault.totalDebt());
}
```

### Integration
- Full deployment stack via shared `BaseScript` — same script used in production
- No test-only setup that diverges from real deploy paths

```solidity
// test/Setup.t.sol — inherits from the production deploy script
contract Setup is DeployVault {
    function setUp() public {
        run(); // same as forge script
    }
}
```

### Fork Tests
- Test against mainnet state — catches oracle misconfigs and governance errors that unit tests miss
- Always write fork tests for governance proposals

```solidity
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

## Coverage Target

- ≥ 90% line coverage
- 100% coverage on all critical paths (fund flows, access control, state transitions)

---

## References
- [Foundry Book — Testing](https://book.getfoundry.sh/forge/tests)
- [Paul R Berg — Branching Tree Technique](https://x.com/PaulRBerg/status/1682346315806539776)
- [Chimera — multi-fuzzer setup](https://github.com/Recon-Fuzz/chimera)
- [FREI-PI pattern](https://www.nascent.xyz/idea/youre-writing-require-statements-wrong)
- [Echidna](https://github.com/crytic/echidna)
- [Medusa](https://github.com/crytic/medusa)
- [Recon Book](https://book.getrecon.xyz)