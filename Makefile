# Shift Core V2 — Makefile
# Usage: make <target>
# Variables are loaded from .env automatically.
# All deploy/wire targets use --interactive: Foundry will prompt for the private key.

# Load .env if it exists (- prefix suppresses error when missing).
-include .env
export

# .PHONY declares targets that are not files — Make always runs them
# even if a file with the same name happens to exist in the directory.
.PHONY: help build test test-v coverage clean \
        deploy-singletons deploy-vault \
        deploy-adapter deploy-peer \
        wire-options wire-peers wire-ratelimit \
        verify verify-oft \
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
	@echo "    make deploy-singletons   — AddressRegistry + AdminGateway + Hub"
	@echo "    make deploy-vault        — SyShare + LiquidityPool + SyVault"
	@echo ""
	@echo "  Deploy (OFT bridge)  — set RPC_URL in .env"
	@echo "    make deploy-adapter      — SyOFTAdapter on home chain"
	@echo "    make deploy-peer         — SySharePeer on remote chain"
	@echo ""
	@echo "  Wire (OFT bridge)  — set RPC_URL in .env to the target chain"
	@echo "    make wire-options        — set enforced gas options"
	@echo "    make wire-peers          — register peers (opens channel)"
	@echo "    make wire-ratelimit      — set outbound rate limit (adapter)"
	@echo ""
	@echo "  Verify (read-only)  — set RPC_URL in .env"
	@echo "    make verify              — verify full protocol deployment"
	@echo "    make verify-oft          — verify OFT wiring"
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
		--rpc-url $(RPC_URL) --broadcast --verify --interactive

deploy-vault:
	forge script script/protocol/DeployVault.s.sol \
		--rpc-url $(RPC_URL) --broadcast --verify --interactive

# ─── Deploy — OFT Bridge ──────────────────────────────────────────────────────

deploy-adapter:
	forge script script/oft/DeployOFTAdapter.s.sol \
		--rpc-url $(RPC_URL) --broadcast --verify --interactive

deploy-peer:
	forge script script/oft/DeployOFTPeer.s.sol \
		--rpc-url $(RPC_URL) --broadcast --verify --interactive

# ─── Wire — OFT Bridge ────────────────────────────────────────────────────────
# Run each step on the correct chain (home for adapter, remote for peer).
# Always SetOptions before SetPeers — SetPeers opens the live channel.

wire-options:
	forge script script/helpers/WireOFT.s.sol:WireOFT_SetOptions \
		--rpc-url $(RPC_URL) --broadcast --interactive

wire-peers:
	forge script script/helpers/WireOFT.s.sol:WireOFT_SetPeers \
		--rpc-url $(RPC_URL) --broadcast --interactive

wire-ratelimit:
	forge script script/helpers/WireOFT.s.sol:WireOFT_SetRateLimit \
		--rpc-url $(RPC_URL) --broadcast --interactive

# ─── Verify (read-only) ───────────────────────────────────────────────────────

verify:
	forge script script/helpers/VerifyDeployment.s.sol \
		--rpc-url $(RPC_URL)

verify-oft:
	forge script script/helpers/VerifyOFT.s.sol \
		--rpc-url $(RPC_URL)

# ─── Testnet Bridge ───────────────────────────────────────────────────────────

bridge-send:
	forge script script/helpers/TestBridge.s.sol:TestBridge_Send \
		--rpc-url $(HOME_RPC) --broadcast --interactive

bridge-return:
	forge script script/helpers/TestBridge.s.sol:TestBridge_Return \
		--rpc-url $(REMOTE_RPC) --broadcast --interactive
