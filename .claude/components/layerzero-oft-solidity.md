# LayerZero OFT — Solidity

> Load when implementing or integrating OFT in Solidity.
> Read alongside `.claude/dev/solidity.md` and `.claude/components/erc-standards-solidity.md`.
> For deployment steps, DVN addresses, and SDK details: query the MCP server (see CLAUDE.md).

---

## Variants — Choose One

| Variant | Use case | Mechanism |
|---|---|---|
| `OFT` | New token — you control supply | burn → mint |
| `OFTAdapter` | Existing token, no mint/burn access | lock → unlock |
| `MintBurnOFTAdapter` | Existing token with mint/burn permissions | burn → mint via adapter |

**⚠️ Only one lockbox OFTAdapter per token globally.** Multiple adapters create separate liquidity pools — tokens sent to a chain without enough supply on the destination are permanently lost.

---

## Implementation

### OFT — New Token

```solidity
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @custom:security-contact security@example.com
contract MyOFT is OFT {
    constructor(
        string memory _name,
        string memory _symbol,
        address _lzEndpoint,
        address _owner
    ) OFT(_name, _symbol, _lzEndpoint, _owner) Ownable(_owner) {}
}
```

### OFTAdapter — Existing Token

```solidity
import {OFTAdapter} from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @custom:security-contact security@example.com
contract MyOFTAdapter is OFTAdapter {
    constructor(
        address _token,
        address _lzEndpoint,
        address _owner
    ) OFTAdapter(_token, _lzEndpoint, _owner) Ownable(_owner) {}
}
```

---

## Configuration Order — Never Deviate

Always configure in this exact sequence. Skipping or reordering breaks the pathway.

```
1. Deploy OFT on each chain
2. Set send/receive libraries (explicit — never rely on defaults)
3. Configure DVNs — both send and receive side per pathway
4. Configure executor
5. Set enforced options
6. Set delegate (before transferring ownership)
7. Set peers — LAST — this opens the messaging channel
```

**Pathways are directional.** A→B and B→A must each be configured and verified separately.

**Never rely on default libraries or DVN config.** Defaults may be dead configs — DVNs not listening, executor not connected. Always call `getSendLibrary`, `getReceiveLibrary`, and `getConfig` to verify explicitly.

---

## Enforced Options

Mandatory gas settings per message type. Without these, `send()` reverts.

```solidity
EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
options[0] = EnforcedOptionParam({
    eid: dstEid,
    msgType: 1, // SEND
    options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(80000, 0)
});
oft.setEnforcedOptions(options);
```

Profile actual gas usage on destination before setting limits — do not guess.

---

## Sending Tokens

```solidity
// 1. Quote fee — call as close to send as possible
SendParam memory sendParam = SendParam({
    dstEid: dstEid,
    to: bytes32(uint256(uint160(recipient))),
    amountLD: amount,
    minAmountLD: amount * 95 / 100,
    extraOptions: OptionsBuilder.newOptions().addExecutorLzReceiveOption(65000, 0),
    composeMsg: "",
    oftCmd: ""
});
MessagingFee memory fee = oft.quoteSend(sendParam, false);

// 2. For OFTAdapter: approve token first
// ERC20(token).approve(adapterAddress, amount);

// 3. Send
oft.send{value: fee.nativeFee}(sendParam, fee, msg.sender);
```

---

## Composed Messages (send + call)

Token transfer and custom logic execute as separate messages — token arrives first, then compose runs.

```solidity
extraOptions: OptionsBuilder.newOptions()
    .addExecutorLzReceiveOption(65000, 0)    // token transfer
    .addExecutorLzComposeOption(0, 50000, 0), // compose execution
composeMsg: abi.encode(finalRecipient, extraParams),
```

Composer must implement `IOAppComposer` and enforce both guards:

```solidity
function lzCompose(
    address _oApp,
    bytes32 _guid,
    bytes calldata _message,
    address _executor,
    bytes calldata _extraData
) external payable {
    require(msg.sender == endpoint, "!endpoint");
    require(_oApp == trustedOFT, "!oApp");
    // tokens already credited to composer at this point
    // if msg.value is encoded in message, validate it:
    require(msg.value >= _decodedValue, "insufficient value");
}
```

**`msg.value` in `lzReceive`/`lzCompose` is not guaranteed.** Any caller can execute a verified message. Encode expected `msg.value` inside the message on the source chain and validate it on destination.

---

## Rate Limiting (optional)

```solidity
import {RateLimiter} from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";

contract MyRateLimitedOFT is OFT, RateLimiter {
    function _debit(address _from, uint256 _amountLD, uint256 _minAmountLD, uint32 _dstEid)
        internal override returns (uint256, uint256)
    {
        _outflow(_dstEid, _amountLD);
        return super._debit(_from, _amountLD, _minAmountLD, _dstEid);
    }
}
```

---

## Security Checklist

### Architecture
- [ ] Only one OFTAdapter deployed per token globally
- [ ] Shared decimals consistent across all chains — inconsistency allows double spending
- [ ] Local decimals on each chain can hold the full intended max supply (overflow risk)
- [ ] Minter/burner role granted to adapter on token contract (MintBurnOFTAdapter)

### Configuration (per pathway, both directions)
- [ ] Libraries set explicitly — not relying on defaults
- [ ] DVNs configured on both send and receive side — at least 2 for production
- [ ] DVN config consistent on both sides of every pathway
- [ ] Executor configured with correct max message size
- [ ] Enforced options set — gas profiled, not guessed
- [ ] Delegate set before transferring ownership
- [ ] Peers set last — after everything else

### Ownership
- [ ] OApp owner set to intended address (multisig on mainnet)
- [ ] Delegate set to intended address at EndpointV2
- [ ] Proxy admin / upgrade authority set correctly (if upgradeable)
- [ ] `_disableInitializers()` in implementation constructor (if upgradeable)

### Code Quality
- [ ] No mock or test functions in production deployment
- [ ] No hardcoded endpoint IDs — use admin-restricted setters
- [ ] Using latest LayerZero packages — not copied source
- [ ] `_lzReceive` security: `msg.sender == endpoint` and peer validation (built-in if using OAppReceiver)
- [ ] `lzCompose` security: `msg.sender == endpoint` and `_oApp == trustedOFT` (must add manually)
- [ ] `msg.value` encoded in message and validated in `lzReceive`/`lzCompose` if value is expected
- [ ] Fee quote freshness — `quoteSend` called close to `send`