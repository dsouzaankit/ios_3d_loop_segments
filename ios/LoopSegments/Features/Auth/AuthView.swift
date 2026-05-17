import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var session: AppSession

    @State private var region: PCloudRegion = .us
    @State private var email = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("pCloud region") {
                    Picker("Region", selection: $region) {
                        ForEach(PCloudRegion.allCases) { r in
                            Text(r.displayName).tag(r)
                        }
                    }
                }
                Section("WebDAV credentials") {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .autocapitalization(.none)
                        .keyboardType(.emailAddress)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
                Section {
                    Text("Use the same US/Europe region as your pCloud account. With 2FA, create an app password at my.pcloud.com (Settings → Security) — not your normal login password.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Build 1.2.5 · pCloud WebDAV · AVFoundation segment export")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Loop Segments")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign in") { Task { await signIn() } }
                        .disabled(isBusy || email.isEmpty || password.isEmpty)
                }
            }
        }
    }

    private func signIn() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await session.signIn(region: region, email: email, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
