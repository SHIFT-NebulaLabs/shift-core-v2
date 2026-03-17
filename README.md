# Shift Core V2

EIP-7540 async yield vault protocol with LayerZero V2 omnichain bridging.

---

## Prerequisites

- [Foundry](https://getfoundry.sh/) installed
- Copy `.env.example` to `.env` and fill in all required values
- Private key is **never** stored in `.env` — Foundry prompts for it at runtime via `--interactives 1`

```bash
cp .env.example .env
```

---

## Dev

```bash
make build       # compile all contracts
make test        # run full test suite
make test-v      # run tests verbose
make coverage    # generate lcov coverage report
make clean       # remove build artifacts
```

---

## Architecture

The protocol has two independent deployment layers:

```
┌────────────────────────────────────────────────────────────┐
│  PROTOCOL (one set per chain)                              │
│  AddressRegistry + AdminGateway + Hub                      │
│                                                            │
│  VAULT (one set per yield strategy)                        │
│  SyShare + LiquidityPool + SyVault                         │
└────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────┐
│  OFT BRIDGE (per vault, per remote chain)                  │
│                                                            │
│  HOME CHAIN          ←────────────────→  REMOTE CHAIN      │
│  SyOFTAdapter                            SySharePeer       │
│  (lock / unlock syShare)                 (mint / burn)     │
└────────────────────────────────────────────────────────────┘
```

**Singletons** (`deploy-singletons`) are deployed once and shared by all vaults.
**Each vault** gets its own adapter on the home chain and its own peer on each remote chain.

---

## Deployment — Protocol

### Step 1 — Deploy singletons (once per chain)

```bash
make deploy-singletons   # RPC_URL in .env
```

Deploys `AddressRegistry`, `AdminGateway`, and `Hub`.
Fill the resulting addresses into `.env` (`REGISTRY`, `ADMIN_GATEWAY`, `HUB`).

### Step 2 — Deploy vault

```bash
make deploy-vault        # RPC_URL in .env
```

Deploys `SyShare`, `LiquidityPool`, and `SyVault` for one yield strategy.
Fill the resulting `SYSHARE` and `VAULT_ID` into `.env`.

**Multiple vaults:** repeat Step 2 with different `VAULT_ASSET`, `VAULT_SHARE_NAME`, `VAULT_SHARE_SYMBOL` for each new strategy. Singletons are reused.

---

## Deployment — OFT Bridge

Each vault needs a bridge independently. The adapter locks/unlocks on the home chain; the peer mints/burns on each remote chain.

### Step 3 — Deploy OFT adapter (home chain, once per vault)

```bash
make deploy-adapter      # HOME_RPC in .env, SYSHARE must be filled
```

Fill `ADAPTER` into `.env`.

### Step 4 — Deploy OFT peer (each remote chain)

```bash
make deploy-peer         # REMOTE_RPC in .env
```

Fill `PEER` into `.env`.

**Multiple remote chains:** run `deploy-peer` once per remote chain with the matching `REMOTE_RPC`. Each run produces a different `PEER` address — save each one before moving on.

---

## Wiring — OFT Bridge

**Order matters.** Wiring opens a live message channel at `wire-peers`. Every setting that governs security (options, rate limit, DVN config) must be locked in first or messages may be blocked or arrive with wrong parameters.

```
wire-options  →  wire-ratelimit  →  wire-libs  →  wire-dvn  →  wire-peers  (LAST)
```

### Step 5 — Enforced options

Sets the minimum gas allocated for `lzReceive` on the destination. Must be set on both ends before the channel opens.

```bash
make wire-options-home     # HOME_RPC in .env
make wire-options-remote   # REMOTE_RPC in .env
```

Controlled by `ENFORCED_GAS` in `.env` (default 80 000).

### Step 6 — Rate limit (adapter only)

Caps outbound token flow per time window. Protects the home chain escrow from rapid drain.

```bash
make wire-ratelimit        # HOME_RPC in .env
```

Controlled by `RATE_LIMIT_AMOUNT` and `RATE_LIMIT_WINDOW` in `.env`.

### Step 7 — MessageLib selection (mainnet only)

Explicitly pins `SendUln302` / `ReceiveUln302` to the OFT contracts on the LayerZero Endpoint. Skip on testnet — the defaults already point to the right library.

```bash
make wire-libs-home        # HOME_RPC in .env
make wire-libs-remote      # REMOTE_RPC in .env
```

Uses `SEND_LIB` and `RECEIVE_LIB` from `.env`.

### Step 8 — DVN + Executor config (mainnet only)

Sets which DVNs must verify each message and which Executor pays gas on the destination. The send config (home) and receive config (remote) **must match exactly** — same DVN set, same block confirmations — or messages will be permanently blocked.

```bash
make wire-dvn-home         # HOME_RPC in .env   (send config)
make wire-dvn-remote       # REMOTE_RPC in .env (receive config)
```

Key `.env` variables:

| Variable            | Description                                         |
|---------------------|-----------------------------------------------------|
| `DVN_COUNT`         | `1` testnet / `2` mainnet                           |
| `DVN_HOME`          | LZ DVN address on the **home** chain                |
| `DVN_REMOTE`        | LZ DVN address on the **remote** chain              |
| `DVN_HOME_2`        | Second DVN on home chain (mainnet, `DVN_COUNT=2`)   |
| `DVN_REMOTE_2`      | Second DVN on remote chain (mainnet, `DVN_COUNT=2`) |
| `EXECUTOR`          | LayerZero Executor on home chain                    |
| `BLOCK_CONFIRMATIONS` | Must be identical on both sides                   |

DVN addresses for each chain: https://docs.layerzero.network/v2/deployments/chains

### Step 9 — Register peers (opens the channel — LAST)

Registers the counterparty contract address on each side. This is the step that opens the live message channel. Run it last.

```bash
make wire-peers-home       # HOME_RPC in .env
make wire-peers-remote     # REMOTE_RPC in .env  ← channel is live after this
```

`wire-peers-remote` is the point of no return. After it runs, messages can flow.

---

## Wiring Multiple Peers

When a vault bridges to more than one remote chain (e.g., Base Sepolia + Optimism Sepolia), wire each pair independently by overriding the relevant env vars on the command line:

```bash
# Wire Base Sepolia peer
make wire-options-remote  REMOTE_RPC=https://sepolia.base.org         PEER=0xABC... ADAPTER_EID=40231 PEER_EID=40245
make wire-ratelimit                                                    PEER_EID=40245
make wire-dvn-remote      REMOTE_RPC=https://sepolia.base.org         PEER=0xABC... RECEIVE_LIB=0x... DVN_REMOTE=0x...
make wire-peers-remote    REMOTE_RPC=https://sepolia.base.org         PEER=0xABC... ADAPTER_EID=40231

# Wire Optimism Sepolia peer
make wire-options-remote  REMOTE_RPC=https://sepolia.optimism.io      PEER=0xDEF... ADAPTER_EID=40231 PEER_EID=40232
make wire-dvn-remote      REMOTE_RPC=https://sepolia.optimism.io      PEER=0xDEF... RECEIVE_LIB=0x... DVN_REMOTE=0x...
make wire-peers-remote    REMOTE_RPC=https://sepolia.optimism.io      PEER=0xDEF... ADAPTER_EID=40231
```

Command-line variable assignments override `.env` — they have the highest Make precedence.
The adapter only needs `wire-options-home`, `wire-ratelimit`, `wire-libs-home`, `wire-dvn-home` run once per new peer EID (or re-run the same commands with `PEER_EID` overridden).

---

## Wiring Multiple Vaults

Each vault has its own adapter and peer. Wire them completely independently — there is no shared state between vaults in the bridge layer.

```bash
# Vault 1 — USDC
ADAPTER=0x<vault1-adapter> PEER=0x<vault1-peer> make wire-options-home   HOME_RPC=...
ADAPTER=0x<vault1-adapter> PEER=0x<vault1-peer> make wire-options-remote REMOTE_RPC=...
# ... continue through wire-peers for vault 1 ...

# Vault 2 — WETH
ADAPTER=0x<vault2-adapter> PEER=0x<vault2-peer> make wire-options-home   HOME_RPC=...
ADAPTER=0x<vault2-adapter> PEER=0x<vault2-peer> make wire-options-remote REMOTE_RPC=...
# ... continue through wire-peers for vault 2 ...
```

---

## Verification

Run after each wiring step to confirm state before proceeding.

```bash
make verify              # full protocol deployment (RPC_URL)
make verify-oft-home     # adapter: token, owner, peers, options, rate limit (HOME_RPC)
make verify-oft-remote   # peer: owner, peers, options, name/symbol (REMOTE_RPC)
make verify-dvn-home     # print active send DVN + executor config (HOME_RPC)
make verify-dvn-remote   # print active receive DVN config (REMOTE_RPC)
```

Run `verify-dvn-home` and `verify-dvn-remote` side-by-side and confirm:
- `confirmations` match on both sides
- `requiredDVNCount` and `requiredDVNs` match (same logical DVNs, different chain addresses)
- `optionalDVNCount` is `255` (NIL — no optional DVNs)

A mismatch in any of these will permanently block messages until corrected.

---

## Testnet Bridge Test

After all wiring is complete, test the full round-trip:

```bash
make bridge-send    # HOME_RPC — sends BRIDGE_AMOUNT from home to remote
make bridge-return  # REMOTE_RPC — returns tokens from remote to home
```

Prints the transaction GUID and a LayerZero Scan link to track delivery.

> **Testnet only.** Requires the deployer wallet to hold `BRIDGE_AMOUNT` of the vault share token on the home chain. Use `deploy-mock-token` to mint a stand-in if needed.

---

## Full Deployment Checklist

### First vault on a new chain

```
[ ] cp .env.example .env — fill all required fields
[ ] make build
[ ] make test
[ ] make deploy-singletons          → fill REGISTRY, ADMIN_GATEWAY, HUB
[ ] make deploy-vault               → fill SYSHARE, VAULT_ID
[ ] make deploy-adapter             → fill ADAPTER
[ ] make deploy-peer                → fill PEER
[ ] make wire-options-home
[ ] make wire-options-remote
[ ] make wire-ratelimit
[ ] make wire-libs-home             (mainnet only)
[ ] make wire-libs-remote           (mainnet only)
[ ] make wire-dvn-home              (mainnet only)
[ ] make wire-dvn-remote            (mainnet only)
[ ] make verify-dvn-home + verify-dvn-remote — confirm configs match
[ ] make wire-peers-home
[ ] make wire-peers-remote          ← channel live
[ ] make verify-oft-home + verify-oft-remote
[ ] make bridge-send + bridge-return (testnet only)
```

### Additional vault (singletons already deployed)

```
[ ] Update .env — VAULT_ASSET, VAULT_SHARE_NAME, VAULT_SHARE_SYMBOL, etc.
[ ] make deploy-vault               → fill SYSHARE, VAULT_ID
[ ] make deploy-adapter             → fill ADAPTER
[ ] make deploy-peer                → fill PEER
[ ] wire steps 5–9 for this vault
```

### Additional remote chain (adapter already deployed)

```
[ ] Update .env — REMOTE_RPC, PEER_EID, DVN_REMOTE, RECEIVE_LIB
[ ] make deploy-peer                → fill PEER
[ ] make wire-options-remote
[ ] make wire-dvn-remote            (mainnet only)
[ ] make wire-peers-home            (registers new peer on adapter side)
[ ] make wire-peers-remote          ← channel live
[ ] make verify-oft-home + verify-oft-remote
```

---

## Security Notes

- Private keys are never stored in `.env`. All broadcast scripts use `--interactives 1` — Foundry prompts for the key at runtime.
- `OFT_OWNER` (multisig) controls peer registration, options, and DVN config. Transfer ownership to the multisig before going to mainnet.
- `wire-peers-remote` opens the live channel. All security settings must be verified before running it.
- DVN addresses differ per chain but the logical security set must be identical on send and receive sides.
- Rate limit on the adapter (`wire-ratelimit`) is the last line of defense against token drain from the home chain escrow.
