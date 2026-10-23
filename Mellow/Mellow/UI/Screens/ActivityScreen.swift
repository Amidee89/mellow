import SwiftUI
import Charts

// MARK: - ActivityScreen (Steps Throughout the Day & Motion Analysis)

struct ActivityScreen: View {
    @EnvironmentObject var health: HealthKitBridge
    @EnvironmentObject var store: RingStore
    @EnvironmentObject var session: RingSession

    @State private var selectedHour: HourlyStepCount?
    @AppStorage("mellow.dailyStepGoal") private var dailyGoal: Int = 10000

    private var stepsTotal: Int {
        if let s = store.stepsToday, s > 0 { return s }
        if health.todaySteps > 0 { return health.todaySteps }
        return 0
    }

    private var goalProgress: Double {
        guard dailyGoal > 0 else { return 0 }
        return min(1.0, Double(stepsTotal) / Double(dailyGoal))
    }

    private var estimatedDistanceKm: Double {
        Double(stepsTotal) * 0.00076
    }

    private var estimatedCalories: Int {
        Int(Double(stepsTotal) * 0.04)
    }

    private var hourlyData: [HourlyStepCount] {
        if !health.todayHourlySteps.isEmpty {
            return health.todayHourlySteps
        }
        if !store.hourlyRingSteps.isEmpty {
            return store.hourlyRingSteps
        }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        return (0..<24).map { h in
            let date = cal.date(byAdding: .hour, value: h, to: start) ?? Date()
            return HourlyStepCount(hour: h, steps: 0, date: date)
        }
    }

    private var peakHour: HourlyStepCount? {
        hourlyData.max { $0.steps < $1.steps }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: MellowTheme.Spacing.lg) {
                if !health.isReadAuthorized && health.readEnabled {
                    healthPermissionBanner
                }
                summaryCard
                hourlyStepsChartCard
                hourlyBreakdownCard
                sourcesCard
            }
            .padding(.horizontal, MellowTheme.Spacing.lg)
            .padding(.top, MellowTheme.Spacing.sm)
            .padding(.bottom, MellowTheme.Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .mellowScreenBackground()
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if health.readEnabled && !health.isReadAuthorized {
                await health.requestReadAuthorization()
            }
            await health.fetchTodaySteps()
        }
        .refreshable {
            await refreshData()
        }
    }

    // MARK: - Health Permission Banner

    private var healthPermissionBanner: some View {
        SurfaceCard {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(MellowTheme.spo2.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(MellowTheme.spo2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Health Permission")
                        .font(.mellowHeadline)
                        .foregroundColor(MellowTheme.textPrimary)
                    Text("Allow read access to sync your Apple Watch steps and sleep stages.")
                        .font(.mellowCaption)
                        .foregroundColor(MellowTheme.textSecondary)
                }

                Spacer()

                Button("Allow") {
                    Task {
                        await health.requestReadAuthorization()
                        await health.fetchAllReadData()
                    }
                }
                .font(.mellowLabel)
                .fontWeight(.bold)
                .foregroundColor(MellowTheme.textInverse)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(MellowTheme.accent))
            }
        }
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(
                    title: "Daily Steps",
                    subtitle: "Today’s activity"
                ) {
                    Chip(
                        text: "\(Int((goalProgress * 100).rounded()))% of goal",
                        icon: "flame.fill",
                        tint: goalProgress >= 1.0 ? MellowTheme.good : MellowTheme.strain,
                        filled: goalProgress >= 1.0
                    )
                }

                HStack(spacing: MellowTheme.Spacing.lg) {
                    // Circular Progress Ring
                    ZStack {
                        Circle()
                            .stroke(MellowTheme.fill, lineWidth: 12)
                            .frame(width: 90, height: 90)
                        Circle()
                            .trim(from: 0, to: CGFloat(goalProgress))
                            .stroke(
                                goalProgress >= 1.0 ? MellowTheme.good : MellowTheme.strain,
                                style: StrokeStyle(lineWidth: 12, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 90, height: 90)
                        VStack(spacing: 0) {
                            Image(systemName: "figure.walk")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(MellowTheme.strain)
                            Text("\(Int((goalProgress * 100).rounded()))%")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(MellowTheme.textSecondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(stepsTotal.formatted())")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundColor(MellowTheme.textPrimary)

                        Text("Goal: \(dailyGoal.formatted()) steps")
                            .font(.mellowLabel)
                            .foregroundColor(MellowTheme.textTertiary)

                        HStack(spacing: MellowTheme.Spacing.md) {
                            HStack(spacing: 3) {
                                Image(systemName: "location.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(MellowTheme.accent)
                                Text(String(format: "%.1f km", estimatedDistanceKm))
                                    .font(.mellowLabel)
                                    .foregroundColor(MellowTheme.textSecondary)
                            }
                            HStack(spacing: 3) {
                                Image(systemName: "flame.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(MellowTheme.strain)
                                Text("\(estimatedCalories) kcal")
                                    .font(.mellowLabel)
                                    .foregroundColor(MellowTheme.textSecondary)
                            }
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Hourly Steps Chart Card

    private var hourlyStepsChartCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hourly Distribution")
                            .font(.mellowHeadline)
                            .foregroundColor(MellowTheme.textPrimary)
                        if let selected = selectedHour {
                            Text("\(formatHourRange(selected.hour)) · \(selected.steps.formatted()) steps")
                                .font(.mellowCaption)
                                .foregroundColor(MellowTheme.accent)
                                .fontWeight(.semibold)
                        } else if let peak = peakHour, peak.steps > 0 {
                            Text("Peak: \(formatHour(peak.hour)) (\(peak.steps.formatted()) steps)")
                                .font(.mellowCaption)
                                .foregroundColor(MellowTheme.textSecondary)
                        } else {
                            Text("Steps by hour of the day")
                                .font(.mellowCaption)
                                .foregroundColor(MellowTheme.textTertiary)
                        }
                    }
                    Spacer()
                    if selectedHour != nil {
                        Button("Reset") {
                            withAnimation { selectedHour = nil }
                        }
                        .font(.mellowLabel)
                        .foregroundColor(MellowTheme.accent)
                    }
                }

                Chart {
                    ForEach(hourlyData) { item in
                        BarMark(
                            x: .value("Hour", item.hour),
                            y: .value("Steps", item.steps)
                        )
                        .foregroundStyle(
                            selectedHour?.hour == item.hour
                                ? MellowTheme.accent
                                : (item.steps > 0 ? MellowTheme.strain.opacity(0.85) : MellowTheme.fill)
                        )
                        .cornerRadius(3)
                    }
                }
                .frame(height: 160)
                .chartXScale(domain: 0...23)
                .chartXAxis {
                    AxisMarks(values: [0, 4, 8, 12, 16, 20]) { val in
                        if let h = val.as(Int.self) {
                            AxisValueLabel {
                                Text(formatHour(h))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(MellowTheme.textTertiary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { _ in
                        AxisGridLine().foregroundStyle(MellowTheme.stroke.opacity(0.5))
                        AxisValueLabel()
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(MellowTheme.textTertiary)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let xPos = value.location.x - geo[proxy.plotFrame!].origin.x
                                        if let hour: Int = proxy.value(atX: xPos) {
                                            let clamped = max(0, min(23, hour))
                                            selectedHour = hourlyData.first { $0.hour == clamped }
                                        }
                                    }
                            )
                    }
                }
            }
        }
    }

    // MARK: - Hourly Breakdown List Card

    private var hourlyBreakdownCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.sm) {
                SectionHeader(
                    title: "Active Intervals",
                    subtitle: "Hours with recorded steps"
                )

                let activeHours = hourlyData.filter { $0.steps > 0 }.sorted { $0.hour < $1.hour }

                if activeHours.isEmpty {
                    Text("No steps recorded for today yet.")
                        .font(.mellowCaption)
                        .foregroundColor(MellowTheme.textTertiary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(activeHours) { item in
                        HStack {
                            Text(formatHourRange(item.hour))
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(MellowTheme.textSecondary)
                            Spacer()
                            Text("\(item.steps.formatted())")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(MellowTheme.textPrimary)
                            Text("steps")
                                .font(.mellowLabel)
                                .foregroundColor(MellowTheme.textTertiary)
                        }
                        .padding(.vertical, 4)
                        Divider().background(MellowTheme.stroke.opacity(0.5))
                    }
                }
            }
        }
    }

    // MARK: - Sources Card

    private var sourcesCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: MellowTheme.Spacing.md) {
                SectionHeader(title: "Activity Sources", subtitle: "Cross-device step counters & motion")

                // Apple Watch / Apple Health
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "applewatch")
                            .font(.system(size: 16))
                            .foregroundColor(MellowTheme.sleep)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Apple Watch")
                                .font(.mellowBody)
                                .foregroundColor(MellowTheme.textPrimary)
                            if health.watchTodaySteps > 0 {
                                Text("\(health.watchTodaySteps.formatted()) steps")
                                    .font(.mellowLabel)
                                    .foregroundColor(MellowTheme.textTertiary)
                            } else if health.todaySteps > 0 {
                                Text("\(health.todaySteps.formatted()) steps (iPhone / Health)")
                                    .font(.mellowLabel)
                                    .foregroundColor(MellowTheme.textTertiary)
                            } else if !health.isReadAuthorized {
                                Text("Permission required")
                                    .font(.mellowLabel)
                                    .foregroundColor(MellowTheme.accent)
                            } else {
                                Text("0 steps recorded today")
                                    .font(.mellowLabel)
                                    .foregroundColor(MellowTheme.textTertiary)
                            }
                        }
                    }
                    Spacer()
                    if health.todaySteps > 0 || health.watchTodaySteps > 0 {
                        Chip(text: "Active", tint: MellowTheme.good)
                    } else if !health.isReadAuthorized {
                        Button("Authorize") {
                            Task {
                                await health.requestReadAuthorization()
                                await health.fetchTodaySteps()
                            }
                        }
                        .font(.mellowLabel)
                        .foregroundColor(MellowTheme.accent)
                    } else {
                        Button("Sync") {
                            Task { await health.fetchTodaySteps() }
                        }
                        .font(.mellowLabel)
                        .foregroundColor(MellowTheme.accent)
                    }
                }

                Divider().background(MellowTheme.stroke)

                // Oura Ring 4
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.circle")
                            .font(.system(size: 16))
                            .foregroundColor(MellowTheme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Oura Ring 4")
                                .font(.mellowBody)
                                .foregroundColor(MellowTheme.textPrimary)
                            if let s = store.stepsToday, s > 0 {
                                Text("\(s.formatted()) steps (classified from motion)")
                                    .font(.mellowLabel)
                                    .foregroundColor(MellowTheme.textTertiary)
                            } else if !store.movementHistory.isEmpty {
                                Text("\(store.movementHistory.count) movement epochs recorded")
                                    .font(.mellowLabel)
                                    .foregroundColor(MellowTheme.textTertiary)
                            } else {
                                Text("Pull to sync ring motion history")
                                    .font(.mellowLabel)
                                    .foregroundColor(MellowTheme.textTertiary)
                            }
                        }
                    }
                    Spacer()
                    if store.stepsToday != nil || !store.movementHistory.isEmpty {
                        Chip(text: "Classified", tint: MellowTheme.accent)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func refreshData() async {
        async let syncWatch: () = health.fetchTodaySteps()
        async let syncRing: () = session.resync()
        _ = await (syncWatch, syncRing)
    }

    private func formatHour(_ h: Int) -> String {
        let hour = h % 24
        return String(format: "%02d:00", hour)
    }

    private func formatHourRange(_ h: Int) -> String {
        let start = h % 24
        let end = (h + 1) % 24
        return String(format: "%02d:00 – %02d:00", start, end)
    }
}
