import Virtualization
import Foundation

public func runImageInfo(_ args: [String]) {
    let a = Args(args)
    guard let spec = a.positionals.first else {
        Wire.emitError(domain: "vz", code: 2, "image-info needs <latest|PATH>")
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
        let f = Wire.errorFields(e)
        Wire.emitError(domain: f.domain, code: f.code, f.message)
        exit(1)
    }
}
