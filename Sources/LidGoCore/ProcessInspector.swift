import Darwin

public protocol ProcessInspecting: Sendable {
    func snapshot(pid: Int32) -> ProcessSnapshot?
}

public struct DarwinProcessInspector: ProcessInspecting {
    public init() {}

    public func snapshot(pid: Int32) -> ProcessSnapshot? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard actualSize == expectedSize else { return nil }

        let seconds = UInt64(info.pbi_start_tvsec)
        let microseconds = UInt64(info.pbi_start_tvusec)
        let (scaledSeconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000)
        guard !overflow else { return nil }

        return ProcessSnapshot(
            pid: pid,
            startTime: scaledSeconds &+ microseconds,
            status: status(from: info.pbi_status)
        )
    }

    private func status(from rawStatus: UInt32) -> ProcessStatus {
        switch rawStatus {
        case UInt32(SRUN):
            return .running
        case UInt32(SSLEEP):
            return .sleeping
        case UInt32(SSTOP):
            return .stopped
        case UInt32(SZOMB):
            return .zombie
        default:
            return .unknown
        }
    }
}
