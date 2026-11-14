import AppKit
import CoreText

/// The style of the lock screen's own clock, read from macOS so the clock in
/// the full-screen view matches it and follows any change made in System
/// Settings.
///
/// macOS keeps the choice in loginwindow's settings as a font name
/// (`ClockFontIdentifier`, for example "rail") and a weight
/// (`ClockFontWeight`). The fonts themselves ship in one system file of
/// numeral faces. Only "rail" has been seen in the settings; the other names
/// below are matched on the obvious word and fall back to the standard face.
enum LockClock {
    private static let fontFile = URL(fileURLWithPath: "/System/Library/Fonts/ADTNumeric.ttc")
    private static let weightAxis = 2_003_265_652 // 'wght'

    /// One starting face per family in the system's numeral font file.
    private static let families: [String: CTFontDescriptor] = {
        let all = (CTFontManagerCreateFontDescriptorsFromURL(fontFile as CFURL) as? [CTFontDescriptor]) ?? []
        var found: [String: CTFontDescriptor] = [:]
        for descriptor in all {
            guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String else { continue }
            let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String ?? ""
            if found[family] == nil || name.hasSuffix("-Regular") { found[family] = descriptor }
        }
        return found
    }()

    private static let knownStyles: [(words: [String], family: String)] = [
        (["railrounded", "roundedrail"], ".SF Rail Rounded Numeric"),
        (["rail"], ".SF Rail Numeric"),
        (["stencil"], ".SF Stencil Numeric"),
        (["slabsoft", "softslab"], ".ADT Slab Soft Numeric"),
        (["slab"], ".ADT Slab Numeric"),
        (["newyorksoft", "serifsoft", "softserif"], ".New York Soft Numeric"),
        (["newyork", "serif"], ".New York Numeric"),
        (["rounded"], ".SF Rounded Numeric"),
        (["soft"], ".SF Soft Numeric"),
    ]

    /// What the lock screen is set to right now. Read fresh on every call.
    static var setting: (identifier: String, weight: Double) {
        let domain = "com.apple.loginwindow" as CFString
        CFPreferencesAppSynchronize(domain)
        let identifier = CFPreferencesCopyAppValue("ClockFontIdentifier" as CFString, domain) as? String ?? ""
        let weight = (CFPreferencesCopyAppValue("ClockFontWeight" as CFString, domain) as? NSNumber)?.doubleValue ?? 700
        return (identifier, weight)
    }

    /// The lock screen clock's font at `size`.
    static func font(size: CGFloat) -> CTFont {
        let current = setting
        let key = current.identifier.lowercased().filter { $0.isLetter }
        let family = knownStyles.first { style in style.words.contains { key.contains($0) } }?.family ?? ".SF Numeric"

        guard let base = families[family] ?? families[".SF Numeric"] else {
            return NSFont.systemFont(ofSize: size, weight: .bold) as CTFont
        }

        // Keep the weight inside what this face can do (rail stops at 400).
        var weight = current.weight
        let probe = CTFontCreateWithFontDescriptor(base, size, nil)
        for axis in (CTFontCopyVariationAxes(probe) as? [[String: Any]]) ?? [] {
            guard (axis[kCTFontVariationAxisIdentifierKey as String] as? Int) == weightAxis else { continue }
            let low = (axis[kCTFontVariationAxisMinimumValueKey as String] as? Double) ?? weight
            let high = (axis[kCTFontVariationAxisMaximumValueKey as String] as? Double) ?? weight
            weight = min(max(weight, low), high)
        }
        let styled = CTFontDescriptorCreateCopyWithVariation(base, weightAxis as CFNumber, CGFloat(weight))
        return CTFontCreateWithFontDescriptor(styled, size, nil)
    }
}
