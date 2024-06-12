// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../../signal/ISignalService.sol";
import "./LibUtils.sol";

/// @title LibVerifying
/// @notice A library for handling block verification in the Taiko protocol.
/// @custom:security-contact security@taiko.xyz
library LibVerifying {
    using LibMath for uint256;

    struct Local {
        TaikoData.SlotB b;
        uint64 blockId;
        uint64 slot;
        uint64 numBlocksVerified;
        uint32 tid;
        uint32 lastVerifiedTransitionId;
        uint16 tier;
        bytes32 blockHash;
        address prover;
        ITierRouter tierRouter;
    }

    /// @dev Emitted when a block is verified.
    /// @param blockId The ID of the verified block.
    /// @param prover The prover whose transition is used for verifying the
    /// block.
    /// @param blockHash The hash of the verified block.
    /// @param stateRoot Deprecated and always zero.
    /// @param tier The tier ID of the proof.
    event BlockVerified(
        uint256 indexed blockId,
        address indexed prover,
        bytes32 blockHash,
        bytes32 stateRoot,
        uint16 tier
    );

    /// @notice Emitted when some state variable values changed.
    /// @dev This event is currently used by Taiko node/client for block proposal/proving.
    /// @param slotB The SlotB data structure.
    event StateVariablesUpdated(TaikoData.SlotB slotB);

    // Warning: Any errors defined here must also be defined in TaikoErrors.sol.
    error L1_BLOCK_MISMATCH();
    error L1_INVALID_CONFIG();
    error L1_INVALID_GENESIS_HASH();
    error L1_TRANSITION_ID_ZERO();
    error L1_TOO_LATE();

    /// @notice Initializes the Taiko protocol state.
    /// @param _state The state to initialize.
    /// @param _config The configuration for the Taiko protocol.
    /// @param _genesisBlockHash The block hash of the genesis block.
    function init(
        TaikoData.State storage _state,
        TaikoData.Config memory _config,
        bytes32 _genesisBlockHash
    )
        internal
    {
        if (!_isConfigValid(_config)) revert L1_INVALID_CONFIG();

        _setupGenesisBlock(_state, _genesisBlockHash);
    }

    function resetGenesisHash(TaikoData.State storage _state, bytes32 _genesisBlockHash) internal {
        if (_state.slotB.numBlocks != 1) revert L1_TOO_LATE();

        _setupGenesisBlock(_state, _genesisBlockHash);
    }

    /// @dev Verifies up to N blocks.
    function verifyBlocks(
        TaikoData.State storage _state,
        IERC20 _tko,
        TaikoData.Config memory _config,
        IAddressResolver _resolver,
        uint64 _maxBlocksToVerify
    )
        internal
    {
        if (_maxBlocksToVerify == 0) {
            return;
        }

        Local memory l;
        l.b = _state.slotB;
        l.blockId = l.b.lastVerifiedBlockId;
        l.slot = l.blockId % _config.blockRingBufferSize;

        TaikoData.Block storage blk = _state.blocks[l.slot];
        if (blk.blockId != l.blockId) revert L1_BLOCK_MISMATCH();

        l.lastVerifiedTransitionId = blk.verifiedTransitionId;
        l.tid = l.lastVerifiedTransitionId;

        // The following scenario should never occur but is included as a
        // precaution.
        if (l.tid == 0) revert L1_TRANSITION_ID_ZERO();

        // The `blockHash` variable represents the most recently trusted
        // blockHash on L2.
        l.blockHash = _state.transitions[l.slot][l.tid].blockHash;

        // Unchecked is safe:
        // - assignment is within ranges
        // - blockId and numBlocksVerified values incremented will still be OK in the
        // next 584K years if we verifying one block per every second
        unchecked {
            ++l.blockId;

            while (l.blockId < l.b.numBlocks && l.numBlocksVerified < _maxBlocksToVerify) {
                l.slot = l.blockId % _config.blockRingBufferSize;

                blk = _state.blocks[l.slot];
                if (blk.blockId != l.blockId) revert L1_BLOCK_MISMATCH();

                l.tid = LibUtils.getTransitionId(_state, blk, l.slot, l.blockHash);
                // When `tid` is 0, it indicates that there is no proven
                // transition with its parentHash equal to the blockHash of the
                // most recently verified block.
                if (l.tid == 0) break;

                // A transition with the correct `parentHash` has been located.
                TaikoData.TransitionState storage ts = _state.transitions[l.slot][l.tid];

                // It's not possible to verify this block if either the
                // transition is contested and awaiting higher-tier proof or if
                // the transition is still within its cooldown period.
                l.tier = ts.tier;

                if (ts.contester != address(0)) {
                    break;
                } else {
                    if (l.tierRouter == ITierRouter(address(0))) {
                        l.tierRouter =
                            ITierRouter(_resolver.resolve(LibStrings.B_TIER_ROUTER, false));
                    }

                    if (
                        !LibUtils.isPostDeadline(
                            ts.timestamp,
                            l.b.lastUnpausedAt,
                            ITierProvider(l.tierRouter.getProvider(l.blockId)).getTier(l.tier)
                                .cooldownWindow
                        )
                    ) {
                        // If cooldownWindow is 0, the block can theoretically
                        // be proved and verified within the same L1 block.
                        break;
                    }
                }

                // Update variables
                l.lastVerifiedTransitionId = l.tid;
                l.blockHash = ts.blockHash;
                l.prover = ts.prover;

                _tko.transfer(l.prover, ts.validityBond);

                // Note: We exclusively address the bonds linked to the
                // transition used for verification. While there may exist
                // other transitions for this block, we disregard them entirely.
                // The bonds for these other transitions are burned (more precisely held in custody)
                // either when the transitions are generated or proven. In such cases, both the
                // provers and contesters of those transitions forfeit their bonds.

                emit BlockVerified({
                    blockId: l.blockId,
                    prover: l.prover,
                    blockHash: l.blockHash,
                    stateRoot: 0, // Always use 0 to avoid an unnecessary sload
                    tier: l.tier
                });

                ++l.blockId;
                ++l.numBlocksVerified;
            }

            if (l.numBlocksVerified != 0) {
                uint64 lastVerifiedBlockId = l.b.lastVerifiedBlockId + l.numBlocksVerified;
                l.slot = lastVerifiedBlockId % _config.blockRingBufferSize;

                _state.slotB.lastVerifiedBlockId = lastVerifiedBlockId;
                _state.blocks[l.slot].verifiedTransitionId = l.lastVerifiedTransitionId;

                // Sync chain data when necessary
                if (
                    lastVerifiedBlockId
                        > _state.slotA.lastSyncedBlockId + _config.blockSyncThreshold
                ) {
                    _state.slotA.lastSyncedBlockId = lastVerifiedBlockId;
                    _state.slotA.lastSynecdAt = uint64(block.timestamp);

                    bytes32 stateRoot =
                        _state.transitions[l.slot][l.lastVerifiedTransitionId].stateRoot;

                    ISignalService(_resolver.resolve(LibStrings.B_SIGNAL_SERVICE, false))
                        .syncChainData(
                        _config.chainId, LibStrings.H_STATE_ROOT, lastVerifiedBlockId, stateRoot
                    );
                }
            }
        }
    }

    /// @notice Emit events used by client/node.
    function emitEventForClient(TaikoData.State storage _state) internal {
        emit StateVariablesUpdated({ slotB: _state.slotB });
    }

    function _setupGenesisBlock(
        TaikoData.State storage _state,
        bytes32 _genesisBlockHash
    )
        private
    {
        if (_genesisBlockHash == 0) revert L1_INVALID_GENESIS_HASH();
        // Init state
        _state.slotA.genesisHeight = uint64(block.number);
        _state.slotA.genesisTimestamp = uint64(block.timestamp);
        _state.slotB.numBlocks = 1;

        // Init the genesis block
        TaikoData.Block storage blk = _state.blocks[0];
        blk.nextTransitionId = 2;
        blk.proposedAt = uint64(block.timestamp);
        blk.verifiedTransitionId = 1;
        blk.metaHash = bytes32(uint256(1)); // Give the genesis metahash a non-zero value.

        // Init the first state transition
        TaikoData.TransitionState storage ts = _state.transitions[0][1];
        ts.blockHash = _genesisBlockHash;
        ts.prover = address(0);
        ts.timestamp = uint64(block.timestamp);

        emit BlockVerified({
            blockId: 0,
            prover: address(0),
            blockHash: _genesisBlockHash,
            stateRoot: 0,
            tier: 0
        });
    }

    function _isConfigValid(TaikoData.Config memory _config) private view returns (bool) {
        if (
            _config.chainId <= 1 || _config.chainId == block.chainid //
                || _config.blockMaxProposals <= 1
                || _config.blockRingBufferSize <= _config.blockMaxProposals + 1
                || _config.blockMaxGasLimit == 0 || _config.livenessBond == 0
                || _config.maxBlocksToVerify % 2 != 0
        ) return false;

        return true;
    }
}
