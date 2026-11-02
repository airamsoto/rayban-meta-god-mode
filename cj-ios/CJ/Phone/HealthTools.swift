import Foundation
import HealthKit

/// Apple Health for "how did I sleep?", "how many steps today?", "my heart rate", "my last workout". Everything that
/// syncs into the Health app counts, including a Garmin, Oura or Whoop watch through their own apps.
///
/// HealthKit needs an entitlement. The regular build has none (it keeps sideloading simple); the "Salud" build adds it
/// and sets CJHealthKit=YES in Info.plist. Without it, this tool says so instead of failing.
@MainActor
final class HealthTools: ObservableObject {
    @Published private(set) var allowed = false

    /// This build carries the HealthKit entitlement (the "Salud" build).
    let built = (Bundle.main.object(forInfoDictionaryKey: "CJHealthKit") as? String) == "YES"
    var available: Bool { built && HKHealthStore.isHealthDataAvailable() }

    private let store = HKHealthStore()
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        for id: HKQuantityTypeIdentifier in [.stepCount, .heartRate, .restingHeartRate, .heartRateVariabilitySDNN,
                                             .activeEnergyBurned, .distanceWalkingRunning, .appleExerciseTime] {
            types.insert(HKQuantityType(id))
        }
        types.insert(HKCategoryType(.sleepAnalysis))
        return types
    }

    func requestAccess() async {
        guard available else { return }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            allowed = true  // HealthKit never says whether reading was granted; asking once is what counts
            UserDefaults.standard.set(true, forKey: "health_asked")
        } catch {
            allowed = false
        }
    }

    init() { allowed = UserDefaults.standard.bool(forKey: "health_asked") }

    func run(_ what: String, daysAgo: Int) async -> String {
        guard available else {
            return "FAILED: this CJ build has no Apple Health access. Install the 'Salud' version, or use Garmin on the Mac."
        }
        if !allowed { await requestAccess() }
        let day = Calendar.current.date(byAdding: .day, value: -max(0, min(daysAgo, 30)), to: .now)!
        let start = Calendar.current.startOfDay(for: day)
        let end = daysAgo == 0 ? Date.now : Calendar.current.date(byAdding: .day, value: 1, to: start)!
        switch what {
        case "steps": return await stepsLine(start, end)
        case "sleep": return await sleep(endingOn: start)
        case "heart": return await heart(start, end)
        case "workouts": return await workouts()
        default:
            return [await stepsLine(start, end), await activeLine(start, end), await heart(start, end),
                    await sleep(endingOn: start)].joined(separator: "\n")
        }
    }

    // MARK: - queries

    private func stepsLine(_ start: Date, _ end: Date) async -> String {
        let steps = await sum(.stepCount, .count(), start, end)
        let km = await sum(.distanceWalkingRunning, .meterUnit(with: .kilo), start, end)
        guard let steps else { return "No step data in Apple Health for that day." }
        return "Steps: \(Int(steps))" + (km.map { String(format: ", %.1f km walked/run", $0) } ?? "")
    }

    private func activeLine(_ start: Date, _ end: Date) async -> String {
        let kcal = await sum(.activeEnergyBurned, .kilocalorie(), start, end)
        let exercise = await sum(.appleExerciseTime, .minute(), start, end)
        return "Active energy: \(kcal.map { "\(Int($0)) kcal" } ?? "?"); exercise: \(exercise.map { "\(Int($0)) min" } ?? "?")"
    }

    private func heart(_ start: Date, _ end: Date) async -> String {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let stats = await statistics(.heartRate, [.discreteAverage, .discreteMin, .discreteMax], start, end)
        let resting = await statistics(.restingHeartRate, [.discreteAverage], start, end)?.averageQuantity()?.doubleValue(for: bpm)
        let hrv = await statistics(.heartRateVariabilitySDNN, [.discreteAverage], start, end)?.averageQuantity()?
            .doubleValue(for: .secondUnit(with: .milli))
        guard let stats, let avg = stats.averageQuantity()?.doubleValue(for: bpm) else {
            return "No heart rate data in Apple Health for that day."
        }
        let low = stats.minimumQuantity()?.doubleValue(for: bpm) ?? avg, high = stats.maximumQuantity()?.doubleValue(for: bpm) ?? avg
        return "Heart rate: average \(Int(avg)) bpm (\(Int(low))–\(Int(high)))"
            + (resting.map { ", resting \(Int($0)) bpm" } ?? "") + (hrv.map { ", HRV \(Int($0)) ms" } ?? "")
    }

    /// The night that ends on [day]'s morning: from 18:00 the day before to 14:00.
    private func sleep(endingOn day: Date) async -> String {
        let from = day.addingTimeInterval(-6 * 3600), to = day.addingTimeInterval(14 * 3600)
        let samples: [HKCategorySample] = await withCheckedContinuation { c in
            let query = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis),
                                      predicate: HKQuery.predicateForSamples(withStart: from, end: to),
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, found, _ in
                c.resume(returning: (found as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
        var seconds: [String: TimeInterval] = [:]
        for s in samples {
            let length = s.endDate.timeIntervalSince(s.startDate)
            switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
            case .asleepDeep: seconds["deep", default: 0] += length
            case .asleepREM: seconds["REM", default: 0] += length
            case .asleepCore: seconds["light", default: 0] += length
            case .asleepUnspecified: seconds["asleep", default: 0] += length
            case .awake: seconds["awake", default: 0] += length
            default: break
            }
        }
        let asleep = seconds.filter { $0.key != "awake" }.values.reduce(0, +)
        guard asleep > 0 else { return "No sleep recorded in Apple Health for last night." }
        let detail = ["deep", "REM", "light", "awake"].compactMap { k in seconds[k].map { "\(k) \(Self.hm($0))" } }
        return "Sleep last night: \(Self.hm(asleep))" + (detail.isEmpty ? "" : " (" + detail.joined(separator: ", ") + ")")
    }

    private func workouts() async -> String {
        let found: [HKWorkout] = await withCheckedContinuation { c in
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: nil, limit: 5,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, s, _ in
                c.resume(returning: (s as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
        guard !found.isEmpty else { return "No workouts in Apple Health." }
        let date = DateFormatter()
        date.locale = Locale(identifier: "es_ES")
        date.dateFormat = "EEE d MMM HH:mm"
        return found.map { w in
            let km = w.totalDistance?.doubleValue(for: .meterUnit(with: .kilo))
            return "\(date.string(from: w.startDate)) \(Self.name(w.workoutActivityType)): \(Self.hm(w.duration))"
                + (km.map { String(format: ", %.2f km", $0) } ?? "")
        }.joined(separator: "\n")
    }

    private func sum(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ start: Date, _ end: Date) async -> Double? {
        await statistics(id, [.cumulativeSum], start, end)?.sumQuantity()?.doubleValue(for: unit)
    }

    private func statistics(_ id: HKQuantityTypeIdentifier, _ options: HKStatisticsOptions,
                            _ start: Date, _ end: Date) async -> HKStatistics? {
        await withCheckedContinuation { c in
            let query = HKStatisticsQuery(quantityType: HKQuantityType(id),
                                          quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end),
                                          options: options) { _, stats, _ in c.resume(returning: stats) }
            store.execute(query)
        }
    }

    private static func hm(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min"
    }

    private static func name(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .hiking: return "hiking"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "strength training"
        case .yoga: return "yoga"
        case .highIntensityIntervalTraining: return "HIIT"
        case .soccer: return "football"
        case .tennis: return "tennis"
        default: return "workout"
        }
    }
}
