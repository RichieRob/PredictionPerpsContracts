// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./0_Types.sol";

/// @notice Min-heap and (optionally) max-heap over blocks (4-ary heap).
/// Each heap node holds a blockId, and its key is
///   - s.minBlockData[account][marketId][blockId].val for MIN
///   - s.blockDataMax[account][marketId][blockId].val for MAX
///
/// We now **only** maintain the MAX side for the DMM in NON-resolving markets.
/// Everyone else (traders, resolving markets) only pays for MIN updates.
library HeapLib {
    struct HeapContext {
        address account;
        uint256 marketId;
        HeapType heapType;
    }

    enum HeapType { MIN, MAX }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Only track max-heap for the DMM in non-resolving markets.
    function _shouldTrackMax(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId
    ) private view returns (bool) {
        if (s.doesResolve[marketId]) return false;
        // Only the single DMM for this market needs redeemability (maxTilt)
        return (s.marketToDMM[marketId] == account);
    }

    /*//////////////////////////////////////////////////////////////
                               UPDATE TILT
    //////////////////////////////////////////////////////////////*/

    function updateTilt(
        address account,
        uint256 marketId,
        uint256 positionId,
        int256  delta
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256 blockId = positionId / Types.BLOCK_SIZE;

        int256 newTilt = s.tilt[account][marketId][positionId] + delta;
        s.tilt[account][marketId][positionId] = newTilt;

        // ── Always maintain MIN structures (solvency constraint) ──
        _updateBlockAndHeap(
            account,
            marketId,
            blockId,
            newTilt,
            positionId,
            HeapType.MIN
        );

        // ── Only maintain MAX tilts for the DMM in non-resolving markets ──
        if (_shouldTrackMax(s, account, marketId)) {
            _updateBlockAndHeap(
                account,
                marketId,
                blockId,
                newTilt,
                positionId,
                HeapType.MAX
            );
        }
        // For all other accounts/markets, MAX side is never updated and
        // getMaxTilt() will simply see an empty heap (length == 0).
    }

    function _updateBlockAndHeap(
        address account,
        uint256 marketId,
        uint256 blockId,
        int256  newTilt,
        uint256 positionId,
        HeapType heapType
    ) private {
        StorageLib.Storage storage s = StorageLib.getStorage();
        Types.BlockData storage b =
            (heapType == HeapType.MIN)
                ? s.minBlockData[account][marketId][blockId]
                : s.blockDataMax[account][marketId][blockId];

        // Lazy init
        if (b.id == 0 && b.val == 0) {
            b.id  = positionId;
            b.val = newTilt;
            _updateTopHeap(account, marketId, blockId, heapType);
            return;
        }

        bool isExtremum = (positionId == b.id);
        bool improved   =
            (heapType == HeapType.MIN)
                ? (newTilt <= b.val)
                : (newTilt >= b.val);

        if (isExtremum) {
            // Extremum improved
            if (improved) {
                b.val = newTilt;
                _updateTopHeap(account, marketId, blockId, heapType);
                return;
            }
            // Extremum worsened: rescan block, then fix heap
            _rescanBlock(account, marketId, blockId, heapType);
            return;
        }

        // Non-extremum updated
        bool newExtremum =
            (heapType == HeapType.MIN)
                ? (newTilt < b.val)
                : (newTilt > b.val);

        if (newExtremum) {
            b.id  = positionId;
            b.val = newTilt;
            _updateTopHeap(account, marketId, blockId, heapType);
        }
        // else: nothing to do
    }

    /*//////////////////////////////////////////////////////////////
                              BLOCK RESCAN
    //////////////////////////////////////////////////////////////*/

    function _rescanBlock(
        address account,
        uint256 marketId,
        uint256 blockId,
        HeapType heapType
    ) private {
        StorageLib.Storage storage s = StorageLib.getStorage();

        // Use storage, not memory → no O(nPositions) copy
        uint256[] storage positions = s.marketPositions[marketId];
        uint256 len = positions.length;

        uint256 start        = blockId * Types.BLOCK_SIZE;
        uint256 endExclusive = start + Types.BLOCK_SIZE;
        if (endExclusive > len) {
            endExclusive = len;
        }

        int256  extremumVal = (heapType == HeapType.MIN)
            ? type(int256).max
            : type(int256).min;
        uint256 extremumId  = 0;

        for (uint256 i = start; i < endExclusive; i++) {
            uint256 k = positions[i];
            int256 v  = s.tilt[account][marketId][k];

            if (
                (heapType == HeapType.MIN && v < extremumVal) ||
                (heapType == HeapType.MAX && v > extremumVal)
            ) {
                extremumVal = v;
                extremumId  = k;
            }
        }

        Types.BlockData storage b =
            (heapType == HeapType.MIN)
                ? s.minBlockData[account][marketId][blockId]
                : s.blockDataMax[account][marketId][blockId];

        b.val = extremumVal;
        b.id  = extremumId;

        _updateTopHeap(account, marketId, blockId, heapType);
    }

    /*//////////////////////////////////////////////////////////////
                                HEAP CORE
    //////////////////////////////////////////////////////////////*/

    // index map helpers (store idx+1 so 0 == not present)
    function _getIndex(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId,
        uint256 blockId,
        HeapType heapType
    ) private view returns (bool found, uint256 idx) {
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) storage indexMap =
            (heapType == HeapType.MIN) ? s.minHeapIndex : s.heapIndexMax;

        uint256 v = indexMap[account][marketId][blockId];
        if (v == 0) return (false, 0);
        return (true, v - 1);
    }

    function _setIndex(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId,
        uint256 blockId,
        uint256 idx,
        HeapType heapType
    ) private {
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) storage indexMap =
            (heapType == HeapType.MIN) ? s.minHeapIndex : s.heapIndexMax;

        indexMap[account][marketId][blockId] = idx + 1;
    }

    function _place(
        StorageLib.Storage storage s,
        uint256[] storage heap,
        address account,
        uint256 marketId,
        uint256 idx,
        uint256 blockId,
        HeapType heapType
    ) private {
        heap[idx] = blockId;
        _setIndex(s, account, marketId, blockId, idx, heapType);
    }

    /// @dev Bubble the node upward
    function _bubbleUp(
        StorageLib.Storage storage s,
        uint256[] storage heap,
        HeapContext memory ctx,
        uint256 index,
        uint256 blockId,
        int256 val
    ) private returns (uint256) {
        while (index > 0) {
            uint256 parent = (index - 1) / 4;
            uint256 parentBlockId = heap[parent];
            int256 parentVal = _getBlockVal(
                s,
                ctx.account,
                ctx.marketId,
                parentBlockId,
                ctx.heapType
            );

            bool shouldSwap = ctx.heapType == HeapType.MIN
                ? parentVal > val
                : parentVal < val;

            if (!shouldSwap) break;

            _place(s, heap, ctx.account, ctx.marketId, index, parentBlockId, ctx.heapType);
            index = parent;
        }
        _place(s, heap, ctx.account, ctx.marketId, index, blockId, ctx.heapType);
        return index;
    }

    function _bubbleDown(
        StorageLib.Storage storage s,
        uint256[] storage heap,
        HeapContext memory ctx,
        uint256 index,
        uint256 blockId,
        int256 val
    ) private returns (uint256) {
        while (true) {
            uint256 best = index;
            int256 bestVal = val;

            for (uint256 i = 1; i <= 4; i++) {
                uint256 child = index * 4 + i;
                if (child >= heap.length) break;

                int256 childVal = _getBlockVal(
                    s,
                    ctx.account,
                    ctx.marketId,
                    heap[child],
                    ctx.heapType
                );

                if (
                    (ctx.heapType == HeapType.MIN && childVal < bestVal) ||
                    (ctx.heapType == HeapType.MAX && childVal > bestVal)
                ) {
                    best = child;
                    bestVal = childVal;
                }
            }

            if (best == index) break;

            _place(s, heap, ctx.account, ctx.marketId, index, heap[best], ctx.heapType);
            index = best;
        }
        _place(s, heap, ctx.account, ctx.marketId, index, blockId, ctx.heapType);
        return index;
    }

    function _getBlockVal(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId,
        uint256 blockId,
        HeapType heapType
    ) private view returns (int256) {
        Types.BlockData storage b =
            (heapType == HeapType.MIN)
                ? s.minBlockData[account][marketId][blockId]
                : s.blockDataMax[account][marketId][blockId];

        return b.val;
    }

    /// @dev Insert or update a block's key in the top heap.
    function _updateTopHeap(
        address account,
        uint256 marketId,
        uint256 blockId,
        HeapType heapType
    ) private {
        StorageLib.Storage storage s = StorageLib.getStorage();

        uint256[] storage heap = heapType == HeapType.MIN
            ? s.minTopHeap[account][marketId]
            : s.topHeapMax[account][marketId];

        int256 newVal = _getBlockVal(s, account, marketId, blockId, heapType);

        HeapContext memory ctx = HeapContext({
            account: account,
            marketId: marketId,
            heapType: heapType
        });

        (bool found, uint256 idx) = _getIndex(s, account, marketId, blockId, heapType);

        if (!found) {
            // insert
            uint256 newIdx = heap.length;
            heap.push();
            _bubbleUp(s, heap, ctx, newIdx, blockId, newVal);
            return;
        }

        // update existing
        idx = _bubbleUp(s, heap, ctx, idx, blockId, newVal);
        _bubbleDown(s, heap, ctx, idx, blockId, newVal);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function getMinTilt(
        address account,
        uint256 marketId
    ) internal view returns (int256, uint256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256[] storage heap = s.minTopHeap[account][marketId];
        if (heap.length == 0) {
            return (0, 0);
        }
        uint256 blockId = heap[0];
        Types.BlockData storage b = s.minBlockData[account][marketId][blockId];
        int256  minVal = b.val;
        uint256 minId  = b.id;
        if (s.isExpanding[marketId] && minVal > 0) {
            return (0, 0); // Clamp to 0 for expanding
        }
        return (minVal, minId);
    }

    function getMaxTilt(
        address account,
        uint256 marketId
    ) internal view returns (int256, uint256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256[] storage heap = s.topHeapMax[account][marketId];
        if (heap.length == 0) {
            // For non-DMM / resolving markets this will just be (0, 0),
            // and SolvencyLib already only uses redeemable for DMM+non-res.
            return (0, 0);
        }
        uint256 blockId = heap[0];
        Types.BlockData storage b = s.blockDataMax[account][marketId][blockId];
        int256  maxVal = b.val;
        uint256 maxId  = b.id;
        if (s.isExpanding[marketId] && maxVal < 0) {
            return (0, 0); // Clamp to 0 for expanding
        }
        return (maxVal, maxId);
    }

    function getMinTiltPosition(
        address account,
        uint256 marketId
    ) internal view returns (uint256) {
        (, uint256 minId) = getMinTilt(account, marketId);
        return minId;
    }
/// @dev Helper to compute the second min in the min block, handling duplicates.
    function _computeBlockSecondMin(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId,
        uint256 minBlockId,
        int256 minVal
    ) private view returns (int256) {
        int256 blockSecondVal = type(int256).max;

        uint256 start = minBlockId * Types.BLOCK_SIZE;
        uint256 len = s.marketPositions[marketId].length;
        uint256 endExclusive = start + Types.BLOCK_SIZE;
        if (endExclusive > len) {
            endExclusive = len;
        }

        // Only scan if block has at least 2 positions
        if (endExclusive - start < 2) {
            return blockSecondVal;
        }

        // Track count of positions with exact minVal (for duplicates)
        uint256 count_min = 0;

        // Scan the block to find second min, skipping/excluding the known minVal instances
        for (uint256 i = start; i < endExclusive; i++) {
            uint256 k = s.marketPositions[marketId][i];
            int256 v = s.tilt[account][marketId][k];

            if (v == minVal) {
                count_min++;
            } else if (v < blockSecondVal) {
                blockSecondVal = v;
            }
        }

        // If multiple positions share the minVal, second min is also minVal
        if (count_min >= 2) {
            blockSecondVal = minVal;
        } else if (blockSecondVal == type(int256).max) {
            // No non-min values found: no second in block
        }
        // else: blockSecondVal is the smallest non-min value in the block

        return blockSecondVal;
    }

  
       /// @notice Computes the delta between the global minimum tilt and the global second minimum tilt
    ///         for a given account and market. In expanding markets we also treat the implicit
    ///         "otherBucket" with tilt 0 as another candidate for min / second-min.
    ///         Returns 0 if no second min exists (after all candidates) or after clamping.
    function _getMinTiltDelta(
        address account,
        uint256 marketId
    ) internal view returns (int256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256[] storage heap = s.minTopHeap[account][marketId];
        if (heap.length == 0) {
            // No positions or heap entries: delta is 0
            return 0;
        }

        // Fetch the global min from the heap root
        uint256 minBlockId = heap[0];
        Types.BlockData storage b =
            s.minBlockData[account][marketId][minBlockId];
        int256 minVal = b.val;

        // Compute block second min using helper to reduce stack depth
        int256 blockSecondVal = _computeBlockSecondMin(
            s,
            account,
            marketId,
            minBlockId,
            minVal
        );

        // Find the smallest val among the direct children in the heap (potential next mins)
        int256 otherMin = type(int256).max;
        for (uint256 i = 1; i <= 4; i++) {
            uint256 childIdx = i;
            if (childIdx >= heap.length) break;
            uint256 childBlock = heap[childIdx];
            int256 childVal = _getBlockVal(
                s,
                account,
                marketId,
                childBlock,
                HeapType.MIN
            );
            if (childVal < otherMin) {
                otherMin = childVal;
            }
        }

        // Determine global second min from blockSecondVal and child blocks
        int256 secondVal = type(int256).max;
        if (blockSecondVal != type(int256).max) {
            secondVal = blockSecondVal;
        }
        if (
            otherMin != type(int256).max &&
            (otherMin < secondVal || secondVal == type(int256).max)
        ) {
            secondVal = otherMin;
        }

        bool isExpanding = s.isExpanding[marketId];

        // In NON-expanding markets, if we still have no second min, we're done.
        if (!isExpanding && secondVal == type(int256).max) {
            return 0;
        }

        // ─────────────────────────────────────
        // Expanding markets: fold in "otherBucket" with tilt 0
        // ─────────────────────────────────────
        if (isExpanding) {
            int256 otherTilt = 0; // implicit bucket

            if (otherTilt < minVal) {
                // otherTilt becomes new global min; old min becomes candidate second
                if (secondVal == type(int256).max || minVal < secondVal) {
                    secondVal = minVal;
                }
                minVal = otherTilt;
            } else if (otherTilt > minVal) {
                // otherTilt is above current min; may become second
                if (otherTilt < secondVal) {
                    secondVal = otherTilt;
                }
            } else {
                // otherTilt == minVal → at least two entries at the minimum
                if (secondVal == type(int256).max || secondVal > minVal) {
                    secondVal = minVal;
                }
            }
        }

        // If after considering all candidates we still have no second min, delta is 0
        if (secondVal == type(int256).max) {
            return 0;
        }

        // Apply clamping for expanding markets
        if (isExpanding && minVal > 0) {
            minVal = 0;
        }
        if (isExpanding && secondVal > 0) {
            secondVal = 0;
        }

        // Delta is always non-negative since secondVal >= minVal
        return secondVal - minVal;
    }




}
