import Foundation
import Contacts

// Contacts: reads and writes through the Contacts framework (contactsd), which merges
// linked cards and syncs over CardDAV. The per-account SQLite files are read only to
// prove a card reached the server (its CardDAV ETag).

// MARK: - Domain

struct ContactsSettings: DomainSettings {
    static let key = "contacts"
    /// Regexes matched against full names. A match hides the contact everywhere.
    var excludeNamePatterns: [String]
    /// Group names whose members are hidden everywhere.
    var excludeGroups: [String]
    /// Contact IDs hidden everywhere.
    var excludeContactIDs: [String]

    static let defaults = ContactsSettings(excludeNamePatterns: [], excludeGroups: [], excludeContactIDs: [])
}

let contactsDomain = Domain(name: "contacts", defaults: ContactsSettings.defaults, commands: contactsCommands, checks: { ctx in
    let status = CNContactStore.authorizationStatus(for: .contacts)
    guard status == .authorized else {
        return [Check(domain: "contacts", name: "framework", ok: status == .notDetermined,
                      detail: status == .notDetermined ? "not asked yet. The first command prompts." : "access is \(status.rawValue)",
                      fix: status == .notDetermined ? nil : "System Settings > Privacy & Security > Contacts")]
    }
    let t = Date()
    do {
        let (people, hidden) = try ContactsStore(ctx).all()
        return [Check(domain: "contacts", name: "framework", ok: true,
                      detail: "\(people.count) people readable, \(hidden) hidden, \(Int(Date().timeIntervalSince(t) * 1000)) ms", fix: nil)]
    } catch {
        return [Check(domain: "contacts", name: "framework", ok: false, detail: AppleError.wrap(error).description, fix: nil)]
    }
})

// MARK: - Outputs

struct Labeled: Encodable {
    let label: String?
    let value: String
}

struct ContactInfo: Output {
    let id: String
    let name: String
    let givenName: String?
    let familyName: String?
    let middleName: String?
    let nickname: String?
    let organization: String?
    let jobTitle: String?
    let department: String?
    let emails: [Labeled]
    let phones: [Labeled]
    let addresses: [Labeled]
    let urls: [Labeled]
    let birthday: String?
    var groups: [String]? = nil
    /// True once the card has a CardDAV ETag from the server. Nil when no synced source holds it.
    var synced: Bool? = nil
    var created: Bool? = nil
    var updated: Bool? = nil

    var line: String {
        var s = name
        if let o = organization, o != name { s += " (\(o))" }
        if let e = emails.first { s += "  \(e.value)" }
        if let p = phones.first { s += "  \(p.value)" }
        return s + "  \(id)"
    }
    var text: String {
        if created == true { return "created \(name)  \(id)" }
        if updated == true { return "updated \(name)  \(id)" }
        guard groups != nil || synced != nil else { return line }
        var out = [name]
        if let o = organization { out.append("Organization: \(o)" + (jobTitle.map { ", \($0)" } ?? "")) }
        for e in emails { out.append("Email \(e.label ?? ""): \(e.value)") }
        for p in phones { out.append("Phone \(p.label ?? ""): \(p.value)") }
        for a in addresses { out.append("Address \(a.label ?? ""): \(a.value)") }
        for u in urls { out.append("URL \(u.label ?? ""): \(u.value)") }
        if let b = birthday { out.append("Birthday: \(b)") }
        if let g = groups, !g.isEmpty { out.append("Groups: \(g.joined(separator: ", "))") }
        out.append("ID: \(id)")
        return out.joined(separator: "\n")
    }
}

struct ContactList: Output {
    let contacts: [ContactInfo]
    let hidden: Int
    var text: String { contacts.map(\.line).joined(separator: "\n") + (hidden > 0 ? "\n\(hidden) contact(s) hidden by privacy config" : "") }
}

struct ContactGroup: Encodable { let id: String; let name: String; let members: Int }
struct ContactGroups: Output {
    let groups: [ContactGroup]
    var text: String { groups.map { "\($0.name)  (\($0.members))" }.joined(separator: "\n") }
}

struct DuplicateSet: Encodable {
    let reason: String     // "name", "email", or "phone"
    let value: String
    let contacts: [ContactInfo]
}
struct Duplicates: Output {
    let duplicates: [DuplicateSet]
    var text: String {
        duplicates.isEmpty ? "no duplicates found" :
            duplicates.map { "same \($0.reason) \($0.value):\n" + $0.contacts.map { "  " + $0.line }.joined(separator: "\n") }.joined(separator: "\n")
    }
}

struct ContactAck: Output {
    let id: String
    let deleted: Bool
    var text: String { "deleted \(id)" }
}

// MARK: - Commands

private let fieldParams: [Param] = [
    Param("first", "Given name"), Param("last", "Family name"), Param("middle", "Middle name"), Param("nickname", "Nickname"),
    Param("org", "Organization"), Param("job", "Job title"), Param("department", "Department"),
    Param("birthday", "YYYY-MM-DD, or MM-DD with no year"),
]

private func contactsCommands(_ ctx: Context) -> [Command] {[
    Command(["contacts", "list"], .read, "List people, sorted by name. Linked cards count once.",
            [Param("group", "Only members of this group"), Param("limit", .integer, "Max (default 100)")]) { a in
        let store = try ContactsStore(ctx)
        var (people, hidden) = try store.all()
        if let g = a.string("group") {
            let members = try store.memberIDs(ofGroupNamed: g)
            people = people.filter { members.contains($0.identifier) }
        }
        return ContactList(contacts: people.prefix(a.int("limit", 100)).map { contactInfo($0) }, hidden: hidden)
    },
    Command(["contacts", "search"], .read, "Search names, nicknames, organizations, emails, and phone numbers.",
            [Param("query", required: true, positional: true, "Text, email, or phone digits"), Param("limit", .integer, "Max (default 20)")]) { a in
        let (hits, hidden) = try ContactsStore(ctx).search(try a.require("query"))
        return ContactList(contacts: hits.prefix(a.int("limit", 20)).map { contactInfo($0) }, hidden: hidden)
    },
    Command(["contacts", "read"], .read, "Read one person with every field, groups, and sync state.",
            [Param("id", required: true, positional: true, "Contact ID")]) { a in
        let store = try ContactsStore(ctx)
        let c = try store.contact(try a.require("id"))
        var info = contactInfo(c)
        info.groups = try store.groupNames(of: c.identifier)
        info.synced = store.isSynced(c.identifier)
        return info
    },
    Command(["contacts", "groups"], .read, "List contact groups with member counts.") { _ in
        ContactGroups(groups: try ContactsStore(ctx).groups())
    },
    Command(["contacts", "duplicates"], .read, "Find people who share a name, email, or phone number.") { _ in
        Duplicates(duplicates: try ContactsStore(ctx).duplicates())
    },
    Command(["contacts", "create"], .write, "Create a contact in the default account (iCloud). Lists are comma-separated; label a value as label=value.",
            fieldParams + [Param("email", "Emails, e.g. work=jane@x.com,jane@home.com"), Param("phone", "Phones, e.g. mobile=+15551234567"),
                           Param("url", "URLs"), Param("group", "Add to this group")]) { a in
        let store = try ContactsStore(ctx)
        let c = CNMutableContact()
        try applyFields(a, to: c)
        c.emailAddresses = a.list("email").map(labeled { $0 as NSString })
        c.phoneNumbers = a.list("phone").map(labeled { CNPhoneNumber(stringValue: $0) })
        c.urlAddresses = a.list("url").map { CNLabeledValue(label: nil, value: $0 as NSString) }
        guard !(c.givenName + c.familyName + c.organizationName).isEmpty else {
            throw AppleError.invalid("give at least one of first, last, or org")
        }
        let id = try store.create(c, group: a.string("group"))
        var info = contactInfo(try store.contact(id))
        info.created = true
        return info
    },
    Command(["contacts", "update"], .write, "Change fields on a contact. Emails and phones are added or removed, never replaced wholesale.",
            [Param("id", required: true, positional: true, "Contact ID")] + fieldParams + [
                Param("add-email", "Emails to add (label=value allowed)"), Param("remove-email", "Emails to remove"),
                Param("add-phone", "Phones to add (label=value allowed)"), Param("remove-phone", "Phones to remove (digits match)"),
                Param("add-url", "URLs to add")]) { a in
        let store = try ContactsStore(ctx)
        let id = try a.require("id")
        let c = try store.contact(id).mutableCopy() as! CNMutableContact
        try applyFields(a, to: c)
        let dropEmail = Set(a.list("remove-email").map { $0.lowercased() })
        c.emailAddresses = c.emailAddresses.filter { !dropEmail.contains(($0.value as String).lowercased()) }
            + a.list("add-email").map(labeled { $0 as NSString })
        let dropPhone = Set(a.list("remove-phone").map { $0.filter(\.isNumber) })
        c.phoneNumbers = c.phoneNumbers.filter { !dropPhone.contains($0.value.stringValue.filter(\.isNumber)) }
            + a.list("add-phone").map(labeled { CNPhoneNumber(stringValue: $0) })
        c.urlAddresses += a.list("add-url").map { CNLabeledValue(label: nil, value: $0 as NSString) }
        try store.update(c)
        var info = contactInfo(try store.contact(id))
        info.updated = true
        return info
    },
    Command(["contacts", "delete"], .destructive, "Delete a contact from every account it is in.",
            [Param("id", required: true, positional: true, "Contact ID")]) { a in
        let id = try a.require("id")
        try ContactsStore(ctx).delete(id)
        return ContactAck(id: id, deleted: true)
    },
]}

/// "work=jane@x.com" -> labeled value with the work label. Plain values get no label.
private func labeled<V>(_ make: @escaping (String) -> V) -> (String) -> CNLabeledValue<V> {
    { raw in
        let known = ["home": CNLabelHome, "work": CNLabelWork, "other": CNLabelOther, "mobile": CNLabelPhoneNumberMobile,
                     "main": CNLabelPhoneNumberMain, "iphone": CNLabelPhoneNumberiPhone]
        if let eq = raw.firstIndex(of: "="), !raw[..<eq].contains("@") {
            let l = String(raw[..<eq]).lowercased()
            return CNLabeledValue(label: known[l] ?? l, value: make(String(raw[raw.index(after: eq)...])))
        }
        return CNLabeledValue(label: nil, value: make(raw))
    }
}

private func applyFields(_ a: Args, to c: CNMutableContact) throws {
    if let v = a.string("first") { c.givenName = v }
    if let v = a.string("last") { c.familyName = v }
    if let v = a.string("middle") { c.middleName = v }
    if let v = a.string("nickname") { c.nickname = v }
    if let v = a.string("org") { c.organizationName = v }
    if let v = a.string("job") { c.jobTitle = v }
    if let v = a.string("department") { c.departmentName = v }
    if let b = a.string("birthday") {
        let parts = b.split(separator: "-").compactMap { Int($0) }
        var d = DateComponents()
        switch parts.count {
        case 3: d.year = parts[0]; d.month = parts[1]; d.day = parts[2]
        case 2: d.month = parts[0]; d.day = parts[1]
        default: throw AppleError.invalid("birthday \(b), use YYYY-MM-DD or MM-DD")
        }
        c.birthday = d
    }
}

/// Label localization is slow (an XPC hop per call), and a handful of labels repeat, so cache them.
private var labelCache: [String: String] = [:]
private func localizedLabel(_ l: String) -> String {
    if let v = labelCache[l] { return v }
    let v = CNLabeledValue<NSString>.localizedString(forLabel: l)
    labelCache[l] = v
    return v
}

private func contactInfo(_ c: CNContact) -> ContactInfo {
    func label(_ l: String?) -> String? { l.map(localizedLabel) }
    func opt(_ s: String) -> String? { s.isEmpty ? nil : s }
    // List and search fetch fewer keys. Reading a key that was not fetched raises, so check first.
    func has(_ k: String) -> Bool { c.isKeyAvailable(k) }
    let name = CNContactFormatter.string(from: c, style: .fullName) ?? opt(c.organizationName) ?? "(no name)"
    let bday: String? = (has(CNContactBirthdayKey) ? c.birthday : nil).flatMap { b in
        guard let m = b.month, let d = b.day else { return nil }
        return b.year.map { String(format: "%04d-%02d-%02d", $0, m, d) } ?? String(format: "--%02d-%02d", m, d)
    }
    return ContactInfo(
        id: c.identifier, name: name, givenName: opt(c.givenName), familyName: opt(c.familyName), middleName: opt(c.middleName),
        nickname: opt(c.nickname), organization: opt(c.organizationName),
        jobTitle: has(CNContactJobTitleKey) ? opt(c.jobTitle) : nil, department: has(CNContactDepartmentNameKey) ? opt(c.departmentName) : nil,
        emails: c.emailAddresses.map { Labeled(label: label($0.label), value: $0.value as String) },
        phones: c.phoneNumbers.map { Labeled(label: label($0.label), value: $0.value.stringValue) },
        addresses: (has(CNContactPostalAddressesKey) ? c.postalAddresses : []).map {
            Labeled(label: label($0.label), value: CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress)
                .replacingOccurrences(of: "\n", with: ", "))
        },
        urls: (has(CNContactUrlAddressesKey) ? c.urlAddresses : []).map { Labeled(label: label($0.label), value: $0.value as String) },
        birthday: bday)
}

// MARK: - Store (Contacts framework)

final class ContactsStore {
    static let sourcesDir = NSHomeDirectory() + "/Library/Application Support/AddressBook/Sources"
    static let keys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
    ] + ([CNContactGivenNameKey, CNContactFamilyNameKey, CNContactMiddleNameKey, CNContactNicknameKey,
          CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactDepartmentNameKey,
          CNContactEmailAddressesKey, CNContactPhoneNumbersKey, CNContactPostalAddressesKey,
          CNContactUrlAddressesKey, CNContactBirthdayKey] as [CNKeyDescriptor])

    /// Fields shown in list and search rows. Fetching fewer keys makes a full pass about 35% faster.
    static let lightKeys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        + ([CNContactOrganizationNameKey, CNContactNicknameKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor])

    let store = CNContactStore()
    let privacy: PrivacyFilter
    let hiddenGroups: [String]

    init(_ ctx: Context) throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: break
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            var granted = false
            CNContactStore().requestAccess(for: .contacts) { ok, _ in granted = ok; sem.signal() }
            _ = sem.wait(timeout: .now() + 60)
            if !granted { throw AppleError.permission("Contacts access was not granted") }
        default:
            throw AppleError.permission("allow Contacts for this app in System Settings > Privacy & Security > Contacts")
        }
        let s = try ctx.settings(ContactsSettings.self)
        privacy = try PrivacyFilter(titlePatterns: s.excludeNamePatterns, containers: [], ids: s.excludeContactIDs)
        hiddenGroups = s.excludeGroups
    }

    /// IDs in excluded groups. Empty (and free) when no group is excluded.
    private lazy var hiddenByGroup: Set<String> = {
        guard !hiddenGroups.isEmpty else { return [] }
        let wanted = Set(hiddenGroups.map { $0.lowercased() })
        let gs = ((try? store.groups(matching: nil)) ?? []).filter { wanted.contains($0.name.lowercased()) }
        return Set(gs.flatMap { g in
            ((try? store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: g.identifier),
                                         keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])) ?? []).map(\.identifier)
        })
    }()

    private func hides(_ c: CNContact) -> Bool {
        privacy.hides(title: CNContactFormatter.string(from: c, style: .fullName) ?? c.organizationName, containers: [], id: c.identifier)
            || hiddenByGroup.contains(c.identifier)
    }

    /// Every person (linked cards merged), sorted by name. Hidden people are removed here.
    func all(keys: [CNKeyDescriptor] = ContactsStore.lightKeys) throws -> (people: [CNContact], hidden: Int) {
        let raw: [CNContact] = try withDeadline(15, "reading contacts") {
            var out: [CNContact] = []
            let req = CNContactFetchRequest(keysToFetch: keys)
            req.unifyResults = true
            req.sortOrder = .userDefault
            try self.store.enumerateContacts(with: req) { c, _ in out.append(c) }
            return out
        }
        let visible = raw.filter { !hides($0) }
        return (visible, raw.count - visible.count)
    }

    /// Fast path first: Apple's indexed name, email, and phone lookups (about 20 ms).
    /// Falls back to one full pass only when they find nothing (organization or partial matches).
    func search(_ query: String) throws -> (people: [CNContact], hidden: Int) {
        let q = query.lowercased()
        let digits = q.filter(\.isNumber)
        var preds = [CNContact.predicateForContacts(matchingName: query)]
        if q.contains("@") { preds.append(CNContact.predicateForContacts(matchingEmailAddress: query)) }
        if digits.count >= 7 { preds.append(CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: query))) }
        var seen = Set<String>(), raw: [CNContact] = []
        for p in preds {
            let hits = try withDeadline(10, "searching contacts") { try self.store.unifiedContacts(matching: p, keysToFetch: Self.lightKeys) }
            for c in hits where seen.insert(c.identifier).inserted { raw.append(c) }
        }
        if raw.isEmpty {
            let (people, hidden) = try all()
            raw = people.filter { c in
                let words = [c.givenName, c.middleName, c.familyName, c.nickname, c.organizationName,
                             CNContactFormatter.string(from: c, style: .fullName) ?? ""] + c.emailAddresses.map { $0.value as String }
                if words.contains(where: { $0.lowercased().contains(q) }) { return true }
                return digits.count >= 4 && c.phoneNumbers.contains { $0.value.stringValue.filter(\.isNumber).contains(digits) }
            }
            return (raw, hidden)
        }
        let visible = raw.filter { !hides($0) }
        return (visible, raw.count - visible.count)
    }

    func contact(_ id: String) throws -> CNContact {
        let c: CNContact
        do {
            c = try withDeadline(10, "reading the contact") { try self.store.unifiedContact(withIdentifier: id, keysToFetch: Self.keys) }
        } catch let e as AppleError {
            throw e
        } catch {
            throw AppleError.notFound("contact \(id)")
        }
        if hides(c) { throw AppleError.hidden("contact \(id)") }
        return c
    }

    func groups() throws -> [ContactGroup] {
        let hidden = Set(hiddenGroups.map { $0.lowercased() })
        return try store.groups(matching: nil).filter { !hidden.contains($0.name.lowercased()) }.map { g in
            let n = try store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: g.identifier),
                                              keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]).count
            return ContactGroup(id: g.identifier, name: g.name, members: n)
        }
    }

    func group(named name: String) throws -> CNGroup {
        if hiddenGroups.contains(where: { $0.lowercased() == name.lowercased() }) { throw AppleError.hidden("group \(name)") }
        let gs = try store.groups(matching: nil).filter { $0.name.lowercased() == name.lowercased() }
        guard gs.count == 1 else { throw gs.isEmpty ? AppleError.notFound("group \(name)") : AppleError.invalid("\(gs.count) groups are named \(name)") }
        return gs[0]
    }

    func memberIDs(ofGroupNamed name: String) throws -> Set<String> {
        let g = try group(named: name)
        return Set(try store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: g.identifier),
                                             keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]).map(\.identifier))
    }

    func groupNames(of id: String) throws -> [String] {
        let hidden = Set(hiddenGroups.map { $0.lowercased() })
        return try store.groups(matching: nil).filter { g in
            !hidden.contains(g.name.lowercased()) &&
            ((try? store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: g.identifier),
                                         keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])) ?? []).contains { $0.identifier == id }
        }.map(\.name)
    }

    func duplicates() throws -> [DuplicateSet] {
        let (people, _) = try all()
        var byKey: [String: [CNContact]] = [:]
        for c in people {
            if let n = CNContactFormatter.string(from: c, style: .fullName)?.lowercased().trimmingCharacters(in: .whitespaces), !n.isEmpty {
                byKey["name\u{1}" + n, default: []].append(c)
            }
            for e in Set(c.emailAddresses.map { ($0.value as String).lowercased() }) { byKey["email\u{1}" + e, default: []].append(c) }
            for p in Set(c.phoneNumbers.map { String($0.value.stringValue.filter(\.isNumber).suffix(10)) }) where p.count >= 7 {
                byKey["phone\u{1}" + p, default: []].append(c)
            }
        }
        return byKey.filter { $0.value.count > 1 }.map { k, v in
            let parts = k.split(separator: "\u{1}", maxSplits: 1).map(String.init)
            return DuplicateSet(reason: parts[0], value: parts[1], contacts: v.map { contactInfo($0) })
        }.sorted { ($0.reason, $0.value) < ($1.reason, $1.value) }
    }

    /// Saves into the default container, which is the iCloud account here.
    func create(_ c: CNMutableContact, group: String?) throws -> String {
        let req = CNSaveRequest()
        req.add(c, toContainerWithIdentifier: nil)
        if let group { req.addMember(c, to: try self.group(named: group)) }
        try withDeadline(10, "saving the contact") { try self.store.execute(req) }
        return c.identifier
    }

    func update(_ c: CNMutableContact) throws {
        if hides(c) { throw AppleError.hidden("contact \(c.identifier)") }
        let req = CNSaveRequest()
        req.update(c)
        try withDeadline(10, "saving the contact") { try self.store.execute(req) }
    }

    func delete(_ id: String) throws {
        let c = try contact(id).mutableCopy() as! CNMutableContact
        let req = CNSaveRequest()
        req.delete(c)
        try withDeadline(10, "deleting the contact") { try self.store.execute(req) }
    }

    /// True when a synced account's store holds this card with a CardDAV ETag, meaning the server
    /// accepted it. False when the card is there without one. Nil when no store holds it.
    func isSynced(_ id: String) -> Bool? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.sourcesDir)) ?? []
        var seen = false
        for f in files {
            let p = Self.sourcesDir + "/" + f + "/AddressBook-v22.abcddb"
            guard let db = try? SQLiteReader(path: p),
                  let rows = try? db.query("SELECT ZEXTERNALMODIFICATIONTAG AS ETAG FROM ZABCDRECORD WHERE ZUNIQUEID = ?", [id]),
                  let row = rows.first else { continue }
            seen = true
            if row.str("ETAG") != nil { return true }
        }
        return seen ? false : nil
    }
}
