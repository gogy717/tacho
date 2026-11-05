import Foundation
import libzstd

/// Why zstd data could not be decompressed.
enum ZstdError: Error, Equatable {
    case outOfMemory
    /// The data is not a valid zstd stream. The message is libzstd's own name for the error and never holds content.
    case corrupt(String)
    /// The data holds no frame, or ends before its last frame does.
    case truncated
}

/// Decompression of zstd data: Codex compresses a rollout to `.jsonl.zst` once its session is old.
enum Zstd {
    /// What the frames in `data` decompress to, one after another.
    ///
    /// The frames are decoded as a stream and their headers' content size is never relied on, because a frame may be written without one.
    static func decompress(_ data: Data) throws -> Data {
        guard let stream = ZSTD_createDStream() else { throw ZstdError.outOfMemory }
        defer { ZSTD_freeDStream(stream) }

        let capacity = ZSTD_DStreamOutSize()
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { chunk.deallocate() }

        var output = Data()
        var atFrameEnd = false
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var input = ZSTD_inBuffer(src: bytes.baseAddress, size: bytes.count, pos: 0)
            // A frame is not given up before all of its content has been handed out, so once the input is used up, so is the output.
            while input.pos < input.size {
                var produced = ZSTD_outBuffer(dst: chunk, size: capacity, pos: 0)
                let hint = ZSTD_decompressStream(stream, &produced, &input)
                guard ZSTD_isError(hint) == 0 else { throw ZstdError.corrupt(String(cString: ZSTD_getErrorName(hint))) }
                output.append(chunk, count: produced.pos)
                // 0 ends a frame; anything else means that this one goes on.
                atFrameEnd = hint == 0
            }
        }
        guard atFrameEnd else { throw ZstdError.truncated }
        return output
    }
}
