import CoreLocation
import Foundation
import Observation

/// The forecast as the Weather page shows it.
struct Forecast: Equatable {
    struct Hour: Equatable, Identifiable {
        let time: Date
        let temperature: Int
        let code: Int
        let isDay: Bool
        var id: Date { time }
    }

    let place: String
    let temperature: Int
    let code: Int
    let isDay: Bool
    let high: Int
    let low: Int
    let hours: [Hour]
    let fetched: Date
}

/// The weather where you are (or in a city you pick), from Open-Meteo: free, no account, no key.
/// Only fetched when the Weather page is opened and what Shima has is more than 15 minutes old, so
/// nothing ticks in the background. The location is rounded to about a kilometer before it's sent.
@Observable
final class WeatherMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherMonitor()
    static let freshFor: TimeInterval = 15 * 60

    private(set) var forecast: Forecast?
    private(set) var problem: String?
    private(set) var locationStatus: CLAuthorizationStatus

    @ObservationIgnored private let locations = CLLocationManager()
    @ObservationIgnored private var loading = false
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)

    private override init() {
        locationStatus = locations.authorizationStatus
        super.init()
        locations.delegate = self
        locations.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    private var isAuthorized: Bool { locationStatus == .authorizedAlways }

    /// Fetches the forecast unless what's there is still fresh.
    func refreshIfStale() {
        guard AppSettings.shared.weatherPage else { return }
        if let forecast, Date().timeIntervalSince(forecast.fetched) < Self.freshFor { return }
        refresh()
    }

    func refresh() {
        guard !loading else { return }
        let settings = AppSettings.shared
        if let city = settings.weatherCity {
            loading = true
            fetch(latitude: city.latitude, longitude: city.longitude, place: city.name)
        } else if isAuthorized {
            loading = true
            locations.requestLocation()
        } else if locationStatus == .notDetermined {
            locations.requestWhenInUseAuthorization()
        } else {
            problem = "Choose a city in Settings, or allow Location for Shima."
        }
    }

    /// Asks for Location the first time (macOS shows its prompt).
    func requestLocation() {
        if locationStatus == .notDetermined { locations.requestWhenInUseAuthorization() } else { refresh() }
    }

    /// Looks a city up by name; the first match is used from then on.
    func search(city name: String, completion: @escaping (Bool) -> Void) {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "1"),
                                 URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en")]
        session.dataTask(with: components.url!) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let first = (json?["results"] as? [[String: Any]])?.first
            DispatchQueue.main.async {
                guard let first, let latitude = first["latitude"] as? Double, let longitude = first["longitude"] as? Double else {
                    return completion(false)
                }
                AppSettings.shared.weatherCity = WeatherCity(name: first["name"] as? String ?? name,
                                                             latitude: latitude, longitude: longitude)
                self.forecast = nil
                self.refresh()
                completion(true)
            }
        }.resume()
    }

    // MARK: Location

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationStatus = manager.authorizationStatus
        if isAuthorized, AppSettings.shared.weatherPage, forecast == nil { refresh() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations found: [CLLocation]) {
        guard let location = found.last else { return }
        CLGeocoder().reverseGeocodeLocation(location) { [weak self] places, _ in
            let place = places?.first?.locality ?? places?.first?.name ?? "Here"
            self?.fetch(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, place: place)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        loading = false
        problem = "Shima couldn't find where you are."
        Log.activity.error("weather: location failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: Forecast

    private func fetch(latitude: Double, longitude: Double, place: String) {
        let fahrenheit = Locale.current.measurementSystem == .us
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        session.dataTask(with: components.url!) { [weak self] data, _, error in
            let forecast = data.flatMap { Self.parse($0, place: place) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                if let forecast {
                    self.forecast = forecast
                    self.problem = nil
                    Log.activity.info("weather: updated")
                } else {
                    self.problem = self.forecast == nil ? "The weather couldn't be loaded." : nil
                    Log.activity.error("weather: failed: \(error?.localizedDescription ?? "unreadable", privacy: .public)")
                }
            }
        }.resume()
    }

    private static func parse(_ data: Data, place: String) -> Forecast? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any], let hourly = json["hourly"] as? [String: Any],
              let daily = json["daily"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double, let code = current["weather_code"] as? Int,
              let times = hourly["time"] as? [Double], let temperatures = hourly["temperature_2m"] as? [Double],
              let codes = hourly["weather_code"] as? [Int], let days = hourly["is_day"] as? [Int],
              let highs = daily["temperature_2m_max"] as? [Double], let lows = daily["temperature_2m_min"] as? [Double],
              let high = highs.first, let low = lows.first else { return nil }
        let now = Date()
        let upcoming = times.indices.filter { Date(timeIntervalSince1970: times[$0]) > now }.prefix(5)
        let hours = upcoming.map {
            Forecast.Hour(time: Date(timeIntervalSince1970: times[$0]), temperature: Int(temperatures[$0].rounded()),
                          code: codes[$0], isDay: days[$0] == 1)
        }
        return Forecast(place: place, temperature: Int(temperature.rounded()), code: code,
                        isDay: (current["is_day"] as? Int ?? 1) == 1, high: Int(high.rounded()), low: Int(low.rounded()),
                        hours: hours, fetched: now)
    }

    /// Fills in the page with a fixed forecast, for snapshots.
    func loadSample(_ forecast: Forecast) { self.forecast = forecast }

    // MARK: Conditions

    /// A symbol for a WMO weather code, by day or night.
    static func symbol(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61, 63, 66: "cloud.rain.fill"
        case 65, 67, 82: "cloud.heavyrain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 80, 81: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func condition(for code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly Clear"
        case 2: "Partly Cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61, 63, 66, 80, 81: "Rain"
        case 65, 67, 82: "Heavy Rain"
        case 71...77, 85, 86: "Snow"
        case 95...99: "Thunderstorms"
        default: "Cloudy"
        }
    }
}

/// A city chosen in Settings instead of the Mac's location.
struct WeatherCity: Codable, Equatable {
    let name: String
    let latitude: Double
    let longitude: Double
}
