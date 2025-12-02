// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

contract Create2Factory {
    event ContractDeployed(address indexed deployed, bytes32 indexed salt, address indexed deployer);

    function deploy(bytes32 salt, bytes memory bytecode) external returns (address deployed) {
        assembly {
            deployed := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(deployed != address(0), "Create2Factory: deployment failed");
        emit ContractDeployed(deployed, salt, msg.sender);
    }

    function computeAddress(bytes32 salt, bytes32 bytecodeHash) external view returns (address predicted) {
        predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)
                    )
                )
            )
        );
    }
}
