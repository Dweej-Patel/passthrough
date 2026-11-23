import Foundation
import PassthroughCore

/// What one side sends: a clipboard's contents or files dropped on the view.
public struct ClipPayload: Sendable {
    public enum Content: Sendable {
        case data(Data)
        case file(URL)
        case folder
    }

    public struct Item: Sendable {
        public var format: ClipSyncWire.Format
        /// The relative path, for files and folders.
        public var name: String
        public var size: UInt64
        public var content: Content

        public init(format: ClipSyncWire.Format, name: String = "", size: UInt64, content: Content) {
            self.format = format
            self.name = name
            self.size = size
            self.content = content
        }

        public static func data(_ format: ClipSyncWire.Format, _ data: Data) -> Item {
            Item(format: format, size: UInt64(data.count), content: .data(data))
        }
    }

    public var items: [Item]
    public init(items: [Item]) { self.items = items }

    public var total: UInt64 { items.reduce(0) { $0 + $1.size } }
    public var hasFiles: Bool { items.contains { $0.format.isFile } }

    public enum FilesError: Error, Equatable {
        /// Over `maxBytes` or `maxItems`: counting stopped there.
        case tooLarge
        case unreadable
    }

    /// The files and folders at `urls` and everything under the folders, named
    /// from each one's own name down. Symbolic links and anything that isn't
    /// a regular file or a folder are left out. Counting stops at the first
    /// byte over `maxBytes` or item over `maxItems`. Names are sent precomposed
    /// (NFC), with the characters the wire doesn't allow (`/`, `\`, `:`, control
    /// characters) replaced; a receiver renames what its own file system can't hold.
    public static func files(_ urls: [URL], maxBytes: UInt64? = nil, maxItems: Int = .max) -> Result<ClipPayload, FilesError> {
        var items: [Item] = []
        var total: UInt64 = 0
        var taken = Set<String>()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]

        func add(_ url: URL, name: String, values: URLResourceValues) -> FilesError? {
            if values.isSymbolicLink == true { return nil }
            if values.isDirectory == true {
                items.append(Item(format: .folder, name: name, size: 0, content: .folder))
            } else if values.isRegularFile == true {
                let size = UInt64(max(values.fileSize ?? 0, 0))
                total += size
                if let maxBytes, total > maxBytes { return .tooLarge }
                items.append(Item(format: .file, name: name, size: size, content: .file(url)))
            } else {
                return nil
            }
            return items.count > maxItems ? .tooLarge : nil
        }

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return .failure(.unreadable) }
            let top = unique(cleanPart(url.lastPathComponent), in: &taken)
            if let error = add(url, name: top, values: values) { return .failure(error) }
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, _ in true }) else { continue }
            // Each folder's name as sent, so what's in it follows it.
            var sent: [String: String] = [url.standardizedFileURL.path: top]
            var childNames: [String: Set<String>] = [:]
            for case let child as URL in walker {
                guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
                let parentPath = child.deletingLastPathComponent().standardizedFileURL.path
                guard let parent = sent[parentPath] else { walker.skipDescendants(); continue }
                if values.isSymbolicLink == true { continue }
                var siblings = childNames[parent, default: []]
                let name = parent + "/" + unique(cleanPart(child.lastPathComponent), in: &siblings)
                childNames[parent] = siblings
                guard name.utf8.count <= ClipSyncWire.maxNameBytes else { walker.skipDescendants(); continue }
                if let error = add(child, name: name, values: values) { return .failure(error) }
                if values.isDirectory == true { sent[child.standardizedFileURL.path] = name }
            }
        }
        return .success(ClipPayload(items: items))
    }

    /// One part of a name as the other side can make it.
    static func cleanPart(_ part: String) -> String {
        var out = String(part.precomposedStringWithCanonicalMapping.unicodeScalars.map { s -> Character in
            let v = s.value
            if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) || s == "\\" || s == ":" || s == "/" { return "_" }
            return Character(s)
        })
        if out.isEmpty || out == "." || out == ".." { out = "_" }
        while out.utf8.count > ClipSyncWire.maxNamePartBytes { out.removeLast() }
        return out
    }

    /// `name`, or `name 2`, `name 3`… so no two in `taken` match without regard to case.
    static func unique(_ name: String, in taken: inout Set<String>) -> String {
        var candidate = name
        var n = 2
        while taken.contains(candidate.lowercased()) {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            n += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }
}

/// A transfer the other side finished sending.
public struct ReceivedTransfer: Sendable {
    public struct Item: Sendable {
        public var format: ClipSyncWire.Format
        public var name: String
        /// Text, RTF, HTML or PNG.
        public var data: Data?
        /// A file or folder, where it was put.
        public var url: URL?
    }

    public var transfer: UInt32
    public var kind: ClipSyncWire.Kind
    public var x: UInt16
    public var y: UInt16
    public var items: [Item]
    /// The folder the files are in (nil when there are none); the receiver decides when it goes.
    public var folder: URL?

    /// The files and folders at the top, which hold the rest.
    public var topLevel: [URL] { items.filter { $0.format.isFile && ClipSyncWire.parent(of: $0.name) == nil }.compactMap(\.url) }
    public func data(_ format: ClipSyncWire.Format) -> Data? { items.first { $0.format == format }?.data }

    /// The same contents to send on to another side (a host passing a viewer's copy to its other viewers).
    public var payload: ClipPayload {
        ClipPayload(items: items.compactMap { item in
            switch item.format {
            case .folder: return ClipPayload.Item(format: .folder, name: item.name, size: 0, content: .folder)
            case .file:
                guard let url = item.url else { return nil }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(UInt64.init) ?? 0
                return ClipPayload.Item(format: .file, name: item.name, size: size, content: .file(url))
            default:
                guard let data = item.data else { return nil }
                return .data(item.format, data)
            }
        })
    }
}
