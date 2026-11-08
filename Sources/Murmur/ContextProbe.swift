import AppKit
import ApplicationServices

struct AppContext {
    var bundleId: String
    var appName: String
    var before: String
}

enum ContextProbe {
    static func current() -> AppContext {
        let app = NSWorkspace.shared.frontmostApplication
        return AppContext(bundleId: app?.bundleIdentifier ?? "",
                          appName: app?.localizedName ?? "",
                          before: textBeforeCursor())
    }

    static func textBeforeCursor() -> String {
        guard AXIsProcessTrusted() else { return "" }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.4)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return "" }
        let el = f as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.25)
        for attr in [kAXRoleAttribute, kAXSubroleAttribute] {
            var r: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, attr as CFString, &r) == .success,
               (r as? String) == "AXSecureTextField" { return "" }
        }
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &val) == .success,
              let str = val as? String else { return "" }
        var rangeRef: CFTypeRef?
        var loc = (str as NSString).length
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let r = rangeRef, CFGetTypeID(r) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(r as! AXValue, .cfRange, &range) { loc = range.location }
        }
        let ns = str as NSString
        let before = ns.substring(to: max(0, min(loc, ns.length)))
        return String(before.suffix(400))
    }

    static func name(forBundleId id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let b = Bundle(url: url)
            if let n = (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String) { return n }
            return url.deletingPathExtension().lastPathComponent
        }
        return id.split(separator: ".").last.map(String.init) ?? id
    }
}
