## 0.1.0

The first release.

### Added

- A menu bar rate across every source you have turned on, over the last 5 minutes and shown per minute (or per second), in three modes switched from the rate itself or in Settings: Output by default, All tokens, or Cost, which is always dollars per minute.
- A panel with the rate and a 60-minute chart, today against your usual range, your limits and one sentence on how they stand, and the first four of your pinned cards, each opening the page behind it.
- A usual range from your newest 14 days with use, shown after 7 days of use.
- Seven sources read from their local files: Claude Code, Codex, oh-my-pi, pi, GitHub Copilot CLI, OpenCode and Grok Build.
- A first-launch step that lists the CLIs found on your Mac, all ticked, and asks which to observe. None of their files are read until you answer. After that a CLI you untick, or one not found, stays off until you turn it on in Settings, and neither its logs nor its quota files are read.
- Tokens split into four categories: uncached input, output (with thinking), cache read and cache write, with Claude's 5-minute and 1-hour writes priced separately.
- Output speed per model, as a reference figure.
- API-equivalent cost from a dated price table with a source for every row, which you can edit in Settings.
- Quota forecasts for Anthropic, ChatGPT/Codex and xAI, from each tool's local records: the 5-hour and weekly windows each provider reports, and Anthropic's weekly limits per model. A figure a full window past its reset shows no forecast and raises no alert: its row says there is no recent quota data. A time on another day says which: tomorrow, a weekday, or from a week away the date.
- An opt-in Anthropic quota request every 5 minutes, off until you allow it.
- A main window with Summary, Limits, and Cost, Tokens, Cache and Speed pages over a Day, Week, Month or Year range, where Week and Month are the last 7 and 30 days, counting today. Those pages and Summary count only the sources you have turned on, apart from the When you work card.
- A switch on Cost and Tokens that stacks the chart by token type, model or CLI, with the top 5 of the period and Other, and a By model list that opens to every model.
- Highlights on those pages and Limits: short sentences on what stands out, which leave out cost compared with the period before, and shares of cost, when 2% or more of a period's tokens have no price.
- An activity log of every request (of every model in a turn, for Grok Build), with filters by CLI, project and model, search, and a strip summing up what matches, and a Calendar by day and by hour of the week. Project is a filter here, not a breakdown.
- Settings for which sources to read and count toward forecasts, their paths, prices, the rate and the menu bar, launch at login, the language and rebuilding the index.
- English and Simplified Chinese.

### Requirements and limits

- macOS 14 or later, though Tacho has only been run on macOS 26 so far. Building from source needs Swift 6.1 or later.
- macOS must allow Tacho's menu bar item. If it blocks the item, Tacho opens its main window, says so and keeps working there.
- Tacho knows only 5-hour and weekly quota windows, so a plan measured over any other period gets no new figures.
- Tacho is unsigned: it has an ad-hoc signature, no Developer ID and no notarization. macOS refuses a downloaded copy until its quarantine flag is cleared with `xattr -dr com.apple.quarantine /Applications/Tacho.app`.
- Tacho does not sync between machines.

### Prices

- Prices were read from the providers' official pages on 2026-11-03 and 2026-11-05. Each row of `prices.json` carries its URL and date.
- `gpt-5.6-sol` carries a promotional price dated 2026-11-03. OpenAI says it is available at least through November 21, 2026, so re-read it after 2026-11-21.
- `gpt-6-astra-law` also carries a promotional price, available at least through December 31, 2026, per the page read on 2026-11-05.
- `codex-auto-review` has no official price, so it shows "no price". So do models whose published price has a gap, such as `gpt-5.5-pro` and `gpt-5.6-cyber`. `grok-4.7-build` and `grok-4.7-build-fast` have no official price either: the first is priced as Grok 4.7 by the project's decision, and the second at twice that, as the Grok CLI shows.
