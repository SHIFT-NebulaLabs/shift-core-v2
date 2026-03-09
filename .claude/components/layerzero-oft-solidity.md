# LayerZero OFT — Solidity

> Load when implementing or integrating OFT (Omnichain Fungible Token) in Solidity.
> Read alongside `.claude/dev/solidity.md` and `.claude/components/erc-standards-solidity.md`.
> Reference: https://docs.layerzero.network/v2/developers/evm/oft/quickstart

---

## Concepts

**OFT** — Omnichain Fungible Token. Burns tokens on source chain, mints on destination.
**OFTAdapter** — Wraps an existing ERC-20 that cannot mint/burn. Locks on source, unlocks on destination.
**MintBurnOFTAdapter** — Like OFTAdapter but delegates mint/burn to a permissioned contract instead of locking.

| Variant | Use case | Mechanism |
|---|---|---|
| `OFT` | New token — you control supply | burn → mint |
| `OFTAdapter` | Existing token, no mint/burn access | lock → unlock |
| `MintBurnOFTAdapter` | Existing token with mint/burn permissions | burn → mint via minter contract |

---

## Installation (Foundry)

```bash
forge install layerzero-labs/devtools
forge install layerzero-labs/LayerZero-v2
forge install OpenZeppelin/openzeppelin-contracts
git submodule add https://github.com/GNSPS/solidity-bytes-utils.git lib/solidity-bytes-utils
```

Add to `foundry.toml` under `[profile.default]`:

```toml
remappings = [
    '@layerzerolabs/oft-evm/=lib/devtools/packages/oft-evm/',
    '@layerzerolabs/oapp-evm/=lib/devtools/packages/oapp-evm/',
    '@layerzerolabs/lz-evm-protocol-v2/=lib/layerzero-v2/packages/layerzero-v2/evm/protocol',
    '@layerzerolabs/lz-evm-messagelib-v2/=lib/layerzero-v2/packages/layerzero-v2/evm/messagelib',
    '@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/',
    'solidity-bytes-utils/=lib/solidity-bytes-utils/',
]
```

---

## Implementation

### OFT — New Token

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

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

Add `_mint` in constructor or expose a protected `mint` function before deploying.

### OFTAdapter — Existing Token (Lock/Unlock)

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

**⚠️ Only one OFTAdapter per token globally.** Multiple adapters break unified liquidity and can cause permanent token loss.

---

## Key Concepts

### Endpoint V2
All chains share the same EndpointV2 address:
```
0x1a44076050125825900e736c501f859c50fE728c
```
Exception: zkSync Era uses `0xd07C30aF3Ff30D96BDc9c6044958230Eb797DDBF`.

### Peers
Each OFT must register trusted remote OFTs via `setPeer`:
```solidity
// _peer must be bytes32 — left-pad EVM addresses
oft.setPeer(dstEid, bytes32(uint256(uint160(remotOFTAddress))));
```
**Set peers last** — after all security configuration. Setting a peer opens the messaging channel.

### Enforced Options
Mandatory gas settings applied to all messages of a given type:
```solidity
EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
options[0] = EnforcedOptionParam({
    eid: dstEid,
    msgType: 1, // SEND
    options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(80000, 0)
});
oft.setEnforcedOptions(options);
```
If not set, `send()` reverts with `LZ_ULN_InvalidWorkerOptions`.

---

## Deployment Flow

### 1. Deploy on each chain
```solidity
// DeployMyOFT.s.sol
contract DeployMyOFT is Script {
    function run() external {
        address endpoint = vm.envAddress("ENDPOINT_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");

        vm.startBroadcast();
        MyOFT oft = new MyOFT("MyToken", "MTK", endpoint, owner);
        vm.stopBroadcast();

        console.log("OFT deployed:", address(oft));
    }
}
```

### 2. Set send/receive libraries (if non-default)
```solidity
ILayerZeroEndpointV2(endpoint).setSendLibrary(oft, dstEid, sendLibAddress);
ILayerZeroEndpointV2(endpoint).setReceiveLibrary(oft, srcEid, receiveLibAddress, 0);
```

### 3. Configure DVNs
```solidity
// Send config — set on source chain
UlnConfig memory uln = UlnConfig({
    confirmations: 15,
    requiredDVNCount: 1,
    optionalDVNCount: 0,
    optionalDVNThreshold: 0,
    requiredDVNs: [LAYERZERO_DVN_ADDRESS],
    optionalDVNs: new address[](0)
});
SetConfigParam[] memory params = new SetConfigParam[](1);
params[0] = SetConfigParam(dstEid, ULN_CONFIG_TYPE, abi.encode(uln));
ILayerZeroEndpointV2(endpoint).setConfig(oft, sendLib, params);
```

### 4. Set enforced options
See `setEnforcedOptions` above. Always set before peers.

### 5. Set peers (last)
```solidity
oft.setPeer(dstEid, bytes32(uint256(uint160(remoteOFTAddress))));
```

---

## Sending Tokens

```solidity
// 1. Quote fee
SendParam memory sendParam = SendParam({
    dstEid: dstEid,
    to: bytes32(uint256(uint160(recipient))),
    amountLD: amount,
    minAmountLD: amount * 95 / 100, // 5% slippage tolerance
    extraOptions: OptionsBuilder.newOptions().addExecutorLzReceiveOption(65000, 0),
    composeMsg: "",
    oftCmd: ""
});
MessagingFee memory fee = oft.quoteSend(sendParam, false);

// 2. Send (for OFTAdapter: approve first)
// ERC20(token).approve(adapterAddress, amount);
oft.send{value: fee.nativeFee}(sendParam, fee, msg.sender);
```

**Quote freshness**: call `quoteSend` as close to `send` as possible — fees change with gas prices.

---

## Composed Messages (send + call)

Horizontal composability — token transfer and custom logic execute as separate messages:

```solidity
// Set to address = composer contract, not end recipient
SendParam memory sendParam = SendParam({
    dstEid: dstEid,
    to: bytes32(uint256(uint160(composerAddress))),
    amountLD: amount,
    minAmountLD: amount * 95 / 100,
    extraOptions: OptionsBuilder.newOptions()
        .addExecutorLzReceiveOption(65000, 0)   // token transfer + compose queue
        .addExecutorLzComposeOption(0, 50000, 0), // composer execution
    composeMsg: abi.encode(finalRecipient, extraParams),
    oftCmd: ""
});
```

Composer contract must implement `IOAppComposer`:
```solidity
function lzCompose(
    address _oApp,
    bytes32 _guid,
    bytes calldata _message,
    address _executor,
    bytes calldata _extraData
) external payable {
    require(msg.sender == endpoint, "unauthorized");
    require(_oApp == trustedOFT, "untrusted OApp");
    // tokens are already credited to composer address at this point
    uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);
    bytes memory composeMsg = OFTComposeMsgCodec.composeMsg(_message);
    // ... custom logic
}
```

---

## Security Checklist (OFT-specific)

- [ ] Only one OFTAdapter deployed per token (if using Adapter)
- [ ] Peers set only after full configuration
- [ ] Enforced options set — `send()` will revert without them
- [ ] DVNs configured — at least one required DVN per pathway
- [ ] `setDelegate` called if owner is a multisig
- [ ] Composer verifies `msg.sender == endpoint` and `_oApp == trustedOFT`
- [ ] Rate limiting considered for high-value tokens
- [ ] Fee quote freshness — `quoteSend` called close to `send`

---

## Rate Limiting (optional)

```solidity
import {RateLimiter} from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";

contract MyRateLimitedOFT is OFT, RateLimiter {
    function _debit(address _from, uint256 _amountLD, uint256 _minAmountLD, uint32 _dstEid)
        internal override returns (uint256, uint256)
    {
        _outflow(_dstEid, _amountLD); // check rate limit
        return super._debit(_from, _amountLD, _minAmountLD, _dstEid);
    }
}
```

---

## References
- [LayerZero V2 OFT Quickstart](https://docs.layerzero.network/v2/developers/evm/oft/quickstart)
- [LayerZero Deployed Contracts](https://docs.layerzero.network/v2/deployments/deployed-contracts)
- [devtools GitHub](https://github.com/layerzero-labs/devtools)
- [LayerZero Scan](https://layerzeroscan.com)