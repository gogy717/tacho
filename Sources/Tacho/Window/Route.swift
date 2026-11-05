import TachoKit

/// What a card asks of the main window: a page, and how to show it. Spec section 10.
struct Route: Equatable {
    var page: Page
    var metric: TokensMetric?
    var limit: LimitKey?
    var model: String?
    var range: DetailRange?

    init(page: Page, metric: TokensMetric? = nil, limit: LimitKey? = nil, model: String? = nil, range: DetailRange? = nil) {
        self.page = page
        self.metric = metric
        self.limit = limit
        self.model = model
        self.range = range
    }
}

/// What the Tokens page charts.
enum TokensMetric: Equatable {
    case allTokens, output
}

/// One limit, as `latestSnapshots` gives one snapshot for it.
struct LimitKey: Hashable {
    var provider: QuotaProvider
    var window: QuotaWindow
    var scope: String?

    init(provider: QuotaProvider, window: QuotaWindow, scope: String? = nil) {
        self.provider = provider
        self.window = window
        self.scope = scope
    }

    init(_ snapshot: QuotaSnapshot) {
        self.init(provider: snapshot.provider, window: snapshot.window, scope: snapshot.scope)
    }
}
