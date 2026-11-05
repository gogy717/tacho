import Foundation
import Testing
@testable import TachoKit

struct ZstdTests {
    /// Text of about 600 kB: more than one output chunk of the decoder, and compressible like a rollout is.
    private let text = Data((0..<20_000).map { "{\"ordinal\":\($0),\"type\":\"response_item\"}\n" }.joined().utf8)

    @Test func decompressesAFrameThatStatesItsContentSize() throws {
        let frame = ZstdFixture.compress(text)
        #expect(ZstdFixture.statedContentSize(of: frame) == UInt64(text.count))
        #expect(try Zstd.decompress(frame) == text)
    }

    @Test func decompressesAFrameWithoutContentSize() throws {
        let frame = ZstdFixture.compressWithoutContentSize(text)
        // The fixture must be what it claims to be, or this test proves nothing about streams of unknown length.
        try #require(ZstdFixture.statedContentSize(of: frame) == nil)
        #expect(try Zstd.decompress(frame) == text)
    }

    @Test func decompressesEmptyContent() throws {
        #expect(try Zstd.decompress(ZstdFixture.compress(Data())) == Data())
    }

    @Test func joinsTheContentOfConcatenatedFrames() throws {
        let first = Data("first\n".utf8)
        let second = Data("second\n".utf8)
        let both = ZstdFixture.compress(first) + ZstdFixture.compress(second)
        #expect(try Zstd.decompress(both) == first + second)
    }

    @Test func rejectsADataThatEndsInsideAFrame() {
        let frame = ZstdFixture.compress(text)
        #expect(throws: ZstdError.truncated) { try Zstd.decompress(frame.prefix(frame.count / 2)) }
        // Inside the frame header too.
        #expect(throws: ZstdError.truncated) { try Zstd.decompress(frame.prefix(3)) }
    }

    @Test func rejectsNoData() {
        #expect(throws: ZstdError.truncated) { try Zstd.decompress(Data()) }
    }

    @Test func rejectsDataThatIsNoZstdStream() {
        #expect(throws: ZstdError.self) { try Zstd.decompress(Data("this is a rollout, not a frame\n".utf8)) }
    }
}
