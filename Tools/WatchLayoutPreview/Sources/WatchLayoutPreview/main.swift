import AppKit
import SwiftUI
import UsageCore
import WatchUI

private struct LayoutMatrix: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ACCESSORY RECTANGULAR · V1")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            ForEach(1 ... 3, id: \.self) { count in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(count) ACCOUNT\(count == 1 ? "" : "S")")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    UsageColumnsView(
                        accounts: Array(UsagePreviewData.accounts.prefix(count)),
                        now: UsagePreviewData.generatedAt,
                        allowsSemanticColors: true
                    )
                    .frame(width: 170, height: 64)
                    .padding(.horizontal, 4)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 13))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .stroke(.white.opacity(0.1), lineWidth: 0.5)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("BUZZ")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                UsageColumnsView(
                    accounts: [UsagePreviewData.buzzAccount],
                    now: UsagePreviewData.generatedAt,
                    allowsSemanticColors: true
                )
                .frame(width: 170, height: 64)
                .padding(.horizontal, 4)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("A/B/C FALLBACK · TINTED / MONOCHROME")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                UsageColumnsView(
                    accounts: UsagePreviewData.unbrandedAccounts,
                    now: UsagePreviewData.generatedAt,
                    allowsSemanticColors: false
                )
                .frame(width: 170, height: 64)
                .padding(.horizontal, 4)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                }
            }
        }
        .padding(18)
        .background(Color(red: 0.035, green: 0.04, blue: 0.055))
        .tint(.cyan)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

private struct PhoneWidgetMatrix: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("IPHONE WIDGETS · V1")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 18) {
                previewSection("HOMESCREEN · KLEIN · 1 ACCOUNT") {
                    homeWidget(style: .small, count: 1)
                        .frame(width: 158, height: 158)
                }
                previewSection("HOMESCREEN · KLEIN · 3 ACCOUNTS") {
                    homeWidget(style: .small, count: 3)
                        .frame(width: 158, height: 158)
                }
            }

            HStack(alignment: .top, spacing: 18) {
                previewSection("HOMESCREEN · KLEIN · BUZZ") {
                    homeWidget(style: .small, accounts: [UsagePreviewData.buzzAccount])
                        .frame(width: 158, height: 158)
                }
                previewSection("HOMESCREEN · KLEIN · A/B/C FALLBACK") {
                    homeWidget(style: .small, accounts: UsagePreviewData.unbrandedAccounts)
                        .frame(width: 158, height: 158)
                }
            }

            ForEach(1 ... 3, id: \.self) { count in
                previewSection("HOMESCREEN · MITTEL · \(count) ACCOUNT\(count == 1 ? "" : "S")") {
                    homeWidget(style: .medium, count: count)
                        .frame(width: 338, height: 158)
                }
            }

            previewSection("SPERRBILDSCHIRM · RECHTECKIG · 3 ACCOUNTS") {
                UsageColumnsView(
                    accounts: UsagePreviewData.accounts,
                    now: UsagePreviewData.generatedAt,
                    allowsSemanticColors: false
                )
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
                .frame(width: 170, height: 64)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
            }
        }
        .padding(22)
        .background(Color(red: 0.035, green: 0.04, blue: 0.055))
        .tint(.cyan)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private func homeWidget(style: UsageHomeWidgetStyle, count: Int) -> some View {
        homeWidget(
            style: style,
            accounts: Array(UsagePreviewData.accounts.prefix(count))
        )
    }

    private func homeWidget(
        style: UsageHomeWidgetStyle,
        accounts: [UsageAccount]
    ) -> some View {
        UsageHomeWidgetView(
            accounts: accounts,
            now: UsagePreviewData.generatedAt,
            style: style,
            allowsSemanticColors: true
        )
        .padding(12)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.1), lineWidth: 0.5)
        }
    }

    private func previewSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

@main
private struct WatchLayoutPreviewRenderer {
    @MainActor
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let output = arguments.first
            ?? "docs/design/v1-layout-preview.png"
        let renderer = ImageRenderer(content: LayoutMatrix())
        renderer.scale = 3
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        let url = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: url, options: .atomic)
        print(url.path)

        if arguments.count >= 3 {
            try writeComparison(
                referencePath: arguments[1],
                previewPath: output,
                outputPath: arguments[2]
            )
            print(URL(fileURLWithPath: arguments[2]).path)
        }

        let phoneOutput = arguments.count >= 4
            ? arguments[3]
            : "docs/design/v1-phone-widget-preview.png"
        try writePhonePreview(outputPath: phoneOutput)
        print(URL(fileURLWithPath: phoneOutput).path)
    }

    @MainActor
    private static func writePhonePreview(outputPath: String) throws {
        let renderer = ImageRenderer(content: PhoneWidgetMatrix())
        renderer.scale = 3
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: outputURL, options: .atomic)
    }

    @MainActor
    private static func writeComparison(
        referencePath: String,
        previewPath: String,
        outputPath: String
    ) throws {
        guard let reference = NSImage(contentsOfFile: referencePath),
              let preview = NSImage(contentsOfFile: previewPath)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let side = max(reference.size.height, preview.size.height)
        let gap: CGFloat = 36
        let referenceWidth = reference.size.width * side / reference.size.height
        let previewWidth = preview.size.width * side / preview.size.height
        let canvas = NSImage(size: NSSize(width: referenceWidth + gap + previewWidth, height: side))
        canvas.lockFocus()
        NSColor(calibratedWhite: 0.025, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvas.size).fill()
        reference.draw(
            in: NSRect(x: 0, y: 0, width: referenceWidth, height: side),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        preview.draw(
            in: NSRect(x: referenceWidth + gap, y: 0, width: previewWidth, height: side),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        canvas.unlockFocus()

        guard let tiff = canvas.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: outputURL, options: .atomic)
    }
}
