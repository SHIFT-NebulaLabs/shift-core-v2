# CLAUDE.md

> Global rules. Always loaded. Keep it lean — domain files live in `.claude/`.

---

## Spec — Source of Truth

If `SPEC.md` exists in the repo root, **read it at the start of every task** before touching any code.
It is the source of truth for protocol behavior, invariants, and architecture.
Standards and code are secondary to the spec.

If code contradicts the spec:
1. **Do not change anything**
2. Describe exactly where the contradiction is (file, line, function)
3. Explain what the spec says vs what the code does
4. Ask: *"Which is correct — should I fix the code to match the spec, or is the spec outdated?"*
5. Wait for confirmation before touching either

---

## Standards — Load Before Working

Read the relevant file(s) before touching any code:

| Context | Load |
|---|---|
| Writing `.sol` source | `.claude/dev/solidity.md` + `.claude/dev/solidity-patterns.md` + `.claude/dev/solidity-natspec.md` |
| Writing Solidity tests (`*.t.sol`, `test/`) | `.claude/testing/solidity-testing.md` |
| Implementing an ERC — Solidity | `.claude/components/erc-standards-solidity.md` |
| OFT / LayerZero — Solidity | `.claude/components/layerzero-oft-solidity.md` |
| Solidity security audit | `.claude/commands/audit-report.md` + `.claude/commands/audit-solidity.md` |

---

## Workflow

### Plan First (tasks with 3+ steps)
Before touching any code, write a checklist to `tasks/todo.md`:
```
- [ ] step one
- [ ] step two
- [ ] step three
```
Update it as you go. If something goes sideways, stop and re-plan — do not keep pushing.

### Lessons
If the user corrects a mistake, append the pattern to `tasks/lessons.md` so it is not repeated.
Read `tasks/lessons.md` at the start of each session if it exists.

### Verification Before Done
- Run tests and check logs — never mark a task complete without proof it works
- Ask: *"Would a senior engineer approve this?"*
- Clean up temporary files when done

---

## Bug Fixes

**Fix autonomously** (no confirmation needed):
- Compilation errors
- Missing imports
- Type errors
- Tests broken directly by the current change

**Ask before fixing:**
- Any bug with ambiguous intent — it might be intentional behavior
- Fixes that touch more than one file
- Any refactor, even a small one
- Anything that changes an interface or function signature

---

## Uncertainty — Propose, Then Ask

Never silently guess. Write your best-guess implementation, then flag the assumption:

- *"This looks like ERC-7540 — I implemented that interface, confirm?"*
- *"This moves funds — I added ReentrancyGuard and CEI, does that match your intent?"*
- *"No direct Cairo equivalent — I chose approach A. Alternative is B. Which do you prefer?"*

---

## Context Before Coding

| Situation | Action |
|---|---|
| New contract / module from scratch | Ask: *"Any specs, audit reports, or interfaces I should read first?"* |
| Adding to existing codebase | Read the code directly — ask only if something is genuinely unclear |
| Bug fix | Read failing test + relevant code — no doc needed |
| Migration Solidity → Cairo | Ask for original Solidity + any specs |

---

## MCP Servers

| When | Server |
|---|---|
| Working on LayerZero / OFT | `https://docs.layerzero.network/mcp` |

Connect via Claude Code: `claude mcp add layerzero https://docs.layerzero.network/mcp`
Use for: DVN addresses, deployment steps, SDK calls, latest package versions — anything that changes between releases.

---

## Core Principles

- **Simplicity first** — make every change as simple as possible
- **Minimal impact** — only touch what is necessary; do not introduce unrelated changes
- **No laziness** — find root causes; no temporary fixes; senior engineer standards