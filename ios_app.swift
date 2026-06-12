// ============================================================
// 🌱 Green Commute Carbon Tracker — iOS App
// Swift + CoreLocation + CoreMotion + SwiftUI
// ============================================================

import Foundation
import CoreLocation
import CoreMotion
import SwiftUI
import Combine


// MARK: - Models

struct GPSWaypoint: Codable {
    let latitude: Double
    let longitude: Double
    let speedKmh: Double?
    let accuracyM: Double?
    let altitudeM: Double?
    let recordedAt: Date
}

struct TripResult: Codable {
    let tripId: String
    let transportMode: String
    let distanceKm: Double
    let carbonEmissionG: Double
    let carbonSavedG: Double
    let pointsEarned: Int
    let busMatchScore: Double?
    let matchedRoute: String?
}

enum TransportMode: String, Codable, CaseIterable {
    case walking, cycling, bus, hsr, car, motorcycle, unknown

    var displayName: String {
        switch self {
        case .walking:    return "步行"
        case .cycling:    return "腳踏車"
        case .bus:        return "公車/客運"
        case .hsr:        return "高鐵"
        case .car:        return "自小客車"
        case .motorcycle: return "機車"
        case .unknown:    return "判斷中..."
        }
    }

    var emoji: String {
        switch self {
        case .walking:    return "🚶"
        case .cycling:    return "🚴"
        case .bus:        return "🚌"
        case .hsr:        return "🚄"
        case .car:        return "🚗"
        case .motorcycle: return "🏍️"
        case .unknown:    return "❓"
        }
    }

    var isGreen: Bool {
        switch self {
        case .walking, .cycling, .bus, .hsr: return true
        case .car, .motorcycle, .unknown: return false
        }
    }
}


// MARK: - Geofence Configuration

struct GeofenceConfig {
    static let zhongliStation = CLLocationCoordinate2D(latitude: 24.9537, longitude: 121.2257)
    static let ncuCampus = CLLocationCoordinate2D(latitude: 24.9681, longitude: 121.1948)
    static let fenceRadius: CLLocationDistance = 200 // meters

    static let zhongliRegion: CLCircularRegion = {
        let region = CLCircularRegion(
            center: zhongliStation,
            radius: fenceRadius,
            identifier: "zhongli_station"
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        return region
    }()

    static let ncuRegion: CLCircularRegion = {
        let region = CLCircularRegion(
            center: ncuCampus,
            radius: 300, // 校園範圍較大
            identifier: "ncu_campus"
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        return region
    }()
}


// MARK: - Location & Motion Tracking Manager

class CommuteTracker: NSObject, ObservableObject, CLLocationManagerDelegate {

    // MARK: Published State
    @Published var isTracking = false
    @Published var currentTrip: TripSession?
    @Published var lastResult: TripResult?
    @Published var detectedActivity: String = "unknown"
    @Published var currentSpeed: Double = 0.0
    @Published var waypointCount: Int = 0
    @Published var errorMessage: String?

    // MARK: Private
    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private let apiClient = APIClient()

    private var gpsTrail: [GPSWaypoint] = []
    private var tripStartTime: Date?
    private var tripStartLocation: CLLocation?
    private var coreMotionActivity: String?

    // 背景定位: 使用 significant location change + geofence
    // 減少電量消耗同時確保能偵測到通勤
    private var isInZhongliZone = false
    private var isInNCUZone = false

    override init() {
        super.init()
        setupLocationManager()
        setupMotionTracking()
    }

    // MARK: - Setup

    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10 // 每移動10m更新一次
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true

        // Request authorization
        locationManager.requestAlwaysAuthorization()
    }

    private func setupMotionTracking() {
        guard CMMotionActivityManager.isActivityAvailable() else {
            print("⚠️ Motion activity not available on this device")
            return
        }

        // 持續監測活動類型
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity = activity else { return }
            DispatchQueue.main.async {
                if activity.walking {
                    self?.detectedActivity = "walking"
                    self?.coreMotionActivity = "walking"
                } else if activity.cycling {
                    self?.detectedActivity = "cycling"
                    self?.coreMotionActivity = "cycling"
                } else if activity.automotive {
                    self?.detectedActivity = "automotive"
                    self?.coreMotionActivity = "automotive"
                } else if activity.stationary {
                    self?.detectedActivity = "stationary"
                } else {
                    self?.detectedActivity = "unknown"
                }
            }
        }
    }

    // MARK: - Geofence Registration

    func startMonitoringGeofences() {
        locationManager.startMonitoring(for: GeofenceConfig.zhongliRegion)
        locationManager.startMonitoring(for: GeofenceConfig.ncuRegion)
        print("📍 Geofence monitoring started for Zhongli Station & NCU")
    }

    func stopMonitoringGeofences() {
        locationManager.stopMonitoring(for: GeofenceConfig.zhongliRegion)
        locationManager.stopMonitoring(for: GeofenceConfig.ncuRegion)
    }

    // MARK: - CLLocationManagerDelegate: Geofence Events

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        print("📍 Entered region: \(region.identifier)")

        switch region.identifier {
        case "zhongli_station":
            isInZhongliZone = true
            // 如果正在追蹤且目的地是中壢 → 結束行程
            if isTracking {
                endTrip(at: GeofenceConfig.zhongliStation)
            }
        case "ncu_campus":
            isInNCUZone = true
            if isTracking {
                endTrip(at: GeofenceConfig.ncuCampus)
            }
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        print("📍 Exited region: \(region.identifier)")

        switch region.identifier {
        case "zhongli_station":
            isInZhongliZone = false
            // 離開中壢車站 → 自動開始通勤追蹤 (往中大方向)
            if !isTracking {
                startTrip(from: .zhongliStation)
            }
        case "ncu_campus":
            isInNCUZone = false
            // 離開中大 → 自動開始通勤追蹤 (往中壢方向)
            if !isTracking {
                startTrip(from: .ncuCampus)
            }
        default: break
        }
    }

    // MARK: - Trip Lifecycle

    enum TripOrigin {
        case zhongliStation
        case ncuCampus
    }

    func startTrip(from origin: TripOrigin) {
        guard !isTracking else { return }

        isTracking = true
        gpsTrail = []
        tripStartTime = Date()
        waypointCount = 0

        let originCoord: CLLocationCoordinate2D
        switch origin {
        case .zhongliStation: originCoord = GeofenceConfig.zhongliStation
        case .ncuCampus:      originCoord = GeofenceConfig.ncuCampus
        }

        tripStartLocation = CLLocation(latitude: originCoord.latitude, longitude: originCoord.longitude)

        // 切換到高精度追蹤
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5
        locationManager.startUpdatingLocation()

        // Notify backend
        Task {
            let session = try? await apiClient.startTrip(
                userId: UserSession.shared.userId,
                latitude: originCoord.latitude,
                longitude: originCoord.longitude
            )
            await MainActor.run {
                self.currentTrip = session
            }
        }

        // 發送本地通知
        sendLocalNotification(
            title: "🌱 通勤追蹤開始",
            body: "正在記錄您從\(origin == .zhongliStation ? "中壢車站" : "中央大學")出發的通勤路線"
        )

        print("🟢 Trip started from \(origin)")
    }

    func endTrip(at destination: CLLocationCoordinate2D) {
        guard isTracking else { return }
        isTracking = false

        // 降回低功耗模式
        locationManager.stopUpdatingLocation()
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = 50

        guard let tripId = currentTrip?.tripId, gpsTrail.count >= 5 else {
            print("⚠️ Trip too short, discarding")
            errorMessage = "軌跡點數不足，此趟不計入"
            return
        }

        // 上傳 GPS 軌跡到後端進行辨識
        Task {
            do {
                let result = try await apiClient.endTrip(
                    tripId: tripId,
                    endLatitude: destination.latitude,
                    endLongitude: destination.longitude,
                    gpsTrail: gpsTrail,
                    coreMotionActivity: coreMotionActivity
                )
                await MainActor.run {
                    self.lastResult = result
                    self.currentTrip = nil

                    // 如果辨識結果不確定, 提示用戶確認
                    if result.transportMode == "unknown" {
                        self.promptUserConfirmation(tripId: tripId)
                    }
                }

                let mode = TransportMode(rawValue: result.transportMode) ?? .unknown
                sendLocalNotification(
                    title: "🌱 通勤紀錄完成",
                    body: "\(mode.emoji) \(mode.displayName) · \(String(format: "%.1f", result.distanceKm))km · 減碳 \(String(format: "%.0f", result.carbonSavedG))g · +\(result.pointsEarned)分"
                )
            } catch {
                await MainActor.run {
                    self.errorMessage = "上傳失敗: \(error.localizedDescription)"
                    // 儲存到本地, 稍後重試
                    self.saveTrailLocally(tripId: tripId)
                }
            }
        }

        print("🔴 Trip ended. Waypoints: \(gpsTrail.count)")
    }

    // MARK: - GPS Updates

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isTracking else { return }

        for location in locations {
            // 過濾精度太差的點
            guard location.horizontalAccuracy <= 50 else { continue }

            let waypoint = GPSWaypoint(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                speedKmh: max(0, location.speed * 3.6), // m/s → km/h
                accuracyM: location.horizontalAccuracy,
                altitudeM: location.altitude,
                recordedAt: location.timestamp
            )
            gpsTrail.append(waypoint)

            DispatchQueue.main.async {
                self.currentSpeed = max(0, location.speed * 3.6)
                self.waypointCount = self.gpsTrail.count
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("❌ Location error: \(error)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            startMonitoringGeofences()
        case .authorizedWhenInUse:
            // 需要 Always 權限才能背景追蹤
            print("⚠️ Need 'Always' location permission for background tracking")
        case .denied, .restricted:
            errorMessage = "請在設定中允許位置存取權限"
        default:
            break
        }
    }

    // MARK: - User Confirmation (for uncertain detection)

    private func promptUserConfirmation(tripId: String) {
        // Trigger a SwiftUI alert or sheet asking user to confirm transport mode
        // This would be handled by the View layer observing a @Published property
        NotificationCenter.default.post(
            name: .tripNeedsConfirmation,
            object: nil,
            userInfo: ["tripId": tripId]
        )
    }

    func confirmTransportMode(tripId: String, mode: TransportMode) {
        Task {
            try? await apiClient.confirmMode(tripId: tripId, mode: mode)
        }
    }

    // MARK: - Offline Storage (fallback)

    private func saveTrailLocally(tripId: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(gpsTrail) {
            UserDefaults.standard.set(data, forKey: "pending_trail_\(tripId)")
            print("💾 GPS trail saved locally for retry")
        }
    }

    func retryPendingUploads() {
        // Iterate over saved trails and retry upload
        // Called on app launch or when network is restored
    }

    // MARK: - Notifications

    private func sendLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Immediate
        )
        UNUserNotificationCenter.current().add(request)
    }
}


// MARK: - Notification Names

extension Notification.Name {
    static let tripNeedsConfirmation = Notification.Name("tripNeedsConfirmation")
}


// MARK: - Trip Session

struct TripSession {
    let tripId: String
    let startTime: Date
}


// MARK: - User Session (singleton)

class UserSession {
    static let shared = UserSession()
    var userId: String = ""
    var accessToken: String = ""
}


// MARK: - API Client

class APIClient {
    let baseURL = "https://api.greencommute.example.com/api/v1"

    private var headers: [String: String] {
        ["Authorization": "Bearer \(UserSession.shared.accessToken)",
         "Content-Type": "application/json"]
    }

    func startTrip(userId: String, latitude: Double, longitude: Double) async throws -> TripSession {
        let body: [String: Any] = [
            "user_id": userId,
            "start_latitude": latitude,
            "start_longitude": longitude,
            "start_time": ISO8601DateFormatter().string(from: Date()),
        ]

        let data = try await post(path: "/trips/start", body: body)
        let tripId = (data["trip_id"] as? String) ?? UUID().uuidString
        return TripSession(tripId: tripId, startTime: Date())
    }

    func endTrip(
        tripId: String,
        endLatitude: Double,
        endLongitude: Double,
        gpsTrail: [GPSWaypoint],
        coreMotionActivity: String?
    ) async throws -> TripResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let trailData = try encoder.encode(gpsTrail)
        let trailArray = try JSONSerialization.jsonObject(with: trailData) as? [[String: Any]] ?? []

        var body: [String: Any] = [
            "trip_id": tripId,
            "end_latitude": endLatitude,
            "end_longitude": endLongitude,
            "end_time": ISO8601DateFormatter().string(from: Date()),
            "gps_trail": trailArray,
        ]
        if let activity = coreMotionActivity {
            body["core_motion_activity"] = activity
        }

        let data = try await post(path: "/trips/end", body: body)
        return TripResult(
            tripId: data["trip_id"] as? String ?? tripId,
            transportMode: data["transport_mode"] as? String ?? "unknown",
            distanceKm: data["distance_km"] as? Double ?? 0,
            carbonEmissionG: data["carbon_emission_g"] as? Double ?? 0,
            carbonSavedG: data["carbon_saved_g"] as? Double ?? 0,
            pointsEarned: data["points_earned"] as? Int ?? 0,
            busMatchScore: data["bus_match_score"] as? Double,
            matchedRoute: data["matched_route"] as? String
        )
    }

    func confirmMode(tripId: String, mode: TransportMode) async throws {
        _ = try await post(
            path: "/trips/\(tripId)/confirm",
            body: ["mode": mode.rawValue]
        )
    }

    // MARK: - HTTP Helper

    private func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.requestFailed
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

enum APIError: Error {
    case requestFailed
    case decodingFailed
    case unauthorized
}


// MARK: - SwiftUI Views

/// 主畫面: 通勤追蹤 Dashboard
struct CommuteDashboardView: View {
    @StateObject private var tracker = CommuteTracker()
    @State private var showConfirmSheet = false
    @State private var pendingTripId: String?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {

                    // ── 即時追蹤狀態卡片 ──
                    trackingStatusCard

                    // ── 最近一趟結果 ──
                    if let result = tracker.lastResult {
                        tripResultCard(result)
                    }

                    // ── 快捷功能 ──
                    HStack(spacing: 12) {
                        NavigationLink(destination: TripHistoryView()) {
                            quickActionButton(icon: "clock.arrow.circlepath", title: "通勤紀錄")
                        }
                        NavigationLink(destination: RewardsView()) {
                            quickActionButton(icon: "gift", title: "兌換獎品")
                        }
                        NavigationLink(destination: LeaderboardView()) {
                            quickActionButton(icon: "trophy", title: "排行榜")
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("🌱 Green Commute")
            .onReceive(NotificationCenter.default.publisher(for: .tripNeedsConfirmation)) { notification in
                if let tripId = notification.userInfo?["tripId"] as? String {
                    pendingTripId = tripId
                    showConfirmSheet = true
                }
            }
            .sheet(isPresented: $showConfirmSheet) {
                TransportConfirmSheet(
                    tripId: pendingTripId ?? "",
                    tracker: tracker
                )
            }
        }
    }

    // MARK: - Tracking Status Card

    private var trackingStatusCard: some View {
        VStack(spacing: 16) {
            HStack {
                Circle()
                    .fill(tracker.isTracking ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 12, height: 12)
                Text(tracker.isTracking ? "追蹤中" : "等待出發")
                    .font(.headline)
                Spacer()
                if tracker.isTracking {
                    Text("\(tracker.waypointCount) 軌跡點")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if tracker.isTracking {
                HStack(spacing: 24) {
                    VStack {
                        Text(String(format: "%.1f", tracker.currentSpeed))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("km/h")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    VStack {
                        Text(tracker.detectedActivity)
                            .font(.system(size: 16, weight: .medium))
                        Text("偵測活動")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text("離開中壢車站或中央大學時自動開始追蹤")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8)
        .padding(.horizontal)
    }

    // MARK: - Trip Result Card

    private func tripResultCard(_ result: TripResult) -> some View {
        let mode = TransportMode(rawValue: result.transportMode) ?? .unknown

        return VStack(spacing: 12) {
            HStack {
                Text("\(mode.emoji) \(mode.displayName)")
                    .font(.title3.bold())
                Spacer()
                if result.pointsEarned > 0 {
                    Text("+\(result.pointsEarned) 分")
                        .font(.headline)
                        .foregroundColor(.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(8)
                }
            }

            HStack(spacing: 20) {
                statItem(value: String(format: "%.1f km", result.distanceKm), label: "距離")
                statItem(value: String(format: "%.0f g", result.carbonEmissionG), label: "碳排放")
                statItem(value: String(format: "%.0f g", result.carbonSavedG), label: "減碳量")
            }

            if let score = result.busMatchScore, score > 0 {
                HStack {
                    Text("路線吻合度")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ProgressView(value: score)
                        .tint(score > 0.6 ? .green : .orange)
                    Text(String(format: "%.0f%%", score * 100))
                        .font(.caption.bold())
                }
            }
        }
        .padding()
        .background(mode.isGreen ? Color.green.opacity(0.05) : Color.orange.opacity(0.05))
        .cornerRadius(16)
        .padding(.horizontal)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(.body, design: .rounded).bold())
            Text(label).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func quickActionButton(icon: String, title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
            Text(title)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}


// MARK: - Transport Confirmation Sheet

struct TransportConfirmSheet: View {
    let tripId: String
    let tracker: CommuteTracker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("請確認交通方式")
                .font(.title2.bold())

            Text("系統無法確定這趟通勤的交通方式，請手動選擇：")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            ForEach(TransportMode.allCases.filter { $0 != .unknown }, id: \.self) { mode in
                Button {
                    tracker.confirmTransportMode(tripId: tripId, mode: mode)
                    dismiss()
                } label: {
                    HStack {
                        Text(mode.emoji)
                            .font(.title2)
                        Text(mode.displayName)
                            .font(.body)
                        Spacer()
                        if mode.isGreen {
                            Image(systemName: "leaf.fill")
                                .foregroundColor(.green)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
    }
}


// MARK: - Placeholder Views

struct TripHistoryView: View {
    var body: some View {
        Text("通勤歷史紀錄")
            .navigationTitle("通勤紀錄")
    }
}

struct RewardsView: View {
    var body: some View {
        Text("可兌換獎品列表")
            .navigationTitle("兌換獎品")
    }
}

struct LeaderboardView: View {
    var body: some View {
        Text("減碳排行榜")
            .navigationTitle("排行榜")
    }
}


// MARK: - Info.plist Required Keys
/*
 Add these to Info.plist for location & motion permissions:

 <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
 <string>Green Commute 需要持續追蹤您的通勤路線以計算碳排放量和發放積分。</string>

 <key>NSLocationWhenInUseUsageDescription</key>
 <string>Green Commute 需要您的位置以追蹤通勤路線。</string>

 <key>NSMotionUsageDescription</key>
 <string>Green Commute 使用動態感測器來辨識您的交通方式（步行、騎車或搭車）。</string>

 <key>UIBackgroundModes</key>
 <array>
     <string>location</string>
 </array>
*/
