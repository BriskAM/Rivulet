import Foundation
import Testing
@testable import RivuletCore

@Suite struct ParserTests {
    @Test func parsesHTTPDownload() {
        let dict: [String: Any] = [
            "gid": "abc", "status": "active", "totalLength": "1000", "completedLength": "250",
            "downloadSpeed": "50", "uploadSpeed": "0", "connections": "4", "dir": "/tmp",
            "files": [["index": "1", "path": "/tmp/movie.mkv", "length": "1000", "completedLength": "250", "selected": "true",
                       "uris": [["uri": "https://example.com/movie.mkv"]]]],
        ]
        let d = Aria2Parser.parseDownload(dict)
        #expect(d?.name == "movie.mkv")
        #expect(d?.fraction == 0.25)
        #expect(d?.eta == 15)
        #expect(d?.isTorrent == false)
    }

    @Test func parsesTorrentAndSeeding() {
        let dict: [String: Any] = [
            "gid": "t1", "status": "active", "totalLength": "100", "completedLength": "100",
            "uploadLength": "50", "seeder": "true", "infoHash": "deadbeef",
            "bittorrent": ["info": ["name": "My Linux ISO"]],
            "files": [],
        ]
        let d = Aria2Parser.parseDownload(dict)
        #expect(d?.name == "My Linux ISO")
        #expect(d?.isSeeding == true)
        #expect(d?.ratio == 0.5)
        #expect(d?.magnetLink?.hasPrefix("magnet:?xt=urn:btih:deadbeef") == true)
    }

    @Test func decodesPeerID() {
        #expect(Aria2Parser.decodePeerID("-qB4650-abcdefghijkl") == "qBittorrent 4650")
    }

    @Test func formatsValues() {
        #expect(Format.percent(1) == "100%")
        #expect(Format.eta(nil) == "remaining time unknown")
        #expect(Format.eta(3700).contains("1 hr"))
    }
}

@Suite struct PieceMapTests {
    @Test func readsBitfield() {
        #expect(PieceMap.bits("a0", pieces: 5) == [true, false, true, false, false])
        #expect(PieceMap.bits("f", pieces: 6) == [true, true, true, true, false, false])
    }

    @Test func collapsesIntoCells() {
        let cells = PieceMap.cells(bitfield: "f0", pieces: 8, count: 2)
        #expect(cells == [1.0, 0.0])
    }

    @Test func computesAvailability() {
        let a = PieceMap.availability(own: "c", peers: ["3"], pieces: 4)
        #expect(a.reachable == 1.0)
        #expect(a.copies >= 1.0)
        let b = PieceMap.availability(own: "8", peers: [], pieces: 4)
        #expect(b.reachable == 0.25)
    }
}
