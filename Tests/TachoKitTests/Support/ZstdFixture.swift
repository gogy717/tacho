import Foundation
import libzstd

/// Zstandard frames for tests. `TachoKit` only decompresses, so the compressing side lives here.
enum ZstdFixture {
    /// One frame holding `data` whose header states the content size: what the `zstd` command writes for a file.
    static func compress(_ data: Data) -> Data {
        var frame = Data(count: ZSTD_compressBound(data.count))
        let written = frame.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                ZSTD_compress(out.baseAddress, out.count, input.baseAddress, input.count, 3)
            }
        }
        guard ZSTD_isError(written) == 0 else { fatalError("ZstdFixture.compress: \(String(cString: ZSTD_getErrorName(written)))") }
        frame.removeSubrange(written...)
        return frame
    }

    /// One frame that does not state its content size: the encoder gets the data in two pieces, so it cannot know the total up front.
    static func compressWithoutContentSize(_ data: Data) -> Data {
        precondition(data.count >= 2, "ZstdFixture.compressWithoutContentSize: needs two pieces")
        guard let context = ZSTD_createCCtx() else { fatalError("ZstdFixture: out of memory") }
        defer { ZSTD_freeCCtx(context) }

        var frame = Data()
        var scratch = [UInt8](repeating: 0, count: ZSTD_CStreamOutSize())
        let half = data.count / 2
        let pieces = [(data.subdata(in: 0..<half), ZSTD_e_continue), (data.subdata(in: half..<data.count), ZSTD_e_end)]
        for (piece, directive) in pieces {
            piece.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                var source = ZSTD_inBuffer(src: input.baseAddress, size: input.count, pos: 0)
                var finished = false
                while !finished {
                    scratch.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                        var sink = ZSTD_outBuffer(dst: out.baseAddress, size: out.count, pos: 0)
                        let remaining = ZSTD_compressStream2(context, &sink, &source, directive)
                        guard ZSTD_isError(remaining) == 0 else { fatalError("ZstdFixture: \(String(cString: ZSTD_getErrorName(remaining)))") }
                        frame.append(contentsOf: out[0..<sink.pos])
                        // `continue` is done when the piece is taken in; `end` when the encoder has nothing left to flush.
                        finished = directive == ZSTD_e_end ? remaining == 0 : source.pos == source.size
                    }
                }
            }
        }
        return frame
    }

    /// The content size a frame's header states; nil when it states none.
    static func statedContentSize(of frame: Data) -> UInt64? {
        let size = frame.withUnsafeBytes { ZSTD_getFrameContentSize($0.baseAddress, $0.count) }
        // ZSTD_CONTENTSIZE_UNKNOWN and ZSTD_CONTENTSIZE_ERROR are the two largest values.
        return size >= UInt64.max - 1 ? nil : size
    }
}
