import AppKit
import Foundation

/// Scans the system for installed applications and returns metadata
/// suitable for displaying in the app picker UI.
final class InstalledAppsScanner {
    /// Represents a discovered application on the system.
    struct DiscoveredApp: Identifiable, Hashable {
        let bundleIdentifier: String
        let displayName: String
        let icon: NSImage
        let path: URL

        var id: String { bundleIdentifier }

        func hash(into hasher: inout Hasher) {
            hasher.combine(bundleIdentifier)
        }

        static func == (lhs: DiscoveredApp, rhs: DiscoveredApp) -> Bool {
            lhs.bundleIdentifier == rhs.bundleIdentifier
        }
    }

    static let shared = InstalledAppsScanner()

    private let customAppURLsKey = "FaceGate.CustomAppURLs"

    private init() {}
    /// Checks if a given URL is within standard app directories or explicitly added custom URLs.
    func isValidAppURL(_ url: URL) -> Bool {
        let path = url.path
        let searchPaths = [
            "/Applications/",
            "/System/Applications/",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"
        ]
        
        for searchPath in searchPaths {
            if path.hasPrefix(searchPath) {
                return true
            }
        }
        
        return getCustomAppURLs().contains { $0.path == path }
    }

    /// Scan for installed applications in standard directories.
    /// - Returns: Array of discovered apps sorted by display name.
    func scanInstalledApps() -> [DiscoveredApp] {
        var apps: [String: DiscoveredApp] = [:]

        let searchPaths = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]

        for searchPath in searchPaths {
            scanDirectory(searchPath, into: &apps, depth: 0, maxDepth: 2)
        }

        var validCustomURLs: [URL] = []
        for url in getCustomAppURLs() {
            let lowerPath = url.path.lowercased()
            if FileManager.default.fileExists(atPath: url.path) && !lowerPath.contains(".trash") && !lowerPath.contains(".trashes") {
                if let app = createDiscoveredApp(from: url) {
                    apps[app.bundleIdentifier] = app
                    validCustomURLs.append(url)
                }
            }
        }
        // Remove any deleted custom apps from UserDefaults
        saveCustomAppURLs(validCustomURLs)

        let excludedBundleIDs: Set<String> = [
            "com.dweep.FaceGate",
            "com.apple.finder",  // Finder can't meaningfully be locked
        ]

        return apps.values
            .filter { !excludedBundleIDs.contains($0.bundleIdentifier) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Convert a DiscoveredApp into a LockedApp for persistence.
    func toLockedApp(_ discovered: DiscoveredApp, isLocked: Bool = true) -> LockedApp {
        // Generate a beautifully sharp 128x128 @2x (256x256 pixels) PNG for persistence.
        let targetSize = NSSize(width: 128, height: 128)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 256,
            pixelsHigh: 256,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = targetSize
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Draw the full icon. AppKit automatically selects the @2x vector/bitmap representation from the NSImage.
        discovered.icon.draw(in: NSRect(origin: .zero, size: targetSize), from: NSRect(origin: .zero, size: discovered.icon.size), operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        
        let iconData = rep.representation(using: .png, properties: [:])

        return LockedApp(
            bundleIdentifier: discovered.bundleIdentifier,
            displayName: discovered.displayName,
            iconData: iconData,
            isLocked: isLocked
        )
    }

    // MARK: - Custom Apps

    /// Adds a custom application URL to be scanned.
    func addCustomAppURL(_ url: URL) {
        var customURLs = getCustomAppURLs()
        if !customURLs.contains(url) {
            customURLs.append(url)
            saveCustomAppURLs(customURLs)
        }
    }

    private func getCustomAppURLs() -> [URL] {
        let strings = UserDefaults.standard.stringArray(forKey: customAppURLsKey) ?? []
        return strings.map { URL(fileURLWithPath: $0) }
    }

    private func saveCustomAppURLs(_ urls: [URL]) {
        let strings = urls.map { $0.path }
        UserDefaults.standard.set(strings, forKey: customAppURLsKey)
    }

    // MARK: - Private

    private func scanDirectory(_ directory: URL, into apps: inout [String: DiscoveredApp], depth: Int, maxDepth: Int) {
        guard depth <= maxDepth else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in contents {
            if url.pathExtension == "app" {
                if let app = createDiscoveredApp(from: url) {
                    // Use bundle ID as key to deduplicate.
                    apps[app.bundleIdentifier] = app
                }
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                // Recurse into subdirectories (e.g., /Applications/Utilities/).
                scanDirectory(url, into: &apps, depth: depth + 1, maxDepth: maxDepth)
            }
        }
    }

    func createDiscoveredApp(from appURL: URL) -> DiscoveredApp? {
        guard let bundle = Bundle(url: appURL),
              let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }

        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent

        let fullIcon = NSWorkspace.shared.icon(forFile: appURL.path)

        return DiscoveredApp(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            icon: fullIcon,
            path: appURL
        )
    }
}
