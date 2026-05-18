import Foundation

/// On-disk store for user-authored .COM files. Lives under
/// ~/Library/Application Support/ElevatorSystem/COM/ so files round-trip
/// across launches.  TYPE, DIRECTORY, CREATE, DELETE, EDIT and @file all
/// consult this store; STARTUP.COM and a small set of sample scripts are
/// seeded on first use so the operator has something to try.
final class DCLScriptStore {
    struct FileInfo {
        let name: String        // Canonical "FOO.COM"
        let version: Int        // OpenVMS ;ver -- always 1 here
        let bytes: Int
        let modified: Date
    }

    private let root: URL

    /// Absolute path of the on-disk store, surfaced through HELP STORAGE
    /// and the MAIL/.LOG output of SUBMIT so an operator can locate the
    /// real files outside the shell (Finder, shell, backups).
    var rootPath: String { root.path }

    init() {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory,
                                   in: .userDomainMask,
                                   appropriateFor: nil,
                                   create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support
            .appendingPathComponent("ElevatorSystem", isDirectory: true)
            .appendingPathComponent("COM", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.root = dir
        seedIfNeeded()
    }

    /// Canonical filename: uppercase, with a ".COM" suffix when none given.
    func normalize(_ raw: String) -> String {
        var s = raw.uppercased()
        // Drop any leading device/directory and trailing version ";n".
        if let bracket = s.lastIndex(of: "]") {
            s = String(s[s.index(after: bracket)...])
        }
        if let colon = s.lastIndex(of: ":") {
            s = String(s[s.index(after: colon)...])
        }
        if let semi = s.firstIndex(of: ";") {
            s = String(s[..<semi])
        }
        if !s.contains(".") { s += ".COM" }
        return s
    }

    private func url(for name: String) -> URL {
        return root.appendingPathComponent(name)
    }

    func read(name: String) -> String? {
        let u = url(for: normalize(name))
        return (try? String(contentsOf: u, encoding: .utf8))
    }

    @discardableResult
    func write(name: String, body: String) -> Bool {
        let u = url(for: normalize(name))
        do {
            try body.write(to: u, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func delete(name: String) -> Bool {
        let u = url(for: normalize(name))
        do {
            try FileManager.default.removeItem(at: u)
            return true
        } catch {
            return false
        }
    }

    func exists(name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: normalize(name)).path)
    }

    func list() -> [FileInfo] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: root,
                                                   includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return entries.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return FileInfo(
                name: url.lastPathComponent.uppercased(),
                version: 1,
                bytes: values?.fileSize ?? 0,
                modified: values?.contentModificationDate ?? Date()
            )
        }
    }

    /// Seeds STARTUP.COM and two sample scripts the first time the store
    /// is created.  Subsequent launches leave whatever the operator wrote
    /// alone.
    private func seedIfNeeded() {
        seed(name: "STARTUP.COM", body: """
        $ ! ELEVATOR$ROOT:[CONTROL]STARTUP.COM
        $ ! Boot-time initialization for the elevator controller cluster
        $ SET NOON
        $ DEFINE/SYSTEM ELEVATOR$ROOT  DISK$ELEV_SYS:[ELEVATOR]
        $ DEFINE/SYSTEM CAB$DATA       DISK$ELEV_DATA:[CABS]
        $ DEFINE/SYSTEM DOOR$STATE     DISK$ELEV_DOORS:[STATE]
        $ INSTALL ADD ELEVATOR$ROOT:[CONTROL]LPDCP.EXE   /OPEN/SHARED
        $ INSTALL ADD ELEVATOR$ROOT:[CONTROL]CONTROL.EXE /OPEN/SHARED
        $ EXIT
        """)
        seed(name: "LOGIN.COM", body: """
        $ ! SYS$LOGIN:LOGIN.COM -- per-user logon
        $ ! Defines the LPD layered-product foreign-command aliases so a
        $ ! site engineer can type short forms instead of LPDCP <verb> <noun>.
        $ ! Run automatically by the shell after the LPD splash.
        $ SET NOON
        $ LPDCP   == "$SYS$SYSTEM:LPDCP.EXE"
        $ CAB     == "LPDCP SHOW CAB"
        $ BLDG    == "LPDCP SHOW BUILDING"
        $ DPATCH  == "LPDCP SHOW DISPATCH"
        $ CALLS   == "LPDCP SHOW CALLS"
        $ LOAD    == "LPDCP SHOW LOAD"
        $ FIRE    == "LPDCP SET BUILDING /FIRE_RECALL=ON"
        $ NORMAL  == "LPDCP SET BUILDING /NORMAL"
        $ WRITE SYS$OUTPUT "LPD-CP aliases loaded:  CAB BLDG DPATCH CALLS LOAD FIRE NORMAL"
        $ EXIT
        """)
        seed(name: "HELLO.COM", body: """
        $ ! HELLO.COM -- demonstrates symbols, IF/THEN and GOTO
        $ WRITE SYS$OUTPUT "Hello from DCL scripting!"
        $ COUNT = 1
        $LOOP:
        $   IF COUNT .GT. 3 THEN GOTO DONE
        $   WRITE SYS$OUTPUT "  Iteration ''COUNT'"
        $   COUNT = COUNT + 1
        $   GOTO LOOP
        $DONE:
        $ WRITE SYS$OUTPUT "Done. F$TIME() is now ''F$TIME()'"
        $ EXIT
        """)
        seed(name: "DEMO.COM", body: """
        $ ! DEMO.COM -- drive cab L01 through a short test cycle.
        $ ! Cab state changes go through LPDCP (the layered control
        $ ! program); CALL / OPEN / CLOSE remain bare operator verbs.
        $ WRITE SYS$OUTPUT "Putting cab 01 into manual control..."
        $ LPDCP SET CAB 01 /MANUAL
        $ CALL CAB 01 FLOOR 5
        $ WAIT 00:00:02
        $ OPEN CAB 01
        $ WAIT 00:00:02
        $ CLOSE CAB 01
        $ LPDCP SET CAB 01 /AUTOMATIC
        $ WRITE SYS$OUTPUT "Returned cab 01 to auto-dispatch."
        $ EXIT
        """)
    }

    private func seed(name: String, body: String) {
        let u = url(for: name)
        if !FileManager.default.fileExists(atPath: u.path) {
            try? body.write(to: u, atomically: true, encoding: .utf8)
        }
    }
}
