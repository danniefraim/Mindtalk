import SwiftUI

// MARK: - Step 7: The word list

struct VocabularyStep: View {
    @ObservedObject var dictation: Dictation
    @Binding var done: Bool
    var body: some View {
        StepHeader(title: "Ordlista", subtitle: "")
    }
}
