import SwiftUI
import Charts

// MARK: - SleepScreen (Ring Sleep Analysis & Aligned Night Timeline)

struct SleepScreen: View {
    @EnvironmentObject var store: RingStore
    @EnvironmentObject var session: RingSession
    @EnvironmentObject var metrics: MetricsStore

    private var activeWindow: ClosedRange<Date>? {
        if let s = store.sleepStartDate, let e = store.sleepEndDate, e > s {
            return s...e
        }
        if let n = store.latestSleepNight, let s = n.startMs, let e = n.endMs, e > s {
            return Date(timeIntervalSince1970: Double(s) / 1000.0)...Date(timeIntervalSince1970: Double(e) / 1000.0)
        }
        return nil
    }

    private func inWindow(_ s: [RingStore.Sample]) -> [RingStore.Sample] {
        guard let w = activeWindow else { return [] }
        return s.filter { w.contains($0.date) }
    }

    private var sleepHR: [RingStore.Sample] { inWindow(store.hrHistorySmoothed) }
    private var sleepTemp: [RingStore.Sample] { inWindow(store.tempHistory) }
    private var sleepMovements: [MovementEpoch] {
        guard let w = activeWindow else { return [] }
        return store.movementHistory.filter { w.contains($0.date) }
    }
    private var sleepMovementSamples: [RingStore.Sample] {
        sleepMovements.map {
            RingStore.Sample(
                timeMs: $0.timeMs,
                value: $0.acmTotal,
                ringTime: $0.ringTime,
                timeResolved: $0.timeResolved
            )
        }
    }
    private var ringNight: RingStore.SleepNight? { store.latestSleepNight }

    private var durationString: String? {
        guard let w = activeWindow else { return nil }
        let mins = Int(w.upperBound.timeIntervalSince(w.lowerBound) / 60)
        return "\(mins / 60)h \(mins % 60)m"
    }

    private var hasData: Bool {
        store.sawSleepFlags || activeWindow != nil || ringNight != nil || !sleepHR.isEmpty || !store.movementHistory.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: MellowTheme.Spacing.lg) {
                if hasData {
                    summaryCard
                    synthesizedHypnogramCard
                    if !sleepMovementSamples.isEmpty { overnightMovementCard }
                    alignedNightTimelineCard
                    if !sleepHR.isEmpty { sleepHRCard }
                    if !sleepTemp.isEmpty { sleepTempCard }
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, MellowTheme.Spacing.lg)
            .padding(.top, MellowTheme.Spacing.sm)
            .padding(.bottom, MellowTheme.Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .mellowScreenBackground()
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await session.resync()
        }
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(
                    title: "Last night",
                    subtitle: "Recorded on ring flash memory"
                ) {
                    Chip(
                        text: store.inBed == true ? "IN BED" : "TRACKED",
                        icon: "bed.double.fill",
                        tint: MellowTheme.sleep,
                        filled: true
                    )
                }

                HStack(spacing: MellowTheme.Spacing.md) {
                    statBox("Time in bed", durationString ?? "—", "bed.double.fill", MellowTheme.sleep)
                    statBox(
                        "Low HR",
                        sleepHR.map(\.value).min().map { "\(Int($0))" } ?? "—",
                        "heart.fill",
                        MellowTheme.heartRate
                    )
                    statBox(
                        "Low temp",
                        sleepTemp.map(\.value).min().map { String(format: "%.1f", $0) } ?? "—",
                        "thermometer.medium",
                        MellowTheme.temperature
                    )
                }

                if let w = activeWindow {
                    Text("Bed \(Self.timeFormatter.string(from: w.lowerBound)) → \(Self.timeFormatter.string(from: w.upperBound))")
                        .font(.mellowLabel)
                        .foregroundColor(MellowTheme.textTertiary)
                }
            }
        }
    }

    private func statBox(_ title: String, _ value: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundColor(tint)
                Text(title.uppercased()).font(.mellowLabel).foregroundColor(MellowTheme.textTertiary).lineLimit(1)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(MellowTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MellowTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MellowTheme.Radius.md, style: .continuous)
                .fill(MellowTheme.fill.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: MellowTheme.Radius.md, style: .continuous).strokeBorder(MellowTheme.stroke, lineWidth: 1))
        )
    }

    // MARK: - Synthesized Hypnogram Card

    private var synthesizedHypnogramCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(
                    title: "Sleep Hypnogram",
                    subtitle: "On-device synthesized stages from motion energy & HR nadir"
                ) {
                    if let hypno = store.synthesizedHypnogram, hypno.totalSleepMinutes > 0 {
                        Chip(
                            text: "\(Int(hypno.sleepEfficiency.rounded()))% EFFICIENCY",
                            icon: "waveform.path.ecg",
                            tint: MellowTheme.accent,
                            filled: true
                        )
                    }
                }

                if let hypno = store.synthesizedHypnogram, hypno.totalSleepMinutes > 0 {
                    // Stage proportion bar
                    StageBar(stages: [
                        Stage(label: "Deep", minutes: hypno.deepMinutes, color: MellowTheme.spo2),
                        Stage(label: "Core", minutes: hypno.coreMinutes, color: MellowTheme.sleep),
                        Stage(label: "REM", minutes: hypno.remMinutes, color: MellowTheme.temperature),
                        Stage(label: "Awake", minutes: hypno.awakeMinutes, color: MellowTheme.textTertiary)
                    ], height: 20)

                    // Stage stats grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        stageStatPill(
                            name: "Deep",
                            mins: hypno.deepMinutes,
                            pct: hypno.deepPercent,
                            desc: "Restorative physical recovery",
                            color: MellowTheme.spo2
                        )
                        stageStatPill(
                            name: "Core / Light",
                            mins: hypno.coreMinutes,
                            pct: hypno.corePercent,
                            desc: "Baseline physiological sleep",
                            color: MellowTheme.sleep
                        )
                        stageStatPill(
                            name: "REM",
                            mins: hypno.remMinutes,
                            pct: hypno.remPercent,
                            desc: "Cognitive & memory consolidation",
                            color: MellowTheme.temperature
                        )
                        stageStatPill(
                            name: "Awake",
                            mins: hypno.awakeMinutes,
                            pct: hypno.awakePercent,
                            desc: "\(hypno.awakeningsCount) micro-awakenings",
                            color: MellowTheme.textTertiary
                        )
                    }
                } else if let n = ringNight, n.asleepMin > 0 {
                    StageBar(stages: [
                        Stage(label: "Deep", minutes: n.deepMin, color: MellowTheme.spo2),
                        Stage(label: "Light/REM", minutes: n.lightRemMin, color: MellowTheme.sleep),
                        Stage(label: "Awake", minutes: n.wakeMin, color: MellowTheme.textTertiary)
                    ], height: 18)
                } else {
                    Text("Synthesizing sleep stages from movement and heart rate epochs...")
                        .font(.mellowCaption)
                        .foregroundColor(MellowTheme.textTertiary)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func stageStatPill(name: String, mins: Double, pct: Double, desc: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(name)
                    .font(.mellowBody)
                    .fontWeight(.semibold)
                    .foregroundColor(MellowTheme.textPrimary)
                Spacer()
                Text("\(Int(pct.rounded()))%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(StageBar.formatMinutes(mins))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(MellowTheme.textPrimary)
            }
            Text(desc)
                .font(.system(size: 10))
                .foregroundColor(MellowTheme.textTertiary)
                .lineLimit(1)
        }
        .padding(MellowTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: MellowTheme.Radius.md, style: .continuous)
                .fill(MellowTheme.fill.opacity(0.4))
                .overlay(RoundedRectangle(cornerRadius: MellowTheme.Radius.md, style: .continuous).strokeBorder(MellowTheme.stroke.opacity(0.5), lineWidth: 1))
        )
    }

    // MARK: - Overnight Movement (Actigraphy) Card

    private var overnightMovementCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(
                    title: "Overnight Movement (Actigraphy)",
                    subtitle: "\(sleepMovements.count) 30s epochs · raw acceleration energy"
                ) {
                    if let maxAcm = sleepMovements.map(\.acmTotal).max() {
                        Chip(text: "Peak \(Int(maxAcm)) ACM", tint: MellowTheme.strain)
                    }
                }

                InteractiveTrendChart(
                    samples: sleepMovementSamples,
                    range: .day,
                    color: MellowTheme.strain,
                    unit: "ACM",
                    valueFormat: { "\(Int($0))" }
                )
                .frame(height: 150)

                HStack(spacing: 12) {
                    movementThresholdItem(label: "Stillness (<28)", color: MellowTheme.spo2)
                    movementThresholdItem(label: "Restless (28–75)", color: MellowTheme.sleep)
                    movementThresholdItem(label: "Active (>75)", color: MellowTheme.strain)
                }
            }
        }
    }

    private func movementThresholdItem(label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(MellowTheme.textTertiary)
        }
    }

    // MARK: - Aligned Night Timeline Card

    private var alignedNightTimelineCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(
                    title: "Night Timeline (Aligned)",
                    subtitle: "Synchronized detection throughout the night"
                )

                if let w = activeWindow {
                    // Time axis ruler
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

                    // In-bed track
                    VStack(alignment: .leading, spacing: 3) {
                        Text("BEDTIME WINDOW")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(MellowTheme.textTertiary)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(MellowTheme.sleep.opacity(0.85))
                            .frame(height: 12)
                    }

                    // Stage track (0x6a if present)
                    if let n = ringNight, n.asleepMin > 0 {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("DETECTED SLEEP STAGES (RING 0x6a)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(MellowTheme.textTertiary)
                            StageBar(stages: [
                                Stage(label: "Deep", minutes: n.deepMin, color: MellowTheme.spo2),
                                Stage(label: "Light/REM", minutes: n.lightRemMin, color: MellowTheme.sleep),
                                Stage(label: "Awake", minutes: n.wakeMin, color: MellowTheme.textTertiary)
                            ], height: 14)
                        }
                    }

                    // Aligned Events Log
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DETECTED EVENTS")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(MellowTheme.textTertiary)

                        timelineEventRow(
                            time: Self.timeFormatter.string(from: w.lowerBound),
                            title: "Bedtime detected",
                            desc: "In-bed flag activated",
                            icon: "bed.double.fill",
                            tint: MellowTheme.sleep
                        )

                        if let minSample = sleepHR.min(by: { $0.value < $1.value }) {
                            timelineEventRow(
                                time: Self.timeFormatter.string(from: minSample.date),
                                title: "Lowest heart rate reached",
                                desc: "\(Int(minSample.value)) bpm recorded by optical sensor",
                                icon: "heart.fill",
                                tint: MellowTheme.heartRate
                            )
                        }

                        if let minTemp = sleepTemp.min(by: { $0.value < $1.value }) {
                            timelineEventRow(
                                time: Self.timeFormatter.string(from: minTemp.date),
                                title: "Minimum skin temperature",
                                desc: String(format: "%.1f °C on ring thermistor", minTemp.value),
                                icon: "thermometer.medium",
                                tint: MellowTheme.temperature
                            )
                        }

                        timelineEventRow(
                            time: Self.timeFormatter.string(from: w.upperBound),
                            title: "Wake up detected",
                            desc: "Movement resumed, in-bed ended",
                            icon: "sun.max.fill",
                            tint: MellowTheme.strain
                        )
                    }
                } else {
                    Text("No aligned window detected yet.")
                        .font(.mellowCaption)
                        .foregroundColor(MellowTheme.textTertiary)
                }
            }
        }
    }

    private func timelineEventRow(time: String, title: String, desc: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(time)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(MellowTheme.textTertiary)
                .frame(width: 58, alignment: .leading)

            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.mellowBody)
                    .fontWeight(.medium)
                    .foregroundColor(MellowTheme.textPrimary)
                Text(desc)
                    .font(.mellowLabel)
                    .foregroundColor(MellowTheme.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Overnight Charts

    private var sleepHRCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(
                    title: "Overnight heart rate",
                    subtitle: "\(sleepHR.count) readings · drag to inspect"
                ) {
                    if let lo = sleepHR.map(\.value).min(), let hi = sleepHR.map(\.value).max() {
                        Chip(text: "\(Int(lo))–\(Int(hi)) bpm", tint: MellowTheme.heartRate)
                    }
                }
                InteractiveTrendChart(
                    samples: sleepHR,
                    range: .day,
                    color: MellowTheme.heartRate,
                    unit: "bpm",
                    valueFormat: { "\(Int($0.rounded()))" }
                )
                .frame(height: 160)
            }
        }
    }

    private var sleepTempCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(
                    title: "Overnight temperature",
                    subtitle: "\(sleepTemp.count) readings · drag to inspect"
                ) {
                    if let lo = sleepTemp.map(\.value).min(), let hi = sleepTemp.map(\.value).max() {
                        Chip(text: String(format: "%.1f–%.1f °C", lo, hi), tint: MellowTheme.temperature)
                    }
                }
                InteractiveTrendChart(
                    samples: sleepTemp,
                    range: .day,
                    color: MellowTheme.temperature,
                    unit: "°C",
                    valueFormat: { String(format: "%.1f", $0) }
                )
                .frame(height: 150)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        SurfaceCard {
            VStack(spacing: MellowTheme.Spacing.md) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 38, weight: .light))
                    .foregroundColor(MellowTheme.sleep)
                Text("No sleep detected yet")
                    .font(.mellowHeadline)
                    .foregroundColor(MellowTheme.textPrimary)
                Text("Wear the ring to bed. It records the night to its onboard flash memory. In the morning, connect the ring and pull down to sync.")
                    .font(.mellowCaption)
                    .foregroundColor(MellowTheme.textSecondary)
                    .multilineTextAlignment(.center)

                Button {
                    Task { await session.resync() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Sync Ring History")
                    }
                    .font(.mellowBody)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: MellowTheme.Radius.md).fill(MellowTheme.fill))
                    .foregroundColor(MellowTheme.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MellowTheme.Spacing.lg)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}
