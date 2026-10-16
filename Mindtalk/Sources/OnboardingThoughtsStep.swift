import SwiftUI

// MARK: - Step 5: A thought, for real

struct ThoughtsStep: View {
    @ObservedObject var dictation: Dictation

    var body: some View {
        StepHeader(title: "Tankar", subtitle: "")
    }
}
