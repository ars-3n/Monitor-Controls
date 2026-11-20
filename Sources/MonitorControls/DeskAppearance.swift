import SwiftUI

enum DeskType {
    // Use the Mac's body style even for supporting text. Status and help
    // carry operational information and need to be readable at desk distance.
    static let body = Font.body
    static let control = Font.body.weight(.medium)
    static let device = Font.headline
    static let heading = Font.title3.weight(.semibold)
}

extension View {
    @ViewBuilder
    func deskGlassButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
