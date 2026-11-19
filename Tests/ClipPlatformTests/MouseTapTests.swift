import CoreGraphics
import Testing
@testable import ClipPlatform

private func wheel(_ units: CGScrollEventUnit, vertical: Int32, horizontal: Int32) -> CGEvent {
    CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)!
}

@Test func wheelEventIsFlippedOnBothAxes() {
    let event = wheel(.line, vertical: 3, horizontal: -1)
    let point = (event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
    #expect(MouseTap.flipIfWheel(event))
    #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -3)
    #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 1)
    #expect(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) == -3)
    #expect(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) == 1)
    // The exact negation, not the accelerated value macOS recomputes from the line delta.
    #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -point.0)
    #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -point.1)
}

@Test func trackpadEventIsLeftAlone() {
    let event = wheel(.pixel, vertical: 10, horizontal: 0)
    #expect(!MouseTap.flipIfWheel(event))
    #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 10)
}

@Test func sideButtonsOnlyTranslateWhereTheyAreIgnored() {
    #expect(MouseTap.navigates("com.apple.Safari"))
    #expect(MouseTap.navigates("com.apple.finder"))
    #expect(MouseTap.navigates("com.apple.Safari.WebApp.ABC123"))
    // Chrome handles the buttons itself; in VS Code ⌘[ would outdent the line.
    #expect(!MouseTap.navigates("com.google.Chrome"))
    #expect(!MouseTap.navigates("com.microsoft.VSCode"))
    #expect(!MouseTap.navigates(nil))
}
