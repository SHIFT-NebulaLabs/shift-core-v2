// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IMessageLib, MessageLibType, SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLib.sol";
import {Packet, ISendLib}                           from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ISendLib.sol";
import {ILayerZeroEndpointV2, MessagingFee, Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {PacketV1Codec}               from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/PacketV1Codec.sol";

/// @title  MockMsgLib
/// @notice Minimal send-and-receive message library for Foundry tests.
///         Zero fees, zero validation — just stores packets and delivers them.
///
/// Usage (per test setUp):
///   1. Deploy one instance shared by all test endpoints.
///   2. On each EndpointV2Mock: registerLibrary, setDefaultSendLibrary, setDefaultReceiveLibrary.
///   3. After calling OFT.send(), call deliverAll(dstEndpoint) to deliver queued packets.
contract MockMsgLib is ERC165, ISendLib {
    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    struct StoredPacket {
        uint64  nonce;
        uint32  srcEid;
        bytes32 sender;   // bytes32-encoded sender address
        address receiver; // decoded receiver address
        bytes32 guid;
        bytes   message;
    }

    StoredPacket[] public pendingPackets;

    /*//////////////////////////////////////////////////////////////
                           ERC-165
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 _interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return _interfaceId == type(IMessageLib).interfaceId || super.supportsInterface(_interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                         IMessageLib
    //////////////////////////////////////////////////////////////*/

    /// @dev SendAndReceive satisfies both isSendLib and isReceiveLib modifiers on EndpointV2.
    function messageLibType() external pure returns (MessageLibType) {
        return MessageLibType.SendAndReceive;
    }

    function isSupportedEid(uint32) external pure returns (bool) {
        return true;
    }

    function version() external pure returns (uint64 major, uint8 minor, uint8 endpointVersion) {
        return (1, 0, 2);
    }

    /*//////////////////////////////////////////////////////////////
                           ISendLib
    //////////////////////////////////////////////////////////////*/

    /// @dev Called by EndpointV2Mock when an OFT sends a message.
    ///      Stores the packet for later delivery via deliverAll().
    function send(
        Packet calldata _packet,
        bytes calldata,
        bool
    ) external returns (MessagingFee memory fee, bytes memory encodedPacket) {
        pendingPackets.push(StoredPacket({
            nonce:    _packet.nonce,
            srcEid:   _packet.srcEid,
            sender:   bytes32(uint256(uint160(_packet.sender))),
            receiver: address(uint160(uint256(_packet.receiver))),
            guid:     _packet.guid,
            message:  _packet.message
        }));

        encodedPacket = PacketV1Codec.encode(_packet);
        fee = MessagingFee({nativeFee: 0, lzTokenFee: 0});
    }

    function quote(
        Packet calldata,
        bytes calldata,
        bool
    ) external pure returns (MessagingFee memory) {
        return MessagingFee({nativeFee: 0, lzTokenFee: 0});
    }

    /*//////////////////////////////////////////////////////////////
                        PACKET DELIVERY
    //////////////////////////////////////////////////////////////*/

    /// @notice Deliver all queued packets to the destination endpoint.
    ///
    ///         This contract (MockMsgLib) must be registered as the default receive library
    ///         on `_dst` for the originating srcEid, so that verify() accepts it as msg.sender.
    ///
    ///         lzReceive() has no access control — anyone may call it after verify().
    function deliverAll(ILayerZeroEndpointV2 _dst) external {
        uint256 len = pendingPackets.length;
        for (uint256 i; i < len; ++i) {
            StoredPacket memory pkt = pendingPackets[i];
            Origin memory origin = Origin({srcEid: pkt.srcEid, sender: pkt.sender, nonce: pkt.nonce});
            bytes memory payloadBytes = abi.encodePacked(pkt.guid, pkt.message);

            // MockMsgLib is msg.sender here → must be registered as receive lib on _dst
            _dst.verify(origin, pkt.receiver, keccak256(payloadBytes));

            // No access control on lzReceive — call from here after verify
            _dst.lzReceive(origin, pkt.receiver, pkt.guid, pkt.message, "");
        }
        delete pendingPackets;
    }

    function pendingCount() external view returns (uint256) {
        return pendingPackets.length;
    }

    /*//////////////////////////////////////////////////////////////
                  ISendLib STUBS (unused in tests)
    //////////////////////////////////////////////////////////////*/

    function setTreasury(address) external {}
    function withdrawFee(address, uint256) external {}
    function withdrawLzTokenFee(address, address, uint256) external {}

    /*//////////////////////////////////////////////////////////////
                  IMessageLib STUBS (unused in tests)
    //////////////////////////////////////////////////////////////*/

    function setConfig(address, SetConfigParam[] calldata) external {}
    function getConfig(uint32, address, uint32) external pure returns (bytes memory) { return ""; }

    /*//////////////////////////////////////////////////////////////
                        REQUIRED FALLBACKS
    //////////////////////////////////////////////////////////////*/

    fallback() external payable {}
    receive()  external payable {}
}
