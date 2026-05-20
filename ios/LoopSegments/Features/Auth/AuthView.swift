import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var session: AppSession

    @State private var region: PCloudRegion = AuthView.initialRegion
    @State private var email = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
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
                    Text("Use your normal pCloud email and password. Sign-in verifies WebDAV and pCloud search. If the wrong region was selected, the app tries the other datacenter automatically.")
                    Text("Two-factor authentication: use a pCloud app password here (not your 2FA login code). Browse/export can work without search, but search needs the API token from sign-in.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Build \(AuthView.buildLabel) · pCloud WebDAV · AVFoundation segment export")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .disabled(isBusy)
            .navigationTitle("Loop Segments")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign in") { Task { await signIn() } }
                        .disabled(isBusy || email.isEmpty || password.isEmpty)
                }
            }

            if isBusy {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                ProgressView("Signing in to pCloud…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            }
        }
    }

    private static var initialRegion: PCloudRegion {
        if let raw = UserDefaults.standard.string(forKey: "pcloud_region_last_sign_in"),
           let region = PCloudRegion(rawValue: raw) {
            return region
        }
        return .us
    }

    private static var buildLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
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
