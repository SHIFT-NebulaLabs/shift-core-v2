// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20}         from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ISyShare}      from "src/interfaces/ISyShare.sol";
import {SyShare__NotVault} from "src/types/Errors.sol";

/// @title  syShare
/// @author Shift Protocol
/// @custom:security-contact team@shiftprotocol.xyz
/// @notice Per-vault ERC-20 share token representing a pro-rata claim on vault assets.
/// @dev    Mintable and burnable exclusively by the paired syVault.
///         No bridge logic — kept as a plain ERC-20 so it can be deployed on any chain.
///         syOFTAdapter (Chain A) wraps this token for LayerZero bridging.
///         vault() implements EIP-7575 bidirectional vault/share discovery.
contract SyShare is ERC20, ERC20Burnable, ISyShare {
    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Address of the paired syVault — the only minter and burner.
    address private immutable i_vault;

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Restricts function to the paired syVault.
    modifier onlyVault() { _onlyVault(); _; }

    function _onlyVault() internal view {
        if (msg.sender != i_vault) revert SyShare__NotVault();
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _name    Token name (e.g. "Shift Yield Share — USDC").
    /// @param _symbol  Token symbol (e.g. "syUSDC").
    /// @param _vault   Address of the paired syVault. Immutable after deployment.
    constructor(string memory _name, string memory _symbol, address _vault)
        ERC20(_name, _symbol)
    {
        if (_vault == address(0)) revert SyShare__NotVault();
        i_vault = _vault;
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyShare
    function mint(address _to, uint256 _amount) external onlyVault {
        _mint(_to, _amount);
    }

    /// @inheritdoc ISyShare
    function burn(address _from, uint256 _amount) external onlyVault {
        _burn(_from, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                      EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISyShare
    function vault() external view returns (address) {
        return i_vault;
    }
}
