// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "src/layer1/verifiers/IVerifier.sol";

contract TestVerifier is IVerifier {
    bool private shouldFail;

    function makeVerifierToFail() external {
        shouldFail = true;
    }

    function makeVerifierToSucceed() external {
        shouldFail = false;
    }

    function verifyProof(
        Context calldata,
        TaikoData.Transition calldata,
        TaikoData.TierProof calldata
    )
        external
    {
        require(!shouldFail, "IVerifier failure");
    }

    function verifyBatchProof(ContextV2[] calldata, TaikoData.TierProof calldata) external {
        require(!shouldFail, "IVerifier failure");
    }
}
