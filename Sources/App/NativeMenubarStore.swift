import Foundation

/// Swift mirror of vscode's real `IMenubarData`
/// (`src/vs/platform/menubar/common/menubar.ts`, verified from source —
/// see code-server's `menubar` channel implementation,
/// `code-server/src/node/routes/ipadVSCodeIpc.ts`, which is what actually
/// pushes this). Field names/shapes match exactly so `Decodable`
/// synthesis needs no custom `CodingKeys`.
///
/// This is genuinely what vscode itself computed from its own live menu
/// registry (contributed commands, keybindings.json, installed
/// extensions' menu contributions) for the current window — not anything
/// this app authored. Consuming it to build the native menu bar is what
/// makes "File/Edit/... shows what vscode defines" real, as opposed to
/// the hand-authored `.commands{}` tree in iPadVSCodeApp.swift today.
struct IMenubarData: Decodable {
    let menus: [String: IMenubarMenu]
    let keybindings: [String: IMenubarKeybinding]
}

struct IMenubarMenu: Decodable {
    let items: [MenubarMenuItem]
}

struct IMenubarKeybinding: Decodable {
    let label: String
    let userSettingsLabel: String?
    /// "Assumed true if missing" per the real source's own comment.
    let isNative: Bool?
}

/// Mirrors vscode's real discriminated union
/// (`IMenubarMenuItemAction | IMenubarMenuItemSubmenu | IMenubarMenuItemSeparator | IMenubarMenuRecentItemAction`)
/// as a Swift enum, since none of those four shapes carries an explicit
/// `"type"` tag on the wire — real vscode itself discriminates
/// structurally (`isMenubarMenuItemSubmenu`/`isMenubarMenuItemSeparator`/
/// `isMenubarMenuItemRecentAction`/`isMenubarMenuItemAction`, in that
/// order, in `common/menubar.ts`), so this custom `init(from:)` checks
/// the same distinguishing fields in the same order rather than
/// guessing a different discrimination scheme.
enum MenubarMenuItem: Decodable {
    case action(IMenubarMenuItemAction)
    case submenu(IMenubarMenuItemSubmenu)
    case separator
    case recentAction(IMenubarMenuRecentItemAction)

    private enum CodingKeys: String, CodingKey {
        case id, label, submenu, uri
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.submenu) {
            self = .submenu(try IMenubarMenuItemSubmenu(from: decoder))
            return
        }
        if let id = try container.decodeIfPresent(String.self, forKey: .id), id == "vscode.menubar.separator" {
            self = .separator
            return
        }
        if container.contains(.uri) {
            self = .recentAction(try IMenubarMenuRecentItemAction(from: decoder))
            return
        }
        self = .action(try IMenubarMenuItemAction(from: decoder))
    }
}

struct IMenubarMenuItemAction: Decodable {
    let id: String
    let label: String
    /// "Assumed false if missing" / "Assumed true if missing" per the
    /// real source's own comments on these two fields.
    let checked: Bool?
    let enabled: Bool?
}

struct IMenubarMenuItemSubmenu: Decodable {
    let id: String
    let label: String
    let submenu: IMenubarMenu
}

struct IMenubarMenuRecentItemAction: Decodable {
    let id: String
    let label: String
    /// Kept as a plain string (the real field is a vscode `URI`, a
    /// structured `{scheme, authority, path, ...}` object, not a bare
    /// URI string) — not yet consumed by anything, so not worth a full
    /// `URI`-shaped decode until a real caller needs to open one of
    /// these.
    let enabled: Bool?
}

/// Holds the most recently pushed `IMenubarData` — the seam a future
/// dynamic native-menu builder (UIMenuBuilder-based, replacing
/// iPadVSCodeApp.swift's hand-authored `.commands{}` tree) will read
/// from. Not wired to any UI yet: this milestone is "receive and parse
/// real vscode menu data correctly," not yet "render it."
@MainActor
final class NativeMenubarStore: ObservableObject {
    static let shared = NativeMenubarStore()

    @Published private(set) var latest: IMenubarData?
    @Published private(set) var lastDecodeError: String?

    private init() {}

    /// Called with the raw JSON text from a `{"kind": "menubarUpdate", "data": ...}`
    /// out-of-band push (`VSCodeIPCWebSocketRelay`'s `.string` case) — the
    /// `"data"` payload specifically, already unwrapped from that
    /// envelope.
    func ingest(rawMenubarDataJSON: Data) {
        do {
            latest = try JSONDecoder().decode(IMenubarData.self, from: rawMenubarDataJSON)
            lastDecodeError = nil
        } catch {
            lastDecodeError = "\(error)"
        }
    }
}
