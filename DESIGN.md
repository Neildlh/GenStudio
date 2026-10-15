# GenStudio — Design System

> The token contract for this app. Edit this with `design-system`; keep `DesignTokens.swift` in lockstep. Baseline: macOS 14+, dark-mode-only by product decision (forced `.preferredColorScheme(.dark)`).

## Personality
A focused, professional dark studio for AI image/video generation — glossy near-black surfaces (echoing the app icon's sphere) with one warm ember-orange accent used sharply for primary action and brand moments. Echoes the feel of pro creative tools with dark node canvases: DaVinci Resolve, Logic Pro, Blender's shader editor. Calm and dense where it needs to be (the node graph, inspectors), confident and warm at the moments that matter (Run, brand marks, the one accent).

## Typography
- Font design: **SF Pro** (system default) throughout. No custom/web fonts.
- Ramp in use (keep to ~5 per screen): `.title3` (panel headers) / `.headline` (node titles, section headers) / `.body` (primary content) / `.callout` (secondary body/description) / `.caption` (badges, metadata, chip labels).
- Hierarchy rule: weight + `.secondary`/`.tertiary` foreground, **≤ 3 styles per screen**. Never introduce a new `.system(size:)` literal where a semantic style or an existing token covers it.
- **Numerals are tabular**: any figure a user compares at a glance (model size, pixel dimensions, seed number) uses `.monospacedDigit()` so digits don't jitter column-to-column.
- **Exception — the node canvas**: node cards live on a fixed-zoom canvas (`NodeLayout` geometry is literal points, not Dynamic-Type-aware), so they use the fixed `CanvasType.*` scale (`micro 9 / label 11 / body 13 / prominent 14`) instead of semantic styles. This is a deliberate, scoped exception — everywhere else uses the semantic ramp above.

## Spacing
- Scale (pt): `Space.xs 4, Space.sm 8, Space.md 12, Space.lg 16, Space.xl 24, Space.xxl 32, Space.section 48`.
- This mirrors the rhythm the node system already uses (`bodyInset 12`, `promptInset 16`) — the rest of the app now follows the same steps instead of ad hoc values (5, 7, 9, 10, 14…).
- Section breaks (between major inspector groups, between sidebar sections) get `xl`/`xxl`; in-card padding stays `md`/`lg`.

## Color
- **Surfaces** — one elevation scale (`Surface.*` in tokens), all near-black per the app icon, lighter = more elevated/interactive:
  - `canvas` (0.09) — the graph background behind everything.
  - `card` (0.12) — standard node card / panel body.
  - `cardImage` (0.14) — image-output card body (sits under checkerboard/media).
  - `cardProminent` (0.155) — prompt-styled cards (taller header, the "primary input" cards).
  - `control` (0.18) — text editors, input fields, hover/pressed chip backgrounds.
  - `controlElevated` (0.205) — popovers, menus, topmost floating chrome.
- **Brand accent** — `Color.brandAccent`, the warm ember-orange from the app icon. Used sharply: the Run button, active/selected states, focus rings, brand moments. Not sprinkled decoratively.
- **Data-type colors** (`DataTypeColor.*`) — the node graph's existing port/wire semantics, kept as-is and formalized as tokens: text = mint, textArray = cyan, number = blue, image = orange (deliberately shares the brand family — images are the app's primary medium), video = purple, shotSequence = pink.
- **Model-purpose colors** (`ModelPurposeColor.*`) — the model-library tagging palette, kept as one dark-only token set (previously a light+dark branching palette with a dead light branch).
- Text: `.primary` / `.secondary` / `.tertiary`. Contrast ≥ 4.5:1 for body text against its surface.
- Dark mode = elevation via the `Surface` scale, not per-screen literals. No raw `Color(white:)` outside `DesignTokens.swift`.

## Depth & corners
- Corner radius scale (`Radius.*`): `xs 6` (small chips/badges), `sm 8` (preview thumbnails, compact controls), `md 12` (standard node cards, panels — matches existing `NodeLayout.cardCornerRadius`), `lg 18` (prominent/prompt cards — matches existing `NodeLayout.prominentCardCornerRadius`).
- Depth from layered `Surface` steps, not heavy shadows. Where a shadow is used it stays soft (opacity 0.05–0.15, large blur, near-zero offset) — never a hard black drop shadow.
- System materials (`.regularMaterial`, `.ultraThinMaterial`, `.quaternary`) stay on chrome (toolbars, popovers, context menus), not stacked on top of an already-opaque card.

## Motion & haptics
- Default spring: `Motion.standard` (`response 0.32, damping 0.85`) for state changes, selection, panel transitions. Nothing idle/decorative on the canvas — motion only where it conveys meaning (node running, take switching, panel open/close).
- No haptics — this is a macOS pointer/keyboard app; the mobile-app haptic guidance in the broader UI/UX skill does not apply here.

## Iconography
- SF Symbols throughout, weight matched to adjacent text, `.hierarchical` rendering by default. No emoji as structural/navigational icons.

## States
- Empty states use `ContentUnavailableView` with a symbol + title + action where one exists (canvas empty state, sidebar empty lists).
- Loading uses the existing `StudioSpinner`/`StudioLinearProgress` (kept — they exist specifically to dodge an AppKit `NSProgressIndicator` sizing bug, a deliberate, justified deviation from the "just use the system control" default).
- Errors show human copy with a retry action, not a raw `error.localizedDescription` dump.

## Platform notes (macOS, not iOS)
- No touch-target minimums (44×44pt) — this is a pointer/trackpad app; standard macOS control sizing (≈20–28pt for toolbar/inline controls) applies instead.
- No safe-area/notch concerns; `NavigationSplitView` + toolbar handle the chrome.
- Forced dark mode is intentional and permanent for this app — do not reintroduce light-mode branching (`@Environment(\.colorScheme)` reads that can never resolve to light in production were removed as dead code in this pass).

## Dependencies (if any)
- None. No new SPM packages added for this pass.
