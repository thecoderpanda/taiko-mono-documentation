// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@risc0/contracts/IRiscZeroVerifier.sol";
import "../common/EssentialContract.sol";
import "../common/LibStrings.sol";
import "../L1/ITaikoL1.sol";
import "./IVerifier.sol";
import "./libs/LibPublicInput.sol";

/// @title RiscZeroVerifier
/// @custom:security-contact security@taiko.xyz
contract RiscZeroVerifier is EssentialContract, IVerifier {
    // [32, 0, 0, 0] -- big-endian uint32(32) for hash bytes len
    bytes private constant FIXED_JOURNAL_HEADER = hex"20000000";

    /// @notice Trusted imageId mapping
    mapping(bytes32 imageId => bool trusted) public isImageTrusted;

    uint256[49] private __gap;

    /// @dev Emitted when a trusted image is set / unset.
    /// @param imageId The id of the image
    /// @param trusted True if trusted, false otherwise
    event ImageTrusted(bytes32 imageId, bool trusted);

    /// @dev Emitted when a proof is verified
    event ProofVerified(bytes32 metaHash, bytes32 publicInputHash);

    error RISC_ZERO_INVALID_IMAGE_ID();
    error RISC_ZERO_INVALID_PROOF();

    /// @notice Initializes the contract with the provided address manager.
    /// @param _owner The address of the owner.
    /// @param _rollupAddressManager The address of the AddressManager.
    function init(address _owner, address _rollupAddressManager) external initializer {
        __Essential_init(_owner, _rollupAddressManager);
    }

    /// @notice Sets/unsets an the imageId as trusted entity
    /// @param _imageId The id of the image.
    /// @param _trusted True if trusted, false otherwise.
    function setImageIdTrusted(bytes32 _imageId, bool _trusted) external onlyOwner {
        isImageTrusted[_imageId] = _trusted;

        emit ImageTrusted(_imageId, _trusted);
    }

    /// @inheritdoc IVerifier
    function verifyProofs(Context[] calldata _ctx, TaikoData.TierProof calldata _proof) external {
        // Decode will throw if not proper length/encoding
        (bytes memory seal, bytes32 blockImageId, bytes32 aggregationImageId) =
            abi.decode(_proof.data, (bytes, bytes32, bytes32));

        // Check if the aggregation program is trusted
        if (!isImageTrusted[aggregationImageId]) {
            revert RISC_ZERO_INVALID_IMAGE_ID();
        }
        // Check if the block proving program is trusted
        if (!isImageTrusted[blockImageId]) {
            revert RISC_ZERO_INVALID_IMAGE_ID();
        }

        // Collect public inputs
        bytes32[] memory public_inputs = new bytes32[](_ctx.length + 1);
        // First public input is the block proving program key
        public_inputs[0] = blockImageId;
        // All other inputs are the block program public inputs (a single 32 byte value)
        for (uint256 i = 0; i < _ctx.length; i++) {
            public_inputs[i + 1] = LibPublicInput.hashPublicInputs(
                _ctx[i].tran,
                address(this),
                address(0),
                _ctx[i].prover,
                _ctx[i].metaHash,
                taikoChainId()
            );
            emit ProofVerified(_ctx[i].metaHash, public_inputs[i + 1]);
        }

        // journalDigest is the sha256 hash of the hashed public input
        bytes32 journalDigest =
            sha256(bytes.concat(FIXED_JOURNAL_HEADER, abi.encodePacked(public_inputs)));

        // call risc0 verifier contract
        (bool success,) = resolve(LibStrings.B_RISCZERO_GROTH16_VERIFIER, false).staticcall(
            abi.encodeCall(IRiscZeroVerifier.verify, (seal, aggregationImageId, journalDigest))
        );
        if (!success) {
            revert RISC_ZERO_INVALID_PROOF();
        }
    }

    function taikoChainId() internal view virtual returns (uint64) {
        return ITaikoL1(resolve(LibStrings.B_TAIKO, false)).getConfig().chainId;
    }
}
