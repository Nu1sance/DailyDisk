import AppKit
import Combine
import DailyDiskCore
import DailyDiskPlatform
import DailyDiskStore
import Foundation

@MainActor
final class AppController: ObservableObject {
    @Published private(set) var fullDiskAccess = FullDiskAccessProbeResult(
        status: .inconclusive,
        accessiblePaths: [],
        deniedPaths: [],
        missingPaths: []
    )
    @Published private(set) var notificationState: NotificationAuthorizationState = .unknown
    @Published private(set) var launchAgentStatus: LaunchAgentStatus = .unknown
    @Published private(set) var helperRuntimeStatus: LaunchAgentRuntimeStatus?
    @Published private(set) var topology: VolumeTopology?
    @Published private(set) var latestReport: DailyReport?
    @Published private(set) var reports: [DailyReport] = []
    @Published private(set) var selectedReport: DailyReport?
    @Published private(set) var discloseReportPaths = false
    @Published private(set) var inspectionSnapshot: RuntimeInspectionSnapshot?
    @Published private(set) var scanState: AppScanState = .idle
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var actionMessage: String?

    private let accessProbe: any FullDiskAccessProbing
    private let notificationManager: any NotificationAuthorizationManaging
    private let volumeDiscovery: any VolumeDiscovering
    private let launchAgentManager: LaunchAgentManager
    private let controlStore: RunControlStore?
    private let inspectionService: RuntimeInspectionService
    private let dataResetter: DailyDiskDataResetter
    private let pollingInterval: Duration
    private var progressPollingTask: Task<Void, Never>?
    private var trackedRequestID: UUID?
    private var loadedTerminalRequestID: UUID?
    private var lastHelperCheck = Date.distantPast
    private var isReadingProgress = false
    private var isSubmittingScanRequest = false
    private var observedRequestID: UUID?
    private var observedRequestAt = Date()
    private let now: @Sendable () -> Date
    @Published private(set) var hasRefreshed = false

    init(
        accessProbe: any FullDiskAccessProbing = FullDiskAccessProbe(),
        notificationManager: (any NotificationAuthorizationManaging)? = nil,
        volumeDiscovery: any VolumeDiscovering = APFSVolumeProvider(),
        launchAgentManager: LaunchAgentManager = LaunchAgentManager(),
        controlStore: RunControlStore? = try? RunControlStore(),
        inspectionService: RuntimeInspectionService = RuntimeInspectionService(),
        dataResetter: DailyDiskDataResetter? = nil,
        pollingInterval: Duration = .milliseconds(500),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accessProbe = accessProbe
        if let notificationManager {
            self.notificationManager = notificationManager
        } else {
            self.notificationManager = NotificationManager()
        }
        self.volumeDiscovery = volumeDiscovery
        self.launchAgentManager = launchAgentManager
        self.controlStore = controlStore
        self.inspectionService = inspectionService
        self.dataResetter = dataResetter ?? DailyDiskDataResetter()
        self.pollingInterval = pollingInterval
        self.now = now
    }

    deinit {
        progressPollingTask?.cancel()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        await refreshScanState()
        startProgressPolling()
        async let access = accessProbe.probe()
        async let notifications = notificationManager.authorizationState()
        do {
            topology = try await volumeDiscovery.discoverInternalAPFSVolumes()
            let inspection = try await inspectionService.loadSnapshot(verify: false)
            inspectionSnapshot = inspection
            applyReports(inspection.reports)
        } catch {
            errorMessage = "无法刷新 DailyDisk 状态。"
        }
        fullDiskAccess = await access
        notificationState = await notifications
        launchAgentStatus = await launchAgentManager.status()
        helperRuntimeStatus = try? await launchAgentManager.runtimeStatus()
        await refreshScanState()
        if scanState.isActive {
            await ensureOutstandingRequestIsStarted()
        }
        startProgressPolling()
        hasRefreshed = true
        isRefreshing = false
    }

    func scanNow(requestedMode: DailyDiskRequestedScanMode = .automatic) async {
        guard !scanState.isActive, !isSubmittingScanRequest else { return }
        isSubmittingScanRequest = true
        defer { isSubmittingScanRequest = false }
        // Publish feedback before the first suspension; repeated clicks cannot enqueue twice.
        scanState = .requesting
        errorMessage = nil
        actionMessage = nil
        loadedTerminalRequestID = nil
        observedRequestID = nil
        lastHelperCheck = .distantPast
        guard let controlStore else {
            scanState = .failed(.controlChannel)
            return
        }
        launchAgentStatus = await launchAgentManager.status()
        guard launchAgentStatus == .enabled else {
            scanState = .failed(.launchAgentUnavailable)
            actionMessage =
                launchAgentStatus == .requiresApproval
                ? "请先在“登录项与扩展”中允许 DailyDisk。"
                : "请先安装 DailyDisk 每日任务。"
            return
        }

        do {
            if let active = try await controlStore.activeRequest() {
                trackedRequestID = active.requestID
                _ = try await launchAgentManager.startIfNeeded(controlStore: controlStore)
                await refreshScanState(allowDuringSubmission: true)
                startProgressPolling()
                return
            }
            if let pending = try await controlStore.pendingRequest() {
                trackedRequestID = pending.requestID
                scanState = .requesting
                _ = try await launchAgentManager.startIfNeeded(controlStore: controlStore)
                await refreshScanState(allowDuringSubmission: true)
                startProgressPolling()
                return
            }
            let inspection = try await inspectionService.loadSnapshot(historyLimit: 1, verify: false)
            if inspection.writerState?.leaseIsHeld == true {
                scanState = .externalWriter
                startProgressPolling()
                return
            }
            let request = try DailyDiskRunRequest(requestedMode: requestedMode)
            scanState = .requesting
            trackedRequestID = request.requestID
            try await controlStore.enqueue(request)
            _ = try await launchAgentManager.startIfNeeded(controlStore: controlStore)
            await refreshScanState(allowDuringSubmission: true)
            startProgressPolling()
        } catch let error as RunControlStoreError {
            switch error {
            case .runAlreadyActive, .requestAlreadyPending:
                await ensureOutstandingRequestIsStarted()
                await refreshScanState(allowDuringSubmission: true)
                startProgressPolling()
            default:
                scanState = .failed(.controlChannel)
            }
        } catch let error as LaunchAgentManagerError {
            if case .serviceUnavailable = error {
                scanState = .failed(.launchAgentUnavailable)
            } else {
                scanState = .failed(.controlChannel)
            }
        } catch {
            scanState = .failed(.controlChannel)
        }
    }

    func cancelScan() async {
        guard let controlStore,
            let progress = scanState.progress,
            progress.phase.allowsCancellation
        else { return }
        do {
            if progress.phase == .queued,
                try await controlStore.activeRequest() == nil
            {
                do {
                    let summary = try await controlStore.cancelPendingRequest(
                        requestID: progress.requestID
                    )
                    scanState = .cancelled(summary)
                    return
                } catch {
                    guard let active = try await controlStore.activeRequest(),
                        active.requestID == progress.requestID
                    else { throw error }
                }
            }
            try await controlStore.requestCancellation(
                DailyDiskCancelRequest(requestID: progress.requestID)
            )
            scanState = .cancellationRequested(progress)
            startProgressPolling()
        } catch {
            await refreshScanState()
        }
    }

    func refreshScanState(allowDuringSubmission: Bool = false) async {
        guard !isReadingProgress, allowDuringSubmission || !isSubmittingScanRequest else { return }
        isReadingProgress = true
        defer { isReadingProgress = false }
        guard let controlStore else {
            scanState = .failed(.controlChannel)
            return
        }
        do {
            let active = try await controlStore.activeRequest()
            let pending = try await controlStore.pendingRequest()
            let progress = try await controlStore.latestProgress()
            let cancellation = try await controlStore.cancellationRequest()
            guard allowDuringSubmission || !isSubmittingScanRequest else { return }
            if let request = active ?? pending {
                trackedRequestID = request.requestID
                if observedRequestID != request.requestID {
                    observedRequestID = request.requestID
                    observedRequestAt = now()
                }
                if now().timeIntervalSince(lastHelperCheck) >= 3 {
                    helperRuntimeStatus = try? await launchAgentManager.runtimeStatus()
                    launchAgentStatus = await launchAgentManager.status()
                    lastHelperCheck = now()
                }
                guard allowDuringSubmission || !isSubmittingScanRequest else { return }
                let updatedAt =
                    progress?.requestID == request.requestID
                    ? progress?.updatedAt ?? request.createdAt : request.createdAt
                if now().timeIntervalSince(updatedAt) > 15,
                    now().timeIntervalSince(observedRequestAt) > 15,
                    progress?.phase.isTerminal != true,
                    helperRuntimeStatus?.isRunning == false,
                    !SQLiteReportStore.writerIsActive(databaseURL: inspectionService.databaseURL)
                {
                    scanState = .failed(.helperStopped)
                    return
                }
                if progress?.requestID != request.requestID {
                    scanState = .requesting
                    return
                }
            } else if SQLiteReportStore.writerIsActive(databaseURL: inspectionService.databaseURL),
                progress?.phase.isTerminal != true
            {
                scanState = .externalWriter
                return
            }
            if let progress,
                trackedRequestID == nil || progress.requestID == trackedRequestID
            {
                trackedRequestID = progress.requestID
                switch progress.phase {
                case .committing, .publishingReport, .notifying, .applyingRetention, .cleaningUpFailedRun:
                    scanState = .finishing(progress)
                case .cancelling:
                    scanState = .cancellationRequested(progress)
                case .completed:
                    if active != nil {
                        scanState = .finishing(progress)
                    } else if let summary = try await controlStore.latestSummary(),
                        summary.requestID == progress.requestID
                    {
                        scanState = summary.terminalState == .skippedNotDue ? .idle : .succeeded(summary)
                        await reloadInspectionAfterTerminal()
                    } else {
                        scanState = .finishing(progress)
                    }
                case .cancelled:
                    if active != nil {
                        scanState = .finishing(progress)
                    } else {
                        let summary = try await controlStore.latestSummary()
                        scanState = .cancelled(summary)
                        await reloadInspectionAfterTerminal()
                    }
                case .failed:
                    if active != nil {
                        scanState = .finishing(progress)
                    } else {
                        scanState =
                            progress.errorCategory == .writerBusy
                            ? .externalWriter : .failed(.scanFailed)
                        await reloadInspectionAfterTerminal()
                    }
                case .queued, .waitingForWriter, .preparing, .discoveringStorage,
                    .recoveringInterruptedRun, .replayingEvents, .scanningFiles, .preservingOpaqueInventory,
                    .catchingUpEvents, .sealingInventory, .reconciling,
                    .collectingDiagnostics:
                    if cancellation?.requestID == progress.requestID {
                        scanState = .cancellationRequested(progress)
                    } else if case .cancellationRequested(let previous) = scanState,
                        previous.requestID == progress.requestID
                    {
                        scanState = .cancellationRequested(progress)
                    } else {
                        scanState = .running(progress)
                    }
                }
            } else if active == nil, pending == nil,
                let summary = try await controlStore.latestSummary(),
                trackedRequestID == nil || summary.requestID == trackedRequestID
            {
                trackedRequestID = summary.requestID
                switch summary.terminalState {
                case .succeeded: scanState = .succeeded(summary)
                case .cancelled: scanState = .cancelled(summary)
                case .failed: scanState = .failed(.scanFailed)
                case .blockedByWriter: scanState = .externalWriter
                case .skippedNotDue: scanState = .idle
                }
                await reloadInspectionAfterTerminal()
            } else if case .externalWriter = scanState {
                let inspection = try await inspectionService.loadSnapshot(historyLimit: 1, verify: false)
                inspectionSnapshot = inspection
                if inspection.writerState?.leaseIsHeld != true {
                    applyReports(inspection.reports)
                    scanState = .idle
                }
            }
        } catch {
            scanState = .failed(.controlChannel)
        }
    }

    func selectReport(_ report: DailyReport) {
        selectedReport = report
        discloseReportPaths = false
    }

    func setReportPathDisclosure(_ disclosed: Bool) {
        discloseReportPaths = disclosed
    }

    func exportSelectedReport(to url: URL) async {
        guard let selectedReport else { return }
        await exportReport(
            runID: selectedReport.runID,
            storageDomainID: selectedReport.storageDomainID,
            to: url
        )
    }

    func exportReport(
        runID: ScanRun.ID,
        storageDomainID: StorageDomain.ID,
        to url: URL
    ) async {
        do {
            guard
                let data = try await inspectionService.reportJSON(
                    runID: runID,
                    storageDomainID: storageDomainID
                )
            else {
                errorMessage = "找不到所选报告。"
                return
            }
            try data.write(to: url, options: [.atomic])
            actionMessage = "报告 JSON 已导出。"
        } catch {
            errorMessage = "导出报告失败。"
        }
    }

    func openReportsDirectory() {
        NSWorkspace.shared.open(LocalReportWriter.defaultReportDirectory)
    }

    func requestNotifications() async {
        do {
            let granted = try await notificationManager.requestAuthorization()
            notificationState = await notificationManager.authorizationState()
            actionMessage = granted ? "通知已启用。" : "通知未启用，请在系统设置中允许 DailyDisk 通知。"
        } catch {
            errorMessage = "通知授权失败。"
        }
    }

    func openFullDiskAccessSettings() { FullDiskAccessProbe.openSystemSettings() }
    func openNotificationSettings() { NotificationManager.openSystemSettings() }

    func installDailyRun() async {
        guard !scanState.isActive else { return }
        scanState = .requesting
        errorMessage = nil
        actionMessage = nil
        do {
            try await launchAgentManager.register()
            launchAgentStatus = await launchAgentManager.status()
            actionMessage =
                launchAgentStatus == .requiresApproval
                ? "请在“登录项与扩展”中允许 DailyDisk。"
                : "已启用每天 09:00 自动检查。"
            scanState = .idle
            await refresh()
            if launchAgentStatus == .enabled, !scanState.isActive {
                await scanNow()
            }
        } catch {
            scanState = .failed(.launchAgentUnavailable)
            errorMessage = "无法启用后台检查。请确认应用位于“应用程序”文件夹，再重试。"
        }
    }

    func uninstallDailyRun() async {
        do {
            try await launchAgentManager.unregister()
            launchAgentStatus = await launchAgentManager.status()
            actionMessage = "每日任务已移除。"
        } catch {
            errorMessage = "移除每日任务失败。"
        }
    }

    func stopCurrentHelper() async {
        do {
            if let progress = scanState.progress {
                guard progress.phase.allowsCancellation, let controlStore else {
                    errorMessage = "当前正在原子提交或生成报告，不能强制停止。"
                    return
                }
                try await launchAgentManager.requestStop(
                    requestID: progress.requestID,
                    controlStore: controlStore
                )
            } else {
                let snapshot = try await inspectionService.loadSnapshot(historyLimit: 1, verify: false)
                guard snapshot.writerState?.leaseIsHeld != true else {
                    errorMessage = "无法确认外部任务是否已进入提交阶段，未执行强制停止。"
                    return
                }
                try await launchAgentManager.terminateHelper()
            }
            actionMessage = "已请求停止后台任务。"
            helperRuntimeStatus = try? await launchAgentManager.runtimeStatus()
        } catch {
            errorMessage = "停止后台任务失败。"
        }
    }

    @Published private(set) var isVerifying = false

    func verifyDatabase() async {
        guard !isVerifying else { return }
        isVerifying = true
        defer { isVerifying = false }
        do {
            inspectionSnapshot = try await inspectionService.loadSnapshot()
        } catch {
            errorMessage = "无法完成数据库检查。请先运行一次磁盘检查以恢复未完成的写入，再重试。"
        }
    }

    func copySanitizedDiagnostics() async {
        do {
            let text = try await inspectionService.sanitizedDiagnostics()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            actionMessage = "脱敏诊断已复制。"
        } catch {
            errorMessage = "无法生成诊断信息。"
        }
    }

    func openDataDirectory() {
        NSWorkspace.shared.open(dataResetter.dataRootURL)
    }

    func resetHistory() async {
        guard !scanState.isActive else {
            errorMessage = "请先等待或停止当前扫描。"
            return
        }
        do {
            guard let controlStore else {
                throw DailyDiskDataResetError.unsafeRoot
            }
            launchAgentStatus = await launchAgentManager.status()
            if launchAgentStatus == .enabled || launchAgentStatus == .requiresApproval {
                try await launchAgentManager.unregister()
                launchAgentStatus = await launchAgentManager.status()
            }
            guard launchAgentStatus == .notRegistered else {
                throw LaunchAgentManagerError.serviceUnavailable(launchAgentStatus)
            }
            var runtime = try await launchAgentManager.runtimeStatus()
            if runtime.isRunning {
                try await launchAgentManager.terminateHelper()
                repeat {
                    try await Task.sleep(for: .milliseconds(100))
                    runtime = try await launchAgentManager.runtimeStatus()
                } while runtime.isRunning
            }
            helperRuntimeStatus = runtime
            let snapshot = try await inspectionService.loadSnapshot(historyLimit: 1, verify: false)
            guard snapshot.writerState?.leaseIsHeld != true else {
                scanState = .externalWriter
                errorMessage = "另一个写入任务仍在运行。"
                return
            }
            let resetLease = try DatabaseResetLease(
                databaseURL: inspectionService.databaseURL
            )
            try await controlStore.clearInactiveState()
            try dataResetter.reset(holding: resetLease)
            inspectionSnapshot = nil
            applyReports([])
            trackedRequestID = nil
            scanState = .idle
            actionMessage = "历史、基线和本地报告已重置。"
        } catch {
            errorMessage = "安全重置未完成。"
        }
    }

    func openLoginItemsSettings() { LaunchAgentManager.openLoginItemsSettings() }

    func openLatestReport() {
        guard let report = latestReport else { return }
        let directory = LocalReportWriter.defaultReportDirectory
            .appendingPathComponent(report.runID.rawValue.uuidString, isDirectory: true)
        NSWorkspace.shared.open(directory)
    }

    var monitoredVolumes: [MonitoredVolume] {
        topology?.volumes.filter { $0.inventoryMode == .full } ?? []
    }

    var metricsOnlyVolumes: [MonitoredVolume] {
        topology?.volumes.filter { $0.inventoryMode == .metricsOnly } ?? []
    }

    private func ensureOutstandingRequestIsStarted() async {
        guard let controlStore, launchAgentStatus == .enabled else { return }
        let hasActive = (try? await controlStore.activeRequest()) != nil
        let hasPending = (try? await controlStore.pendingRequest()) != nil
        guard hasActive || hasPending else { return }
        _ = try? await launchAgentManager.startIfNeeded(controlStore: controlStore)
    }

    private func reloadInspectionAfterTerminal() async {
        guard trackedRequestID != loadedTerminalRequestID || inspectionSnapshot == nil else { return }
        do {
            let snapshot = try await inspectionService.loadSnapshot(verify: false)
            inspectionSnapshot = snapshot
            applyReports(snapshot.reports)
            if snapshot.writerState?.leaseIsHeld != true {
                loadedTerminalRequestID = trackedRequestID
            }
        } catch {
            // Keep the last known report visible if verification is temporarily unavailable.
        }
    }

    private func applyReports(_ values: [DailyReport]) {
        reports = values
        latestReport = values.first
        if let selectedReport,
            let refreshed = values.first(where: {
                $0.runID == selectedReport.runID
                    && $0.storageDomainID == selectedReport.storageDomainID
            })
        {
            self.selectedReport = refreshed
        } else {
            selectedReport = values.first
        }
    }

    private func startProgressPolling() {
        guard progressPollingTask == nil else { return }
        let interval = pollingInterval
        progressPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshScanState()
                guard self != nil else { break }
                let delay = self?.scanState.isActive == true ? interval : max(interval, .seconds(2))
                try? await Task.sleep(for: delay)
            }
            self?.progressPollingTask = nil
        }
    }
}
