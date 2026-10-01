import Foundation

/// USD per million tokens.
struct ModelPrice: Codable, Sendable, Equatable {
    var input: Decimal
    var output: Decimal
    var cacheRead: Decimal
    /// Defaults: 1.25× input for 5-minute writes, 2× input for 1-hour writes.
    var cacheWrite5m: Decimal?
    var cacheWrite1h: Decimal?
}

/// API list prices used to put a dollar figure on local logs. For people on a
/// subscription this is what the same usage *would* cost on the API — shown
/// as "API-equivalent", never as what they paid.
///
/// Built in from Anthropic's first-party price list (as of 2026-09-25).
/// `~/Library/Application Support/MyHub/pricing.json` — the same shape, keyed
/// by model-id prefix — overrides or extends it.
struct PriceTable: Sendable {
    let entries: [String: ModelPrice]

    static let anthropicDefaults: [String: ModelPrice] = [
        "claude-fable-5-1": .init(input: 10, output: 50, cacheRead: 0.25),
        "claude-mythos-5-1": .init(input: 10, output: 50, cacheRead: 0.25),
        "claude-fable-5": .init(input: 10, output: 50, cacheRead: 1),
        "claude-mythos-5": .init(input: 10, output: 50, cacheRead: 1),
        "claude-opus-5-5": .init(input: 4, output: 20, cacheRead: 0.2),
        "claude-opus-5": .init(input: 5, output: 25, cacheRead: 0.5),
        "claude-opus-4-8": .init(input: 5, output: 25, cacheRead: 0.5),
        "claude-opus-4-7": .init(input: 5, output: 25, cacheRead: 0.5),
        "claude-opus-4-6": .init(input: 5, output: 25, cacheRead: 0.5),
        "claude-sonnet-5-5": .init(input: 2, output: 10, cacheRead: 0.2),
        "claude-sonnet-5": .init(input: 2, output: 10, cacheRead: 0.2),
        "claude-sonnet-4-6": .init(input: 3, output: 15, cacheRead: 0.3),
        "claude-haiku-4-5": .init(input: 1, output: 5, cacheRead: 0.1),
    ]

    static let standard: PriceTable = {
        var entries = anthropicDefaults
        if let data = try? Data(contentsOf: AppPaths.file("pricing.json")),
           let overrides = try? JSONDecoder().decode([String: ModelPrice].self, from: data) {
            entries.merge(overrides) { $1 }
        }
        return PriceTable(entries: entries)
    }()

    /// Longest matching prefix, so "claude-opus-5-5" never falls back to
    /// "claude-opus-5" and dated ids ("…-4-5-20251001") still match.
    func price(for model: String) -> ModelPrice? {
        let id = model.lowercased()
        return entries.filter { id.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }?.value
    }

    func cost(model: String, input: Int, output: Int, cacheRead: Int, write5m: Int, write1h: Int) -> Decimal? {
        guard let p = price(for: model) else { return nil }
        let w5 = p.cacheWrite5m ?? p.input * Decimal(string: "1.25")!
        let w1 = p.cacheWrite1h ?? p.input * 2
        let total = Decimal(input) * p.input + Decimal(output) * p.output + Decimal(cacheRead) * p.cacheRead
            + Decimal(write5m) * w5 + Decimal(write1h) * w1
        return total / 1_000_000
    }
}
