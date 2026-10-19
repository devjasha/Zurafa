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

    static func url(forResource name: String, withExtension ext: String?, subdirectory: String? = nil) -> URL? {
        for bundle in candidateBundles {
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) { return url }
            if let subdirectory {
                if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Resources/\(subdirectory)") { return url }
            } else if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Resources") { return url }
        }
        return nil
    }

    static func image(named name: String, subdirectory: String? = nil) -> NSImage? {
        if subdirectory == nil, let image = Bundle.main.image(forResource: name) { return image }
        return url(forResource: name, withExtension: "png", subdirectory: subdirectory).flatMap { NSImage(contentsOf: $0) }
            ?? url(forResource: name, withExtension: "icns", subdirectory: subdirectory).flatMap { NSImage(contentsOf: $0) }
    }
}
