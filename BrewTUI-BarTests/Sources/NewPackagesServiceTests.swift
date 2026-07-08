import Testing
import Foundation
@testable import BrewTUI_Bar

@Suite("NewPackagesService commit message parser")
struct NewPackagesServiceParserTests {
    @Test("Merge PR wrapping a (new formula) line extracts the formula name")
    func mergePRFormula() {
        let msg = "Merge pull request #286257 from YupItzAfi/libbcg729\n\nlibbcg729 1.1.1 (new formula)"
        #expect(NewPackagesService.extractPackageName(from: msg, kind: .formula) == "libbcg729")
    }

    @Test("Direct commit with (new formula) on the first line")
    func directCommitFormula() {
        let msg = "zellij 0.42.0 (new formula)"
        #expect(NewPackagesService.extractPackageName(from: msg, kind: .formula) == "zellij")
    }

    @Test("Versioned formula keeps its @-fragment")
    func versionedFormula() {
        let msg = "Merge pull request #1\n\npython@3.13 3.13.1 (new formula)"
        #expect(NewPackagesService.extractPackageName(from: msg, kind: .formula) == "python@3.13")
    }

    @Test("Cask kind requires (new cask) suffix, not (new formula)")
    func caskKindIsolated() {
        let formulaMsg = "ghostty 1.0 (new formula)"
        #expect(NewPackagesService.extractPackageName(from: formulaMsg, kind: .cask) == nil)
        let caskMsg = "ghostty 1.0 (new cask)"
        #expect(NewPackagesService.extractPackageName(from: caskMsg, kind: .cask) == "ghostty")
    }

    @Test("Cask commits with an Add prefix extract the token, not Add")
    func addPrefixCask() {
        let msg = "Merge pull request #268160 from AdamBaali/add-microsoft-remote-help\n\nAdd microsoft-remote-help (new cask)"
        #expect(NewPackagesService.extractPackageName(from: msg, kind: .cask) == "microsoft-remote-help")
    }

    @Test("Message without the (new <kind>) suffix returns nil")
    func noSuffix() {
        let msg = "Merge pull request #999\n\nfoo 1.0 (rebuild)"
        #expect(NewPackagesService.extractPackageName(from: msg, kind: .formula) == nil)
    }

    @Test("First token starting with a digit or punctuation is rejected")
    func invalidFirstToken() {
        // A line that contains the suffix but starts with a non-letter first
        // token would let bogus rows through (e.g. truncated merge titles).
        let msg = "1.0 (new formula)"
        #expect(NewPackagesService.extractPackageName(from: msg, kind: .formula) == nil)
        let msg2 = "--option (new formula)"
        #expect(NewPackagesService.extractPackageName(from: msg2, kind: .formula) == nil)
    }

    @Test("Names with disallowed characters (spaces, colons) are rejected")
    func disallowedCharacters() {
        // isValidPackageName must guard against tokens that pass the split but
        // contain punctuation Homebrew never uses in formula names.
        #expect(NewPackagesService.isValidPackageName("foo:bar") == false)
        #expect(NewPackagesService.isValidPackageName("foo bar") == false)
        #expect(NewPackagesService.isValidPackageName("foo") == true)
        #expect(NewPackagesService.isValidPackageName("python@3.13") == true)
        #expect(NewPackagesService.isValidPackageName("gtk+3") == true)
    }

    @Test("Date parser accepts fractional and base ISO 8601 forms")
    func dateParsing() {
        let withFraction = NewPackagesService.parseDate("2026-06-04T15:24:17.000Z")
        #expect(withFraction.timeIntervalSince1970 > 1_000_000_000)
        let withoutFraction = NewPackagesService.parseDate("2026-06-04T15:24:17Z")
        #expect(withoutFraction.timeIntervalSince1970 > 1_000_000_000)
        // Invalid strings fall back to "now" (within a few seconds of the test run).
        let fallback = NewPackagesService.parseDate("not a date")
        #expect(abs(fallback.timeIntervalSinceNow) < 5)
    }
}

@Suite("NewPackage")
struct NewPackageTests {
    @Test("installCommand differs by kind")
    func installCommandByKind() {
        let formula = NewPackage(name: "ripgrep", kind: .formula, addedAt: Date(), desc: nil, homepage: nil)
        let cask = NewPackage(name: "ghostty", kind: .cask, addedAt: Date(), desc: nil, homepage: nil)
        #expect(formula.installCommand == "brew install ripgrep")
        #expect(cask.installCommand == "brew install --cask ghostty")
    }

    @Test("id namespaces the name by kind so formula+cask homonyms don't collide")
    func idIsNamespaced() {
        let formula = NewPackage(name: "node", kind: .formula, addedAt: Date(), desc: nil, homepage: nil)
        let cask = NewPackage(name: "node", kind: .cask, addedAt: Date(), desc: nil, homepage: nil)
        #expect(formula.id != cask.id)
        #expect(formula.id == "formula:node")
        #expect(cask.id == "cask:node")
    }

    @Test("addedAt is optional — search hits carry nil, novelties carry a date")
    func addedAtOptional() {
        let hit = NewPackage(name: "wget", kind: .formula, addedAt: nil, desc: "Internet file retriever", homepage: nil)
        #expect(hit.addedAt == nil)
        #expect(hit.installCommand == "brew install wget")
    }
}

@Suite("CatalogSearchService")
struct CatalogSearchServiceTests {
    @Test("parseSearchOutput drops the tip line, blanks and headers")
    func parseSearchOutputFilters() {
        // Real `brew search --formula wget` stdout: names, then a tip line that
        // brew prints to *stdout* (not stderr).
        let stdout = """
        wget
        wget2
        wgetpaste
        Use `brew desc` to list packages with a short description.
        """
        #expect(CatalogSearchService.parseSearchOutput(stdout) == ["wget", "wget2", "wgetpaste"])
    }

    @Test("parseSearchOutput strips ==> section headers if a TTY reintroduces them")
    func parseSearchOutputStripsHeaders() {
        let stdout = "==> Formulae\nwget\n\n==> Casks\ngoogle-chrome\n"
        #expect(CatalogSearchService.parseSearchOutput(stdout) == ["wget", "google-chrome"])
    }

    @Test("isValidCandidate accepts bare, versioned and tapped names")
    func candidateValidity() {
        #expect(CatalogSearchService.isValidCandidate("wget"))
        #expect(CatalogSearchService.isValidCandidate("bun@1.2.3"))
        #expect(CatalogSearchService.isValidCandidate("oven-sh/bun/bun"))
        #expect(CatalogSearchService.isValidCandidate("google-chrome@beta"))
        #expect(CatalogSearchService.isValidCandidate("foo bar") == false)
        #expect(CatalogSearchService.isValidCandidate("1node") == false)
    }

    @Test("rank floats exact, then prefix, then contains; caps to the limit")
    func ranking() {
        let names = ["libwget", "wget2", "wget", "oven-sh/x/wget-extra", "nowget"]
        let ranked = CatalogSearchService.rank(names, query: "wget", limit: 10)
        // Exact base-name match first, then prefix matches in brew's order,
        // then contains matches.
        #expect(ranked.first == "wget")
        #expect(ranked.firstIndex(of: "wget2")! < ranked.firstIndex(of: "libwget")!)
        #expect(ranked.firstIndex(of: "wget2")! < ranked.firstIndex(of: "nowget")!)
    }

    @Test("rank caps the result count")
    func rankingCap() {
        let names = (0..<100).map { "pkg\($0)" }
        #expect(CatalogSearchService.rank(names, query: "pkg", limit: 50).count == 50)
    }

    @Test("rank treats the last path component as the base name for tapped packages")
    func rankingTappedBaseName() {
        let names = ["zzz-decoy", "owner/tap/bun"]
        let ranked = CatalogSearchService.rank(names, query: "bun", limit: 10)
        #expect(ranked.first == "owner/tap/bun")
    }

    @Test("rank sinks version-pinned names below clean ones")
    func rankingVersionedSink() {
        let names = ["bun@1.2.3", "bun", "bun@0.5.0"]
        let ranked = CatalogSearchService.rank(names, query: "bun", limit: 10)
        #expect(ranked == ["bun", "bun@1.2.3", "bun@0.5.0"])
    }

    @Test("rank keeps the exact versioned match on top when the query has @")
    func rankingVersionedQuery() {
        let names = ["python", "python@3.13"]
        let ranked = CatalogSearchService.rank(names, query: "python@3.13", limit: 10)
        #expect(ranked.first == "python@3.13")
    }

    @Test("parseInfo decodes formulae by full_name and casks by token")
    func parseInfoKeys() {
        let json = """
        {
          "formulae": [
            {"full_name": "wget", "desc": "Internet file retriever", "homepage": "https://www.gnu.org/software/wget/"},
            {"full_name": "oven-sh/bun/bun", "desc": "Fast JS runtime", "homepage": "https://bun.sh"}
          ],
          "casks": [
            {"token": "google-chrome", "desc": "Web browser", "homepage": "https://www.google.com/chrome/"}
          ]
        }
        """.data(using: .utf8)!

        let formulae = CatalogSearchService.parseInfo(json, kind: .formula)
        #expect(formulae["wget"]?.desc == "Internet file retriever")
        #expect(formulae["oven-sh/bun/bun"]?.homepage?.absoluteString == "https://bun.sh")
        #expect(formulae["google-chrome"] == nil)

        let casks = CatalogSearchService.parseInfo(json, kind: .cask)
        #expect(casks["google-chrome"]?.desc == "Web browser")
        #expect(casks["wget"] == nil)
    }

    @Test("parseInfo returns empty on malformed JSON instead of throwing")
    func parseInfoMalformed() {
        let garbage = Data("not json".utf8)
        #expect(CatalogSearchService.parseInfo(garbage, kind: .formula).isEmpty)
    }
}
