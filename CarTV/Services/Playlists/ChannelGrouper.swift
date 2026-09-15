import Foundation

/// Maps a channel's group title and name onto a `Genre`.
/// Group title wins over name; keywords are matched on a normalized string.
enum ChannelGrouper {

    nonisolated static func genre(group: String?, name: String) -> Genre {
        if let group, let g = match(group.searchNormalized) { return g }
        if let g = match(name.searchNormalized) { return g }
        return .other
    }

    // Order matters: more specific genres first so "Kids Movies" → kids, "Sport News" → sports.
    nonisolated private static let table: [(Genre, [String])] = [
        (.kids, ["kids", "kid", "children", "child", "cartoon", "junior", "nick", "disney", "baby", "boomerang", "cbeebies",
                 "اطفال", "أطفال", "كرتون", "منداڵ", "مندالان", "çocuk", "cocuk", "infantil", "enfants", "kinder", "детск"]),
        (.animation, ["anime", "animation", "animated", "manga", "انمي", "ئەنیمە"]),
        (.sports, ["sport", "sports", "football", "soccer", "nba", "nfl", "mlb", "nhl", "ufc", "wwe", "espn", "bein", "dazn",
                   "premier league", "la liga", "bundesliga", "serie a", "cricket", "tennis", "golf", "f1", "formula", "motogp", "racing", "fight", "boxing",
                   "رياض", "ریاض", "spor", "deporte", "esporte", "deportes", "спорт", "wer", "وەرزش", "wêrzish", "varzesh"]),
        (.news, ["news", "noticias", "notícias", "nachrichten", "info", "actualité", "haber", "اخبار", "أخبار", "الاخبار", "هەواڵ", "نووچە", "новости", "cnn", "bbc news", "al jazeera", "aljazeera", "sky news", "france 24", "euronews", "rt ", "trt haber", "rudaw", "kurdistan24", "k24", "nrt"]),
        (.movies, ["movie", "movies", "cinema", "cine", "film", "films", "hbo", "action", "thriller", "horror", "drama", "afl", "أفلام", "افلام", "سینما", "فیلم", "فيلم", "kino", "película", "peliculas", "фильм"]),
        (.series, ["series", "serie", "show", "shows", "tv show", "drama series", "مسلسل", "مسلسلات", "زنجیرە", "dizi", "сериал", "novela", "telenovela"]),
        (.documentary, ["documentar", "docu", "discovery", "nat geo", "national geographic", "history", "animal", "wild", "planet", "وثائق", "وثائقي", "بەڵگە", "belgesel", "документ"]),
        (.music, ["music", "musik", "musica", "música", "mtv", "vh1", "hits", "radio", "song", "songs", "موسيق", "أغاني", "اغاني", "مۆسیقا", "گۆرانی", "müzik", "muzik", "музык"]),
        (.religion, ["religio", "islam", "quran", "koran", "christian", "church", "gospel", "bible", "catholic", "hindu", "دين", "ديني", "قرآن", "القرآن", "إسلام", "ئایین", "ئیسلام", "din", "dini", "religión"]),
        (.food, ["food", "cook", "cooking", "chef", "kitchen", "recipe", "طبخ", "مطبخ", "خواردن", "yemek", "cocina", "cuisine"]),
        (.travel, ["travel", "voyage", "tourism", "trip", "سفر", "گەشت", "seyahat", "viaje"]),
        (.weather, ["weather", "meteo", "wetter", "طقس", "کەشوهەوا", "hava durumu", "clima"]),
        (.business, ["business", "finance", "economic", "economy", "bloomberg", "cnbc", "market", "اقتصاد", "ئابووری", "ekonomi", "negocios"]),
        (.education, ["educat", "learn", "school", "university", "teach", "تعليم", "پەروەردە", "eğitim", "egitim", "educación"]),
        (.science, ["science", "tech", "technology", "علوم", "زانست", "bilim", "ciencia"]),
        (.gaming, ["gaming", "game", "games", "esport", "twitch", "oyun", "ألعاب", "یاری"]),
        (.shopping, ["shop", "shopping", "tele shop", "qvc", "hsn", "تسوق", "alışveriş"]),
        (.fashion, ["fashion", "style", "beauty", "موضة", "مۆدە", "moda"]),
        (.health, ["health", "fitness", "medical", "yoga", "wellness", "صحة", "تەندروستی", "sağlık", "salud"]),
        (.comedy, ["comedy", "comedia", "funny", "humor", "كوميدي", "کۆمیدی", "komedi"]),
        (.culture, ["culture", "arts", "art ", "theatre", "theater", "ثقاف", "کولتوور", "kültür", "cultura"]),
        (.lifestyle, ["lifestyle", "life", "living", "home", "garden", "hgtv", "yaşam"]),
        (.legal, ["legal", "law", "court", "قانون", "hukuk"]),
        (.publicTV, ["public", "government", "parliament", "c-span", "cspan", "national", "state tv", "حكومي", "رسمي", "devlet"]),
        (.family, ["family", "familia", "famille", "عائل", "خێزان", "aile"]),
        (.classics, ["classic", "classics", "retro", "vintage", "oldies", "كلاسيك", "klasik"]),
        (.relax, ["relax", "chill", "ambient", "nature", "lounge", "sleep", "meditation", "fireplace", "aquarium"]),
        (.outdoor, ["outdoor", "hunting", "fishing", "adventure", "camping", "صيد", "av ", "avcılık"]),
        (.entertainment, ["entertain", "entretenimiento", "eğlence", "eglence", "ترفيه", "منوعات", "variety", "general", "عام", "گشتی", "genel", "fun", "comedy central", "e!"]),
        (.regional, ["local", "regional", "region", "city", "محلي", "ناوخۆ", "yerel", "bölge"]),
    ]

    nonisolated private static func match(_ text: String) -> Genre? {
        guard !text.isEmpty else { return nil }
        for (genre, keywords) in table {
            for k in keywords where text.contains(k) {
                return genre
            }
        }
        return nil
    }
}
