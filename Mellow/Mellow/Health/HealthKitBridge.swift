import Foundation
import HealthKit

// MARK: - Models for Apple Health Data

struct HourlyStepCount: Identifiable, Equatable {
    var id: Int { hour }
    let hour: Int
    let steps: Int
    let date: Date
}

struct WatchSleepData: Identifiable, Equatable {
    let id: UUID = UUID()
    let startDate: Date
    let endDate: Date
    let timeInBedMinutes: Double
    let totalSleepMinutes: Double
    let deepMinutes: Double
    let coreMinutes: Double
    let remMinutes: Double
    let awakeMinutes: Double
    let awakeningsCount: Int
    let midpointHour: Double
    let sourceName: String
    var lowestHR: Double?
    var averageHR: Double?
    var stageIntervals: [WatchSleepStageInterval] = []
    var mellowSleepScore: SleepScoreResult?

    static func == (lhs: WatchSleepData, rhs: WatchSleepData) -> Bool {
        lhs.startDate == rhs.startDate &&
        lhs.endDate == rhs.endDate &&
        lhs.totalSleepMinutes == rhs.totalSleepMinutes &&
        lhs.timeInBedMinutes == rhs.timeInBedMinutes &&
        lhs.mellowSleepScore?.score == rhs.mellowSleepScore?.score
    }
}

struct WatchSleepStageInterval: Identifiable, Equatable {
    let id = UUID()
    let stage: WatchSleepStage
    let startDate: Date
    let endDate: Date
    var durationMinutes: Double {
        max(0, endDate.timeIntervalSince(startDate) / 60.0)
    }
}

enum WatchSleepStage: String, CaseIterable, Equatable, Codable {
    case deep = "Deep"
    case core = "Core"
    case rem = "REM"
    case awake = "Awake"
    case inBed = "In Bed"
}

// MARK: - HealthKitBridge

@MainActor
final class HealthKitBridge: ObservableObject {

    static let readEnabledKey = "mellow.healthReadEnabled"
    static let exportEnabledKey = "mellow.healthExportEnabled"

    private let store = HKHealthStore()

    // MARK: - Read from Health State

    @Published var readEnabled: Bool {
        didSet {
            guard oldValue != readEnabled else { return }
            UserDefaults.standard.set(readEnabled, forKey: Self.readEnabledKey)
            if readEnabled {
                Task { await fetchAllReadData() }
            }
        }
    }
    @Published private(set) var isReadAuthorized: Bool = false
    @Published var isReadingHealth: Bool = false

    @Published var latestWatchSleep: WatchSleepData?
    @Published var todaySteps: Int = 0
    @Published var watchTodaySteps: Int = 0
    @Published var phoneTodaySteps: Int = 0
    @Published var todayHourlySteps: [HourlyStepCount] = []
    @Published var watchHeartRateHistory: [RingStore.Sample] = []
    @Published var watchTemperatureHistory: [RingStore.Sample] = []

    // MARK: - Write to Health State

    @Published var exportEnabled: Bool {
        didSet {
            guard oldValue != exportEnabled else { return }
            UserDefaults.standard.set(exportEnabled, forKey: Self.exportEnabledKey)
        }
    }
    @Published private(set) var isWriteAuthorized: Bool = false

    @Published var lastError: String?

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    var isExporting: Bool { isAvailable && exportEnabled && isWriteAuthorized }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.readEnabledKey) == nil {
            readEnabled = true
        } else {
            readEnabled = defaults.bool(forKey: Self.readEnabledKey)
        }

        if defaults.object(forKey: Self.exportEnabledKey) == nil {
            exportEnabled = false
        } else {
            exportEnabled = defaults.bool(forKey: Self.exportEnabledKey)
        }

        refreshWriteAuthorizationStatus()

        if readEnabled {
            Task { [weak self] in
                await self?.requestReadAuthorization()
            }
        }
    }

    // MARK: - HealthKit Types

    private var heartRateType: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: .heartRate)
    }
    private var hrvType: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
    }
    private var spo2Type: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)
    }
    private var bodyTempType: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: .bodyTemperature)
    }
    private var wristTempType: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: .appleSleepingWristTemperature)
    }
    private var stepCountType: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: .stepCount)
    }
    private var sleepAnalysisType: HKCategoryType? {
        HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)
    }

    private var writeTypes: Set<HKSampleType> {
        var s = Set<HKSampleType>()
        if let t = heartRateType { s.insert(t) }
        if let t = hrvType { s.insert(t) }
        if let t = spo2Type { s.insert(t) }
        if let t = bodyTempType { s.insert(t) }
        return s
    }

    private var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>()
        if let t = sleepAnalysisType { s.insert(t) }
        if let t = stepCountType { s.insert(t) }
        if let t = heartRateType { s.insert(t) }
        if let t = wristTempType { s.insert(t) }
        if let t = bodyTempType { s.insert(t) }
        return s
    }

    // MARK: - Separate Authorization

    func requestReadAuthorization() async {
        guard isAvailable else {
            lastError = "Apple Health is not available on this device."
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            lastError = nil
            isReadAuthorized = true
            await fetchAllReadData()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func requestWriteAuthorization() async {
        guard isAvailable else {
            lastError = "Apple Health is not available on this device."
            return
        }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: [])
            lastError = nil
            refreshWriteAuthorizationStatus()
        } catch {
            lastError = error.localizedDescription
            refreshWriteAuthorizationStatus()
        }
    }

    func refreshWriteAuthorizationStatus() {
        guard isAvailable else {
            isWriteAuthorized = false
            return
        }
        let granted = writeTypes.contains { store.authorizationStatus(for: $0) == .sharingAuthorized }
        isWriteAuthorized = granted
    }

    // MARK: - Bulk Read Dispatcher

    func fetchAllReadData() async {
        guard isAvailable, readEnabled else { return }
        isReadingHealth = true
        defer { isReadingHealth = false }

        async let sleepTask: () = fetchLatestSleep()
        async let stepsTask: () = fetchTodaySteps()
        async let hrTask: () = fetchWatchHeartRate()
        async let tempTask: () = fetchWatchTemperature()

        _ = await (sleepTask, stepsTask, hrTask, tempTask)
    }

    // MARK: - Step Count Ingestion

    func fetchTodaySteps() async {
        guard isAvailable, readEnabled, let stepType = stepCountType else { return }

        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: now, options: [])

        // 1. Total steps today via cumulative sum
        let total: Int = await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: stepType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
                let count = stats?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                continuation.resume(returning: Int(count))
            }
            self.store.execute(query)
        }

        // 2. Hourly breakdown
        var interval = DateComponents()
        interval.hour = 1

        let hourly: [HourlyStepCount] = await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: stepType,
                                                    quantitySamplePredicate: predicate,
                                                    options: .cumulativeSum,
                                                    anchorDate: startOfDay,
                                                    intervalComponents: interval)
            query.initialResultsHandler = { _, results, _ in
                guard let results else {
                    continuation.resume(returning: [])
                    return
                }
                var buckets: [HourlyStepCount] = []
                results.enumerateStatistics(from: startOfDay, to: now) { stats, _ in
                    let stepCount = Int(stats.sumQuantity()?.doubleValue(for: .count()) ?? 0)
                    let hour = cal.component(.hour, from: stats.startDate)
                    buckets.append(HourlyStepCount(hour: hour, steps: stepCount, date: stats.startDate))
                }
                continuation.resume(returning: buckets)
            }
            self.store.execute(query)
        }

        // 3. Separate Watch samples vs other sources
        let (watchSum, phoneSum): (Int, Int) = await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let sampleQuery = HKSampleQuery(sampleType: stepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, rawSamples, _ in
                guard let qSamples = rawSamples as? [HKQuantitySample], !qSamples.isEmpty else {
                    continuation.resume(returning: (0, 0))
                    return
                }
                var w: Double = 0
                var p: Double = 0
                for s in qSamples {
                    let count = s.quantity.doubleValue(for: .count())
                    let src = s.sourceRevision.source.name.lowercased()
                    let prod = s.sourceRevision.productType?.lowercased() ?? ""
                    if src.contains("watch") || prod.contains("watch") {
                        w += count
                    } else {
                        p += count
                    }
                }
                continuation.resume(returning: (Int(w), Int(p)))
            }
            self.store.execute(sampleQuery)
        }

        let hourlySum = hourly.reduce(0) { $0 + $1.steps }
        let finalTotal = total > 0 ? total : (hourlySum > 0 ? hourlySum : (watchSum + phoneSum))

        self.todaySteps = finalTotal
        self.watchTodaySteps = watchSum
        self.phoneTodaySteps = phoneSum
        self.todayHourlySteps = hourly

        if finalTotal > 0 || !hourly.isEmpty || watchSum > 0 {
            self.isReadAuthorized = true
        }
    }

    // MARK: - Watch Heart Rate Ingestion

    func fetchWatchHeartRate() async {
        guard isAvailable, readEnabled, let hrType = heartRateType else { return }

        let now = Date()
        let lookback = Calendar.current.date(byAdding: .hour, value: -36, to: now) ?? now.addingTimeInterval(-36 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: lookback, end: now, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let unit = HKUnit.count().unitDivided(by: .minute())

        let samples: [RingStore.Sample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: hrType,
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [sort]) { _, rawSamples, _ in
                guard let qSamples = rawSamples as? [HKQuantitySample], !qSamples.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                // Filter for Apple Watch source
                let watchSamples = qSamples.filter {
                    let src = $0.sourceRevision.source.name.lowercased()
                    let prod = $0.sourceRevision.productType?.lowercased() ?? ""
                    return src.contains("watch") || prod.contains("watch")
                }
                let list = watchSamples.isEmpty ? qSamples : watchSamples
                let converted = list.map {
                    RingStore.Sample(
                        timeMs: UInt64($0.startDate.timeIntervalSince1970 * 1000),
                        value: $0.quantity.doubleValue(for: unit),
                        ringTime: 0,
                        timeResolved: true
                    )
                }
                continuation.resume(returning: converted)
            }
            self.store.execute(query)
        }

        self.watchHeartRateHistory = samples
        if !samples.isEmpty { self.isReadAuthorized = true }
    }

    // MARK: - Watch Temperature Ingestion

    func fetchWatchTemperature() async {
        guard isAvailable, readEnabled else { return }

        let now = Date()
        let lookback = Calendar.current.date(byAdding: .hour, value: -48, to: now) ?? now.addingTimeInterval(-48 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: lookback, end: now, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let unit = HKUnit.degreeCelsius()

        // Try sleeping wrist temperature first (Series 8+), fallback to bodyTemperature
        let targetType = wristTempType ?? bodyTempType
        guard let target = targetType else { return }

        let samples: [RingStore.Sample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: target,
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [sort]) { _, rawSamples, _ in
                guard let qSamples = rawSamples as? [HKQuantitySample], !qSamples.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                let converted = qSamples.map {
                    RingStore.Sample(
                        timeMs: UInt64($0.startDate.timeIntervalSince1970 * 1000),
                        value: $0.quantity.doubleValue(for: unit),
                        ringTime: 0,
                        timeResolved: true
                    )
                }
                continuation.resume(returning: converted)
            }
            self.store.execute(query)
        }

        self.watchTemperatureHistory = samples
    }

    // MARK: - Reading Sleep from Apple Health

    func fetchLatestSleep() async {
        guard isAvailable, readEnabled, let sleepType = sleepAnalysisType else { return }

        let now = Date()
        let lookback = Calendar.current.date(byAdding: .hour, value: -48, to: now) ?? now.addingTimeInterval(-48 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: lookback, end: now, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        do {
            let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(sampleType: sleepType,
                                          predicate: predicate,
                                          limit: HKObjectQueryNoLimit,
                                          sortDescriptors: [sort]) { _, result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (result as? [HKCategorySample]) ?? [])
                    }
                }
                self.store.execute(query)
            }

            guard !samples.isEmpty else { return }
            self.isReadAuthorized = true

            if let processed = await processSleepSamples(samples) {
                self.latestWatchSleep = processed
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func processSleepSamples(_ samples: [HKCategorySample]) async -> WatchSleepData? {
        guard !samples.isEmpty else { return nil }

        let sorted = samples.sorted { $0.startDate < $1.startDate }

        // Group into sessions: gap of > 3 hours marks a boundary between nights
        var sessions: [[HKCategorySample]] = []
        var currentSession: [HKCategorySample] = []

        for sample in sorted {
            if let last = currentSession.last {
                if sample.startDate.timeIntervalSince(last.endDate) > 3 * 3600 {
                    sessions.append(currentSession)
                    currentSession = [sample]
                } else {
                    currentSession.append(sample)
                }
            } else {
                currentSession.append(sample)
            }
        }
        if !currentSession.isEmpty {
            sessions.append(currentSession)
        }

        guard let latestSession = sessions.last, !latestSession.isEmpty else { return nil }

        let watchSamples = latestSession.filter {
            let src = $0.sourceRevision.source.name.lowercased()
            let prod = $0.sourceRevision.productType?.lowercased() ?? ""
            return src.contains("watch") || prod.contains("watch")
        }
        let samplesToUse = watchSamples.isEmpty ? latestSession : watchSamples
        let sourceName = samplesToUse.first?.sourceRevision.source.name ?? "Apple Watch"

        var deepMin: Double = 0
        var coreMin: Double = 0
        var remMin: Double = 0
        var awakeMin: Double = 0
        var inBedMin: Double = 0
        var intervals: [WatchSleepStageInterval] = []

        for s in samplesToUse {
            let dur = max(0, s.endDate.timeIntervalSince(s.startDate) / 60.0)
            switch s.value {
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                deepMin += dur
                intervals.append(WatchSleepStageInterval(stage: .deep, startDate: s.startDate, endDate: s.endDate))
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                 HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                coreMin += dur
                intervals.append(WatchSleepStageInterval(stage: .core, startDate: s.startDate, endDate: s.endDate))
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                remMin += dur
                intervals.append(WatchSleepStageInterval(stage: .rem, startDate: s.startDate, endDate: s.endDate))
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                awakeMin += dur
                intervals.append(WatchSleepStageInterval(stage: .awake, startDate: s.startDate, endDate: s.endDate))
            case HKCategoryValueSleepAnalysis.inBed.rawValue:
                inBedMin += dur
            default:
                break
            }
        }

        let sleepIntervals = intervals.filter { $0.stage != .awake && $0.stage != .inBed }
        let sessionStart = sleepIntervals.map(\.startDate).min() ?? samplesToUse.map(\.startDate).min()!
        let sessionEnd = sleepIntervals.map(\.endDate).max() ?? samplesToUse.map(\.endDate).max()!
        let totalSleepMin = deepMin + coreMin + remMin
        let inBedCalculated = inBedMin > totalSleepMin ? inBedMin : (totalSleepMin + awakeMin)
        let effectiveInBedMin = max(inBedCalculated, sessionEnd.timeIntervalSince(sessionStart) / 60.0)

        let awakenings = intervals.filter { $0.stage == .awake && $0.startDate >= sessionStart && $0.endDate <= sessionEnd }.count

        let midDate = Date(timeIntervalSince1970: (sessionStart.timeIntervalSince1970 + sessionEnd.timeIntervalSince1970) / 2.0)
        let cal = Calendar.current
        let midpointHour = Double(cal.component(.hour, from: midDate)) + Double(cal.component(.minute, from: midDate)) / 60.0

        let hrSummary = await fetchHeartRateSummary(startDate: sessionStart, endDate: sessionEnd)

        let scoreResult = MetricsEngine.sleepScore(
            totalSleepMin: totalSleepMin,
            timeInBedMin: effectiveInBedMin,
            remMin: remMin,
            deepMin: deepMin,
            latencyMin: nil,
            awakenings: awakenings,
            midpointHour: midpointHour
        )

        return WatchSleepData(
            startDate: sessionStart,
            endDate: sessionEnd,
            timeInBedMinutes: effectiveInBedMin,
            totalSleepMinutes: totalSleepMin,
            deepMinutes: deepMin,
            coreMinutes: coreMin,
            remMinutes: remMin,
            awakeMinutes: awakeMin,
            awakeningsCount: awakenings,
            midpointHour: midpointHour,
            sourceName: sourceName,
            lowestHR: hrSummary.lowest,
            averageHR: hrSummary.average,
            stageIntervals: intervals,
            mellowSleepScore: scoreResult
        )
    }

    private func fetchHeartRateSummary(startDate: Date, endDate: Date) async -> (lowest: Double?, average: Double?) {
        guard let hrType = heartRateType else { return (nil, nil) }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [])
        let unit = HKUnit.count().unitDivided(by: .minute())

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: hrType,
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, samples, _ in
                guard let qSamples = samples as? [HKQuantitySample], !qSamples.isEmpty else {
                    continuation.resume(returning: (nil, nil))
                    return
                }
                let values = qSamples.map { $0.quantity.doubleValue(for: unit) }
                let lowest = values.min()
                let avg = values.reduce(0.0, +) / Double(values.count)
                continuation.resume(returning: (lowest, avg))
            }
            self.store.execute(query)
        }
    }

    // MARK: - Saving Samples (Write to Health)

    func saveHeartRate(_ bpm: Double, date: Date) {
        guard isExporting, bpm > 20, bpm < 250, let type = heartRateType else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        save(type: type, quantity: HKQuantity(unit: unit, doubleValue: bpm), date: date)
    }

    func saveHRV(_ rmssdMs: Int, date: Date) {
        guard isExporting, rmssdMs > 0, rmssdMs < 500, let type = hrvType else { return }
        save(type: type,
             quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: Double(rmssdMs)),
             date: date)
    }

    func saveSpO2(_ percent: Int, date: Date) {
        guard isExporting, percent > 50, percent <= 100, let type = spo2Type else { return }
        save(type: type,
             quantity: HKQuantity(unit: .percent(), doubleValue: Double(percent) / 100.0),
             date: date)
    }

    func saveBodyTemp(_ celsius: Double, date: Date) {
        guard isExporting, celsius > 25, celsius < 45, let type = bodyTempType else { return }
        save(type: type,
             quantity: HKQuantity(unit: .degreeCelsius(), doubleValue: celsius),
             date: date)
    }

    private func save(type: HKQuantityType, quantity: HKQuantity, date: Date) {
        let sample = HKQuantitySample(type: type, quantity: quantity, start: date, end: date)
        store.save(sample) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.lastError = error.localizedDescription }
        }
    }
}
