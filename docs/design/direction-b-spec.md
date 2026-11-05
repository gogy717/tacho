# Tacho direction B: implementation spec

Date: 2026-11-05. Direction chosen by the user: **B · Highlights**. The rule of this document: a developer can build every screen from it without opening the canvas. Where the canvas and this document differ, this document wins, and section 1 says why. Checked against the code section by section on 2026-11-05 (TSPEC). A sentence that still differs from the code, with no ruling behind the difference, is left as written and listed for the PM in `task-tspec-report.md`.

- Canvas (reference only): https://claude.ai/artifact/N4JMsEpPBdhLBoTrYjhD41, version `1793813787-56db`
- Audit and evidence: `docs/design/ui-audit.md`
- Authority: `docs/superpowers/specs/2026-11-03-tacho-design.md` outranks this document, except for the decisions below, which the user made after it. That spec's dated section records them, in items 1, 6, 8, 9, 10 and 11.

## 0. Decisions that bind this document

| Decision | Value |
|---|---|
| Direction | B · Highlights |
| Rate window | 300 s, shown per minute: `tokens in (now − 300, now] ÷ 5`. Replaces the fixed 60 s |
| Rate modes | Output (default), All tokens, Cost in $/min. Chosen in Settings or by clicking the figure. The menu bar shows the chosen mode |
| 60-minute chart | Stepped. Output mode is one layer; All tokens and Cost are four stacked layers |
| Usual range | p25 to p75 of the last 14 days with use, shown after 7 days of use |
| Projects | No project grouping in the main interface. Project stays a filter in the activity log |
| Apple Health | A reference for clarity and drill-down. Nothing copied: no rings, icons, artwork or layouts |
| Honest states | "no price", "no recent quota data" and "needs N days of use" stay. Nothing is ever a guessed figure |
| Platform | SwiftUI on macOS 14, native components. Every API named here compiled against a macOS 14 target in a scratch package, and every SF Symbol named exists on macOS 14 |

Original-work rule (spec §2): avoid ClaudeBar's words. Do not use "Runs out in", "Lasts until", "Resets in", "On track", "Running hot", "Room to spare", "Saved $X" or "N% from cache". The old strings `quota.runsOut` and `quota.lastsUntilReset` were too close to ClaudeBar's: the L rules in section 8 replaced them, and they are gone.

## 1. What is wrong on the canvas

Each item says what the canvas shows, why it is wrong, and what to build instead. Numbers such as C4 are referred to below. C1 to C18 concern the foundation and panel; C19 onward concern the main window, detail pages and first launch, except C44 and C45, which concern the panel too.

| # | Canvas shows | Problem | Build this |
|---|---|---|---|
| C1 | Figure menu with right-aligned values; the prototype cycles modes on click instead | A SwiftUI `Menu` item cannot right-align a second column, and the two boards disagree | A `Menu` (section 4.1). Each item is one string, `Output · 11.2k/min`. Clicking does not cycle |
| C2 | While idle the figure is plain text, so the mode cannot be changed | No reason to lock it | The same `Menu`, with `Idle` as its label |
| C3 | `Idle` during a new install | During the recent-logs phase the rate is not known yet, so "idle" could be false | `Reading logs` until the recent phase ends |
| C4 | New install: Cache, Speed and CLIs read "No data yet" | They need no history, only tokens today. Only comparisons need history | Show today's value. "No data yet" only when there is no value to show |
| C5 | Busy caption gives the median, idle caption gives a range | Inconsistent, and a range does not match the percent beside it | Always the median: `usually about $76.00 by 15:42`, in `usdFigure`'s two decimals (ruling TSPEC 20) |
| C6 | "A quiet start, inside your usual range." | "Quiet start" has no rule behind it | `Inside your usual range for this time of day.` |
| C7 | Limit sentence names no limit | With several limits it does not say which | Name it: see L3 in section 8 |
| C8 | Today's cost line is Output's violet | Colour follows the category; cost is not output | `.primary` for cost. Violet only when the card falls back to output |
| C9 | Chart legend is text with no swatches | Identity must not depend on matching order | A 7 pt swatch before each name |
| C10 | A hairline between stacked layers | `AreaMark` has no stroke | No hairline. The validated palette separates the layers |
| C11 | Solid panel and window colours | Stand-ins for system materials | Paint no background. Use the system's (section 2.1) |
| C12 | 11.5 pt text, negative letter spacing | Half points are not a macOS size; SF already adjusts by size | 11 pt, no tracking |
| C13 | `≈64%` | `quota.approximate` is `≈ %@`, with a space | `≈ 64%` |
| C14 | Idle curve drawn on a hand-picked scale, band clipped at the top | A mockup shortcut | One rule for the scale: section 3.3 |
| C15 | 21 ticks on the 52 pt scale | Too dense to read | 11 ticks when narrower than 100 pt |
| C16 | Panel and window pin different cards in different orders | There is one pinned list | One list: section 7 |
| C17 | "Updated 2 min ago" for the whole Limits card | Providers have different ages | Newest age among current limits; a stale limit shows its own age in its cell |
| C18 | Money with cents on large figures, whole dollars elsewhere, with no rule | `TokenFormat.usd` stops cents at $10, which would turn $98.74 into $99 | New `usdFigure` rule: section 2.5 |
| C19 | Detail pages lose the sidebar and use a "Summary" back link | The sidebar already lists these pages, so a second way back is noise, and it hides navigation | Keep the sidebar. A card selects its sidebar page. No back link, no `NavigationStack` |
| C20 | A 21 pt rate figure in the window's toolbar | Toolbar items are the system's size; custom type there is not dependable | A standard toolbar `Menu`, label `11.2k/min` |
| C21 | Settings pinned to the bottom of the sidebar | A row outside the `List` cannot share its selection | Settings is the last row of the `List` |
| C22 | One flat band on the Day chart | Each hour of the day has its own usual; a flat band says something false | A stepped band, per hour |
| C23 | Detail and trend charts stack three layers; proportions are fixed | Input is left out, and the fixed split was a mockup shortcut | Four layers from real figures |
| C24 | Detail charts have no axes | Bars with no scale cannot be read | Y axis on the trailing edge, X labels per range |
| C25 | CLI lists show no clients; token lists show no 5-minute and 1-hour split | Spec goals 2 and 3 ask for both | Client rows under each CLI; the split on the Tokens page |
| C26 | A segmented control picks the limit | Limits vary in number and overflow it at 1040 pt | Rows in "Every limit" are the selector |
| C27 | "2 of 24 windows ran out" | Tacho only knows windows it has a snapshot for | "{n} of {m} recorded windows" |
| C28 | Sentences with no rule: "with one big day today", "Spending has roughly doubled since January", "Three days went over $90", "A usual range for months needs two years of use" | Each is a one-off written for the mockup | Dropped. Every sentence here has a rule |
| C29 | Log filters in the toolbar | Four controls and a search field do not fit at the minimum width | The existing row above the table |
| C30 | Log time column has no date | The log runs across days | Date on rows that are not today |
| C31 | **First launch chooser shows file counts** | Counting files means reading CLI directories before the answer. That breaks "nothing is read until you continue", which T17b proved on a real run | No counts. Detected or not, by the existing existence check |
| C32 | Chooser and setup wording differ from the app; Continue is blue | The app's strings passed review; a blue button reads as the default, and Return must not answer | Keep `setup.*` and the plain button |
| C33 | "Neither button is the default…" under the consent sheet | A design note, not UI | Leave it out |
| C34 | Last setup step says Tacho lives in the menu bar, always | False when macOS has blocked the item | A blocked variant: section 14 |
| C35 | Blocked banner drops "then quit and reopen Tacho" and the Quit button | Both were proven in T17b: the app must restart, and with no panel Quit lives here | Keep `blocked.title`, `blocked.body` and Quit; add Open System Settings |
| C36 | Dock icon is a placeholder gauge | Stand-in | The real app icon, no badge |
| C37 | No board for Tokens, Speed, Calendar, Settings or the pin editor | They are linked from the sidebar and cards | Specified in sections 11 to 13 |
| C38 | Every card but Cache and Limits links to the Cost page | A mockup shortcut | Routes in section 7 |
| C39 | Window's limit card shows the 5-hour limit when idle, though another is higher | No rule | Most urgent, else the highest percent |
| C40 | "How this forecast is made" has a Scale row | The weights' unit is not exposed | A Method row from `Projection.method` |
| C41 | "Busiest: Tue and Wed" | Two days needs a rule of its own | One weekday |
| C42 | Rate modes board explains $/min by a 60-second burst | Out of date at a 300 s window. $/min stays, as decided | Leave the explanation out of the UI |
| C43 | Last setup step has a count for recent logs and a bar for each phase | `filesTotal` covers all files, so a recent-only count does not exist | One bar and the existing `Labels.progress` line |
| C44 | `clis` card has a sparkline of the top CLI's share by day | It needs a query for one small line | A share bar, from `PanelInsights.clis.shares` |
| C45 | Hourly cost for CLIs with no quota has gone | Spec goal 6 keeps it, and the product spec outranks this document | A row in the Limits card and a list on the Limits page |

## 2. Foundation

Built: `Sources/Tacho/Design/Tokens.swift`. Colours are `Theme.tile`, `Theme.amberInk` and so on; type is `Theme.Style`; metrics are `Theme.Size`; the stack order is `Theme.stackOrder`.

### 2.1 Colours

**Surfaces. Paint nothing here unless told to.**

| Token | SwiftUI | Light | Dark | Use |
|---|---|---|---|---|
| Panel background | none: `MenuBarExtra(.window)` supplies it | system | system | Panel |
| Window background | none: `NavigationSplitView` supplies it | system | system | Sidebar, detail |
| `tile` | dynamic | `#000000` 4% | `#FFFFFF` 6% | Card fill |
| `well` | dynamic | `#000000` 9% | `#FFFFFF` 11% | Meter track, usual-range band, grey "last week" bars |
| `hover` | dynamic | `#000000` 9% | `#FFFFFF` 13% | Card hover and pressed fill |
| `tick` | `Color.primary.opacity(0.24)` | | | Scale ticks |
| Separator | `Divider()` | system | system | Between panel sections |

**Text.** `.primary` and `.secondary` only. Never `.tertiary` for text. In light mode `.secondary` on the panel measures about 3.9:1. That is the platform's standard, it follows Increase Contrast and vibrancy, and a custom grey would not; accepted.

| Token | SwiftUI | Light | Dark | Use |
|---|---|---|---|---|
| Accent | `Color.accentColor` | user's | user's | Limit fill, links, Open Tacho |
| `amberFill` | `Color.orange` | system | system | Limit at risk: bar, runway projection, menu bar icon |
| `amberInk` | dynamic | `#8A4B00` | `#FFC56E` | Amber text. System orange fails contrast as text |
| `amberWash` | `Color.orange.opacity(0.14)` | | | The "nothing left" span of the runway |
| `redFill` | `Color.red` | system | system | Limit at 90% or more |
| `redInk` | dynamic | `#B3211A` | `#FF8F87` | Red text |
| `live` | `Color.green` | system | system | Live dot |

Amber and red are reserved for warnings. No chart series may use them.

**Token categories.** They replaced an orange and an amber that could not be told from the warning colours.

| Category | Light | Dark | Stack position, bottom to top |
|---|---|---|---|
| Cache read | `#2A78D6` | `#3987E5` | 1 |
| Cache write | `#1BAF7A` | `#199E70` | 2 |
| Output | `#6250D6` | `#9085E9` | 3 |
| Input | `#E87BA4` | `#D55181` | 4 |

Keep this stack order: the colour-vision check passed for these neighbours (worst adjacent ΔE 19.9 light, 16.0 dark). `TokenCategory.allCases` is in a different order, so charts must not iterate it. Text never takes a category colour; a swatch sits beside it.

### 2.2 Type

SF through the system; Chinese falls back to PingFang SC with no extra work. All figures use `.monospacedDigit()`. Not built in the menu bar label: section 5. Sizes verified with `NSFont.preferredFont` on macOS.

| Token | SwiftUI | Size | Use |
|---|---|---|---|
| `figureXL` | `.system(size: 36, weight: .semibold)` | 36 | Detail page headline figure |
| `figureL` | `.system(size: 21, weight: .semibold)` | 21 | Rate figure, stat figures |
| `sentenceL` | `.system(size: 18, weight: .semibold)` | 18 | Highlight sentence in the window |
| `sentence` | `.system(size: 16, weight: .semibold)` | 16 | Highlight sentence in the panel |
| `value` | `.title3.weight(.semibold)` | 15 | Value on a pinned card; page title |
| `body` | `.body` | 13 | Default |
| `small` | `.callout` | 12 | Limit percent, rows, notes |
| `caption` | `.subheadline` | 11 | Captions, says, axis labels |
| `cardTitle` | `.subheadline.weight(.semibold)`, `.secondary` | 11 | Card and section titles |

On macOS `.caption` is 10 pt, so do not use it on new pages. Calendar and Settings, which section 13 keeps as they were, still have it (ruling TSPEC 16).

### 2.3 Spacing and sizes

| Name | Value |
|---|---|
| Panel width | 360, fixed (existing) |
| Panel side inset | 16 |
| Panel content cap | 652 (`PopoverPanel.contentCap`), 630 during a backfill, because 632 measured 722 through a real window (TUP; confirmed in the TSPEC triage); past it the content scrolls |
| Gap between cards | 8 |
| Card padding | 12 horizontal, 10 vertical |
| Small card padding | 10 horizontal, 8 vertical |
| Gap inside a card | 4 |
| Swatch | 7 × 7, radius 2 |
| Live dot | 7 × 7 circle |
| Limit meter | height 5 |
| Scale height | 13 |
| Main window | default 1240 × 720, minimum 820 × 560, toolbar included (existing). The minimum comes from the root view through `sizingOptions = [.minSize]`: with no options the hosting view clears `contentMinSize` on its first layout |
| Window page inset | 20 |
| Gap between window columns | 20 |

### 2.4 Radii

| Element | Radius |
|---|---|
| Panel, windows, sheets | System. Do not clip or draw them |
| Card | 12, `RoundedRectangle(style: .continuous)` |
| Note inside a card | 8, continuous |
| Meter track and fill | `Capsule()` |
| Band on a scale, swatch | 2 |
| Chart bars | 1.5, `.cornerRadius(1.5)` |

### 2.5 Number and time formats

Fixed formats, the same in both languages, in `TokenFormat`.

| What | Rule | Examples |
|---|---|---|
| Tokens | Existing `compact` | `999`, `1.2k`, `123k`, `1.8M`, `307M` |
| Rate, Output and All tokens | Existing `rate(perMinute:unit:)`, fed the 5-minute average | `11.2k/min`, `4.1M/min`, `187/s` |
| `costRate` | As `usd` does: test the raw value for `<$0.01/min` (above 0, below $0.01), then test the rest on the value rounded to cents. Below $10 two decimals; from $10 whole dollars. Always per minute, whatever the unit setting | `$1.20/min`, `$14/min` |
| Cost rate, some models unpriced | `+` before the slash | `$1.20+/min` |
| Cost rate, nothing priced | `cost.noPrice`. Never `$0` | `no price` |
| `usdFigure` | Exactly 0 is `$0.00`. As `usd` does: test the raw value for `<$0.01`, then the rest on the value rounded to cents. Below $100 two decimals; from $100 whole dollars with a comma | `$0.00`, `$0.62`, `$98.74`, `$375`, `$1,630` |
| `Labels.figure(_ cost: CostSummary)` | The three-way rule of `Labels.cost`, on `usdFigure`. Use this for every figure from a `CostSummary`: nothing unpriced, the amount; some unpriced, a trailing `+`; only unpriced, `cost.noPrice` | `$98.74`, `$98.74+`, `no price` |
| Existing `usd` | Stays for per-request costs in the log | `$0.18` |
| Percent of a limit | `Labels.percent`; `≈ ` when `isEstimate` | `41%`, `≈ 64%` |
| Percent in a sentence | Whole number | `30%` |
| Cache hit | One decimal, `cacheRead ÷ prompt` | `97.8%` |
| Speed | `Labels.speed` | `71 tok/s`, `≈ 71 tok/s` |
| Clock time | `Date.FormatStyle(time: .shortened).locale(Labels.locale)`, so it follows the region | `16:52`, `4:52 PM` |
| Weekday and time | Abbreviated weekday, then clock time, `Labels.locale` | `Sat 09:00`, `周六 09:00` |
| Duration | Existing `Labels.duration` | `1 h 25 min`, `1 小时 25 分钟` |
| `Labels.ageShort` | Largest unit only: days, else hours, else minutes (`age.*`). For tight cells | `7 d`, `5 h`, `12 min`, `7 天` |
| Model short name | `Labels.modelShort`: `claude-<name>-<a>-<b>` becomes `<Name> <a>.<b>`; anything else stays the raw id | `claude-opus-5-5` → `Opus 5.5`; `gpt-6.1-sol` unchanged |

## 3. Drawing

### 3.1 Needle on a tick scale

Built as `NeedleMark` and `NeedleGeometry`. Tacho's own mark: a needle on a tick scale, with the usual range as a band. One `Canvas`, not a `Chart`, so that a card stays cheap. The geometry below was rendered from synthetic values above, below and far outside the band.

Inputs: `value`, and `p25` and `p75` when there is a usual range. Width `w` comes from the layout. Height is always 13.

```
domain  = max(p75 × 2, value × 1.15)       // no usual range: do not draw a scale at all
                                           // domain == 0 (nothing yet, no use at this hour): draw the ticks only
ticks   = w < 100 ? 11 : 21
tick i  : rect x = (w − 1) × i ÷ (ticks − 1), y = 8, width 1, height 5, fill tick
band    : rect x = p25 ÷ domain × w, y = 1, width max(2, (p75 − p25) ÷ domain × w), height 7, radius 2, fill well
needle  : rect x = clamp(value ÷ domain, 0, 1) × (w − 2), y = 0, width 2, height 13, radius 1, fill .primary
```

Draw in that order. The domain keeps the band in the left half and the needle always on the scale: a huge day squeezes the band to the left instead of clipping the needle. The band is never narrower than 2 pt. The scale is `accessibilityHidden`; the card's label says the same in words.

### 3.2 Limit meter

Built as `Meter(value:tick:level:)`, both as fractions. `Capsule` track in `well`, `Capsule` fill to `estimatedPercent`, height 5, drawn (existing reason: a system progress bar greys out in a window that is not key).

| State | `Meter.Level` | Fill |
|---|---|---|
| Normal | `.normal` | Accent |
| `ProjectionEngine.alert([p]) == .amber` | `.warning` | `amberFill` |
| `.red` | `.critical` | `redFill` |
| `isStale`, and no alert | `.stale` | `.secondary` |

Alert colours win over stale.

**Even-pace tick:** a 1.5 × 9 pt rectangle in `.primary`, centred on the track, at `elapsed ÷ window length` of the width, where `elapsed = now − (resetsAt − length)`. It marks where use would be if spread evenly across the window. No tick when stale. Add `.help` on the meter: `limit.tickHelp`.

### 3.3 Usual-range curve

Built as `UsualRangeChart`, fed a `UsualRangeSeries`. On the Cost card and on any `today` highlight. X is hours since local midnight, 0 to 24, `chartXScale(domain: 0...24)`. Axes hidden.

- **Band:** `AreaMark(x:, yStart: p25(q), yEnd: p75(q))` for each of the 96 quarter hours, `.linear`, fill `well`. Omit it below 7 days of use.
- **Today:** `LineMark`, cumulative to now, width 2, `.primary` (`Output` colour when the card has fallen back to output).
- **Now:** one `PointMark` at the end of the line, `symbolSize(36)`, same colour.
- **Y scale:** `0 ... max(today, p75 at 24:00) × 1.05`, always the whole day, whatever the hour. If that top is 0, use `0 ... 1`. A quiet morning sits low on the chart, and that is true.

### 3.4 60-minute chart

Built as `MinuteChart(series:layers:label:selection:emptyText:)`. `AreaMark`, `.interpolationMethod(.stepCenter)`, `chartXScale(domain: -59.5...0.5)`, `stacking: .standard`, one mark per layer per minute, zeros included. The newest step is the minute under way. Axes hidden; a `RuleMark(y: 0)` hairline in the separator colour is the baseline.

| Mode | Layers | Unit | Series |
|---|---|---|---|
| Output | 1, Output colour | tokens a minute | `series[i].output` |
| All tokens | 4, stacked in section 2.1 order | tokens a minute | `series[i]` |
| Cost | 4, stacked, same order | USD a minute | `costSeries[i]` |

The bars are per-minute buckets and the headline is a 5-minute average, so they will not match to the digit. That is correct; `.help` on the figure says what it is.

Under the chart, one row in `caption`: `chart.hourAgo` left, legend centred, `chart.now` right. Output mode's legend is the word Output with no swatch. The other modes show a swatch and name for each layer. On hover, use `chartXSelection`: the centre text becomes the minute and its value, `15:12 · 18.2k`.

Empty hour: `chart.empty` centred at the chart's height. Cost mode with tokens in the hour but none priced: `chart.noPrice` instead.

### 3.5 Sparkline

Built as `Sparkline(values:color:)`. A `Path` in a `Shape`, not a `Chart`. Points evenly spaced, y scaled to the series' own min and max with 2 pt inset, stroke 1.8, round caps and joins. Size 52 × 20 in the panel. Colour: Cache read: the `cache` card is its one use.

## 4. Components

Each is a view taking plain values, and `PanelState` words everything first, so that previews and offscreen tests work. A clickable card is `Card(action:)`; each opens a `Route`: section 10. The headings below name roles, not types: the rate row is `PanelHeader`, the Cost today card is `Highlight` inside `PopoverPanel`, a small card is `TileGrid`'s tile, and the footer is `PopoverPanel.footer`.

**Built in `Sources/Tacho/Design`:** `Card` (`.regular`, `.small`), `CardHeader(title, opens:, trailing:)`, `Say(text, tone:)` with `Tone` `.plain`, `.warning`, `.critical`, `Highlight`, `UsualRangeChart`, `MinuteChart`, `Meter`, `NeedleMark`, `Sparkline`, `ShareBar`, `Swatch`, `LiveBadge(isLive:text:)`.

**Foundation follow-ups.** All six differences the foundation merged with are closed (TUP): a domain of 0 draws ticks only; the band is `max(2, span)`; `Card` has a pressed fill through `CardButtonStyle`; `Highlight` takes `chartHeight` and `figure`; `MinuteChart` takes `emptyText`; `Meter` drops its animation under Reduce Motion, through `Theme.motion`.

### 4.1 RateFigure

A `Menu` with exactly these modifiers: `.menuStyle(.button)`, `.buttonStyle(.plain)`, `.menuIndicator(.hidden)`, `.fixedSize()`. Label: an `HStack(alignment: .firstTextBaseline, spacing: 6)` of the figure in `figureL`, the mode name in `caption`, `.secondary`, and `Image(systemName: "chevron.down")`, `.imageScale(.small)`, `.secondary`.

**Do not use `.menuStyle(.borderlessButton)`:** rendered offscreen with a macOS 14 target on macOS 26, it keeps only the label's first `Text`, so the mode name vanishes and a second chevron appears. The form above drew correctly in the same test.

Contents, top to bottom: a `Picker` with `.pickerStyle(.inline)` and hidden label, one row for each mode, `Output · 11.2k/min`, `All tokens · 4.1M/min`, `Cost · $1.20/min`; `Divider`; `Rate settings…`, which opens Settings. The picked row carries the system check mark. Readings are taken as the menu opens and do not update while it is open.

| State | Label |
|---|---|
| Live | `11.2k/min` Output |
| Idle | `Idle`, then `last request 38 min ago` in `caption` |
| Reading (phase `.idle` or `.recent`) | `Reading logs` as plain text, no menu |
| Cost, some unpriced | `$1.20+/min` Cost, and below the row in `caption`, `amberInk`: `rate.excludes` with the first model, or `rate.excludesUnnamed` if `unpricedModels` is empty |
| Cost, nothing priced | `no price` Cost |

`.help`: `rate.average`. Accessibility label: `rate.switch`, value: the figure and mode.

### 4.2 LiveBadge

`LiveBadge(isLive:text:)`, trailing edge of the rate row, text `live.on` or `live.off`. Live means an event inside the rate window: `!dashboard.isIdle`.

### 4.3 Card

`tile` fill, radius 12, card padding, gap 4. Hover: `hover` fill. Pressed: the same. Title row: `cardTitle`, then a trailing chevron (`chevron.right`, `.imageScale(.small)`, `.secondary`). Small cards have no chevron, because the width is needed for the figure.

### 4.4 CostTodayCard

```
Cost today                                   ›
30% above your usual by this time of day.
[ usual-range curve, 304 × 48 ]
$98.74 so far           usually about $76.00 by 15:42
Not counted: acme-coder-2, 12.4M tokens. Add a price in Settings.
```

Title `card.costToday`; sentence in `sentence` (rule H, section 8), wraps to two lines at most; curve; a row with value `$98.74 so far` (`small`, semibold) and the usual caption (`caption`, `.secondary`, trailing); and the not-counted note in `caption`, `amberInk`, only when something is left out. The card opens the Cost page.

| State | Sentence | Curve | Value row |
|---|---|---|---|
| Reading | H1, or H1h during older logs | Today only | Value, no caption |
| Under 7 days of use | H2 once the phase is `.live` (section 8.1) | Today only | Value, `usual.none` |
| No use today | H3 | Band only | `$0.00 so far`, usual caption |
| Above range | H4, H5, H5s or H6 | Band and today | Value, usual caption |
| Below range | H7, H7s or H7f | Band and today | Value, usual caption |
| Inside range | H8 | Band and today | Value, usual caption |
| Some unpriced | The above-range rows if above; otherwise H9 | Band and today | `$98.74+ so far`, usual caption, note |
| Nothing priced | Title becomes `card.outputToday`, H rules run on output, `.help` says why | Violet line, output band | Output value, usual caption, note |

### 4.5 LimitsCard

```
Limits                          updated 2 min ago ›
Anthropic 5 hours: at this pace empty about 16:52, 1 h 25 min
before the 18:17 reset.
Anthropic  5 h    ▓▓▓▓▓▓|░░░  ≈ 64%      18:17
           Week   ▓▓▓|░░░░░░    41%  Sat 09:00
           Fable  ▓▓▓▓▓|▓░░░    78%  Sat 09:00
ChatGPT    5 h    ▓▓|░░░░░░░    18%      19:40
           Week   ▓|░░░░░░░░     9%  Mon 08:10
xAI        Week   ▓▓▓▓|░░░░░  ≈ 33%    7 d old
```

Title `quota.title`, renamed in English to `Limits` (zh stays 额度). Age in the title row: `quota.updatedAgo`, for the newest `observedAt` among limits that are not stale. The sentence (rules L, section 8) in `caption`: `amberInk` for L3, `redInk` for L1 and L2, `.secondary` otherwise.

Then one line for each limit, in `QuotaProvider.allCases` order, in `LimitColumns`: column gap 6, line gap 5. Five columns: the provider's name (`small`, `.secondary`, on its first line only); the window label (`caption`, `.secondary`, no wrap: `limit.short.fiveHour`, `limit.short.week`, or the scope alone, `Fable`); the meter, section 3.2; the percent (`small`, medium, monospaced digits); and the caption (`caption`, `.secondary`), by the `{reset}` rule in section 8.3, or the age when stale: `limit.age` with `Labels.ageShort`, `7 d old`.

The name, percent and caption each take their widest entry on the card, and a label takes what is left after the shortest meter, so one long caption narrows every meter: from an ideal 64 down to 24 at the least. Cells side by side were tried first: a label and percent over a reset want about 85 pt, three beside the name had 66, and figures were cut off (TLC).

**A limit with `hasRecentData == false`** has no meter and no figure: its cells merge into one line in `caption`, `.secondary`: `limit.noRecent` with `Labels.ageShort`: `No recent quota data · last figure 15 d ago`. Several old limits, beside a recent one or not, merge into one line with the newest age, and it wraps rather than lose the age; the Limits page shows each (ruling TUM).

**CLIs with no quota (spec goal 6, C45):** a last row for sources with `hasQuota == false`, `isActive` and use today (`today.total > 0`). Label `limits.noQuotaShort` in the provider column; then in `caption`, `.secondary`, one line, truncated: `OpenCode ≈ $0.20/h · pi ≈ $0.10/h`, from `Labels.hourlyCost(costLastHour)`. No such sources: no row.

| Card state | Shows |
|---|---|
| No snapshots, query off | L7 as the sentence, no provider rows, no age. The no-quota row stays (ruling TD section 16) |
| No snapshots, query on | L8, no provider rows, no age. The no-quota row stays |
| No snapshots, Claude Code not enabled | L9, no provider rows, no age. The no-quota row stays |
| Some provider current | Rows as above |
| Only old data | L6, then the no-recent lines |

The card opens Limits with the rule's limit selected.

### 4.6 SmallCard

Used for pinned cards in the panel. Small card padding, gap 1.

```
Output today
1.8M           ┆┆┆▇┆┆|┆┆
above your usual
```

Title `cardTitle`. Then a row, spread apart, gap 6: value in `value` with no wrap, shrinking to 0.8 at most, and a mini view from 24 to 52 wide, as the value leaves room (a scale, a sparkline, or nothing). Then a `say` in `caption`, `.secondary`, one line. It shrinks to 0.85 before it truncates, since the words at its end say what a share is of (ruling TSPEC 17). Each card's content is in section 7.

### 4.7 Footer

Existing structure. `footer.open` as `.buttonStyle(.link)`, a spacer, then borderless icon buttons `gearshape` (`footer.settings`) and `power` (`footer.quit`, keeps `.keyboardShortcut("q")`), each with `.help` and an accessibility label. Padding: leading 16, trailing 10, vertical 8. During a backfill a progress block sits above it: section 6.3.

## 5. Menu bar

Keep `MenuBarLabel`: `gauge.with.needle` and text. The needle does not move in direction B. No tinted text; only the icon takes a colour, by the existing `icon(alert:)`.

| State | Icon | Text |
|---|---|---|
| Output (default) | Template | `11.2k/min` |
| All tokens | Template | `4.1M/min` |
| Cost | Template | `$1.20/min` |
| Cost, some unpriced | Template | `$1.20+/min` |
| Cost, nothing priced | Template | `no price` |
| Idle (no event in 300 s) | By alert (ruling TSPEC 19) | None |
| First figures not in, setup unanswered, or phase `.idle` or `.recent` | By alert, so Template until there are figures (ruling TSPEC 19) | None, except in style 5-hour % |
| A limit will run out first | `systemOrange` | Chosen mode |
| A limit at 90% or more | `systemRed` | Chosen mode |
| No quota data | Template | Chosen mode. No data is nothing to warn about |
| Style: Icon only | By alert | None |
| Style: 5-hour % | By alert | `Labels.percent` of Anthropic's account-wide 5-hour limit, none when it has no recent data |
| Blocked by macOS | No item. See section 15 | |

Unit `Per second` applies to Output and All tokens. Figures are the same in both languages. The label should not redraw when the figures have not changed: `AppModel.apply` assigns only a change, and holds a forecast's moment until it is a minute out (TF3).

Not built: the label has no `.monospacedDigit()`, so whether it survives in a `MenuBarExtra` label has never been tried. If it does not, leave it; do not render the label to an image for this.

## 6. Panel

Keeps `PopoverPanel`'s sizing: width 360, content in a `ScrollView` sized to its measured height up to the cap, footer below. The cap is 652, and **630 while the progress block shows**, so the whole panel stays within 720. Do not reintroduce `ViewThatFits` here (the empty-panel bug). `PopoverWindowHeightTests` must keep passing, including `theProgressLineStaysUnderTheCap`.

### 6.1 Order

```
┌ RateRow:  RateFigure ................... LiveBadge      top 12, sides 16
│ MinuteChart  328 × 34                                  gap 6
│ Chart label row                                        gap 6, bottom 10
├ Divider
│ CostTodayCard                                          top 10, sides 16
│ LimitsCard                                             gap 8
│ Pinned cards: 2 columns × 2 rows of SmallCard          gap 8, bottom 12
├ Divider and progress block, during a backfill, outside the scroll view
├ Divider
└ Footer
```

Height with the sample data, measured on the window (TLC): 663 in all, 664 in Chinese. Pinned cards are rows of two equal columns; with no pinned cards the block is left out, and with an odd number the last cell stays empty.

### 6.2 Screen states

| State | When | What changes |
|---|---|---|
| Setup unanswered | `Labels.setupNote` is set | Existing centred note and footer only |
| Failing | `isFailing` | Existing `popover.unavailable` and footer only |
| Waiting | `dashboard == nil` | Existing `popover.waiting` and footer only |
| Reading | `progress.phase` is `.idle` or `.recent` | RateFigure says `Reading logs`; LiveBadge hidden; card H1; progress block |
| Reading older logs | `.history` | Everything normal, plus the progress block. If under 7 days of use: H1h, and the rule in section 8.1 |
| Busy | Events in the window | As in 6.1 |
| Idle | `isIdle` | RateFigure idle; LiveBadge Quiet; the chart keeps what the hour has |
| No quota | No snapshots | LimitsCard L7 or L8. The rest is unaffected |
| Old quota | Snapshots, none recent | LimitsCard L6. No icon colour |
| Some unpriced | `unpricedTokens > 0` | `+` on figures; note on the Cost card; figure note in Cost mode |
| Nothing priced | Priced USD is 0 with tokens | Cost card falls back to output; `no price` in Cost mode |
| Under 7 days of use | `daysOfUse < 7` | H2 once the phase is `.live` (section 8.1); scales hidden; `say` per section 7 |

### 6.3 Progress block

Section with vertical padding 8, side 16, gap 4: `Labels.progress` in `caption`, `.secondary`, one line; `ProgressView(value:)`, `.linear`, `.controlSize(.small)`, value `filesDone ÷ filesTotal`. While `filesTotal` is 0 use the indeterminate `ProgressView()`.

### 6.4 Panel data

The fields the panel reads, as built.

| Need | Built as |
|---|---|
| Output rate | `Dashboard.outputPerMinute` |
| All tokens rate | `Dashboard.perMinute` |
| Cost rate | `Dashboard.costPerMinute`: `CostSummary` |
| `isIdle`, `isActive` | 300 s |
| `series` | `Dashboard.series` |
| `costSeries` | `Dashboard.costSeries`: 60 `CategoryCost`, priced tokens only |
| Today's cost and tokens | `Dashboard.today` |
| Today's cumulative value by quarter hour, for cost and output | `UsualCurve.today` in `PanelInsights.cost` and `.output`, ending at now |
| Usual range now, and by quarter hour | `UsualCurve.band` and `.usualNow`: section 8.1 |
| `daysOfUse` | `PanelInsights.daysOfUse`: days with use before today, up to 14 |
| Projections | `Dashboard.quotas`, with `recentPercentPerHour`, `windowPercentPerHour` and `pacePercentPerHour` |
| Insight results | `Engine.insights`, through `Insights.compute`: section 8. Held 60 s in the engine and never read on the 1 s tick, with one exception: crossing `.live` clears the hold, and with the panel open the tick starts one read, at most twice a backfill |
| Speed usual range, per model | `SpeedInsight.range`, from `History.speedMedians`: section 8.1 |
| Hourly cost of CLIs with no quota | `SourceRow.costLastHour`, `hasQuota` |
| Pinned list | `Preferences.pinnedCards`, lenient decode |
| Rate mode | `Preferences.rateMode`: `RateMode` `.output`, `.allTokens`, `.cost` |

## 7. Cards and pinning

**Fixed cards, not pinnable:** Cost today and Limits. They always come first, in that order.

**Pinned cards:** one ordered list, `Preferences.pinnedCards`. The panel shows the first four; the window shows all of them. Default order:

| # | Id | Title | Value | Mini view | Say | Opens |
|---|---|---|---|---|---|---|
| 1 | `output` | `card.outputToday` | Output tokens today | Scale: today's output against its usual range at this time | P1 to P4 | Tokens, Output, Day |
| 2 | `cache` | `card.cache` | `97.8% hit` | Sparkline: daily hit rate, last 7 days with use; none if fewer than 2 | P5 to P7 | Cache, Day |
| 3 | `speed` | `card.speed` | Median tok/s of the model with the most samples in 24 h | Scale: the last 24 hours' median against that model's usual range | P8 to P10, or P4 with no range | Speed, that model. The card speaks of the last 24 hours, which Week holds, so the page opens on Week |
| 4 | `clis` | `card.clis` | Number of CLIs used today | Share bar: today's share by CLI, top three, in `.primary` at 0.7, 0.45 and 0.25, gap 2 (C44). Each keeps its true width, and whatever is past the top three is one muted segment. By cost, or by tokens when anything today is unpriced: the basis of P12, so that the bar and the sentence beside it agree | P12 | Cost, Day |
| 5 | `tokens` | `card.tokens` | Total tokens today | Share bar: one row, section 2.1 order | P13 | Tokens, All tokens, Day |
| 6 | `when` | `card.when` | None | Hour grid: section 11 | P14 | Calendar |

A card with no value to show says `No data yet` in `value` type, no mini view and no say. Any user can unpin all six. In the panel the `tokens` card's share bar sits in the mini view's slot; the `when` card shows its say only, since the grid does not fit.

Editing happens in the main window: section 11.

## 8. Highlight sentences

Every sentence is a rule over stored figures. Nothing here predicts or judges. `Insights.compute` returns an id and its numbers. `Labels` words rules H, L and P, except P12; `WindowLabels` words P12 and rules W, WL, WC, D, T, K and LH. Test each rule at its boundaries.

### 8.1 Usual range

- **Days with use:** local days before today with at least one event from an enabled source. Walk back up to 90 calendar days and keep the newest 14. (The 90 is my call: it bounds the query. A user back after a long gap restarts the count.)
- **`daysOfUse`:** how many of those there are. A range exists when `daysOfUse >= 7`.
- **Days so far:** what a sentence counts: `daysOfUse`, and today once it has use, so that a card showing tokens does not say none have been seen (TFIRST). The thresholds stay on finished days, so this can reach what a sentence asks for a day before the figure arrives, which is why H2 has a last-day form. "More days" never falls below 1: the day under way is still one more. The window's `stat.usual` and the panel share this rule through `Insights.daysLeft`.
- **Curve:** for each kept day, cumulative value at the end of each of 96 local quarter hours, built from `quarterHourGroups` through `LocalBuckets`. A daylight saving day keeps 96 slots: a repeated hour adds to its slots, a skipped hour stays flat.
- **At time t:** each day's cumulative value at the quarter hour containing t, interpolated by the fraction of that quarter gone.
- **p25, median, p75:** linear interpolation on the sorted values (position `(n − 1) × p`).
- **Refresh:** days are recomputed once a local day, when preferences change, and **when the phase reaches `.live`**, which also covers a rebuild. Otherwise a new install with months of logs would say "needs 7 days" until midnight. Past days are also read again after the rescan a preferences change brings (ruling TE), and at the first read past the 60 s hold when the store's fingerprint of those days has moved (ruling TF). Only today's value moves in between.
- **Until the phase is `.live`,** older days may still arrive, so nothing may say days are missing. Until then H1 or H1h replaces H2, W6 replaces W4, and P4 and the `stat.usual` "needs" text become `reading.logs`. W6 and `reading.logs` hold through `.history` as well, so rules W and P14 say nothing until `.live`.
- **Cost:** priced tokens only, on both sides.
- **Speed is different:** it is a median, not a running total, so the curve above does not apply. For each model, take its median tok/s for each local day with at least 5 samples, over that model's newest 14 such days in 90 calendar days. The range is p25 to p75 of those daily medians, shown after 7 such days. `{n}` in P4 counts that model's days.

### 8.2 Today against usual: rules H

`M` is cost, or output when nothing today has a price. `today`, `p25`, `median`, `p75` are at the current time. `floor` is $0.50 for cost and 1,000 tokens for output.

Work down this table and stop at the first row that applies. `pct` is computed only in the rows that use it, after their `median` check, so the median is never 0 there: `pct = round(abs(today − median) ÷ median × 100)`. `times` is `today ÷ median` to one decimal. In H7, cap `pct` at 99, since some use today is not 100% below.

| Id | When | English | 简体中文 |
|---|---|---|---|
| H1 | Phase `.idle` or `.recent` | Reading your logs. Today's figure is still rising. | 正在读取日志，今天的数字还会上升。 |
| H1h | Phase `.history`, `daysOfUse < 7` | Reading older logs. Your usual range may follow. | 正在读取更早的日志，之后可能会有常见范围。 |
| H2 | `daysOfUse < 7`. `{n}` is days so far, section 8.1 | Your usual range appears after 7 days of use. {n} so far. | 用满 7 天后才有常见范围。目前 {n} 天。 |
| H2, last day | `daysOfUse < 7`, days so far 7 | Your usual range appears tomorrow. | 明天起会有常见范围。 |
| H3 | No tokens today | Nothing yet today. | 今天还没有用量。 |
| H6 | `today > p75`, `median < floor` | More than usual for this time of day. | 比平时这个时候多。 |
| H4 | `today > p75`, `pct >= 300` | {times}× your usual by this time of day. | 是你平时这个时候的 {times} 倍。 |
| H5 | `today > p75`, `pct >= 5` | {pct}% above your usual by this time of day. | 比你平时这个时候多 {pct}%。 |
| H5s | `today > p75` | Just above your usual range for this time of day. | 略高于你这个时段的常见范围。 |
| H9 | `M` is cost, and some of today is unpriced | Some of today has no price, so it can't be compared yet. | 今天有一部分没有价格，暂时无法比较。 |
| H7 | `today < p25`, `median >= floor`, `pct >= 5` | {pct}% below your usual by this time of day. | 比你平时这个时候少 {pct}%。 |
| H7s | `today < p25`, `median >= floor` | Just below your usual range for this time of day. | 略低于你这个时段的常见范围。 |
| H7f | `today < p25` | Less than usual for this time of day. | 比平时这个时候少。 |
| H8 | Otherwise | Inside your usual range for this time of day. | 在你这个时段的常见范围内。 |

With unpriced models, `today` is a lower bound, so "above" holds but "below" and "inside" cannot be claimed: hence H9 after the above rows and before H7.

Worked examples, with p25 41, median 76, p75 84: today 98.74 gives H5, 30%. Today 400 gives H4, 5.3×. Today 60 gives H8. Today 30 gives H7, 61%. With median 0 and p75 0, any use gives H6. With median 0.20 and p25 0.10, today 0.05 gives H7f: below the range, but too small for a percent to mean anything.

Captions: `usual.median` `usually about {median} by {time}` / `平时到 {time} 约 {median}`. `usual.none` `no usual range yet` / `还没有常见范围`. `today.soFar` `{value} so far` / `目前 {value}`.

Not counted: `cost.uncountedTokens`: `Not counted: {models}, {tokens} tokens. Add a price in Settings.` / `未计入：{models}，{tokens} token。可在设置里添加价格。` With more than two models, show two and `more.count`. With no model named, `cost.uncountedTokensUnnamed`: `Not counted: {tokens} tokens from requests that name no model.` / `未计入：{tokens} token，来自没有写明模型的请求。`

### 8.3 Limits: rules L

`limit` is the display name: `Anthropic 5 hours`, `Anthropic weekly`, `Fable weekly`. The rule looks at limits with `hasRecentData` and picks the most urgent: L1, then L2, then L3 with the soonest run-out. L4 alone looks at every limit, old ones included: "every limit" beside one with no recent data would not be true.

| Id | When | English | 简体中文 |
|---|---|---|---|
| L1 | `estimatedPercent` rounds to 100 | {limit} is used up. It resets at {reset}. | {limit}额度已用完，{reset} 重置。 |
| L2 | At 90% or more, not `runsOut` | {limit} is at {percent}. It resets at {reset}. | {limit}额度已用到 {percent}，{reset} 重置。 |
| L3 | `.runsOut` | {limit}: at this pace empty about {empty}, {short} before the {reset} reset. | {limit}额度：照现在的速度约 {empty} 用完，比 {reset} 重置早 {short}。 |
| L4 | Every limit, old ones included, `.lastsUntilReset` or `.idle`, none stale | Every limit is clear for now. | 全部额度暂时都够用。 |
| L5 | Otherwise, some current. A limit with no recent data gives L5, not L4 | No limit looks at risk from the figures Tacho has. | 从现有数据看，没有哪项额度有风险。 |
| L6 | Snapshots exist, none current | No recent quota data. | 没有近期额度数据。 |
| L7 | No snapshots, query off | No quota data yet. Turn on the Claude quota query in Settings. | 还没有额度数据。可在设置里打开 Claude 额度查询。 |
| L8 | No snapshots, query on | Waiting for the first quota reading. | 正在等待第一次额度读数。 |
| L9 | No snapshots, Claude Code not an enabled source. Wins over L7 and L8: there is no first reading to wait for | No quota data yet. | 还没有额度数据。 |

`{reset}` and `{empty}` say which day, by calendar day and not by hours from now (the user's decision, 2026-11-05): today the clock time alone, tomorrow by name, within a week the weekday and time, further out the date and time. A weekly limit reads `empty about Thu 16:52`. `{percent}` comes from `Labels.percent`. `{short}` is the gap between `{empty}` and `{reset}` as printed, so that it is what they subtract to (ruling TGAP). WC1 and `limits.short` take the same gap.

### 8.4 Pinned card says: rules P

`usual` here means the range in section 8.1 for that card's metric. Speed uses the per-model range there.

| Id | Card | When | English | 简体中文 |
|---|---|---|---|---|
| P1 | Output | Above range | above your usual | 高于平时 |
| P2 | Output | Inside | inside your usual range | 在常见范围内 |
| P3 | Output | Below | below your usual | 低于平时 |
| P4 | Output, Speed | Output: `daysOfUse < 7`. Speed: that model has fewer than 7 speed days (section 8.1). `{n}` is what is left after the days so far, section 8.1, and never under 1 | needs {n} more days of use | 还需使用 {n} 天 |
| P4s | Output, Speed | `n == 1` | needs 1 more day of use | 还需使用 1 天 |
| P5 | Cache | Saving known | ≈ {usd} kept off the bill | 账单少了约 {usd} |
| P6 | Cache | Some unpriced | ≈ {usd}+ kept off the bill | 账单少了约 {usd}+ |
| P7 | Cache | Nothing priced | no price | 无价格 |
| P8 | Speed | Inside usual | {model}, usual speed | {model}，速度如常 |
| P9 | Speed | Above | {model}, faster than usual | {model}，比平时快 |
| P10 | Speed | Below | {model}, slower than usual | {model}，比平时慢 |
| P12 | CLIs | Any use. Share of cost; share of tokens when any source has unpriced tokens | `card.clis.sayCost`: {cli}: {pct}% of cost. `card.clis.sayTokens`: {cli}: {pct}% of tokens | {cli} 占费用的 {pct}%；{cli} 占 token 的 {pct}% |
| P13 | All tokens | Any use | {pct}% are cache reads | 其中 {pct}% 是缓存读 |
| P14 | When you work | 14 days of use | Busiest: {weekday}, and {from} to {to} | 最忙：{weekday}；最忙时段：{from} 到 {to} |

"Kept off the bill" is `Σ cacheRead × (input rate − cache read rate)` on each model's card, priced models only. It is a what-if and the Cache page says so. P12 uses cost share, or token share when any source has unpriced tokens, since a share of cost would then be a share of only the priced part. Its text says which it is. Under 14 days of use the `when` card says P4. P14 gives two separate facts: `{weekday}` is the day with the most tokens in `hourOfWeek`; `{from}` to `{to}` is the 3-hour block with the most tokens across all days.

Sentences for the main window and detail pages are in sections 11 and 12.

### 8.5 Strings for the panel

| Key | English | 简体中文 |
|---|---|---|
| `rate.mode.output` | Output | 输出 |
| `rate.mode.tokens` | All tokens | 全部 token |
| `rate.mode.cost` | Cost | 费用 |
| `rate.menu.item` | %1$@ · %2$@ | %1$@ · %2$@ |
| `rate.menu.settings` | Rate settings… | 速率设置… |
| `rate.switch` | Change what the rate shows | 切换速率显示的内容 |
| `rate.average` | Average over the last 5 minutes | 最近 5 分钟的平均值 |
| `rate.idle` | Idle | 空闲 |
| `rate.lastRequest` | last request %@ ago | 上次请求 %@前 |
| `rate.reading` | Reading logs | 正在读取日志 |
| `reading.logs` | still reading logs | 还在读取日志 |
| `rate.excludes` | Excludes %@: no price | 未计入 %@：无价格 |
| `rate.excludesUnnamed` | Excludes requests that name no model | 未计入没有写明模型的请求 |
| `live.on` | Live | 活动中 |
| `live.off` | Quiet | 无活动 |
| `card.costToday` | Cost today | 今天的费用 |
| `card.outputToday` | Output today | 今天的输出 |
| `card.cache` | Cache | 缓存 |
| `card.cache.value` | %@ hit | 命中 %@ |
| `card.speed` | Speed | 速度 |
| `card.clis` | CLIs | CLI |
| `card.tokens` | All tokens today | 今天的全部 token |
| `card.when` | When you work | 使用时段 |
| `card.noData` | No data yet | 还没有数据 |
| `quota.title` | Limits | 额度 |
| `limit.short.fiveHour` | 5 h | 5 小时 |
| `limit.short.week` | Week | 周 |
| `limit.age` | %@ old | %@前 |
| `age.days` | %ld d | %ld 天 |
| `age.hours` | %ld h | %ld 小时 |
| `age.minutes` | %ld min | %ld 分钟 |
| `limits.noQuotaShort` | No quota | 无额度 |
| `chart.noPrice` | No price for this hour's models | 这一小时的模型没有价格 |
| `limit.noRecent` | No recent quota data · last figure %@ ago | 没有近期额度数据 · 最近一次数据在 %@前 |
| `limit.tickHelp` | Where use would be at an even pace | 匀速使用时应到的位置 |

`quota.lastsUntilReset`, `quota.runsOut` and `quota.usedUp` go; the L rules replace them. Limit names on the Limits page and in `{limit}`: `limit.name.fiveHour` `%@ 5 hours` / `%@ 5 小时`, `limit.name.weekly` `%@ weekly` / `%@ 每周`, `limit.name.scoped` `%@ weekly` / `%@ 每周`, the last taking the scope.

## 9. Motion

Little, and all of it value-driven. No `repeatForever`, no `TimelineView` for animation: an idle Tacho must not redraw.

| What | Motion |
|---|---|
| Rate figure value | No animation on a change of value, only on a change of mode: `numericText` on each 1 s tick measured about 780 ms of CPU a second, against 2 to 4 ms without it, in a hidden debug window, which may overstate a release build (ruling TUM). Not in the menu bar |
| Rate mode change | `.easeOut(duration: 0.2)` on the chart swap and the figure |
| Needle moving | None: left unanimated, by decision at TUM. A `Canvas` would need an `Animatable` wrapper |
| Meter fill | `.easeOut(duration: 0.25)` |
| Charts on each 1 s tick | None. Bars just change |
| Card hover | `.easeOut(duration: 0.12)` on the fill |
| New highlight sentence | `.opacity` transition, `.easeOut(duration: 0.2)` |
| Panel open and close | The system's. Add nothing |

With `accessibilityReduceMotion` on, drop all of these except the hover fill. Figures then change with no transition.

## 10. Main window shell

As T17b built it: one `NSWindow` owned by `AppDelegate`, `MainWindow` as `VStack { blocked note; NavigationSplitView }`, default 1240 × 720, minimum 820 × 560, closing drops the views so that a closed window polls nothing. `sceneBridgingOptions` is `.all`, so that `navigationTitle` reaches the window.

**`Page`** is the sidebar's list. Raw values are what `-TachoPage` takes.

| Page | Raw value | Title key | SF Symbol | Section |
|---|---|---|---|---|
| Summary | `summary` | `page.summary` | `square.grid.2x2` | 11 |
| Limits | `limits` | `page.limits` | `gauge.with.needle` | 12.5 |
| Cost | `cost` | `page.cost` | `dollarsign.circle` | 12.2 |
| Tokens | `tokens` | `page.tokens` | `chart.line.uptrend.xyaxis` | 12.3 |
| Cache | `cache` | `page.cache` | `cylinder` | 12.4 |
| Speed | `speed` | `page.speed` | `bolt` | 12.6 |
| Activity log | `activity` | `page.activity` | `list.bullet.rectangle` | 13.1 |
| Calendar | `calendar` | `page.calendar` | `calendar` | 13.2 |
| Settings | `settings` | `page.settings` | `gearshape` | 13.3 |

**Sidebar:** `List(selection:)`, three sections with `navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 240)`:

1. No header: Summary, Limits, Cost, Tokens, Cache, Speed.
2. Header `sidebar.records`: Activity log, Calendar.
3. No header: Settings.

The sidebar shows and hides by its toolbar button and by View > Toggle Sidebar, Control-Command-S, the standard item, which `MainMenu` adds and AppKit retitles Show or Hide. Both send `toggleSidebar:`.

**Toolbar:** `navigationTitle` is the page's title, and the rate menu on Summary: nothing else on any page, so that nothing in the toolbar moves between pages. No other control goes in the title bar: the range there answered on less of itself than it drew, about 20 pt short at each end, and only the real window showed it, as offscreen every point answered. The toolbar goes on a container that stays, never on a `Group` around the loading switch: a `Group` hands it to each branch, so its items were rebuilt as the figures came and went, and a click that landed meanwhile was lost (TLAY). No toolbar item appears or vanishes around a click.

**`PageControls`:** above a page's figures and outside what loads, so that nothing there moves while they do. On Cost, Tokens, Cache and Speed the range comes first, `RangePicker`, in the same place on every page. Then Tokens' metric, Cost's and Tokens' Type, Model, CLI switch, and Speed's model. The row wraps when narrow.

**Reaching a page:** a `Route`, which carries more than `Page` does:

```
struct Route: Equatable { var page: Page; var metric: TokensMetric?; var limit: LimitKey?; var model: String?; var range: DetailRange? }
enum TokensMetric { case allTokens, output }
enum DetailRange { case day, week, month, year }
struct LimitKey: Hashable { var provider: QuotaProvider; var window: QuotaWindow; var scope: String? }
```

The panel's `open` and `AppDelegate.showMainWindow` take a `Route`. `model.page` still drives the sidebar; the rest goes in `model.pendingRoute`. A page reads it on appearing **and** in `.onChange(of: model.pendingRoute)`, since a card may aim at the page already showing, and then clears it. There is no push and no back button (C19). Routes for pinned cards are in section 7; the others are below.

| From | Route |
|---|---|
| Cost today card | Cost, Day |
| Limits card, limit card | Limits, the limit the rule picked |
| Output this week | Tokens, Output, Week |
| `Rate settings…` | Settings |

**Sidebar defaults,** when a page is reached from the sidebar with no route:

| Page | Default |
|---|---|
| Cost | Month |
| Tokens | All tokens, Week |
| Cache | Week |
| Speed | Week, model with the most samples in range |
| Limits | The most urgent limit, else the highest percent |

**Pages load** through `Loaded<Value>` and `.task(id:)`, polling only while `model.mainWindowVisible`. Loading shows `ProgressView`; failure shows `ProblemNote`. Old figures must not stand under a new range's name.

**Summary and Limits keep the figures out of their bodies** (rulings TF3): once a second, only while the page shows, a look builds its worded state from outside the body and assigns it only if something drawn has changed. `model.pageClock`, moved by the first tick of each minute, stands in for `refreshedAt` there. So a figure reaches the page up to a second later, and the page's clock can lag by a minute and a tick. A person's own change does not wait for the look.

**Every width** (TLAY), from the 820 × 560 minimum up, with the sidebar shown or hidden, in both languages: every figure and label is whole and reachable, with nothing cut, overlapping or needing a sideways scroll. Decided by what the content needs at each layout, never by a width remembered from before:

- **Two columns** (`TwoColumns`, a `Layout`) sit side by side while each holds its content in its share, and stack once either would not. A column needs the narrowest its content can take, measured, and at least a floor in ems: 21 em of `small` for a side column, 30 for a main one, 2 cards for Summary's pinned column. The first version pinned each column to the width it last measured, so a page could grow but never shrink, and a smaller window, or the sidebar shown again, cut it off at both sides.
- **Rows reflow** (`Flow`): stats, legends, captions, the log's filters and strip, the Calendar's headings go onto another line rather than squeeze; captions spread across the line when they fit. A figure is never wrapped or cut; a name or a sentence wraps.
- **Cards reflow** (`CardGrid`): Summary's pinned cards take as many equal columns as the room holds, 12 em each at least. Charts take the width they are given.
- **Lists** (`FigureList`, Every limit) give a figure its width and wrap the name: a model's id can be longer than the column. Every limit sizes its columns to their widest entries, with no fixed widths.
- **A slow first read's shape** (`PagePlaceholder`) fits wherever its page does: in a narrow window the detail shape leaves out the cards beside the chart, which the page would put below it.

Each page is a `ScrollView`, with page inset 20 on all sides. `LayoutMatrixTests` holds all of this to the drawing on every page, and Cost and Tokens by Model and by CLI, with the sidebar shown and hidden, at six widths and two heights in both languages, with a contact sheet. It runs only through `scripts/layout-matrix.sh`: `swift test` skips it, as it needs window focus, a quiet machine and minutes.

## 11. Summary

The page a person sees first on opening the app. Looks at `model.dashboard` each second, as section 10 says, and reads insights at most once a minute.

**Toolbar:** title; `navigationSubtitle` with the weekday and time, updating each minute. `ToolbarItem(id: "rate", placement: .primaryAction)`: a standard `Menu`, same contents as RateFigure, label `11.2k/min` (C20). While idle the label is `Idle`.

**Layout:** two columns, widths 1.3 to 1, gap 20, top aligned. Fixed heights throughout, so a taller window leaves space at the bottom rather than stretching.

```
Highlights                                     Pinned                      Edit
┌ Cost today                                 › ┌ Output today ┐ ┌ Cache ──────┐
│ 30% above your usual…              $98.74    │ 1.8M        │ │ 97.8% hit   │
│ [ usual-range curve, height 96 ]             │ [bars]       │ │ [spark]     │
│ 00:00   shaded: your usual…          24:00   │ above…       │ │ ≈ $864…     │
├ Anthropic 5 hours        updated 2 min ago › ├ Speed ───────┤ ├ CLIs today ─┤
│ At this pace it empties about 16:52.  ≈ 64%  │ ≈ 71 tok/s   │ │ rows        │
│ [ runway, height 74 ]                        │ [scale]      │ │             │
│ 13:17   resets 18:17, 1 h 25 min later 18:17 ├ All tokens ──┤ ├ When ───────┤
├ Output this week                           › │ 307M         │ │ [hour grid] │
│ 20% up on last week.                         │ [share bar]  │ │ Busiest…    │
│ [ 14 columns, height 96 ]                    └──────────────┘ └─────────────┘
│ grey: last week                  this week
```

### 11.1 Highlights column

Heading `summary.highlights` in `cardTitle`, gap 8. Three cards with card padding, each with title, chevron, a sentence in `sentenceL`, and a chart.

**1. Cost today.** Rules H, the same as section 4.4, sentence on the left, value on the right in `figureL`. Curve height 96 (section 3.3). Row in `caption`: `00:00`, `summary.bandLegend`, `24:00`. Opens Cost.

**2. Limit.** The limit shown is the one rules L pick; if all are clear, the highest `estimatedPercent` (C39). Title: its name. Age on the right. Sentence (rules WL below) on the left in `amberInk` or `redInk` when it warns; percent on the right in `figureL`. Runway height 74 (section 12.5, no axes). Row in `caption`: window start time, centre text (rules WC), reset time. Opens Limits with this limit selected. With no current limit: title `quota.title`, sentence L6, L7 or L8, no chart.

| Id | When | English | 简体中文 |
|---|---|---|---|
| WL1 | Used up | Used up. It resets at {reset}. | 已用完，{reset} 重置。 |
| WL2 | 90% or more, not `.runsOut` | At {percent}. It resets at {reset}. | 已用到 {percent}，{reset} 重置。 |
| WL3 | `.runsOut` | At this pace it empties about {empty}. | 照现在的速度约 {empty} 用完。 |
| WL4 | `.lastsUntilReset` | Clear to {reset}. | 能撑到 {reset}。 |
| WL5 | `.idle` | Clear for now: not in use. | 暂时够用：现在没在用。 |
| WL6 | `.unknown` | No forecast yet. | 暂无预测。 |
| WC1 | `.runsOut` | resets {reset}, {short} later | {reset} 重置，还要再等 {short} |
| WC2 | Otherwise | resets {reset} | {reset} 重置 |

**3. Output this week.** Title `summary.outputWeek`. Sentence, rules W. Chart height 96: 14 `BarMark`s, the last 7 local days, today so far last, in Output colour, and the 7 before them in `well`, the last of those cut at the time of day it is now, as `outputSevenDaysBefore` is, so that the chart and the sentence agree and a morning does not read about 14% down. One shared Y scale, no axes. `detail(range: .week)` gives these: `columns` and `previousColumns`. Row in `caption`: `summary.lastWeek`, `summary.thisWeek`. Opens Tokens, Output metric, Week.

Work down the table. `pct` is computed only where it is used, so `last week` is never 0 there.

| Id | When | English | 简体中文 |
|---|---|---|---|
| W6 | Any phase before `.live` (ruling TI) | Still reading your logs. This comparison may follow. | 还在读取日志，之后可能会有这个对比。 |
| W4 | Fewer than 14 days of use. `{n}` is days so far, section 8.1 | Comparing weeks starts after 14 days of use. {n} so far. | 用满 14 天后才能按周对比。目前 {n} 天。 |
| W5 | Nothing in the 7 days before | Nothing last week to compare with. | 上周没有用量，无法比较。 |
| W1 | Up 5% or more | {pct}% up on last week. | 比上周多 {pct}%。 |
| W2 | Down 5% or more | {pct}% down on last week. | 比上周少 {pct}%。 |
| W3 | Otherwise | About the same as last week. | 和上周差不多。 |

W2 caps `pct` at 99 with some use left, as H7 does. For W4 and W6 the chart still draws, without the grey columns. "Last week" here means the 7 days before the last 7, as much of them as there is of this week so far, not a calendar week.

### 11.2 Pinned column

Heading row: `summary.pinned` in `cardTitle`, and `Edit` (`summary.edit`, `.buttonStyle(.link)`) trailing. Below, a `Grid` of two equal columns, gap 8, every pinned card in order: a `LazyVGrid` leaves a shorter card short. Card: card padding, title, value in `figureL`, a visual, a say in `caption` of up to two lines. A row's cards share a height.

| Card | Visual, full card width |
|---|---|
| `output` | `Chart`, 24 hourly `BarMark`s of today's output, Output colour, height 50, no axes |
| `tokens` | Share bar: height 8, one rectangle for each category in stack order, gap 2, width by share, at least 4 pt each, outer corners 2 |
| `cache` | Sparkline, height 44, Cache read colour |
| `speed` | Scale, section 3.1, 21 ticks |
| `clis` | Title `card.clisToday`. Value left out. Up to four rows: name and `Labels.figure` (`small`), then a 3 pt meter in `.secondary`, width relative to the top CLI. Further CLIs: `list.more`. Figures are always money. Order and meters take P12's basis, `CLIFigures.shares`: by cost, or by tokens when anything today is unpriced, so that they agree with the say, which names its share. With no answer yet, no meters |
| `when` | Hour grid: `Canvas`, 24 columns × 7 rows, height 78, cells 1 pt apart, colour by `HeatScale` on `hourOfWeek` over the last 30 days |

Says are the P rules, section 8.4. `tokens` says in full: `{pct}% of them are cache reads` / `其中 {pct}% 是缓存读`.

### 11.3 Editing pins

Not on the canvas (C37). `Edit` opens a `.sheet`, width 360:

- Title `pins.title`, note `pins.note` in `small`, `.secondary`.
- A `List` of all six cards in the current order, pinned first, each row a `Toggle` with `.toggleStyle(.checkbox)` and the card's title; `.onMove` to reorder.
- `common.done`, `.keyboardShortcut(.defaultAction)`, saves to `Preferences.pinnedCards`.

### 11.4 States

| State | Change |
|---|---|
| Busy | As drawn |
| Idle | Toolbar label `Idle`. Sentences as the rules give. Idle in the morning is the normal case: nothing special |
| Reading | Toolbar label `Reading logs`, disabled. H1 or H1h. Progress block from section 6.3 above the Highlights heading |
| Under 7 days of use | H2 and W4, or H1 or H1h and W6 before `.live`. No band; no scales; P4 says, or `reading.logs` |
| No quota data | Second card as in 11.1 |
| Unpriced | `+` on figures; the note under the Cost card; H9 where the rule says |
| Blocked | Note above the split view, and the rate strip above the columns: section 15 |
| A week read failed | `ProblemNote` in the chart's place, as a failed read on any page: the sentence and the other cards stay |

## 12. Detail pages

### 12.1 The template

Cost, Tokens, Cache and Speed share this. Two columns, widths 1.75 to 1, gap 20.

**Toolbar:** title. **`PageControls`:** range picker: Day, Week, Month, Year (`range.day` and so on).

**Stacking, on Cost and Tokens:** `GroupingPicker` in `PageControls`: Type (`chart.byType`, the default), Model, CLI, kept for each page through the session in `ChartSession`. Model and CLI read `detail(range:grouping:)`, whose columns and totals come from the rows `series` does, so they add up however the store moves, and stack `layers(of:)`: the top five by what the page draws, then `chart.other` in `seriesOther`. A colour follows the model and not its place (`LayerColours`), so any two can touch and the palette passes for every pair. A stack has no usual band, which is a range of what the Type view draws; the stat still says it. A model with no price has no layer of cost, and `totals.cost` goes on naming it.

| Range | Columns | Previous period |
|---|---|---|
| Day | 24 local hours of today | None: compared with the usual range |
| Week | The last 7 local days, today so far last | The 7 before those, the last cut at the time of day it is now |
| Month | The last 30 local days, today so far last | The 30 before those, the last cut at the time of day it is now |
| Year | Last 12 calendar months, this month last | None |

Week and Month end with today so far, today being the calendar day, up to 23:59: the user's decision, reversing ruling TWD. The previous period is cut at the time of day it is now, so the two compare like with like and a morning does not read as a fall: that is what the 5% lines of D4 to D6, D9 to D11 and W1 to W3 compare. Medians, usual ranges, D7's days, D12 and D13 go on the days before today; today's column is drawn (rulings TWEEK).

**Left column:** a stat row, then the chart, then its legend row.

- **Stat row:** up to three stats, gap 28, baseline aligned. Each is a `caption` label over a figure. First in `figureXL`, the rest in `figureL`.
- **Chart:** `Chart`, height 300, `BarMark`s. Trailing Y axis with 3 marks, hairline grid. X labels: Day `00`, `06`, `12`, `18`; Week weekdays; Month every 7th day; Year month names, all in `Labels.locale`.
- **Hover:** `chartXSelection`. The legend row is replaced by `{label} · {value}`.
- **Legend row** in `caption`: a swatch and name for each layer, then `detail.bandLegend`. No range: leave the band note out.

**Right column:** gap 14. Highlights: `summary.highlights`, then up to three `tile` boxes, padding 8 × 11, `small`. Before `.live` a page's figures are still arriving, so on Cost, Tokens and Cache only D1 and W6 speak. Then the page's lists. Last, **About:** a `tile` box, padding 10 × 12: `detail.about` in `cardTitle`, then the page's text in `caption`.

**Usual range on charts:**

| Range | Band |
|---|---|
| Day | Per hour: `AreaMark(yStart:, yEnd:)`, `.stepCenter`, p25 and p75 of that hour's value across the kept days (C22) |
| Week, Month | One `RectangleMark(yStart:, yEnd:)` across the plot: p25 and p75 of daily totals across the kept days |
| Year | None |

Draw the band first, so it sits behind the bars. Fill `well`. Under 7 days of use: no band, and the Usual range stat reads `needs {n} more days of use`, or `reading.logs` until `.live` (section 8.1).

**Empty range:** `overview.empty` centred in place of the chart. Lists hide.

### 12.2 Cost

Default range Month. Opens from the Cost today card and the `clis` card.

Chart: four stacked layers in USD, section 2.1 order, from real figures (C23). A column with unpriced tokens only has no bar; below the chart, `Labels.notCounted` names what is left out.

| Range | Stat 1 | Stat 2 | Stat 3 |
|---|---|---|---|
| Day | `stat.today`: total | `stat.now`: cost rate | `stat.usual`: `$41.00 to $84.00` at this time |
| Week | `stat.last7` | `stat.medianDay`, over the days before today with use | `stat.usual`: `$20.00 to $70.00 a day` |
| Month | `stat.last30` | `stat.medianDay` | `stat.usual` |
| Year | `stat.last12` | `stat.medianMonth`, over months with use | Left out |

Figures from a `CostSummary` use `Labels.figure`.

Lists: **By token type** (`detail.byType`): share bar, height 10, cost by category, then a two-column grid of swatch, name and percent (`caption`). **By CLI** (`overview.byCLI`): rows of name and `Labels.figure`, with a 3 pt `.secondary` meter below, width relative to the top row. A CLI with more than one client has indented rows below it in `caption`, `.secondary`, from `clientsBySource` (C25). **By model** (`overview.byModel`): rows of `Labels.model` and `Labels.figure`, top five, then `list.showAll`, which opens every row, and `list.showFewer`. Both lists sort by cost, largest first, rows with no price last; `rows()` sorts by tokens, so re-sort here. An unpriced row reads `no price`, never `$0.00`.

Highlights, in order, first three that apply:

| Id | Range | When | English | 简体中文 |
|---|---|---|---|---|
| D1 | Day | Always | The sentence from rules H | 同规则 H |
| D2 | Day | The current hour has the most cost today, at least 2 hours have use, and nothing today is unpriced (ruling TWD, as the TSPEC triage reads it) | The last hour was the busiest today: {usd}. | 最近一小时是今天最贵的：{usd}。 |
| D3 | Any | Tokens and cost known, and cache reads above 0 (ruling TSPEC 22) | Cache reads are {a}% of tokens but {b}% of cost. | 缓存读占 token 的 {a}%，但占费用的 {b}%。 |
| D4 | Week | Up 5% or more | {pct}% up on the previous 7 days. | 比此前 7 天多 {pct}%。 |
| D5 | Week | Down 5% or more | {pct}% down on the previous 7 days. | 比此前 7 天少 {pct}%。 |
| D6 | Week | Within 5% | About the same as the previous 7 days. | 和此前 7 天差不多。 |
| D7 | Week | The top 2 days before today hold half or more of the week so far | {n} days carried {pct}% of the week. | {n} 天占了本周 {pct}% 的费用。 |
| D8 | Week | Output's share of cost moved 3 points or more | Output's share of cost went from {a}% to {b}%. | 输出的费用占比从 {a}% 变为 {b}%。 |
| D9 | Month | Up 5% or more | {pct}% up on the previous 30 days. | 比此前 30 天多 {pct}%。 |
| D10 | Month | Down 5% or more | {pct}% down on the previous 30 days. | 比此前 30 天少 {pct}%。 |
| D11 | Month | Within 5% | About the same as the previous 30 days. | 和此前 30 天差不多。 |
| D12 | Month | A range exists, and at least one day before today above it | {n} days were above your usual range. | 有 {n} 天高于常见范围。 |
| D13 | Month | At least one day before today with no use | {n} days had no use. | 有 {n} 天没有用量。 |
| D14 | Year | A month with cost above 0 (ruling TSPEC 21) | {month} was the busiest month: {usd}. | {month}最忙：{usd}。 |
| D15 | Year | Any use | {n} days with use in the last 12 months. | 最近 12 个月用过 {n} 天。 |

A period's cost claims (D3 to D12, K3, K4, `medianCost`) hold while its unpriced tokens are under 2% of its tokens; over that they are left out. For `medianCost` and D12 the 2% is of the days before today they go on. `Labels.notCounted` beside them still names what is excluded.

D5 and D10 cap `pct` at 99 with some use left, as H7 does. Week and month comparisons need a full previous period with use; otherwise leave them out. With one day, D7 reads `1 day carried`: `{n}` takes the plural form in English.

About: `about.cost`.

### 12.3 Tokens

Not on the canvas (C37). Same template. Default range Week. In the page's controls above its figures (section 10): a segmented `Picker`, All tokens and Output, set by the card that opened the page.

- **All tokens:** four stacked layers. **Output:** one layer, Output colour. Band as in 12.1 for the metric shown.
- **Stats:** first, total for the range; second, `stat.output`, or `stat.allTokens` when Output is picked; third, `stat.usual`, left out on Year as on Cost.
- **By token type** (`detail.byType`): a `FigureList`, one row each, with `TokenFormat.compact`: `category.input`, `category.output`, `tokens.thinking` (indented), `category.cacheRead`, `prices.cacheWrite5m`, `prices.cacheWrite1h`. The thinking row shows only where a source reports it (C25).
- **By CLI:** as in 12.2, in tokens, clients included. **By model:** likewise.

Highlights: the W rules for Week, using the metric shown; then:

| Id | When | English | 简体中文 |
|---|---|---|---|
| T1 | Some source has `reasoning > 0` in range. `pct` is reasoning ÷ the output of those sources only | {pct}% of output was thinking, where recorded. | 在有记录的来源里，输出中有 {pct}% 是思考。 |
| T2 | Any events in range | Sub-agents made {pct}% of requests. | 子代理发起了 {pct}% 的请求。 |

About: `about.tokens`.

### 12.4 Cache

Default range Week.

**Stats:** `stat.hitRate`; `stat.kept`, `about $864`; `stat.writes`, cost of cache writes in the range.

**Chart:** height 200. `LineMark`, width 2.4, Cache read colour, `PointMark` at the end. Y scale: the series' minimum less 1 point, to 100, with a trailing axis. Day plots hours; Week and Month days; Year months. Legend row: `cache.legend`.

**The same range, counted two ways:** below the chart, heading `cache.twoWays`. Two share bars, height 14, gap 10, each with a label row above: `cache.byTokens` and total, `cache.byCost` and total. Legend: one line for each category, stacked, in `caption`: a swatch and `cache.share`, `Cache read: 97% of tokens, 46% of cost`.

**Right column:** Highlights; **By CLI** (`overview.byCLI`): rows of name, a meter in Cache read colour, and hit rate; About.

| Id | When | English | 简体中文 |
|---|---|---|---|
| K1 | Week with a full previous period (ruling TWD), moved 0.5 points or more. `{a}` and `{b}` to one decimal | Your hit rate went from {a}% to {b}% this week. | 本周命中率从 {a}% 变为 {b}%。 |
| K2 | Week with a full previous period, moved less | Your hit rate held near {b}% this week. | 本周命中率保持在 {b}% 左右。 |
| K3 | Tokens and cost known, and cache reads above 0 (ruling TSPEC 22) | Cache reads are {a}% of your tokens but {b}% of your cost. | 缓存读占 token 的 {a}%，但占费用的 {b}%。 |
| K4 | Cost known, and cache writes above 0 (ruling TSPEC 22) | Cache writes cost {usd}: {b}% of the bill from {a}% of the tokens. | 缓存写花了 {usd}：占费用的 {b}%，来自 {a}% 的 token。 |

About: `about.cache`. Nothing priced: the Kept and Writes stats read `no price`; K3 and K4 are left out.

### 12.5 Limits

No range picker. Same two columns.

**Selected limit:** set by the card that opened the page, else the most urgent. The toolbar's subtitle is its name.

**Stats:** `stat.used` in `figureXL`, the percent. `stat.empties` in `figureL`, `amberInk`, `about 16:52`, by the `{empty}` rule: only for `.runsOut`. `stat.resets`, by the `{reset}` rule.

**Runway chart:** height 250, `Chart`, X is `Date` from window start to `resetsAt`, Y 0 to 100.

| Mark | Spec |
|---|---|
| Grid | `RuleMark(y:)` hairlines at 0, 50 and 100 |
| Used | `LineMark`, `.stepEnd`, width 2.4, Accent. Points: window start at 0, every snapshot in this window, then now at `estimatedPercent`. With no snapshots in yet, `.linear` between those two points: steps would say all the use came at once, just now. Group by `resetsAt`, treating values within 60 s as one window |
| Now | `RuleMark(x: now)`, `.secondary`, and a `PointMark`, `symbolSize(50)` |
| Forecast, `.runsOut` | `LineMark` from now to the run-out time at 100, width 2.4, `dash: [5, 5]`, `amberFill`. `PointMark` at the end. `RectangleMark` from there to the reset, full height, `amberWash` |
| Forecast, `.lastsUntilReset` | Same line to the reset, at `estimatedPercent` plus pace × time left, `.secondary`. No wash |
| `.idle`, `.unknown`, used up | No forecast marks |

Row in `caption`: `limits.opens` with the start time, `limits.now` with the current clock time, `limits.short` with the gap for `.runsOut`, and `limits.reset` with the reset time. Summary's small runway is this chart at height 74 with no 50 line.

**Recent windows:** heading `limits.recent`. `Chart`, height 68, the last 24 recorded windows of this limit: one `BarMark` each at its highest reading, `well`; `amberFill` if it reached 100; Accent for the current one. Row in `caption`: `limits.oldest` left, with the age of the oldest window through `Labels.ageShort`; `limits.recentOf` centred (C27); `chart.now` right. Fewer than 2 recorded windows: leave this block out.

**Right column:**

- Highlights, rules LH.
- **How this forecast is made:** `tile` box, rows of label and value in `small`:

  | Row | Value |
  |---|---|
  | `how.last` | `62%, 2 min ago` |
  | `how.from` | `quota.origin.*` |
  | `how.since` | `how.sinceValue`, `+2% from local use`, when `isEstimate` and the reset has not passed; `how.resetSince` when the engine has moved `resetsAt` on from the snapshot's, since the page's own clock can be a minute behind (TF3); otherwise `how.noChange` |
  | `how.pace` | `how.pace.recent` when `.calibrated`, `how.pace.window` when `.windowAverage` |
  | `how.method` | `how.method.calibrated` or `how.method.window` (C40) |
  | `how.plan` | `snapshot.plan`, row left out when nil |

  Below, `quota.footnote` in `caption`, `.secondary`.
- **Every limit:** heading `limits.every`. A column of plain `Button` rows: one for each limit, name in `small` (width 116), a meter, percent. Selected row in `hover` fill (C26). No-recent rows show `limit.noRecent` instead of the meter.
- **No quota here** (spec goal 6, C45): heading `limits.noQuota`, then a row for each enabled source with `hasQuota == false` and use today (`today.total > 0`, because `hasQuota` is false for any source unused today), name and `Labels.hourlyCost(costLastHour)`. Left out if there are none.

| Id | When | English | 简体中文 |
|---|---|---|---|
| LH1 | `.calibrated`, both paces above 0, recent at least 1.1 × average, and the printed figures differ (ruling TSPEC 23) | This window is running ahead: {recent}% an hour lately, against {avg}% an hour since it opened. | 这个窗口用得偏快：最近每小时 {recent}%，窗口开始以来每小时 {avg}%。 |
| LH2 | `.calibrated`, both paces above 0, recent at most 0.9 × average, and the printed figures differ (ruling TSPEC 23) | This window has slowed: {recent}% an hour lately, against {avg}% an hour since it opened. | 这个窗口慢下来了：最近每小时 {recent}%，窗口开始以来每小时 {avg}%。 |
| LH3 | 5 or more finished windows, the current one left out, once the phase is `.live` (confirmed in the TSPEC triage) | Recent windows peaked around {median}%. | 最近的窗口峰值大约在 {median}%。 |
| LH4 | 5 or more finished windows; current above p75 of their peaks; once the phase is `.live` (confirmed in the TSPEC triage) | This window is past most recent peaks. | 这个窗口已超过最近大多数窗口的峰值。 |

`{recent}` and `{avg}` take one decimal, because a weekly pace can be 0.3% an hour.

**States:**

| State | Page |
|---|---|
| No snapshots | Centred: L7 or L8, and `limits.openSettings` when L7 |
| Selected limit has no recent data | Stats and charts hidden. `limit.noRecent` in `body`, then the right column |
| Stale | `isStale`: meter grey unless it warns, since alert colours win over stale (section 3.2), `quota.mayBeStale` beside the used stat. Forecast marks stay, as the rule allows |
| `.windowAverage` | `quota.windowAverage` beside the used stat |
| Used up | Used stat in `redInk`; L1 as first highlight |

### 12.6 Speed

Not on the canvas (C37). Same template. Default range Week. In the page's controls above its figures (section 10): a menu `Picker` of models with samples in the range, most samples first. It keeps the last figures' models while the next are read, so it does not go blank and come back around a click.

**Stats:** `stat.median`, `≈ 71 tok/s`, over the range; `stat.usual`, the chosen model's range from section 8.1, or P4 by that model's speed days; `stat.samples`. A model with any request timed by an approximate start marks its median, its usual range, once at the front, and its chart's readout with `≈`.

**Chart:** height 300, one `LineMark`, width 2, `.primary`, the chosen model's median by hour, day or month. Week and Month have one `RectangleMark` band from that model's range. Day and Year have no band. Chart hidden with fewer than 2 points: `speed.few`.

**Right column:** one highlight, the P rule for the chosen model; **All models** (`speed.models`): rows of `Labels.modelShort`, `Labels.speed`, sample count in `caption`; About: `about.speed`.

## 13. Records and Settings

### 13.1 Activity log

Keep `ActivityLogPage`'s loading, paging and merge logic.

**Filter row** (existing, C29): CLI, Project, Model pickers and the search field, 200 wide, padding 16. They go onto a second line rather than squeeze their titles, and so does the strip below.

**Summary strip**, new, below it: one row in `small`, gap 24, padding 8 × 20, with a bottom divider. Each item a `.secondary` label and a medium figure: `log.showing` with `log.requests` (`formatted()`, so `1,204`), `log.cost`, `log.output`, `log.cacheHit`, `log.subagents` `38% of requests`. Trailing `log.clear`, `.buttonStyle(.link)`, shown only when a filter is set. The strip covers everything matching, not just loaded rows.

**Table** columns, ideal widths: Time 148, CLI 82, Project 72, Model 153, Input 46, Output 50, Cache read 66, `log.write5m` 60, `log.write1h` 36, Cost 52, tok/s 72. `Table` spends 17 beside each column and 15 at the edges, so all eleven fill a 1039 detail: the default window less its sidebar and the split view's 1 pt divider. A point over and AppKit shaves the first two columns, which cuts Time at 1x. So as the log narrows, whole columns give way instead (`LogColumn.givingWay`, through `TableColumnCustomization`), least wanted first: `log.write1h`, `log.write5m`, tok/s, Input, Cache read, Project, Output. Time, CLI, Model and Cost never go, and the person cannot hide them. A hidden column's value stays in every cell's tooltip, a line each: `Cache write, 1 h: 1.2k`. At the 820 minimum with the sidebar, Time, CLI, Model, Output and Cost show. Time fits the widest older row of every language: `Labels.locale` takes the clock from the region, and only `CN` gives Chinese 24 hours, so `10月28日 上午12:48:58`, at 147, is the common case for Chinese outside China and sets the width. CLI shows the CLI's name alone, and `.help` adds the client: `Claude Code · Terminal` would need 144, and the name is what the column is for.

- **Time:** today `15:41:52`; another day `Nov 4, 15:41:52` (C30).
- **CLI:** `displayName`, with `Labels.source(of:)` as its `.help`.
- **Model:** id, then chips in `caption` on `tile` fill, radius 5: `log.tagAgent` when `isSubagent`, `log.tagFast` when `speed == "fast"`. One line, and the id gives way before the chips. The whole id if it fits; if not, `WindowLabels.modelFamily`, which drops `claude-` and a date suffix, cut at its end, so that the family name goes last: a row of one vendor's models differ there. `.help` gives the whole id. At the column's 90 minimum a chip truncates too.
- **Secondary** on Input, Cache read, both Cache write columns and tok/s, so Output and Cost lead.
- **Cost:** `Labels.logCost`, so a missing price reads `no price`. **tok/s:** `Labels.logSpeed`.

This is the one place projects appear. No project breakdown anywhere else.

States: existing `log.empty` and `ProblemNote`.

### 13.2 Calendar

`HeatmapPage` as it is, retitled with `page.calendar`. Colours, quantile shades, hover readout and both range pickers stay. A month's name goes above the week it starts in, or within three columns of the right edge at most: Charts cuts a label short at the plot's edge.

### 13.3 Settings

`SettingsPage` as it was, with a `Rate` section, `RateSettings`, in a `Form` with `.grouped` style:

| Row | Control | Values |
|---|---|---|
| `settings.rateShows` | Segmented `Picker` | Output, All tokens, Cost |
| `settings.unit` | Segmented `Picker` | Per minute, Per second. Disabled in Cost mode, with note `settings.costPerMinute` |
| `settings.style` | Segmented `Picker` | Rate, Icon only, 5-hour % |

The figure's `Rate settings…` item opens this page.

## 14. First launch

`SetupSheet` is one sheet over the main window, width 460, padding 20, gap 14.

**Step 1: `.sources`.** `SourceChooser`, with its strings and its plain Continue (C32). Below the checkboxes, only if there is anything to list, heading `setup.notWatched` in `cardTitle`, then rows in `small`, `.secondary`: each `Source` not detected, with `settings.notFound`; each `SourceRoots.unsupportedDetected` name, with `settings.noRecords`. These come from existence checks only. **No file counts** (C31). With nothing detected: existing `setup.none`.

**Step 2: `.consent`.** `ConsentSheet` unchanged: same facts, `Not now` and `Allow`, neither the default (C33).

**Step 3: `.ready`.** It is shown once, after first launch, and never from Settings.

- **The trigger:** `showsReady: Bool` on `AppModel`, not persisted. `answerSources` sets it when it is given a set and creates an engine. It is not set on the nothing-found path, because there is no engine and nothing is reading. `Done` clears it.
- **In `setupStep`:** after the existing checks, `return isAskingConsent ? .consent : (showsReady ? .ready : nil)`. So it follows consent if consent is still to be asked, and comes straight after the chooser if consent was already answered. A later `requestConsent` from Settings cannot reach it, since `showsReady` is by then false.

```
Reading your logs
Reading recent logs: 212 of 704 files
▓▓▓▓▓░░░░░░░░░░░░
Figures fill in as Tacho reads. Totals rise until it finishes.
─────────────────
Where to find Tacho
◠ It lives in the menu bar. Click the gauge for your summary.
Comparisons with your usual need 7 days of use. Until then cards say so.
                                                   [Done]
```

- Title `ready.title`, `.title3.weight(.semibold)`.
- `Labels.progress` in `small`, then one `.linear` `ProgressView`, as in section 6.3 (C43). If this step opens before `dashboard` exists, `progress.starting` and the indeterminate bar. At `.live`, `ready.finished` and a full bar.
- `ready.rise` in `small`, `.secondary`.
- A `Divider`, `ready.where` in `cardTitle`, the `gauge.with.needle` symbol beside `ready.menuBar` in `small`, then `ready.usual` in `small`, `.secondary`. If `model.menuBarBlocked`, replace the symbol line with `ready.blocked` (C34).
- `common.done`, the one button here with `.keyboardShortcut(.defaultAction)`: it answers nothing. It closes the sheet; reading goes on.

`SetupFlowTests` covers these steps, including `theConsentStillFollowsWhenNothingWasFound` and no `.ready` after a Settings toggle. Its tests that expect `setupStep == nil` after the answers use `Sandbox(noEngine: true)`, so `showsReady` stays false; the tests of `.ready` need an engine.

## 15. Menu bar item blocked by macOS

T17b's behaviour: `.regular` activation, Dock icon, window opens, `MenuBarBlockedNote` above the split view at full width, `.background(.bar)`.

It keeps its title, body and Quit (C35), with `blocked.openSettings`, a plain `Button` before Quit, opening System Settings with `NSWorkspace.shared.openApplication(at:configuration:)` on `/System/Applications/System Settings.app`. A deep link to the Menu Bar pane is not verified on any macOS version; do not rely on one.

With no panel, the window is the whole app. **While blocked, Summary gains a rate strip** above its two columns: RateFigure, LiveBadge and the 60-minute chart at full width and height 44, with its label row, in a card. Every limit is on the Limits page, and everything else the panel shows is already on Summary. No Dock badge (C36).

Both languages must fit at the 820 pt minimum: the body wraps; the buttons do not.

## 16. Data contract for the main window

Section 6.4 lists what the panel reads. These are the rest, as built.

| Need | Used by | Built as |
|---|---|---|
| Usual curves with p25, median, p75 by quarter hour, for cost, output and total tokens | Cost today card, scales, Summary | `PanelInsights.cost`, `.output`, `.tokens`: `UsualCurve.band`, from the internal `Engine.dayCurves`. Recomputed as section 8.1 says. No view reads `.tokens` |
| Usual range of daily totals | Cost, Tokens | `UsualBands.daily` in `DetailFigures.usualCost`, `usualTokens` and `usualOutput` |
| Usual range by hour of day | Cost and Tokens, Day | `UsualBands.hourly`, 24 entries |
| Series by range: hour, day, month buckets of `TokenCounts` and USD by category | Cost, Tokens, Summary | `Engine.detail(range:now:calendar:)`: `DetailFigures.columns`, each a `DetailColumn` with `tokens`, `cost`, `costByCategory` and `hasUse` |
| Previous period totals | D4 to D11, W rules, K1 | `DetailFigures.previous`, `previousColumns` and `previousIsFull`, in the same call, cut at the time of day it is now. Summary's W rules read `InsightInputs.outputLastSevenDays` and `outputSevenDaysBefore` |
| USD by category | Cost, Cache, `costSeries` | `PriceTable.usdByCategory(of:)`: `CategoryCost` |
| Cache saving | Cache card and page | `PriceTable.cacheSaving(of:)` |
| Daily hit rate, by CLI | Cache | Chart: `DetailColumn.tokens.cacheHitRate`. By CLI: `bySource`, for the whole range. Card: `CacheFigures.dailyHitRates` |
| Quota history for a limit | Limits, Summary | `Engine.limitHistory(of:now:)`, from `EventStore.limitReadings(of:upTo:windows:)`, bounded at 24 windows |
| Recorded windows and peaks | Limits | `LimitHistory.windows`, each with `resetsAt` and `peak`, grouped by `resetsAt` within 60 s |
| Pace | LH1, LH2, forecast line | `Projection.recentPercentPerHour`, `windowPercentPerHour` and `pacePercentPerHour` |
| Speed by model and bucket, with per-model daily medians | Speed, `speed` card | `Engine.speed(range:model:now:calendar:)`: `SpeedFigures`. Daily medians: `History.speedMedians`, into `InsightInputs.Speed.dailyMedians` |
| Log summary for a filter | Activity log strip | `Engine.logSummary(filter:)`: `LogSummary`, with `requests`, `cost`, `output`, `cacheHitRate` and `subagentShare` |
| `isSubagent` share | T2, log strip | `EventFilter.isSubagent`; `EventStore.requestCounts(in:filter:)`, into `PeriodTotals.subagentRequests` and `LogSummary.subagentShare` |
| Thinking share | T1 | `TokenCounts.reasoning` |
| Hour-of-week grid | Calendar, `when` card | Calendar: `Engine.heatmaps`, full history. The card: `PanelInsights.hourOfWeek`, the 30 days before today. Both take every source |
| `bySource`, `byModel`, `clientsBySource` | Cost, Tokens | `DetailFigures`, enabled sources only. `Overview` itself stays unfiltered |

**Enabled sources:** Summary, Cost, Tokens, Cache and Speed count enabled sources only, so that a page agrees with the panel. This replaces the Task 15b ruling that Overview keeps history, for these pages (accepted by the PM, 2026-11-05). The exceptions are Calendar and the `when` card that leads to it, which take every source. Nothing here runs on the 1 s tick except what section 6.4 says; the ledger's CPU budget and the 100 ms panel open still apply.

`OverviewPage`, `SourcesSection`, `TodaySection`, `QuotaSection` and `RateChart` are gone. `Engine.overview` stays: `ActivityLogPage.loadOptions` and `tacho-cli` call it.

## 17. Strings for the window

Reused as they are: `quota.footnote`, `quota.mayBeStale`, `quota.windowAverage`, `overview.empty`, `overview.byCLI`, `overview.byModel`, `overview.noModel`, `cost.noPrice`, `cost.partial`, `category.*`, `chart.*`, `footer.*`, `sources.hourlyCost`, `sources.hourlyNoPrice`, `prices.cacheWrite5m`, `prices.cacheWrite1h`, `setup.*`, `consent.*`, `blocked.*`, and `settings.*` not listed here.

| Key | English | 简体中文 |
|---|---|---|
| `page.summary` | Summary | 摘要 |
| `page.limits` | Limits | 额度 |
| `page.cost` | Cost | 费用 |
| `page.tokens` | Tokens | Token |
| `page.cache` | Cache | 缓存 |
| `page.speed` | Speed | 速度 |
| `page.calendar` | Calendar | 日历 |
| `sidebar.records` | Records | 记录 |
| `summary.highlights` | Highlights | 重点 |
| `summary.bandLegend` | shaded: your usual range by time of day | 阴影：各时段的常见范围 |
| `summary.outputWeek` | Output this week | 本周输出 |
| `summary.lastWeek` | grey: last week | 灰色：上周 |
| `summary.thisWeek` | this week | 本周 |
| `summary.pinned` | Pinned | 已固定 |
| `summary.edit` | Edit | 编辑 |
| `pins.title` | Pinned cards | 已固定的卡片 |
| `pins.note` | The panel shows the first four. | 面板显示前四张。 |
| `common.done` | Done | 完成 |
| `list.more` | and %ld more | 还有 %ld 个 |
| `list.showAll` | Show all %ld | 显示全部 %ld 个 |
| `list.showFewer` | Show fewer | 收起 |
| `chart.grouping` | Stack by | 堆叠方式 |
| `chart.byType` | Type | 类别 |
| `chart.byModel` | Model | 模型 |
| `chart.byCLI` | CLI | CLI |
| `chart.other` | Other | 其他 |
| `time.tomorrow` | %@ tomorrow | 明天 %@ |
| `range.day` | Day | 日 |
| `range.weekShort` | Week | 周 |
| `range.monthShort` | Month | 月 |
| `range.year` | Year | 年 |
| `detail.bandLegend` | shaded: your usual | 阴影：常见范围 |
| `detail.about` | About this figure | 关于这个数字 |
| `detail.byType` | By token type | 按 token 类别 |
| `stat.today` | Today | 今天 |
| `stat.now` | Now | 现在 |
| `stat.usual` | Usual range | 常见范围 |
| `stat.usualRange` | %1$@ to %2$@ | %1$@ 到 %2$@ |
| `stat.usualDay` | %1$@ to %2$@ a day | 每天 %1$@ 到 %2$@ |
| `stat.last7` | Last 7 days | 最近 7 天 |
| `stat.last30` | Last 30 days | 最近 30 天 |
| `stat.last12` | Last 12 months | 最近 12 个月 |
| `stat.medianDay` | Median day | 每天中位数 |
| `stat.medianMonth` | Median month | 每月中位数 |
| `stat.output` | Output | 输出 |
| `stat.allTokens` | All tokens | 全部 token |
| `stat.hitRate` | Hit rate | 命中率 |
| `stat.kept` | Kept off the bill | 账单减少 |
| `stat.keptValue` | about %@ | 约 %@ |
| `stat.writes` | Paid to write the cache | 写入缓存的费用 |
| `stat.used` | Used so far | 目前已用 |
| `stat.empties` | Empties at this pace | 照这个速度用完 |
| `stat.emptiesValue` | about %@ | 约 %@ |
| `stat.resets` | Resets | 重置 |
| `stat.median` | Median | 中位数 |
| `stat.samples` | Requests timed | 计时的请求数 |
| `cache.legend` | hit rate: cache reads as a share of all prompt tokens | 命中率：缓存读占全部提示 token 的比例 |
| `cache.twoWays` | The same range, counted two ways | 同一段时间，两种算法 |
| `cache.byTokens` | By tokens | 按 token |
| `cache.byCost` | By cost | 按费用 |
| `cache.share` | %1$@: %2$ld%% of tokens, %3$ld%% of cost | %1$@：占 token 的 %2$ld%%，占费用的 %3$ld%% |
| `limits.opens` | %@ window opens | %@ 窗口开始 |
| `limits.now` | now %@ | 现在 %@ |
| `limits.short` | %@ with nothing left | %@ 无额度可用 |
| `limits.reset` | %@ reset | %@ 重置 |
| `limits.recent` | Recent windows: how far each one got | 最近的窗口：每个用到了多少 |
| `limits.recentOf` | %1$ld of %2$ld recorded windows reached 100%% | %2$ld 个有记录的窗口中有 %1$ld 个用到 100%% |
| `limits.oldest` | %@ ago | %@前 |
| `limits.noQuota` | No quota here | 这些 CLI 没有额度数据 |
| `limits.every` | Every limit | 全部额度 |
| `limits.openSettings` | Open Settings | 打开设置 |
| `how.title` | How this forecast is made | 这个预测是怎么算的 |
| `how.last` | Last reading | 最近一次读数 |
| `how.lastValue` | %1$@, %2$@ ago | %1$@，%2$@前 |
| `how.from` | From | 来源 |
| `how.since` | Since then | 此后 |
| `how.sinceValue` | +%@ from local use | 本机用量 +%@ |
| `how.noChange` | no change | 没有变化 |
| `how.resetSince` | the window has reset since | 此后窗口已重置 |
| `how.pace` | Pace taken from | 速度取自 |
| `how.pace.recent` | the last 30 minutes | 最近 30 分钟 |
| `how.pace.window` | the window so far | 这个窗口到目前为止 |
| `how.method` | Method | 算法 |
| `how.method.calibrated` | local use, scaled to the last reading | 本机用量，按最近读数校准 |
| `how.method.window` | window average | 窗口平均 |
| `how.plan` | Plan | 套餐 |
| `quota.origin.anthropicAPI` | Anthropic usage request | Anthropic 用量请求 |
| `quota.origin.claudeCache` | Claude Code's cached usage | Claude Code 缓存的用量 |
| `quota.origin.ompCache` | oh-my-pi's cached usage | oh-my-pi 缓存的用量 |
| `quota.origin.codexLog` | Codex log | Codex 日志 |
| `quota.origin.grokLog` | Grok log | Grok 日志 |
| `speed.few` | Too few timed requests to chart. | 计时的请求太少，画不出图。 |
| `speed.models` | All models | 全部模型 |
| `log.showing` | Showing | 显示 |
| `log.request` | 1 request | 1 个请求 |
| `log.requests` | %@ requests | %@ 个请求 |
| `log.dayTime` | %1$@, %2$@ | %1$@ %2$@ |
| `log.cost` | Cost | 费用 |
| `log.output` | Output | 输出 |
| `log.cacheHit` | Cache hit | 缓存命中率 |
| `log.subagents` | By sub-agents | 来自子代理 |
| `log.subagentsValue` | %ld%% of requests | 占请求的 %ld%% |
| `log.clear` | Clear filters | 清除筛选 |
| `log.write5m` | Write 5 m | 写 5 分钟 |
| `log.write1h` | 1 h | 1 小时 |
| `log.tagAgent` | sub-agent | 子代理 |
| `log.tagFast` | fast | 快速 |
| `settings.rate` | Rate | 速率 |
| `settings.rateShows` | Rate shows | 速率显示 |
| `settings.costPerMinute` | Cost is always per minute. | 费用始终按分钟显示。 |
| `setup.notWatched` | Can't be watched | 无法观察 |
| `ready.title` | Reading your logs | 正在读取日志 |
| `ready.finished` | All logs read. | 日志已全部读完。 |
| `ready.rise` | Figures fill in as Tacho reads. Totals rise until it finishes. | 数字会随读取逐步出现，读完之前总数还会上升。 |
| `ready.where` | Where to find Tacho | 在哪里找到 Tacho |
| `ready.menuBar` | It lives in the menu bar. Click the gauge for your summary. | 它在菜单栏里。点击仪表图标查看摘要。 |
| `ready.blocked` | macOS is hiding its menu bar item, so use Tacho from this window. | macOS 隐藏了它的菜单栏图标，请在这个窗口里使用 Tacho。 |
| `ready.usual` | Comparisons with your usual need 7 days of use. Until then cards say so. | 用满 7 天后才能和平时对比，在那之前卡片会写明。 |
| `blocked.openSettings` | Open System Settings | 打开系统设置 |
| `tokens.thinking` | of which thinking | 其中思考 |
| `about.cost` | API-equivalent: what these tokens would cost at list prices, by model. On a subscription you do not pay this. Models with no price are left out and named here. | 等价 API 费用：这些 token 按各模型官网价格要花多少钱。订阅用户实际不付这笔钱。没有价格的模型不计入，并在这里写明。 |
| `about.tokens` | All four token types, as your CLIs recorded them. Cache reads are counted in full, though they cost far less. | 全部四类 token，以各 CLI 的记录为准。缓存读虽然便宜得多，也全部计入。 |
| `about.cache` | Kept off the bill: what these cache reads would have cost at each model's input price, minus what they did cost. It assumes the same prompts; it is not a promise of what you would have paid. Models with no price are left out. | 账单减少：这些缓存读按各模型输入价格要花的钱，减去实际花费。这里假设提示不变，不代表你真的会付这笔钱。没有价格的模型不计入。 |
| `about.speed` | Median output tokens a second, from requests long enough to mean something. A ≈ means the start time is approximate. Codex, OpenCode and Grok are not timed. | 每秒输出 token 数的中位数，只算足够长的请求。≈ 表示开始时间是估计的。Codex、OpenCode 和 Grok 不计时。 |

Plurals: the English `{n}` sentences need the singular for 1 (`1 day`, `1 request`). Chinese has none.

## 18. Not verified

As of 2026-11-05. These are things nobody has seen work, not requirements. The final smoke is the run on the real app that the ledger holds open; most of it needs a person.

### Verified since this section was first written

| Item | How |
|---|---|
| Cost of the usual-range walk, off the tick | Measured by a harness on real logs, not in the running app: `Engine.insights` took 138 ms on the past-day walk, 6 to 13 ms a minute later and 0.03 ms held (TE), then 16 to 19 ms after TF. TF3's samples of the running app found no walk in the minutes sampled. Its cost in the app with a panel open is still owed: item 3 below |
| The cap during a backfill | 632 measured 722 through a real window (TUP), so 630 shipped |
| Panel height | Measured by `PopoverWindowHeightTests` in a hosted window, no longer estimated from the canvas: busy 686, with progress 720, from the Before column of TLC's report, which is today's code. Cells and the longest share are measured in both languages. A real `MenuBarExtra` window has not been measured since direction B, and neither has the whole panel in Chinese |

### Owed by the final smoke

1. Closing a real `MenuBarExtra` stops the reads. `window.isVisible` by KVO is proven on a hosted plain `NSWindow` only.
2. A panel opened and then closed does not rebuild `PanelState` each tick: CPU after opening then closing. TF3 found no `PopoverView` frames among 6,616 busy samples, but that instance's panel may never have been opened, so this stays owed.
3. What `Engine.insights` costs on real logs with the panel open. It runs on the Engine actor, so a slow read would delay the 1 s tick.
4. A `Menu` inside a `.window` `MenuBarExtra`: it compiles, but opening it without closing the panel has not been run. If the panel closes, tell the PM before changing the design. Also whether the open menu holds still while `rate.readings` changes each tick, and its check mark.
5. The panel on first open: it may draw only its footer for one update. This needs a person watching a click.
6. The headline's accessibility value under VoiceOver: the modifier has no test and has not been heard.
7. The main window closed and reopened on Summary with figures showing. Offscreen, a window opening on Summary stayed blank (TW2). Measured: it needs `PageBody`'s `ScrollView` in the first commit, and it is not the reads, the toolbar or the sheet. The test host never reports a visible window, so "an artefact of that host" is likely and unproven.
8. The toolbar's rate title in the real app, a `Menu` label that changes each second. No test reads it. TF3's frames show `RateToolbarMenu` being updated.
9. `navigationTitle` and `navigationSubtitle` through `sceneBridgingOptions = .all` in `AppDelegate`'s window. `aLimitPickedIsDrawnAtOnce` reads `window.subtitle`, but in a plain test window with no hosting controller.
10. `.monospacedDigit()` in the menu bar label: never tried (section 5).
11. Owed by the user since T17b: Cmd-C and Cmd-V in the Activity search field; Tacho > Quit and the Dock's Quit on a blocked id, where a refused menu Quit would be Important; the blocked note on screen, not yet seen by pixels; the sheets clicked through, including a double-click on Continue.

### Spec 5.11: what the budgets stand on

**Nothing in this table was measured at the current head.** The CPU and memory figures are of `8a33581`, and the commits since have not been measured.

| Budget | Measured | Standing |
|---|---|---|
| CPU idle about 0% | **Not measured since direction B.** The one reading is 0.41%, on TP's build, down from 2.21%, mostly the 60 s rescan; accepted by ruling (TP) | Not verified. The line through TF3's minutes gives 0.51% closed and 1.19% open at no events: an extrapolation, not a reading |
| CPU under 2% while CLIs write | The budget means this user's ordinary load, about 9.5 events a minute, window open or closed, with peaks above that accepted (rulings TP, TF3). Measured: open on Summary 1.81% at 6.1 events a minute; closed 1.45% at 8.4 | **Not shown met.** Nothing has been measured at 9.5. TF3 projects 2.14 ± 0.16% with the window open, over budget, reaching 2.00% at about 8.1 events a minute, and closed reaching it at about 14. These are projections from a straight line through 27 noisy minutes, not measurements. An occluded window and Limits' CPU are unmeasured |
| Resident memory under 150 MB | Open 85 to 125 MB, closed 61 to 79 MB, over the measured stretches. 141 MB seen once, 8 s after launching with the window open | Inside the budget at that build, the launch peak 9 MB under it. Backfill not measured on it; a throwaway merge reached 183 MB, over the budget |
| First index under 3 minutes, 7 days under 15 s | `tacho-cli scan`: 13.28 s and 3.91 s (Task 15c) | Inside the budget, on an early build, by the CLI and not the app |
| Panel opens in under 100 ms | **Never measured, click to drawn.** Only parts: `dashboard` 17 to 42 ms, `insights` as above | Not verified |

### Never run

- **GitHub:** CI and `release.yml` have never run. The first run's watch list: `MemoryDefaults` on Swift 6.1, `HeadlineTests`, `aCellIsAsTallAsItsLine`. This code has only been compiled by Swift 6.4.2; the floor is 6.1.
- **macOS 14 and 15:** nothing has run on either. macOS 14 has no test path, since GitHub retired its runners. RateFigure's label was rendered on macOS 26 with a macOS 14 target. `ReadOnlySQLite` relies on the system SQLite having `USE_URI`, seen only on macOS 26.6.2. The log's widths and date patterns were measured on macOS 26 only.

### Decided, ahead of the code

These sentences state what was decided. They are not yet true of `build/v0.1`, so a review should read each as a requirement still being built:

- A time saying which day, and the gap as printed: section 8.3. TGAP.
- Section 4.5 and the panel heights describe today's limit cells, which TLC replaces.

The requirements the TSPEC triage sends back to the lanes stand as written until those fixes land: see the ledger's TSPEC list.

### Not the user's decision yet

- My calls, not the user's: 90 calendar days as the limit on the walk back (section 8.1), 5 samples for a speed day, $0.50 and 1,000 tokens as `floor`, the 5% lines between "up" and "about the same", and 5% for "just above".
- The Chinese strings have not had a native reader's review. TZH changed 65 values and wrote `zh-review.md`, but only the user can close this.

### Unexplained

- `itOpensAtItsFullSize` failed 1 of 21 at `build/v0.1`, with no cause shown, and has not recurred.
- A redraw test failed 1 of 10 at `6538adf`. The likely cause is a fixed wait counting a late first layout. It was never reproduced. With the wait gone, 10 of 10 at `751858f`.
- Something outside Tacho touches `opencode.db-shm` every 10 to 20 s, with OpenCode not running. Tacho's reads were shown not to move it; what does is unknown.
- A throwaway render helper died in 1 of 6 runs with no crash report, then 0 of 60.
