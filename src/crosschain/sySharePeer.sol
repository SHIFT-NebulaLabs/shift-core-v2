// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {OFT}     from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title  sySharePeer
/// @author Shift Protocol
/// @custom:security-contact team@shiftprotocol.xyz
/// @notice Per-remote-chain LayerZero OFT peer for syShare — mint/burn mechanism.
/// @dev    Deployed on each remote chain where syShare liquidity is needed.
///         Mints tokens on arrival from Chain A, burns on return.
///         No economic logic — purely a bridged representation of syShare.
///
///         Planned DeFi use cases on spoke chains: Morpho and Vesu as collateral.
///         Liquidity bootstrapping is a per-chain deployment concern.
///
///         Supply invariant: syShare locked in syOFTAdapter on Chain A ≡
///         sySharePeer minted on all remote chains combined.
///
///         To redeem from a remote chain: bridge back to Chain A, then requestRedeem().
///
///         Deployment order:
///           1. Deploy sySharePeer on remote chain (this contract).
///           2. setEnforcedOptions() on each pathway.
///           3. setPeer() last on both syOFTAdapter and this contract.
contract SySharePeer is OFT {
    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _name       Token name — matches syShare on Chain A (e.g. "Shift Yield Share — USDC").
    /// @param _symbol     Token symbol — matches syShare (e.g. "syUSDC").
    /// @param _lzEndpoint LayerZero EndpointV2 address for this remote chain.
    /// @param _owner      Owner address — must be a multisig. Controls peer config.
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _owner
    ) OFT(_name, _symbol, _lzEndpoint, _owner) Ownable(_owner) {}
}
