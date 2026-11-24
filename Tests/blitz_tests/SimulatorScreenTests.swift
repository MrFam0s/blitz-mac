import Foundation
import Testing
@testable import Blitz

@Test func simulatorSelectsOnlyTheIntegratedDisplayMatchingTheActiveApplication() throws {
    let screens = SimulatorScreen.integratedScreens(in: """
        Port:
            Power state: On
            Connected Screens:
            (1) LCD:
                Screen ID: 1
                Device Name: primary
                Screen Type: Integrated
                Pixel Size: {1398, 2034}
                Preferred UI Scale: 3
            (2) TVOut:
                Screen ID: 2
                Device Name: external-0
                Screen Type: TVOut
                Pixel Size: {1398, 2034}
                Preferred UI Scale: 3
            (3) LCD-1:
                Screen ID: 3
                Device Name: primary-1
                Screen Type: Integrated
                Pixel Size: {2007, 2853}
                Preferred UI Scale: 3
                UI Orientation: Landscape Left
        Port:
            Power state: On
        """)
    #expect(screens.map(\.id) == ["1", "3"])
    #expect(screens[0].orientedPoints == nil)
    let inner = try SimulatorScreen.active(in: screens, applicationSize: CGSize(width: 669, height: 951))
    #expect(inner.orientedPoints == CGSize(width: 951, height: 669))
    #expect(try SimulatorScreen.active(in: screens, applicationSize: .init(width: 466, height: 678)).id == "1")
    #expect(try SimulatorScreen.active(in: screens, applicationSize: .init(width: 951, height: 669)).id == "3")
    #expect(throws: SimulatorScreen.ScreenError.self) {
        try SimulatorScreen.active(in: screens, applicationSize: .init(width: 430, height: 932))
    }
    #expect(throws: SimulatorScreen.ScreenError.self) {
        try SimulatorScreen.active(in: screens + screens, applicationSize: .init(width: 951, height: 669))
    }
}

@Test func simulatorDisplaySizeRequiresAFullApplicationRoot() throws {
    let frame = #"{"type":"Application","frame":{"x":0,"y":0,"width":951,"height":669}}"#
    #expect(try SimulatorScreen.applicationSize(from: Data("[\(frame)]".utf8)) == CGSize(width: 951, height: 669))
    for invalid in [frame.replacingOccurrences(of: "Application", with: "Button"),
                    frame.replacingOccurrences(of: #""x":0"#, with: #""x":200"#),
                    frame + "," + frame.replacingOccurrences(of: "951", with: "466")] {
        #expect(throws: SimulatorScreen.ScreenError.self) {
            try SimulatorScreen.applicationSize(from: Data("[\(invalid)]".utf8))
        }
    }
}
