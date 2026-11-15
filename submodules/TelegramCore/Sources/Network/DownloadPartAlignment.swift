import Foundation

private let possiblePartLengths: [Int64] = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576]

func alignPartFetchRange(partRange: Range<Int64>, minPartSize: Int64, maxPartSize: Int64, alignment: Int64, boundaryLimit: Int64) -> (partRange: Range<Int64>, fetchRange: Range<Int64>) {
    var partRange = partRange
    
    let lowerPartitionIndex = partRange.lowerBound / boundaryLimit
    let upperPartitionIndex = (partRange.upperBound - 1) / boundaryLimit
    if lowerPartitionIndex != upperPartitionIndex {
        partRange = partRange.lowerBound ..< (upperPartitionIndex * boundaryLimit)
    }
    
    let absolutePartLowerBound = (partRange.lowerBound / boundaryLimit) * boundaryLimit
    let absolutePartUpperBound = absolutePartLowerBound + boundaryLimit
    let maxPartRange = absolutePartLowerBound ..< absolutePartUpperBound
    
    let alignedPartLowerBound = (partRange.lowerBound / alignment) * alignment
    let alignmentDifference = partRange.lowerBound - alignedPartLowerBound
    if (partRange.upperBound - alignmentDifference) > partRange.lowerBound {
        partRange = partRange.lowerBound ..< (partRange.upperBound - alignmentDifference)
    }
    
    var selectedPartLength: Int64?
    if minPartSize == maxPartSize {
        assert(possiblePartLengths.contains(minPartSize))
        selectedPartLength = minPartSize
    } else {
        for partLength in possiblePartLengths {
            if partLength >= minPartSize && partLength <= maxPartSize && partLength >= partRange.upperBound - alignedPartLowerBound {
                selectedPartLength = partLength
                break
            }
        }
    }
    
    guard let fetchPartLength = selectedPartLength else {
        preconditionFailure()
    }
    
    var fetchRange = alignedPartLowerBound ..< (alignedPartLowerBound + fetchPartLength)
    
    if fetchRange.upperBound > maxPartRange.upperBound {
        fetchRange = (maxPartRange.upperBound - fetchPartLength) ..< maxPartRange.upperBound
    }
    
    assert(fetchRange.lowerBound >= maxPartRange.lowerBound)
    assert(fetchRange.lowerBound % alignment == 0)
    assert(possiblePartLengths.contains(fetchRange.upperBound - fetchRange.lowerBound))
    assert(fetchRange.lowerBound <= partRange.lowerBound && fetchRange.upperBound >= partRange.upperBound)
    assert(fetchRange.lowerBound / boundaryLimit == (fetchRange.upperBound - 1) / boundaryLimit)
    
    return (partRange, fetchRange)
}

