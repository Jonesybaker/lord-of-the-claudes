import AppKit
import Carbon.HIToolbox
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import LordOfTheClaudes

/// A made-up picture: a red square with a number on it, or noise, which compresses badly.
private func picture(width: Int, height: Int, noise: Bool = false, as type: UTType = .png) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if noise, let pixels = context.data {
        arc4random_buf(pixels, context.bytesPerRow * height)
        let bytes = pixels.assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 3, to: context.bytesPerRow * height, by: 4) { bytes[i] = 255 }
    } else {
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.85, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: width / 8, y: height / 8, width: width * 3 / 4, height: height * 3 / 4))
    }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func size(of data: Data) -> (width: Int, height: Int, type: String)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
          let type = CGImageSourceGetType(source) as String?
    else { return nil }
    return (width, height, type)
}

private func scratchDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lotc-attachments-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A pasteboard of its own, so the tests never touch the clipboard.
private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
    let pasteboard = NSPasteboard(name: .init("lotc-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    try body(pasteboard)
}

struct PastedImageTests {
    @Test func aScreenshotOnTheClipboardIsAnImage() {
        let png = picture(width: 40, height: 30)
        withPasteboard { pasteboard in
            pasteboard.setData(png, forType: .png)
            #expect(PastedImages.sources(from: pasteboard) == [.data(png)])
            #expect(PastedImages.holdsImages(pasteboard))
        }
    }

    @Test func aCopiedImageAsTIFFIsAnImageAndKeptAsPNG() throws {
        let tiff = picture(width: 40, height: 30, as: .tiff)
        try withPasteboard { pasteboard in
            pasteboard.setData(tiff, forType: .tiff)
            let sources = try #require(PastedImages.sources(from: pasteboard))
            #expect(sources == [.data(tiff)])
            let kept = try #require(ImageFiles.prepare(tiff))
            #expect(kept.ext == "png" && size(of: kept.data)?.width == 40)
        }
    }

    @Test func aFileCopiedInFinderIsItsImageNotItsIcon() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("away kit.png")
        try picture(width: 40, height: 30).write(to: file)
        withPasteboard { pasteboard in
            // As Finder puts it: the file, its name as text and its icon as an image.
            let item = NSPasteboardItem()
            item.setString(file.absoluteString, forType: .fileURL)
            item.setString("away kit.png", forType: .string)
            item.setData(picture(width: 16, height: 16, as: .tiff), forType: .tiff)
            pasteboard.writeObjects([item])
            #expect(PastedImages.sources(from: pasteboard) == [.file(file)])
            #expect(PastedImages.holdsImages(pasteboard))
        }
    }

    @Test func textIsPastedAsText() {
        withPasteboard { pasteboard in
            pasteboard.setString("rebase on main", forType: .string)
            #expect(PastedImages.sources(from: pasteboard) == nil)
            #expect(!PastedImages.holdsImages(pasteboard))
        }
        // A word processor puts a picture of the words beside them: still a text paste.
        withPasteboard { pasteboard in
            pasteboard.declareTypes([.string, .png], owner: nil)
            pasteboard.setString("Matchday squad list", forType: .string)
            pasteboard.setData(picture(width: 40, height: 30), forType: .png)
            #expect(PastedImages.sources(from: pasteboard) == nil)
            #expect(!PastedImages.holdsImages(pasteboard))
        }
    }

    @Test func aBrowsersCopyImageWithItsAddressIsAnImage() {
        let png = picture(width: 40, height: 30)
        withPasteboard { pasteboard in
            pasteboard.declareTypes([.string, .png], owner: nil)
            pasteboard.setString("https://example.com/kit/home-shirt.png", forType: .string)
            pasteboard.setData(png, forType: .png)
            #expect(PastedImages.sources(from: pasteboard) == [.data(png)])
        }
    }

    @Test func aCopiedFileThatIsNotAnImageIsLeftToTheField() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixtures.txt")
        try Data("Saturday 15:00".utf8).write(to: file)
        withPasteboard { pasteboard in
            pasteboard.writeObjects([file as NSURL])
            #expect(PastedImages.sources(from: pasteboard) == nil)
            #expect(!PastedImages.holdsImages(pasteboard))
        }
    }

    @Test func aDroppedFilesPathInAFieldIsTheImage() {
        let there: Set<String> = ["/p/shot.png", "/p/old trafford.jpg"]
        let exists = { (path: String) in there.contains(path) }
        #expect(PastedImages.files(inText: "/p/shot.png", exists: exists) == [URL(fileURLWithPath: "/p/shot.png")])
        #expect(PastedImages.files(inText: "/p/shot.png\n/p/old trafford.jpg\n", exists: exists)?.count == 2)
        #expect(PastedImages.files(inText: "file:///p/shot.png", exists: exists) == [URL(fileURLWithPath: "/p/shot.png")])
        #expect(PastedImages.files(inText: "look at /p/shot.png", exists: exists) == nil)
        #expect(PastedImages.files(inText: "/p/notes.txt", exists: { _ in true }) == nil)
        #expect(PastedImages.files(inText: "/p/missing.png", exists: exists) == nil)
        #expect(PastedImages.files(inText: "png", exists: { _ in true }) == nil)
    }

    @Test func findsWhatAFieldGainedInOneChange() {
        #expect(PastedImages.insertion(from: "hello ", to: "hello /p/shot.png")! == ("/p/shot.png", "hello "))
        #expect(PastedImages.insertion(from: "ab", to: "a/p/x.png\nb")! == ("/p/x.png\n", "ab"))
        #expect(PastedImages.insertion(from: "hello world", to: "hello /p/x.png")! == ("/p/x.png", "hello "))  // over a selection
        #expect(PastedImages.insertion(from: "abc", to: "ab") == nil)
        #expect(PastedImages.insertion(from: "abc", to: "abc") == nil)
    }
}

struct ImageFileTests {
    @Test func atMostFiveAndNoneTwice() {
        let images = (1...7).map { AttachedImage(path: "/a/\($0).png") }
        #expect(ImageFiles.adding(images, to: []) == Array(images.prefix(5)))
        #expect(ImageFiles.adding([images[0], images[1]], to: [images[0]]) == [images[0], images[1]])
        #expect(ImageFiles.adding([images[6]], to: Array(images.prefix(5))) == Array(images.prefix(5)))
    }

    @Test func aBigImageIsScaledToTwoThousandOnItsLongEdge() throws {
        let wide = try #require(ImageFiles.prepare(picture(width: 3000, height: 1200)))
        #expect(wide.ext == "png")
        let scaled = try #require(size(of: wide.data))
        #expect(scaled.width == 2000 && scaled.height == 800)

        let tall = try #require(ImageFiles.prepare(picture(width: 1000, height: 2600, as: .jpeg)))
        #expect(tall.ext == "jpg")
        #expect(size(of: tall.data).map { max($0.width, $0.height) } == 2000)
    }

    @Test func aPNGOrJPEGThatFitsIsKeptAsItIs() throws {
        let png = picture(width: 1200, height: 800)
        #expect(try #require(ImageFiles.prepare(png)) == (png, "png"))
        let jpeg = picture(width: 800, height: 600, as: .jpeg)
        #expect(try #require(ImageFiles.prepare(jpeg)) == (jpeg, "jpg"))
        let gif = try #require(ImageFiles.prepare(picture(width: 50, height: 40, as: .gif)))
        #expect(gif.ext == "png" && size(of: gif.data)?.width == 50)
    }

    @Test func aPNGTooBigToSendGoesAsJPEG() throws {
        let kept = try #require(ImageFiles.prepare(picture(width: 1900, height: 1900, noise: true)))
        #expect(kept.ext == "jpg")
        #expect(kept.data.count <= ImageFiles.largestFile)
    }

    @Test func notAnImageIsNothing() {
        #expect(ImageFiles.prepare(Data("United 2 City 1".utf8)) == nil)
        #expect(ImageFiles.save(.data(Data("x".utf8)), in: FileManager.default.temporaryDirectory) == nil)
    }

    @Test func keptUnderItsContentHashOnce() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = picture(width: 40, height: 30)
        let first = try #require(ImageFiles.save(.data(png), in: directory))
        #expect(first.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(first.url.lastPathComponent.wholeMatch(of: #/[0-9a-f]{32}\.png/#) != nil)
        #expect(try Data(contentsOf: first.url) == png)
        #expect(first.mediaType == "image/png")

        let weekOld = Date().addingTimeInterval(-8 * 86400)
        try FileManager.default.setAttributes([.modificationDate: weekOld], ofItemAtPath: first.path)
        let again = try #require(ImageFiles.save(.data(png), in: directory))
        #expect(again == first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
        let touched = try #require(try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date)
        #expect(touched > weekOld.addingTimeInterval(86400))  // pasted again, so new again for the clean-up
    }
}

struct AttachmentSweepTests {
    @Test func removesOnlyWeekOldImagesNothingRefersTo() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        func file(_ name: String, daysOld: Double) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysOld * 86400)], ofItemAtPath: url.path)
            return url
        }
        let inAMessage = try file("a.png", daysOld: 30)
        let loose = try file("b.png", daysOld: 8)
        let recent = try file("c.png", daysOld: 6)  // a session may not have read it yet

        let removed = AttachmentSweep.sweep(directory, keeping: [inAMessage.path], now: now)
        #expect(removed.map(\.lastPathComponent) == ["b.png"])
        #expect(FileManager.default.fileExists(atPath: inAMessage.path))
        #expect(!FileManager.default.fileExists(atPath: loose.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(AttachmentSweep.sweep(directory.appendingPathComponent("never-made"), keeping: []).isEmpty)
    }
}

struct RoutedImageTests {
    private let images = [AttachedImage(path: "/Users/fan/Library/Application Support/LordOfTheClaudes/attachments/ab12.png"),
                          AttachedImage(path: "/Users/fan/Library/Application Support/LordOfTheClaudes/attachments/cd34.jpg")]

    @Test func thePromptEndsWithEachPathOnALineOfItsOwn() {
        #expect(TypedPrompt.text("the VAT is a penny out here", images: images) == """
            the VAT is a penny out here
            /Users/fan/Library/Application Support/LordOfTheClaudes/attachments/ab12.png
            /Users/fan/Library/Application Support/LordOfTheClaudes/attachments/cd34.jpg
            """)
        #expect(TypedPrompt.text("rebase on main", images: []) == "rebase on main")
        #expect(TypedPrompt.text("", images: [images[0]]) == images[0].path)
    }

    @Test func waitsLongerBeforeReturnWhenImagesGoWithIt() {
        #expect(TypedPrompt.settle(images: 0) == 0.3)
        #expect(TypedPrompt.settle(images: 1) >= 1)
        #expect(TypedPrompt.settle(images: 5) > TypedPrompt.settle(images: 1))
    }

    @Test func aNewSessionMayReadTheImagesFolder() {
        #expect(Ghostty.claudeCommand(prompt: "fix this\n/a b/x.png", alsoReading: "/a b")
                == "claude --add-dir '/a b' -- 'fix this /a b/x.png'")
        #expect(Ghostty.claudeCommand(prompt: "-v is a flag") == "claude -- '-v is a flag'")
    }

    @Test func theRunnerSendsWordsThenImagesAsOneStreamJSONMessage() throws {
        let png = picture(width: 20, height: 20)
        let jpeg = picture(width: 20, height: 20, as: .jpeg)
        let line = StreamInput.userMessage("<briefing>...</briefing>\n\nwhat is this?",
                                           images: [("image/png", png), ("image/jpeg", jpeg)])
        #expect(line.last == 0x0A)
        #expect(!line.dropLast().contains(0x0A))  // one line
        let json = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(json["type"] as? String == "user")
        #expect(json["parent_tool_use_id"] is NSNull)
        let message = try #require(json["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["text", "image", "image"])
        #expect(content[0]["text"] as? String == "<briefing>...</briefing>\n\nwhat is this?")
        let source = try #require(content[1]["source"] as? [String: String])
        #expect(source["type"] == "base64" && source["media_type"] == "image/png")
        #expect(Data(base64Encoded: try #require(source["data"])) == png)
        #expect((content[2]["source"] as? [String: String])?["media_type"] == "image/jpeg")

        let args = ClaudeCLI.arguments(for: OverseerRequest(message: "m", systemPrompt: "s", sessionId: "id", resume: true,
                                                            settings: OverseerSettings()))
        #expect(args.firstIndex(of: "--input-format").map { args[$0 + 1] } == "stream-json")
        #expect(args.firstIndex(of: "--output-format").map { args[$0 + 1] } == "stream-json")
    }

    @Test func aPastedImageGoesToTheFieldWithTheKeyboard() {
        func route(_ focus: MainField?, images: Bool) -> MainKey {
            MainKeys.route(keyCode: kVK_ANSI_V, modifiers: .command, characters: "v",
                           in: .init(focus: focus, composerEmpty: false, imagesToPaste: images))
        }
        for focus: MainField in [.composer, .proposal, .reply(sessionId: "a")] {
            #expect(route(focus, images: true) == .pasteImages)
            #expect(route(focus, images: false) == .passThrough)  // text pastes as ever
        }
        #expect(route(.filter, images: true) == .passThrough)
        #expect(route(.rename(groupId: "g"), images: true) == .passThrough)
    }
}

@MainActor
struct ImageIntakeTests {
    /// Holds a field's state, as the chat or the window model would.
    private final class Field {
        var text = ""
        var images: [AttachedImage] = []
        var textBinding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
        var imagesBinding: Binding<[AttachedImage]> { Binding(get: { self.images }, set: { self.images = $0 }) }
    }

    private func waitFor(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func pastedImagesAreSavedThenAttachedUpToTheCap() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let field = Field()
        field.images = (1...3).map { AttachedImage(path: "/a/\($0).png") }
        let sources = (1...3).map { ImageSource.data(picture(width: 10 * $0, height: 10)) }
        ImageIntake.attach(sources, to: field.imagesBinding, in: directory)
        await waitFor { field.images.count == ImageFiles.cap }
        #expect(field.images.count == ImageFiles.cap)
        #expect(field.images.dropFirst(3).allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test func aDroppedFilesPathInTheFieldBecomesTheImage() async throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("home shirt.png")
        try picture(width: 30, height: 20).write(to: file)
        let field = Field()
        field.text = "fix this "
        let text = field.textBinding.takingImagePaths(into: field.imagesBinding)

        text.wrappedValue = "fix this x"  // typing stays typing
        #expect(field.text == "fix this x")
        text.wrappedValue = "fix this x" + file.path  // what a drop on the field inserts
        await waitFor { !field.images.isEmpty }
        #expect(field.text == "fix this x")
        #expect(field.images.count == 1)
        text.wrappedValue = "fix this x/no/such/image.png"
        try await Task.sleep(for: .milliseconds(50))
        #expect(field.text == "fix this x/no/such/image.png")
        #expect(field.images.count == 1)
    }
}
