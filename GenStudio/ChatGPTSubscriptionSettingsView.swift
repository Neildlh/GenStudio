import SwiftUI

/// Published status for the (experimental, unofficial) ChatGPT-subscription image
/// engine, shared between the Settings window and the Image Generator inspector so the
/// node picker only offers the cloud option once a session is actually connected.
@MainActor
final class ChatGPTSubscriptionSessionStore: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published private(set) var accountLabel: String?
    @Published private(set) var isWorking = false
    @Published var lastError: String?

    let authenticator: ChatGPTSubscriptionAuthenticator

    init(authenticator: ChatGPTSubscriptionAuthenticator = ChatGPTSubscriptionAuthenticator()) {
        self.authenticator = authenticator
    }

    func refreshStatus() async {
        let hasSession = (try? await authenticator.hasStoredSession()) ?? false
        let label = hasSession ? (try? await authenticator.storedAccountLabel()) ?? nil : nil
        isSignedIn = hasSession
        accountLabel = label ?? nil
    }

    func signIn() async {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            let label = try await authenticator.signIn()
            isSignedIn = true
            accountLabel = label
        } catch {
            lastError = String(describing: error)
        }
    }

    func signOut() async {
        do {
            try await authenticator.signOut()
        } catch {
            lastError = String(describing: error)
        }
        isSignedIn = false
        accountLabel = nil
    }
}

struct ChatGPTSubscriptionSettingsView: View {
    @ObservedObject var session: ChatGPTSubscriptionSessionStore

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Experimental · Unofficial", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout.weight(.semibold))
                    Text("This connects GenStudio to your ChatGPT subscription using the same sign-in Codex CLI (OpenAI's own coding agent) uses, so image generation is billed to your ChatGPT plan instead of a separate API key. OpenAI has not published or authorized this for third-party apps: it could stop working without warning, and using it carries some risk of your ChatGPT account being rate-limited or flagged. Sign in only if you accept that.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section("ChatGPT Subscription") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.isSignedIn ? "Connected" : "Not connected")
                            .font(.headline)
                        if session.isSignedIn, let label = session.accountLabel {
                            Text(label).font(.callout).foregroundStyle(.secondary)
                        } else if !session.isSignedIn {
                            Text("Sign in opens your browser to log in to ChatGPT.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if session.isWorking {
                        ProgressView().controlSize(.small)
                    } else if session.isSignedIn {
                        Button("Sign Out") { Task { await session.signOut() } }
                    } else {
                        Button("Sign In with ChatGPT") { Task { await session.signIn() } }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                if let error = session.lastError {
                    Label(error, systemImage: "xmark.octagon").font(.callout).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task { await session.refreshStatus() }
    }
}
