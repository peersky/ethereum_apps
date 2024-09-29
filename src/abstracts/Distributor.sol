// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0 <0.9.0;
import "../interfaces/IDistribution.sol";
import "../interfaces/IDistributor.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/IInitializer.sol";
import "../abstracts/CodeIndexer.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
/**
 * @title Distributor
 * @notice Abstract contract that implements the IDistributor interface, CodeIndexer, and ERC165.
 * This contract serves as a base for creating distributor contracts with specific functionalities.
 * It provides the necessary structure and functions to be extended by other contracts.
 * @author Peeramid Labs, 2024
 */
abstract contract Distributor is IDistributor, CodeIndexer, ERC165 {
    struct DistributionComponent {
        bytes32 id;
        address initializer;
    }
    using EnumerableSet for EnumerableSet.Bytes32Set;
    EnumerableSet.Bytes32Set private distirbutionsSet;
    // mapping(bytes32 => IInitializer) private initializers;
    mapping(address => uint256) private instanceIds;
    mapping(uint256 => bytes32) public distributionOf;
    mapping(bytes32 => DistributionComponent) public distributionComponents;
    uint256 public numInstances;
    // @inheritdoc IDistributor
    function getDistributions() external view returns (bytes32[] memory) {
        return distirbutionsSet.values();
    }
    // @inheritdoc IDistributor
    function getDistributionId(address instance) external view virtual returns (bytes32) {
        return distributionOf[getInstanceId(instance)];
    }
    // @inheritdoc IDistributor
    function getInstanceId(address instance) public view virtual returns (uint256) {
        return instanceIds[instance];
    }
    // @inheritdoc IDistributor
    function getDistributionURI(bytes32 distributorsId) external view returns (string memory) {
        DistributionComponent memory distributionComponent = distributionComponents[distributorsId];
        ICodeIndex codeIndex = getContractsIndex();
        return IDistribution(codeIndex.get(distributionComponent.id)).getMetadata();
    }

    function _addDistribution(bytes32 id, address initializerAddress) internal virtual {
        ICodeIndex codeIndex = getContractsIndex();
        if (codeIndex.get(id) == address(0)) revert DistributionNotFound(id);
        bytes32 distributorsId = keccak256(abi.encode(id, initializerAddress));
        if (distirbutionsSet.contains(distributorsId)) revert DistributionExists(distributorsId);
        distirbutionsSet.add(distributorsId);
        distributionComponents[distributorsId] = DistributionComponent(id, initializerAddress);
        emit DistributionAdded(id, initializerAddress);
    }

    function _removeDistribution(bytes32 distributorsId) internal virtual {
        if (!distirbutionsSet.contains(distributorsId)) revert DistributionNotFound(distributorsId);
        distirbutionsSet.remove(distributorsId);
        delete distributionComponents[distributorsId];
        emit DistributionRemoved(distributorsId);
    }

    /**
     * @notice Internal function to instantiate a new instance.
     * @dev WARNING: This function will DELEGATECALL to initializer. Initializer MUST be trusted contract.
     */
    function _instantiate(
        bytes32 distributorsId,
        bytes memory args
    ) internal virtual returns (address[] memory instances, bytes32 distributionName, uint256 distributionVersion) {
        ICodeIndex codeIndex = getContractsIndex();
        if (!distirbutionsSet.contains(distributorsId)) revert DistributionNotFound(distributorsId);
        DistributionComponent memory distributionComponent = distributionComponents[distributorsId];
        bytes4 selector = IInitializer.initialize.selector;
        // bytes memory instantiationArgs = initializer != address(0) ? args : bytes ("");
        (instances, distributionName, distributionVersion) = IDistribution(codeIndex.get(distributionComponent.id))
            .instantiate(args);
        if (distributionComponent.initializer != address(0)) {
            (bool success, bytes memory result) = address(distributionComponent.initializer).delegatecall(
                abi.encodeWithSelector(selector, instances, args)
            );
            if (!success) {
                if (result.length > 0) {
                    assembly {
                        let returndata_size := mload(result)
                        revert(add(32, result), returndata_size)
                    }
                } else {
                    revert("initializer delegatecall failed without revert reason");
                }
            }
        }
        numInstances++;
        uint256 instanceId = numInstances;
        uint256 instancesLength = instances.length;
        for (uint256 i; i < instancesLength; ++i) {
            instanceIds[instances[i]] = instanceId;
            distributionOf[instanceId] = distributorsId;
        }
        emit Instantiated(distributorsId, instanceId, args, instances);
        return (instances, distributionName, distributionVersion);
    }

    /**
     * @inheritdoc IERC7746
     * @notice This is ERC7746 hook must be called by instance methods that access scope is limited to the same instance or distribution
     * @dev it will revert if: (1) `msg.sender` is not a valid instance; (2) `maybeInstance` is not a valid instance (3) `instanceId` belongs to disactivated distribution
     */
    function beforeCall(
        bytes memory config,
        bytes4,
        address maybeInstance,
        uint256,
        bytes memory
    ) external view virtual returns (bytes memory) {
        address target = config.length > 0 ? abi.decode(config, (address)) : msg.sender;
        bytes32 distributorsId = distributionOf[getInstanceId(maybeInstance)];
        if (
            distributorsId != bytes32(0) &&
            getInstanceId(target) == getInstanceId(maybeInstance) &&
            distirbutionsSet.contains(distributorsId)
        ) {
            // ToDo: This check could be based on DistributionOf, hence allowing cross-instance calls
            // Use layerConfig to allow client to configure requirement for the call
            return abi.encode(distributorsId, "");
        }
        revert InvalidInstance(maybeInstance);
    }
    /**
     * @inheritdoc IERC7746
     * @notice This is ERC7746 hook must be called by instance methods that access scope is limited to the same instance or distribution
     * @dev it will revert if: (1) `msg.sender` is not a valid instance; (2) `maybeInstance` is not a valid instance (3) `instanceId` belongs to disactivated distribution
     */
    function afterCall(
        bytes memory config,
        bytes4,
        address maybeInstance,
        uint256,
        bytes memory,
        bytes memory
    ) external virtual {
        address target = config.length > 0 ? abi.decode(config, (address)) : msg.sender;
        bytes32 distributorsId = distributionOf[getInstanceId(maybeInstance)];
        if ((getInstanceId(target) != getInstanceId(maybeInstance)) && distirbutionsSet.contains(distributorsId)) {
            revert InvalidInstance(maybeInstance);
        }
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IDistributor).interfaceId || super.supportsInterface(interfaceId);
    }
}
