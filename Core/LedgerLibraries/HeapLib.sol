// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "./Types.sol";
import "./MarketManagementLib.sol";

/// @notice Min-heap and max-heap over blocks (4-ary heap). Each heap node holds a blockId,
/// and its key is s.minBlockData[account][marketId][blockId].val or s.blockDataMax[...].val.
/// We maintain the heaps when a block's extremum value changes.
library HeapLib {
    enum HeapType { MIN, MAX }

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

        // Update min block and heap
        _updateBlockAndHeap(account, marketId, blockId, newTilt, positionId, HeapType.MIN);

        // Update max block and heap
        _updateBlockAndHeap(account, marketId, blockId, newTilt, positionId, HeapType.MAX);
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
        uint256 start        = blockId * Types.BLOCK_SIZE;
        uint256 endExclusive = start + Types.BLOCK_SIZE;
        uint256[] memory positions = MarketManagementLib.getMarketPositions(marketId);
        if (endExclusive > positions.length) endExclusive = positions.length;

        int256  extremumVal = (heapType == HeapType.MIN) ? type(int256).max : type(int256).min;
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

    /// @dev Bubble the node with (blockId, val) upward; returns final index.
    function _bubbleUp(
        uint256[] storage heap,
        uint256 index,
        uint256 blockId,
        int256  val,
        address account,
        uint256 marketId,
        HeapType heapType
    ) private returns (uint256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        while (index > 0) {
            uint256 parent    = (index - 1) / 4;
            int256  parentVal = _getBlockVal(s, account, marketId, heap[parent], heapType);
            bool    swap      =
                (heapType == HeapType.MIN)
                    ? (parentVal > val)
                    : (parentVal < val);

            if (!swap) break;

            // move parent down one level and fix its index
            _place(s, heap, account, marketId, index, heap[parent], heapType);
            index = parent;
        }
        _place(s, heap, account, marketId, index, blockId, heapType);
        return index;
    }

    /// @dev Bubble the node with (blockId, val) downward; returns final index.
    function _bubbleDown(
        uint256[] storage heap,
        uint256 index,
        uint256 blockId,
        int256  val,
        address account,
        uint256 marketId,
        HeapType heapType
    ) private returns (uint256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        while (true) {
            uint256 extremumChild    = index;
            int256  extremumChildVal = val; // current node's value

            // 4-ary children: 4*index + 1 .. 4*index + 4
            for (uint256 i = 1; i <= 4; i++) {
                uint256 child = index * 4 + i;
                if (child >= heap.length) break;
                int256 childVal = _getBlockVal(s, account, marketId, heap[child], heapType);
                bool better =
                    (heapType == HeapType.MIN)
                        ? (childVal < extremumChildVal)
                        : (childVal > extremumChildVal);

                if (better) {
                    extremumChild    = child;
                    extremumChildVal = childVal;
                }
            }
            if (extremumChild == index) break;

            // move extremum child up
            _place(s, heap, account, marketId, index, heap[extremumChild], heapType);
            index = extremumChild;
        }
        _place(s, heap, account, marketId, index, blockId, heapType);
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
        uint256[] storage heap =
            (heapType == HeapType.MIN)
                ? s.minTopHeap[account][marketId]
                : s.topHeapMax[account][marketId];

        int256 newVal = _getBlockVal(s, account, marketId, blockId, heapType);

        (bool found, uint256 idx) = _getIndex(s, account, marketId, blockId, heapType);

        if (!found) {
            // Insert: append placeholder, then bubble up the new node.
            heap.push(); // increase length
            uint256 newIdx = heap.length - 1;
            _bubbleUp(heap, newIdx, blockId, newVal, account, marketId, heapType);
            return;
        }

        // Update: node exists at idx; its key changed to newVal.
        // Try moving up; if it didn't move, try moving down.
        idx = _bubbleUp(heap, idx, blockId, newVal, account, marketId, heapType);
        _bubbleDown(heap, idx, blockId, newVal, account, marketId, heapType);
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
}
