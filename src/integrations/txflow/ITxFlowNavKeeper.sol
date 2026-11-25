// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title ITxFlowNavKeeper
/// @notice Independent NAV approvals for the standard TxFlow Shift V2 vault.
interface ITxFlowNavKeeper {
    /// @notice Exact EIP-712 approval bound to one observed Arbitrum vault state.
    /// @dev Price is gross raw USDC per 1e18 shares. Timestamps use Unix seconds.
    struct EpochApproval {
        uint256 epochEnd;
        uint256 price;
        uint256 nonce;
        uint64 observedAt;
        uint64 validUntil;
        bytes32 stateHash;
        bytes32 evidenceHash;
    }

    /// @notice Records the independently approved gross price passed to the vault.
    event EpochApprovalConsumed(uint256 indexed nonce, uint256 indexed epochEnd, uint256 price, bytes32 evidenceHash);

    /// @notice Identifies a consumed carry-forward approval and the price retained by the vault.
    event EpochPriceCarriedForward(uint256 indexed nonce, uint256 indexed epochEnd, uint256 sharePrice);

    /// @notice Settles one elapsed epoch or starts the vault with an independently approved checkpoint.
    /// @param approval Exact signed epoch inputs.
    /// @param signature Signature from the configured independent NAV signer.
    function settleEpoch(EpochApproval calldata approval, bytes calldata signature) external;

    /// @notice Retains the stored share price for an elapsed positive-supply epoch with unavailable NAV.
    /// @param approval A zero-price carry-forward checkpoint with independent custody and outage evidence.
    /// @param signature Independent NAV signer signature for the carry-forward action.
    function carryForwardEpoch(EpochApproval calldata approval, bytes calldata signature) external;

    /// @notice EIP-712 digest for carrying forward the previous price, scoped to this guard.
    /// @param approval The zero-price checkpoint for this specific epoch.
    /// @return digest Action-specific digest for the independent signer.
    function carryForwardDigest(EpochApproval calldata approval) external view returns (bytes32 digest);

    /// @notice Current Arbitrum state checkpoint used by the NAV approval.
    /// @return checkpoint Deterministic hash of the current vault, pool and executor observations.
    function stateHash() external view returns (bytes32 checkpoint);

    /// @notice Canonical EIP-712 digest for the given approval.
    /// @param approval Approval inputs including the evidence hash and single-use nonce.
    /// @return digest The digest to be signed by the independent NAV signer.
    function approvalDigest(EpochApproval calldata approval) external view returns (bytes32 digest);
}
