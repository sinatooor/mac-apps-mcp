// ContactsTools.swift — Contacts through Apple's Contacts framework.
// Search, create and add details. No delete, and existing emails/phones are never removed.

import Foundation
import Contacts

let cnStore = CNContactStore()
var contactsAccessOK = false

func ensureContactsAccess() throws {
    if contactsAccessOK { return }
    let status = CNContactStore.authorizationStatus(for: .contacts)
    if status == .denied || status == .restricted {
        throw ToolError("Contacts access is denied. Enable it in System Settings > Privacy & Security > Contacts.")
    }
    if status != .authorized {
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        cnStore.requestAccess(for: .contacts) { ok, _ in granted = ok; sem.signal() }
        sem.wait()
        if !granted { throw ToolError("Contacts access was not granted.") }
    }
    contactsAccessOK = true
}

let contactKeys: [CNKeyDescriptor] = [
    CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
    CNContactJobTitleKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
] as [CNKeyDescriptor]

func contactDict(_ c: CNContact) -> [String: Any] {
    var d: [String: Any] = [
        "id": c.identifier,
        "name": "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces),
    ]
    if !c.organizationName.isEmpty { d["organization"] = c.organizationName }
    if !c.jobTitle.isEmpty { d["job_title"] = c.jobTitle }
    let emails = c.emailAddresses.map { $0.value as String }
    if !emails.isEmpty { d["emails"] = emails }
    let phones = c.phoneNumbers.map { $0.value.stringValue }
    if !phones.isEmpty { d["phones"] = phones }
    return d
}

func searchContacts(_ q: String) throws -> [CNContact] {
    let pred: NSPredicate
    let digits = q.filter { $0.isNumber }
    if q.contains("@") {
        pred = CNContact.predicateForContacts(matchingEmailAddress: q)
    } else if digits.count >= 5 && digits.count >= q.filter({ $0.isLetter }).count {
        pred = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: q))
    } else {
        pred = CNContact.predicateForContacts(matchingName: q)
    }
    return try cnStore.unifiedContacts(matching: pred, keysToFetch: contactKeys)
}

func normalizedPhone(_ s: String) -> String { s.filter { $0.isNumber } }

let contactTools: [Tool] = [
    Tool(app: "contacts", name: "contacts_search",
         description: "Find contacts by name, email or phone.",
         properties: ["query": prop("string"), "limit": prop("integer", "default 10")],
         required: ["query"], kind: .read) { a in
        try ensureContactsAccess()
        let found = try searchContacts(try a.req("query"))
        return Array(found.prefix(a.int("limit") ?? 10)).map(contactDict)
    },

    Tool(app: "contacts", name: "contacts_create",
         description: "Create a contact. Refuses if the name already exists unless force=true.",
         properties: [
            "first_name": prop("string"), "last_name": prop("string"),
            "organization": prop("string"), "job_title": prop("string"),
            "emails": listProp(), "phones": listProp(),
            "force": prop("boolean", "create even if a contact with this name exists"),
         ], required: ["first_name"], kind: .write) { a in
        try ensureContactsAccess()
        let first = try a.req("first_name")
        let last = a.str("last_name") ?? ""
        let fullName = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
        if a.bool("force") != true {
            let existing = try searchContacts(fullName)
            if !existing.isEmpty {
                return ["created": false,
                        "message": "A contact with this name already exists. Use contacts_update to add details, or force=true.",
                        "existing": existing.prefix(5).map(contactDict)] as [String: Any]
            }
        }
        let c = CNMutableContact()
        c.givenName = first
        c.familyName = last
        if let o = a.str("organization") { c.organizationName = o }
        if let j = a.str("job_title") { c.jobTitle = j }
        c.emailAddresses = a.list("emails").map { CNLabeledValue(label: CNLabelOther, value: $0 as NSString) }
        c.phoneNumbers = a.list("phones").map {
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0))
        }
        let req = CNSaveRequest()
        req.add(c, toContainerWithIdentifier: nil)
        try cnStore.execute(req)
        audit("contacts_create", fullName)
        return ["created": true, "contact": contactDict(c)] as [String: Any]
    },

    Tool(app: "contacts", name: "contacts_update",
         description: "Add emails/phones to a contact or set organization/job title. Never removes anything.",
         properties: [
            "id": prop("string"),
            "add_emails": listProp(), "add_phones": listProp(),
            "organization": prop("string"), "job_title": prop("string"),
         ], required: ["id"], kind: .write) { a in
        try ensureContactsAccess()
        let id = try a.req("id")
        let existing = try cnStore.unifiedContact(withIdentifier: id, keysToFetch: contactKeys)
        guard let c = existing.mutableCopy() as? CNMutableContact else { throw ToolError("Could not edit contact.") }
        let haveEmails = Set(c.emailAddresses.map { ($0.value as String).lowercased() })
        for e in a.list("add_emails") where !haveEmails.contains(e.lowercased()) {
            c.emailAddresses.append(CNLabeledValue(label: CNLabelOther, value: e as NSString))
        }
        let havePhones = Set(c.phoneNumbers.map { normalizedPhone($0.value.stringValue) })
        for p in a.list("add_phones") where !havePhones.contains(normalizedPhone(p)) {
            c.phoneNumbers.append(CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: p)))
        }
        if let o = a.str("organization") { c.organizationName = o }
        if let j = a.str("job_title") { c.jobTitle = j }
        let req = CNSaveRequest()
        req.update(c)
        try cnStore.execute(req)
        audit("contacts_update", "\(c.givenName) \(c.familyName) | +emails \(a.list("add_emails").count) +phones \(a.list("add_phones").count)")
        return ["updated": contactDict(c)]
    },
]
