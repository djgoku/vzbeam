import Virtualization
import Foundation

public func runImageInfo(_ args: [String]) {
    let a = Args(args)
    guard let spec = a.positionals.first else {
        Wire.emit(["type": "error", "domain": "vz", "code": 2, "message": "image-info needs <latest|PATH>"])
        exit(2)
    }
    if spec == "latest" {
        VZMacOSRestoreImage.fetchLatestSupported { result in finishImageInfo(result, source: "latest") }
    } else {
        VZMacOSRestoreImage.load(from: URL(fileURLWithPath: spec)) { result in
            finishImageInfo(result, source: "local")
        }
    }
    RunLoop.main.run()   // handler calls exit(); never returns normally
}

private func finishImageInfo(_ result: Result<VZMacOSRestoreImage, Error>, source: String) {
    // Codex NICE #8: log which queue the handler fired on (validation probe).
    Wire.log("image-info handler on \(Thread.isMainThread ? "main" : "background") thread")
    switch result {
    case .success(let image):
        let v = image.operatingSystemVersion
        Wire.emit([
            "type": "image",
            "version": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            "build": image.buildVersion,
            "url": image.url.absoluteString,
            "source": source,
        ])
        exit(0)
    case .failure(let e):
        Wire.emit(["type": "error", "domain": "VZErrorDomain", "code": (e as NSError).code,
                   "message": e.localizedDescription])
        exit(1)
    }
}
