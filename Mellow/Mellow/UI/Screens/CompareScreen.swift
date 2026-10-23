import SwiftUI
import Charts

// MARK: - CompareScreen (Algorithm Tuning & Cross-Device Comparison)

struct CompareScreen: View {
    @EnvironmentObject var health: HealthKitBridge
    @EnvironmentObject var store: RingStore
    @EnvironmentObject var session: RingSession
    @EnvironmentObject var metrics: MetricsStore

    enum TimeScope: String, CaseIterable {
        case overnight = "Overnight"
        case fullDay = "Full Day"
    }

    @State private var timeScope: TimeScope = .overnight
    @State private var isRefreshing = false

    private var watchSleep: WatchSleepData? { health.latestWatchSleep }
    private var ringNight: RingStore.SleepNight? { store.latestSleepNight }

    // Active night window for overnight comparison
    private var nightWindow: ClosedRange<Date>? {
        if let w = watchSleep { return w.startDate...w.endDate }
        if let s = store.sleepStartDate, let e = store.sleepEndDate, e > s { return s...e }
        if let n = ringNight, let s = n.startMs, let e = n.endMs, e > s {
            return Date(timeIntervalSince1970: Double(s) / 1000.0)...Date(timeIntervalSince1970: Double(e) / 1000.0)
        }
        return nil
    }

    // Filtered Heart Rate samples based on scope
    private var ringHRSamples: [RingStore.Sample] {
        switch timeScope {
        case .overnight:
            guard let w = nightWindow else { return store.hrHistorySmoothed }
            return store.hrHistorySmoothed.filter { w.contains($0.date) }
        case .fullDay:
            let startOfDay = Calendar.current.startOfDay(for: Date())
            return store.hrHistorySmoothed.filter { $0.date >= startOfDay }
        }
    }

    private var watchHRSamples: [RingStore.Sample] {
        switch timeScope {
        case .overnight:
            guard let w = nightWindow else { return health.watchHeartRateHistory }
            return health.watchHeartRateHistory.filter { w.contains($0.date) }
        case .fullDay:
            let startOfDay = Calendar.current.startOfDay(for: Date())
            return health.watchHeartRateHistory.filter { $0.date >= startOfDay }
        }
    }

    // Filtered Temperature samples based on scope
    private var ringTempSamples: [RingStore.Sample] {
        switch timeScope {
        case .overnight:
            guard let w = nightWindow else { return store.tempHistory }
            return store.tempHistory.filter { w.contains($0.date) }
        case .fullDay:
            let startOfDay = Calendar.current.startOfDay(for: Date())
            return store.tempHistory.filter { $0.date >= startOfDay }
        }
    }

    private var watchTempSamples: [RingStore.Sample] {
        switch timeScope {
        case .overnight:
            guard let w = nightWindow else { return health.watchTemperatureHistory }
            return health.watchTemperatureHistory.filter { w.contains($0.date) }
        case .fullDay:
            let startOfDay = Calendar.current.startOfDay(for: Date())
            return health.watchTemperatureHistory.filter { $0.date >= startOfDay }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: MellowTheme.Spacing.lg) {
                headerControlCard
                sleepAlignmentCard
                heartRateComparisonCard
                temperatureComparisonCard
                stepsComparisonCard
                algorithmTuningCard
            }
            .padding(.horizontal, MellowTheme.Spacing.lg)
            .padding(.top, MellowTheme.Spacing.sm)
            .padding(.bottom, MellowTheme.Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .mellowScreenBackground()
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if health.readEnabled && !health.isReadAuthorized {
                await health.requestReadAuthorization()
            }
            await health.fetchAllReadData()
            store.recomputeStepsAndHypnogram()
        }
        .refreshable {
            await refreshAll()
        }
    }

    // MARK: - Header Controls

    private var headerControlCard: some View {
        SurfaceCard(padding: MellowTheme.Spacing.sm) {
            VStack(spacing: 8) {
                HStack {
                    Picker("Scope", selection: $timeScope) {
                        ForEach(TimeScope.allCases, id: \.self) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)

                    Spacer()

                    Button {
                        Task { await refreshAll() }
                    } label: {
                        HStack(spacing: 4) {
                            if isRefreshing {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            Text("Sync All")
                                .font(.mellowLabel)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(MellowTheme.accent)
                    }
                }

                HStack {
                    HStack(spacing: 4) {
                        Circle().fill(Color.purple).frame(width: 8, height: 8)
                        Text("Oura Ring 4")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(MellowTheme.textPrimary)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Circle().fill(Color.blue).frame(width: 8, height: 8)
                        Text("Apple Watch")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(MellowTheme.textPrimary)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Sleep Alignment Card

    private var sleepAlignmentCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                let agreement: Double? = {
                    guard let hypno = store.synthesizedHypnogram, let watch = watchSleep else { return nil }
                    return SleepHypnogramClassifier.computeAgreement(ringStages: hypno.stages, watchStages: watch.stageIntervals)
                }()

                SectionHeader(
                    title: "Sleep Detection Alignment",
                    subtitle: "Synchronized timeline: what each device detected"
                ) {
                    if let agr = agreement {
                        Chip(text: "\(Int(agr.rounded()))% MATCH", icon: "checkmark.seal.fill", tint: MellowTheme.good)
                    } else {
                        Chip(text: "ALIGNMENT", tint: MellowTheme.accent)
                    }
                }

                if let w = nightWindow {
                    // Shared time ruler
                    HStack {
                        Text(Self.timeFormatter.string(from: w.lowerBound))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(MellowTheme.textTertiary)
                        Spacer()
                        let mid = Date(timeIntervalSince1970: (w.lowerBound.timeIntervalSince1970 + w.upperBound.timeIntervalSince1970) / 2)
                        Text(Self.timeFormatter.string(from: mid))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(MellowTheme.textTertiary)
                        Spacer()
                        Text(Self.timeFormatter.string(from: w.upperBound))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(MellowTheme.textTertiary)
                    }

                    // Track 1: Apple Watch
                    if let watch = watchSleep {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: "applewatch")
                                    .font(.system(size: 11))
                                    .foregroundColor(.blue)
                                Text("APPLE WATCH HYPNOGRAM")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(MellowTheme.textSecondary)
                                Spacer()
                                Text(StageBar.formatMinutes(watch.totalSleepMinutes))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(MellowTheme.textPrimary)
                            }
                            StageBar(stages: [
                                Stage(label: "Deep", minutes: watch.deepMinutes, color: MellowTheme.spo2),
                                Stage(label: "Core", minutes: watch.coreMinutes, color: MellowTheme.sleep),
                                Stage(label: "REM", minutes: watch.remMinutes, color: MellowTheme.temperature),
                                Stage(label: "Awake", minutes: watch.awakeMinutes, color: MellowTheme.textTertiary)
                            ], height: 16)
                        }
                    }

                    // Track 2: Oura Ring
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: "circle.circle")
                                .font(.system(size: 11))
                                .foregroundColor(.purple)
                            Text("OURA RING 4 (SYNTHESIZED FROM MOTION + HR)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(MellowTheme.textSecondary)
                            Spacer()
                            if let hypno = store.synthesizedHypnogram, hypno.totalSleepMinutes > 0 {
                                Text(StageBar.formatMinutes(hypno.totalSleepMinutes))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(MellowTheme.textPrimary)
                            } else if let n = ringNight {
                                Text(StageBar.formatMinutes(n.asleepMin))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(MellowTheme.textPrimary)
                            }
                        }

                        if let hypno = store.synthesizedHypnogram, hypno.totalSleepMinutes > 0 {
                            StageBar(stages: [
                                Stage(label: "Deep", minutes: hypno.deepMinutes, color: MellowTheme.spo2),
                                Stage(label: "Core", minutes: hypno.coreMinutes, color: MellowTheme.sleep),
                                Stage(label: "REM", minutes: hypno.remMinutes, color: MellowTheme.temperature),
                                Stage(label: "Awake", minutes: hypno.awakeMinutes, color: MellowTheme.textTertiary)
                            ], height: 16)
                        } else if let n = ringNight, n.asleepMin > 0 {
                            StageBar(stages: [
                                Stage(label: "Deep", minutes: n.deepMin, color: MellowTheme.spo2),
                                Stage(label: "Light/REM", minutes: n.lightRemMin, color: MellowTheme.sleep),
                                Stage(label: "Awake", minutes: n.wakeMin, color: MellowTheme.textTertiary)
                            ], height: 16)
                        } else {
                            // In-bed span fallback
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.purple.opacity(0.8))
                                .frame(height: 16)
                                .overlay(
                                    Text("In-Bed Tracked (Optical HR / Temp active)")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(.white)
                                )
                        }
                    }

                    Divider().background(MellowTheme.stroke)

                    // Side-by-side metric comparison table
                    VStack(spacing: 8) {
                        if let watch = watchSleep {
                            let ringMins = store.synthesizedHypnogram?.totalSleepMinutes
                                ?? ringNight?.asleepMin
                                ?? Double(Int(w.upperBound.timeIntervalSince(w.lowerBound) / 60))
                            metricComparisonRow(
                                title: "Total Sleep",
                                ringVal: StageBar.formatMinutes(ringMins),
                                watchVal: StageBar.formatMinutes(watch.totalSleepMinutes),
                                delta: "\(Int(ringMins - watch.totalSleepMinutes))m"
                            )

                            let ringInBed = store.synthesizedHypnogram?.timeInBedMinutes
                                ?? ringNight?.inBedMin
                                ?? Double(Int(w.upperBound.timeIntervalSince(w.lowerBound) / 60))
                            metricComparisonRow(
                                title: "Time in Bed",
                                ringVal: StageBar.formatMinutes(ringInBed),
                                watchVal: StageBar.formatMinutes(watch.timeInBedMinutes),
                                delta: "\(Int(ringInBed - watch.timeInBedMinutes))m"
                            )

                            let ringDeep = store.synthesizedHypnogram?.deepMinutes ?? ringNight?.deepMin
                            metricComparisonRow(
                                title: "Deep Sleep",
                                ringVal: ringDeep.map { StageBar.formatMinutes($0) } ?? "—",
                                watchVal: StageBar.formatMinutes(watch.deepMinutes),
                                delta: ringDeep.map { "\(Int($0 - watch.deepMinutes))m" } ?? "—"
                            )

                            let ringRem = store.synthesizedHypnogram?.remMinutes
                            metricComparisonRow(
                                title: "REM Sleep",
                                ringVal: ringRem.map { StageBar.formatMinutes($0) } ?? "—",
                                watchVal: StageBar.formatMinutes(watch.remMinutes),
                                delta: ringRem.map { "\(Int($0 - watch.remMinutes))m" } ?? "—"
                            )

                            let ringAwake = store.synthesizedHypnogram?.awakeMinutes ?? ringNight?.wakeMin
                            metricComparisonRow(
                                title: "Awake Time",
                                ringVal: ringAwake.map { StageBar.formatMinutes($0) } ?? "—",
                                watchVal: StageBar.formatMinutes(watch.awakeMinutes),
                                delta: ringAwake.map { "\(Int($0 - watch.awakeMinutes))m" } ?? "—"
                            )

                            let ringEff = store.synthesizedHypnogram?.sleepEfficiency
                            metricComparisonRow(
                                title: "Sleep Efficiency",
                                ringVal: ringEff.map { "\(Int($0.rounded()))%" } ?? "—",
                                watchVal: "\(Int(((watch.totalSleepMinutes / max(1, watch.timeInBedMinutes)) * 100).rounded()))%",
                                delta: ringEff.map { "\(Int($0.rounded()) - Int(((watch.totalSleepMinutes / max(1, watch.timeInBedMinutes)) * 100).rounded()))%" } ?? "—"
                            )
                        }
                    }
                } else {
                    Text("No night window detected. Pull down to sync both devices.")
                        .font(.mellowCaption)
                        .foregroundColor(MellowTheme.textTertiary)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private func metricComparisonRow(title: String, ringVal: String, watchVal: String, delta: String) -> some View {
        HStack {
            Text(title)
                .font(.mellowBody)
                .foregroundColor(MellowTheme.textPrimary)
            Spacer()
            HStack(spacing: 12) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ringVal)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.purple)
                    Text("Ring")
                        .font(.system(size: 9))
                        .foregroundColor(MellowTheme.textTertiary)
                }

                VStack(alignment: .trailing, spacing: 1) {
                    Text(watchVal)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.blue)
                    Text("Watch")
                        .font(.system(size: 9))
                        .foregroundColor(MellowTheme.textTertiary)
                }

                Text("(\(delta))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(MellowTheme.textSecondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Heart Rate Comparison Card

    private var heartRateComparisonCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(
                    title: "Heart Rate Comparison",
                    subtitle: "\(timeScope.rawValue) · Ring (Purple) vs. Watch (Blue)"
                ) {
                    let rLow = ringHRSamples.map(\.value).min()
                    let wLow = watchHRSamples.map(\.value).min()
                    if let r = rLow, let w = wLow {
                        Chip(text: "Δ \(Int(abs(r - w))) bpm", tint: MellowTheme.heartRate)
                    }
                }

                if ringHRSamples.isEmpty && watchHRSamples.isEmpty {
                    Text("No heart rate samples logged for \(timeScope.rawValue.lowercased()).")
                        .font(.mellowCaption)
                        .foregroundColor(MellowTheme.textTertiary)
                        .frame(height: 120)
                } else {
                    Chart {
                        ForEach(ringHRSamples) { sample in
                            LineMark(
                                x: .value("Time", sample.date),
                                y: .value("HR", sample.value),
                                series: .value("Device", "Ring")
                            )
                            .foregroundStyle(Color.purple)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }

                        ForEach(watchHRSamples) { sample in
                            LineMark(
                                x: .value("Time", sample.date),
                                y: .value("HR", sample.value),
                                series: .value("Device", "Watch")
                            )
                            .foregroundStyle(Color.blue)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { val in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2])).foregroundStyle(MellowTheme.stroke)
                            AxisValueLabel {
                                if let v = val.as(Double.self) {
                                    Text("\(Int(v))").font(.system(size: 9)).foregroundColor(MellowTheme.textTertiary)
                                }
                            }
                        }
                    }
                    .frame(height: 170)

                    // Stats row
                    HStack(spacing: MellowTheme.Spacing.md) {
                        deviceHRStat(
                            title: "Ring Lowest",
                            val: ringHRSamples.map(\.value).min().map { "\(Int($0)) bpm" } ?? "—",
                            tint: .purple
                        )
                        deviceHRStat(
                            title: "Watch Lowest",
                            val: watchHRSamples.map(\.value).min().map { "\(Int($0)) bpm" } ?? "—",
                            tint: .blue
                        )
                        deviceHRStat(
                            title: "Ring Avg",
                            val: ringHRSamples.isEmpty ? "—" : "\(Int(ringHRSamples.map(\.value).reduce(0, +) / Double(ringHRSamples.count))) bpm",
                            tint: .purple
                        )
                        deviceHRStat(
                            title: "Watch Avg",
                            val: watchHRSamples.isEmpty ? "—" : "\(Int(watchHRSamples.map(\.value).reduce(0, +) / Double(watchHRSamples.count))) bpm",
                            tint: .blue
                        )
                    }
                }
            }
        }
    }

    private func deviceHRStat(title: String, val: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(MellowTheme.textTertiary)
            Text(val)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(MellowTheme.fill))
    }

    // MARK: - Temperature Comparison Card

    private var temperatureComparisonCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(
                    title: "Temperature Comparison",
                    subtitle: "\(timeScope.rawValue) · Ring Skin Temp vs. Watch Wrist Temp"
                )

                if ringTempSamples.isEmpty && watchTempSamples.isEmpty {
                    Text("No temperature samples logged for \(timeScope.rawValue.lowercased()).")
                        .font(.mellowCaption)
                        .foregroundColor(MellowTheme.textTertiary)
                        .frame(height: 100)
                } else {
                    Chart {
                        ForEach(ringTempSamples) { sample in
                            LineMark(
                                x: .value("Time", sample.date),
                                y: .value("Temp", sample.value),
                                series: .value("Device", "Ring")
                            )
                            .foregroundStyle(Color.purple)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }

                        ForEach(watchTempSamples) { sample in
                            LineMark(
                                x: .value("Time", sample.date),
                                y: .value("Temp", sample.value),
                                series: .value("Device", "Watch")
                            )
                            .foregroundStyle(Color.blue)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { val in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2])).foregroundStyle(MellowTheme.stroke)
                            AxisValueLabel {
                                if let v = val.as(Double.self) {
                                    Text(String(format: "%.1f°", v)).font(.system(size: 9)).foregroundColor(MellowTheme.textTertiary)
                                }
                            }
                        }
                    }
                    .frame(height: 150)

                    HStack(spacing: MellowTheme.Spacing.md) {
                        if let rMin = ringTempSamples.map(\.value).min(), let rMax = ringTempSamples.map(\.value).max() {
                            Text("Ring: \(String(format: "%.1f–%.1f °C", rMin, rMax))")
                                .font(.mellowLabel)
                                .foregroundColor(.purple)
                        }
                        Spacer()
                        if let wMin = watchTempSamples.map(\.value).min(), let wMax = watchTempSamples.map(\.value).max() {
                            Text("Watch: \(String(format: "%.1f–%.1f °C", wMin, wMax))")
                                .font(.mellowLabel)
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Steps Comparison Card

    private var stepsComparisonCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(title: "Activity / Steps Comparison", subtitle: "Today's tally across sensors")

                HStack(spacing: MellowTheme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("OURA RING 4")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.purple)
                        if let steps = store.stepsToday {
                            Text("\(steps.formatted())")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(MellowTheme.textPrimary)
                            Text("\(store.movementHistory.count) 30s epochs")
                                .font(.system(size: 10))
                                .foregroundColor(MellowTheme.textTertiary)
                        } else {
                            Text("—")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(MellowTheme.textSecondary)
                            Text(store.movementHistory.isEmpty ? "Sync ring to tally" : "Analyzing \(store.movementHistory.count) epochs")
                                .font(.system(size: 10))
                                .foregroundColor(MellowTheme.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("APPLE WATCH")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.blue)
                        let watchOrAll = health.watchTodaySteps > 0 ? health.watchTodaySteps : health.todaySteps
                        Text("\(watchOrAll.formatted())")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(MellowTheme.textPrimary)
                        if health.phoneTodaySteps > 0 && health.watchTodaySteps > 0 {
                            Text("Watch \(health.watchTodaySteps.formatted()) · Phone \(health.phoneTodaySteps.formatted())")
                                .font(.system(size: 10))
                                .foregroundColor(MellowTheme.textTertiary)
                        } else if !health.isReadAuthorized {
                            Text("Health permission needed")
                                .font(.system(size: 10))
                                .foregroundColor(MellowTheme.warning)
                        } else {
                            Text("From HealthKit")
                                .font(.system(size: 10))
                                .foregroundColor(MellowTheme.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Algorithm Tuning Card

    private var algorithmTuningCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(
                    title: "Algorithm Tuning Breakdown",
                    subtitle: "Mellow oura_core weights evaluated on Watch data"
                )

                if let watch = watchSleep, let scoreRes = watch.mellowSleepScore {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Mellow Sleep Score")
                                .font(.mellowBody)
                                .fontWeight(.semibold)
                                .foregroundColor(MellowTheme.textPrimary)
                            Spacer()
                            Text("\(Int(scoreRes.score.rounded())) / 100")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(MellowTheme.accent)
                        }

                        tuningFactorRow(name: "Duration (30%)", score: scoreRes.duration, desc: "Target: 420m / 7h")
                        tuningFactorRow(name: "Efficiency (18%)", score: scoreRes.efficiency, desc: "Benchmark: 85%+")
                        tuningFactorRow(name: "Deep Sleep (14%)", score: scoreRes.deep, desc: "Target: 75m+")
                        tuningFactorRow(name: "REM Sleep (12%)", score: scoreRes.rem, desc: "Target: 90m+")
                        tuningFactorRow(name: "Restfulness (10%)", score: scoreRes.restfulness, desc: "Penalizes awakenings")
                        tuningFactorRow(name: "Timing (6%)", score: scoreRes.timing, desc: "Circadian ideal ~01:30 AM")
                    }
                } else {
                    Text("Sync Apple Watch sleep data to view the algorithmic breakdown.")
                        .font(.mellowCaption)
                        .foregroundColor(MellowTheme.textTertiary)
                }
            }
        }
    }

    private func tuningFactorRow(name: String, score: Double?, desc: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.mellowBody).foregroundColor(MellowTheme.textPrimary)
                Text(desc).font(.mellowLabel).foregroundColor(MellowTheme.textTertiary)
            }
            Spacer()
            Text(score.map { "\(Int($0.rounded())) pts" } ?? "—")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(MellowTheme.textSecondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func refreshAll() async {
        isRefreshing = true
        defer { isRefreshing = false }
        async let syncWatch: () = health.fetchAllReadData()
        async let syncRing: () = session.resync()
        _ = await (syncWatch, syncRing)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}
