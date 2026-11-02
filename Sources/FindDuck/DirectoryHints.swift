import Foundation
import Darwin

// Advisory notifications only. Remote SMB implementations differ, so the catalog
// always schedules direct directory reconciliation independently of these hints.
final class DirectoryHints: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SMBSearch.directory-hints", qos: .utility)
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    func replace(_ directories: [URL], onChange: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            let wanted = Set(directories.map(\.path))
            for path in Array(sources.keys) where !wanted.contains(path) { sources.removeValue(forKey: path)?.cancel() }
            for directory in directories where sources[directory.path] == nil {
                let fd = open(directory.path, O_EVTONLY | O_CLOEXEC)
                guard fd >= 0 else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: queue)
                source.setEventHandler { onChange(directory.path) }
                source.setCancelHandler { close(fd) }
                sources[directory.path] = source
                source.resume()
            }
        }
    }
    func stop() {
        queue.async { [self] in
            for source in sources.values { source.cancel() }
            sources.removeAll()
        }
    }
}
