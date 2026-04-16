// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {ERC20}           from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal mintable ERC-20. Testnet only — no access control on mint.
contract MockToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory _name, string memory _symbol, uint8 _decimals)
        ERC20(_name, _symbol)
    {
        _dec = _decimals;
    }

    function decimals() public view override returns (uint8) { return _dec; }

    function mint(address _to, uint256 _amount) external { _mint(_to, _amount); }
}

/// @title  DeployMockToken
/// @notice Testnet helper — deploys a mintable ERC-20 to use as the syShare stand-in
///         when testing the OFT adapter without a full vault deployment.
///
///         Required .env:
///           DEPLOYER_ADDRESS    — deployer EOA (must match --interactives 1 key)
///           VAULT_SHARE_NAME    — token name  (e.g. "Shift Yield Share USDC")
///           VAULT_SHARE_SYMBOL  — token symbol (e.g. "syUSDC")
///           MINT_AMOUNT         — raw units to mint to deployer (e.g. 1000000000000000000000 = 1000 tokens)
///
/// @dev Run on the HOME chain:
///   forge script script/helpers/DeployMockToken.s.sol --rpc-url $HOME_RPC --broadcast --verify --interactives 1
contract DeployMockToken is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        string  memory name   = vm.envString("VAULT_SHARE_NAME");
        string  memory symbol = vm.envString("VAULT_SHARE_SYMBOL");
        uint256 mintAmount    = vm.envUint("MINT_AMOUNT");

        vm.startBroadcast();

        MockToken token = new MockToken(name, symbol, 18);
        token.mint(deployer, mintAmount);

        vm.stopBroadcast();

        console.log("=== MOCK TOKEN DEPLOYED ===");
        console.log("MockToken   :", address(token));
        console.log("Name        :", name);
        console.log("Symbol      :", symbol);
        console.log("Minted to   :", deployer);
        console.log("Amount      :", mintAmount);
        console.log("");
        console.log("Add to .env:");
        console.log("SYSHARE=", address(token));
    }
}
