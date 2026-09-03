import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct SecureFileIdentity: Codable, Equatable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var fileType: UInt32

    public init(device: UInt64, inode: UInt64, fileType: UInt32) {
        self.device = device
        self.inode = inode
        self.fileType = fileType
    }
}

public enum SecureFileMutationError: Error, Equatable, CustomStringConvertible {
    case invalidPath
    case outsideAllowedRoot
    case destinationExists
    case unsupportedOverwrite
    case verificationFailed
    case posix(Int32)

    public var description: String {
        switch self {
        case .invalidPath: return "Invalid filesystem path"
        case .outsideAllowedRoot: return "Target is outside the allowed root"
        case .destinationExists: return "Destination already exists"
        case .unsupportedOverwrite: return "Secure overwrite is not supported for this operation"
        case .verificationFailed: return "Secure filesystem postcondition verification failed"
        case .posix(let code): return "POSIX filesystem error \(code)"
        }
    }
}

/// Final mutation primitives for approved filesystem operations.
///
/// The caller still performs PathGuard/PolicyEngine checks and approval. These primitives
/// close the final pathname race by opening every directory component with O_NOFOLLOW and
/// doing the state change relative to pinned directory file descriptors. They are intended
/// to defend against ordinary concurrent filesystem/symlink races, not a kernel/root attacker.
public struct SecureFileMutation: Sendable {
    private let beforeFinalMutation: (@Sendable () -> Void)?

    public init() {
        self.beforeFinalMutation = nil
    }

    /// Deterministic race injection for @testable tests. Production callers use init().
    init(beforeFinalMutation: @escaping @Sendable () -> Void) {
        self.beforeFinalMutation = beforeFinalMutation
    }

    public func identity(of approvedTarget: URL, allowedRoot: URL?) throws -> SecureFileIdentity {
        let parent = try openParent(of: approvedTarget, allowedRoot: allowedRoot, createIntermediates: false)
        defer { close(parent.fd) }
        var itemStat = stat()
        let status = parent.leaf.withCString { fstatat(parent.fd, $0, &itemStat, AT_SYMLINK_NOFOLLOW) }
        guard status == 0 else { throw SecureFileMutationError.posix(errno) }
        guard (itemStat.st_mode & S_IFMT) != S_IFLNK else { throw SecureFileMutationError.invalidPath }
        return identity(from: itemStat)
    }

    public func parentIdentity(of approvedTarget: URL, allowedRoot: URL?) throws -> SecureFileIdentity {
        let parent = try openParent(of: approvedTarget, allowedRoot: allowedRoot, createIntermediates: false)
        defer { close(parent.fd) }
        var parentStat = stat()
        guard fstat(parent.fd, &parentStat) == 0 else { throw SecureFileMutationError.posix(errno) }
        return identity(from: parentStat)
    }

    public func readFile(
        at approvedTarget: URL,
        allowedRoot: URL?,
        expectedIdentity: SecureFileIdentity? = nil,
        maxBytes: Int? = nil
    ) throws -> Data {
        let parent = try openParent(of: approvedTarget, allowedRoot: allowedRoot, createIntermediates: false)
        defer { close(parent.fd) }
        let fd = parent.leaf.withCString { openat(parent.fd, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw SecureFileMutationError.posix(errno) }
        defer { close(fd) }

        var itemStat = stat()
        guard fstat(fd, &itemStat) == 0 else { throw SecureFileMutationError.posix(errno) }
        guard (itemStat.st_mode & S_IFMT) == S_IFREG else { throw SecureFileMutationError.invalidPath }
        try requireIdentity(expectedIdentity, actual: itemStat)
        try assertPinnedDirectoryStillMatches(parent.fd, path: parent.path)

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let requested = maxBytes.map { max(0, min(buffer.count, $0 - output.count)) } ?? buffer.count
            if requested == 0 { break }
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                read(fd, rawBuffer.baseAddress, requested)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw SecureFileMutationError.posix(errno)
            }
            if count == 0 { break }
            output.append(contentsOf: buffer.prefix(count))
        }
        try assertPinnedDirectoryStillMatches(parent.fd, path: parent.path)
        return output
    }

    public func createFile(
        at approvedTarget: URL,
        data: Data,
        allowedRoot: URL?,
        createIntermediates: Bool = true,
        expectedParentIdentity: SecureFileIdentity? = nil
    ) throws {
        let parent = try openParent(
            of: approvedTarget,
            allowedRoot: allowedRoot,
            createIntermediates: createIntermediates
        )
        defer { close(parent.fd) }

        try requireIdentity(expectedParentIdentity, forDirectoryFD: parent.fd)
        try assertPinnedDirectoryStillMatches(parent.fd, path: parent.path)
        beforeFinalMutation?()
        try assertPinnedDirectoryStillMatches(parent.fd, path: parent.path)

        let flags = O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let fileFD = parent.leaf.withCString { openat(parent.fd, $0, flags, mode_t(0o600)) }
        guard fileFD >= 0 else {
            let code = errno
            if code == EEXIST { throw SecureFileMutationError.destinationExists }
            throw SecureFileMutationError.posix(code)
        }

        var committed = false
        defer {
            close(fileFD)
            if !committed {
                _ = parent.leaf.withCString { unlinkat(parent.fd, $0, 0) }
            }
        }

        try writeAll(data, to: fileFD)
        guard fsync(fileFD) == 0 else { throw SecureFileMutationError.posix(errno) }
        try verifyFileDescriptor(fileFD, equals: data)
        try assertPinnedDirectoryStillMatches(parent.fd, path: parent.path)
        committed = true
    }

    public func replaceFile(
        at approvedTarget: URL,
        data: Data,
        allowedRoot: URL?,
        expectedTargetIdentity: SecureFileIdentity? = nil
    ) throws {
        let parent = try openParent(
            of: approvedTarget,
            allowedRoot: allowedRoot,
            createIntermediates: false
        )
        defer { close(parent.fd) }

        var targetStat = stat()
        let targetStatus = parent.leaf.withCString {
            fstatat(parent.fd, $0, &targetStat, AT_SYMLINK_NOFOLLOW)
        }
        guard targetStatus == 0 else { throw SecureFileMutationError.posix(errno) }
        guard (targetStat.st_mode & S_IFMT) == S_IFREG else { throw SecureFileMutationError.invalidPath }
        try requireIdentity(expectedTargetIdentity, actual: targetStat)

        let temporaryLeaf = ".cloudcode-\(UUID().uuidString).tmp"
        let temporaryFD = temporaryLeaf.withCString {
            openat(parent.fd, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard temporaryFD >= 0 else { throw SecureFileMutationError.posix(errno) }

        var committed = false
        defer {
            close(temporaryFD)
            if !committed {
                _ = temporaryLeaf.withCString { unlinkat(parent.fd, $0, 0) }
            }
        }

        try writeAll(data, to: temporaryFD)
        guard fsync(temporaryFD) == 0 else { throw SecureFileMutationError.posix(errno) }
        try verifyFileDescriptor(temporaryFD, equals: data)
        try assertPinnedDirectoryStillMatches(parent.fd, path: parent.path)

        var currentTargetStat = stat()
        let currentTargetStatus = parent.leaf.withCString {
            fstatat(parent.fd, $0, &currentTargetStat, AT_SYMLINK_NOFOLLOW)
        }
        guard currentTargetStatus == 0 else { throw SecureFileMutationError.posix(errno) }
        guard currentTargetStat.st_dev == targetStat.st_dev,
              currentTargetStat.st_ino == targetStat.st_ino,
              (currentTargetStat.st_mode & S_IFMT) == S_IFREG else {
            throw SecureFileMutationError.verificationFailed
        }

        beforeFinalMutation?()
        try assertPinnedDirectoryStillMatches(parent.fd, path: parent.path)

        var finalTargetStat = stat()
        let finalTargetStatus = parent.leaf.withCString {
            fstatat(parent.fd, $0, &finalTargetStat, AT_SYMLINK_NOFOLLOW)
        }
        guard finalTargetStatus == 0,
              finalTargetStat.st_dev == targetStat.st_dev,
              finalTargetStat.st_ino == targetStat.st_ino,
              (finalTargetStat.st_mode & S_IFMT) == S_IFREG else {
            throw SecureFileMutationError.verificationFailed
        }

        let result = temporaryLeaf.withCString { temporaryName in
            parent.leaf.withCString { targetName in
                renameat(parent.fd, temporaryName, parent.fd, targetName)
            }
        }
        guard result == 0 else { throw SecureFileMutationError.posix(errno) }
        committed = true
        try assertPinnedDirectoryStillMatches(parent.fd, path: parent.path)
    }

    public func copyFile(
        from approvedSource: URL,
        sourceAllowedRoot: URL?,
        to approvedDestination: URL,
        destinationAllowedRoot: URL?,
        createDestinationIntermediates: Bool = true,
        expectedSourceIdentity: SecureFileIdentity? = nil,
        expectedDestinationParentIdentity: SecureFileIdentity? = nil
    ) throws {
        let sourceParent = try openParent(
            of: approvedSource,
            allowedRoot: sourceAllowedRoot,
            createIntermediates: false
        )
        defer { close(sourceParent.fd) }

        let sourceFD = sourceParent.leaf.withCString {
            openat(sourceParent.fd, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceFD >= 0 else { throw SecureFileMutationError.posix(errno) }
        defer { close(sourceFD) }

        var sourceStat = stat()
        guard fstat(sourceFD, &sourceStat) == 0 else { throw SecureFileMutationError.posix(errno) }
        guard (sourceStat.st_mode & S_IFMT) == S_IFREG else { throw SecureFileMutationError.invalidPath }
        try requireIdentity(expectedSourceIdentity, actual: sourceStat)

        let destinationParent = try openParent(
            of: approvedDestination,
            allowedRoot: destinationAllowedRoot,
            createIntermediates: createDestinationIntermediates
        )
        defer { close(destinationParent.fd) }

        try requireIdentity(expectedDestinationParentIdentity, forDirectoryFD: destinationParent.fd)
        try requireDestinationAbsent(parentFD: destinationParent.fd, leaf: destinationParent.leaf)
        try assertPinnedDirectoryStillMatches(sourceParent.fd, path: sourceParent.path)
        try assertPinnedDirectoryStillMatches(destinationParent.fd, path: destinationParent.path)
        beforeFinalMutation?()
        try assertPinnedDirectoryStillMatches(sourceParent.fd, path: sourceParent.path)
        try assertPinnedDirectoryStillMatches(destinationParent.fd, path: destinationParent.path)

        let destinationFD = destinationParent.leaf.withCString {
            openat(destinationParent.fd, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard destinationFD >= 0 else {
            let code = errno
            if code == EEXIST { throw SecureFileMutationError.destinationExists }
            throw SecureFileMutationError.posix(code)
        }

        var committed = false
        defer {
            close(destinationFD)
            if !committed {
                _ = destinationParent.leaf.withCString { unlinkat(destinationParent.fd, $0, 0) }
            }
        }

        try copyAll(from: sourceFD, to: destinationFD)
        guard fsync(destinationFD) == 0 else { throw SecureFileMutationError.posix(errno) }
        try assertPinnedDirectoryStillMatches(sourceParent.fd, path: sourceParent.path)
        try assertPinnedDirectoryStillMatches(destinationParent.fd, path: destinationParent.path)
        committed = true
    }

    public func moveItem(
        from approvedSource: URL,
        sourceAllowedRoot: URL?,
        to approvedDestination: URL,
        destinationAllowedRoot: URL?,
        createDestinationIntermediates: Bool = true,
        expectedSourceIdentity: SecureFileIdentity? = nil,
        expectedDestinationParentIdentity: SecureFileIdentity? = nil
    ) throws {
        let sourceParent = try openParent(
            of: approvedSource,
            allowedRoot: sourceAllowedRoot,
            createIntermediates: false
        )
        defer { close(sourceParent.fd) }

        var sourceStat = stat()
        let sourceStatus = sourceParent.leaf.withCString {
            fstatat(sourceParent.fd, $0, &sourceStat, AT_SYMLINK_NOFOLLOW)
        }
        guard sourceStatus == 0 else { throw SecureFileMutationError.posix(errno) }
        guard (sourceStat.st_mode & S_IFMT) != S_IFLNK else { throw SecureFileMutationError.invalidPath }
        try requireIdentity(expectedSourceIdentity, actual: sourceStat)

        let destinationParent = try openParent(
            of: approvedDestination,
            allowedRoot: destinationAllowedRoot,
            createIntermediates: createDestinationIntermediates
        )
        defer { close(destinationParent.fd) }

        try requireIdentity(expectedDestinationParentIdentity, forDirectoryFD: destinationParent.fd)
        try requireDestinationAbsent(parentFD: destinationParent.fd, leaf: destinationParent.leaf)
        try assertPinnedDirectoryStillMatches(sourceParent.fd, path: sourceParent.path)
        try assertPinnedDirectoryStillMatches(destinationParent.fd, path: destinationParent.path)
        beforeFinalMutation?()
        try assertPinnedDirectoryStillMatches(sourceParent.fd, path: sourceParent.path)
        try assertPinnedDirectoryStillMatches(destinationParent.fd, path: destinationParent.path)

        var finalSourceStat = stat()
        let finalSourceStatus = sourceParent.leaf.withCString {
            fstatat(sourceParent.fd, $0, &finalSourceStat, AT_SYMLINK_NOFOLLOW)
        }
        guard finalSourceStatus == 0,
              finalSourceStat.st_dev == sourceStat.st_dev,
              finalSourceStat.st_ino == sourceStat.st_ino,
              (finalSourceStat.st_mode & S_IFMT) == (sourceStat.st_mode & S_IFMT) else {
            throw SecureFileMutationError.verificationFailed
        }
        try requireDestinationAbsent(parentFD: destinationParent.fd, leaf: destinationParent.leaf)

        let result = sourceParent.leaf.withCString { sourceName in
            destinationParent.leaf.withCString { destinationName in
                renameat(sourceParent.fd, sourceName, destinationParent.fd, destinationName)
            }
        }
        guard result == 0 else { throw SecureFileMutationError.posix(errno) }

        do {
            try assertPinnedDirectoryStillMatches(sourceParent.fd, path: sourceParent.path)
            try assertPinnedDirectoryStillMatches(destinationParent.fd, path: destinationParent.path)
        } catch {
            let rollback = destinationParent.leaf.withCString { destinationName in
                sourceParent.leaf.withCString { sourceName in
                    renameat(destinationParent.fd, destinationName, sourceParent.fd, sourceName)
                }
            }
            guard rollback == 0 else { throw SecureFileMutationError.verificationFailed }
            throw error
        }
    }

    private struct OpenParent {
        var fd: Int32
        var leaf: String
        var path: String
    }

    private func openParent(
        of approvedTarget: URL,
        allowedRoot: URL?,
        createIntermediates: Bool
    ) throws -> OpenParent {
        let targetPath = approvedTarget.standardizedFileURL.path
        guard targetPath.hasPrefix("/"), targetPath != "/" else { throw SecureFileMutationError.invalidPath }

        let rootURL: URL
        if let allowedRoot {
            rootURL = allowedRoot.standardizedFileURL.resolvingSymlinksInPath()
        } else {
            rootURL = URL(fileURLWithPath: "/", isDirectory: true)
        }
        let rootPath = rootURL.path
        let rootPrefix = rootPath == "/" ? "/" : (rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        guard rootPath == "/" || targetPath.hasPrefix(rootPrefix) else {
            throw SecureFileMutationError.outsideAllowedRoot
        }

        let relative: String
        if rootPath == "/" {
            relative = String(targetPath.dropFirst())
        } else {
            relative = String(targetPath.dropFirst(rootPrefix.count))
        }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let leaf = components.last, validComponent(leaf) else {
            throw SecureFileMutationError.invalidPath
        }

        var directoryFD = try openAbsoluteDirectoryNoFollow(rootPath)
        var currentPath = rootPath
        do {
            for component in components.dropLast() {
                guard validComponent(component) else { throw SecureFileMutationError.invalidPath }
                let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                var nextFD = component.withCString { openat(directoryFD, $0, flags) }
                if nextFD < 0, errno == ENOENT, createIntermediates {
                    let mkdirResult = component.withCString { mkdirat(directoryFD, $0, mode_t(0o700)) }
                    if mkdirResult != 0, errno != EEXIST { throw SecureFileMutationError.posix(errno) }
                    nextFD = component.withCString { openat(directoryFD, $0, flags) }
                }
                guard nextFD >= 0 else { throw SecureFileMutationError.posix(errno) }
                close(directoryFD)
                directoryFD = nextFD
                currentPath = URL(fileURLWithPath: currentPath, isDirectory: true)
                    .appendingPathComponent(component, isDirectory: true)
                    .standardizedFileURL.path
            }
            return OpenParent(fd: directoryFD, leaf: leaf, path: currentPath)
        } catch {
            close(directoryFD)
            throw error
        }
    }

    private func openAbsoluteDirectoryNoFollow(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/") else { throw SecureFileMutationError.invalidPath }
        // The resolved allowed root is the trust anchor. Re-opening a directory path here is
        // only a read-only identity check; all actual descendant mutation still uses pinned
        // directory FDs plus openat/renameat with O_NOFOLLOW. Opening the final directory in
        // one syscall intentionally permits macOS system-level intermediate aliases such as
        // /var -> /private/var, while O_NOFOLLOW still rejects a swapped final component.
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let directoryFD = path.withCString { open($0, flags) }
        guard directoryFD >= 0 else { throw SecureFileMutationError.posix(errno) }
        return directoryFD
    }

    private func assertPinnedDirectoryStillMatches(_ pinnedFD: Int32, path: String) throws {
        var pinned = stat()
        guard fstat(pinnedFD, &pinned) == 0 else { throw SecureFileMutationError.posix(errno) }

        let currentFD = try openAbsoluteDirectoryNoFollow(path)
        defer { close(currentFD) }
        var current = stat()
        guard fstat(currentFD, &current) == 0 else { throw SecureFileMutationError.posix(errno) }
        guard pinned.st_dev == current.st_dev, pinned.st_ino == current.st_ino else {
            throw SecureFileMutationError.verificationFailed
        }
    }

    private func identity(from value: stat) -> SecureFileIdentity {
        SecureFileIdentity(
            device: UInt64(truncatingIfNeeded: value.st_dev),
            inode: UInt64(truncatingIfNeeded: value.st_ino),
            fileType: UInt32(truncatingIfNeeded: value.st_mode & S_IFMT)
        )
    }

    private func requireIdentity(_ expected: SecureFileIdentity?, actual: stat) throws {
        guard let expected else { return }
        guard identity(from: actual) == expected else { throw SecureFileMutationError.verificationFailed }
    }

    private func requireIdentity(_ expected: SecureFileIdentity?, forDirectoryFD fd: Int32) throws {
        guard let expected else { return }
        var actual = stat()
        guard fstat(fd, &actual) == 0 else { throw SecureFileMutationError.posix(errno) }
        try requireIdentity(expected, actual: actual)
    }

    private func requireDestinationAbsent(parentFD: Int32, leaf: String) throws {
        var destinationStat = stat()
        let status = leaf.withCString {
            fstatat(parentFD, $0, &destinationStat, AT_SYMLINK_NOFOLLOW)
        }
        if status == 0 { throw SecureFileMutationError.destinationExists }
        let code = errno
        if code != ENOENT { throw SecureFileMutationError.posix(code) }
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw SecureFileMutationError.posix(errno)
                }
                if count == 0 { throw SecureFileMutationError.verificationFailed }
                offset += count
            }
        }
    }

    private func copyAll(from sourceFD: Int32, to destinationFD: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let readCount = buffer.withUnsafeMutableBytes { rawBuffer in
                read(sourceFD, rawBuffer.baseAddress, rawBuffer.count)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw SecureFileMutationError.posix(errno)
            }
            if readCount == 0 { break }

            var offset = 0
            while offset < readCount {
                let writeCount = buffer.withUnsafeBytes { rawBuffer in
                    write(destinationFD, rawBuffer.baseAddress!.advanced(by: offset), readCount - offset)
                }
                if writeCount < 0 {
                    if errno == EINTR { continue }
                    throw SecureFileMutationError.posix(errno)
                }
                if writeCount == 0 { throw SecureFileMutationError.verificationFailed }
                offset += writeCount
            }
        }
    }

    private func verifyFileDescriptor(_ fd: Int32, equals expected: Data) throws {
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw SecureFileMutationError.posix(errno) }
        var actual = Data(count: expected.count)
        var bytesRead = 0
        try actual.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while bytesRead < rawBuffer.count {
                let count = read(fd, base.advanced(by: bytesRead), rawBuffer.count - bytesRead)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw SecureFileMutationError.posix(errno)
                }
                if count == 0 { break }
                bytesRead += count
            }
        }
        guard bytesRead == expected.count, actual == expected else {
            throw SecureFileMutationError.verificationFailed
        }
    }

    private func validComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && !component.contains("/")
    }
}
