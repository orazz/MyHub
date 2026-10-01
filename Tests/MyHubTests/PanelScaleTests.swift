import AppKit
import Testing
@testable import MyHub

@MainActor
@Suite struct PanelSizeTests {
    func metrics(_ size: PanelSize) -> ScreenMetrics? {
        NSScreen.screens.first.flatMap { ScreenMetrics(screen: $0, fullHeightDrawn: false, panelSize: size) }
    }

    @Test func biggerPanelsGiveTheTabsMoreRoomNotBiggerText() throws {
        let standard = try #require(metrics(.standard)), xl = try #require(metrics(.extraLarge))
        #expect(standard.bodySize == CGSize(width: 600, height: 300))
        #expect(xl.contentHeight - standard.contentHeight == 120)
        #expect(xl.collapsedSize == standard.collapsedSize)
    }

    @Test func theDefaultMatchesTheHandoff() throws {
        let m = try #require(metrics(.standard))
        // 38 top + 200 content + 14 + 34 + 14 on any notch up to 32pt tall.
        if m.notch.height <= 32 { #expect(m.contentHeight == 200) }
        #expect(m.topPadding >= m.notch.height + 6)
    }

    @Test func aPanelTheScreenCannotHoldIsCapped() throws {
        let screen = try #require(NSScreen.screens.first)
        let m = try #require(ScreenMetrics(screen: screen, fullHeightDrawn: false, panelSize: .extraLarge))
        #expect(m.bodySize.width <= screen.frame.width)
        #expect(m.bodySize.height <= screen.frame.height)
    }

    @Test func differentSizesDoNotMatch() throws {
        #expect(try !#require(metrics(.standard)).matches(try #require(metrics(.large))))
    }
}

@Suite struct StashLayoutTests {
    @Test func defaultWidthIsTheMocksFourColumnsOneRow() {
        let layout = StashView.layout(for: CGSize(width: 564, height: 164), count: 12)
        #expect(layout.columns == 4)
        #expect(layout.rows == 1)
        #expect(layout.tile.width == 135)
    }

    @Test func widerAndTallerPanelsShowMoreTiles() {
        let xl = StashView.layout(for: CGSize(width: 724, height: 284), count: 12)
        #expect(xl.columns == 5)
        #expect(xl.rows == 2)
        #expect(xl.tile.height == 138)
    }

    @Test func aFewFilesStayInOneRowEvenInATallPanel() {
        #expect(StashView.layout(for: CGSize(width: 724, height: 284), count: 4).rows == 1)
    }
}

@MainActor
@Suite struct PanelPositionTests {
    func metrics(_ position: PanelPosition) throws -> ScreenMetrics {
        let screen = try #require(NSScreen.screens.first)
        return try #require(ScreenMetrics(screen: screen, fullHeightDrawn: false, panelSize: .standard, position: position))
    }

    @Test func sidePanelsAreDockedToTheirEdgeAtMidHeight() throws {
        let left = try metrics(.left), right = try metrics(.right)
        let frame = left.screen.frame
        let l = left.bodyRect(left.bodySize), r = right.bodyRect(right.bodySize)
        #expect(l.minX == frame.minX)
        #expect(r.maxX == frame.maxX)
        #expect(l.midY == frame.midY)
        #expect(r.midY == frame.midY)
    }

    @Test func topStaysUnderTheNotch() throws {
        let top = try metrics(.center)
        let body = top.bodyRect(top.bodySize)
        #expect(body.midX == top.screen.frame.midX)
        #expect(body.maxY == top.screen.frame.maxY)
    }

    @Test func aClosedSidePanelIsAVerticalStripOnTheEdge() throws {
        let left = try metrics(.left), right = try metrics(.right)
        let frame = left.screen.frame
        #expect(left.collapsedSize == CGSize(width: ScreenMetrics.drawnStripDepth, height: ScreenMetrics.sideStripLength))
        // A pointer pushed against the edge at mid-height is inside.
        #expect(left.openRect.contains(CGPoint(x: frame.minX, y: frame.midY)))
        #expect(right.openRect.contains(CGPoint(x: frame.maxX - 1, y: frame.midY)))
        // …and one at the top of the edge is not.
        #expect(!left.openRect.contains(CGPoint(x: frame.minX, y: frame.maxY - 5)))
    }

    @Test func sidePanelsNeedNoNotchPadding() throws {
        let left = try metrics(.left), top = try metrics(.center)
        #expect(left.topPadding == ScreenMetrics.sideTopPadding)
        #expect(left.contentHeight > top.contentHeight)
    }

    @Test func theWindowCoversTheBodyWithRoomForTheShadow() throws {
        for position in PanelPosition.allCases {
            let m = try metrics(position)
            #expect(m.windowFrame.contains(m.bodyRect(m.bodySize)))
        }
    }

    @Test func positionsDoNotMatchEachOther() throws {
        #expect(try !metrics(.left).matches(try metrics(.right)))
    }
}
