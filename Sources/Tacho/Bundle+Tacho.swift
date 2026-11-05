import Foundation

extension Bundle {
    /// The app's resource bundle, which holds its strings.
    ///
    /// A packaged app carries it as `Contents/Resources/Tacho_Tacho.bundle`. Where SwiftPM's generated `Bundle.module` searches differs
    /// between toolchains, and it stops the process when it finds nothing, so the packaged place is looked in first.
    static let tacho: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Tacho_Tacho.bundle"), let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}
