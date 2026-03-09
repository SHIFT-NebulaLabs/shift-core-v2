# ERC Standards — Solidity

> Load when implementing an ERC standard in Solidity.
> Read alongside `.claude/dev/solidity.md`.
> Always read the canonical EIP before implementing — never guess the interface.

---

## General Rules

- [All ERCs index](https://eips.ethereum.org/erc) — canonical source
- Use OpenZeppelin v5 implementations as base — never reimplement from scratch
- Read the rounding section of each EIP carefully — wrong direction = funds at risk
- Emit every required event — missing events break indexers and integrations
- Implement every required view function — omissions break composability

---

## ERC-20 — Fungible Token

**Canonical**: [EIP-20](https://eips.ethereum.org/EIPS/eip-20)
**OZ base**: `ERC20`, `ERC20Burnable`, `ERC20Permit`

Required interface:
```solidity
function transfer(address to, uint256 amount) external returns (bool);
function transferFrom(address from, address to, uint256 amount) external returns (bool);
function approve(address spender, uint256 amount) external returns (bool);
function allowance(address owner, address spender) external view returns (uint256);
function balanceOf(address account) external view returns (uint256);
function totalSupply() external view returns (uint256);
```

**Rules:**
- Always use `SafeERC20` when calling external ERC-20s — handles non-compliant tokens (no return value, fee-on-transfer)
- Never assume `transfer` returns `true` on external tokens
- `approve` race condition — prefer `increaseAllowance`/`decreaseAllowance` or ERC-2612 permit
- Fee-on-transfer tokens: never assume `amount` received == `amount` sent — check balance delta

---

## ERC-721 — Non-Fungible Token

**Canonical**: [EIP-721](https://eips.ethereum.org/EIPS/eip-721)
**OZ base**: `ERC721`, `ERC721Enumerable`, `ERC721URIStorage`

Required interface:
```solidity
function ownerOf(uint256 tokenId) external view returns (address);
function safeTransferFrom(address from, address to, uint256 tokenId) external;
function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
function transferFrom(address from, address to, uint256 tokenId) external;
function approve(address to, uint256 tokenId) external;
function setApprovalForAll(address operator, bool approved) external;
function getApproved(uint256 tokenId) external view returns (address);
function isApprovedForAll(address owner, address operator) external view returns (bool);
```

**Rules:**
- Prefer `safeTransferFrom` over `transferFrom` — calls `onERC721Received` on contract recipients
- `_safeMint` over `_mint` when minting to unknown addresses
- Never use sequential IDs for sensitive logic — predictable and frontrunnable

---

## ERC-1155 — Multi-Token

**Canonical**: [EIP-1155](https://eips.ethereum.org/EIPS/eip-1155)
**OZ base**: `ERC1155`, `ERC1155Supply`

**Rules:**
- `TransferBatch` event required for batch operations — `TransferSingle` for single
- Implement `onERC1155Received` and `onERC1155BatchReceived` on receiver contracts
- `balanceOfBatch` must return results in the same order as inputs

---

## ERC-4626 — Tokenized Vault (Sync)

**Canonical**: [EIP-4626](https://eips.ethereum.org/EIPS/eip-4626)
**OZ base**: `ERC4626`

### Rounding Rules (critical — wrong direction = exploitable)

| Function | Rounds | Direction |
|---|---|---|
| `deposit(assets)` → shares | down | favors vault |
| `mint(shares)` → assets | up | favors vault |
| `withdraw(assets)` → shares | up | favors vault |
| `redeem(shares)` → assets | down | favors vault |
| `previewDeposit` | down | match `deposit` |
| `previewMint` | up | match `mint` |
| `previewWithdraw` | up | match `withdraw` |
| `previewRedeem` | down | match `redeem` |

**Rules:**
- `totalAssets` must include all protocol-owned assets, not just idle balance
- `preview*` functions must match actual behavior exactly — used by integrators for quotes
- `max*` functions must return 0 when the operation is paused or unavailable
- Inflation attack: seed the vault with a small initial deposit or use virtual shares (OZ v5 default)

```solidity
// ✅ OZ v5 virtual shares — inflation attack mitigation built in
contract MyVault is ERC4626 {
    constructor(IERC20 asset) ERC4626(asset) ERC20("My Vault", "mvTKN") {}
}
```

---

## ERC-7540 — Async Vault

**Canonical**: [EIP-7540](https://eips.ethereum.org/EIPS/eip-7540)

### Three-Phase Lifecycle

```
REQUEST → (epoch) → PROCESS → (claim) → CLAIM
```

**Never collapse phases** — each phase has a distinct state and accounting requirement.

| Phase | User action | Contract action |
|---|---|---|
| REQUEST | `requestDeposit(assets, controller, owner)` | Records pending request, does NOT mint shares |
| PROCESS | Off-chain or keeper triggers epoch | Converts assets → shares at current rate |
| CLAIM | `deposit(0, receiver, controller)` | Mints shares to receiver |

**Rules:**
- Shares must NOT be minted at request time — only at claim
- `pendingDepositRequest` and `claimableDepositRequest` must be correctly separated
- Implement operator pattern if multiple controllers are supported
- `requestId` is per controller — not globally unique by default

---

## ERC-4337 — Account Abstraction

**Canonical**: [EIP-4337](https://eips.ethereum.org/EIPS/eip-4337)

**Rules:**
- **Never implement a custom EntryPoint** — use the canonical deployed one
- `validateUserOp` must return `SIG_VALIDATION_SUCCESS` (0) or `SIG_VALIDATION_FAILED` (1)
- Paymaster logic must be audited separately — it controls gas sponsorship
- Storage access in `validateUserOp` is restricted — only sender's storage allowed

```solidity
// ✅ Canonical EntryPoint — never redeploy
address constant ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
```

---

## Pre-Implementation Checklist

- [ ] Read the canonical EIP — especially rounding and event sections
- [ ] Use OZ base contract — do not reimplement
- [ ] All required functions implemented
- [ ] All required events emitted
- [ ] Rounding direction correct for every function
- [ ] `preview*` matches actual behavior
- [ ] `max*` returns 0 when unavailable

---

## References
- [All ERCs](https://eips.ethereum.org/erc)
- [OpenZeppelin Contracts v5](https://docs.openzeppelin.com/contracts/5.x)
- [ERC-4626 reference implementation](https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC4626.sol)
- [ERC-7540 reference](https://eips.ethereum.org/EIPS/eip-7540)