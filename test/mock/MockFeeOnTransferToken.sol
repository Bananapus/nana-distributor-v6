// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC-20 that charges a fixed basis-point fee on every transfer. The fee is burned (removed from supply)
/// so `balanceOf(recipient)` only increases by `amount * (BPS_DENOMINATOR - feeBps) / BPS_DENOMINATOR`.
/// @dev Used to exercise `JBDistributor._acceptErc20FundsFrom`'s balance-delta crediting on fee-on-transfer tokens.
contract MockFeeOnTransferToken is ERC20 {
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public immutable feeBps;

    constructor(uint256 _feeBps) ERC20("MockFOT", "MFOT") {
        require(_feeBps < BPS_DENOMINATOR, "fee >= 100%");
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / BPS_DENOMINATOR;
        super._update(from, to, value - fee);
        super._update(from, address(0xdead), fee);
    }
}
