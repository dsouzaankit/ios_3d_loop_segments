import SwiftUI

/// Orange “Exporting” strip used on Browse / Queued / Paused while a run is active.
struct ExportActivityBanner: View {
    let itemName: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Exporting")
                    .font(.subheadline.weight(.semibold))
                Text(itemName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("Open")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.16))
    }
}
