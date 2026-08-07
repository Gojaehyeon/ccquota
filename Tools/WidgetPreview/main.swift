import CCQuotaCore
import SwiftUI
import AppKit

// Renders the real widget views to PNG at the actual widget point sizes, in both
// appearances, so the layout can be reviewed without installing anything.

@MainActor
func render<V: View>(_ view: V, size: CGSize, dark: Bool, to path: String) {
    let backing = dark
        ? Color(nsColor: NSColor(calibratedWhite: 0.12, alpha: 1))
        : Color(nsColor: NSColor(calibratedWhite: 0.96, alpha: 1))
    let wrapped = view
        .padding(14)
        .frame(width: size.width, height: size.height)
        .background(backing)
        .environment(\.colorScheme, dark ? .dark : .light)

    let renderer = ImageRenderer(content: wrapped)
    renderer.scale = 3
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("렌더 실패: \(path)"); return
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("생성: \(path)")
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// Use live data when it exists so the review reflects real values, not mock ones.
let live = SharedState.read()
var accounts = live?.accounts ?? []
if accounts.isEmpty {
    var a = AccountSnapshot(label: "limboart", isActive: true)
    a.fiveHourPercent = 2; a.weeklyPercent = 0
    var b = AccountSnapshot(label: "tntlabgo", isActive: false)
    b.fiveHourPercent = 9; b.weeklyPercent = 14
    var c = AccountSnapshot(label: "teamtntlabs", isActive: false)
    c.fiveHourPercent = 4; c.weeklyPercent = 73
    accounts = [a, b, c]
}

// A synthetic worst case, so the urgent grade and a full bar get reviewed too.
var hot = AccountSnapshot(label: "verylongaccountname", isActive: false)
hot.fiveHourPercent = 97; hot.weeklyPercent = 100
var stale = AccountSnapshot(label: "stalefeed", isActive: false)
stale.fiveHourPercent = 58; stale.weeklyPercent = 61; stale.isStale = true
stale.error = "인증 만료"

MainActor.assumeIsolated {
    for dark in [false, true] {
        let tag = dark ? "dark" : "light"
        render(SmallView(accounts: accounts), size: CGSize(width: 155, height: 155),
               dark: dark, to: "\(out)/small-\(tag).png")
        render(MediumView(accounts: accounts, updatedAt: Date()),
               size: CGSize(width: 329, height: 155), dark: dark, to: "\(out)/medium-\(tag).png")
        render(MediumView(accounts: accounts + [hot, stale], updatedAt: Date()),
               size: CGSize(width: 329, height: 155), dark: dark, to: "\(out)/medium-edge-\(tag).png")
        render(SmallView(accounts: [hot]), size: CGSize(width: 155, height: 155),
               dark: dark, to: "\(out)/small-edge-\(tag).png")
    }
}
