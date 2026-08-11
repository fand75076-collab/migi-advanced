import Dispatch
import Foundation

public enum CodexActivity: String, Codable, CaseIterable, Hashable, Sendable {
    case idle
    case thinking
    case tool
    case waiting
    case review
    case failed
}

/// A conservative, animation-oriented hint about what a tool is doing.
///
/// `.write` is reserved for tools that explicitly edit or apply changes.
/// Generic shell execution remains `.none` unless its command is unmistakably
/// read-only, so Migi never presents a destructive action that Codex did not
/// actually announce.
public enum CodexToolActionHint: String, Codable, Equatable, Sendable {
    case none
    case read
    case write
}

/// Separates an ordinary software failure from an explicit safety threat.
///
/// The monitor deliberately defaults to `.routine`: missing or ambiguous
/// metadata must never make Migi expose the defensive blade.
public enum CodexFailureDisposition: String, Codable, Equatable, Sendable {
    case none
    case routine
    case interrupted
    case credibleThreat
}

/// A restrained, persistent description of Migi's coexistence with the user.
///
/// Stages are earned from both actual foreground cooperation and a diverse set
/// of familiar tools. Merely leaving the app open cannot advance the bond.
public enum MigiRelationshipStage: Int, Codable, CaseIterable, Sendable {
    case cautious
    case cooperative
    case protective
}

public struct MigiRelationshipProfile: Codable, Equatable, Sendable {
    public var cooperationDuration: TimeInterval
    public var familiarToolCount: Int

    public var stage: MigiRelationshipStage {
        if cooperationDuration >= 12 * 60 * 60, familiarToolCount >= 10 {
            return .protective
        }
        if cooperationDuration >= 30 * 60, familiarToolCount >= 3 {
            return .cooperative
        }
        return .cautious
    }

    public init(
        cooperationDuration: TimeInterval = 0,
        familiarToolCount: Int = 0
    ) {
        self.cooperationDuration = max(
            cooperationDuration.isFinite ? cooperationDuration : 0,
            0
        )
        self.familiarToolCount = max(familiarToolCount, 0)
    }
}

public enum MonitoredAgent: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case grok
    case zcode
}

public enum AgentMonitoringMode: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case grok
    case zcode
    case all
}

/// A newly observed, stable tool identity.
///
/// This signal is deliberately independent from the activity winner. A tool
/// can be discovered while another agent's higher-priority failure or review
/// state remains the visible activity.
public struct ToolNoveltyEvent: Equatable, Sendable {
    public let sequence: UInt64
    public let agent: MonitoredAgent
    public let canonicalName: String
    public let observedAt: Date
    public let sourcePath: String
    public let toolActionHint: CodexToolActionHint

    public init(
        sequence: UInt64,
        agent: MonitoredAgent,
        canonicalName: String,
        observedAt: Date,
        sourcePath: String,
        toolActionHint: CodexToolActionHint
    ) {
        self.sequence = sequence
        self.agent = agent
        self.canonicalName = canonicalName
        self.observedAt = observedAt
        self.sourcePath = sourcePath
        self.toolActionHint = toolActionHint
    }
}

public struct CodexActivitySnapshot: Sendable {
    public var activity: CodexActivity
    public var detail: String
    public var observedAt: Date
    public var sourcePath: String?
    public var toolActionHint: CodexToolActionHint
    public var sourceAgent: MonitoredAgent?
    /// Identifies the monitoring-mode epoch that produced this snapshot.
    ///
    /// AppKit callbacks are delivered asynchronously. A mode change increments
    /// this value so a callback already queued for the previous source set can
    /// never update the new mode's UI.
    public var monitoringGeneration: UInt64
    public var latestNovelTool: ToolNoveltyEvent?
    public var activeAgents: Set<MonitoredAgent>
    public var failureDisposition: CodexFailureDisposition
    public var relationshipProfile: MigiRelationshipProfile
    /// Most recent user-visible Agent reply that is still inside its display
    /// lifetime. This is independent of the activity winner in all-Agent mode.
    public var spokenText: String?
    public var spokenAgent: MonitoredAgent?
    /// Changes for each accepted utterance, including an identical reply in a
    /// later turn. The UI uses it to restart presentation without replaying
    /// duplicate JSONL representations of the same message.
    public var spokenRevision: UInt64?

    public init(
        activity: CodexActivity,
        detail: String,
        observedAt: Date,
        sourcePath: String?,
        toolActionHint: CodexToolActionHint = .none,
        sourceAgent: MonitoredAgent? = nil,
        monitoringGeneration: UInt64 = 0,
        latestNovelTool: ToolNoveltyEvent? = nil,
        activeAgents: Set<MonitoredAgent> = [],
        failureDisposition: CodexFailureDisposition = .none,
        relationshipProfile: MigiRelationshipProfile = .init(),
        spokenText: String? = nil,
        spokenAgent: MonitoredAgent? = nil,
        spokenRevision: UInt64? = nil
    ) {
        self.activity = activity
        self.detail = detail
        self.observedAt = observedAt
        self.sourcePath = sourcePath
        self.toolActionHint = toolActionHint
        self.sourceAgent = sourceAgent
        self.monitoringGeneration = monitoringGeneration
        self.latestNovelTool = latestNovelTool
        self.activeAgents = activeAgents
        self.failureDisposition = failureDisposition
        self.relationshipProfile = relationshipProfile
        self.spokenText = spokenText
        self.spokenAgent = spokenAgent
        self.spokenRevision = spokenRevision
    }
}

/// Observes Codex rollout JSONL files without changing Codex configuration.
///
/// The desktop app writes task, reasoning, and tool events to
/// `~/.codex/sessions/**/rollout-*.jsonl`. This monitor tails a small set of the
/// most recently modified rollouts on a private queue and converts those events
/// into stable, animation-friendly activity states.
public final class CodexStateMonitor: @unchecked Sendable {
    public var onChange: ((CodexActivitySnapshot) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return callback
        }
        set {
            callbackLock.lock()
            callback = newValue
            callbackLock.unlock()
        }
    }

    private struct CandidateFile {
        let agent: MonitoredAgent
        let url: URL
        let modificationDate: Date
        let size: UInt64
        let fileIdentifier: UInt64?
    }

    private struct SourceKey: Hashable {
        let agent: MonitoredAgent
        let path: String
    }

    private struct ToolIdentity: Codable, Hashable {
        let agent: MonitoredAgent
        let canonicalName: String
    }

    private struct Evidence {
        let activity: CodexActivity
        let detail: String
        let observedAt: Date
        let sourcePath: String
        let toolActionHint: CodexToolActionHint
        let sourceAgent: MonitoredAgent
        let failureDisposition: CodexFailureDisposition
    }

    private struct PersistedRelationshipState: Codable {
        static let currentVersion = 1

        var version = currentVersion
        var cooperationDuration: TimeInterval = 0
        var knownTools: Set<ToolIdentity> = []
        var updatedAt: Date?
    }

    private struct OpenCall {
        let activity: CodexActivity
        let detail: String
        let startedAt: Date
        let toolActionHint: CodexToolActionHint
    }

    private struct ActiveTurn {
        let identifier: String?
        let startedAt: Date
    }

    private enum SpokenKind: Int {
        case commentary = 0
        case answer = 1
    }

    private struct SpokenMessage {
        let turnIdentifier: String?
        var kind: SpokenKind
        var text: String
        var updatedAt: Date
        var completedAt: Date?
        var originPriority: Int
        var revision: UInt64
    }

    private struct SourceRuntime {
        var offset: UInt64 = 0
        var isInitialized = false
        var hasCompletedInitialCatchUp = false
        var isDroppingPartialLine = false
        var remainder = Data()
        var modificationDate = Date.distantPast
        var fileIdentifier: UInt64?
        var latestEventAt = Date.distantPast
        var activeTurn: ActiveTurn?
        var spokenMessage: SpokenMessage?
        var openCalls: [String: OpenCall] = [:]
        var evidence: [CodexActivity: Evidence] = [:]

        mutating func resetParserState() {
            offset = 0
            isInitialized = false
            isDroppingPartialLine = false
            remainder.removeAll(keepingCapacity: false)
            fileIdentifier = nil
            activeTurn = nil
            spokenMessage = nil
            openCalls.removeAll(keepingCapacity: true)
            evidence.removeAll(keepingCapacity: true)
            latestEventAt = .distantPast
        }
    }

    private enum NoveltyEmissionPolicy {
        case suppress
        case live
        case since(Date)
    }

    private struct RolloutRecord {
        let timestamp: Date
        let envelopeType: String
        let payloadType: String
        let payload: [String: Any]
    }

    private let homeDirectory: URL
    private let relationshipStateURL: URL
    private let workerQueue = DispatchQueue(
        label: "com.migi-advanced.codex-state-monitor",
        qos: .utility
    )
    private let callbackLock = NSLock()
    private let stateLock = NSRecursiveLock()
    private let fractionalTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let wholeSecondsTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private var callback: ((CodexActivitySnapshot) -> Void)?
    private var timer: DispatchSourceTimer?
    private var monitoringMode: AgentMonitoringMode = .codex
    private var monitoringGeneration: UInt64 = 0
    private var candidateFiles: [MonitoredAgent: [CandidateFile]] = [:]
    private var sources: [SourceKey: SourceRuntime] = [:]
    private var lastDiscoveryAt: [MonitoredAgent: Date] = [:]
    private var lastDelivered: CodexActivitySnapshot?
    private var seenTools: Set<ToolIdentity> = []
    private var latestNovelTool: ToolNoveltyEvent?
    private var noveltySequence: UInt64 = 0
    private var spokenRevisionSequence: UInt64 = 0
    private var epochBaselineSources: Set<SourceKey>?
    private var epochNoveltyCutoff: Date?
    private var relationshipState: PersistedRelationshipState
    private var relationshipLastSampleAt: Date?
    private var relationshipWasCooperating = false
    private var relationshipStateIsDirty = false
    private var relationshipNeedsImmediateSave = false
    private var relationshipLastSavedAt = Date.distantPast

    private let pollInterval: TimeInterval = 0.8
    private let discoveryInterval: TimeInterval = 2.0
    private let maximumCandidateCount = 12
    private let maximumReadSize: UInt64 = 1_048_576
    private let maximumLineSize = 4_194_304
    private let noveltyLifetime: TimeInterval = 12
    static let maximumSpokenTextCharacters = 4_096
    private let completedSpeechLifetime: TimeInterval = 6
    private let streamingSpeechLifetime: TimeInterval = 8

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        relationshipStateURL = self.homeDirectory
            .appendingPathComponent(".codex/migi-advanced", isDirectory: true)
            .appendingPathComponent("relationship-v1.json")
        let restored = Self.loadRelationshipState(from: relationshipStateURL)
        relationshipState = restored
        seenTools = restored.knownTools
    }

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
    }

    public func start() {
        workerQueue.async { [weak self] in
            guard let self, self.timer == nil else { return }

            let timer = DispatchSource.makeTimerSource(queue: self.workerQueue)
            timer.schedule(
                deadline: .now(),
                repeating: self.pollInterval,
                leeway: .milliseconds(120)
            )
            timer.setEventHandler { [weak self] in
                self?.performPoll()
            }
            self.timer = timer
            timer.resume()
        }
    }

    public func stop() {
        workerQueue.async { [weak self] in
            guard let self, let timer = self.timer else { return }
            timer.setEventHandler {}
            timer.cancel()
            self.timer = nil
        }
    }

    public func pollNow() {
        workerQueue.async { [weak self] in
            self?.performPoll()
        }
    }

    /// Changes the monitored source set atomically. The next poll starts from
    /// fresh candidates and parser state, so evidence from a disabled agent can
    /// never leak into the newly selected mode.
    @discardableResult
    public func setMonitoringMode(_ mode: AgentMonitoringMode) -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }

        monitoringMode = mode
        monitoringGeneration &+= 1
        candidateFiles.removeAll(keepingCapacity: true)
        sources.removeAll(keepingCapacity: true)
        lastDiscoveryAt.removeAll(keepingCapacity: true)
        lastDelivered = nil
        latestNovelTool = nil
        epochBaselineSources = nil
        epochNoveltyCutoff = nil
        return monitoringGeneration
    }

    /// Deterministic entry point for fixture tests. Production callers should
    /// use `start()` or `pollNow()` so parsing stays off the main thread.
    @discardableResult
    internal func pollSynchronously(now: Date = Date()) -> CodexActivitySnapshot {
        performPoll(now: now)
    }

    @discardableResult
    private func performPoll(now: Date = Date()) -> CodexActivitySnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }

        let agents = monitoredAgents(for: monitoringMode)
        for agent in agents {
            let existing = candidateFiles[agent] ?? []
            if let lastDiscovery = lastDiscoveryAt[agent],
               now.timeIntervalSince(lastDiscovery) < discoveryInterval
            {
                // Recursive discovery is deliberately infrequent, but each
                // source's selected rollouts are cheap to stat every 0.8 s.
                candidateFiles[agent] = refreshCandidateFiles(existing)
            } else {
                candidateFiles[agent] = discoverCandidateFiles(for: agent)
                lastDiscoveryAt[agent] = now
            }
        }

        if epochBaselineSources == nil {
            epochBaselineSources = Set(
                agents.flatMap { agent in
                    (candidateFiles[agent] ?? []).map {
                        SourceKey(agent: agent, path: $0.url.path)
                    }
                }
            )
            epochNoveltyCutoff = now
        }

        for agent in agents {
            for candidate in candidateFiles[agent] ?? [] {
                ingest(candidate, now: now)
            }
        }

        pruneSources(now: now)
        var snapshot = makeSnapshot(now: now)
        updateRelationshipState(for: snapshot, now: now)
        snapshot.relationshipProfile = relationshipProfile
        persistRelationshipStateIfNeeded(now: now)
        deliverIfChanged(snapshot)
        return snapshot
    }

    private static func loadRelationshipState(
        from url: URL
    ) -> PersistedRelationshipState {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(
                  PersistedRelationshipState.self,
                  from: data
              ),
              decoded.version == PersistedRelationshipState.currentVersion
        else {
            return PersistedRelationshipState()
        }

        var sanitized = decoded
        sanitized.cooperationDuration = max(
            decoded.cooperationDuration.isFinite
                ? decoded.cooperationDuration
                : 0,
            0
        )
        sanitized.knownTools = Set(
            decoded.knownTools.filter {
                !$0.canonicalName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            }
        )
        return sanitized
    }

    private var relationshipProfile: MigiRelationshipProfile {
        MigiRelationshipProfile(
            cooperationDuration: relationshipState.cooperationDuration,
            familiarToolCount: seenTools.count
        )
    }

    private func updateRelationshipState(
        for snapshot: CodexActivitySnapshot,
        now: Date
    ) {
        if let previousSample = relationshipLastSampleAt {
            let elapsed = now.timeIntervalSince(previousSample)
            // Do not count time while the app was suspended or the machine was
            // asleep. Regular 0.8-second monitor samples remain fully counted.
            let boundedElapsed = min(max(elapsed, 0), pollInterval * 2)
            if relationshipWasCooperating, boundedElapsed > 0 {
                relationshipState.cooperationDuration += boundedElapsed
                relationshipStateIsDirty = true
            }
        }

        relationshipLastSampleAt = now
        relationshipWasCooperating = snapshot.activity.isCooperativeWork
            && snapshot.sourcePath != nil
    }

    private func persistRelationshipStateIfNeeded(
        now: Date,
        force: Bool = false
    ) {
        guard relationshipStateIsDirty else { return }
        let saveInterval: TimeInterval = 10
        guard force
                || relationshipNeedsImmediateSave
                || now.timeIntervalSince(relationshipLastSavedAt) >= saveInterval
        else {
            return
        }

        relationshipState.version = PersistedRelationshipState.currentVersion
        relationshipState.knownTools = seenTools
        relationshipState.updatedAt = now

        do {
            try FileManager.default.createDirectory(
                at: relationshipStateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(relationshipState).write(
                to: relationshipStateURL,
                options: .atomic
            )
            relationshipStateIsDirty = false
            relationshipNeedsImmediateSave = false
            relationshipLastSavedAt = now
        } catch {
            // Monitoring must remain read-safe and animation-capable even when
            // persistence is unavailable. A later poll will retry.
        }
    }

    private func monitoredAgents(for mode: AgentMonitoringMode) -> [MonitoredAgent] {
        switch mode {
        case .codex:
            return [.codex]
        case .grok:
            return [.grok]
        case .zcode:
            return [.zcode]
        case .all:
            return [.codex, .grok, .zcode]
        }
    }

    private func sourceDirectory(for agent: MonitoredAgent) -> URL {
        switch agent {
        case .codex:
            return homeDirectory
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        case .grok:
            return homeDirectory
                .appendingPathComponent(".grok", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        case .zcode:
            return homeDirectory
                .appendingPathComponent(".zcode", isDirectory: true)
                .appendingPathComponent("cli", isDirectory: true)
                .appendingPathComponent("rollout", isDirectory: true)
        }
    }

    private func matchesSourceFile(_ url: URL, agent: MonitoredAgent) -> Bool {
        guard url.pathExtension == "jsonl" else { return false }
        switch agent {
        case .codex:
            return url.lastPathComponent.hasPrefix("rollout-")
        case .grok:
            return url.lastPathComponent == "updates.jsonl"
        case .zcode:
            return url.lastPathComponent.hasPrefix("model-io-")
        }
    }

    private func discoverCandidateFiles(for agent: MonitoredAgent) -> [CandidateFile] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: sourceDirectory(for: agent),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var discovered: [CandidateFile] = []
        for case let url as URL in enumerator {
            guard matchesSourceFile(url, agent: agent),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let candidate = candidateMetadata(for: url, agent: agent)
            else {
                continue
            }

            discovered.append(candidate)
        }

        return sortedCandidates(discovered)
    }

    private func refreshCandidateFiles(_ candidates: [CandidateFile]) -> [CandidateFile] {
        sortedCandidates(
            candidates.compactMap {
                candidateMetadata(for: $0.url, agent: $0.agent)
            }
        )
    }

    private func candidateMetadata(
        for url: URL,
        agent: MonitoredAgent
    ) -> CandidateFile? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let modificationDate = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.uint64Value
        else {
            return nil
        }

        return CandidateFile(
            agent: agent,
            url: url.standardizedFileURL,
            modificationDate: modificationDate,
            size: size,
            fileIdentifier: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private func sortedCandidates(_ candidates: [CandidateFile]) -> [CandidateFile] {
        Array(
            candidates
                .sorted { lhs, rhs in
                    if lhs.modificationDate == rhs.modificationDate {
                        return lhs.url.path < rhs.url.path
                    }
                    return lhs.modificationDate > rhs.modificationDate
                }
                .prefix(maximumCandidateCount)
        )
    }

    private func ingest(_ candidate: CandidateFile, now: Date) {
        let path = candidate.url.path
        let sourceKey = SourceKey(agent: candidate.agent, path: path)
        var runtime = sources[sourceKey] ?? SourceRuntime()

        let wasReplaced = runtime.isInitialized
            && runtime.fileIdentifier != nil
            && candidate.fileIdentifier != nil
            && runtime.fileIdentifier != candidate.fileIdentifier
        if runtime.isInitialized,
           wasReplaced
            || candidate.size < runtime.offset
            || (
                candidate.size == runtime.offset
                    && candidate.modificationDate > runtime.modificationDate
            )
        {
            // Truncation and same-length replacement both start a fresh JSONL
            // stream. The latter also covers atomic rollout rotation.
            runtime.resetParserState()
        }

        let isPendingEpochBaseline =
            !runtime.hasCompletedInitialCatchUp
            && epochBaselineSources?.contains(sourceKey) == true
        if runtime.isInitialized, candidate.size == runtime.offset {
            runtime.hasCompletedInitialCatchUp = true
            epochBaselineSources?.remove(sourceKey)
            runtime.modificationDate = candidate.modificationDate
            runtime.fileIdentifier = candidate.fileIdentifier
            sources[sourceKey] = runtime
            return
        }

        let isInitialRead = !runtime.isInitialized
        let noveltyPolicy: NoveltyEmissionPolicy
        if !runtime.hasCompletedInitialCatchUp {
            if isPendingEpochBaseline {
                noveltyPolicy = .suppress
            } else {
                noveltyPolicy = .since(recentNoveltyCutoff(now: now))
            }
        } else if isInitialRead {
            // A path that was already caught up can become initial again after
            // truncation or atomic replacement. Treat its fresh records as live,
            // but never replay old records copied into the replacement.
            noveltyPolicy = .since(recentNoveltyCutoff(now: now))
        } else {
            noveltyPolicy = .live
        }
        var startOffset = runtime.offset
        var mustDropPartialLine = runtime.isDroppingPartialLine

        if isInitialRead {
            startOffset = candidate.size > maximumReadSize
                ? candidate.size - maximumReadSize
                : 0
            mustDropPartialLine = startOffset > 0
        }

        guard let handle = try? FileHandle(forReadingFrom: candidate.url) else {
            runtime.modificationDate = candidate.modificationDate
            sources[sourceKey] = runtime
            return
        }

        defer {
            try? handle.close()
        }

        do {
            try handle.seek(toOffset: startOffset)
            runtime.offset = startOffset
            runtime.isInitialized = true
            runtime.modificationDate = candidate.modificationDate
            runtime.fileIdentifier = candidate.fileIdentifier

            // Catch up from the exact previous offset in bounded chunks. A
            // burst larger than 1 MiB must not erase open calls, the active
            // turn, evidence, or a JSON line split across chunk boundaries.
            while let chunk = try handle.read(upToCount: Int(maximumReadSize)),
                  !chunk.isEmpty
            {
                runtime.offset += UInt64(chunk.count)
                var incoming = chunk

                if mustDropPartialLine {
                    if let newline = incoming.firstIndex(of: 0x0A) {
                        incoming.removeSubrange(incoming.startIndex...newline)
                        mustDropPartialLine = false
                        runtime.isDroppingPartialLine = false
                    } else {
                        runtime.isDroppingPartialLine = true
                        runtime.remainder.removeAll(keepingCapacity: false)
                        continue
                    }
                }

                var combined = runtime.remainder
                combined.append(incoming)
                let lines = completeLines(in: combined, remainder: &runtime.remainder)

                for line in lines {
                    // One record can contain arbitrarily large model/tool output.
                    // It is not worth retaining or decoding once it crosses the
                    // line budget; later records still carry the live state.
                    guard line.count <= maximumLineSize else { continue }
                    apply(
                        line,
                        from: candidate.agent,
                        sourcePath: path,
                        noveltyPolicy: noveltyPolicy,
                        runtime: &runtime
                    )
                }

                if runtime.remainder.count > maximumLineSize {
                    // Drop only this oversized record until its newline. Parser
                    // evidence, the active turn, and open calls remain intact.
                    runtime.remainder.removeAll(keepingCapacity: false)
                    runtime.isDroppingPartialLine = true
                    mustDropPartialLine = true
                }
            }
            runtime.hasCompletedInitialCatchUp = true
            epochBaselineSources?.remove(sourceKey)
        } catch {
            // A temporarily unavailable or concurrently rotated rollout is
            // retried on the next poll; monitoring must never block the UI.
        }

        sources[sourceKey] = runtime
    }

    private func recentNoveltyCutoff(now: Date) -> Date {
        max(
            epochNoveltyCutoff ?? now,
            now.addingTimeInterval(-noveltyLifetime)
        )
    }

    private func completeLines(in data: Data, remainder: inout Data) -> [Data] {
        guard !data.isEmpty else {
            remainder.removeAll(keepingCapacity: true)
            return []
        }

        var lines: [Data] = []
        var lineStart = data.startIndex
        var cursor = data.startIndex

        while cursor < data.endIndex {
            if data[cursor] == 0x0A {
                if lineStart < cursor {
                    lines.append(data.subdata(in: lineStart..<cursor))
                }
                lineStart = data.index(after: cursor)
            }
            cursor = data.index(after: cursor)
        }

        if lineStart < data.endIndex {
            remainder = data.subdata(in: lineStart..<data.endIndex)
        } else {
            remainder.removeAll(keepingCapacity: true)
        }

        return lines
    }

    private func apply(
        _ line: Data,
        from agent: MonitoredAgent,
        sourcePath: String,
        noveltyPolicy: NoveltyEmissionPolicy,
        runtime: inout SourceRuntime
    ) {
        switch agent {
        case .codex:
            guard let record = decodeRecord(line) else { return }
            apply(
                record,
                sourcePath: sourcePath,
                noveltyPolicy: noveltyPolicy,
                runtime: &runtime
            )
        case .grok:
            applyGrokRecord(
                line,
                sourcePath: sourcePath,
                noveltyPolicy: noveltyPolicy,
                runtime: &runtime
            )
        case .zcode:
            applyZCodeRecord(
                line,
                sourcePath: sourcePath,
                noveltyPolicy: noveltyPolicy,
                runtime: &runtime
            )
        }
    }

    private func applyGrokRecord(
        _ data: Data,
        sourcePath: String,
        noveltyPolicy: NoveltyEmissionPolicy,
        runtime: inout SourceRuntime
    ) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestampNumber = envelope["timestamp"] as? NSNumber,
              let params = envelope["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              let updateType = (update["sessionUpdate"] as? String)?.lowercased()
        else {
            return
        }

        var seconds = timestampNumber.doubleValue
        if seconds > 10_000_000_000 {
            seconds /= 1_000
        }
        let timestamp = Date(timeIntervalSince1970: seconds)
        runtime.latestEventAt = max(runtime.latestEventAt, timestamp)

        let status = (update["status"] as? String)?.lowercased() ?? ""
        if updateType == "tool_call" || updateType == "tool_call_update" {
            let metadata = update["_meta"] as? [String: Any]
            let toolMetadata = metadata?["x.ai/tool"] as? [String: Any]
            if let stableName = toolMetadata?["name"] as? String {
                let kind = (update["kind"] as? String)
                    ?? (toolMetadata?["kind"] as? String)
                    ?? ""
                observeTool(
                    named: stableName,
                    agent: .grok,
                    at: timestamp,
                    sourcePath: sourcePath,
                    toolActionHint: grokActionHint(kind: kind, name: stableName),
                    noveltyPolicy: noveltyPolicy
                )
            }
        }

        if ["failed", "failure", "error", "errored"].contains(status) {
            runtime.activeTurn = nil
            runtime.spokenMessage = nil
            runtime.openCalls.removeAll(keepingCapacity: true)
            remember(
                .failed,
                detail: "Grok tool failed",
                at: timestamp,
                sourcePath: sourcePath,
                failureDisposition: .routine,
                sourceAgent: .grok,
                runtime: &runtime
            )
            return
        }

        switch updateType {
        case "user_message_chunk":
            if runtime.activeTurn == nil || runtime.spokenMessage?.kind == .answer {
                runtime.activeTurn = ActiveTurn(
                    identifier: grokTurnIdentifier(params: params, update: update),
                    startedAt: timestamp
                )
                runtime.spokenMessage = nil
            }
            remember(
                .thinking,
                detail: "Grok is working",
                at: timestamp,
                sourcePath: sourcePath,
                sourceAgent: .grok,
                runtime: &runtime
            )

        case "agent_thought_chunk":
            if runtime.activeTurn == nil {
                runtime.activeTurn = ActiveTurn(
                    identifier: grokTurnIdentifier(params: params, update: update),
                    startedAt: timestamp
                )
                runtime.spokenMessage = nil
            }
            remember(
                .thinking,
                detail: "Grok is thinking",
                at: timestamp,
                sourcePath: sourcePath,
                sourceAgent: .grok,
                runtime: &runtime
            )

        case "agent_message_chunk":
            if runtime.activeTurn == nil {
                runtime.activeTurn = ActiveTurn(
                    identifier: grokTurnIdentifier(params: params, update: update),
                    startedAt: timestamp
                )
                runtime.spokenMessage = nil
            }
            if let content = update["content"] as? [String: Any],
               let text = content["text"] as? String,
               !text.isEmpty
            {
                appendSpokenText(
                    text,
                    turnIdentifier: runtime.activeTurn?.identifier,
                    at: timestamp,
                    runtime: &runtime
                )
            }
            remember(
                .thinking,
                detail: "Grok is responding",
                at: timestamp,
                sourcePath: sourcePath,
                sourceAgent: .grok,
                runtime: &runtime
            )

        case "tool_call", "tool_call_update":
            applyGrokToolEvent(
                update,
                updateType: updateType,
                at: timestamp,
                sourcePath: sourcePath,
                noveltyPolicy: noveltyPolicy,
                runtime: &runtime
            )

        case "turn_completed":
            markSpokenMessageCompleted(at: timestamp, runtime: &runtime)
            runtime.activeTurn = nil
            runtime.openCalls.removeAll(keepingCapacity: true)
            remember(
                .review,
                detail: "Reviewing Grok's result",
                at: timestamp,
                sourcePath: sourcePath,
                sourceAgent: .grok,
                runtime: &runtime
            )

        default:
            break
        }
    }

    private func grokTurnIdentifier(
        params: [String: Any],
        update: [String: Any]
    ) -> String? {
        let paramsMetadata = params["_meta"] as? [String: Any]
        let updateMetadata = update["_meta"] as? [String: Any]
        return (paramsMetadata?["promptId"] as? String)
            ?? (updateMetadata?["promptId"] as? String)
            ?? (update["prompt_id"] as? String)
            ?? (params["sessionId"] as? String)
    }

    private func applyGrokToolEvent(
        _ update: [String: Any],
        updateType: String,
        at timestamp: Date,
        sourcePath: String,
        noveltyPolicy: NoveltyEmissionPolicy,
        runtime: inout SourceRuntime
    ) {
        let callID = update["toolCallId"] as? String
        let status = (update["status"] as? String)?.lowercased() ?? ""
        let metadata = update["_meta"] as? [String: Any]
        let toolMetadata = metadata?["x.ai/tool"] as? [String: Any]
        let name = (toolMetadata?["name"] as? String)
            ?? (update["title"] as? String)
            ?? "tool"
        let kind = (update["kind"] as? String)
            ?? (toolMetadata?["kind"] as? String)
            ?? ""
        let previous = callID.flatMap { runtime.openCalls[$0] }
        var actionHint = grokActionHint(kind: kind, name: name)
        if actionHint == .none, let previous {
            actionHint = previous.toolActionHint
        }
        let detail = previous?.detail ?? "Grok: \(String(name.prefix(48)))"

        // Titles describe a particular invocation and can contain paths or
        // user text. Only x.ai's stable metadata name is a tool identity.
        if let stableName = toolMetadata?["name"] as? String {
            observeTool(
                named: stableName,
                agent: .grok,
                at: timestamp,
                sourcePath: sourcePath,
                toolActionHint: actionHint,
                noveltyPolicy: noveltyPolicy
            )
        }

        if let callID,
           status != "completed",
           status != "failed",
           status != "error"
        {
            runtime.openCalls[callID] = OpenCall(
                activity: .tool,
                detail: detail,
                startedAt: timestamp,
                toolActionHint: actionHint
            )
        } else if let callID {
            runtime.openCalls.removeValue(forKey: callID)
        }

        remember(
            .tool,
            detail: detail,
            at: timestamp,
            sourcePath: sourcePath,
            toolActionHint: actionHint,
            sourceAgent: .grok,
            runtime: &runtime
        )
    }

    private func grokActionHint(
        kind rawKind: String,
        name rawName: String
    ) -> CodexToolActionHint {
        let kind = rawKind.lowercased()
        if kind.contains("execute") {
            return .none
        }

        let descriptor = "\(kind) \(rawName.lowercased())"
        if descriptor.contains("write")
            || descriptor.contains("edit")
            || descriptor.contains("apply")
        {
            return .write
        }
        if descriptor.contains("read")
            || descriptor.contains("search")
            || descriptor.contains("fetch")
        {
            return .read
        }
        return .none
    }

    private func applyZCodeRecord(
        _ data: Data,
        sourcePath: String,
        noveltyPolicy: NoveltyEmissionPolicy,
        runtime: inout SourceRuntime
    ) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let startedText = envelope["startedAt"] as? String,
              let startedAt = parseTimestamp(startedText)
        else {
            return
        }

        let completedAt = (envelope["completedAt"] as? String).flatMap(parseTimestamp)
        // model-io lines are written only after the provider response completes.
        // `startedAt` describes past work; it cannot provide a truthful live
        // start signal, so ZCode is intentionally completion-observed.
        let timestamp = completedAt ?? startedAt
        runtime.latestEventAt = max(runtime.latestEventAt, timestamp)
        let response = envelope["response"] as? [String: Any] ?? [:]
        let finishReason = (response["finishReason"] as? String)?.lowercased() ?? ""
        let toolCalls = response["toolCalls"] as? [[String: Any]] ?? []

        // ZCode persists one completed provider response per line. Record every
        // stable tool name, even though only the strongest hint is used for the
        // activity snapshot.
        for toolCall in toolCalls {
            let rawName = toolCall["name"] as? String ?? ""
            observeTool(
                named: rawName,
                agent: .zcode,
                at: timestamp,
                sourcePath: sourcePath,
                toolActionHint: zcodeActionHint(for: [toolCall]),
                noveltyPolicy: noveltyPolicy
            )
        }

        if zcodeRecordFailed(envelope, response: response, finishReason: finishReason) {
            runtime.spokenMessage = nil
            remember(
                .failed,
                detail: "ZCode request failed",
                at: timestamp,
                sourcePath: sourcePath,
                failureDisposition: .routine,
                sourceAgent: .zcode,
                runtime: &runtime
            )
            return
        }

        if !toolCalls.isEmpty || finishReason == "tool-calls" {
            let actionHint = zcodeActionHint(for: toolCalls)
            let names = toolCalls.compactMap { $0["name"] as? String }
            let detail = names.isEmpty
                ? "ZCode completed tool calls"
                : "ZCode: \(names.prefix(2).joined(separator: ", "))"
            remember(
                .tool,
                detail: detail,
                at: timestamp,
                sourcePath: sourcePath,
                toolActionHint: actionHint,
                sourceAgent: .zcode,
                runtime: &runtime
            )
            return
        }

        if finishReason == "stop" {
            captureZCodeSpokenText(envelope, at: timestamp, runtime: &runtime)
            remember(
                .review,
                detail: "Reviewing ZCode's result",
                at: timestamp,
                sourcePath: sourcePath,
                sourceAgent: .zcode,
                runtime: &runtime
            )
        } else {
            remember(
                .thinking,
                detail: "ZCode response completed",
                at: timestamp,
                sourcePath: sourcePath,
                sourceAgent: .zcode,
                runtime: &runtime
            )
        }
    }

    /// Pull assistant reply text out of a ZCode `model_io` record and accumulate
    /// it on the in-flight turn so the speech bubble can echo it. ZCode persists
    /// one completed provider response per line; the final text answer lives in
    /// `response.text` when `finishReason == "stop"`.
    private func captureZCodeSpokenText(
        _ envelope: [String: Any],
        at timestamp: Date,
        runtime: inout SourceRuntime
    ) {
        guard let response = envelope["response"] as? [String: Any],
              let text = response["text"] as? String,
              !text.isEmpty
        else {
            return
        }
        let turnIdentifier = (envelope["turnId"] as? String)
            ?? (envelope["requestId"] as? String)
        replaceSpokenText(
            text,
            turnIdentifier: turnIdentifier,
            kind: .answer,
            originPriority: 3,
            at: timestamp,
            runtime: &runtime
        )
        markSpokenMessageCompleted(at: timestamp, runtime: &runtime)
    }

    private func zcodeRecordFailed(
        _ envelope: [String: Any],
        response: [String: Any],
        finishReason: String
    ) -> Bool {
        let status = ((envelope["status"] as? String)
            ?? (response["status"] as? String)
            ?? "").lowercased()
        if ["failed", "failure", "error", "errored"].contains(status)
            || finishReason.contains("error")
            || finishReason.contains("fail")
        {
            return true
        }
        if let error = envelope["error"], !(error is NSNull) {
            return true
        }
        if let error = response["error"], !(error is NSNull) {
            return true
        }
        return false
    }

    private func zcodeActionHint(
        for toolCalls: [[String: Any]]
    ) -> CodexToolActionHint {
        var result = CodexToolActionHint.none
        for call in toolCalls {
            let name = (call["name"] as? String ?? "").lowercased()
            let hint: CodexToolActionHint
            if name.contains("bash") {
                hint = .none
            } else if name.contains("write")
                || name.contains("edit")
                || name.contains("applypatch")
                || name.contains("apply_patch")
            {
                hint = .write
            } else if name.contains("read")
                || name.contains("webfetch")
                || name.contains("web_fetch")
                || name.contains("search")
            {
                hint = .read
            } else {
                hint = .none
            }

            if hint == .write {
                return .write
            }
            if hint == .read {
                result = .read
            }
        }
        return result
    }

    private func decodeRecord(_ data: Data) -> RolloutRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any],
              let timestampText = envelope["timestamp"] as? String,
              let timestamp = parseTimestamp(timestampText),
              let envelopeType = envelope["type"] as? String
        else {
            return nil
        }

        let payload = envelope["payload"] as? [String: Any] ?? [:]
        let payloadType = payload["type"] as? String ?? ""
        return RolloutRecord(
            timestamp: timestamp,
            envelopeType: envelopeType,
            payloadType: payloadType,
            payload: payload
        )
    }

    private func parseTimestamp(_ value: String) -> Date? {
        if let date = fractionalTimestampFormatter.date(from: value) {
            return date
        }
        return wholeSecondsTimestampFormatter.date(from: value)
    }

    private func apply(
        _ record: RolloutRecord,
        sourcePath: String,
        noveltyPolicy: NoveltyEmissionPolicy,
        runtime: inout SourceRuntime
    ) {
        runtime.latestEventAt = max(runtime.latestEventAt, record.timestamp)

        let payloadType = record.payloadType.lowercased()
        let envelopeType = record.envelopeType.lowercased()
        let status = (record.payload["status"] as? String)?.lowercased() ?? ""

        if ["function_call", "custom_tool_call", "tool_search_call"].contains(payloadType),
           let rawName = record.payload["name"] as? String
        {
            let activity = activityForTool(named: rawName)
            observeTool(
                named: rawName,
                agent: .codex,
                at: record.timestamp,
                sourcePath: sourcePath,
                toolActionHint: activity == .tool
                    ? toolActionHint(forToolNamed: rawName, payload: record.payload)
                    : .none,
                noveltyPolicy: noveltyPolicy
            )
        }

        if isFailure(record, payloadType: payloadType, status: status) {
            runtime.activeTurn = nil
            runtime.spokenMessage = nil
            runtime.openCalls.removeAll(keepingCapacity: true)
            remember(
                .failed,
                detail: failureDetail(for: payloadType),
                at: record.timestamp,
                sourcePath: sourcePath,
                failureDisposition: failureDisposition(
                    for: record,
                    payloadType: payloadType,
                    status: status
                ),
                runtime: &runtime
            )
            return
        }

        switch payloadType {
        case "task_started":
            runtime.openCalls.removeAll(keepingCapacity: true)
            runtime.spokenMessage = nil
            runtime.activeTurn = ActiveTurn(
                identifier: record.payload["turn_id"] as? String,
                startedAt: record.timestamp
            )
            remember(
                .thinking,
                detail: "Working",
                at: record.timestamp,
                sourcePath: sourcePath,
                runtime: &runtime
            )
            return

        case "task_complete":
            let completedTurnIdentifier = record.payload["turn_id"] as? String
            guard turnCompletionMatches(
                completedTurnIdentifier,
                runtime: runtime
            ) else {
                // A delayed completion from an older rollout turn must not
                // replace or finish the newer turn currently being followed.
                return
            }
            let turnIdentifier = (record.payload["turn_id"] as? String)
                ?? runtime.activeTurn?.identifier
            if let finalText = record.payload["last_agent_message"] as? String {
                replaceSpokenText(
                    finalText,
                    turnIdentifier: turnIdentifier,
                    kind: .answer,
                    originPriority: 3,
                    at: record.timestamp,
                    runtime: &runtime
                )
            }
            clearTurn(
                using: completedTurnIdentifier,
                completedAt: record.timestamp,
                runtime: &runtime
            )
            runtime.openCalls.removeAll(keepingCapacity: true)
            remember(
                .review,
                detail: "Reviewing the result",
                at: record.timestamp,
                sourcePath: sourcePath,
                runtime: &runtime
            )
            return

        case "turn_aborted":
            runtime.activeTurn = nil
            runtime.spokenMessage = nil
            runtime.openCalls.removeAll(keepingCapacity: true)
            remember(
                .failed,
                detail: "Task interrupted",
                at: record.timestamp,
                sourcePath: sourcePath,
                failureDisposition: .interrupted,
                runtime: &runtime
            )
            return

        case "function_call", "custom_tool_call", "tool_search_call":
            applyToolCall(
                record,
                sourcePath: sourcePath,
                noveltyPolicy: noveltyPolicy,
                runtime: &runtime
            )
            return

        case "function_call_output", "custom_tool_call_output", "tool_search_output":
            if let callID = record.payload["call_id"] as? String {
                runtime.openCalls.removeValue(forKey: callID)
            }
            remember(
                .thinking,
                detail: "Processing tool output",
                at: record.timestamp,
                sourcePath: sourcePath,
                runtime: &runtime
            )
            return

        default:
            break
        }

        if payloadType.contains("approval")
            || payloadType.contains("permission")
            || payloadType.contains("elicitation")
            || payloadType.contains("waiting")
        {
            remember(
                .waiting,
                detail: "Waiting for input",
                at: record.timestamp,
                sourcePath: sourcePath,
                runtime: &runtime
            )
            return
        }

        if payloadType.contains("review") {
            remember(
                .review,
                detail: "Reviewing changes",
                at: record.timestamp,
                sourcePath: sourcePath,
                runtime: &runtime
            )
            return
        }

        if isToolCompletion(payloadType) {
            remember(
                .tool,
                detail: toolCompletionDetail(payloadType),
                at: record.timestamp,
                sourcePath: sourcePath,
                toolActionHint: toolCompletionActionHint(payloadType),
                runtime: &runtime
            )
            return
        }

        let phase = (record.payload["phase"] as? String)?.lowercased() ?? ""
        if payloadType == "agent_message",
           phase == "final_answer" || phase == "commentary"
        {
            captureCodexSpokenText(
                record,
                kind: phase == "final_answer" ? .answer : .commentary,
                originPriority: 2,
                runtime: &runtime
            )
            remember(
                phase == "final_answer" ? .review : .thinking,
                detail: phase == "final_answer" ? "Reviewing the result" : "Thinking",
                at: record.timestamp,
                sourcePath: sourcePath,
                runtime: &runtime
            )
            return
        }

        if envelopeType == "response_item", payloadType == "message" {
            let role = (record.payload["role"] as? String)?.lowercased() ?? ""
            guard role == "assistant",
                  phase == "final_answer" || phase == "commentary"
            else {
                return
            }
            captureCodexSpokenText(
                record,
                kind: phase == "final_answer" ? .answer : .commentary,
                originPriority: 1,
                runtime: &runtime
            )
            remember(
                phase == "final_answer" ? .review : .thinking,
                detail: phase == "final_answer" ? "Reviewing the result" : "Thinking",
                at: record.timestamp,
                sourcePath: sourcePath,
                runtime: &runtime
            )
            return
        }

        if payloadType == "agent_reasoning"
            || payloadType == "reasoning"
            || payloadType == "token_count"
            || payloadType == "sub_agent_activity"
            || payloadType == "context_compacted"
        {
            remember(
                .thinking,
                detail: payloadType == "sub_agent_activity"
                    ? "Coordinating work"
                    : "Thinking",
                at: record.timestamp,
                sourcePath: sourcePath,
                runtime: &runtime
            )
        }
    }

    /// Capture one complete Codex commentary/final message. The event form uses
    /// `payload.message`; the response-item form uses `content[].output_text`.
    /// Repeated representations replace/no-op rather than concatenate.
    private func captureCodexSpokenText(
        _ record: RolloutRecord,
        kind: SpokenKind,
        originPriority: Int,
        runtime: inout SourceRuntime
    ) {
        if runtime.activeTurn == nil {
            runtime.activeTurn = ActiveTurn(
                identifier: record.payload["turn_id"] as? String,
                startedAt: record.timestamp
            )
        }

        let rawText: String?
        if let message = record.payload["message"] as? String, !message.isEmpty {
            rawText = message
        } else if let content = record.payload["content"] as? [[String: Any]] {
            let pieces = content.compactMap { item -> String? in
                guard (item["type"] as? String) == "output_text" else { return nil }
                return item["text"] as? String
            }
            rawText = pieces.isEmpty ? nil : pieces.joined(separator: "\n")
        } else {
            rawText = nil
        }
        guard let rawText else { return }
        replaceSpokenText(
            rawText,
            turnIdentifier: runtime.activeTurn?.identifier,
            kind: kind,
            originPriority: originPriority,
            at: record.timestamp,
            runtime: &runtime
        )
    }

    private func applyToolCall(
        _ record: RolloutRecord,
        sourcePath: String,
        noveltyPolicy: NoveltyEmissionPolicy,
        runtime: inout SourceRuntime
    ) {
        let rawName = (record.payload["name"] as? String ?? "tool")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let activity = activityForTool(named: rawName)
        let detail = detailForTool(named: rawName, activity: activity)
        let toolActionHint = activity == .tool
            ? toolActionHint(forToolNamed: rawName, payload: record.payload)
            : .none
        let status = (record.payload["status"] as? String)?.lowercased() ?? ""
        let callID = record.payload["call_id"] as? String

        observeTool(
            named: rawName,
            agent: .codex,
            at: record.timestamp,
            sourcePath: sourcePath,
            toolActionHint: toolActionHint,
            noveltyPolicy: noveltyPolicy
        )

        // custom_tool_call records currently arrive with status=completed.
        // Standard function_call records stay open until function_call_output.
        if let callID, status != "completed", status != "failed", status != "error" {
            runtime.openCalls[callID] = OpenCall(
                activity: activity,
                detail: detail,
                startedAt: record.timestamp,
                toolActionHint: toolActionHint
            )
        }

        remember(
            activity,
            detail: detail,
            at: record.timestamp,
            sourcePath: sourcePath,
            toolActionHint: toolActionHint,
            runtime: &runtime
        )
    }

    private func observeTool(
        named rawName: String,
        agent: MonitoredAgent,
        at timestamp: Date,
        sourcePath: String,
        toolActionHint: CodexToolActionHint,
        noveltyPolicy: NoveltyEmissionPolicy
    ) {
        guard let canonicalName = canonicalToolName(rawName) else { return }
        let identity = ToolIdentity(agent: agent, canonicalName: canonicalName)
        let insertion = seenTools.insert(identity)
        guard insertion.inserted else { return }
        relationshipStateIsDirty = true
        relationshipNeedsImmediateSave = true

        switch noveltyPolicy {
        case .suppress:
            return
        case .live:
            break
        case let .since(cutoff):
            guard timestamp >= cutoff else { return }
        }

        noveltySequence &+= 1
        let event = ToolNoveltyEvent(
            sequence: noveltySequence,
            agent: agent,
            canonicalName: canonicalName,
            observedAt: timestamp,
            sourcePath: sourcePath,
            toolActionHint: toolActionHint
        )
        if let current = latestNovelTool, current.observedAt > event.observedAt {
            return
        }
        // Candidate and adapter traversal order is deterministic. For exactly
        // equal timestamps, the later monotonic sequence is the final tie-break.
        latestNovelTool = event
    }

    private func canonicalToolName(_ rawName: String) -> String? {
        let components = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
        guard !components.isEmpty else { return nil }

        let canonicalName = components.map(String.init).joined(separator: "_")
        let genericNames: Set<String> = [
            "call",
            "custom_tool_call",
            "function",
            "function_call",
            "generic",
            "generic_tool",
            "mcp_tool",
            "mcp_tool_call",
            "tool",
            "tool_call",
            "tools",
            "unknown",
            "unnamed",
        ]
        guard !genericNames.contains(canonicalName) else { return nil }
        return canonicalName
    }

    private func activityForTool(named rawName: String) -> CodexActivity {
        let name = rawName.lowercased()

        if name.contains("request_user_input")
            || name.contains("approval")
            || name.contains("permission")
            || name.contains("elicitation")
            || name == "wait"
            || name.hasPrefix("wait_")
            || name == "write_stdin"
            || name.hasSuffix("__write_stdin")
            || name.hasSuffix(".write_stdin")
        {
            return .waiting
        }

        if name.contains("review") {
            return .review
        }

        return .tool
    }

    private func toolActionHint(
        forToolNamed rawName: String,
        payload: [String: Any]
    ) -> CodexToolActionHint {
        let name = rawName.lowercased()
        let components = Set(
            name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        )

        if name.contains("apply_patch")
            || name.contains("patch_apply")
            || name.contains("edit_file")
            || name.contains("write_file")
            || name.contains("replace_file")
            || name.contains("create_file")
            || name.contains("delete_file")
            || name.contains("move_file")
            || name.contains("rename_file")
            || (
                components.contains("edit")
                    && !components.contains("editor")
            )
            || (
                components.contains("write")
                    && !components.contains("stdin")
            )
        {
            return .write
        }

        if components.contains("read")
            || components.contains("search")
            || components.contains("find")
            || components.contains("inspect")
            || components.contains("view")
            || components.contains("list")
            || components.contains("get")
            || components.contains("screenshot")
        {
            return .read
        }

        if name == "exec"
            || name.hasSuffix("__exec")
            || name.hasSuffix(".exec")
        {
            let input = toolInputText(from: payload).lowercased()
            if input.contains("tools.apply_patch")
                || input.contains("apply_patch(")
                || input.contains("edit_file(")
                || input.contains("write_file(")
            {
                return .write
            }
            if input.contains("tools.read_")
                || input.contains("tools.search_")
                || input.contains("tools.find")
                || input.contains("tools.list_")
                || input.contains("tools.get_")
            {
                return .read
            }
        }

        if name == "exec_command"
            || name == "shell_command"
            || name.hasSuffix("__exec_command")
            || name.hasSuffix("__shell_command")
            || name.hasSuffix(".exec_command")
            || name.hasSuffix(".shell_command")
        {
            return readOnlyShellHint(for: toolInputText(from: payload))
        }

        return .none
    }

    private func toolInputText(from payload: [String: Any]) -> String {
        for key in ["arguments", "input"] {
            guard let value = payload[key] else { continue }
            if let dictionary = value as? [String: Any] {
                if let command = dictionary["cmd"] as? String
                    ?? dictionary["command"] as? String
                {
                    return command
                }
                continue
            }

            guard let text = value as? String else { continue }
            if let data = text.data(using: .utf8),
               let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let command = dictionary["cmd"] as? String
                    ?? dictionary["command"] as? String
            {
                return command
            }
            return text
        }
        return ""
    }

    private func readOnlyShellHint(for rawCommand: String) -> CodexToolActionHint {
        let command = rawCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !command.isEmpty,
              !command.contains(">"),
              !command.contains(" -i "),
              !command.hasSuffix(" -i")
        else {
            return .none
        }

        let separators = CharacterSet(charactersIn: ";&|")
        let segments = command
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !segments.isEmpty, segments.allSatisfy(isReadOnlyShellSegment) else {
            return .none
        }
        return .read
    }

    private func isReadOnlyShellSegment(_ segment: String) -> Bool {
        let words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = words.first?.split(separator: "/").last.map(String.init) else {
            return false
        }

        let readOnlyExecutables: Set<String> = [
            "cat", "find", "file", "grep", "head", "ls", "md5", "md5sum",
            "pwd", "rg", "sed", "sha256sum", "sort", "stat", "tail", "wc",
            "which",
        ]
        if readOnlyExecutables.contains(executable) {
            return true
        }

        if executable == "git", words.count > 1 {
            return ["diff", "log", "show", "status"].contains(words[1])
        }
        if executable == "defaults", words.count > 1 {
            return words[1] == "read"
        }
        if executable == "plutil" {
            return words.contains("-p") || words.contains("-lint")
        }
        return false
    }

    private func detailForTool(named rawName: String, activity: CodexActivity) -> String {
        switch activity {
        case .waiting:
            if rawName.lowercased().contains("user_input")
                || rawName.lowercased().contains("approval")
                || rawName.lowercased().contains("permission")
            {
                return "Waiting for user input"
            }
            return "Waiting for another task"

        case .review:
            return "Reviewing changes"

        case .tool:
            let safeName = rawName
                .prefix(48)
                .map { $0 == "_" ? " " : String($0) }
                .joined()
            return safeName.isEmpty ? "Using a tool" : "Using \(safeName)"

        default:
            return "Working"
        }
    }

    private func isFailure(
        _ record: RolloutRecord,
        payloadType: String,
        status: String
    ) -> Bool {
        if payloadType.contains("failed")
            || payloadType.contains("failure")
            || payloadType.contains("error")
        {
            return true
        }

        if ["failed", "failure", "error", "errored"].contains(status) {
            return true
        }

        if let success = record.payload["success"] as? Bool, !success {
            return true
        }

        if let error = record.payload["error"], !(error is NSNull) {
            return true
        }

        return false
    }

    private func failureDetail(for payloadType: String) -> String {
        payloadType.contains("abort") ? "Task interrupted" : "Task failed"
    }

    private func failureDisposition(
        for record: RolloutRecord,
        payloadType: String,
        status: String
    ) -> CodexFailureDisposition {
        if payloadType.contains("abort") || status == "aborted" {
            return .interrupted
        }

        // Blade use is fail-closed: only explicit structured safety evidence
        // can identify a credible threat. Arbitrary error prose is never
        // keyword-scanned because ordinary compiler and network errors often
        // mention words such as "fatal", "unsafe", or "attack".
        if record.payload["credible_threat"] as? Bool == true
            || record.payload["security_threat"] as? Bool == true
            || [
                "credible_threat",
                "malware_detected",
                "safety_threat",
                "security_threat",
            ].contains(payloadType)
            || ["credible_threat", "security_threat"].contains(status)
        {
            return .credibleThreat
        }

        return .routine
    }

    private func replaceSpokenText(
        _ rawText: String,
        turnIdentifier: String?,
        kind: SpokenKind,
        originPriority: Int,
        at timestamp: Date,
        runtime: inout SourceRuntime
    ) {
        guard let text = normalizedSpokenText(rawText) else { return }

        if let current = runtime.spokenMessage,
           current.turnIdentifier == turnIdentifier
        {
            if current.text == text, current.kind == kind {
                return
            }
            if current.kind.rawValue > kind.rawValue {
                return
            }
            if current.kind == kind {
                if timestamp < current.updatedAt {
                    return
                }
                if timestamp == current.updatedAt,
                   current.originPriority > originPriority
                {
                    return
                }
            }
        }

        spokenRevisionSequence &+= 1
        runtime.spokenMessage = SpokenMessage(
            turnIdentifier: turnIdentifier,
            kind: kind,
            text: text,
            updatedAt: timestamp,
            completedAt: nil,
            originPriority: originPriority,
            revision: spokenRevisionSequence
        )
    }

    private func appendSpokenText(
        _ chunk: String,
        turnIdentifier: String?,
        at timestamp: Date,
        runtime: inout SourceRuntime
    ) {
        guard !chunk.isEmpty else { return }
        let existing: String
        if let current = runtime.spokenMessage,
           current.turnIdentifier == turnIdentifier,
           current.kind == .answer,
           current.completedAt == nil
        {
            existing = current.text
        } else {
            existing = ""
        }
        let combined = boundedSpokenText(existing + chunk)
        guard !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              combined != runtime.spokenMessage?.text
        else {
            return
        }

        spokenRevisionSequence &+= 1
        runtime.spokenMessage = SpokenMessage(
            turnIdentifier: turnIdentifier,
            kind: .answer,
            text: combined,
            updatedAt: timestamp,
            completedAt: nil,
            originPriority: 3,
            revision: spokenRevisionSequence
        )
    }

    private func normalizedSpokenText(_ rawText: String) -> String? {
        var text = rawText
        let opening = "<oai-mem-citation>"
        let closing = "</oai-mem-citation>"
        while let start = text.range(of: opening) {
            if let end = text.range(of: closing, range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                text.removeSubrange(start.lowerBound..<text.endIndex)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return boundedSpokenText(text)
    }

    private func boundedSpokenText(_ text: String) -> String {
        guard text.count > Self.maximumSpokenTextCharacters else { return text }
        return String(text.suffix(Self.maximumSpokenTextCharacters))
    }

    private func markSpokenMessageCompleted(
        at timestamp: Date,
        runtime: inout SourceRuntime
    ) {
        guard var message = runtime.spokenMessage else { return }
        guard message.completedAt == nil else { return }
        message.completedAt = max(timestamp, message.updatedAt)
        runtime.spokenMessage = message
    }

    private func spokenMessageIsFresh(_ message: SpokenMessage, now: Date) -> Bool {
        let anchor = message.completedAt ?? message.updatedAt
        let lifetime = message.completedAt == nil
            ? streamingSpeechLifetime
            : completedSpeechLifetime
        let age = now.timeIntervalSince(anchor)
        return age >= -2 && age <= lifetime
    }

    private func clearTurn(
        using identifier: String?,
        completedAt timestamp: Date,
        runtime: inout SourceRuntime
    ) {
        if let activeTurn = runtime.activeTurn {
            guard identifier == nil
                    || activeTurn.identifier == nil
                    || identifier == activeTurn.identifier
            else {
                return
            }
            markSpokenMessageCompleted(at: timestamp, runtime: &runtime)
            runtime.activeTurn = nil
            return
        }

        if let message = runtime.spokenMessage,
           identifier == nil
                || message.turnIdentifier == nil
                || identifier == message.turnIdentifier
        {
            markSpokenMessageCompleted(at: timestamp, runtime: &runtime)
        }
    }

    private func turnCompletionMatches(
        _ identifier: String?,
        runtime: SourceRuntime
    ) -> Bool {
        if let activeTurn = runtime.activeTurn {
            return identifier == nil
                || activeTurn.identifier == nil
                || identifier == activeTurn.identifier
        }
        if let message = runtime.spokenMessage {
            return identifier == nil
                || message.turnIdentifier == nil
                || identifier == message.turnIdentifier
        }
        return true
    }

    private func isToolCompletion(_ payloadType: String) -> Bool {
        payloadType == "patch_apply_end"
            || payloadType == "mcp_tool_call_end"
            || payloadType == "web_search_end"
            || payloadType == "image_generation_end"
    }

    private func toolCompletionDetail(_ payloadType: String) -> String {
        switch payloadType {
        case "patch_apply_end":
            return "Applying changes"
        case "web_search_end":
            return "Researching"
        case "image_generation_end":
            return "Creating artwork"
        default:
            return "Using a tool"
        }
    }

    private func toolCompletionActionHint(_ payloadType: String) -> CodexToolActionHint {
        switch payloadType {
        case "patch_apply_end":
            return .write
        case "web_search_end":
            return .read
        default:
            return .none
        }
    }

    private func remember(
        _ activity: CodexActivity,
        detail: String,
        at timestamp: Date,
        sourcePath: String,
        toolActionHint: CodexToolActionHint = .none,
        failureDisposition: CodexFailureDisposition = .none,
        sourceAgent: MonitoredAgent = .codex,
        runtime: inout SourceRuntime
    ) {
        guard activity != .idle else { return }
        if let existing = runtime.evidence[activity], existing.observedAt > timestamp {
            return
        }
        runtime.evidence[activity] = Evidence(
            activity: activity,
            detail: detail,
            observedAt: timestamp,
            sourcePath: sourcePath,
            toolActionHint: toolActionHint,
            sourceAgent: sourceAgent,
            failureDisposition: activity == .failed
                ? (
                    failureDisposition == .none
                        ? .routine
                        : failureDisposition
                )
                : .none
        )
    }

    private func pruneSources(now: Date) {
        let candidateKeys = Set(
            candidateFiles.flatMap { agent, files in
                files.map { SourceKey(agent: agent, path: $0.url.path) }
            }
        )
        sources = sources.filter { key, runtime in
            candidateKeys.contains(key)
                || now.timeIntervalSince(runtime.modificationDate) < 1_800
        }

        for key in Array(sources.keys) {
            guard var runtime = sources[key] else { continue }
            runtime.evidence = runtime.evidence.filter { activity, evidence in
                now.timeIntervalSince(evidence.observedAt) <= evidenceLifetime(for: activity)
            }
            runtime.openCalls = runtime.openCalls.filter { _, call in
                now.timeIntervalSince(call.startedAt) <= openCallLifetime(for: call.activity)
            }
            if let activeTurn = runtime.activeTurn,
               now.timeIntervalSince(max(activeTurn.startedAt, runtime.latestEventAt)) > 180
            {
                runtime.activeTurn = nil
            }
            if let message = runtime.spokenMessage,
               !spokenMessageIsFresh(message, now: now)
            {
                runtime.spokenMessage = nil
            }
            sources[key] = runtime
        }
    }

    private func evidenceLifetime(for activity: CodexActivity) -> TimeInterval {
        switch activity {
        case .idle:
            return 0
        case .thinking:
            return 20
        case .tool:
            return 10
        case .waiting:
            return 20
        case .review:
            return 14
        case .failed:
            return 18
        }
    }

    private func openCallLifetime(for activity: CodexActivity) -> TimeInterval {
        switch activity {
        case .waiting:
            return 43_200
        case .tool:
            return 1_800
        case .review:
            return 600
        case .failed:
            return 60
        case .thinking:
            return 1_800
        case .idle:
            return 0
        }
    }

    private func makeSnapshot(now: Date) -> CodexActivitySnapshot {
        var candidates: [Evidence] = []
        let activeAgents = makeActiveAgents(now: now)
        let latestNovelTool = freshNovelTool(now: now)
        // Speech is arbitrated independently from activity. In all-Agent mode a
        // newer reply must remain visible even when another Agent wins the state
        // cluster because of a higher-priority failure or waiting event.
        var spokenText: String? = nil
        var spokenTextObservedAt = Date.distantPast
        var spokenAgent: MonitoredAgent? = nil
        var spokenRevision: UInt64? = nil
        var spokenKind: SpokenKind?
        var spokenSourcePath = ""

        for (key, runtime) in sources {
            for call in runtime.openCalls.values {
                candidates.append(
                    Evidence(
                        activity: call.activity,
                        detail: call.detail,
                        observedAt: call.startedAt,
                        sourcePath: key.path,
                        toolActionHint: call.toolActionHint,
                        sourceAgent: key.agent,
                        failureDisposition: .none
                    )
                )
            }

            candidates.append(contentsOf: runtime.evidence.values)

            if let message = runtime.spokenMessage,
               spokenMessageIsFresh(message, now: now)
            {
                let observedAt = max(message.updatedAt, message.completedAt ?? .distantPast)
                let shouldReplace: Bool
                if observedAt != spokenTextObservedAt {
                    shouldReplace = observedAt > spokenTextObservedAt
                } else if message.kind != spokenKind {
                    shouldReplace = message.kind.rawValue > (spokenKind?.rawValue ?? -1)
                } else if key.agent != spokenAgent {
                    shouldReplace = priority(of: key.agent)
                        > (spokenAgent.map { priority(of: $0) } ?? -1)
                } else {
                    shouldReplace = spokenSourcePath.isEmpty || key.path < spokenSourcePath
                }
                if shouldReplace {
                    spokenText = message.text
                    spokenTextObservedAt = observedAt
                    spokenAgent = key.agent
                    spokenRevision = message.revision
                    spokenKind = message.kind
                    spokenSourcePath = key.path
                }
            }

            if let activeTurn = runtime.activeTurn {
                let turnObservedAt = max(activeTurn.startedAt, runtime.latestEventAt)
                candidates.append(
                    Evidence(
                        activity: .thinking,
                        detail: "Working",
                        observedAt: turnObservedAt,
                        sourcePath: key.path,
                        toolActionHint: .none,
                        sourceAgent: key.agent,
                        failureDisposition: .none
                    )
                )
            }
        }

        guard let newestObservedAt = candidates.map(\.observedAt).max() else {
            return CodexActivitySnapshot(
                activity: .idle,
                detail: "Idle",
                observedAt: now,
                sourcePath: nil,
                monitoringGeneration: monitoringGeneration,
                latestNovelTool: latestNovelTool,
                activeAgents: activeAgents,
                spokenText: spokenText,
                spokenAgent: spokenAgent,
                spokenRevision: spokenRevision
            )
        }

        // First anchor the burst to the newest evidence. Only then apply
        // activity priority inside that one fixed cluster. Mixing the two rules
        // pairwise creates a non-transitive comparator and dictionary-order
        // dependent winners.
        let coalescingWindow: TimeInterval = 2.5
        let latestCluster = candidates.filter {
            newestObservedAt.timeIntervalSince($0.observedAt) <= coalescingWindow
        }
        guard let winner = latestCluster.max(by: evidencePrecedes) else {
            return CodexActivitySnapshot(
                activity: .idle,
                detail: "Idle",
                observedAt: now,
                sourcePath: nil,
                monitoringGeneration: monitoringGeneration,
                latestNovelTool: latestNovelTool,
                activeAgents: activeAgents,
                spokenText: spokenText,
                spokenAgent: spokenAgent,
                spokenRevision: spokenRevision
            )
        }

        return CodexActivitySnapshot(
            activity: winner.activity,
            detail: winner.detail,
            observedAt: winner.observedAt,
            sourcePath: winner.sourcePath,
            toolActionHint: winner.toolActionHint,
            sourceAgent: winner.sourceAgent,
            monitoringGeneration: monitoringGeneration,
            latestNovelTool: latestNovelTool,
            activeAgents: activeAgents,
            failureDisposition: winner.failureDisposition,
            spokenText: spokenText,
            spokenAgent: spokenAgent,
            spokenRevision: spokenRevision
        )
    }

    private func freshNovelTool(now: Date) -> ToolNoveltyEvent? {
        guard let event = latestNovelTool,
              monitoredAgents(for: monitoringMode).contains(event.agent)
        else {
            return nil
        }

        let age = now.timeIntervalSince(event.observedAt)
        guard age >= -2, age <= noveltyLifetime else { return nil }
        return event
    }

    private func makeActiveAgents(now: Date) -> Set<MonitoredAgent> {
        var result: Set<MonitoredAgent> = []

        for (key, runtime) in sources {
            // ZCode writes model-io records only after completion and therefore
            // cannot truthfully contribute a live-active signal.
            guard key.agent == .codex || key.agent == .grok else { continue }

            let latestEvidence = runtime.evidence.values.max { lhs, rhs in
                if lhs.observedAt != rhs.observedAt {
                    return lhs.observedAt < rhs.observedAt
                }
                return priority(of: lhs.activity) < priority(of: rhs.activity)
            }
            let hasBlockingOpenCall = runtime.openCalls.values.contains {
                $0.activity == .waiting
                    || $0.activity == .failed
                    || $0.activity == .review
            }
            let latestEvidenceIsBlocked = latestEvidence.map {
                $0.activity == .waiting
                    || $0.activity == .failed
                    || $0.activity == .review
            } ?? false
            guard !hasBlockingOpenCall, !latestEvidenceIsBlocked else {
                continue
            }

            let hasOpenWork = runtime.openCalls.values.contains {
                $0.activity == .tool || $0.activity == .thinking
            }
            let hasFreshWorkEvidence = latestEvidence.map { evidence in
                guard evidence.activity == .thinking || evidence.activity == .tool else {
                    return false
                }
                let age = now.timeIntervalSince(evidence.observedAt)
                return age >= -2 && age <= evidenceLifetime(for: evidence.activity)
            } ?? false

            if runtime.activeTurn != nil
                || hasOpenWork
                || hasFreshWorkEvidence
            {
                result.insert(key.agent)
            }
        }

        return result
    }

    private func evidencePrecedes(_ lhs: Evidence, _ rhs: Evidence) -> Bool {
        let lhsPriority = priority(of: lhs.activity)
        let rhsPriority = priority(of: rhs.activity)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        if lhs.observedAt != rhs.observedAt {
            return lhs.observedAt < rhs.observedAt
        }

        let lhsAgentPriority = priority(of: lhs.sourceAgent)
        let rhsAgentPriority = priority(of: rhs.sourceAgent)
        if lhsAgentPriority != rhsAgentPriority {
            return lhsAgentPriority < rhsAgentPriority
        }

        if lhs.toolActionHint != rhs.toolActionHint {
            return priority(of: lhs.toolActionHint) < priority(of: rhs.toolActionHint)
        }

        if lhs.failureDisposition != rhs.failureDisposition {
            return priority(of: lhs.failureDisposition)
                < priority(of: rhs.failureDisposition)
        }

        if lhs.sourcePath != rhs.sourcePath {
            // Prefer the lexicographically smaller path as a stable final source
            // tie-breaker; the choice is arbitrary, but never hash-order based.
            return lhs.sourcePath > rhs.sourcePath
        }

        return lhs.detail > rhs.detail
    }

    /// Priority for events emitted in the same short activity burst:
    /// failed > waiting > review > tool > thinking > idle.
    private func priority(of activity: CodexActivity) -> Int {
        switch activity {
        case .failed:
            return 500
        case .waiting:
            return 400
        case .review:
            return 300
        case .tool:
            return 200
        case .thinking:
            return 100
        case .idle:
            return 0
        }
    }

    private func priority(of agent: MonitoredAgent) -> Int {
        switch agent {
        case .codex:
            return 300
        case .grok:
            return 200
        case .zcode:
            return 100
        }
    }

    private func priority(of hint: CodexToolActionHint) -> Int {
        switch hint {
        case .write:
            return 300
        case .read:
            return 200
        case .none:
            return 100
        }
    }

    private func priority(
        of disposition: CodexFailureDisposition
    ) -> Int {
        switch disposition {
        case .credibleThreat:
            return 300
        case .interrupted:
            return 200
        case .routine:
            return 100
        case .none:
            return 0
        }
    }

    private func deliverIfChanged(_ snapshot: CodexActivitySnapshot) {
        let stateChanged = lastDelivered?.activity != snapshot.activity
        let detailChanged = lastDelivered?.detail != snapshot.detail
        let sourceChanged = lastDelivered?.sourcePath != snapshot.sourcePath
        let actionChanged = lastDelivered?.toolActionHint != snapshot.toolActionHint
        let agentChanged = lastDelivered?.sourceAgent != snapshot.sourceAgent
        let generationChanged =
            lastDelivered?.monitoringGeneration != snapshot.monitoringGeneration
        let novelToolChanged =
            lastDelivered?.latestNovelTool?.sequence != snapshot.latestNovelTool?.sequence
        let activeAgentsChanged = lastDelivered?.activeAgents != snapshot.activeAgents
        let failureDispositionChanged =
            lastDelivered?.failureDisposition != snapshot.failureDisposition
        let relationshipChanged =
            lastDelivered?.relationshipProfile != snapshot.relationshipProfile
        let spokenTextChanged = lastDelivered?.spokenText != snapshot.spokenText
        let spokenAgentChanged = lastDelivered?.spokenAgent != snapshot.spokenAgent
        let spokenRevisionChanged =
            lastDelivered?.spokenRevision != snapshot.spokenRevision

        guard lastDelivered == nil
            || stateChanged
            || detailChanged
            || sourceChanged
            || actionChanged
            || agentChanged
            || generationChanged
            || novelToolChanged
            || activeAgentsChanged
            || failureDispositionChanged
            || relationshipChanged
            || spokenTextChanged
            || spokenAgentChanged
            || spokenRevisionChanged
        else {
            return
        }

        lastDelivered = snapshot

        callbackLock.lock()
        let callback = self.callback
        callbackLock.unlock()

        guard let callback else { return }
        DispatchQueue.main.async {
            callback(snapshot)
        }
    }
}

private extension CodexActivity {
    var isCooperativeWork: Bool {
        switch self {
        case .thinking, .tool, .review:
            return true
        case .idle, .waiting, .failed:
            return false
        }
    }
}
