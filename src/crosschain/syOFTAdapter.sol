// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {OFTAdapter} from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import {RateLimiter} from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";
import {Ownable}    from "@openzeppelin/contracts/access/Ownable.sol";

/// @title  syOFTAdapter
/// @author Shift Protocol
/// @custom:security-contact team@shiftprotocol.xyz
/// @notice Chain A LayerZero OFT adapter for syShare — lock/unlock mechanism.
/// @dev    Deployed ONCE on the home chain (Chain A) alongside syShare.
///         Wraps syShare using the lock/unlock model — tokens locked here are mirrored as minted
///         sySharePeer on remote chains. Never holds economic logic.
///
///         ⚠️ Only ONE OFTAdapter per syShare globally. Multiple adapters break unified liquidity
///         and can cause permanent token loss.
///
///         Supply invariant: locked balance in this adapter ≡ sySharePeer minted on all remotes.
///
///         Deployment order:
///           1. Deploy syOFTAdapter (this contract).
///           2. Deploy sySharePeer on each remote chain.
///           3. setEnforcedOptions() on each pathway.
///           4. setPeer() last — opening the messaging channel.
contract SyOFTAdapter is OFTAdapter, RateLimiter {
    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _syShare    Address of the syShare ERC-20 token on Chain A.
    /// @param _lzEndpoint LayerZero EndpointV2 address for this chain.
    /// @param _owner      Owner address — must be a multisig. Controls peer config and rate limits.
    constructor(address _syShare, address _lzEndpoint, address _owner)
        OFTAdapter(_syShare, _lzEndpoint, _owner)
        Ownable(_owner)
    {}

    /*//////////////////////////////////////////////////////////////
                    RATE LIMITING — CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set outbound rate limits per destination chain.
    ///         Rate limits are REQUIRED — a limit of 0 (default) blocks all sends.
    ///         Must be called by the owner (multisig) before the adapter can be used.
    /// @param _rateLimitConfigs Array of {dstEid, limit, window} configurations.
    function setRateLimits(RateLimiter.RateLimitConfig[] calldata _rateLimitConfigs)
        external
        onlyOwner
    {
        _setRateLimits(_rateLimitConfigs);
    }

    /// @notice Reset (clear) outbound rate limits for the given destination chains.
    /// @param _eids Destination endpoint IDs to reset.
    function resetRateLimits(uint32[] calldata _eids) external onlyOwner {
        _resetRateLimits(_eids);
    }

    /*//////////////////////////////////////////////////////////////
                        RATE LIMITING — OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /// @dev Apply outbound rate limit before debiting tokens from the adapter.
    ///      Per spec section 10.3 — rate limiting caps bridgeable flow per period.
    ///      _removeDust is applied before _outflow so the rate limiter tracks the actual
    ///      locked amount, not the pre-truncation gross amount. Without this, each transfer
    ///      over-counts by up to (decimalConversionRate - 1) units, making the effective
    ///      rate limit stricter than configured.
    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32  _dstEid
    ) internal override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        _outflow(_dstEid, _removeDust(_amountLD));
        return super._debit(_from, _amountLD, _minAmountLD, _dstEid);
    }
}
