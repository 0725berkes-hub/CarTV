import Foundation
import SwiftUI

/// Auto-detected channel genre. Order here = display order in the UI.
nonisolated enum Genre: String, CaseIterable, Codable, Sendable, Identifiable {
    case news, sports, movies, series, kids, music, documentary, entertainment
    case comedy, animation, education, science, culture, religion, food, travel
    case lifestyle, fashion, health, business, gaming, shopping, weather
    case family, classics, relax, outdoor, regional, publicTV = "public", legal
    case other

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .news:          "News"
        case .sports:        "Sports"
        case .movies:        "Movies"
        case .series:        "Series"
        case .kids:          "Kids"
        case .music:         "Music"
        case .documentary:   "Documentary"
        case .entertainment: "Entertainment"
        case .comedy:        "Comedy"
        case .animation:     "Animation"
        case .education:     "Education"
        case .science:       "Science"
        case .culture:       "Culture"
        case .religion:      "Religion"
        case .food:          "Food"
        case .travel:        "Travel"
        case .lifestyle:     "Lifestyle"
        case .fashion:       "Fashion"
        case .health:        "Health"
        case .business:      "Business"
        case .gaming:        "Gaming"
        case .shopping:      "Shopping"
        case .weather:       "Weather"
        case .family:        "Family"
        case .classics:      "Classics"
        case .relax:         "Relax"
        case .outdoor:       "Outdoor"
        case .regional:      "Local"
        case .publicTV:      "Public"
        case .legal:         "Legal Affairs"
        case .other:         "Other"
        }
    }

    var symbol: String {
        switch self {
        case .news:          "newspaper.fill"
        case .sports:        "sportscourt.fill"
        case .movies:        "film.fill"
        case .series:        "tv.fill"
        case .kids:          "teddybear.fill"
        case .music:         "music.note"
        case .documentary:   "globe.americas.fill"
        case .entertainment: "sparkles.tv.fill"
        case .comedy:        "face.smiling.fill"
        case .animation:     "paintpalette.fill"
        case .education:     "graduationcap.fill"
        case .science:       "atom"
        case .culture:       "theatermasks.fill"
        case .religion:      "hands.and.sparkles.fill"
        case .food:          "fork.knife"
        case .travel:        "airplane"
        case .lifestyle:     "leaf.fill"
        case .fashion:       "tshirt.fill"
        case .health:        "heart.fill"
        case .business:      "chart.line.uptrend.xyaxis"
        case .gaming:        "gamecontroller.fill"
        case .shopping:      "bag.fill"
        case .weather:       "cloud.sun.fill"
        case .family:        "figure.2.and.child.holdinghands"
        case .classics:      "film.stack.fill"
        case .relax:         "moon.stars.fill"
        case .outdoor:       "mountain.2.fill"
        case .regional:      "mappin.and.ellipse"
        case .publicTV:      "building.columns.fill"
        case .legal:         "scale.3d"
        case .other:         "square.grid.2x2.fill"
        }
    }

    /// Accent tint used for tiles without artwork.
    var tint: Color {
        switch self {
        case .news:          Color(hue: 0.00, saturation: 0.70, brightness: 0.85)
        case .sports:        Color(hue: 0.38, saturation: 0.75, brightness: 0.75)
        case .movies:        Color(hue: 0.74, saturation: 0.60, brightness: 0.85)
        case .series:        Color(hue: 0.62, saturation: 0.65, brightness: 0.90)
        case .kids:          Color(hue: 0.12, saturation: 0.80, brightness: 0.95)
        case .music:         Color(hue: 0.88, saturation: 0.70, brightness: 0.90)
        case .documentary:   Color(hue: 0.50, saturation: 0.60, brightness: 0.70)
        case .entertainment: Color(hue: 0.95, saturation: 0.65, brightness: 0.90)
        case .religion:      Color(hue: 0.10, saturation: 0.55, brightness: 0.80)
        case .weather:       Color(hue: 0.55, saturation: 0.55, brightness: 0.90)
        default:             TileTint.color(for: rawValue)
        }
    }
}
