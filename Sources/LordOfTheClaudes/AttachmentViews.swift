import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Saves pasted and dropped images off the main thread, then adds them to a message's.
@MainActor
enum ImageIntake {
    static func attach(_ sources: [ImageSource], to images: Binding<[AttachedImage]>, in directory: URL = OverseerFiles.attachments) {
        guard !sources.isEmpty else { return }
        let room = ImageFiles.cap - images.wrappedValue.count
        guard room > 0 else { return NSSound.beep() }
        let taking = Array(sources.prefix(room))
        Task {
            let saved = await Task.detached { taking.compactMap { ImageFiles.save($0, in: directory) } }.value
            if saved.count < sources.count { NSSound.beep() }  // over the cap, or not an image after all
            images.wrappedValue = ImageFiles.adding(saved, to: images.wrappedValue)
        }
    }

    /// What was dragged: image files, else image data.
    static func sources(from providers: [NSItemProvider]) async -> [ImageSource] {
        var sources: [ImageSource] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                if let url = await fileURL(from: provider), ImageFiles.isImageFile(url) { sources.append(.file(url)) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier), let data = await imageData(from: provider) {
                sources.append(.data(data))
            }
        }
        return sources
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
        }
    }

    private static func imageData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in done.resume(returning: data) }
        }
    }
}

extension View {
    /// Image files and images dragged here are attached to `images`.
    func takesDroppedImages(into images: Binding<[AttachedImage]>, isTargeted: Binding<Bool>? = nil) -> some View {
        onDrop(of: [.fileURL, .image], isTargeted: isTargeted) { providers in
            Task { @MainActor in ImageIntake.attach(await ImageIntake.sources(from: providers), to: images) }
            return true
        }
    }
}

extension Binding where Value == String {
    /// A field's text, where an image file dropped on the field arrives as its path: that path is taken out again
    /// and the image attached, as Claude Code does in a terminal. Taken out a moment later, as the field shows
    /// only a change it did not make itself.
    @MainActor
    func takingImagePaths(into images: Binding<[AttachedImage]>) -> Binding<String> {
        Binding(get: { wrappedValue }, set: { new in
            let old = wrappedValue
            wrappedValue = new
            guard let change = PastedImages.insertion(from: old, to: new), change.inserted.contains("/"),
                  let files = PastedImages.files(inText: change.inserted)
            else { return }
            DispatchQueue.main.async {
                if wrappedValue == new { wrappedValue = change.without }
                ImageIntake.attach(files.map(ImageSource.file), to: images)
            }
        })
    }
}

/// The images going with a message, small, each with a button to take it off.
struct AttachmentStrip: View {
    @Binding var images: [AttachedImage]
    var editable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ForEach(Array(images.enumerated()), id: \.element) { index, image in
                    Thumbnail(image: image, height: 52, label: "Image \(index + 1) of \(images.count)")
                        .overlay(alignment: .topTrailing) {
                            if editable {
                                Button { images.removeAll { $0 == image } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Color.black.opacity(0.7))
                                        .font(.body)
                                }
                                .buttonStyle(.borderless)
                                .offset(x: 7, y: -7)
                                .help("Remove this image")
                                .accessibilityLabel("Remove image \(index + 1)")
                            }
                        }
                }
            }
            .padding(.top, editable ? 7 : 0)
            if editable && images.count >= ImageFiles.cap {
                Text("Five images at most.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// An attached image, `height` high and as wide as its shape, within reason. One whose file has gone shows
/// as a placeholder. `opens` opens it in Preview on a click.
struct Thumbnail: View {
    let image: AttachedImage
    var height: CGFloat = 52
    var label = "Image"
    var opens = false

    var body: some View {
        let picture = ThumbnailCache.image(for: image)
        let aspect = picture.map { $0.size.width / max($0.size.height, 1) } ?? 1
        let thumbnail = Group {
            if let picture {
                Image(nsImage: picture).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
            }
        }
        .frame(width: (height * min(max(aspect, 0.6), 2)).rounded(), height: height)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityElement()
        .accessibilityLabel(picture == nil ? "\(label), no longer on this Mac" : label)
        if opens && picture != nil {
            Button { NSWorkspace.shared.open(image.url) } label: { thumbnail }
                .buttonStyle(.plain)
                .help("Open in Preview")
        } else {
            thumbnail.help(picture == nil ? "This image is no longer on this Mac" : label)
        }
    }
}

/// Small copies of attached images, made once each.
enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for attachment: AttachedImage) -> NSImage? {
        if let hit = cache.object(forKey: attachment.path as NSString) { return hit }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 320]
        guard let source = CGImageSourceCreateWithURL(attachment.url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        cache.setObject(image, forKey: attachment.path as NSString)
        return image
    }
}

/// Shown over an area while images are dragged across it.
struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
            .overlay(Label("Drop to attach", systemImage: "photo.badge.plus").font(.headline).foregroundStyle(Color.accentColor))
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
