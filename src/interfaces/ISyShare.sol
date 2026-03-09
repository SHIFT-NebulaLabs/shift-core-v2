// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  ISyShare
/// @author Shift Protocol
/// @notice Interface for syShare — plain ERC-20 share token.
/// @dev    Mintable and burnable exclusively by the paired syVault. No bridge logic.
///         vault() implements EIP-7575 bidirectional discovery.

interface ISyShare is IERC20 {
    /*//////////////////////////////////////////////////////////////
                       SYVAULT — STATE-CHANGING
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint shares to an address. Only callable by the paired syVault.
    /// @param  to      Recipient of newly minted shares.
    /// @param  amount  Number of shares to mint.
    function mint(address to, uint256 amount) external;

    /// @notice Burn shares from an address. Only callable by the paired syVault.
    /// @param  from    Address whose shares are burned.
    /// @param  amount  Number of shares to burn.
    function burn(address from, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                              VIEW
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the address of the paired syVault.
    /// @dev    Required by EIP-7575 for bidirectional vault/share discovery.
    ///         Called as vault() on syShare; share() on syVault returns this contract's address.
    function vault() external view returns (address);
}
