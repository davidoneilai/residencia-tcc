import ContactsUI
import SwiftUI

// Cartão de confirmação de mensagem/ligação no estilo da Siri do iOS 27: pergunta acima ("Devo enviar?"),
// foto do contato com selo do canal, troca de canal (WhatsApp ⇄ Mensagens), "Alterar" abre o seletor
// de contatos do iOS (não pede permissão) e o texto é editável antes de enviar.

struct MessageCard: View {
    let proposal: ToolProposal
    let resolve: (Bool, MessageDraft?) -> Void
    @State private var draft: MessageDraft
    @State private var photo: UIImage?
    @State private var picking = false

    init(proposal: ToolProposal, draft: MessageDraft, resolve: @escaping (Bool, MessageDraft?) -> Void) {
        self.proposal = proposal
        self.resolve = resolve
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.channel.sendsText ? "Devo enviar?" : "Devo ligar?")
                .font(.system(.title3, design: .rounded))
                .foregroundStyle(.white)
                .padding(.leading, 18)
                .accessibilityIdentifier("chat.confirm.summary")
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    avatar
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.name ?? draft.phone)
                            .font(.system(.headline, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                        channelMenu
                    }
                    Spacer(minLength: 8)
                    Button("Alterar") { picking = true }
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(Self.blue)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.white.opacity(0.10), in: Capsule())
                        .accessibilityIdentifier("chat.confirm.change")
                }
                if draft.channel.sendsText {
                    TextField("Mensagem", text: $draft.body, axis: .vertical)
                        .lineLimit(1...6)
                        .font(.system(.body, design: .rounded))
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityIdentifier("chat.confirm.body")
                }
                HStack(spacing: 10) {
                    Button { resolve(false, nil) } label: {
                        Text("Cancelar").frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    .accessibilityIdentifier("chat.deny")
                    Button { resolve(true, draft) } label: {
                        Text(draft.channel.sendsText ? "Enviar" : "Ligar").frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(Self.blue, in: Capsule())
                    }
                    .disabled(draft.channel == .sms && draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("chat.confirm")
                }
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
        .task(id: draft.phone) { photo = await ContactsIndex.shared.thumbnail(phone: draft.phone).flatMap(UIImage.init(data:)) }
        .sheet(isPresented: $picking) {
            ContactPicker { name, phone in
                draft.name = name
                draft.phone = phone
            }
            .ignoresSafeArea()
        }
    }

    static let blue = Color(red: 0.24, green: 0.55, blue: 0.96)

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFill()
                } else {
                    Text(Self.initials(draft.name ?? "#"))
                        .font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.35)], startPoint: .top, endPoint: .bottom))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(Circle())
            Image(systemName: Self.badge(draft.channel))
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Self.tint(draft.channel), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .offset(x: 3, y: 3)
        }
    }

    @ViewBuilder private var channelMenu: some View {
        let options = draft.channel.siblings
        Menu {
            ForEach(options, id: \.self) { channel in
                Button(channel.title) { draft.channel = channel }
            }
        } label: {
            HStack(spacing: 4) {
                Text(draft.channel.title)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.system(.subheadline, design: .rounded)).foregroundStyle(.secondary)
        }
        .disabled(options.count < 2)
    }

    static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "#" : String(letters).uppercased()
    }

    static func badge(_ channel: MessageDraft.Channel) -> String {
        switch channel {
        case .whatsapp: "phone.bubble.fill"
        case .sms: "message.fill"
        case .call: "phone.fill"
        case .facetime: "video.fill"
        }
    }

    static func tint(_ channel: MessageDraft.Channel) -> Color {
        switch channel {
        case .whatsapp: Color(red: 0.15, green: 0.83, blue: 0.40)
        case .sms, .call, .facetime: Color(red: 0.20, green: 0.78, blue: 0.35)
        }
    }
}

/// Seletor de contatos do sistema: roda fora do processo, então não precisa de permissão da agenda.
/// Só deixa escolher um telefone.
private struct ContactPicker: UIViewControllerRepresentable {
    let pick: (String, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(pick: pick) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        picker.predicateForSelectionOfProperty = NSPredicate(format: "key == 'phoneNumbers'")
        return picker
    }

    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let pick: (String, String) -> Void
        init(pick: @escaping (String, String) -> Void) { self.pick = pick }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect property: CNContactProperty) {
            guard let number = (property.value as? CNPhoneNumber)?.stringValue,
                  let phone = ContactMatch.dialable(number) else { return }
            let contact = property.contact
            let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            pick(name.isEmpty ? (contact.organizationName.isEmpty ? phone : contact.organizationName) : name, phone)
        }
    }
}
