# NatSpec — Solidity

> When and how to document Solidity code.
> Read alongside `.claude/dev/solidity.md`.

---

## NatSpec — Solidity

Use `///` for single lines, `/** */` for blocks.

**Mandatory on**: all `external`, `public`, and `internal` functions where logic is non-obvious.

### Contracts / Interfaces
```solidity
/// @title  VaultManager
/// @author Team Name
/// @notice Manages async deposit/redeem lifecycle for ERC-7540 vaults
/// @dev    Follows CEI pattern throughout. Ward-gated admin functions.
```

### Public / External Functions
```solidity
/// @notice Deposits assets into the vault and mints shares to receiver
/// @dev    Assets transferred to escrow immediately. CEI order enforced.
/// @param  assets   Amount of underlying asset tokens in wei
/// @param  receiver Address that will receive the minted shares
/// @return shares   Number of shares minted
function deposit(uint256 assets, address receiver) external returns (uint256 shares);
```

### Events and Errors
```solidity
/// @notice Emitted when a deposit request is approved by admin
/// @param  poolId   The pool identifier
/// @param  amount   Approved asset amount in wei
event DepositApproved(PoolId indexed poolId, uint256 amount);

/// @notice Thrown when caller is not an authorized ward
error NotAuthorized();
```

### Internal Functions — NatSpec only if non-obvious
```solidity
// ✅ Needs @dev — rounding has security implications
/// @dev Rounds down to prevent share inflation attacks. See ERC-4626 §8.
function _convertToShares(uint256 assets) internal view returns (uint256) { ... }

// ✅ Needs @dev — non-obvious side effect
/// @dev Also increments the global epoch counter. Call only after state is settled.
function _closeEpoch() internal { ... }

// ❌ Skip — self-explanatory
function _isAuthorized(address account) internal view returns (bool) {
    return wards[account] == 1;
}
```

---

## Inline Comments — When to Write Them

Write an inline comment **only** for one of these five reasons:

### 1. Non-obvious math or deliberate rounding
```solidity
// Round down to protect against share inflation (ERC-4626 §8)
shares = assets.mulDivDown(totalSupply, totalAssets);

// Multiply before divide — Solidity truncates integer division
uint256 fee = (amount * feeBps) / 10_000;
```

### 2. Security decision — why that specific choice
```solidity
// SECURITY: state updated before external call to prevent reentrancy
balances[msg.sender] -= amount;
(bool ok,) = msg.sender.call{value: amount}("");

// SECURITY: tx.origin excluded intentionally — msg.sender only for auth
require(wards[msg.sender] == 1, NotAuthorized());
```

### 3. Workaround or non-intuitive behavior
```solidity
// globalEscrow() deprecated in v3.1+ but ABI preserved for backward compat
// Returns pool-specific PoolEscrow, not a global contract
address escrow = vault.globalEscrow();
```

### 4. Critical invariant or assumption
```solidity
// Invariant: totalAssets >= sum(pendingRedeems) must hold after _settle()
// Violation enables share price manipulation
assert(totalAssets >= pendingRedeemTotal);
```

### 5. External reference (EIP slot, issue number, spec link)
```solidity
// EIP-1967 storage slot: keccak256("eip1967.proxy.implementation") - 1
bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894...;
```

---

## Anti-Patterns — Never Write These

```solidity
// ❌ Obvious — remove it
// Increment counter
counter++;

// ❌ Repeats the code — adds no information
// Transfer tokens to user
token.transfer(user, amount);

// ❌ TODO in production code — open a GitHub issue instead
// TODO: fix precision loss here
// ✅ Acceptable form: reference an issue
// NOTE: precision loss <1 wei per tx, acceptable. Tracked in issue #142.
```

---

## Documentation Checklist (pre-PR)
- [ ] Every contract/interface has `@title`, `@notice`, `@dev`
- [ ] Every `external`/`public` function has `@notice`, `@param` per parameter, `@return` if it returns
- [ ] Every non-obvious `internal` function has at least `@dev`
- [ ] Every event has `@notice` describing when it fires
- [ ] Every custom error has `@notice`
- [ ] Inline comments on: math, security decisions, workarounds, invariants, external refs
- [ ] No obvious comments, no TODOs in production code
- [ ] `forge doc` generates without warnings