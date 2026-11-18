import Foundation

/// A message naming a private session, answered by the app itself. The overseer is never told of private
/// sessions, so it cannot route to one; their titles are on screen in the sidebar, so the developer's words
/// are matched against them here, before anything is asked.
enum PrivateRoute: Equatable {
    /// Only going there.
    case goTo(SessionPlace)
    /// More than going there, with no prompt that comes out of the message cleanly.
    case goToAndReply(SessionPlace)
    /// A prompt taken from the message, for the developer to edit before sending.
    case send(SessionPlace, prompt: String)

    var place: SessionPlace {
        switch self {
        case .goTo(let place), .goToAndReply(let place), .send(let place, _): place
        }
    }

    /// The app's answer. It stays in the chat and is never told to the overseer.
    var answer: String {
        let lead = "That is a private session, so the overseer cannot see it."
        return switch self {
        case .goTo: lead + " I can take you there."
        case .goToAndReply: lead + " I can take you there, or you can reply from its page in the sidebar."
        case .send: lead + " Here is the prompt for it to check before sending."
        }
    }

    var card: RoutingCard {
        var card = switch self {
        case .goTo(let place), .goToAndReply(let place): RoutingCard(kind: .goTo([place], missing: []), prompt: "")
        case .send(let place, let prompt): RoutingCard(kind: .send([place], missing: []), prompt: prompt)
        }
        card.isPrivate = true
        return card
    }

    /// The private session the message names: exactly one matches and no other session shares as many of
    /// the message's words. Nil leaves the message to the overseer.
    static func find(_ message: String, in places: [SessionPlace]) -> PrivateRoute? {
        let words = TitleWords.words(message)
        let said = Set(words.filter { !TitleWords.ordinary($0.text) }.map(\.stem))
        guard !said.isEmpty else { return nil }
        let scored = places.map { place in
            let title = TitleWords.distinctive(place.title)
            return (place: place, title: title, shared: title.intersection(said).count)
        }
        let named = scored.filter { $0.place.isPrivate && TitleWords.isMatch(shared: $0.shared, of: $0.title.count) }
        guard named.count == 1, let found = named.first,
              !scored.contains(where: { !$0.place.isPrivate && $0.shared >= found.shared })
        else { return nil }
        return route(message, words: words, title: found.title, to: found.place)
    }

    /// Going there, or a prompt: the words after the session's name, when they read as an instruction.
    private static func route(_ message: String, words: [TitleWords.Word], title: Set<String>, to place: SessionPlace) -> PrivateRoute {
        guard let name = TitleWords.firstRun(of: title, in: words) else { return .goTo(place) }
        let before = words[..<name.lowerBound]
        let after = words[name.upperBound...]
        let asks = before.contains { TitleWords.instructions.contains($0.text) }
        let saysMore = before.contains { !TitleWords.ordinary($0.text) }
            || after.contains { !TitleWords.ordinary($0.text) && !TitleWords.filler.contains($0.text) }
        guard saysMore else { return .goTo(place) }
        guard !before.contains(where: { !TitleWords.ordinary($0.text) }) else { return .goToAndReply(place) }

        var rest = message[words[name.upperBound - 1].range.upperBound...]
        while true {
            rest = rest.drop(while: \.isWhitespace)
            let word = rest.prefix(while: \.isLetter)
            guard !word.isEmpty, TitleWords.filler.contains(word.lowercased()) else { break }
            rest = rest.dropFirst(word.count)
        }
        let lower = rest.lowercased()
        var prompt: Substring?
        if asks, let joiner = ["to", "that"].first(where: { lower.hasPrefix($0 + " ") }) {
            prompt = rest.dropFirst(joiner.count)
        } else if let mark = rest.first, ":,-–".contains(mark) {
            prompt = rest.dropFirst()
        }
        guard let text = prompt.map(String.init)?.trimmedNonEmpty, text.contains(where: \.isLetter) else { return .goToAndReply(place) }
        return .send(place, prompt: text)
    }
}

/// Titles and messages as words, for telling which session a message names.
enum TitleWords {
    struct Word: Equatable {
        /// Lower case, accents dropped.
        let text: String
        /// Without a plural's s, so "tests" names "Fix the test".
        let stem: String
        let range: Range<String.Index>
    }

    /// Navigation and everyday words, which never say which session.
    static let navigation: Set<String> = [
        "go", "goes", "going", "went", "gone", "take", "taking", "took", "bring", "show", "open", "switch", "jump",
        "head", "back", "over", "there", "here", "about", "talking", "talk", "talked", "working", "chat", "chats",
        "session", "sessions", "one", "ones", "tab", "tabs", "window", "conversation", "thread", "let", "lets",
    ]
    static let everyday: Set<String> = [
        "the", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "from", "by", "into", "onto",
        "up", "out", "off", "as", "is", "are", "was", "were", "be", "been", "being", "am", "it", "its", "this", "that",
        "these", "those", "me", "my", "mine", "we", "us", "our", "you", "your", "im", "ive", "id", "ll", "re", "ve",
        "please", "can", "could", "would", "will", "shall", "should", "may", "might", "must", "do", "does", "did",
        "done", "doing", "want", "need", "like", "see", "look", "find", "where", "which", "what", "who", "how",
        "when", "why", "now", "just", "then", "so", "some", "any", "all", "again", "still", "yes", "ok", "okay",
        "hey", "hi", "thanks", "they", "them", "if", "not", "no", "don", "isn", "doesn", "didn", "won", "also",
        "too", "very", "really", "quick", "quickly", "has", "had", "needs", "wants",
    ]
    /// Words that hand a session something to do: "tell the payroll one to ...".
    static let instructions: Set<String> = ["tell", "ask", "say", "send", "message", "instruct", "remind", "get", "have", "make"]
    /// What follows a session's name without being part of the instruction: "the payroll one to ...".
    static let filler: Set<String> = ["one", "ones", "session", "chat", "tab", "thread", "conversation", "window"]
    /// May sit between the words of a title as written in a message.
    static let joiners: Set<String> = ["the", "an", "of", "and", "for", "in", "on", "with"]

    static func ordinary(_ word: String) -> Bool {
        navigation.contains(word) || everyday.contains(word) || instructions.contains(word)
    }

    static func words(_ text: String) -> [Word] {
        text.matches(of: #/[\p{L}\p{N}]+/#).compactMap { match in
            let word = String(match.output).lowercased().folding(options: .diacriticInsensitive, locale: nil)
            // "s" and "t" are what is left of "Rashford's" and "don't".
            guard word.count > 1 || word.allSatisfy(\.isNumber) else { return nil }
            let stem = word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
            return Word(text: word, stem: stem, range: match.range)
        }
    }

    /// The words of a title that can say which session it is.
    static func distinctive(_ title: String) -> Set<String> {
        Set(words(title).filter { !ordinary($0.text) }.map(\.stem))
    }

    /// All of a title's words, or two thirds of three or more.
    static func isMatch(shared: Int, of distinctive: Int) -> Bool {
        shared > 0 && (shared == distinctive || (distinctive >= 3 && shared * 3 >= distinctive * 2))
    }

    /// Where the message first names the session: title words in a row, with joiners between them.
    static func firstRun(of title: Set<String>, in words: [Word]) -> Range<Int>? {
        let names = { (word: Word) in !ordinary(word.text) && title.contains(word.stem) }
        guard let start = words.firstIndex(where: names) else { return nil }
        var end = start + 1
        var index = start + 1
        while index < words.count, names(words[index]) || joiners.contains(words[index].text) {
            if names(words[index]) { end = index + 1 }
            index += 1
        }
        return start..<end
    }
}
