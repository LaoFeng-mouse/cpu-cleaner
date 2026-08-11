# 鼠鼠 Cleaner 视觉 QA

## Comparison target

- Source visual truth: `docs/design-references/shushu-fantasy-comic-target.png`
- Source pixels: 1487 x 1058; density metadata is not used as a layout contract.
- Implementation screenshots: `artifacts/gui-states/{100,125,150}/{idle,scanning,results,review,executing,completed,error}.png`
- WPF viewport: 1040 x 760 device-independent pixels.
- Captured pixels: 1040 x 760 at 100%, 1300 x 950 at 125%, and 1560 x 1140 at 150%.
- Normalization: the source was aspect-fit without cropping into a 1040 x 760 cream canvas. The 100% implementation was compared at its native 1040 x 760 size; higher-density captures were downsampled only for contact-sheet inspection.
- States: all seven application states, with focused comparisons for `results` and partial-failure `completed`.

## Evidence

- Full-view comparisons: `artifacts/gui-states/100/comparison-100.png`, `artifacts/gui-states/125/comparison-125.png`, `artifacts/gui-states/150/comparison-150.png`
- Focused comparison, scan result: `artifacts/gui-states/100/focused-results.png`
- Focused comparison, partial completion: `artifacts/gui-states/100/focused-completed.png`
- The selected source image copy has the same SHA-256 as the original generated image: `b8302ad1f7610dca319c049db99c6daf07c27e7b8f3522f3bbb93730c10da654`.

## Required fidelity surfaces

- Fonts and typography: Microsoft YaHei UI preserves clear Chinese hierarchy; 26 px product title, 24 px state title, bold outcome summaries, and wrapped secondary copy remain legible at all three capture densities. The source's oversized single-result headline was adapted into reusable state headings because the product must support seven truthful states rather than one static result screen.
- Spacing and layout rhythm: the four-stage comic remains the dominant top rail, the state card has consistent cream-paper margins, and primary actions stay reachable without covering lists. No overlap, clipping, broken wrapping, or hidden persistent action was visible at 100%, 125%, or 150%.
- Colors and visual tokens: cream, paper white, near-black ink, fantasy yellow, muted future stages, and restrained danger red match the source direction. No blue-purple gradient or unrelated visual system appears.
- Image quality and asset fidelity: all four visible stages use real raster mouse images with consistent crops and no stretch artifacts. No placeholder, emoji, CSS illustration, inline SVG, or text-glyph substitute is used.
- Copy and content: app-owned Chinese copy stands alone and keeps the product rule explicit: scanning may be broad, execution must be narrow and revalidated. English text visible in deterministic rows is fixture data used only by the renderer, not hard-coded production interface copy.
- Interaction and accessibility: automated GUI coverage verifies the seven-state journey, language repaint, default buttons, continuous keyboard navigation, screen-reader names, scroll resilience, truthful errors, restore outcomes, and non-mutating scan behavior. Off-screen rendering does not launch clean, restore, service, task, process, or Run-key mutation paths.

## Comparison history

### Pass 1 - blocked

- P2, partial-failure completion summary: the `completed` state displayed `failed 1` with the same ink color as a pure success summary, so a meaningful failure could be missed at a glance.
- Fix: added `Set-GuiCompletedSummary`, which uses the danger token whenever failed items are present; the same rule now applies to partial restore results. Added a regression test before implementation.

### Pass 2 - passed

- Post-fix evidence: `artifacts/gui-states/100/focused-completed.png` and all three regenerated contact sheets show the partial-failure summary in danger red while keeping the yellow recovery actions visible.
- Automated evidence: 141 GUI tests passed after the fix.
- No actionable P0, P1, or P2 visual finding remains.

### Pass 3 - reopened from user review

- P1, comic expressions: all four square mouse assets used `UniformToFill` inside wide slots, visibly cropping the top and bottom of each expression.
- P1, results hierarchy: the selected target's oversized result headline, yellow count, dual actions, and evidence footer had been reduced to a generic small state card.
- P2, journey emphasis: the results state still highlighted stage 2 and faded stage 3, while the selected target fully reveals the decision/cleanup panel and only subdues the final panel.
- P2, duplicate heading: the generic `扫描结论` header repeated the new `扫描完成，发现问题` result status.

### Pass 4 - passed

- Fixes: all stage images now use `Uniform`; the comic rail is taller; results use a 38/50 px hero headline, yellow dynamic total, dual 56 px actions, and collapsed evidence footer; results highlight stage 3; the duplicate generic state header is hidden only for results.
- Interaction: `这次先不处理` returns safely to idle and clears the in-memory reviewed authorization snapshot without deleting the read-only scan result.
- Post-fix evidence: `artifacts/audit-current/04-reference-vs-final-results.png` and `artifacts/gui-states/{100,125,150}/results.png`.
- Automated evidence: 146 GUI tests passed after the revision.
- No actionable P0, P1, or P2 visual finding remains in the revised results state.

### Pass 5 - runtime scan integrity passed

- A real read-only GUI scan reproduced `Get-CimInstance` access denial that previously produced a false-clean `0 / 0` result with exit code 0.
- Fix: system information now falls back to explicit compatibility values; service collection falls back to `Get-Service`; scheduled-task collection falls back to read-only `schtasks /Query /FO CSV /V`. If both the primary and fallback collector fail, scanning stops instead of reporting an empty category.
- Runtime evidence on the current Lenovo machine: `0` executable actions, `8` observations, and `0` suspicious processes. The observations comprise six Lenovo services and two Lenovo scheduled tasks; no clean or restore path was invoked.
- Empty-state copy now says no matching items were found instead of displaying “发现问题” or “抓到 0 个”. Non-empty results retain the selected target hierarchy.
- Post-fix visual evidence: `artifacts/audit-current/05-reference-vs-runtime-fix.png` and `artifacts/gui-states/{100,125,150}/results.png`; no clipping or overlap is visible at any tested density.
- Automated evidence: 147 GUI tests and 221 core Pester tests pass after the runtime repair.

## Follow-up polish

- P3: production screenshot fixtures could use fully localized sample item names in a future pass; current mixed-language sample rows are useful for deterministic width testing and do not affect the shipped runtime copy.

## Final result

final result: passed
