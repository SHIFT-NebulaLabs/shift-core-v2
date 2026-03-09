# Audit — Report

> Always load alongside `audit-solidity.md` or `audit-cairo.md`.

---

## Audit Process

1. **Read `SPEC.md` first** — if it exists in the repo root, read it before touching any code. It is the source of truth. If code contradicts the spec, report it as a finding with exact location — do not change either until instructed.
2. **Map the attack surface** — list all external entry points, privileged functions, and fund flows
3. **Run static analysis** — `slither .` (Solidity) or `caracal detect .` (Cairo) before manual review
4. **Check invariants** — identify O(1) properties that must always hold; verify they are encoded or tested
5. **Review by category** using the language-specific checklist
6. **Write findings** — for each issue: location, severity, description, impact, recommendation

---

## Severity Scale

| Level | Definition |
|---|---|
| **Critical** | Direct loss of funds, full access control bypass |
| **High** | Significant loss risk or broken core invariant |
| **Medium** | Limited loss, requires specific conditions |
| **Low** | Best-practice violation, no immediate risk |
| **Informational** | Style, gas, documentation |

---

## Findings Template

```
## [SEV-001] Title

**Severity**: Critical / High / Medium / Low / Informational
**Location**: `contracts/Vault.sol:L123` or `fn withdraw()`

**Description**
What is the issue, explained precisely.

**Impact**
What can an attacker do, and what is the worst-case outcome.

**Proof of Concept** (if applicable)
```solidity
// minimal reproducer
```

**Recommendation**
Concrete fix — code snippet if possible.
```