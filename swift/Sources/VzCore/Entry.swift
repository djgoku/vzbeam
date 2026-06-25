import Foundation

public func dispatch(_ argv: [String]) {
    let args = Array(argv.dropFirst())   // drop program name
    guard let sub = args.first else { Wire.log("vz: missing subcommand"); exit(2) }
    let rest = Array(args.dropFirst())
    switch sub {
    case "--version": runVersion(); exit(0)
    case "reid": runReid(); exit(0)
    case "image-info": runImageInfo(rest)
    case "restore": runRestore(rest)
    default: Wire.log("vz: unknown subcommand \(sub)"); exit(2)
    }
}
