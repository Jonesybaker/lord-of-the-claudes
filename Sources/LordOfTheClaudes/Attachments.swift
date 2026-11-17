import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image attached to a message: a PNG or JPEG in the attachments folder, named by its content hash.
/// Saved as its path alone.
struct AttachedImage: Hashable, Identifiable, Codable, Sendable {
    let path: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var mediaType: String { url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg" }

    init(path: String) { self.path = path }

    init(from decoder: Decoder) throws {
        path = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(path)
    }
}

/// Where an image to attach comes from: bytes off the pasteboard or a drag, or an image file.
enum ImageSource: Equatable, Sendable {
    case data(Data)
    case file(URL)

    func read() -> Data? {
        switch self {
        case .data(let data): data
        case .file(let url): try? Data(contentsOf: url)
        }
    }
}

/// Turns pasted and dropped images into files Claude Code can take: PNG or JPEG, no more than
/// `longestEdge` across, kept in the attachments folder.
enum ImageFiles {
    static let cap = 5
    /// The API scales anything longer down anyway.
    static let longestEdge = 2000
    /// A bigger PNG goes as JPEG, so its base64 stays under the API's 5 MB an image.
    static let largestFile = 3_700_000

    /// The images already attached, then new ones while there is room. One already there is not added twice.
    static func adding(_ new: [AttachedImage], to existing: [AttachedImage]) -> [AttachedImage] {
        var all = existing
        for image in new where !all.contains(image) && all.count < cap { all.append(image) }
        return all
    }

    /// The bytes to keep and their extension. A PNG or JPEG that already fits is kept as it is; anything else
    /// is scaled down, turned the right way up and written as PNG, or JPEG when that PNG would be too big.
    static func prepare(_ data: Data) -> (data: Data, ext: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return nil }
        let type = (CGImageSourceGetType(source) as String?).flatMap(UTType.init)
        let isPNG = type?.conforms(to: .png) == true
        let isJPEG = type?.conforms(to: .jpeg) == true
        let upright = (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
        if max(width, height) <= longestEdge, upright, data.count <= largestFile {
            if isPNG { return (data, "png") }
            if isJPEG { return (data, "jpg") }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), longestEdge),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if !isJPEG, let png = encode(image, as: .png), png.count <= largestFile { return (png, "png") }
        let opaque = flattened(image) ?? image
        for quality in [0.85, 0.6, 0.4] {
            if let jpeg = encode(opaque, as: .jpeg, quality: quality), jpeg.count <= largestFile { return (jpeg, "jpg") }
        }
        return nil
    }

    /// Keeps an image in `directory` under its content hash. One kept already is touched, so the clean-up counts it as new.
    static func save(_ source: ImageSource, in directory: URL) -> AttachedImage? {
        guard let original = source.read(), let (bytes, ext) = prepare(original) else { return nil }
        let name = SHA256.hash(data: bytes).prefix(16).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent("\(name).\(ext)")
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        if files.fileExists(atPath: file.path) {
            try? files.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        } else if (try? bytes.write(to: file, options: .atomic)) == nil {
            return nil
        }
        return AttachedImage(path: file.path)
    }

    static func isImageFile(_ url: URL) -> Bool {
        url.isFileURL && UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// JPEG has no transparency: what was see-through goes white, not black.
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }
}

/// What a paste or a drop onto a field holds that should be attached rather than typed.
enum PastedImages {
    /// Image data a pasteboard may hold, the most faithful first.
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .init(UTType.jpeg.identifier), .tiff, .init(UTType.heic.identifier),
        .init(UTType.gif.identifier), .init(UTType.webP.identifier),
    ]

    /// The images a paste attaches, or nil for a paste of text, which goes ahead as before. Image files copied in
    /// Finder come first, as Finder also puts each file's icon on the pasteboard. Image data counts only with no
    /// text beside it but a link: a browser's Copy Image adds its address, a word processor adds the words.
    static func sources(from pasteboard: NSPasteboard) -> [ImageSource]? {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            let images = files.filter(ImageFiles.isImageFile)
            return images.isEmpty ? nil : images.map(ImageSource.file)
        }
        if let text = pasteboard.string(forType: .string)?.trimmedNonEmpty, !isLink(text) { return nil }
        guard let type = pasteboard.availableType(from: imageTypes), let data = pasteboard.data(forType: type) else { return nil }
        return [.data(data)]
    }

    /// Whether a paste would attach images, without reading them.
    static func holdsImages(_ pasteboard: NSPasteboard) -> Bool {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { return files.contains(where: ImageFiles.isImageFile) }
        if let text = pasteboard.string(forType: .string)?.trimmedNonEmpty, !isLink(text) { return false }
        return pasteboard.availableType(from: imageTypes) != nil
    }

    /// An image file dropped on a field that is being typed in arrives as its path, one line a file. Text that is
    /// nothing but such paths, each to an image that exists, gives those files; anything else is left as typed.
    static func files(inText text: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [URL]? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        var files: [URL] = []
        for line in lines {
            let url = line.hasPrefix("file://") ? URL(string: line) : line.hasPrefix("/") ? URL(fileURLWithPath: line) : nil
            guard let url, ImageFiles.isImageFile(url), exists(url.path) else { return nil }
            files.append(url)
        }
        return files
    }

    /// One change to a field: what it gained, and the field as it would be without that.
    static func insertion(from old: String, to new: String) -> (inserted: String, without: String)? {
        let old = Array(old), new = Array(new)
        guard new.count > old.count else { return nil }
        var prefix = 0
        while prefix < old.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let inserted = String(new[prefix..<(new.count - suffix)])
        return (inserted, String(new[..<prefix]) + String(new[(new.count - suffix)...]))
    }

    private static func isLink(_ text: String) -> Bool {
        !text.contains(where: \.isWhitespace) && (text.hasPrefix("http://") || text.hasPrefix("https://"))
    }
}

/// A prompt typed into a session's tab. Claude Code takes a pasted line that is only an image's path as that
/// image, so each path goes on a line of its own; one it does not take still reaches Claude as a path to read.
enum TypedPrompt {
    static func text(_ prompt: String, images: [AttachedImage]) -> String {
        ((prompt.isEmpty ? [] : [prompt]) + images.map(\.path)).joined(separator: "\n")
    }

    /// How long to wait before Return. Claude Code reads pasted images before it takes the prompt, and drops a
    /// Return that comes while it reads.
    static func settle(images: Int) -> TimeInterval {
        images == 0 ? 0.3 : 1 + 0.5 * Double(images)
    }
}

/// Removes attachments no saved message refers to once they are a week old. Recent ones stay, as a session
/// sent one may not have read it yet.
enum AttachmentSweep {
    static let maxAge: TimeInterval = 7 * 86400

    @discardableResult
    static func sweep(_ directory: URL, keeping: Set<String>, now: Date = Date()) -> [URL] {
        let files = FileManager.default
        let contents = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles])) ?? []
        let kept = Set(keeping.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var removed: [URL] = []
        for file in contents where !kept.contains(file.standardizedFileURL.path) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            guard now.timeIntervalSince(modified) > maxAge else { continue }
            if (try? files.removeItem(at: file)) != nil { removed.append(file) }
        }
        return removed
    }
}
