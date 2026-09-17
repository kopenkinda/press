import SwiftUI

struct PasswordPrompt: View {
    let name: String
    let hint: String?
    let submit: (String?) -> Void
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Enter password", systemImage: "lock").font(.headline)
            Text(name).lineLimit(2).truncationMode(.middle)
            if let hint { Text(hint).font(.callout).foregroundStyle(.red) }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit(unlock)
            HStack {
                Spacer()
                Button("Cancel") { submit(nil) }.keyboardShortcut(.cancelAction)
                Button("Unlock", action: unlock).keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        }
        .padding(24).frame(width: 340)
        .onAppear { focused = true }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        let value = password
        password = ""
        submit(value)
    }
}
