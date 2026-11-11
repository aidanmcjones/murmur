import ApplicationServices
import Foundation

/// Minimal abstraction over an accessibility element so the walk / extraction logic can be tested with fake trees.
protocol AXNode {
    /// Attribute value as a Swift value (String, Bool, NSNumber, NSAttributedString...), nil when unavailable.
    func attr(_ name: String) -> Any?
    func children() -> [AXNode]
    func stringForRange(location: Int, length: Int) -> String?
}

enum AXRead {
    static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]

    static func isSecure(_ n: AXNode) -> Bool {
        for a in ["AXRole", "AXSubrole"] where (n.attr(a) as? String) == "AXSecureTextField" { return true }
        return false
    }

    /// Web areas / groups report focus on a container: walk down to the focused text area / field / contenteditable.
    static func descendFocused(_ n: AXNode, depth: Int = 0) -> AXNode {
        if let role = n.attr("AXRole") as? String, textRoles.contains(role) { return n }
        guard depth < 6 else { return n }
        for k in n.children().prefix(100) where (k.attr("AXFocused") as? Bool) == true {
            return descendFocused(k, depth: depth + 1)
        }
        return n
    }

    /// AXValue, falling back to AXStringForRange over AXNumberOfCharacters.
    static func value(_ n: AXNode, maxChars: Int) -> String? {
        if let v = n.attr("AXValue") {
            if let s = v as? String { return s }
            if let a = v as? NSAttributedString { return a.string }
        }
        guard let count = (n.attr("AXNumberOfCharacters") as? NSNumber)?.intValue, count > 0, count <= maxChars else { return nil }
        return n.stringForRange(location: 0, length: count)
    }

    // MARK: Self test with fake trees

    final class Fake: AXNode {
        var props: [String: Any]
        var kids: [Fake]
        var range: String?
        init(_ props: [String: Any] = [:], kids: [Fake] = [], range: String? = nil) { self.props = props; self.kids = kids; self.range = range }
        func attr(_ name: String) -> Any? { props[name] }
        func children() -> [AXNode] { kids }
        func stringForRange(location: Int, length: Int) -> String? { range.map { String($0.prefix(length)) } }
    }

    static func selfTest() -> Int {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            if !ok { fails += 1 }
            print("\(ok ? "PASS" : "FAIL") ax-\(name)")
        }
        // Chromium-style: focus reported on the web area; the focused textarea sits several levels down.
        let ta = Fake(["AXRole": "AXTextArea", "AXFocused": true, "AXValue": "take control of my Kolabtree tab"])
        let other = Fake(["AXRole": "AXTextField", "AXFocused": false, "AXValue": "decoy"])
        let group = Fake(["AXRole": "AXGroup", "AXFocused": true], kids: [other, ta])
        let web = Fake(["AXRole": "AXWebArea"], kids: [Fake(["AXRole": "AXGroup"], kids: [Fake(["AXRole": "AXGroup", "AXFocused": false])]), group])
        let hit = descendFocused(web) as? Fake
        check("web-area-descends-to-focused-textarea", hit === ta)
        check("textfield-returned-directly", descendFocused(other) as? Fake === other)
        check("no-focused-child-stays", (descendFocused(Fake(["AXRole": "AXWebArea"], kids: [other])) as? Fake)?.props["AXRole"] as? String == "AXWebArea")
        // contenteditable div exposed as AXTextArea with AXValue.
        check("contenteditable-value", value(ta, maxChars: 1000) == "take control of my Kolabtree tab")
        // Value missing: fall back to AXStringForRange over AXNumberOfCharacters.
        let big = Fake(["AXRole": "AXTextArea", "AXNumberOfCharacters": NSNumber(value: 5)], range: "hello world")
        check("string-for-range-fallback", value(big, maxChars: 1000) == "hello")
        check("string-for-range-too-long", value(big, maxChars: 3) == nil)
        check("attributed-value", value(Fake(["AXValue": NSAttributedString(string: "attr")]), maxChars: 10) == "attr")
        check("non-text-value-nil", value(Fake(["AXValue": NSNumber(value: 3)]), maxChars: 10) == nil)
        check("empty-field-value", value(Fake(["AXValue": ""]), maxChars: 10) == "")
        // Secure fields: by role or subrole.
        check("secure-role", isSecure(Fake(["AXRole": "AXSecureTextField"])))
        check("secure-subrole", isSecure(Fake(["AXRole": "AXTextField", "AXSubrole": "AXSecureTextField"])))
        check("plain-not-secure", !isSecure(ta))
        let pw = Fake(["AXRole": "AXWebArea"], kids: [Fake(["AXRole": "AXTextField", "AXSubrole": "AXSecureTextField", "AXFocused": true])])
        check("secure-found-via-descend", isSecure(descendFocused(pw)))
        // Depth bound.
        var deep = Fake(["AXRole": "AXTextArea", "AXFocused": true])
        for _ in 0..<10 { deep = Fake(["AXRole": "AXGroup", "AXFocused": true], kids: [deep]) }
        check("depth-bounded", (descendFocused(deep) as? Fake)?.props["AXRole"] as? String == "AXGroup")
        return fails
    }
}

/// Real AX element.
struct RealAX: AXNode {
    let el: AXUIElement
    init(_ el: AXUIElement) { self.el = el }

    func attr(_ name: String) -> Any? {
        var r: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &r) == .success ? r : nil
    }

    func children() -> [AXNode] {
        guard let arr = attr("AXChildren") as? [AXUIElement] else { return [] }
        return arr.map { k in AXUIElementSetMessagingTimeout(k, 0.4); return RealAX(k) }
    }

    func stringForRange(location: Int, length: Int) -> String? {
        var range = CFRange(location: location, length: length)
        guard let axr = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, axr, &out) == .success
        else { return nil }
        return out as? String
    }
}
