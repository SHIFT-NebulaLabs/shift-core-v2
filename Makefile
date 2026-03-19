# Shift Core V2 — Makefile
# Usage: make <target>
# Variables are loaded from .env automatically.
# All deploy/wire targets use --interactives 1s 1: Foundry will prompt for the private key.

# Load .env if it exists (- prefix suppresses error when missing).
-include .env
export

# .PHONY declares targets that are not files — Make always runs them
# even if a file with the same name happens to exist in the directory.
.PHONY: help build test test-v coverage clean \
        deploy-singletons deploy-vault \
        deploy-mock-token deploy-adapter deploy-peer \
        wire-options-home wire-options-remote \
        wire-ratelimit \
        wire-libs-home wire-libs-remote \
        wire-dvn-home wire-dvn-remote \
        wire-peers-home wire-peers-remote \
        verify verify-oft-home verify-oft-remote \
        verify-dvn-home verify-dvn-remote \
        bridge-send bridge-return

# ─── Default ──────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "  Shift Core V2"
	@echo ""
	@echo "  Dev"
	@echo "    make build            — compile all contracts"
	@echo "    make test             — run full test suite"
	@echo "    make test-v           — run tests (verbose)"
	@echo "    make coverage         — generate lcov coverage report"
	@echo "    make clean            — remove build artifacts"
	@echo ""
	@echo "  Deploy (protocol)  — set RPC_URL in .env"
	@echo "    make deploy-singletons        — AddressRegistry + AdminGateway + Hub"
	@echo "    make deploy-vault             — SyShare + LiquidityPool + SyVault"
	@echo "    make activate-vault-schedule  — schedule Pending -> Active transition (timelock)"
	@echo "    make activate-vault-execute   — execute after TIMELOCK_DELAY has elapsed"
	@echo ""
	@echo "  Deploy (OFT bridge)  — set HOME_RPC / REMOTE_RPC in .env"
	@echo "    make deploy-mock-token   — mintable ERC-20 stand-in (testnet only)"
	@echo "    make deploy-adapter      — SyOFTAdapter on home chain"
	@echo "    make deploy-peer         — SySharePeer on remote chain"
	@echo ""
	@echo "  Wire (OFT bridge)  — run in this order; set HOME_RPC / REMOTE_RPC in .env"
	@echo "    make wire-options-home   — 1. enforced gas options on home chain"
	@echo "    make wire-options-remote — 1. enforced gas options on remote chain"
	@echo "    make wire-ratelimit      — 2. outbound rate limit (adapter, home chain)"
	@echo "    make wire-libs-home      — 3. set SendUln302 on home chain (mainnet)"
	@echo "    make wire-libs-remote    — 3. set ReceiveUln302 on remote chain (mainnet)"
	@echo "    make wire-dvn-home       — 4. DVN send config on home chain (mainnet)"
	@echo "    make wire-dvn-remote     — 4. DVN receive config on remote chain (mainnet)"
	@echo "    make wire-peers-home     — 5. register peers on home chain"
	@echo "    make wire-peers-remote   — 5. register peers on remote chain (opens channel — LAST)"
	@echo ""
	@echo "  Verify (read-only)"
	@echo "    make verify              — verify full protocol deployment (set RPC_URL)"
	@echo "    make verify-oft-home     — verify adapter wiring on home chain"
	@echo "    make verify-oft-remote   — verify peer wiring on remote chain"
	@echo "    make verify-dvn-home     — print A->B send + B->A receive DVN config (home chain)"
	@echo "    make verify-dvn-remote   — print A->B receive + B->A send DVN config (remote chain)"
	@echo ""
	@echo "  Testnet bridge  — set HOME_RPC / REMOTE_RPC in .env"
	@echo "    make bridge-send         — send syShare home -> remote"
	@echo "    make bridge-return       — return syShare remote -> home"
	@echo ""

# ─── Dev ──────────────────────────────────────────────────────────────────────

build:
	forge build

test:
	forge test --summary

test-v:
	forge test -vvv

coverage:
	forge coverage --report lcov

clean:
	forge clean

# ─── Deploy — Protocol ────────────────────────────────────────────────────────

deploy-singletons:
	forge script script/protocol/DeploySingletons.s.sol \
		--rpc-url $(RPC_URL) --broadcast --verify --interactives 1

deploy-vault:
	forge script script/protocol/DeployVault.s.sol \
		--rpc-url $(RPC_URL) --broadcast --verify --interactives 1

activate-vault-schedule:
	forge script script/protocol/ActivateVault.s.sol:ActivateVault_Schedule \
		--rpc-url $(RPC_URL) --broadcast --interactives 1

activate-vault-execute:
	forge script script/protocol/ActivateVault.s.sol:ActivateVault_Execute \
		--rpc-url $(RPC_URL) --broadcast --interactives 1

# ─── Deploy — OFT Bridge ──────────────────────────────────────────────────────

deploy-mock-token:
	forge script script/helpers/DeployMockToken.s.sol:DeployMockToken \
		--rpc-url $(HOME_RPC) --broadcast --verify --interactives 1

deploy-adapter:
	forge script script/oft/DeployOFTAdapter.s.sol \
		--rpc-url $(HOME_RPC) --broadcast --verify --interactives 1

deploy-peer:
	forge script script/oft/DeployOFTPeer.s.sol \
		--rpc-url $(REMOTE_RPC) --broadcast --verify --interactives 1

# ─── Wire — OFT Bridge ────────────────────────────────────────────────────────
# Correct order: options → ratelimit → libs → dvn → peers (peers LAST — opens channel).

wire-options-home:
	forge script script/helpers/WireOFT_SetOptions.s.sol:WireOFT_SetOptions_Home \
		--rpc-url $(HOME_RPC) --broadcast --interactives 1

wire-options-remote:
	forge script script/helpers/WireOFT_SetOptions.s.sol:WireOFT_SetOptions_Remote \
		--rpc-url $(REMOTE_RPC) --broadcast --interactives 1

wire-ratelimit:
	forge script script/helpers/WireOFT_SetRateLimit.s.sol:WireOFT_SetRateLimit \
		--rpc-url $(HOME_RPC) --broadcast --interactives 1

# ─── Library selection (mainnet — optional if using default libs) ──────────────

wire-libs-home:
	forge script script/helpers/WireOFT_SetLibs.s.sol:WireOFT_SetLibs_Home \
		--rpc-url $(HOME_RPC) --broadcast --interactives 1

wire-libs-remote:
	forge script script/helpers/WireOFT_SetLibs.s.sol:WireOFT_SetLibs_Remote \
		--rpc-url $(REMOTE_RPC) --broadcast --interactives 1

# ─── DVN config (mainnet security — run after wire-libs, before wire-peers) ───

wire-dvn-home:
	forge script script/helpers/WireOFT_SetDVN.s.sol:WireOFT_SetDVN_Home \
		--rpc-url $(HOME_RPC) --broadcast --interactives 1

wire-dvn-remote:
	forge script script/helpers/WireOFT_SetDVN.s.sol:WireOFT_SetDVN_Remote \
		--rpc-url $(REMOTE_RPC) --broadcast --interactives 1

# ─── Peers (opens the live channel — always last) ─────────────────────────────

wire-peers-home:
	forge script script/helpers/WireOFT_SetPeers.s.sol:WireOFT_SetPeers_Home \
		--rpc-url $(HOME_RPC) --broadcast --interactives 1

wire-peers-remote:
	forge script script/helpers/WireOFT_SetPeers.s.sol:WireOFT_SetPeers_Remote \
		--rpc-url $(REMOTE_RPC) --broadcast --interactives 1

# ─── Verify (read-only) ───────────────────────────────────────────────────────

verify:
	forge script script/helpers/VerifyDeployment.s.sol \
		--rpc-url $(RPC_URL)

verify-oft-home:
	forge script script/helpers/VerifyOFT.s.sol:VerifyOFT_Home \
		--rpc-url $(HOME_RPC)

verify-oft-remote:
	forge script script/helpers/VerifyOFT.s.sol:VerifyOFT_Remote \
		--rpc-url $(REMOTE_RPC)

verify-dvn-home:
	forge script script/helpers/VerifyDVN.s.sol:VerifyDVN_Home \
		--rpc-url $(HOME_RPC)

verify-dvn-remote:
	forge script script/helpers/VerifyDVN.s.sol:VerifyDVN_Remote \
		--rpc-url $(REMOTE_RPC)

# ─── Testnet Bridge ───────────────────────────────────────────────────────────

bridge-send:
	forge script script/helpers/TestBridge.s.sol:TestBridge_Send \
		--rpc-url $(HOME_RPC) --broadcast --interactives 1

bridge-return:
	forge script script/helpers/TestBridge.s.sol:TestBridge_Return \
		--rpc-url $(REMOTE_RPC) --broadcast --interactives 1
