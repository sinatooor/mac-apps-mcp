// NotesSemantic.swift — semantic + keyword search over all notes, fully on-device.
//
// How it works:
//  1. List every note (id, title, folder, modified date) in a few bulk Apple Events.
//  2. Read the text of new or changed notes only, in batches, and cache it.
//  3. Split each note into chunks and embed them with Apple's NaturalLanguage sentence
//     embeddings (per detected language, English model as fallback). Vectors are normalized.
//  4. Query: embed the question, score each note by its best-matching chunk (cosine),
//     add a bonus for keyword hits in the cached text, return the top notes with a snippet.
//
// The index lives in ~/Library/Application Support/mac-apps-mcp/notes-index.plist and never
// leaves the Mac. Indexing works within a time budget and resumes on the next call.

import Foundation
import NaturalLanguage

struct NoteChunk: Codable {
    var lang: String
    var start: Int      // character offset of the chunk in the note text (for snippets)
    var length: Int
    var vec: Data       // normalized Float32 vector
}

struct IndexedNote: Codable {
    var title: String
    var folder: String
    var modified: Double    // seconds since 1970
    var text: String        // cached plain text (capped) for keyword search and snippets
    var chunks: [NoteChunk]
}

struct NotesIndex: Codable {
    var version = 2
    var notes: [String: IndexedNote] = [:]
    var total: Int? = nil       // number of indexable notes at the last listing
}

let indexURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mac-apps-mcp")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("notes-index.plist")
}()

func loadIndex() -> NotesIndex {
    guard let d = try? Data(contentsOf: indexURL),
          let idx = try? PropertyListDecoder().decode(NotesIndex.self, from: d),
          idx.version == NotesIndex().version else { return NotesIndex() }
    return idx
}

func saveIndex(_ idx: NotesIndex) {
    let enc = PropertyListEncoder()
    enc.outputFormat = .binary
    if let d = try? enc.encode(idx) { try? d.write(to: indexURL, options: .atomic) }
}

// MARK: - Embeddings

var embeddingModels: [String: NLEmbedding] = [:]
/// Embeddings are used from the background indexer and from searches; serialize access.
let embedLock = NSLock()

/// Embeds `text` with the model for `lang` (English fallback). Returns (language used, vector).
func embed(_ text: String, lang: String) -> (String, [Float])? {
    embedLock.lock(); defer { embedLock.unlock() }
    guard let m = embeddingModel(lang), let v = m.1.vector(for: text) else { return nil }
    return (m.0, normalizedVector(v))
}

/// Sentence embedding for a language, falling back to English. Call only while holding embedLock.
func embeddingModel(_ lang: String) -> (String, NLEmbedding)? {
    for code in [lang, "en"] {
        if let m = embeddingModels[code] { return (code, m) }
        if let m = NLEmbedding.sentenceEmbedding(for: NLLanguage(rawValue: code)) {
            embeddingModels[code] = m
            return (code, m)
        }
    }
    return nil
}

func normalizedVector(_ v: [Double]) -> [Float] {
    let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
    guard norm > 0 else { return v.map { Float($0) } }
    return v.map { Float($0 / norm) }
}

func toData(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

func fromData(_ d: Data) -> [Float] {
    var arr = [Float](repeating: 0, count: d.count / MemoryLayout<Float>.size)
    _ = arr.withUnsafeMutableBytes { d.copyBytes(to: $0) }
    return arr
}

func dot(_ a: [Float], _ b: [Float]) -> Float {
    var s: Float = 0
    for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
    return s
}

func detectLanguage(_ text: String) -> String {
    let r = NLLanguageRecognizer()
    r.processString(String(text.prefix(1000)))
    return r.dominantLanguage?.rawValue ?? "en"
}

/// Splits text into chunks of roughly `size` characters on sentence boundaries.
func chunkText(_ text: String, size: Int = 400, maxChunks: Int = 12) -> [(Int, Int)] {
    let tok = NLTokenizer(unit: .sentence)
    tok.string = text
    var chunks: [(Int, Int)] = []
    var curStart: String.Index? = nil
    var curEnd = text.startIndex
    tok.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        if curStart == nil { curStart = range.lowerBound }
        curEnd = range.upperBound
        if text.distance(from: curStart!, to: curEnd) >= size {
            chunks.append((text.distance(from: text.startIndex, to: curStart!), text.distance(from: curStart!, to: curEnd)))
            curStart = nil
        }
        return chunks.count < maxChunks
    }
    if let s = curStart, chunks.count < maxChunks {
        chunks.append((text.distance(from: text.startIndex, to: s), text.distance(from: s, to: curEnd)))
    }
    if chunks.isEmpty && !text.isEmpty { chunks.append((0, min(text.count, size))) }
    return chunks
}

func substring(_ text: String, _ start: Int, _ length: Int) -> String {
    guard start < text.count else { return "" }
    let a = text.index(text.startIndex, offsetBy: start)
    let b = text.index(a, offsetBy: min(length, text.count - start))
    return String(text[a..<b])
}

func embedNote(title: String, text: String) -> [NoteChunk] {
    var out: [NoteChunk] = []
    for (start, length) in chunkText(text) {
        var piece = substring(text, start, length)
        if start == 0 && !piece.hasPrefix(title) { piece = title + ". " + piece }
        // One shared (English) vector space keeps scores comparable; other languages
        // are covered by keyword matching.
        guard piece.count >= 3, let e = embed(piece, lang: "en") else { continue }
        out.append(NoteChunk(lang: e.0, start: start, length: length, vec: toData(e.1)))
    }
    return out
}

// MARK: - Reading notes

let asNotesTexts = """
on run argv
    set US to character id 31
    set RS to character id 30
    set out to ""
    tell application "Notes"
        repeat with i from 1 to count of argv
            set nid to item i of argv
            try
                set t to plaintext of note id nid
                set out to out & nid & US & t & RS
            end try
        end repeat
    end tell
    return out
end run
"""

/// Text of every note in the folders with this name (all accounts), in two bulk requests per folder.
let asFolderTexts = """
on run argv
    set US to character id 31
    set RS to character id 30
    set out to ""
    tell application "Notes"
        repeat with f in (folders whose name is (item 1 of argv))
            try
                set ids to id of notes of f
                set txts to plaintext of notes of f
                repeat with i from 1 to count of ids
                    set out to out & (item i of ids) & US & (item i of txts) & RS
                end repeat
            end try
        end repeat
    end tell
    return out
end run
"""

struct NoteListing { let id: String, title: String, folder: String, modified: Double, locked: Bool }

/// All notes that live in a folder (Recently Deleted excluded), via the bulk listing script.
func listAllNotes() throws -> [NoteListing] {
    // The script reports dates relative to its own start time, so convert them using the
    // time just before it started (not after it finished, which can be seconds later).
    let scriptStart = Date().timeIntervalSince1970
    let out = try appleScript(asNotesSearch + asHelpers, ["", "", ""], timeout: 240)
    let sections = out.components(separatedBy: "\u{1D}")
    var folderOf: [String: String] = [:]
    if sections.count > 1 {
        for m in records(sections[1]) where m.count >= 2 { folderOf[m[0]] = m[1] }
    }
    var seen = Set<String>()
    var list: [NoteListing] = []
    for f in records(sections[0]) where f.count >= 5 {
        guard !seen.contains(f[0]), let folder = folderOf[f[0]],
              folder != "Recently Deleted", folder != "Nyligen raderade" else { continue }
        seen.insert(f[0])
        let modified = (scriptStart + (Double(f[3]) ?? 0)).rounded()
        list.append(NoteListing(id: f[0], title: f[1], folder: folder, modified: modified, locked: f[4] == "true"))
    }
    return list
}

/// Brings the index up to date within `budget` seconds. Returns (indexed, total, remaining).
/// Titles of notes that were pending (new or changed) on the last update, for diagnostics.
var lastPending: [String] = []

func updateIndex(_ idx: inout NotesIndex, budget: TimeInterval) throws -> (Int, Int, Int) {
    let started = Date()
    let listing = try listAllNotes()
    idx.total = listing.filter { !$0.locked }.count
    let live = Set(listing.map { $0.id })
    for id in idx.notes.keys where !live.contains(id) { idx.notes.removeValue(forKey: id) }

    var todo: [NoteListing] = []
    for n in listing where !n.locked {
        if let have = idx.notes[n.id], abs(have.modified - n.modified) < 5 {
            idx.notes[n.id]?.folder = n.folder
            idx.notes[n.id]?.title = n.title
        } else {
            todo.append(n)
        }
    }
    lastPending = todo.prefix(8).map { n in
        if let have = idx.notes[n.id] {
            return "\(n.title) (changed: modified \(Int(n.modified - have.modified)) s later)"
        }
        return "\(n.title) (new)"
    }
    // Folders with many changed notes: read all their text in bulk. Others: note by note.
    var byFolder: [String: [NoteListing]] = [:]
    for n in todo { byFolder[n.folder, default: []].append(n) }
    var done = 0
    func store(_ n: NoteListing, _ raw: String?) {
        let text = String((raw ?? "").replacingOccurrences(of: "\u{FFFC}", with: "").prefix(20000))
        idx.notes[n.id] = IndexedNote(title: n.title, folder: n.folder, modified: n.modified,
                                      text: text, chunks: embedNote(title: n.title, text: text))
        done += 1
    }
    for (folder, notes) in byFolder.sorted(by: { $0.value.count > $1.value.count }) {
        if Date().timeIntervalSince(started) > budget { break }
        if notes.count > 15 {
            let out = try appleScript(asFolderTexts, [folder], timeout: 600)
            var texts: [String: String] = [:]
            for r in records(out) where r.count >= 2 { texts[r[0]] = r[1...].joined(separator: US) }
            for n in notes { store(n, texts[n.id]) }
            saveIndex(idx)
        } else {
            var i = 0
            while i < notes.count && Date().timeIntervalSince(started) < budget {
                let batch = Array(notes[i..<min(i + 50, notes.count)])
                let out = try appleScript(asNotesTexts, batch.map { $0.id }, timeout: 180)
                var texts: [String: String] = [:]
                for r in records(out) where r.count >= 2 { texts[r[0]] = r[1...].joined(separator: US) }
                for n in batch { store(n, texts[n.id]) }
                i += batch.count
                saveIndex(idx)
            }
        }
    }
    let total = listing.filter { !$0.locked }.count
    return (total - (todo.count - done), total, todo.count - done)
}

// MARK: - Background indexing

let indexLock = NSLock()
var indexRunning = false
var indexProgress = (indexed: 0, total: 0)

/// Starts one background indexing run (if none is running) that continues until finished.
/// Claude may run several copies of this server. A file lock makes sure only one of them
/// builds the index at a time; the others just search what's saved.
let indexLockPath = indexURL.deletingLastPathComponent().appendingPathComponent("notes-index.lock").path

func tryProcessLock() -> Int32? {
    let fd = open(indexLockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return nil }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return nil }
    return fd
}

func startBackgroundIndexing() {
    indexLock.lock()
    if indexRunning { indexLock.unlock(); return }
    indexRunning = true
    indexLock.unlock()
    Thread.detachNewThread {
        if let fd = tryProcessLock() {
            var idx = loadIndex()
            if let r = try? updateIndex(&idx, budget: 7200) {
                indexLock.lock(); indexProgress = (r.0, r.1); indexLock.unlock()
            }
            flock(fd, LOCK_UN); close(fd)
        }
        indexLock.lock(); indexRunning = false; indexLock.unlock()
    }
}

/// True while another copy of the server holds the indexing lock.
func otherProcessIndexing() -> Bool {
    guard let fd = tryProcessLock() else { return true }
    flock(fd, LOCK_UN); close(fd)
    return false
}

func backgroundRunning() -> Bool {
    indexLock.lock(); defer { indexLock.unlock() }
    return indexRunning
}

// MARK: - Tool

let notesSemanticTools: [Tool] = [
    Tool(app: "notes", name: "notes_semantic_search",
         description: "Find notes by meaning (on-device embeddings) plus keywords. Pass keywords in several languages (e.g. English, Swedish, Farsi) for best recall. First run builds an index and may need repeated calls.",
         properties: [
            "query": prop("string", "the question or topic"),
            "keywords": listProp("extra words/synonyms/translations to match in note text"),
            "limit": prop("integer", "default 10"),
            "index_seconds": prop("integer", "time budget for updating changed notes before searching, default 30"),
         ], required: ["query"], kind: .read) { a in
        let query = try a.req("query")
        var idx = loadIndex()
        var total = 0, remaining = 0
        if backgroundRunning() || otherProcessIndexing() {
            // A background run is still building the index: search what's saved so far.
            total = idx.total ?? 0
            remaining = max(0, total - idx.notes.count)
            if total == 0 { remaining = -1 }
        } else {
            (_, total, remaining) = try updateIndex(&idx, budget: TimeInterval(a.int("index_seconds") ?? 30))
            if remaining > 0 { startBackgroundIndexing() }
        }

        // Query vectors per language present in the index.
        var qvec: [String: [Float]] = [:]
        let langs = Set(idx.notes.values.flatMap { $0.chunks.map { $0.lang } })
        for l in langs {
            if let e = embed(query, lang: l), e.0 == l { qvec[l] = e.1 }
        }
        let keywords = (a.list("keywords") + [query]).map { $0.lowercased() }

        var scored: [(Float, String, IndexedNote, String, [String])] = []
        for (id, n) in idx.notes {
            var best: Float = 0
            var bestChunk: NoteChunk? = nil
            for c in n.chunks {
                guard let q = qvec[c.lang] else { continue }
                // Very short passages get high similarity by accident; weight by length.
            let s = dot(q, fromData(c.vec)) * min(1, Float(c.length) / 150)
                if s > best { best = s; bestChunk = c }
            }
            let hay = (n.title + "\n" + n.text).lowercased()
            let hits = keywords.filter { !$0.isEmpty && hay.contains($0) }
            let score = best + min(0.45, Float(hits.count) * 0.15)
            var snippet = bestChunk.map { substring(n.text, $0.start, min($0.length, 220)) } ?? String(n.text.prefix(220))
            if let kw = hits.first, let r = n.text.lowercased().range(of: kw) {
                let pos = n.text.lowercased().distance(from: n.text.lowercased().startIndex, to: r.lowerBound)
                snippet = substring(n.text, max(0, pos - 80), 220)
            }
            scored.append((score, id, n, snippet.replacingOccurrences(of: "\n", with: " "), hits))
        }
        scored.sort { $0.0 > $1.0 }
        let results = scored.prefix(a.int("limit") ?? 10).map { s -> [String: Any] in
            var d: [String: Any] = ["id": s.1, "title": s.2.title, "folder": s.2.folder,
                                    "score": (Double(s.0) * 100).rounded() / 100, "snippet": s.3]
            let matched = s.4.filter { $0 != query.lowercased() }
            if !matched.isEmpty { d["keywords_matched"] = matched }
            return d
        }
        var out: [String: Any] = ["results": results, "indexed": idx.notes.count]
        if total > 0 { out["total_notes"] = total }
        if remaining != 0 {
            out["note"] = "Index still building in the background (\(idx.notes.count) notes indexed so far). Results cover only those; search again in a few minutes for complete results."
            if !lastPending.isEmpty { out["pending_examples"] = lastPending }
        }
        return out
    },
]
