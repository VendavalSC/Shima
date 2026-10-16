import SwiftUI

/// The Weather page, after Apple's Weather widget: where, how warm, and the sky now on the leading
/// side, with today's high and low; the next five hours on the trailing side.
struct WeatherSection: View {
    let weather: WeatherMonitor

    var body: some View {
        Group {
            if let forecast = weather.forecast {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 3) {
                            Text(forecast.place).lineLimit(1)
                            if AppSettings.shared.weatherCity == nil {
                                Image(systemName: "location.fill").font(.system(size: 8))
                            }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        Text("\(forecast.temperature)°")
                            .font(.system(size: 36, weight: .regular))
                            .foregroundStyle(.white)
                        Text("H:\(forecast.high)°  L:\(forecast.low)°")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(width: 96, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: WeatherMonitor.symbol(for: forecast.code, isDay: forecast.isDay))
                                .symbolRenderingMode(.multicolor)
                            Text(WeatherMonitor.condition(for: forecast.code))
                                .foregroundStyle(.white)
                        }
                        .font(.system(size: 13, weight: .semibold))
                        HStack(spacing: 0) {
                            ForEach(forecast.hours) { hour in
                                VStack(spacing: 5) {
                                    Text(hour.time.formatted(.dateTime.hour(.defaultDigits(amPM: .narrow))))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.5))
                                    Image(systemName: WeatherMonitor.symbol(for: hour.code, isDay: hour.isDay))
                                        .symbolRenderingMode(.multicolor)
                                        .font(.system(size: 14))
                                        .frame(height: 16)
                                    Text("\(hour.temperature)°")
                                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.white)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "cloud.sun.fill").symbolRenderingMode(.multicolor).font(.system(size: 22))
                    Text(weather.problem ?? "Loading the weather…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 2)
        .onAppear { weather.refreshIfStale() }
    }
}
