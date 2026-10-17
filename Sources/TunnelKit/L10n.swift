import Foundation

/// Localized text from TunnelKit's own strings, in the app's current language.
enum L10n {
    /// Forces one localization (tests run under whatever language the Mac uses).
    nonisolated(unsafe) static var override: String?

    static var bundle: Bundle {
        // SwiftPM writes zh-Hans.lproj as zh-hans.lproj.
        if let override,
           let path = Bundle.module.path(forResource: override, ofType: "lproj")
               ?? Bundle.module.path(forResource: override.lowercased(), ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .module
    }

    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle)
    }
}
