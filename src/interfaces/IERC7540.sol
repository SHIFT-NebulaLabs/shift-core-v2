// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title  IERC7540Deposit
/// @notice Minimal EIP-7540 async deposit interface.
///         Function signatures are verbatim from the EIP — used to derive the correct EIP-165 interface IDs.
interface IERC7540Deposit {
    function requestDeposit(uint256 assets, address controller, address owner)
        external returns (uint256 requestId);

    function pendingDepositRequest(uint256 requestId, address controller)
        external view returns (uint256 pendingAssets);

    function claimableDepositRequest(uint256 requestId, address controller)
        external view returns (uint256 claimableAssets);
}

/// @title  IERC7540Redeem
/// @notice Minimal EIP-7540 async redeem interface.
///         Function signatures are verbatim from the EIP — used to derive the correct EIP-165 interface IDs.
interface IERC7540Redeem {
    function requestRedeem(uint256 shares, address controller, address owner)
        external returns (uint256 requestId);

    function pendingRedeemRequest(uint256 requestId, address controller)
        external view returns (uint256 pendingShares);

    function claimableRedeemRequest(uint256 requestId, address controller)
        external view returns (uint256 claimableShares);
}
