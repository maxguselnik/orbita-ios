import Foundation

/// Форматирование чисел HUD по-русски. Цифры в интерфейсе — моноширинные (`.monospacedDigit()`).
enum HUDFormat {
    static let dash = "—"
    static let minus = "\u{2212}"
    /// Узкий неразрывный пробел — разделитель тысяч и перед единицами.
    static let thinSpace = "\u{202F}"

    /// Высота или расстояние: м, км, Мм. nil, NaN → «—», бесконечность → «∞».
    static func distance(_ meters: Double?) -> String {
        guard let meters, !meters.isNaN else { return dash }
        if meters.isInfinite { return meters > 0 ? "∞" : minus + "∞" }
        let sign = meters < 0 ? minus : ""
        let value = abs(meters)
        if value < 10_000 {
            return sign + grouped(value) + " м"
        } else if value < 1_000_000 {
            return sign + fixed(value / 1_000, digits: 1) + " км"
        } else if value < 100_000_000 {
            return sign + fixed(value / 1_000_000, digits: 2) + " Мм"
        } else {
            return sign + grouped(value / 1_000_000) + " Мм"
        }
    }

    /// Скорость: «12.4 м/с», «812 м/с», «12.3 км/с».
    static func speed(_ metersPerSecond: Double) -> String {
        guard metersPerSecond.isFinite else { return dash }
        let sign = metersPerSecond < 0 ? minus : ""
        let value = abs(metersPerSecond)
        if value < 10 {
            return sign + fixed(value, digits: 1) + " м/с"
        } else if value < 100_000 {
            return sign + grouped(value) + " м/с"
        }
        return sign + fixed(value / 1_000, digits: 1) + " км/с"
    }

    /// Вертикальная скорость со знаком: «+96 м/с», «−12 м/с».
    static func signedSpeed(_ metersPerSecond: Double) -> String {
        guard metersPerSecond.isFinite else { return dash }
        let text = speed(abs(metersPerSecond))
        if text == "0.0 м/с" { return text }
        return (metersPerSecond < 0 ? minus : "+") + text
    }

    /// Время миссии: «02:14:05», с сутками «1д 02:14:05».
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return dash }
        let total = Int(max(0, seconds).rounded(.down))
        let days = total / 86_400
        let h = (total / 3_600) % 24
        let m = (total / 60) % 60
        let s = total % 60
        let hms = String(format: "%02d:%02d:%02d", h, m, s)
        return days > 0 ? "\(days)д \(hms)" : hms
    }

    /// Время миссии с префиксом: «Т+ 02:14:05».
    static func missionTime(_ seconds: Double) -> String {
        "Т+ " + clock(seconds)
    }

    /// Обратный отсчёт: «42 с», «1:42», «1:02:03», «2д 03:04». nil, NaN, ∞ → «—».
    static func countdown(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return dash }
        let total = Int(max(0, seconds).rounded())
        let days = total / 86_400
        let h = (total / 3_600) % 24
        let m = (total / 60) % 60
        let s = total % 60
        if days > 0 { return String(format: "%dд %02d:%02d", days, h, m) }
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        if m > 0 { return String(format: "%d:%02d", m, s) }
        return "\(s) с"
    }

    /// Ускорение времени: «×1», «×10 000».
    static func warp(_ factor: Double) -> String {
        "×" + grouped(factor)
    }

    /// Тяговооружённость: «1.52».
    static func twr(_ value: Double) -> String {
        value.isFinite ? fixed(value, digits: 2) : dash
    }

    /// Доля 0…1 в процентах: «73 %».
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return dash }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))" + thinSpace + "%"
    }

    /// Угол в радианах как курс 000…359°.
    static func heading(_ radians: Double) -> String {
        guard radians.isFinite else { return dash }
        var degrees = Int((radians * 180 / .pi).rounded()) % 360
        if degrees < 0 { degrees += 360 }
        return String(format: "%03d°", degrees)
    }

    /// Целое с разделителем тысяч: «10 000».
    static func grouped(_ value: Double) -> String {
        guard value.isFinite else { return dash }
        let rounded = Int(abs(value).rounded())
        var digits = String(rounded)
        var groups: [String] = []
        while digits.count > 3 {
            groups.insert(String(digits.suffix(3)), at: 0)
            digits.removeLast(3)
        }
        groups.insert(digits, at: 0)
        return (value < 0 && rounded != 0 ? minus : "") + groups.joined(separator: thinSpace)
    }

    /// Число с фиксированными знаками после точки (как в согласованном макете: «12.4 км»).
    static func fixed(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}
