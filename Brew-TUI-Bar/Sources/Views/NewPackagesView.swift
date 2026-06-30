import SwiftUI

/// Glass sheet listing formulae/casks recently added to Homebrew's core taps,
/// plus a search field that queries the *entire* Homebrew catalog (core + any
/// third-party taps). Discoverability surface for "what's new" — clicking a row
/// copies the `brew install <name>` command to the pasteboard so the user can
/// paste it straight into their shell (Brew-TUI-Bar deliberately stays out of
/// the install path; that's Brew-TUI's job).
///
/// Two modes driven by the search field:
///  - **Novelties** (query empty or 1 char): the recently-added feed, optionally
///    filtered locally by that single character.
///  - **Global search** (query ≥ `globalSearchThreshold`): `searchResults*`,
///    produced by `AppState.searchCatalog` via `brew search`/`brew info`.
struct NewPackagesView: View {
    let formulae: [NewPackage]
    let casks: [NewPackage]
    let isLoading: Bool
    let error: String?
    let fetchedAt: Date?
    /// Global-catalog search results for the current query, supplied by AppState.
    let searchResultsFormulae: [NewPackage]
    let searchResultsCasks: [NewPackage]
    let isSearchingCatalog: Bool
    let searchError: String?
    /// The query `searchResults*` correspond to (for staleness checks/debug).
    let searchResultsQuery: String
    /// Called on every keystroke so AppState can debounce + run the catalog search.
    let onSearch: (String) -> Void
    let onClose: () -> Void
    let onRefresh: () -> Void

    @State private var selectedKind: NewPackage.Kind = .formula
    @State private var copiedID: String?
    @State private var allCopied = false
    @State private var panelAppeared = false
    @State private var contentPhase = 0
    @State private var searchQuery = ""

    @FocusState private var searchFocused: Bool

    @Namespace private var kindPickerNamespace

    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var highContrast: Bool { colorSchemeContrast == .increased }

    /// At/above this query length the field queries ALL of Homebrew via
    /// `brew search`; below it we stay on the (cheap, local) novelties feed —
    /// one character would match half the catalog and spawn brew per keystroke.
    private static let globalSearchThreshold = 2

    /// Normalised search term (diacritic- and case-insensitive, trimmed).
    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True once the query is long enough to search the whole catalog. Switches
    /// the content panel from the novelties feed to `searchResults*`.
    private var isGlobalSearch: Bool { trimmedQuery.count >= Self.globalSearchThreshold }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    /// Novelties for the active kind (the recently-added feed).
    private var noveltyPackages: [NewPackage] {
        switch selectedKind {
        case .formula: formulae
        case .cask:    casks
        }
    }

    /// Global-search results for the active kind.
    private var searchResults: [NewPackage] {
        switch selectedKind {
        case .formula: searchResultsFormulae
        case .cask:    searchResultsCasks
        }
    }

    /// Source list for the active mode, before any local filter. Drives the
    /// "real" empty/loading/error states.
    private var basePackages: [NewPackage] {
        isGlobalSearch ? searchResults : noveltyPackages
    }

    /// Packages actually rendered. In global mode the results are already
    /// filtered by `brew search`, so they pass through; in novelties mode a
    /// single-character query filters the feed locally by name + description.
    private var visiblePackages: [NewPackage] {
        guard !isGlobalSearch else { return basePackages }
        let query = normalized(trimmedQuery)
        guard !query.isEmpty else { return basePackages }
        return basePackages.filter { pkg in
            if normalized(pkg.name).contains(query) { return true }
            if let desc = pkg.desc, normalized(desc).contains(query) { return true }
            return false
        }
    }

    /// Predictive completions for the novelties feed: names that *begin with*
    /// the typed character, as tappable chips. Suppressed in global mode — there
    /// the result list itself is the prediction, so chips would be redundant.
    private var completions: [NewPackage] {
        guard !isGlobalSearch else { return [] }
        let query = normalized(trimmedQuery)
        guard query.count >= 1 else { return [] }
        var seen = Set<String>()
        return noveltyPackages.filter { pkg in
            let name = normalized(pkg.name)
            guard name.hasPrefix(query), name != query else { return false }
            return seen.insert(name).inserted
        }
        .prefix(5)
        .map { $0 }
    }

    /// Per-kind count for the picker badges — search-result counts while
    /// searching, novelty counts otherwise.
    private func count(for kind: NewPackage.Kind) -> Int {
        if isGlobalSearch {
            return kind == .formula ? searchResultsFormulae.count : searchResultsCasks.count
        }
        return kind == .formula ? formulae.count : casks.count
    }

    /// The kind not currently selected — used to offer a jump when the active
    /// tab has no matches but the other does.
    private var otherKind: NewPackage.Kind { selectedKind == .formula ? .cask : .formula }

    /// Global-search result count for `otherKind` (0 outside global search).
    private var otherKindResultCount: Int {
        guard isGlobalSearch else { return 0 }
        return otherKind == .formula ? searchResultsFormulae.count : searchResultsCasks.count
    }

    private var crossKindLabel: String {
        // "Formulae"/"Casks" are Homebrew terms — kept untranslated in both locales.
        let kindName = otherKind == .formula
            ? String(localized: "Formulae")
            : String(localized: "Casks")
        return String(
            format: String(localized: "%1$lld results in %2$@"),
            Int64(otherKindResultCount),
            kindName
        )
    }

    private var contentStateID: String {
        if isGlobalSearch {
            if basePackages.isEmpty && isSearchingCatalog { return "searching" }
            if searchError != nil, basePackages.isEmpty { return "searchError" }
            if basePackages.isEmpty { return "noresults-global:\(selectedKind.rawValue)" }
            return "results:\(selectedKind.rawValue)"
        }
        if let error, basePackages.isEmpty, !isLoading { return "error:\(error)" }
        if basePackages.isEmpty && isLoading { return "loading" }
        if basePackages.isEmpty { return "empty:\(selectedKind.rawValue)" }
        if visiblePackages.isEmpty { return "noresults:\(selectedKind.rawValue)" }
        return "list:\(selectedKind.rawValue)"
    }

    var body: some View {
        VStack(spacing: CrystalGlass.Spacing.md) {
            header
            crystalKindPicker
            searchField
            suggestionRow
            contentPanel
            footer
        }
        .padding(CrystalGlass.Spacing.lg)
        .frame(width: 440)
        .frame(minHeight: 440, idealHeight: 560, maxHeight: 640)
        .background {
            ZStack {
                Color.clear
                CrystalAmbientBackground()
                GlassPanelBackground(
                    cornerRadius: CrystalGlass.Radius.panel,
                    strokeOpacity: highContrast ? 0.78 : 0.68,
                    fillOpacity: highContrast ? 1.25 : 1.05
                )
            }
            .ignoresSafeArea()
        }
        .scaleEffect(panelAppeared || reduceMotion ? 1 : 0.97)
        .opacity(panelAppeared || reduceMotion ? 1 : 0)
        .onAppear {
            guard !reduceMotion else {
                panelAppeared = true
                return
            }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                panelAppeared = true
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: CrystalGlass.Spacing.xs) {
            HStack(spacing: CrystalGlass.Spacing.sm) {
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                CrystalGlass.glassCyan,
                                CrystalGlass.glassCyan.opacity(0.75),
                                .white.opacity(0.9),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating, isActive: isLoading)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "What's new in Homebrew"))
                        .font(.title3)
                        .fontWeight(legibilityWeight == .bold ? .bold : .semibold)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(secondaryReadable)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: CrystalGlass.Spacing.xs)

                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.glassIcon)
                .disabled(isLoading)
                .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating, isActive: isLoading)
                .accessibilityLabel(String(localized: "Refresh new packages"))
            }
        }
    }

    private var subtitle: String {
        if isGlobalSearch {
            if isSearchingCatalog && visiblePackages.isEmpty {
                return String(localized: "Searching all of Homebrew…")
            }
            if !visiblePackages.isEmpty {
                return String(
                    format: String(localized: "%lld results across Homebrew"),
                    Int64(visiblePackages.count)
                )
            }
            return String(localized: "Searched all of Homebrew")
        }
        if isLoading && basePackages.isEmpty {
            return String(localized: "Loading from Homebrew…")
        }
        if !trimmedQuery.isEmpty && !basePackages.isEmpty {
            return String(
                format: String(localized: "%1$lld of %2$lld match"),
                Int64(visiblePackages.count),
                Int64(basePackages.count)
            )
        }
        if !visiblePackages.isEmpty {
            return String(
                format: String(localized: "%lld packages · tap a row to copy"),
                Int64(visiblePackages.count)
            )
        }
        if let fetchedAt {
            let template = String(localized: "Updated %@")
            return String(format: template, fetchedAt.formatted(.relative(presentation: .named)))
        }
        return String(localized: "Recently added to homebrew-core and homebrew-cask")
    }

    // MARK: - Kind picker

    private var crystalKindPicker: some View {
        HStack(spacing: CrystalGlass.Spacing.xs) {
            kindTab(.formula, title: String(localized: "Formulae"), count: count(for: .formula))
            kindTab(.cask, title: String(localized: "Casks"), count: count(for: .cask))
        }
        .padding(CrystalGlass.Spacing.xs)
        .background(
            GlassPanelBackground(
                cornerRadius: CrystalGlass.Radius.pill,
                strokeOpacity: highContrast ? 0.72 : 0.58,
                fillOpacity: 1.1
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Type"))
    }

    private func kindTab(_ kind: NewPackage.Kind, title: String, count: Int) -> some View {
        let isSelected = selectedKind == kind

        return Button {
            guard selectedKind != kind else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82)) {
                selectedKind = kind
                contentPhase += 1
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(kindAccent(kind).opacity(isSelected ? 0.22 : 0.12))
                    )
                    .foregroundStyle(isSelected ? kindAccent(kind) : tertiaryReadable)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, CrystalGlass.Spacing.sm)
            .padding(.horizontal, CrystalGlass.Spacing.sm)
            .foregroundStyle(isSelected ? .primary : secondaryReadable)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(.thinMaterial)
                        .overlay(
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            kindAccent(kind).opacity(0.18),
                                            .white.opacity(0.10),
                                            kindAccent(kind).opacity(0.08),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(kindAccent(kind).opacity(highContrast ? 0.75 : 0.55), lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "kind-tab", in: kindPickerNamespace)
                        .shadow(color: kindAccent(kind).opacity(0.18), radius: 8, y: 3)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: CrystalGlass.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(kindAccent(selectedKind))
                .accessibilityHidden(true)

            TextField(
                text: $searchQuery,
                prompt: Text(String(localized: "Search all of Homebrew"))
            ) {
                Text(String(localized: "Search all of Homebrew"))
            }
            .textFieldStyle(.plain)
            .font(.system(.subheadline, design: .monospaced))
            .foregroundStyle(.primary)
            .focused($searchFocused)
            .autocorrectionDisabled(true)
            .accessibilityLabel(String(localized: "Search all of Homebrew"))
            // Best-effort predictive accept: only swallow Tab when there's a
            // completion to apply, otherwise let focus traversal proceed.
            .onKeyPress(.tab) {
                guard let first = completions.first else { return .ignored }
                acceptCompletion(first)
                return .handled
            }
            // Debounce + the actual `brew search`/`brew info` run live in AppState.
            .onChange(of: searchQuery) { _, newValue in
                onSearch(newValue)
            }

            if isSearchingCatalog {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Searching all of Homebrew…"))
                    .transition(.scale.combined(with: .opacity))
            } else if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(tertiaryReadable)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear search"))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, CrystalGlass.Spacing.md)
        .padding(.vertical, CrystalGlass.Spacing.sm + 1)
        .background(
            GlassPanelBackground(
                cornerRadius: CrystalGlass.Radius.pill,
                strokeOpacity: searchFocused ? (highContrast ? 0.85 : 0.72) : (highContrast ? 0.68 : 0.5),
                fillOpacity: 1.1
            )
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(kindAccent(selectedKind).opacity(searchFocused ? 0.55 : 0), lineWidth: 1)
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: searchFocused)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: searchQuery.isEmpty)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var suggestionRow: some View {
        if !completions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CrystalGlass.Spacing.xs) {
                    ForEach(completions) { pkg in
                        suggestionChip(for: pkg)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
            }
            .frame(height: 30)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Suggestions"))
        }
    }

    private func suggestionChip(for pkg: NewPackage) -> some View {
        Button {
            acceptCompletion(pkg)
        } label: {
            Text(highlightedName(pkg.name))
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, CrystalGlass.Spacing.sm)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(.thinMaterial)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(kindAccent(pkg.kind).opacity(highContrast ? 0.6 : 0.4), lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Complete with \(pkg.name)"))
    }

    /// First `trimmedQuery.count` characters of the (prefix-matched) name are
    /// tinted with the kind accent so the chip reads as "what you typed + the
    /// predicted rest". Names are ASCII in Homebrew, so character counts line up.
    private func highlightedName(_ name: String) -> AttributedString {
        var attributed = AttributedString(name)
        let matchLen = min(trimmedQuery.count, name.count)
        guard matchLen > 0 else { return attributed }
        let end = attributed.index(attributed.startIndex, offsetByCharacters: matchLen)
        attributed[attributed.startIndex..<end].foregroundColor = kindAccent(selectedKind)
        return attributed
    }

    private func acceptCompletion(_ pkg: NewPackage) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) {
            searchQuery = pkg.name
        }
        searchFocused = true
    }

    // MARK: - Content panel

    private var contentPanel: some View {
        Group {
            if isGlobalSearch {
                if basePackages.isEmpty && isSearchingCatalog {
                    searchingState
                } else if let searchError, basePackages.isEmpty {
                    errorState(searchError)
                } else if basePackages.isEmpty {
                    searchEmptyState
                } else {
                    packagesList
                }
            } else if let error, basePackages.isEmpty, !isLoading {
                errorState(error)
            } else if basePackages.isEmpty && isLoading {
                loadingState
            } else if basePackages.isEmpty {
                emptyState
            } else if visiblePackages.isEmpty {
                searchEmptyState
            } else {
                packagesList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(CrystalGlass.Spacing.sm)
        .background(
            GlassPanelBackground(
                cornerRadius: CrystalGlass.Radius.panel - 4,
                strokeOpacity: highContrast ? 0.72 : 0.52,
                fillOpacity: 1.15
            )
        )
        .shadow(
            color: CrystalGlass.ambientShadow(intensity: highContrast ? 0.24 : 0.16),
            radius: 12,
            y: 5
        )
        .overlay(
            RoundedRectangle(cornerRadius: CrystalGlass.Radius.panel - 4, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            CrystalGlass.glassCyan.opacity(0.25),
                            .clear,
                            CrystalGlass.glassCyan.opacity(0.15),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .id(contentStateID)
        .transition(contentTransition)
        .animation(reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.86), value: contentStateID)
    }

    private var contentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.98, anchor: .top))
                .combined(with: .offset(y: 10)),
            removal: .opacity.combined(with: .scale(scale: 0.99))
        )
    }

    private var packagesList: some View {
        ScrollView {
            LazyVStack(spacing: CrystalGlass.Spacing.sm) {
                ForEach(Array(visiblePackages.enumerated()), id: \.element.id) { index, pkg in
                    row(for: pkg)
                        .opacity(panelAppeared || reduceMotion ? 1 : 0)
                        .offset(y: panelAppeared || reduceMotion ? 0 : 12)
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.84)
                                .delay(Double(index) * 0.035),
                            value: panelAppeared
                        )
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86),
                            value: contentPhase
                        )
                }
            }
            .padding(CrystalGlass.Spacing.xs)
        }
    }

    @ViewBuilder
    private func row(for pkg: NewPackage) -> some View {
        let isCopied = copiedID == pkg.id

        Button {
            copy(pkg)
        } label: {
            HStack(alignment: .top, spacing: CrystalGlass.Spacing.sm) {
                kindGlyph(for: pkg.kind)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(pkg.name)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 4)

                        kindBadge(for: pkg.kind)
                    }

                    if let desc = pkg.desc, !desc.isEmpty {
                        Text(desc)
                            .font(.subheadline)
                            .foregroundStyle(secondaryReadable)
                            .lineSpacing(2)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(String(localized: "No description available"))
                            .font(.subheadline)
                            .foregroundStyle(tertiaryReadable)
                            .italic()
                    }

                    if let addedAt = pkg.addedAt {
                        Text(addedAt.formatted(.relative(presentation: .named)))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(kindAccent(pkg.kind).opacity(highContrast ? 0.95 : 0.82))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(kindAccent(pkg.kind).opacity(0.14))
                            )
                    }
                }

                trailingIndicator(for: pkg, isCopied: isCopied)
            }
            .padding(.vertical, CrystalGlass.Spacing.sm + 2)
            .padding(.horizontal, CrystalGlass.Spacing.sm + 2)
            .background(rowBackground(isCopied: isCopied, kind: pkg.kind))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(NewPackageRowButtonStyle(reduceMotion: reduceMotion))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pkg.name). \(pkg.desc ?? "")")
        .accessibilityHint(String(localized: "Double tap to copy install command"))
        .help(pkg.installCommand)
    }

    private func kindGlyph(for kind: NewPackage.Kind) -> some View {
        Image(systemName: kind == .formula ? "terminal.fill" : "macwindow")
            .font(.caption.weight(.semibold))
            .foregroundStyle(kindAccent(kind))
            .frame(width: 28, height: 28)
            .background(
                Circle()
                    .fill(kindAccent(kind).opacity(0.16))
            )
            .overlay(
                Circle()
                    .strokeBorder(kindAccent(kind).opacity(0.35), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    private func kindBadge(for kind: NewPackage.Kind) -> some View {
        Text(kind == .formula
             ? String(localized: "Formula")
             : String(localized: "Cask"))
            .font(.caption2.weight(.bold))
            .foregroundStyle(kindAccent(kind))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(kindAccent(kind).opacity(0.16))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(kindAccent(kind).opacity(0.35), lineWidth: 0.5)
            )
    }

    private func rowBackground(isCopied: Bool, kind: NewPackage.Kind) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.thinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(highContrast ? 0.14 : 0.10),
                                kindAccent(kind).opacity(isCopied ? 0.16 : 0.05),
                                .white.opacity(0.03),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                kindAccent(kind).opacity(isCopied ? 0.75 : 0.42),
                                .white.opacity(0.28),
                                kindAccent(kind).opacity(0.30),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isCopied ? 1.25 : 1
                    )
            )
            .shadow(
                color: kindAccent(kind).opacity(isCopied ? 0.22 : 0.08),
                radius: isCopied ? 10 : 5,
                y: isCopied ? 4 : 2
            )
    }

    @ViewBuilder
    private func trailingIndicator(for pkg: NewPackage, isCopied: Bool) -> some View {
        if isCopied {
            VStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(
                        colorSchemeContrast == .increased
                            ? Color(red: 0, green: 0.6, blue: 0)
                            : .green
                    )
                    .symbolEffect(.bounce, value: isCopied)
                Text(String(localized: "Copied"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(secondaryReadable)
            }
            .transition(.scale.combined(with: .opacity))
        } else {
            Image(systemName: "doc.on.doc")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tertiaryReadable)
                .accessibilityHidden(true)
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: CrystalGlass.Spacing.md) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Text(String(localized: "Fetching latest formulae and casks…"))
                .font(.subheadline)
                .foregroundStyle(secondaryReadable)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchingState: some View {
        VStack(spacing: CrystalGlass.Spacing.md) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Text(String(localized: "Searching all of Homebrew…"))
                .font(.subheadline)
                .foregroundStyle(secondaryReadable)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: CrystalGlass.Spacing.sm) {
            Spacer()
            Image(systemName: selectedKind == .cask ? "macwindow.on.rectangle" : "shippingbox")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(tertiaryReadable)
                .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .default, value: contentPhase)
                .accessibilityHidden(true)
            Text(String(localized: "No new packages found"))
                .font(.headline.weight(.semibold))
                .foregroundStyle(secondaryReadable)
            Text(emptyStateDetail)
                .font(.subheadline)
                .foregroundStyle(tertiaryReadable)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CrystalGlass.Spacing.md)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateDetail: String {
        if selectedKind == .cask {
            return String(localized: "No recent casks in homebrew-cask. Try refreshing or check back later.")
        }
        return String(localized: "No recent formulae in homebrew-core. Try refreshing or check back later.")
    }

    private var searchEmptyState: some View {
        VStack(spacing: CrystalGlass.Spacing.sm) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(tertiaryReadable)
                .accessibilityHidden(true)
            Text(String(localized: "No matches"))
                .font(.headline.weight(.semibold))
                .foregroundStyle(secondaryReadable)
            Text(String(localized: "No packages match \(trimmedQuery)"))
                .font(.subheadline)
                .foregroundStyle(tertiaryReadable)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, CrystalGlass.Spacing.md)
            // Search runs across both kinds; if the active tab is empty but the
            // other has hits (e.g. searching a cask while on Formulae), surface a
            // jump so the result isn't hidden behind the inactive tab's badge.
            if otherKindResultCount > 0 {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82)) {
                        selectedKind = otherKind
                        contentPhase += 1
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: otherKind == .formula ? "terminal.fill" : "macwindow")
                        Text(crossKindLabel).fontWeight(.semibold)
                        Image(systemName: "arrow.right").font(.caption.weight(.bold))
                    }
                }
                .buttonStyle(.glassPillProminent)
                .accessibilityLabel(crossKindLabel)
            }
            Button {
                searchQuery = ""
                searchFocused = true
            } label: {
                Text(String(localized: "Clear search"))
            }
            .buttonStyle(.glassPill)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: CrystalGlass.Spacing.md) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(BrewTUIBarTheme.warning(highContrast: highContrast))
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(secondaryReadable)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            Button {
                onRefresh()
            } label: {
                Text(String(localized: "Retry"))
            }
            .buttonStyle(.glassPill)
            Spacer()
        }
        .padding(CrystalGlass.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: CrystalGlass.Spacing.sm) {
            if !visiblePackages.isEmpty {
                Button {
                    copyAll()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: allCopied ? "checkmark.circle.fill" : "doc.on.clipboard")
                            .font(.caption.weight(.semibold))
                        Text(allCopied
                             ? String(localized: "Copied!")
                             : String(localized: "Copy all (\(visiblePackages.count))"))
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.glassPill)
                .foregroundStyle(allCopied ? .green : .primary)
                .accessibilityLabel(String(localized: "Copy all install commands"))
                .accessibilityHint(
                    String(localized: "Copies all \(visiblePackages.count) install commands to the clipboard")
                )
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Text(String(localized: "Close"))
                    .fontWeight(.semibold)
            }
            .buttonStyle(.glassPillProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(String(localized: "Close new packages"))
        }
    }

    // MARK: - Tokens

    private var secondaryReadable: Color {
        highContrast ? Color.primary.opacity(0.88) : Color.secondary
    }

    private var tertiaryReadable: Color {
        highContrast ? Color.primary.opacity(0.72) : Color.secondary.opacity(0.82)
    }

    private func kindAccent(_ kind: NewPackage.Kind) -> Color {
        switch kind {
        case .formula:
            return highContrast
                ? Color(red: 0.05, green: 0.62, blue: 0.78)
                : CrystalGlass.glassCyan
        case .cask:
            return highContrast
                ? Color(red: 0.88, green: 0.42, blue: 0.34)
                : CrystalGlass.warmAccent
        }
    }

    // MARK: - Actions

    private func copy(_ pkg: NewPackage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pkg.installCommand, forType: .string)
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.72)) {
            copiedID = pkg.id
        }
        let pkgID = pkg.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if copiedID == pkgID {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    copiedID = nil
                }
            }
        }
    }

    private func copyAll() {
        guard !visiblePackages.isEmpty else { return }
        let combined = visiblePackages
            .map(\.installCommand)
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.72)) {
            allCopied = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                allCopied = false
            }
        }
    }
}

// MARK: - Row press style

private struct NewPackageRowButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .brightness(configuration.isPressed ? 0.03 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

// MARK: - Previews

#Preview("With data") {
    NewPackagesView(
        formulae: [
            NewPackage(
                name: "ripgrep-all",
                kind: .formula,
                addedAt: Date().addingTimeInterval(-3600),
                desc: "ripgrep, but also for PDFs, E-Books, Office documents, zip, tar.gz, etc.",
                homepage: URL(string: "https://example.com")
            ),
            NewPackage(
                name: "zellij",
                kind: .formula,
                addedAt: Date().addingTimeInterval(-86_400),
                desc: "Pluggable terminal workspace, with terminal multiplexer as the base feature",
                homepage: nil
            ),
            NewPackage(
                name: "uv",
                kind: .formula,
                addedAt: Date().addingTimeInterval(-172_800),
                desc: "Extremely fast Python package installer and resolver",
                homepage: nil
            )
        ],
        casks: [
            NewPackage(
                name: "ghostty",
                kind: .cask,
                addedAt: Date().addingTimeInterval(-7200),
                desc: "Fast, native, feature-rich terminal emulator",
                homepage: nil
            ),
            NewPackage(
                name: "microsoft-remote-help",
                kind: .cask,
                addedAt: Date().addingTimeInterval(-14_400),
                desc: "Remote assistance tool for Microsoft 365",
                homepage: nil
            )
        ],
        isLoading: false,
        error: nil,
        fetchedAt: Date().addingTimeInterval(-1200),
        searchResultsFormulae: [],
        searchResultsCasks: [],
        isSearchingCatalog: false,
        searchError: nil,
        searchResultsQuery: "",
        onSearch: { _ in },
        onClose: {},
        onRefresh: {}
    )
}

#Preview("Loading") {
    NewPackagesView(
        formulae: [],
        casks: [],
        isLoading: true,
        error: nil,
        fetchedAt: nil,
        searchResultsFormulae: [],
        searchResultsCasks: [],
        isSearchingCatalog: false,
        searchError: nil,
        searchResultsQuery: "",
        onSearch: { _ in },
        onClose: {},
        onRefresh: {}
    )
}

#Preview("Error") {
    NewPackagesView(
        formulae: [],
        casks: [],
        isLoading: false,
        error: "Could not load new packages: GitHub rate limit exceeded",
        fetchedAt: nil,
        searchResultsFormulae: [],
        searchResultsCasks: [],
        isSearchingCatalog: false,
        searchError: nil,
        searchResultsQuery: "",
        onSearch: { _ in },
        onClose: {},
        onRefresh: {}
    )
}

#Preview("Empty") {
    NewPackagesView(
        formulae: [],
        casks: [],
        isLoading: false,
        error: nil,
        fetchedAt: Date(),
        searchResultsFormulae: [],
        searchResultsCasks: [],
        isSearchingCatalog: false,
        searchError: nil,
        searchResultsQuery: "",
        onSearch: { _ in },
        onClose: {},
        onRefresh: {}
    )
}

#Preview("Global search results") {
    NewPackagesView(
        formulae: [],
        casks: [],
        isLoading: false,
        error: nil,
        fetchedAt: Date(),
        searchResultsFormulae: [
            NewPackage(
                name: "wget",
                kind: .formula,
                addedAt: nil,
                desc: "Internet file retriever",
                homepage: URL(string: "https://www.gnu.org/software/wget/")
            ),
            NewPackage(
                name: "oven-sh/bun/bun",
                kind: .formula,
                addedAt: nil,
                desc: "Incredibly fast JavaScript runtime, bundler, transpiler and package manager",
                homepage: nil
            ),
            NewPackage(
                name: "wget2",
                kind: .formula,
                addedAt: Date().addingTimeInterval(-3600),
                desc: "Successor of GNU Wget",
                homepage: nil
            )
        ],
        searchResultsCasks: [],
        isSearchingCatalog: false,
        searchError: nil,
        searchResultsQuery: "wget",
        onSearch: { _ in },
        onClose: {},
        onRefresh: {}
    )
}
