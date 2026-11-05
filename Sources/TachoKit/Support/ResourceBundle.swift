import Foundation

enum TachoKitResources {
    /// The package's resource bundle (`prices.json`, the localized strings).
    ///
    /// A packaged app carries it as `Contents/Resources/Tacho_TachoKit.bundle`, so that is where it is looked for first:
    /// where SwiftPM's generated `Bundle.module` searches differs between toolchains, and it stops the process when it finds nothing.
    /// Everywhere else (tests, `swift run`) the bundle sits where `Bundle.module` expects it.
    static var bundle: Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Tacho_TachoKit.bundle"), let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }
}
