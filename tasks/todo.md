# Setup — Project Infrastructure

## Lib & Config
- [x] Update `foundry.toml` — solc 0.8.28, cancun EVM, optimizer 200 runs, remappings
- [x] Install `openzeppelin-contracts` v5.6.1
- [x] Install `layerzero-labs/devtools`
- [x] Install `layerzero-labs/LayerZero-v2`
- [x] Install `solidity-bytes-utils` (git submodule)
- [x] Remove Counter.sol / Counter.t.sol / Counter.s.sol placeholders

## Src Scaffold
- [x] `src/types/Types.sol` — VaultState, CycleType, CycleState, RedeemCycle, SharePriceSnapshot
- [x] `src/types/Errors.sol` — all custom errors
- [x] `src/types/Constants.sol` — epoch timing, math, LZ, EIP-165 IDs, roles
- [x] `src/interfaces/ISyVault.sol` — full EIP-7540 + EIP-4626 + EIP-7575 interface
- [x] `src/interfaces/ILiquidityPool.sol`
- [x] `src/interfaces/ISyShare.sol`
- [x] `src/interfaces/IHub.sol`
- [x] `src/interfaces/IAddressRegistry.sol`
- [x] `src/syShare.sol` — complete (ERC20, onlyVault mint/burn, EIP-7575 vault())
- [x] `src/LiquidityPool.sol` — skeleton (deployCapital/returnCapital/allocatorAllowance)
- [x] `src/Hub.sol` — skeleton (all user write routes, vault state checks)
- [x] `src/AddressRegistry.sol` — skeleton (storage + onlyAdminGateway writes)
- [x] `src/AdminGateway.sol` — skeleton (TimelockController + onlyTimelock + lifecycle)
- [x] `src/syVault.sol` — skeleton (full state layout, view functions, TODO stubs for complex logic)
- [x] `src/crosschain/syOFTAdapter.sol` — skeleton (OFTAdapter + rate limiting)
- [x] `src/crosschain/sySharePeer.sol` — skeleton (OFT peer)

## Implementation (next pass)
- [x] `syVault.epochSettle()` — share price validation, fee collection, deposit settlement
- [x] `syVault.requestDeposit()` — whitelist, maxTVL, transfer to pool
- [x] `syVault.deposit()` / `mint()` — claim minting logic
- [x] `syVault.maxDeposit()` — pause + whitelist + TVL cap + stale price guard
- [x] Supporting: ILiquidityPool.transferTo, LiquidityPool.transferTo, LiquidityPool.allocatorAllowance fix
- [x] Supporting: Hub._requireOwnerOrOperator, Hub.setOperator forwarding fix
- [x] Supporting: ISyVault.setOperator controller param, syVault.setOperator updated
- [x] `syVault.requestRedeem()` / `requestFastRedeem()` — cycle assignment, share locking
- [x] `syVault.cancelRedeemRequest()` / `cancelFastRedeemRequest()`
- [x] `syVault.settleRedeemBatch()` — cycleRate, share burn, fast fee deduction
- [x] `syVault.recordReturnedAmount()` — allocator sets returnedAmount before settle
- [x] `syVault.redeem()` / `withdraw()` — claim asset transfer
- [x] `syVault.maxRedeem()` — claimable shares
- [x] syVault.setAllocatorActive(bool) — onlyAllocator, explicit signal for mid-bridge/mid-operation phases
- [x] Pause functions (GUARDIAN/ADMIN) on syVault + AdminGateway forwarders
- [x] AdminGateway parameter setters (setKeeper, setAllocator, setFeeRecipient, fees, whitelists)
- [x] syVault role view functions (keeper, allocator, feeRecipient, adminGateway, all params, isPaused)
- [x] syVault role/param setters with onlyAdminGateway modifier
- [x] i_adminGateway immutable added to syVault constructor
- [x] Full spec review — read SPEC.md line by line, flag every deviation for discussion before touching code
- [x] Spec fix: fast redeem fee moved to claim time (redeem/withdraw), per-controller with whitelist
- [x] Spec fix: feeExemptWhitelist removed — all users pay maintenance and performance fees
- [x] Spec fix: preview functions now revert with SyVault__AsyncVault() custom error
- [ ] Manual code review by user — full read-through of all src/ files before proceeding
- [ ] Claude code review — independent pass over all src/ files after user review, flag any issues and check for any not used.
- [ ] Forge build review — address any compiler warnings, linter notes, and suggestions from `forge build`
- [ ] Tests (unit, fuzz, invariant, crosschain)
- [ ] Solidity audit (/audit-solidity)
- [ ] Deploy scripts
- [ ] Makefile
