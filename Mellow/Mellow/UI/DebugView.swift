import SwiftUI
import UIKit

// MARK: - DebugView (Packet Inspector, Decoded Feed & Diagnostic Export)

struct DebugView: View {
    @EnvironmentObject var store: RingStore
    @EnvironmentObject var session: RingSession
    @EnvironmentObject var health: HealthKitBridge
    @EnvironmentObject var metrics: MetricsStore

    @State private var mode = Mode.records
    @State private var shareFileUrl: URL?
    @State private var showingShareSheet = false
    @State private var isExporting = false

    enum Mode: String, CaseIterable {
        case records = "Records"
        case packets = "Packets"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            switch mode {
            case .records: recordsList
            case .packets: packetsList
            }
        }
        .navigationTitle("Debug & Diagnostics")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    exportAndShareDiagnostics()
                } label: {
                    HStack(spacing: 4) {
                        if isExporting {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Text("Share Dump")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .disabled(isExporting)
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let url = shareFileUrl {
                ShareActivitySheet(activityItems: [url])
            }
        }
    }

    // MARK: - Lists

    private var recordsList: some View {
        List(store.recentRecords) { rec in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(rec.tagHex).font(.system(.caption, design: .monospaced)).bold()
                    Text(rec.typeName).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("rt \(rec.ringTime)").font(.caption2).foregroundStyle(.tertiary)
                }
                ForEach(rec.fields.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Text(rec.fields[i].0).font(.caption2).foregroundStyle(.secondary)
                        Text(rec.fields[i].1).font(.system(.caption2, design: .monospaced)).lineLimit(2)
                    }
                }
                if let ev = rec.eventTimeMs {
                    Text("event \(Date(timeIntervalSince1970: Double(ev)/1000).formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.plain)
    }

    private var packetsList: some View {
        List(store.packetLog) { p in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: p.direction == .tx ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(p.direction == .tx ? .blue : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.hex).font(.system(.caption2, design: .monospaced)).lineLimit(3)
                    HStack {
                        if !p.note.isEmpty { Text(p.note).font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Text(p.date.formatted(date: .omitted, time: .standard))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .listStyle(.plain)
    }

    // MARK: - Export Diagnostics

    private func exportAndShareDiagnostics() {
        isExporting = true
        defer { isExporting = false }

        var export: [String: Any] = [:]
        export["exported_at"] = ISO8601DateFormatter().string(from: Date())
        export["app_name"] = "Mellow"

        // BLE Session details
        var sessionDict: [String: Any] = [:]
        sessionDict["phase"] = String(describing: session.phase)
        sessionDict["ble_state"] = String(describing: session.ble.state)
        sessionDict["auth_confirmed"] = AuthKeyStore.isClaimConfirmed
        sessionDict["battery_percent"] = store.batteryPercent ?? -1
        sessionDict["battery_voltage_mv"] = store.batteryVoltageMv ?? -1
        export["session"] = sessionDict

        // RingStore biometrics
        var biometrics: [String: Any] = [:]
        biometrics["instant_hr_bpm"] = store.instantHrBpm ?? -1
        biometrics["skin_temp_c"] = store.skinTempC ?? -1
        biometrics["spo2_percent"] = store.spo2Percent ?? -1
        biometrics["hrv_rmssd_ms"] = store.hrvRmssdMs ?? -1
        biometrics["respiratory_rate"] = store.respiratoryRate ?? -1
        biometrics["wear_state"] = store.wearStateName ?? "unknown"
        biometrics["steps_today"] = store.stepsToday ?? -1
        biometrics["in_bed"] = store.inBed ?? false
        biometrics["sleep_start"] = store.sleepStartDate?.description ?? "nil"
        biometrics["sleep_end"] = store.sleepEndDate?.description ?? "nil"
        biometrics["saw_sleep_flags"] = store.sawSleepFlags
        export["biometrics"] = biometrics

        // Packet Log
        export["packet_log"] = store.packetLog.map { p -> [String: Any] in
            [
                "time": ISO8601DateFormatter().string(from: p.date),
                "direction": p.direction == .tx ? "tx" : "rx",
                "hex": p.hex,
                "note": p.note
            ]
        }

        // Decoded Records
        export["decoded_records"] = store.recentRecords.map { r -> [String: Any] in
            var dict: [String: Any] = [
                "tag_hex": r.tagHex,
                "type_name": r.typeName,
                "ring_time": r.ringTime
            ]
            if let ev = r.eventTimeMs { dict["event_time_ms"] = ev }
            var fieldsDict: [String: String] = [:]
            for f in r.fields { fieldsDict[f.0] = f.1 }
            dict["fields"] = fieldsDict
            return dict
        }

        // Sleep Nights from Ring
        var nightsDict: [String: Any] = [:]
        for (k, n) in store.sleepNights {
            nightsDict[k] = [
                "start_ms": n.startMs ?? 0,
                "end_ms": n.endMs ?? 0,
                "deep_min": n.deepMin,
                "light_rem_min": n.lightRemMin,
                "wake_min": n.wakeMin,
                "awakenings": n.awakenings,
                "avg_hr": n.avgHr,
                "respiratory_rates": n.respiratoryRates
            ]
        }
        export["ring_sleep_nights"] = nightsDict

        // Raw Histories (most recent 200 samples each)
        export["hr_history"] = store.hrHistory.suffix(200).map { ["time_ms": $0.timeMs, "bpm": $0.value] }
        export["temp_history"] = store.tempHistory.suffix(200).map { ["time_ms": $0.timeMs, "celsius": $0.value] }
        export["spo2_history"] = store.spo2History.suffix(200).map { ["time_ms": $0.timeMs, "percent": $0.value] }
        export["hrv_history"] = store.hrvHistory.suffix(200).map { ["time_ms": $0.timeMs, "rmssd": $0.value] }

        // Apple Health Data
        var healthDict: [String: Any] = [:]
        healthDict["today_steps"] = health.todaySteps
        healthDict["today_hourly_steps"] = health.todayHourlySteps.map { ["hour": $0.hour, "steps": $0.steps] }
        if let w = health.latestWatchSleep {
            healthDict["watch_sleep"] = [
                "start": ISO8601DateFormatter().string(from: w.startDate),
                "end": ISO8601DateFormatter().string(from: w.endDate),
                "total_sleep_min": w.totalSleepMinutes,
                "time_in_bed_min": w.timeInBedMinutes,
                "deep_min": w.deepMinutes,
                "core_min": w.coreMinutes,
                "rem_min": w.remMinutes,
                "awake_min": w.awakeMinutes,
                "awakenings": w.awakeningsCount,
                "midpoint_hour": w.midpointHour,
                "source_name": w.sourceName,
                "lowest_hr": w.lowestHR ?? -1,
                "avg_hr": w.averageHR ?? -1,
                "mellow_score": w.mellowSleepScore?.score ?? -1
            ]
        }
        healthDict["watch_hr_count"] = health.watchHeartRateHistory.count
        healthDict["watch_temp_count"] = health.watchTemperatureHistory.count
        export["apple_health"] = healthDict

        // Write to temporary JSON file
        do {
            let data = try JSONSerialization.data(withJSONObject: export, options: [.prettyPrinted, .sortedKeys])
            let filename = "mellow_diagnostics_\(Int(Date().timeIntervalSince1970)).json"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: tempURL)
            self.shareFileUrl = tempURL
            self.showingShareSheet = true
        } catch {
            print("Failed to serialize diagnostics: \(error)")
        }
    }
}

// MARK: - Share Sheet Wrapper

private struct ShareActivitySheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
