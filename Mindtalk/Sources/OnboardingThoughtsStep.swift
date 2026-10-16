import SwiftUI

// MARK: - Step 5: A thought, for real

struct ThoughtsStep: View {
    @ObservedObject var dictation: Dictation
    @Binding var done: Bool

    var body: some View {
        StepHeader(title: "Tankar", subtitle: "")
    }
}
