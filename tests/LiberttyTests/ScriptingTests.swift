import AppKit
import Testing
@testable import LiberttyApp

/// The AppleScript dictionary and the code behind it agree: every class
/// and command it names is there, under the name it gives.
struct ScriptingTests {
    private func sdef() throws -> XMLDocument {
        let url = try #require(AppResources.url("Libertty.sdef"))
        return try XMLDocument(contentsOf: url)
    }

    @Test func everyCocoaClassExists() throws {
        let doc = try sdef()
        let classes = try doc.nodes(forXPath: "//class/cocoa/@class").compactMap(\.stringValue)
        let commands = try doc.nodes(forXPath: "//command/cocoa/@class").compactMap(\.stringValue)
        #expect(classes.count == 3 && commands.count == 7)
        for name in classes { #expect(NSClassFromString(name) != nil, "no class \(name)") }
        for name in commands {
            let found: AnyClass? = NSClassFromString(name)
            #expect(found.map { $0 is NSScriptCommand.Type } == true, "no command class \(name)")
        }
    }

    @Test func everyKeyAndHandlerIsThere() throws {
        let doc = try sdef()
        for cls in try doc.nodes(forXPath: "//suite[@code='Lbty']/class") {
            guard let element = cls as? XMLElement, let cocoa = try element.nodes(forXPath: "cocoa/@class").first?.stringValue,
                  let found = NSClassFromString(cocoa) as? NSObject.Type else { continue }
            for key in try element.nodes(forXPath: "property/cocoa/@key | element/cocoa/@key").compactMap(\.stringValue) {
                #expect(found.instancesRespond(to: NSSelectorFromString(key)), "\(cocoa) has no \(key)")
            }
            for method in try element.nodes(forXPath: "responds-to/cocoa/@method").compactMap(\.stringValue) {
                #expect(found.instancesRespond(to: NSSelectorFromString(method)), "\(cocoa) has no \(method)")
            }
        }
        // The application's elements, on NSApplication.
        for key in try doc.nodes(forXPath: "//class-extension[@extends='application']/element/cocoa/@key").compactMap(\.stringValue) {
            #expect(NSApplication.instancesRespond(to: NSSelectorFromString(key)), "NSApplication has no \(key)")
        }
    }
}
