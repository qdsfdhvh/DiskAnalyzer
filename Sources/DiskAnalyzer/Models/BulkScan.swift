import Darwin
import Foundation

/// Low-level wrapper around `getattrlistbulk(2)` and `getattrlist(2)`.
///
/// The higher-level Foundation path (`FileManager.contentsOfDirectory` +
/// per-URL `resourceValues`) issues one readdir per directory and then a
/// `stat`-equivalent per child, plus a pile of CFURL/CFString allocations.
/// `getattrlistbulk` asks the kernel for a packed buffer of {name, type,
/// fsid, allocated-size} records — one syscall covers tens to hundreds of
/// entries. On a ~6M-file home scan this is the single biggest lever.
enum BulkScan {

    struct Entry {
        var name: String
        var isDir: Bool
        var isSymlink: Bool
        var fsid: fsid_t
        var allocSize: Int64
    }

    // Attribute-group bitmasks. Redefined locally because the Darwin import
    // of ATTR_CMN_RETURNED_ATTRS (0x80000000) comes through as a signed Int
    // on some SDK versions, which makes `attrgroup_t(...)` casts painful.
    // These constants are stable — pulled straight from <sys/attr.h>.
    private static let A_RETURNED:       UInt32 = 0x8000_0000
    private static let A_NAME:           UInt32 = 0x0000_0001
    private static let A_FSID:           UInt32 = 0x0000_0004
    private static let A_OBJTYPE:        UInt32 = 0x0000_0008
    private static let A_FILE_ALLOCSIZE: UInt32 = 0x0000_0004

    // vnode types from <sys/vnode.h>. Hardcoded for the same import reason.
    private static let V_DIR: UInt32 = 2
    private static let V_LNK: UInt32 = 5

    // Roomy enough to hold ~500 typical entries per syscall — the fewer
    // syscalls per directory, the better. 64 KiB amortizes the round-trip
    // without risking stack pressure via withUnsafeTemporaryAllocation.
    private static let bufSize = 64 * 1024

    static func sameFSID(_ a: fsid_t, _ b: fsid_t) -> Bool {
        a.val.0 == b.val.0 && a.val.1 == b.val.1
    }

    /// `getattrlist(2)` on a single path. Used only to prime the scan's
    /// root (bulk returns children, never the dir itself). FSOPT_NOFOLLOW
    /// keeps us from silently following a symlinked root.
    static func stat(path: String) -> Entry? {
        var al = attrlist()
        al.bitmapcount = UInt16(5)           // ATTR_BIT_MAP_COUNT
        al.commonattr  = A_RETURNED | A_OBJTYPE | A_FSID
        al.fileattr    = A_FILE_ALLOCSIZE

        var out: Entry? = nil
        withUnsafeTemporaryAllocation(byteCount: 256, alignment: 8) { raw in
            let buf = raw.baseAddress!
            let rc: Int32 = path.withCString { cpath in
                getattrlist(cpath, &al, buf, 256, UInt32(0x01))  // FSOPT_NOFOLLOW
            }
            if rc != 0 { return }

            // getattrlist(2) writes a leading u_int32_t total-length prefix
            // just like getattrlistbulk. Skip it before reading returned_attrs
            // (missing this shifts every subsequent field by 4 bytes).
            var cursor = buf.advanced(by: 4)
            let returned = cursor.loadUnaligned(as: attribute_set_t.self)
            cursor = cursor.advanced(by: MemoryLayout<attribute_set_t>.size)

            var fsid = fsid_t(val: (0, 0))
            var objtype: UInt32 = 0
            var allocSize: UInt64 = 0

            // Bitmap order within commonattr: FSID (0x04) before OBJTYPE (0x08).
            if returned.commonattr & A_FSID != 0 {
                fsid = cursor.loadUnaligned(as: fsid_t.self)
                cursor = cursor.advanced(by: MemoryLayout<fsid_t>.size)
            }
            if returned.commonattr & A_OBJTYPE != 0 {
                objtype = cursor.loadUnaligned(as: UInt32.self)
                cursor = cursor.advanced(by: 4)
            }
            if returned.fileattr & A_FILE_ALLOCSIZE != 0 {
                allocSize = cursor.loadUnaligned(as: UInt64.self)
            }

            out = Entry(
                name: "",
                isDir: objtype == V_DIR,
                isSymlink: objtype == V_LNK,
                fsid: fsid,
                allocSize: Int64(bitPattern: allocSize)
            )
        }
        return out
    }

    /// Read every entry in `path` via `getattrlistbulk(2)`. Returns nil
    /// only on `open()` failure (permission denied, nonexistent). Mid-stream
    /// errors yield partial results — callers treat that the same as a full
    /// read, matching the "unreadable dir → empty node" convention.
    static func readDirectory(path: String) -> [Entry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY, 0)
        if fd < 0 { return nil }
        defer { close(fd) }
        return readEntries(fd: fd)
    }

    /// Flat walk of a package's contents, summing allocated bytes and file
    /// count. Explicit stack instead of recursion — packages often hold
    /// thousands of tiny files and we don't want the Task/actor overhead
    /// when we're discarding the tree anyway.
    static func packageTotal(path: String) -> (bytes: Int64, fileCount: Int) {
        var totalBytes: Int64 = 0
        var totalCount = 0
        var stack: [String] = [path]
        while let p = stack.popLast() {
            guard let entries = readDirectory(path: p) else { continue }
            let prefix = p.hasSuffix("/") ? p : p + "/"
            for e in entries {
                if e.isSymlink { continue }
                if e.isDir {
                    stack.append(prefix + e.name)
                } else {
                    totalBytes += e.allocSize
                    totalCount += 1
                }
            }
        }
        return (totalBytes, totalCount)
    }

    private static func readEntries(fd: Int32) -> [Entry] {
        var al = attrlist()
        al.bitmapcount = UInt16(5)
        al.commonattr  = A_RETURNED | A_NAME | A_FSID | A_OBJTYPE
        al.fileattr    = A_FILE_ALLOCSIZE

        var result: [Entry] = []

        withUnsafeTemporaryAllocation(byteCount: bufSize, alignment: 8) { raw in
            let buf = raw.baseAddress!
            while true {
                let count = getattrlistbulk(fd, &al, buf, bufSize, 0)
                // 0 = end of directory; <0 = error. Treat both as stop and
                // return whatever we already parsed.
                if count <= 0 { break }

                if result.capacity == 0 {
                    result.reserveCapacity(Int(count) * 2)
                }

                var pos = buf
                for _ in 0..<Int(count) {
                    let entryStart = pos
                    let length = Int(entryStart.loadUnaligned(as: UInt32.self))
                    let nextEntry = entryStart.advanced(by: length)
                    var cursor = entryStart.advanced(by: 4)

                    let returned = cursor.loadUnaligned(as: attribute_set_t.self)
                    cursor = cursor.advanced(by: MemoryLayout<attribute_set_t>.size)

                    var name = ""
                    var fsid = fsid_t(val: (0, 0))
                    var objtype: UInt32 = 0
                    var allocSize: UInt64 = 0

                    // Bitmap order within commonattr:
                    //   NAME (0x01), FSID (0x04), OBJTYPE (0x08)
                    if returned.commonattr & A_NAME != 0 {
                        let ref = cursor.loadUnaligned(as: attrreference_t.self)
                        let nameStart = cursor.advanced(by: Int(ref.attr_dataoffset))
                        if ref.attr_length > 1 {  // length includes trailing NUL
                            name = String(
                                cString: nameStart.assumingMemoryBound(to: CChar.self)
                            )
                        }
                        cursor = cursor.advanced(by: MemoryLayout<attrreference_t>.size)
                    }
                    if returned.commonattr & A_FSID != 0 {
                        fsid = cursor.loadUnaligned(as: fsid_t.self)
                        cursor = cursor.advanced(by: MemoryLayout<fsid_t>.size)
                    }
                    if returned.commonattr & A_OBJTYPE != 0 {
                        objtype = cursor.loadUnaligned(as: UInt32.self)
                        cursor = cursor.advanced(by: 4)
                    }
                    if returned.fileattr & A_FILE_ALLOCSIZE != 0 {
                        allocSize = cursor.loadUnaligned(as: UInt64.self)
                    }

                    if !name.isEmpty {
                        result.append(Entry(
                            name: name,
                            isDir: objtype == V_DIR,
                            isSymlink: objtype == V_LNK,
                            fsid: fsid,
                            allocSize: Int64(bitPattern: allocSize)
                        ))
                    }

                    pos = nextEntry
                }
            }
        }

        return result
    }
}
