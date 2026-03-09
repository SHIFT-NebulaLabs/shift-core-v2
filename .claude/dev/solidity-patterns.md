# Solidity Patterns

> Gas optimization, upgradability, and CI.
> Read alongside `.claude/dev/solidity.md`.

---

## Gas Optimization

### Storage Packing
```solidity
// ❌ 3 slots
uint256 a;
uint128 b;
uint128 c;

// ✅ 2 slots — b and c share one slot
uint256 a;
uint128 b;
uint128 c;
```

### Rules
- `immutable` for values set once in constructor — reads are free (no SLOAD)
- `constant` for compile-time values — zero gas
- Cache storage reads in a local variable before loops — but **do not** cache `calldata` array length (already cheap)
- `calldata` over `memory` for external params not being modified
- `++i` over `i++` in loops
- Short-circuit: revert as early as possible — cheap checks before storage reads or external calls
- Only write storage if value actually changed
- If a modifier reads the same storage slot as the function body, refactor the modifier to an internal function

```solidity
// ✅ calldata, no cached length (calldata length is cheap)
function processIds(uint256[] calldata _ids) external {
    for (uint256 i; i < _ids.length; ++i) { ... }
}

// ✅ cache storage reads, not calldata
function _sumBalances(address[] calldata _accounts) internal view returns (uint256 total) {
    uint256 _len = _accounts.length;
    for (uint256 i; i < _len; ++i) {
        total += s_balances[_accounts[i]];
    }
}
```

**Never** sacrifice readability or safety for marginal gas gains. Measure with `forge snapshot` — never guess.

---

## Upgradability

**Default: UUPS** unless there is a specific reason otherwise.

| Pattern | When to use |
|---|---|
| **UUPS** (default) | New contracts — smaller proxy, cheaper calls |
| **Transparent Proxy** | When admin key must be separated from users |
| **Beacon** | Many instances of the same implementation (e.g. vaults per pool) |
| **None** | Contracts that must be immutable by design |

### OZ Upgradeable — Installation & Remappings

```bash
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.3.0
```

`remappings.txt` — use this exact layout for Etherscan verification to work:
```
@openzeppelin/contracts/=lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/
@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/
```

> Do NOT install `openzeppelin-contracts` separately alongside — it will conflict. Both `@openzeppelin/contracts/` and `@openzeppelin/contracts-upgradeable/` must come from the upgradeable submodule.

```solidity
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/// @custom:security-contact security@example.com
contract MyContract is UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address _owner) external initializer {
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        _transferOwnership(_owner);
    }

    function _authorizeUpgrade(address _newImpl) internal override onlyOwner {}
}
```

**Non-negotiable:**
- Never use `constructor` in upgradeable contracts — use `initialize` + `initializer`
- Never reorder or remove storage variables between upgrades — append only
- Always `_disableInitializers()` in constructor
- Gate `_authorizeUpgrade` — unprotected = full takeover
- Storage gaps in base contracts: `uint256[50] private __gap;`

---

## CI Pipeline (minimum)

Run in parallel via matrix strategy:

```yaml
strategy:
  matrix:
    check: [lint, build, slither, fuzz]
```

- `solhint` — style and security linting
- `forge build --sizes` — verify contracts are under 24KB deployment limit
- `slither .` — static analysis
- Invariant/fuzz suite — Echidna or Medusa, ~10 min budget per tool

---

## Pre-PR Checklist
- [ ] All admin functions have access control modifiers
- [ ] `Ownable2Step` used — not `Ownable`
- [ ] Admin is a multisig address — not a deployer EOA
- [ ] CEI order respected in all state-changing functions
- [ ] `nonReentrant` before all other modifiers on vulnerable functions
- [ ] `SafeTransferLib::safeTransferETH` used — no raw `call{value}`
- [ ] No `tx.origin` for auth
- [ ] External call return values checked
- [ ] No hardcoded addresses
- [ ] Events emitted for all state changes
- [ ] No plaintext private keys anywhere
- [ ] `@custom:security-contact` in every deployed contract
- [ ] Slither passes with no high/medium findings
- [ ] Fuzz tests cover mathematical invariants
- [ ] `forge snapshot` run — gas regressions reviewed
- [ ] `forge build --sizes` — no contract over 24KB