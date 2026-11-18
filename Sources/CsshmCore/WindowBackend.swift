// SPDX-License-Identifier: GPL-3.0-or-later

/// A terminal window as the backend reports it.
public struct WindowInfo: Equatable, Sendable {
    public var id: Int
    /// Device name of the window's terminal, e.g. `/dev/ttys004`.
    public var tty: String
    public var background: RGB
    public var foreground: RGB
    public var fontSize: Int

    public init(id: Int, tty: String, background: RGB, foreground: RGB, fontSize: Int) {
        self.id = id
        self.tty = tty
        self.background = background
        self.foreground = foreground
        self.fontSize = fontSize
    }
}

/// A window to open. Giving the bounds and style here lets the window appear
/// already in place, instead of being moved after it has opened.
public struct WindowRequest: Equatable, Sendable {
    /// The line typed into the new window's shell.
    public var command: String
    public var bounds: Rect?
    public var profile: String?
    public var fontSize: Int?

    public init(command: String, bounds: Rect? = nil, profile: String? = nil, fontSize: Int? = nil) {
        self.command = command
        self.bounds = bounds
        self.profile = profile
        self.fontSize = fontSize
    }
}

/// One change to a window. Operations are sent in batches.
public enum WindowOp: Equatable, Sendable {
    case setBounds(window: Int, Rect)
    case setColors(window: Int, foreground: RGB, background: RGB)
    /// Un-minimise and un-hide.
    case show(window: Int)
    case raise(window: Int)
    case hide(window: Int)
    case minimise(window: Int)
    case close(window: Int)
    /// Switch the window to a named profile of the terminal application.
    case setProfile(window: Int, name: String)
    case setFontSize(window: Int, size: Int)
}

/// Everything csshm asks of the terminal application and the display system.
/// The session logic talks only to this, so it can be tested without opening
/// windows and other terminal applications can be supported later.
public protocol WindowBackend {
    /// Visible frames of the attached displays, primary display first.
    func screens() throws -> [Rect]
    /// Opens one new window per request, in order and returns each one's
    /// id (`nil` where it could not be found out).
    func openWindows(_ requests: [WindowRequest]) throws -> [Int?]
    func listWindows() throws -> [WindowInfo]
    /// Names of the terminal application's profiles.
    func profileNames() throws -> [String]
    func bounds(of window: Int) throws -> Rect
    func perform(_ ops: [WindowOp]) throws
    /// The window's scrollback text.
    func history(of window: Int) throws -> String
    /// Brings the terminal application to the front.
    func activate() throws
}
