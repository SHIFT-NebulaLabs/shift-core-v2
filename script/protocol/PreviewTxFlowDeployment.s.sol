// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {AdminGateway} from "src/AdminGateway.sol";
import {VaultState} from "src/types/Types.sol";

/// @title PreviewTxFlowDeployment
/// @notice Encodes unsigned TxFlow Core creation and governance transactions for review.
contract PreviewTxFlowDeployment is Script {
    error InvalidPreviewInput();

    address private constant NATIVE_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 private constant ARBITRUM_ONE = 42_161;
    uint256 private constant INITIAL_PRICE = 1e6;

    struct Config {
        address deployer;
        uint64 startNonce;
        address hub;
        address gateway;
        address executor;
        address feeRecipient;
        address navSigner;
        address operator;
        uint64 maximumNavAge;
        uint64 maximumApprovalLifetime;
        string shareName;
        string shareSymbol;
        uint256 timelockDelay;
    }

    struct TimelockPacket {
        bytes32 operationId;
        bytes scheduleData;
        bytes executeData;
    }

    struct DeploymentPacket {
        address share;
        address pool;
        address vault;
        address guard;
        bytes shareInitCode;
        bytes poolInitCode;
        bytes vaultInitCode;
        bytes guardInitCode;
        TimelockPacket register;
    }

    /// @notice Returns an unsigned creation and registration packet as JSON.
    /// @dev This entrypoint neither broadcasts nor signs. Use verified input and a frozen nonce lane.
    function run() external returns (string memory) {
        Config memory config = Config({
            deployer: vm.envAddress("TXFLOW_DEPLOYER"),
            startNonce: _uint64Env("TXFLOW_START_NONCE"),
            hub: vm.envAddress("TXFLOW_HUB"),
            gateway: vm.envAddress("TXFLOW_ADMIN_GATEWAY"),
            executor: vm.envAddress("TXFLOW_EXECUTOR"),
            feeRecipient: vm.envAddress("TXFLOW_FEE_RECIPIENT"),
            navSigner: vm.envAddress("TXFLOW_NAV_SIGNER"),
            operator: vm.envAddress("TXFLOW_KEEPER_OPERATOR"),
            maximumNavAge: _uint64Env("TXFLOW_NAV_MAX_AGE_SECONDS"),
            maximumApprovalLifetime: _uint64Env("TXFLOW_NAV_MAX_APPROVAL_SECONDS"),
            shareName: vm.envString("TXFLOW_SHARE_NAME"),
            shareSymbol: vm.envString("TXFLOW_SHARE_SYMBOL"),
            timelockDelay: vm.envUint("TXFLOW_TIMELOCK_DELAY_SECONDS")
        });
        DeploymentPacket memory packet = buildDeployment(config);
        string memory object = "txflowDeployment";
        vm.serializeUint(object, "chainId", ARBITRUM_ONE);
        vm.serializeAddress(object, "deployer", config.deployer);
        vm.serializeUint(object, "firstNonce", config.startNonce);
        vm.serializeAddress(object, "governanceTo", config.gateway);
        vm.serializeUint(object, "timelockDelaySeconds", config.timelockDelay);
        vm.serializeAddress(object, "share", packet.share);
        vm.serializeAddress(object, "pool", packet.pool);
        vm.serializeAddress(object, "vault", packet.vault);
        vm.serializeAddress(object, "keeperGuard", packet.guard);
        vm.serializeBytes(object, "shareInitCode", packet.shareInitCode);
        vm.serializeBytes(object, "poolInitCode", packet.poolInitCode);
        vm.serializeBytes(object, "vaultInitCode", packet.vaultInitCode);
        vm.serializeBytes(object, "guardInitCode", packet.guardInitCode);
        vm.serializeBytes32(object, "registerOperationId", packet.register.operationId);
        vm.serializeBytes(object, "registerScheduleData", packet.register.scheduleData);
        return vm.serializeBytes(object, "registerExecuteData", packet.register.executeData);
    }

    /// @notice Returns unsigned fee or activation governance calldata as JSON for an observed vault ID.
    /// @param activate False prepares the performance fee proposal. True prepares the later activation proposal.
    function runGovernance(bool activate) external returns (string memory) {
        address gateway = vm.envAddress("TXFLOW_ADMIN_GATEWAY");
        uint256 vaultId = vm.envUint("TXFLOW_VAULT_ID");
        uint256 delay = vm.envUint("TXFLOW_TIMELOCK_DELAY_SECONDS");
        TimelockPacket memory packet = buildGovernance(gateway, vaultId, delay, activate);
        string memory object = "txflowGovernance";
        vm.serializeUint(object, "chainId", ARBITRUM_ONE);
        vm.serializeAddress(object, "to", gateway);
        vm.serializeUint(object, "vaultId", vaultId);
        vm.serializeUint(object, "timelockDelaySeconds", delay);
        vm.serializeString(object, "operation", activate ? "Activate" : "SetPerformanceFee1500");
        vm.serializeBytes32(object, "operationId", packet.operationId);
        vm.serializeBytes(object, "scheduleData", packet.scheduleData);
        return vm.serializeBytes(object, "executeData", packet.executeData);
    }

    /// @notice Encodes the exact four consecutive CREATE transactions and Pending registration.
    /// @param config Expected signer addresses, transaction nonce and unsigned deployment settings.
    /// @return packet Predicted addresses and unsigned transaction data.
    function buildDeployment(Config memory config) public view returns (DeploymentPacket memory packet) {
        if (
            config.deployer == address(0) || config.hub == address(0) || config.gateway == address(0)
                || config.executor == address(0) || config.feeRecipient == address(0) || config.navSigner == address(0)
                || config.operator == address(0) || config.executor == config.operator
                || config.executor == config.navSigner || config.navSigner == config.operator
                || config.startNonce > type(uint64).max - 4 || config.maximumNavAge == 0
                || config.maximumNavAge > 30 minutes || config.maximumApprovalLifetime == 0
                || config.maximumApprovalLifetime > 30 minutes || bytes(config.shareName).length == 0
                || bytes(config.shareSymbol).length == 0
        ) revert InvalidPreviewInput();

        packet.share = vm.computeCreateAddress(config.deployer, config.startNonce);
        packet.pool = vm.computeCreateAddress(config.deployer, config.startNonce + 1);
        packet.vault = vm.computeCreateAddress(config.deployer, config.startNonce + 2);
        packet.guard = vm.computeCreateAddress(config.deployer, config.startNonce + 3);

        packet.shareInitCode = abi.encodePacked(
            vm.getCode("src/syShare.sol:SyShare"), abi.encode(config.shareName, config.shareSymbol, packet.vault)
        );
        packet.poolInitCode =
            abi.encodePacked(vm.getCode("src/LiquidityPool.sol:LiquidityPool"), abi.encode(NATIVE_USDC, packet.vault));
        packet.vaultInitCode = abi.encodePacked(
            vm.getCode("src/syVault.sol:SyVault"),
            abi.encode(
                NATIVE_USDC,
                packet.share,
                packet.pool,
                config.hub,
                config.gateway,
                packet.guard,
                config.executor,
                config.feeRecipient,
                INITIAL_PRICE,
                false
            )
        );
        packet.guardInitCode = abi.encodePacked(
            vm.getCode("src/integrations/txflow/TxFlowNavKeeper.sol:TxFlowNavKeeper"),
            abi.encode(
                packet.vault,
                packet.pool,
                config.executor,
                config.navSigner,
                config.operator,
                config.maximumNavAge,
                config.maximumApprovalLifetime
            )
        );
        packet.register = _timelockPacket(
            config.gateway,
            abi.encodeCall(AdminGateway.registerVault, (packet.vault, packet.pool, packet.share, address(0))),
            keccak256(abi.encode("shift.txflow.register.v1", packet.vault)),
            config.timelockDelay
        );
    }

    /// @notice Encodes a distinct proposal for the performance fee or Pending-to-Active transition.
    /// @param gateway Existing Shift AdminGateway on Arbitrum.
    /// @param vaultId Identifier verified from the registration receipt and registry readback.
    /// @param delay Current AdminGateway minimum delay in seconds.
    /// @param activate True for activation, false for the fee proposal.
    /// @return packet Timelock scheduling and execution calldata.
    function buildGovernance(address gateway, uint256 vaultId, uint256 delay, bool activate)
        public
        pure
        returns (TimelockPacket memory packet)
    {
        if (gateway == address(0) || vaultId == 0) revert InvalidPreviewInput();
        bytes memory payload = activate
            ? abi.encodeCall(AdminGateway.setVaultState, (vaultId, VaultState.Active))
            : abi.encodeCall(AdminGateway.setPerformanceFeeBps, (vaultId, 1500));
        return
            _timelockPacket(gateway, payload, keccak256(abi.encode("shift.txflow.launch.v1", vaultId, activate)), delay);
    }

    function _timelockPacket(address _gateway, bytes memory _payload, bytes32 _salt, uint256 _delay)
        private
        pure
        returns (TimelockPacket memory packet)
    {
        packet.operationId = keccak256(abi.encode(_gateway, uint256(0), _payload, bytes32(0), _salt));
        packet.scheduleData =
            abi.encodeCall(TimelockController.schedule, (_gateway, 0, _payload, bytes32(0), _salt, _delay));
        packet.executeData = abi.encodeCall(TimelockController.execute, (_gateway, 0, _payload, bytes32(0), _salt));
    }

    function _uint64Env(string memory _key) private view returns (uint64) {
        return SafeCast.toUint64(vm.envUint(_key));
    }
}
