// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {DonationVault4626} from "../src/DonationVault4626.sol";

contract LocalFactory {
    function deploy() external returns (LaunchToken token, DonationVault4626 vault) {
        token = new LaunchToken{salt: bytes32(uint256(1))}();
        vault = new DonationVault4626{salt: bytes32(uint256(2))}(address(token));
    }
}

contract FactoryCompatibilityTest is Test {
    function test_create2FactoryKeepsSupplyAndAppNeedsNoInitialization() public {
        vm.chainId(11155111);
        LocalFactory factory = new LocalFactory();
        (LaunchToken token, DonationVault4626 vault) = factory.deploy();
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(address(vault.token()), address(token));
        assertEq(vault.asset(), address(token));
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        _checkRuntime(address(token));
        _checkRuntime(address(vault));
    }

    function test_constructorRejectsEth() public {
        LaunchToken token = new LaunchToken();
        bytes memory code = abi.encodePacked(type(DonationVault4626).creationCode, abi.encode(address(token)));
        vm.deal(address(this), 1);
        address deployed;
        assembly ("memory-safe") {
            deployed := create(1, add(code, 0x20), mload(code))
        }
        assertEq(deployed, address(0));
    }

    function _checkRuntime(address deployed) internal view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
