import AppKit
import Foundation

private final class ZurafaResourceMarker {}

enum ZurafaResources {
    private static let bundleName = "Zurafa_Zurafa"

    private static var candidateBundles: [Bundle] {
        var bundles = [Bundle.main, Bundle(for: ZurafaResourceMarker.self)] + Bundle.allBundles
        var seenBundlePaths = Set<String>()
        bundles = bundles.filter { seenBundlePaths.insert($0.bundlePath).inserted }

        let baseURLs = bundles.flatMap { bundle in
            [bundle.resourceURL, bundle.bundleURL, bundle.privateFrameworksURL].compactMap { $0 }
        }

        var seenPaths = Set<String>()
        for baseURL in baseURLs {
            for url in [
                baseURL.appendingPathComponent("\(bundleName).bundle"),
                baseURL.appendingPathComponent("Resources/\(bundleName).bundle"),
                baseURL.appendingPathComponent("\(bundleName).resources"),
            ] where seenPaths.insert(url.path).inserted {
                if let bundle = Bundle(url: url) { bundles.append(bundle) }
            }
        }
        return bundles
    }

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        for bundle in candidateBundles {
            if let url = bundle.url(forResource: name, withExtension: ext) { return url }
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Resources") { return url }
        }
        return nil
    }

    static func image(named name: String) -> NSImage? {
        Bundle.main.image(forResource: name)
            ?? url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
            ?? url(forResource: name, withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
    }
}
