import SwiftUI

/// A group's name, with its colour as a dot when one has been chosen.
struct GroupHeader: View {
    let name: String
    let hex: String?

    var body: some View {
        HStack(spacing: 5) {
            if let hex {
                Circle().fill(Color(hex: hex)).frame(width: 7, height: 7).accessibilityHidden(true)
            }
            Text(name)
        }
    }
}
