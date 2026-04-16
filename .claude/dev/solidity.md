# Solidity Standards

> Read alongside `.claude/dev/solidity-natspec.md` for documentation rules.

---

## Toolchain

- **Framework**: Foundry (Forge + Cast + Anvil)
- **Compiler version**: defined in `foundry.toml` — always use the version pinned there, never assume a newer one
- **Libraries**: OpenZeppelin Contracts v5+
- **Static Analysis**: Slither — run before every PR
- **Fuzzing**: Echidna or Medusa

```toml
# foundry.toml — source of truth for compiler version
[profile.default]
solc = "0.8.28"
evm_version = "cancun"
optimizer = true
optimizer_runs = 200
```

```bash
forge build
forge test
forge test -vvv                          # with traces
forge test --match-test testName -vvvv   # single test, full trace
forge test --gas-report
forge test --fork-url $MAINNET_RPC_URL --match-path test/Fork.t.sol -vvv
forge snapshot        # gas snapshots — run before/after optimization
forge fmt
slither .
```

### Makefile — Wrapping Complex Commands

Use `make` to avoid retyping long commands. Keep targets short and obvious.

```makefile
# Makefile
.PHONY: test test-fork coverage slither

test:
	forge test -vvv

test-fork:
	forge test --fork-url $(MAINNET_RPC_URL) --match-path test/Fork.t.sol -vvv

coverage:
	forge coverage --report lcov

slither:
	slither . --config-file slither.config.json

sizes:
	forge build --sizes
```

```bash
make test
make test-fork
make slither
```

---

### Cast — Debug & Inspection
```bash
cast 4byte-decode <calldata>             # decode calldata
cast decode-error <revert_data>          # decode revert
cast storage <address> <slot> --rpc-url $RPC_URL   # inspect storage slot
cast call <contract> "fn(uint256)(uint256)" <arg> --rpc-url $RPC_URL
cast run <tx_hash> --rpc-url $RPC_URL   # replay a tx locally
```

### Debug Patterns in Tests
```solidity
// Label addresses for readable traces
vm.label(address(vault), "Vault");
vm.label(address(token), "Token");

// Snapshot + revert state
uint256 snap = vm.snapshot();
vm.revertTo(snap);

// Expect specific revert
vm.expectRevert(Vault__NotAuthorized.selector);
vault.withdraw(amount);
```

---

## Philosophy

**Everything will be attacked.** Write every contract assuming an adversary will probe every edge case, every state transition, and every external call path.

---

## File Structure

Split by responsibility. Keep files under **300 lines** — if a file grows beyond that, split it.

```
src/
├── Types.sol        ← structs, custom types (type PoolId is uint64)
├── Errors.sol       ← all custom errors
├── Constants.sol    ← global constants (SCREAMING_SNAKE_CASE)
├── IVault.sol       ← interfaces (one interface per file)
├── Vault.sol        ← main contract logic
└── VaultLib.sol     ← reusable pure/internal logic extracted as library
```

**Rules:**
- Structs, custom types, and errors in dedicated files — never inline in the contract that first needs them
- If a struct or error is used in more than one contract, it must be in `Types.sol` or `Errors.sol`
- Constants shared across contracts go in `Constants.sol`; contract-specific constants stay in the contract
- One interface per file, prefixed with `I`
- If a pure/internal function is needed in more than one contract, extract it to a `*Lib.sol` library

### Inheritance vs Import

Use **inheritance** (`is`) for behavior — when the contract *is a* thing:
```solidity
// ✅ Vault IS an ERC4626, IS Ownable2Step, IS Pausable
contract Vault is ERC4626, Ownable2StepUpgradeable, Pausable { ... }
```

Use **import** (named, absolute — never relative `..`) for types, errors, and constants:
```solidity
// ✅ named absolute imports only
import {PoolId, AssetId} from "src/Types.sol";
import {NotAuthorized, InsufficientBalance} from "src/Errors.sol";
import {BASIS_POINTS, MAX_SUPPLY} from "src/Constants.sol";

// ❌ never relative paths
import "../Types.sol";
```

**Never** inherit from a file just to access its constants or errors — pollutes ABI and storage layout.

---

## Security Rules (Priority Order)

### 1. Access Control
- Use `Ownable2Step` (not `Ownable`) — two-step transfer prevents accidental ownership loss
- Use OZ `AccessControl` for multi-role systems, or custom Ward pattern — one choice per contract
- Every admin function must be gated — missing modifiers are the #1 audit finding
- Every `grantRole` / `rely` needs a matching revocation path
- Admin must be a **multisig from the very first mainnet deploy** — never a deployer EOA

### 2. CEI — Checks-Effects-Interactions
```solidity
function withdraw(uint256 amount) external {
    // CHECKS — revert as early as possible, before any storage reads
    if (s_balances[msg.sender] < amount) revert Vault__InsufficientBalance();
    // EFFECTS
    s_balances[msg.sender] -= amount;
    // INTERACTIONS — always last
    SafeTransferLib.safeTransferETH(msg.sender, amount);
}
```

### 3. Reentrancy
- `nonReentrant` modifier **before** all other modifiers
- Use `ReentrancyGuardTransient` (EIP-1153) when available — cheaper than storage-based guard
- Prefer pull-over-push payment patterns

### 4. Integer Safety
- Solidity 0.8+ has built-in overflow checks — do NOT add SafeMath
- No phantom overflow: `a * b / c` — multiply before divide only if `a * b` cannot overflow
- Be explicit about division truncation in financial math

### 5. ETH Transfers
- Use `SafeTransferLib::safeTransferETH` — never raw `call{value: ...}()` or `.transfer()`

### 6. Oracle / Price Manipulation
- Use TWAP — never spot prices for on-chain logic
- Add staleness checks on Chainlink feeds
- Consider flash loan manipulation on any price-reading path

---

## Code Style

### Naming (enforced, no exceptions)
- Internal/private functions: `_` prefix → `_convertToShares`, `_closeEpoch`
- Internal/private parameters: `_` prefix → `function _mint(address _to, uint256 _amount)`
- Public/external parameters: no prefix → `function deposit(uint256 assets, address receiver)`
- Interfaces: `I` prefix → `IVault`, `IToken`
- Events: PascalCase past tense → `DepositApproved`, `SharesMinted`
- Custom errors: `ContractName__ErrorName` → `Vault__NotAuthorized`, `Vault__InsufficientBalance`
- Constants: SCREAMING_SNAKE_CASE → `MAX_SUPPLY`, `BASIS_POINTS`
- Storage variables: `s_` prefix → `s_totalShares`, `s_lastEpochTimestamp`
- Immutable variables: `i_` prefix → `i_owner`, `i_asset`

### Layout of File (always)
```
Pragma statements
Import statements
Events
Errors
Interfaces
Libraries
Contracts
```

### Layout of Contract (always)
```
Type declarations
State variables
Events
Errors
Modifiers
constructor
receive (if exists)
fallback (if exists)
external state-changing functions
external view/pure functions
public state-changing functions
public view/pure functions
internal state-changing functions
internal view/pure functions
private functions
```

### Section Headers
```solidity
/*//////////////////////////////////////////////////////////////
                    INTERNAL STATE-CHANGING FUNCTIONS
//////////////////////////////////////////////////////////////*/
```

### Other Rules
- `revert` with custom errors only — no `require` with strings
- Custom error format: `ContractName__ErrorName()` with double underscore
- Do not initialize variables to default values (`uint256 x;` not `uint256 x = 0;`)
- Prefer named return variables to avoid declaring unnecessary locals:
  ```solidity
  // ✅
  function getBalance() external view returns (uint256 balance) {
      balance = s_balances[msg.sender];
  }
  ```
- Use `msg.sender` directly inside `onlyOwner` functions — not a cached `owner` variable
- Do not copy an entire struct from storage to memory if only a few slots are needed
- Remove unnecessary context structs and variables from them

### NatSpec Security Contact
Every deployed contract must include a security contact:
```solidity
/// @custom:security-contact security@example.com
contract Vault { ... }
```

### Private Keys
**NEVER** store private keys in plaintext. Use Foundry's encrypted keystore:
```bash
cast wallet import mykey --interactive
forge script --account mykey
```
The only acceptable plaintext key is Anvil's default dev key, and it must be marked as such.

---

## OpenZeppelin Patterns

- `Ownable2Step` — default for ownership (not `Ownable`)
- `AccessControl` — multi-role systems
- `ReentrancyGuardTransient` — preferred; fallback to `ReentrancyGuard`
- `Pausable` — emergency stop
- `SafeERC20` — token transfers (handles non-standard ERC20s)
- Upgrades plugin — never reorder storage between upgrades

---

> For gas optimization, upgradability patterns, and CI pipeline see `.claude/dev/solidity-patterns.md`