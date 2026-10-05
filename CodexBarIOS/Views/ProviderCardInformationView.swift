import SwiftUI

struct ProviderCardInformationView: View {
    let sections: [ProviderCardInformationSection]
    let greptileRenewal: GreptileAllowanceRenewal?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let greptileRenewal {
                    Section(greptileRenewal.isApplicable ? "Free allowance renewal" : "Greptile connection") {
                        GreptileRenewalView(renewal: greptileRenewal, showsTitle: false)
                    }
                }
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            LabeledContent {
                                Text(item.detail)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            } label: {
                                Text(item.label)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(item.label), \(item.detail)")
                        }
                    }
                }
            }
            .navigationTitle("More Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
