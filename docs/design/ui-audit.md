# Tacho UI audit and redesign directions

Date: 2026-11-05. Status: for the user to choose a direction. No Swift has been written.

**Design canvas (private):** https://claude.ai/artifact/N4JMsEpPBdhLBoTrYjhD41

The canvas has seven pages: Compare, A · Cluster, B · Highlights, C · Trends, Detail pages and log, First launch, and Today's app (renders of the current build).

## Recommendation

Choose **B · Highlights**. It opens on one sentence about what changed, drawn on a chart of the user's own usual range, with pinned cards below in a fixed order. It is the closest match to the brief (insight first, Apple Health's clarity and drill-down, tables second), it needs less new Engine work than C, and it falls back to plain cards with honest "no data yet" text on a new install. Reasons and trade-offs are under [Recommendation](#recommendation-1).

## How this was checked

- **Code:** spec, `Sources/Tacho/**`, `Engine.swift`, `Dashboard.swift`, `Queries.swift`, `Projection.swift`, the progress ledger.
- **Current views:** rendered offscreen with `ImageRenderer` from synthetic data in a scratch package. Tacho was not launched. The activity log's `Table` and the segmented pickers do not draw offscreen, so the log was read from code.
- **Usage shape:** aggregates only, read-only, from Tacho's own store (`mode=ro&readonly_shm=1`). No project, session or path left the script.
- **Caveat on the data:** this is one Mac during an intense multi-agent build, so it shows a heavy user, not a typical one. Dollar figures use base price cards (no fast or long-context cards), so they are approximate.

## The starting points, tested

| Claim in the brief | Measured | Verdict |
|---|---|---|
| Headline rate is about 99% cache reads | 97.0% (7 days), 97.6% (24 h), 97.2% (all time) | True in substance; 97%, not 99% |
| So the rate says little about real work | Output is 0.8% of tokens but 27% of cost | True. But cache reads are still **46% of cost** (14 days), the largest single item. Hiding them would hide real money |
| A jump-and-drop 60 s window reads as noise | In active hours (58 in 14 days) the reading is exactly 0 for 48% of seconds and flips idle/busy about 12 times an hour. p10/p50/p90/p99 = 0 / 115k / 3.7M / 8.6M per minute | True |
| A longer window would fix it | 5 min: reads 0 for 33%, 2.2 flips an hour. 15 min: 22%, 1.2 flips. Spread barely moves (CV 1.77 to 1.63) | Partly: it stops the flicker, not the spread. The spread is real |
| Cost sits low in the panel | In the render the cost total is 916 pt down; the scroll area ends at 652 pt | True. It is below the fold |
| A forecast is one sentence with no trend | `QuotaSection` shows a bar and a sentence. The store keeps every snapshot (8,434 rows) but only the latest is ever read | True |
| Per-CLI rows may not explain what is burning | In non-empty 5-minute slices: sources p50 1, p90 2; sessions p50 2, p90 4, max 19 | True, but the user has since ruled that project grouping does not belong in the main interface |
| Cache efficiency, cost rate, sessions, sub-agents never surface | Confirmed. Sub-agents are 38% of requests and 22% of tokens over 7 days, shown nowhere | True |

Two more findings matter for insights. Daily spend here is very uneven: the last 15 days with use range from $1 to $477, median $54, mean about $109. A plain "30% above your weekly average" would fire on most days, so insights use a median and a usual range, and stay quiet inside it. Also, unpriced tokens over 14 days were zero on this Mac, so a cost figure is rarely blank, while OpenAI and xAI quota data were 14 and 7 days old.

## Audit by surface

### Menu bar

- **The moment:** a half-second glance. Is it running? Am I about to hit a limit?
- **Today:** a gauge and `4.1M/min`, 97% cache reads.
- **Problems:** the figure vanishes for nearly half of active time and comes back about 12 times an hour. A status item that changes width also moves its neighbours (not observed here: this terminal cannot see the menu bar). The needle never moves, so the gauge says nothing until it changes colour.
- **Missing:** a figure that means work done. Now settled by the user: Output by default, with All tokens and Cost as modes.

### Panel

- **The moment:** ten seconds. Is today normal? Will I make it to the reset?
- **Today:** rate, chart, sources table, every quota row, then today.
- **Problems:**
  - It is 974 pt tall with only 5 sources and 5 limits, against a 720 pt cap, so the answer is below the fold.
  - The chart is one green band: with 97% cache reads, the other three layers cannot be seen.
  - Four rows read `0/min`, and `≈ $0.00/h` appears twice. "Updated 2 min ago" repeats on every Anthropic limit.
  - The reset time is never shown. `Projection.resetsAt` is not used by the UI at all.
  - Each limit takes four lines. A stale row reads `0%` beside "No forecast yet" (T17b covers this).
  - The chart's orange and amber are nearly the warning colours; in the render the Output swatch matches the warning bar.
- **Missing:** any comparison, any trend, any sentence of meaning, any way to drill down.

### Overview

- **The moment:** minutes. Where did it go, and how does this compare?
- **Today:** five totals, then three tables with the same five columns.
- **Problems:** no chart on the page; names on the far left and figures on the far right with a wide empty band between; sorted by tokens, so ranking is by cache reads rather than cost; no comparison with any earlier period.
- **Missing:** the trend over day, week, month and year.

### Activity log

- **The moment:** forensic. What was that one expensive request?
- **Today:** a sound table with filters. This is the right shape, and per the user the only place project data should stay.
- **Problems:** no summary of what a filter selects; sub-agent, fast mode, session, and the 5-minute and 1-hour cache write split are all dropped (the split is spec goal 3).

### Heatmaps

- **Problems:** the best-looking page, but it only answers "when". The hour grid has tokens only, and hover is the only way to read a figure. In all three directions these become a card plus a page behind it.

### Settings

- Works, but 55 price rows share a page with everything else. Rate mode needs a place here. Out of scope for this round beyond that.

### First launch

- The CLI chooser and consent are one flow, drawn on the First launch page. The current sheet does not say where the app lives afterwards, so the last step does. When macOS blocks the menu bar item the user needs another way in, drawn on each direction's blocked board.

## Data the Engine has that the UI drops

| Field | Where | Use |
|---|---|---|
| `Projection.resetsAt` | every limit | The reset time, the plainest missing fact |
| `QuotaSnapshot.origin`, `plan`, `observedAt` age | every limit | "How this forecast is made" |
| `Projection.method` | every limit | Shown as a note today; belongs on the detail page |
| `SourceRow.lastActivity` | sources | "Last request 38 min ago" |
| `TokenCounts.reasoning` | everywhere | Share of output spent thinking |
| `cacheWrite5m`, `cacheWrite1h` | everywhere | Spec goal 3 asks for the split |
| `UsageEvent.isSubagent`, `sessionId`, `speed`, `geo`, `provider`, `generationMs` | log rows | Tags and columns in the log |
| `Heatmaps.days` cost | heatmaps | Busiest day and month insights |

## Data that needs a new Engine query

| Need | Today | Change |
|---|---|---|
| **Per-minute cost for the rate window** | Tokens only | `Dashboard.lastMinuteCost: CostSummary` from `pricingGroups` over the rate window, enabled sources only |
| **Output-only rate** | `lastMinute.output` and `series` already hold it | No new query; a `RateMode` preference (Output default, lenient decode) and formatting |
| Cost-mode 60-minute chart | `minuteSeries` has tokens only | `minuteCostSeries`, grouped by minute, model, speed, geo and band; `PriceTable` gains a per-category split |
| The chart honours enabled sources | Known bug in `series` | Fix (already routed to lane beluga) |
| Usual range by time of day | Nothing | `dayCurves(days:)`, per local day, cumulative by quarter hour, from `quarterHourGroups` (already public on the store). Compute once a day and at most once a minute for today; never on the 1 s tick |
| Prior-period comparison | Nothing | `Overview` gains a previous-range total and per-category cost |
| Pace on a limit | `WindowWeights.recent` stays internal | `Projection.pacePercentPerHour` |
| Quota trend and past windows | `latestSnapshots` only | `quotaHistory(limit:since:)`. History exists; 20 five-hour rows in 7 days today, more now the 5-minute fetch runs |
| "Kept off the bill" | Nothing | `PriceTable.cacheSaving(of:)`: cache reads at input price minus what they cost |
| Sub-agent share, log filters | `EventFilter` has neither | `isSubagent` and `sessionId` on `EventFilter` |
| Insights themselves | Nothing | `Insights.compute(...)`, a pure function in TachoKit with the rules below, unit tested |

**Blocked state:** this is app work rather than Engine work. Detect that the status item is not allowed, switch to a regular activation policy so the Dock icon appears, and show the banner. It builds on the T17b window change.

## Insights: what Tacho can honestly say

Every insight is a rule over stored figures. If its minimum history is not met the card says so ("needs 7 days of use: 2 so far"). Inside the usual range it says nothing dramatic.

| Insight | Rule | Min. history | Engine |
|---|---|---|---|
| Cost against usual | Cumulative cost now vs p25 to p75 at this time on the last 14 days with use. Percent is against the median. Fires only outside the range | 7 days with use | New: `dayCurves` |
| Output against usual | Same, on output | 7 days | New: `dayCurves` |
| Week on week | Last 7 days vs the 7 before | 14 days | Exists: `overview` twice |
| Limit forecast | `Projection.outcome` with `resetsAt` | None | Exists |
| Limit pace | Last 30 minutes vs since the window opened | One window | New: pace field |
| Windows that ran out | Snapshots at or near 100% per window; a window with no snapshot counts as unknown | Several windows | New: `quotaHistory` |
| Cache hit rate | `cacheRead ÷ prompt` | None | Exists |
| Cache trend | Daily hit rate, 7 days | 7 days | New: daily rollup |
| Kept off the bill | Σ cache reads × (input rate − cache rate), priced models only, labelled as a what-if | None | New: `cacheSaving` |
| Tokens against cost | Category share by tokens and by cost | None | New: per-category cost |
| When you work | Top cells of `hourOfWeek` | 14 days | Exists |
| Busiest day or month | `Heatmaps.days` | 30 days | Exists |
| Top CLI share | Cost share in `bySource` | None | Exists |
| Speed against usual | Median tok/s vs its 14-day range | 7 days | New: small |
| Sub-agent share | `isSubagent` | None | New: filter |
| Thinking share | `reasoning ÷ output`, only where a source reports it (omp reports none) | None | Exists |

**Never said:** anything about the quality of work, anything that assumes use on other devices, any ranking of projects in the main interface, and any figure for a model with no price.

## The three directions

All three share the same synthetic day, the rate modes, click-to-switch, drill-down, the limit runway, the first launch flow and the blocked state. They differ in what leads and how the surface is organised.

| | A · Cluster | B · Highlights | C · Trends |
|---|---|---|---|
| **Leads with** | The live rate on a dial | A sentence on what changed | The period total, with a Day / Week / Month / Year switch |
| **Organised by** | Fixed tile grid | Highlights, then pinned cards | Time range, which re-scopes every card |
| **Best answers** | What is happening now? | Is today normal? | How does this compare over time? |
| **Weakest at** | What changed | A brand new install | Now; limits sit lowest |
| **Menu bar glyph** | Needle follows the rate | Fixed gauge | Small spark of recent minutes |
| **Panel height, busy** | about 600 pt | about 680 pt | about 620 pt |

The shared detail pages carry the drill-down: Cost (range switch, usual range, highlights, by token type, CLI and model, "About this figure"), Limits (the runway chart, recent windows, how the forecast is made), Cache (tokens against cost, what the cache kept off the bill).

Tacho's own mark, in place of anything from Health: **a needle on a tick scale, with the usual range as a band.**

## Recommendation

**B · Highlights**, because:

1. It is what the user described: cards, a small chart each, a plain-language highlight, drill-down, insights before tables.
2. The sentence does work a chart cannot. With daily spend from $1 to $477, the useful statement is "this is outside your usual range", not a raw figure.
3. Pinned cards keep a fixed order, so only the top slot changes. Spatial memory survives, which is A's main advantage.
4. It degrades honestly: on a new install, or with no quota, the top card says what it needs and the rest stay plain cards.
5. It needs less new Engine work than C, and no peak query, unlike A.

**The cost:** it is the tallest panel, and its value grows with history, so the first week is plainer. Its sentences need careful rules, and each needs a test.

**What would change this:** if the user mostly wants a live glance, A is better. If the user mostly reviews weeks and months, C is better. A's dial or C's range switch can be brought into B later without changing its structure.

## What each direction needs from the Engine

**All directions:** `RateMode` preference; `lastMinuteCost`; `minuteCostSeries` and the per-category split; the `series` fix; `pacePercentPerHour`; `quotaHistory`; `cacheSaving`; `EventFilter` additions; the blocked state.

| Direction | Also needs | Relative size |
|---|---|---|
| A · Cluster | `peakMinute` per mode over 30 days for the dial's scale (cost mode needs pricing per minute, so cache it daily); `dayCurves` for the tiles' usual-range lines | Medium |
| B · Highlights | `dayCurves`; `Insights.compute`; `Preferences.pinnedCards` | Medium |
| C · Trends | `series(range:bucket:)` for every range, previous-period totals on each switch, and a daily rollup so a switch stays under the 100 ms panel budget. The ledger already flags all-history overview cost as unmeasured | Large |

## Spec changes these imply

- **Goal 1 and §5.5, §5.7:** rate modes with Output as default (user-confirmed). The menu bar no longer defaults to all tokens.
- **Goal 2:** project grouping relaxed; project stays as a log filter (user decision).
- **§5.7:** panel and window layouts are replaced by the chosen direction.
- **Changes item 1 (stepped stacked chart):** kept in All tokens and Cost modes. Output mode has one layer, since the other three are not output. See question 3.
- **Fixed value, rate window 60 s:** unchanged in the mockups. See question 2.

## Questions for the user

1. **Which direction?** Recommended: B.
2. **Rate window:** keep 60 s, or average over 5 minutes? 5 minutes cuts flips from about 12 to 2 an hour, and matches the 300 s "active" rule. Recommended: 5 minutes, still shown per minute. This changes a fixed value in the spec.
3. **Chart in Output mode:** one layer instead of four. Recommended: accept, since four stacked layers only make sense for All tokens and Cost.
4. **What counts as usual:** p25 to p75 of the last 14 days with use, shown after 7 days of use. Recommended: accept, or say if a different baseline fits better.

## Originality and privacy

- **ClaudeBar:** nothing taken from its layout, text or assets. Its pace badges, its "Vs date" and "Saved $X" wording and its session status cards were avoided, from the notes in `glassbox/docs/research/claudebar.md`.
- **Existing strings to change:** the current English forecast strings ("Runs out in about…, … before the reset", "Lasts until the reset") sit very close to ClaudeBar's ("Runs out in 38m — 34m before it resets", "Lasts until it resets"). The mockups reword them. The Chinese comes from the spec and is unaffected.
- **Money saved:** the idea was requested by the user and also exists in ClaudeBar, so it keeps a different name and form here.
- **Apple Health:** the clarity and interaction model only: no rings, icons, artwork or layouts.
- **Synthetic data:** every project, path and model name on the canvas that is not a public model id is invented. The bad-price example `acme-coder-2` is invented. Figures are shaped by the aggregates above, not copied from any real day.
- **Unchanged:** the consent text is the existing wording, neither button is default, and "no price" and "no recent quota data" stay honest states.
- **Colour:** token categories move off orange and amber so warnings stay unique: cache read blue, cache write aqua, output violet, input magenta. Passes colour-vision checks in both modes. In light mode aqua and magenta fall below 3:1 against the surface, so every chart carries labels.

## Not verified

- Viewed once in Chrome with the coordinator's approval. Seen at full size: Compare, Menu bar, B's states, A's and B's main windows, and the blocked window for B and C. Seen at canvas zoom only: A's and C's panel states, the light windows, the detail pages, the log, first launch, rate modes and today's app.
- Tested by clicking: the rate figure in B and the range switch in C. The figure in A and C and the range switch on the Cost detail page use the same code but were not clicked.
- These are HTML mockups, so type, vibrancy and heights will differ somewhat in SwiftUI. Panel heights are estimates from the browser.
- Performance of the new charts and queries is unmeasured against §5.11.
- Detecting the blocked state is assumed possible; it has not been tried.
