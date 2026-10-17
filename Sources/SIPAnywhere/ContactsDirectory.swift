import Contacts
import Foundation

/// Names from the Mac's Contacts for phone numbers. The address book is read once
/// (after the user allows access) into an index keyed by the last 9 digits, so that
/// "+44 20 7946 0018", "00442079460018" and "02079460018" match the same contact.
@MainActor
final class ContactsDirectory {
    private var index: [String: String] = [:]
    private var state = State.notLoaded
    private enum State { case notLoaded, loading, loaded }
    /// Called on the main thread when the index changes (loaded or Contacts edited).
    var onChange: (() -> Void)?

    init() {
        NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .loaded else { return }
                self.state = .notLoaded
                self.load()
            }
        }
    }

    /// The contact's name, or nil. The first call starts loading (asking for access the
    /// first time) and returns nil; onChange fires when the names are available.
    func name(for number: String) -> String? {
        guard let key = Self.key(number) else { return nil }
        if state == .notLoaded { load() }
        return index[key]
    }

    func load() {
        guard state == .notLoaded else { return }
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .denied, .restricted:
            state = .loaded
            return
        default:
            break
        }
        state = .loading
        CNContactStore().requestAccess(for: .contacts) { granted, _ in
            guard granted else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.finish([:]) } }
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let names = Self.readAddressBook()
                DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(names) } }
            }
        }
    }

    private func finish(_ names: [String: String]) {
        index = names
        state = .loaded
        onChange?()
    }

    nonisolated private static func readAddressBook() -> [String: String] {
        var names: [String: String] = [:]
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                    CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
            let person = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let name = person.isEmpty ? c.organizationName : person
            guard !name.isEmpty else { return }
            for phone in c.phoneNumbers {
                if let k = key(phone.value.stringValue), names[k] == nil { names[k] = name }
            }
        }
        return names
    }

    /// The last 9 digits; nil for short numbers (e.g. 112), which would match too much.
    nonisolated static func key(_ number: String) -> String? {
        let digits = number.filter(\.isNumber)
        guard digits.count >= 6 else { return nil }
        return String(digits.suffix(9))
    }
}
