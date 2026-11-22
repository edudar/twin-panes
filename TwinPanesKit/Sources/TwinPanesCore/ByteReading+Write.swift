import Foundation

extension ByteReading {
    /// Streams `range` to a new file at `destination` in chunks of `chunkSize` through
    /// the uncached path. Throws `ByteSourceError.truncated` if the source ends before
    /// `range` does (the file got shorter); the partial file is left for the caller.
    public func write(
        _ range: Range<UInt64>, to destination: URL, chunkSize: Int = 1 << 20
    ) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var offset = range.lowerBound
        while offset < range.upperBound {
            let end = min(range.upperBound, offset + UInt64(max(1, chunkSize)))
            let chunk = try readSequential(offset..<end)
            try handle.write(contentsOf: chunk)
            offset += UInt64(chunk.count)
            if offset < end {
                throw ByteSourceError.truncated(expected: range.upperBound, available: offset)
            }
        }
    }
}
