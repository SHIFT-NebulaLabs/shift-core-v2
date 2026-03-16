// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {RateLimiter} from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingFee} from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {EndpointV2Mock} from
    "@layerzerolabs/test-devtools-evm-foundry/contracts/mocks/EndpointV2Mock.sol";

import {MockERC20}    from "test/mocks/MockERC20.sol";
import {MockMsgLib}   from "test/mocks/MockMsgLib.sol";
import {SyOFTAdapter} from "src/crosschain/SyOFTAdapter.sol";
import {SySharePeer}  from "src/crosschain/SySharePeer.sol";

/*//////////////////////////////////////////////////////////////
                        TEST HARNESS
//////////////////////////////////////////////////////////////*/

/// @dev Thin wrapper — keeps a named type so tests read clearly.
contract SyOFTAdapterHarness is SyOFTAdapter {
    constructor(address _syShare, address _lzEndpoint, address _owner)
        SyOFTAdapter(_syShare, _lzEndpoint, _owner)
    {}
}

/*//////////////////////////////////////////////////////////////
                           TESTS
//////////////////////////////////////////////////////////////*/

/// @title  Crosschain — SyOFTAdapter + SySharePeer
/// @notice Tests the lock/unlock (adapter) and mint/burn (peer) OFT bridging paths
///         using EndpointV2Mock + a zero-fee MockMsgLib — no npm / TestHelperOz5 required.
///
/// Chain topology (simulated in one Foundry test):
///   A (aEid = 1) — SyOFTAdapterHarness wrapping syShare ERC-20
///   B (bEid = 2) — SySharePeer (pure OFT mint/burn)
contract CrosschainTest is Test {
    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint32 internal constant A_EID = 1;
    uint32 internal constant B_EID = 2;

    /*//////////////////////////////////////////////////////////////
                            CONTRACTS
    //////////////////////////////////////////////////////////////*/

    MockERC20           internal syShare;   // syShare ERC-20 on chain A
    EndpointV2Mock      internal endpointA; // mock LZ endpoint on chain A
    EndpointV2Mock      internal endpointB; // mock LZ endpoint on chain B
    MockMsgLib          internal msgLib;    // shared zero-fee message library
    SyOFTAdapterHarness internal adapter;  // OFT adapter on chain A
    SySharePeer         internal peer;     // OFT peer on chain B

    /*//////////////////////////////////////////////////////////////
                             ACTORS
    //////////////////////////////////////////////////////////////*/

    address internal owner  = makeAddr("owner");
    address internal userA  = makeAddr("userA");
    address internal userB  = makeAddr("userB");

    /*//////////////////////////////////////////////////////////////
                              SET UP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // 1. Mock endpoints (each is owner of itself)
        endpointA = new EndpointV2Mock(A_EID, address(this));
        endpointB = new EndpointV2Mock(B_EID, address(this));

        // 2. Shared zero-fee message library
        msgLib = new MockMsgLib();

        // 3. Register + wire lib on both endpoints
        //    A sends to B, B receives from A — and vice versa
        _wireEndpoint(endpointA, B_EID);
        _wireEndpoint(endpointB, A_EID);

        // 4. syShare token (chain A)
        syShare = new MockERC20("Shift Yield Share USDC", "syUSDC", 18);

        // 5. OFT adapter on chain A
        adapter = new SyOFTAdapterHarness(address(syShare), address(endpointA), owner);

        // 6. OFT peer on chain B
        peer = new SySharePeer("Shift Yield Share USDC", "syUSDC", address(endpointB), owner);

        // 7. Wire peers (bidirectional)
        vm.prank(owner);
        adapter.setPeer(B_EID, _toBytes32(address(peer)));
        vm.prank(owner);
        peer.setPeer(A_EID, _toBytes32(address(adapter)));

        // 8. Default high rate limit — RateLimiter _outflow reverts with limit=0.
        //    Rate-limit-specific tests override this with a smaller value.
        RateLimiter.RateLimitConfig[] memory rl = new RateLimiter.RateLimitConfig[](1);
        rl[0] = RateLimiter.RateLimitConfig({
            dstEid: B_EID,
            limit:  type(uint192).max,
            window: 1 hours
        });
        vm.prank(owner);
        adapter.setRateLimits(rl);
    }

    /// @dev Register msgLib as default send and receive lib for the given remote eid.
    function _wireEndpoint(EndpointV2Mock _ep, uint32 _remoteEid) internal {
        _ep.registerLibrary(address(msgLib));
        _ep.setDefaultSendLibrary(_remoteEid, address(msgLib));
        _ep.setDefaultReceiveLibrary(_remoteEid, address(msgLib), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _toBytes32(address _a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_a)));
    }

    function _mintAndApprove(address _who, uint256 _amount) internal {
        syShare.mint(_who, _amount);
        vm.prank(_who);
        syShare.approve(address(adapter), _amount);
    }

    /// @dev OFT removes dust: amounts must be multiples of 10^(localDecimals-sharedDecimals) = 1e12.
    ///      Use minAmountLD=0 in tests — slippage tolerance not under test here.
    function _sendParamAtoB(address _to, uint256 _amount) internal pure returns (SendParam memory) {
        return SendParam({
            dstEid:       B_EID,
            to:           bytes32(uint256(uint160(_to))),
            amountLD:     _amount,
            minAmountLD:  0,
            extraOptions: bytes(""),
            composeMsg:   bytes(""),
            oftCmd:       bytes("")
        });
    }

    function _sendParamBtoA(address _to, uint256 _amount) internal pure returns (SendParam memory) {
        return SendParam({
            dstEid:       A_EID,
            to:           bytes32(uint256(uint160(_to))),
            amountLD:     _amount,
            minAmountLD:  0,
            extraOptions: bytes(""),
            composeMsg:   bytes(""),
            oftCmd:       bytes("")
        });
    }

    /// @dev Snap `_raw` down to the nearest multiple of 1e12 (OFT shared-decimal dust removal).
    ///      Division before multiplication is intentional — truncation IS the point.
    function _dustFree(uint256 _raw) internal pure returns (uint256) {
        return (_raw / 1e12) * 1e12; // solhint-disable-line divide-before-multiply
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_adapter_constructor() public view {
        assertEq(adapter.owner(), owner);
        assertEq(adapter.token(), address(syShare));
    }

    function test_peer_constructor() public view {
        assertEq(peer.owner(), owner);
        assertEq(peer.name(), "Shift Yield Share USDC");
        assertEq(peer.symbol(), "syUSDC");
        assertEq(peer.token(), address(peer)); // OFT: token() returns self
    }

    function test_peer_decimals_matchSyShare() public view {
        assertEq(peer.decimals(), syShare.decimals());
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP / ACCESS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_nonOwner_setPeer_adapter() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        adapter.setPeer(B_EID, _toBytes32(address(peer)));
    }

    function test_RevertWhen_nonOwner_setPeer_peer() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        peer.setPeer(A_EID, _toBytes32(address(adapter)));
    }

    /*//////////////////////////////////////////////////////////////
                    SEND A → B  (lock / mint)
    //////////////////////////////////////////////////////////////*/

    function test_sendAtoB() public {
        uint256 amount = 1_000e18;
        _mintAndApprove(userA, amount);

        SendParam  memory sp  = _sendParamAtoB(userB, amount);
        MessagingFee memory fee = adapter.quoteSend(sp, false);

        assertEq(syShare.balanceOf(userA), amount);
        assertEq(syShare.balanceOf(address(adapter)), 0);
        assertEq(peer.balanceOf(userB), 0);

        vm.prank(userA);
        adapter.send{value: fee.nativeFee}(sp, fee, payable(userA));

        // Deliver queued packet to chain B
        msgLib.deliverAll(ILayerZeroEndpointV2(address(endpointB)));

        assertEq(syShare.balanceOf(userA), 0);
        assertEq(syShare.balanceOf(address(adapter)), amount);
        assertEq(peer.balanceOf(userB), amount);
    }

    function testFuzz_sendAtoB(uint256 _amount) public {
        // OFT uses uint64 shared decimals (6 dp); max SD = type(uint64).max. Multiply by 1e12 for 18-dp LD amount.
        _amount = bound(_amount, 1, type(uint64).max) * 1e12;
        _mintAndApprove(userA, _amount);

        SendParam  memory sp  = _sendParamAtoB(userB, _amount);
        MessagingFee memory fee = adapter.quoteSend(sp, false);

        vm.prank(userA);
        adapter.send{value: fee.nativeFee}(sp, fee, payable(userA));
        msgLib.deliverAll(ILayerZeroEndpointV2(address(endpointB)));

        // Supply invariant: locked == minted on remote
        assertEq(syShare.balanceOf(address(adapter)), peer.balanceOf(userB));
        assertEq(syShare.balanceOf(address(adapter)), _amount);
    }

    /*//////////////////////////////////////////////////////////////
                    SEND B → A  (burn / unlock)
    //////////////////////////////////////////////////////////////*/

    function test_sendBtoA() public {
        uint256 amount = 500e18;
        _mintAndApprove(userA, amount);

        // First bridge A→B so userB has peer tokens
        SendParam  memory spAB  = _sendParamAtoB(userB, amount);
        MessagingFee memory feeAB = adapter.quoteSend(spAB, false);
        vm.prank(userA);
        adapter.send{value: feeAB.nativeFee}(spAB, feeAB, payable(userA));
        msgLib.deliverAll(ILayerZeroEndpointV2(address(endpointB)));

        // Bridge back B→A
        SendParam  memory spBA  = _sendParamBtoA(userA, amount);
        MessagingFee memory feeBA = peer.quoteSend(spBA, false);

        vm.prank(userB);
        peer.send{value: feeBA.nativeFee}(spBA, feeBA, payable(userB));
        msgLib.deliverAll(ILayerZeroEndpointV2(address(endpointA)));

        // sySharePeer burned, syShare returned to userA
        assertEq(peer.balanceOf(userB), 0);
        assertEq(syShare.balanceOf(address(adapter)), 0);
        assertEq(syShare.balanceOf(userA), amount);
    }

    /*//////////////////////////////////////////////////////////////
                    SUPPLY INVARIANT — FUZZ ROUND TRIP
    //////////////////////////////////////////////////////////////*/

    function testFuzz_roundTrip_supplyInvariant(uint256 _amount) public {
        _amount = bound(_amount, 1, type(uint64).max) * 1e12;

        // A→B
        _mintAndApprove(userA, _amount);
        SendParam  memory spAB  = _sendParamAtoB(userB, _amount);
        MessagingFee memory feeAB = adapter.quoteSend(spAB, false);
        vm.prank(userA);
        adapter.send{value: feeAB.nativeFee}(spAB, feeAB, payable(userA));
        msgLib.deliverAll(ILayerZeroEndpointV2(address(endpointB)));

        // Invariant mid-trip: locked == minted
        assertEq(syShare.balanceOf(address(adapter)), peer.totalSupply());

        // B→A
        SendParam  memory spBA  = _sendParamBtoA(userA, _amount);
        MessagingFee memory feeBA = peer.quoteSend(spBA, false);
        vm.prank(userB);
        peer.send{value: feeBA.nativeFee}(spBA, feeBA, payable(userB));
        msgLib.deliverAll(ILayerZeroEndpointV2(address(endpointA)));

        // Invariant after round-trip: no locked supply, no peer supply
        assertEq(syShare.balanceOf(address(adapter)), 0);
        assertEq(peer.totalSupply(), 0);
        assertEq(syShare.balanceOf(userA), _amount);
    }

    /*//////////////////////////////////////////////////////////////
                         RATE LIMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_rateLimitBlocks_whenExceeded() public {
        uint192 limit  = 100e18;
        uint64  window = 1 hours;

        RateLimiter.RateLimitConfig[] memory configs = new RateLimiter.RateLimitConfig[](1);
        configs[0] = RateLimiter.RateLimitConfig({dstEid: B_EID, limit: limit, window: window});
        vm.prank(owner);
        adapter.setRateLimits(configs);

        // Exhaust the limit
        uint256 amount = 100e18;
        _mintAndApprove(userA, amount);
        SendParam  memory sp  = _sendParamAtoB(userB, amount);
        MessagingFee memory fee = adapter.quoteSend(sp, false);
        vm.prank(userA);
        adapter.send{value: fee.nativeFee}(sp, fee, payable(userA));
        msgLib.deliverAll(ILayerZeroEndpointV2(address(endpointB)));

        // Next send within the same window should revert
        uint256 amount2 = 1e18;
        syShare.mint(userA, amount2);
        vm.prank(userA);
        syShare.approve(address(adapter), amount2);

        SendParam  memory sp2  = _sendParamAtoB(userB, amount2);
        MessagingFee memory fee2 = adapter.quoteSend(sp2, false);

        vm.prank(userA);
        vm.expectRevert(); // RateLimiter: RateLimitExceeded
        adapter.send{value: fee2.nativeFee}(sp2, fee2, payable(userA));
    }

    function test_rateLimitResets_afterWindow() public {
        uint192 limit  = 100e18;
        uint64  window = 1 hours;

        RateLimiter.RateLimitConfig[] memory configs = new RateLimiter.RateLimitConfig[](1);
        configs[0] = RateLimiter.RateLimitConfig({dstEid: B_EID, limit: limit, window: window});
        vm.prank(owner);
        adapter.setRateLimits(configs);

        // Exhaust limit
        uint256 amount = 100e18;
        _mintAndApprove(userA, amount);
        SendParam  memory sp  = _sendParamAtoB(userB, amount);
        MessagingFee memory fee = adapter.quoteSend(sp, false);
        vm.prank(userA);
        adapter.send{value: fee.nativeFee}(sp, fee, payable(userA));
        msgLib.deliverAll(ILayerZeroEndpointV2(address(endpointB)));

        // Advance past window
        vm.warp(block.timestamp + uint256(window) + 1);

        // Can send again
        uint256 amount2 = 50e18;
        _mintAndApprove(userA, amount2);
        SendParam  memory sp2  = _sendParamAtoB(userB, amount2);
        MessagingFee memory fee2 = adapter.quoteSend(sp2, false);
        vm.prank(userA);
        adapter.send{value: fee2.nativeFee}(sp2, fee2, payable(userA));
        msgLib.deliverAll(ILayerZeroEndpointV2(address(endpointB)));

        assertEq(peer.balanceOf(userB), amount + amount2);
    }

    function test_sendSucceeds_withHighRateLimit() public {
        // setUp configures type(uint192).max rate limit — large amounts must succeed
        uint256 amount = 1_000_000e18;
        _mintAndApprove(userA, amount);

        SendParam  memory sp  = _sendParamAtoB(userB, amount);
        MessagingFee memory fee = adapter.quoteSend(sp, false);

        vm.prank(userA);
        adapter.send{value: fee.nativeFee}(sp, fee, payable(userA));
        msgLib.deliverAll(ILayerZeroEndpointV2(address(endpointB)));

        assertEq(peer.balanceOf(userB), amount);
    }
}
