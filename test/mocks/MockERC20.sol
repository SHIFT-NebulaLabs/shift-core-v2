// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal ERC-20 for testing. Unlimited mint.
contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory _name, string memory _symbol, uint8 _decimals)
        ERC20(_name, _symbol)
    {
        _dec = _decimals;
    }

    function decimals() public view override returns (uint8) { return _dec; }

    function mint(address _to, uint256 _amount) external { _mint(_to, _amount); }
}
