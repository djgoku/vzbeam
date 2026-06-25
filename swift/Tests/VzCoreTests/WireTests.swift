import Testing
import Foundation
@testable import VzCore

@Test func testEmitIsOneCompactJSONLine() throws {
    // Capture stdout via a pipe.
    let pipe = Pipe(); let saved = dup(STDOUT_FILENO)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    Wire.emit(["type": "version", "protocol": 1])
    fflush(stdout); dup2(saved, STDOUT_FILENO); pipe.fileHandleForWriting.closeFile()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
    #expect(out.filter { $0 == "\n" }.count == 1)              // exactly one line
    let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as! [String: Any]
    #expect(obj["type"] as? String == "version")
    #expect(obj["protocol"] as? Int == 1)
}
