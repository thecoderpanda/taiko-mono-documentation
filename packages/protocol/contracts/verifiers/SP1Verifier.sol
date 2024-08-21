// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@sp1-contracts/src/ISP1Verifier.sol";
import "../common/EssentialContract.sol";
import "../common/LibStrings.sol";
import "../L1/ITaikoL1.sol";
import "./IVerifier.sol";
import "./libs/LibPublicInput.sol";

/// @title SP1Verifier
/// @custom:security-contact security@taiko.xyz
contract SP1Verifier is EssentialContract, IVerifier {
    /// @notice The verification keys mappings for the proving programs.
    mapping(bytes32 provingProgramVKey => bool trusted) public isProgramTrusted;

    uint256[49] private __gap;

    /// @dev Emitted when a trusted image is set / unset.
    /// @param programVKey The id of the image
    /// @param trusted The block's assigned prover.
    event ProgramTrusted(bytes32 programVKey, bool trusted);

    error SP1_INVALID_PROGRAM_VKEY();
    error SP1_INVALID_PROOF();

    /// @notice Initializes the contract with the provided address manager.
    /// @param _owner The address of the owner.
    /// @param _addressManager The address of the AddressManager.
    function init(address _owner, address _addressManager) external initializer {
        __Essential_init(_owner, _addressManager);
    }

    /// @notice Sets/unsets an the program's verification key as trusted entity
    /// @param _programVKey The verification key of the program.
    /// @param _trusted True if trusted, false otherwise.
    function setProgramTrusted(bytes32 _programVKey, bool _trusted) external onlyOwner {
        isProgramTrusted[_programVKey] = _trusted;

        emit ProgramTrusted(_programVKey, _trusted);
    }

    /// @inheritdoc IVerifier
    function verifyProofs(
        Context[] calldata _ctx,
        TaikoData.TierProof calldata _proof
    )
        external
        view
    {
        // Extract the necessary data
        bytes32 aggregation_program = bytes32(_proof.data[0:32]);
        bytes32 block_proving_program = bytes32(_proof.data[32:64]);
        bytes memory proof = _proof.data[64:];

        // Check if the aggregation program is trusted
        if (!isProgramTrusted[aggregation_program]) {
            revert SP1_INVALID_PROGRAM_VKEY();
        }
        // Check if the block proving program is trusted
        if (!isProgramTrusted[block_proving_program]) {
            revert SP1_INVALID_PROGRAM_VKEY();
        }

        // Collect public inputs
        bytes32[] memory public_inputs = new bytes32[](_ctx.length + 1);
        // First public input is the block proving program key
        public_inputs[0] = block_proving_program;
        // All other inputs are the block program public inputs (a single 32 byte value)
        for (uint256 i = 0; i < _ctx.length; i++) {
            // Need to be converted from bytes32 to bytes
            public_inputs[i + 1] = sha256(
                abi.encodePacked(
                    LibPublicInput.hashPublicInputs(
                        _ctx[i].tran,
                        address(this),
                        address(0),
                        _ctx[i].prover,
                        _ctx[i].metaHash,
                        taikoChainId()
                    )
                )
            );
        }

        // _proof.data[32:] is the succinct's proof position
        (bool success,) = sp1RemoteVerifier().staticcall(
            abi.encodeCall(
                ISP1Verifier.verifyProof,
                (block_proving_program, abi.encodePacked(public_inputs), proof)
            )
        );

        if (!success) {
            revert SP1_INVALID_PROOF();
        }
    }

    function taikoChainId() internal view virtual returns (uint64) {
        return ITaikoL1(resolve(LibStrings.B_TAIKO, false)).getConfig().chainId;
    }

    function sp1RemoteVerifier() public view virtual returns (address) {
        return resolve(LibStrings.B_SP1_REMOTE_VERIFIER, false);
    }
}
