import Foundation

@main
struct DownloadPartAlignmentTests {
    static func main() {
        let boundary: Int64 = 1024 * 1024
        let hashBlock: Int64 = 128 * 1024
        var checks = 0
        // Include unaligned seeks, hash boundaries, 1 MiB boundaries and EOF.
        let offsets: [Int64] = [0, 1, 4095, 4096, hashBlock - 1, hashBlock,
                                boundary - 1, boundary, boundary + 1, 3 * boundary - 1]
        for partSize in [hashBlock, 512 * 1024, boundary] {
            for offset in offsets {
                for length in [Int64(1), 17, hashBlock - 1, hashBlock, 512 * 1024, boundary] {
                    let requested = offset ..< (offset + min(length, partSize))
                    let result = alignPartFetchRange(
                        partRange: requested,
                        minPartSize: hashBlock,
                        maxPartSize: min(partSize * 2, boundary),
                        alignment: hashBlock,
                        boundaryLimit: boundary
                    )
                    let fetch = result.fetchRange
                    let count = fetch.upperBound - fetch.lowerBound
                    precondition(!result.partRange.isEmpty && result.partRange.lowerBound == offset)
                    precondition(fetch.contains(offset))
                    precondition(fetch.lowerBound <= result.partRange.lowerBound)
                    precondition(fetch.upperBound >= result.partRange.upperBound)
                    precondition(fetch.lowerBound % hashBlock == 0)
                    precondition(count >= hashBlock && count <= boundary)
                    precondition(boundary % count == 0)
                    precondition(fetch.lowerBound / boundary == (fetch.upperBound - 1) / boundary)
                    // Every returned CDN hash block can be verified separately.
                    precondition(count % hashBlock == 0)
                    checks += 1
                }
            }
        }
        // A complete large-file request must actually use the selected chunk size.
        for partSize in [Int64(512 * 1024), boundary] {
            let result = alignPartFetchRange(partRange: 0 ..< partSize,
                                            minPartSize: hashBlock, maxPartSize: boundary,
                                            alignment: hashBlock, boundaryLimit: boundary)
            precondition(result.fetchRange == 0 ..< partSize)
        }
        print("Download alignment: \(checks) CDN seek, boundary, tail and hash-alignment checks passed.")
    }
}
