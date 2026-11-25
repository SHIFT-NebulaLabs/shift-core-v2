// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ILiquidityPool} from "src/interfaces/ILiquidityPool.sol";
import {ISyVault} from "src/interfaces/ISyVault.sol";
import {ITxFlowNavKeeper} from "src/integrations/txflow/ITxFlowNavKeeper.sol";

/// @title TxFlowNavKeeper
/// @author Shift Protocol
/// @notice Runs independently signed TxFlow NAV approvals through the existing Shift V2 epoch settlement.
/// @dev The vault keeps the native venue owner EOA as its allocator. The keeper cannot move funds.
/// @custom:security-contact team@shiftprotocol.xyz
contract TxFlowNavKeeper is ITxFlowNavKeeper, EIP712, ReentrancyGuard {
    /// @notice The bound chain, vault, pool, token or executor is invalid.
    error TxFlowNavKeeper__InvalidBinding();

    /// @notice The caller is outside the operator role.
    error TxFlowNavKeeper__Unauthorized();

    /// @notice The approval has invalid timing, nonce, evidence, state or signature.
    error TxFlowNavKeeper__InvalidApproval();

    /// @notice The vault is in an incompatible settlement state.
    error TxFlowNavKeeper__InvalidVaultState();

    /// @notice Native USDC on Arbitrum One.
    address public constant NATIVE_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    uint256 private constant ARBITRUM_ONE = 42_161;
    uint256 private constant PERFORMANCE_FEE_BPS = 1_500;
    uint64 private constant MAXIMUM_WINDOW = 30 minutes;
    bytes32 private constant EPOCH_APPROVAL_TYPEHASH = keccak256(
        "EpochApproval(uint256 epochEnd,uint256 price,uint256 nonce,uint64 observedAt,uint64 validUntil,bytes32 stateHash,bytes32 evidenceHash)"
    );

    bytes32 private constant CARRY_FORWARD_TYPEHASH = keccak256(
        "CarryForwardApproval(uint256 epochEnd,uint256 price,uint256 nonce,uint64 observedAt,uint64 validUntil,bytes32 stateHash,bytes32 evidenceHash)"
    );

    /// @notice Bound Shift V2 vault.
    ISyVault public immutable vault;
    /// @notice Bound native-USDC liquidity pool.
    ILiquidityPool public immutable pool;
    /// @notice Native TxFlow owner EOA with the Shift V2 allocator role.
    address public immutable executor;
    /// @notice Independent ECDSA NAV approval signer.
    address public immutable navSigner;
    /// @notice Nebula keeper transaction sender.
    address public immutable operator;
    /// @notice Maximum approval observation age in seconds.
    uint64 public immutable maximumNavAge;
    /// @notice Maximum interval between observation and expiration in seconds.
    uint64 public immutable maximumApprovalLifetime;
    /// @notice Next single-use approval nonce.
    uint256 public nonce;

    /// @notice Binds the keeper to one existing Arbitrum Shift V2 vault and two distinct signer roles.
    /// @param vaultAddress The deployed Shift V2 vault.
    /// @param poolAddress The deployed native-USDC liquidity pool paired with the vault.
    /// @param executorAddress The vault's existing native TxFlow owner and allocator EOA.
    /// @param navSignerAddress The independent NAV signer.
    /// @param operatorAddress The keeper transaction sender.
    /// @param maxNavAge The maximum age of NAV evidence.
    /// @param maxApprovalLifetime The maximum lifetime of an approval from observation.
    constructor(
        address vaultAddress,
        address poolAddress,
        address executorAddress,
        address navSignerAddress,
        address operatorAddress,
        uint64 maxNavAge,
        uint64 maxApprovalLifetime
    ) EIP712("Shift TxFlow NAV Keeper", "1") {
        if (
            block.chainid != ARBITRUM_ONE || executorAddress == address(0) || navSignerAddress == address(0)
                || operatorAddress == address(0) || executorAddress == navSignerAddress
                || executorAddress == operatorAddress || navSignerAddress == operatorAddress || maxNavAge == 0
                || maxNavAge > MAXIMUM_WINDOW || maxApprovalLifetime == 0 || maxApprovalLifetime > MAXIMUM_WINDOW
        ) revert TxFlowNavKeeper__InvalidBinding();

        vault = ISyVault(vaultAddress);
        pool = ILiquidityPool(poolAddress);
        executor = executorAddress;
        navSigner = navSignerAddress;
        operator = operatorAddress;
        maximumNavAge = maxNavAge;
        maximumApprovalLifetime = maxApprovalLifetime;
        _checkBinding();
        if (IERC20Metadata(NATIVE_USDC).decimals() != 6) revert TxFlowNavKeeper__InvalidBinding();
    }

    /// @inheritdoc ITxFlowNavKeeper
    function settleEpoch(EpochApproval calldata approval, bytes calldata signature) external nonReentrant {
        _checkApproval(approval);
        uint256 supply = vault.effectiveSupply();
        if (
            (approval.epochEnd == type(uint256).max && (approval.price != 0 || supply != 0))
                || (approval.price == 0 && supply != 0)
        ) revert TxFlowNavKeeper__InvalidVaultState();
        _consume(approval, signature, approvalDigest(approval));
    }

    /// @inheritdoc ITxFlowNavKeeper
    function carryForwardEpoch(EpochApproval calldata approval, bytes calldata signature) external nonReentrant {
        _checkApproval(approval);
        if (
            approval.price != 0 || vault.stalePriceEpochs() == 0 || vault.effectiveSupply() == 0
                || vault.latestSharePrice() == 0
        ) revert TxFlowNavKeeper__InvalidVaultState();
        _consume(approval, signature, carryForwardDigest(approval));
        emit EpochPriceCarriedForward(approval.nonce, approval.epochEnd, vault.latestSharePrice());
    }

    function _checkApproval(EpochApproval calldata approval) private view {
        if (msg.sender != operator) revert TxFlowNavKeeper__Unauthorized();
        _checkBinding();
        if (
            vault.keeper() != address(this) || vault.allocatorActive()
                || vault.performanceFeeBps() != PERFORMANCE_FEE_BPS || vault.maintenanceFeeBps() != 0
                || vault.fastRedeemCapBps() > 1_000
        ) revert TxFlowNavKeeper__InvalidVaultState();

        if (
            approval.nonce != nonce || approval.epochEnd != vault.epochEnd() || approval.observedAt == 0
                || approval.observedAt > block.timestamp || block.timestamp - approval.observedAt > maximumNavAge
                || approval.validUntil <= block.timestamp
                || approval.validUntil - approval.observedAt > maximumApprovalLifetime || approval.evidenceHash == 0
                || approval.stateHash != stateHash()
        ) revert TxFlowNavKeeper__InvalidApproval();
    }

    function _consume(EpochApproval calldata approval, bytes calldata signature, bytes32 digest) private {
        if (ECDSA.recover(digest, signature) != navSigner) revert TxFlowNavKeeper__InvalidApproval();

        ++nonce;
        vault.epochSettle(approval.price);
        emit EpochApprovalConsumed(approval.nonce, approval.epochEnd, approval.price, approval.evidenceHash);
    }

    /// @inheritdoc ITxFlowNavKeeper
    function stateHash() public view returns (bytes32 checkpoint) {
        (uint256 poolContribution, uint256 strategyReserved) = vault.tvlComponents();
        uint256 pendingDeposits = vault.pendingDepositAssets();
        uint256 claimableRedeems = vault.claimableRedeemAssets();
        uint256 poolBalance = IERC20Metadata(NATIVE_USDC).balanceOf(address(pool));
        if (poolBalance + strategyReserved != pendingDeposits + claimableRedeems + poolContribution) {
            revert TxFlowNavKeeper__InvalidBinding();
        }

        bytes32 inventory = keccak256(
            abi.encode(
                IERC20Metadata(NATIVE_USDC).balanceOf(executor),
                poolBalance,
                poolContribution,
                strategyReserved,
                pendingDeposits,
                vault.totalClaimableDeposits(),
                claimableRedeems,
                // redeemDue is derived from pendingRedeemShares and latestSharePrice.
                vault.pendingRedeemShares(),
                vault.effectiveSupply()
            )
        );
        bytes32 pricing = keccak256(
            abi.encode(
                vault.latestSharePrice(),
                vault.latestHwm(),
                vault.allocatorActive(),
                vault.performanceFeeBps(),
                vault.maintenanceFeeBps(),
                vault.fastRedeemEnabled(),
                vault.fastRedeemCapBps(),
                vault.fastRedeemFeeBps(),
                vault.feeRecipient(),
                vault.maxSharePriceDelta(),
                vault.stalePriceEpochs(),
                vault.maxStalePriceEpochs()
            )
        );
        (uint256 lastSettledEpoch,,,, uint256 lastSettledAt,) = vault.latestPerformance();
        return keccak256(abi.encode(vault.epochEnd(), lastSettledEpoch, lastSettledAt, inventory, pricing));
    }

    /// @inheritdoc ITxFlowNavKeeper
    function approvalDigest(EpochApproval calldata approval) public view returns (bytes32 digest) {
        return _hashTypedDataV4(keccak256(abi.encode(EPOCH_APPROVAL_TYPEHASH, approval)));
    }

    /// @inheritdoc ITxFlowNavKeeper
    function carryForwardDigest(EpochApproval calldata approval) public view returns (bytes32 digest) {
        return _hashTypedDataV4(keccak256(abi.encode(CARRY_FORWARD_TYPEHASH, approval)));
    }

    function _checkBinding() private view {
        if (
            block.chainid != ARBITRUM_ONE || address(vault).code.length == 0 || address(pool).code.length == 0
                || NATIVE_USDC.code.length == 0 || executor.code.length != 0 || vault.asset() != NATIVE_USDC
                || pool.asset() != NATIVE_USDC || pool.vault() != address(vault) || vault.allocator() != executor
        ) revert TxFlowNavKeeper__InvalidBinding();
    }
}
