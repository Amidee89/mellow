import Foundation

// MARK: - Movement Epoch & Staging Models

struct MovementEpoch: Identifiable, Codable {
    var id: String { "\(timeMs)_\(ringTime)" }
    var timeMs: UInt64
    var ringTime: UInt32
    var timeResolved: Bool
    var acmTotal: Double          // acm0 + acm1 + acm2 movement energy
    var acm0: UInt16
    var acm1: UInt16
    var acm2: UInt16
    var respiratoryRate: Double?
    var motionState: Int?         // 0: NO_MOTION, 1: RESTLESS, 2: TOSSING_AND_TURNING, 3: ACTIVE
    var estimatedSteps: Int

    var date: Date { Date(timeIntervalSince1970: Double(timeMs) / 1000.0) }
}

struct SynthesizedSleepStage: Identifiable, Codable, Equatable {
    var id: String { "\(startDate.timeIntervalSince1970)" }
    let startDate: Date
    let endDate: Date
    let stage: WatchSleepStage    // .deep, .core, .rem, .awake
    let movementEnergy: Double
    let hr: Double?
    let hrv: Double?
    let reason: String

    var durationMinutes: Double {
        max(0, endDate.timeIntervalSince(startDate) / 60.0)
    }
}

struct SynthesizedHypnogramResult: Codable {
    var stages: [SynthesizedSleepStage] = []
    var totalSleepMinutes: Double = 0
    var timeInBedMinutes: Double = 0
    var deepMinutes: Double = 0
    var coreMinutes: Double = 0
    var remMinutes: Double = 0
    var awakeMinutes: Double = 0
    var sleepEfficiency: Double = 0
    var awakeningsCount: Int = 0
    var lowestHR: Double?
    var averageHR: Double?

    var deepPercent: Double {
        totalSleepMinutes > 0 ? (deepMinutes / totalSleepMinutes) * 100.0 : 0
    }
    var remPercent: Double {
        totalSleepMinutes > 0 ? (remMinutes / totalSleepMinutes) * 100.0 : 0
    }
    var corePercent: Double {
        totalSleepMinutes > 0 ? (coreMinutes / totalSleepMinutes) * 100.0 : 0
    }
    var awakePercent: Double {
        timeInBedMinutes > 0 ? (awakeMinutes / timeInBedMinutes) * 100.0 : 0
    }
}

// MARK: - Algorithm Classifier

enum SleepHypnogramClassifier {

    /// Tunable classification parameters for on-device staging
    struct TuningParameters {
        var wakeAcmThreshold: Double = 75.0        // acmTotal above this triggers wake
        var deepStillnessThreshold: Double = 28.0  // acmTotal below this allows deep
        var deepHrDeltaMaxBpm: Double = 6.0        // max bpm above nadir for deep sleep
        var remHrDeltaMinBpm: Double = 4.0         // min bpm above nadir for REM activation
        var remCycleIntervalMinutes: Double = 90.0 // ultradian cycle duration
        var remFirstCycleDelayMinutes: Double = 70.0 // delay before first REM period
    }

    /// Classifies continuous overnight 30-second epochs into Deep, Core, REM, and Awake stages
    static func classify(
        windowStart: Date,
        windowEnd: Date,
        movementEpochs: [MovementEpoch],
        hrSamples: [RingStore.Sample],
        hrvSamples: [RingStore.Sample],
        params: TuningParameters = TuningParameters()
    ) -> SynthesizedHypnogramResult {
        guard windowEnd > windowStart else { return SynthesizedHypnogramResult() }

        let windowDurationS = windowEnd.timeIntervalSince(windowStart)
        guard windowDurationS >= 1800 else { // At least 30 minutes
            return SynthesizedHypnogramResult()
        }

        // 1. Gather heart rate baseline & nadir for the night
        let inWindowHR = hrSamples.filter { $0.date >= windowStart && $0.date <= windowEnd && $0.value > 35 && $0.value < 140 }
        let sortedHR = inWindowHR.map(\.value).sorted()
        let nadirHR: Double = sortedHR.first ?? 55.0
        let medianHR: Double = !sortedHR.isEmpty ? sortedHR[sortedHR.count / 2] : 62.0
        let avgHR: Double = !sortedHR.isEmpty ? sortedHR.reduce(0, +) / Double(sortedHR.count) : medianHR

        // 2. Generate 30-second epoch intervals
        let epochDuration: TimeInterval = 30.0
        var currentStart = windowStart
        var rawStages: [SynthesizedSleepStage] = []

        let sortedMovements = movementEpochs.sorted { $0.timeMs < $1.timeMs }

        while currentStart < windowEnd {
            let currentEnd = min(windowEnd, currentStart.addingTimeInterval(epochDuration))
            let midpoint = currentStart.addingTimeInterval(epochDuration / 2.0)
            let elapsedMin = currentStart.timeIntervalSince(windowStart) / 60.0
            let totalNightMin = windowDurationS / 60.0

            // Find closest movement epoch within ±45s
            let matchedMovement = sortedMovements.first { abs($0.date.timeIntervalSince(midpoint)) <= 45 }
            let motionEnergy: Double
            let motionState: Int?

            if let m = matchedMovement {
                motionEnergy = m.acmTotal
                motionState = m.motionState
            } else {
                motionEnergy = 14.0 // Baseline quiet stillness
                motionState = 0
            }

            // Find closest HR sample within ±90s
            let matchedHR = inWindowHR.first { abs($0.date.timeIntervalSince(midpoint)) <= 90 }?.value

            // Classification Logic
            let stage: WatchSleepStage
            let reason: String

            let isEarlyInBed = elapsedMin < 12.0 && motionEnergy > 35.0
            let isAwakeMovement = motionEnergy >= params.wakeAcmThreshold || (motionState ?? 0) >= 2

            if isEarlyInBed {
                stage = .awake
                reason = "Sleep onset latency period"
            } else if isAwakeMovement {
                stage = .awake
                reason = "Movement burst (ACM \(Int(motionEnergy)))"
            } else if motionEnergy < params.deepStillnessThreshold,
                      let hr = matchedHR,
                      hr <= (nadirHR + params.deepHrDeltaMaxBpm),
                      elapsedMin < (totalNightMin * 0.6) {
                // Deep sleep dominates the first 60% of the night during HR nadir
                stage = .deep
                reason = "Stillness (ACM \(Int(motionEnergy))) + HR nadir (\(Int(hr)) bpm)"
            } else if motionEnergy < (params.deepStillnessThreshold + 6.0),
                      let hr = matchedHR,
                      hr >= (nadirHR + params.remHrDeltaMinBpm),
                      elapsedMin >= params.remFirstCycleDelayMinutes,
                      isRemPhase(elapsedMin: elapsedMin, params: params) {
                // REM sleep occurs with muscle atonia, elevated autonomic HR, in ultradian cycles
                stage = .rem
                reason = "Atonia with elevated autonomic HR (\(Int(hr)) bpm)"
            } else {
                // Default NREM Core/Light sleep
                stage = .core
                reason = "Resting baseline NREM (ACM \(Int(motionEnergy)))"
            }

            rawStages.append(
                SynthesizedSleepStage(
                    startDate: currentStart,
                    endDate: currentEnd,
                    stage: stage,
                    movementEnergy: motionEnergy,
                    hr: matchedHR,
                    hrv: nil,
                    reason: reason
                )
            )

            currentStart = currentEnd
        }

        // 3. Smooth transient single-epoch anomalies (physiological constraint: stages last >= 1.5 - 2m)
        let smoothedStages = smoothEpochs(rawStages)

        // 4. Group adjacent epochs of the same stage into merged intervals
        let mergedStages = mergeAdjacentEpochs(smoothedStages)

        // 5. Calculate summary metrics
        var deepM = 0.0
        var coreM = 0.0
        var remM = 0.0
        var awakeM = 0.0
        var awakenings = 0
        var lastWasAsleep = false

        for s in mergedStages {
            let dur = s.durationMinutes
            switch s.stage {
            case .deep:
                deepM += dur
                lastWasAsleep = true
            case .core:
                coreM += dur
                lastWasAsleep = true
            case .rem:
                remM += dur
                lastWasAsleep = true
            case .awake, .inBed:
                awakeM += dur
                if lastWasAsleep { awakenings += 1 }
                lastWasAsleep = false
            }
        }

        let totalSleepM = deepM + coreM + remM
        let inBedM = totalSleepM + awakeM
        let efficiency = inBedM > 0 ? (totalSleepM / inBedM) * 100.0 : 0.0

        return SynthesizedHypnogramResult(
            stages: mergedStages,
            totalSleepMinutes: totalSleepM,
            timeInBedMinutes: inBedM,
            deepMinutes: deepM,
            coreMinutes: coreM,
            remMinutes: remM,
            awakeMinutes: awakeM,
            sleepEfficiency: efficiency,
            awakeningsCount: awakenings,
            lowestHR: nadirHR,
            averageHR: avgHR
        )
    }

    /// Tests if elapsed minutes falls near an ultradian REM cycle window (~90m periodicity)
    private static func isRemPhase(elapsedMin: Double, params: TuningParameters) -> Bool {
        guard elapsedMin >= params.remFirstCycleDelayMinutes else { return false }
        let cyclePos = (elapsedMin - params.remFirstCycleDelayMinutes).truncatingRemainder(dividingBy: params.remCycleIntervalMinutes)
        // REM typically occupies 15 to 35 minutes of each 90-minute cycle, lengthening later
        return cyclePos >= 55.0 && cyclePos <= 88.0
    }

    /// Filters isolated 30-second spikes so stages don't flicker unrealistically
    private static func smoothEpochs(_ epochs: [SynthesizedSleepStage]) -> [SynthesizedSleepStage] {
        guard epochs.count >= 3 else { return epochs }
        var result = epochs

        for i in 1..<(result.count - 1) {
            let prev = result[i - 1].stage
            let curr = result[i].stage
            let next = result[i + 1].stage

            // If an isolated stage is flanked by the same stage, adopt the surrounding stage (unless high motion wake)
            if prev == next && curr != prev && result[i].movementEnergy < 90.0 {
                result[i] = SynthesizedSleepStage(
                    startDate: result[i].startDate,
                    endDate: result[i].endDate,
                    stage: prev,
                    movementEnergy: result[i].movementEnergy,
                    hr: result[i].hr,
                    hrv: result[i].hrv,
                    reason: "Smoothed with adjacent \(prev.rawValue) stage"
                )
            }
        }
        return result
    }

    /// Merges contiguous epochs of the same stage into single intervals for efficient UI rendering
    private static func mergeAdjacentEpochs(_ epochs: [SynthesizedSleepStage]) -> [SynthesizedSleepStage] {
        guard let first = epochs.first else { return [] }
        var merged: [SynthesizedSleepStage] = []

        var currentStart = first.startDate
        var currentEnd = first.endDate
        var currentStage = first.stage
        var totalEnergy = first.movementEnergy
        var count = 1.0
        var latestHR = first.hr
        var latestReason = first.reason

        for e in epochs.dropFirst() {
            if e.stage == currentStage {
                currentEnd = e.endDate
                totalEnergy += e.movementEnergy
                count += 1.0
                if let hr = e.hr { latestHR = hr }
            } else {
                merged.append(
                    SynthesizedSleepStage(
                        startDate: currentStart,
                        endDate: currentEnd,
                        stage: currentStage,
                        movementEnergy: totalEnergy / count,
                        hr: latestHR,
                        hrv: nil,
                        reason: latestReason
                    )
                )
                currentStart = e.startDate
                currentEnd = e.endDate
                currentStage = e.stage
                totalEnergy = e.movementEnergy
                count = 1.0
                latestHR = e.hr
                latestReason = e.reason
            }
        }

        merged.append(
            SynthesizedSleepStage(
                startDate: currentStart,
                endDate: currentEnd,
                stage: currentStage,
                movementEnergy: totalEnergy / count,
                hr: latestHR,
                hrv: nil,
                reason: latestReason
            )
        )

        return merged
    }

    // MARK: - Step Estimation from Movement Epochs

    /// Estimates daily and hourly steps from daytime 30s movement/step feature epochs
    static func estimateSteps(epochs: [MovementEpoch], for date: Date = Date()) -> (totalSteps: Int, hourly: [HourlyStepCount]) {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? date

        let todayEpochs = epochs.filter { $0.date >= startOfDay && $0.date < endOfDay }

        var hourlyBuckets = [Int: Int]()
        for h in 0..<24 { hourlyBuckets[h] = 0 }

        var total = 0
        for ep in todayEpochs {
            var steps = 0
            if ep.estimatedSteps > 0 {
                steps = ep.estimatedSteps
            } else if ep.motionState == 3 { // Active motion state (0x6b)
                steps = max(25, min(65, Int(ep.acmTotal / 3.5)))
            } else if ep.acmTotal > 95.0 {
                // Rhythmic walking acceleration (0x72 / 0x47 / 0x7e)
                steps = max(15, min(60, Int(ep.acmTotal / 4.0)))
            }

            if steps > 0 {
                total += steps
                let hour = cal.component(.hour, from: ep.date)
                hourlyBuckets[hour, default: 0] += steps
            }
        }

        var hourlyCounts: [HourlyStepCount] = []
        for h in 0..<24 {
            let hDate = cal.date(byAdding: .hour, value: h, to: startOfDay) ?? startOfDay
            hourlyCounts.append(HourlyStepCount(hour: h, steps: hourlyBuckets[h, default: 0], date: hDate))
        }

        return (totalSteps: total, hourly: hourlyCounts)
    }

    // MARK: - Hypnogram Agreement Comparison

    /// Computes percentage agreement between Ring hypnogram and Apple Watch staging
    static func computeAgreement(
        ringStages: [SynthesizedSleepStage],
        watchStages: [WatchSleepStageInterval]
    ) -> Double? {
        guard !ringStages.isEmpty, !watchStages.isEmpty else { return nil }

        guard let start = [ringStages.map(\.startDate).min()!, watchStages.map(\.startDate).min()!].max(),
              let end = [ringStages.map(\.endDate).max()!, watchStages.map(\.endDate).max()!].min(),
              end > start else { return nil }

        let sampleInterval: TimeInterval = 60.0 // 1-minute comparison resolution
        var current = start
        var matches = 0
        var total = 0

        while current < end {
            let rStage = ringStages.first { $0.startDate <= current && $0.endDate > current }?.stage
            let wStage = watchStages.first { $0.startDate <= current && $0.endDate > current }?.stage

            if let r = rStage, let w = wStage {
                total += 1
                if r == w {
                    matches += 1
                }
            }
            current = current.addingTimeInterval(sampleInterval)
        }

        guard total > 10 else { return nil }
        return (Double(matches) / Double(total)) * 100.0
    }
}
