// Weather widget: current temperature and condition, or when rain starts in
// the next hours. Its drawer has the details: feels like, high and low, wind,
// sunrise and sunset, and the next twelve hours. Location comes from Core Location (asks once); the
// coordinates, rounded to about 10 km, go to Open-Meteo (free, no account).
// Refreshes every 15 minutes. Hidden when location is denied or offline.
import CoreLocation
import SwiftUI

@MainActor
final class Weather: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var temperature: Int?
    @Published private(set) var symbol = "cloud"
    @Published private(set) var detail = ""
    /// Details for the drawer: today's high and low, feels like, wind in
    /// km/h, sunrise and sunset ("07:58").
    @Published private(set) var high: Int?
    @Published private(set) var low: Int?
    @Published private(set) var feels: Int?
    @Published private(set) var wind: Int?
    @Published private(set) var sunrise = ""
    @Published private(set) var sunset = ""
    @Published private(set) var condition = ""
    /// Next hours: time, temperature, symbol, chance of rain.
    @Published private(set) var hours: [(time: String, temp: Int, symbol: String, rain: Int)] = []

    private let location = CLLocationManager()
    private var coordinate: CLLocationCoordinate2D?

    override init() {
        super.init()
        if Config.demo != nil {
            temperature = 11
            symbol = "cloud.rain.fill"
            detail = "Rain from 15:00"
            high = 13
            low = 6
            feels = 9
            wind = 18
            sunrise = "08:12"
            sunset = "16:41"
            condition = "Rain"
            hours = [("13:00", 11, "cloud.fill", 20), ("14:00", 11, "cloud.fill", 40), ("15:00", 10, "cloud.rain.fill", 70),
                     ("16:00", 10, "cloud.rain.fill", 80), ("17:00", 9, "cloud.rain.fill", 60), ("18:00", 8, "cloud.moon.fill", 30)]
            return
        }
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        location.requestWhenInUseAuthorization()
        location.requestLocation()
        Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.location.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        Task { @MainActor in await self.fetch(latitude: c.latitude, longitude: c.longitude) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        manager.requestLocation()
    }

    private func fetch(latitude: Double, longitude: Double) async {
        let lat = (latitude * 10).rounded() / 10, lon = (longitude * 10).rounded() / 10
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
            + "&current=temperature_2m,apparent_temperature,wind_speed_10m,weather_code,is_day"
            + "&hourly=precipitation_probability,temperature_2m,weather_code,is_day&forecast_hours=13"
            + "&daily=temperature_2m_max,temperature_2m_min,sunrise,sunset&forecast_days=1&timezone=auto")!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let temp = current["temperature_2m"] as? Double,
              let code = current["weather_code"] as? Int
        else { return }
        let day = (current["is_day"] as? Int ?? 1) == 1
        temperature = Int(temp.rounded())
        symbol = Self.symbol(code, day: day)
        feels = (current["apparent_temperature"] as? Double).map { Int($0.rounded()) }
        wind = (current["wind_speed_10m"] as? Double).map { Int($0.rounded()) }
        condition = Self.condition(code)
        if let daily = json["daily"] as? [String: Any] {
            high = (daily["temperature_2m_max"] as? [Double])?.first.map { Int($0.rounded()) }
            low = (daily["temperature_2m_min"] as? [Double])?.first.map { Int($0.rounded()) }
            sunrise = (daily["sunrise"] as? [String])?.first.map { String($0.suffix(5)) } ?? ""
            sunset = (daily["sunset"] as? [String])?.first.map { String($0.suffix(5)) } ?? ""
        }

        // First upcoming hour with a 50%+ chance of rain, if it isn't raining.
        detail = Self.condition(code)
        if let hourly = json["hourly"] as? [String: Any],
           let times = hourly["time"] as? [String], let temps = hourly["temperature_2m"] as? [Double],
           let codes = hourly["weather_code"] as? [Int], let rains = hourly["precipitation_probability"] as? [Int],
           let days = hourly["is_day"] as? [Int] {
            hours = (1..<min(times.count, temps.count, codes.count, rains.count, days.count)).map {
                (String(times[$0].suffix(5)), Int(temps[$0].rounded()), Self.symbol(codes[$0], day: days[$0] == 1), rains[$0])
            }
        }
        if let hourly = json["hourly"] as? [String: Any],
           let times = hourly["time"] as? [String],
           let chances = hourly["precipitation_probability"] as? [Int],
           !(51...99).contains(code),
           let index = chances.indices.dropFirst().first(where: { chances[$0] >= 50 }),
           times.indices.contains(index) {
            detail = "Rain from " + times[index].suffix(5)
        }
    }

    private static func symbol(_ code: Int, day: Bool) -> String {
        switch code {
        case 0: return day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    private static func condition(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67, 80...82: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...99: return "Thunderstorm"
        default: return ""
        }
    }
}

struct WeatherView: View {
    @ObservedObject var weather: Weather

    var body: some View {
        Button { Drawers.shared.toggle("weather") } label: {
            HStack(spacing: 10) {
                Image(systemName: weather.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 24))
                    .contentTransition(.symbolEffect(.replace))
                Lines(title: "\(weather.temperature ?? 0)°", subtitle: weather.detail, maxWidth: 110)
            }
        }
        .buttonStyle(WidgetPress())
        .contextMenu { Button("Open Weather") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Weather.app")) } }
        .animation(.smooth, value: weather.symbol)
    }
}

/// Drawer content: now in detail (condition, feels like, high and low, wind,
/// sunrise and sunset), then the next twelve hours.
struct WeatherHours: View {
    @ObservedObject var weather: Weather

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: weather.symbol).symbolRenderingMode(.multicolor).font(.system(size: 34))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(weather.temperature ?? 0)° \(weather.condition)").font(.system(size: 20, weight: .semibold))
                    if let feels = weather.feels { Text("Feels like \(feels)°").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 20)
                VStack(alignment: .trailing, spacing: 3) {
                    if let high = weather.high, let low = weather.low {
                        Text("H \(high)°  L \(low)°").font(.system(size: 13, weight: .medium)).monospacedDigit()
                    }
                    HStack(spacing: 10) {
                        if let wind = weather.wind { Label("\(wind) km/h", systemImage: "wind") }
                        if !weather.sunrise.isEmpty { Label(weather.sunrise, systemImage: "sunrise.fill") }
                        if !weather.sunset.isEmpty { Label(weather.sunset, systemImage: "sunset.fill") }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary).labelStyle(TightLabel())
                }
            }
            Divider().opacity(0.4)
            hourly
        }
        .padding(16)
        .card()
    }

    private var hourly: some View {
        HStack(spacing: 14) {
            ForEach(weather.hours, id: \.time) { hour in
                VStack(spacing: 6) {
                    Text(hour.time).font(.system(size: 11)).foregroundStyle(.secondary)
                    Image(systemName: hour.symbol).symbolRenderingMode(.multicolor).font(.system(size: 18)).frame(height: 22)
                    Text("\(hour.temp)°").font(.system(size: 13, weight: .semibold))
                    Text("\(hour.rain)%").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(hour.rain >= 50 ? Color(red: 0.45, green: 0.7, blue: 1) : .secondary)
                }
            }
        }
    }
}

/// Icon and text close together.
private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon; configuration.title }
    }
}
