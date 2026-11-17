import AppKit
import Foundation
import Testing
@testable import LordOfTheClaudes

/// Asks the real `claude -p` about made-up pictures, then carries on the conversation. It spends a little of your
/// plan, so it only runs when asked, sandboxed so nothing lands in the overseer's own folder:
/// LOTC_SANDBOX=1 LOTC_CLAUDE_TESTS=1 ./build.sh test --filter LiveOverseerTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOTC_CLAUDE_TESTS"] == "1" && Sandbox.isOn), .serialized)
struct LiveOverseerTests {
    private static let instructions = "You are being tested. Answer in one short sentence."

    /// A red square with a white number on it, on white or on noise, which compresses worst.
    private func square(_ number: Int, side: Int = 240, noise: Bool = false) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        if noise, let pixels = bitmap.bitmapData {
            arc4random_buf(pixels, bitmap.bytesPerRow * side)
            for i in stride(from: 3, to: bitmap.bytesPerRow * side, by: 4) { pixels[i] = 255 }
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        if !noise {
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: side, height: side).fill()
        }
        NSColor.red.setFill()
        NSRect(x: side / 8, y: side / 8, width: side * 3 / 4, height: side * 3 / 4).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: CGFloat(side) / 2.5),
                                                         .foregroundColor: NSColor.white]
        let text = "\(number)" as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }

    private func answer(_ request: OverseerRequest) async throws -> String {
        var reply = ""
        for try await event in ClaudeCLI().run(request) { if case .answer(let text) = event { reply = text } }
        return reply
    }

    @Test func seesTheImageThenCarriesOnWithoutIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lotc-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try #require(ImageFiles.save(.data(square(7)), in: directory))
        let id = UUID().uuidString.lowercased()

        var first = OverseerRequest(message: "What is in this picture? Name the colour and the number.",
                                    systemPrompt: Self.instructions, sessionId: id, resume: false, settings: OverseerSettings())
        first.images = [image]
        let seen = try await answer(first).lowercased()
        print("First answer: \(seen)")
        #expect(seen.contains("red"))
        #expect(seen.contains("7") || seen.contains("seven"))

        let second = OverseerRequest(message: "What number was on the square I showed you? Just the number.",
                                     systemPrompt: Self.instructions, sessionId: id, resume: true, settings: OverseerSettings())
        let remembered = try await answer(second).lowercased()
        print("Second answer: \(remembered)")
        #expect(remembered.contains("7") || remembered.contains("seven"))
    }

    @Test func fiveImagesAtTheirLargestFitOnStdin() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lotc-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var images: [AttachedImage] = []
        for number in 1...ImageFiles.cap {
            // Noise round the square, so each is about as big as a kept image can be.
            images.append(try #require(ImageFiles.save(.data(square(number, side: 2000, noise: true)), in: directory)))
        }
        let total = images.compactMap { try? Data(contentsOf: $0.url).count }.reduce(0, +)
        print("Five images, \(total / 1000) KB before base64")

        var request = OverseerRequest(message: "How many pictures are there, and what numbers are on the red squares?",
                                      systemPrompt: Self.instructions, sessionId: UUID().uuidString.lowercased(), resume: false,
                                      settings: OverseerSettings(), persist: false)
        request.images = images
        let reply = try await answer(request)
        print("Answer: \(reply)")
        #expect(reply.contains("5") || reply.lowercased().contains("five"))
    }
}
