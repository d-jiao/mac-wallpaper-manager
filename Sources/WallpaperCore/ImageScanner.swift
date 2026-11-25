import Foundation

/// Finds the wallpaper images inside a folder.
public enum ImageScanner {
    /// File extensions that macOS can use as a desktop picture.
    public static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "avif",
    ]

    public static func isSupportedImage(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Returns the paths of all supported images in `folder`, sorted.
    /// Hidden files and the insides of packages are skipped.
    public static func imagePaths(
        in folder: URL,
        includeSubfolders: Bool,
        fileManager: FileManager = .default
    ) -> [String] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !includeSubfolders {
            options.insert(.skipsSubdirectoryDescendants)
        }
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: options
        ) else {
            return []
        }

        var paths: [String] = []
        for case let url as URL in enumerator {
            guard isSupportedImage(url),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            paths.append(url.path)
        }
        return paths.sorted()
    }
}
