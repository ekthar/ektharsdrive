import CoreGraphics

/// Window sizing so the three columns (sidebar, files, info panel) never fight for space.
public enum Layout {
    public static let sidebarWidth: CGFloat = 230
    /// Smallest window that still shows sidebar + a usable file area without macOS overlaying the sidebar.
    public static let windowMinWidth: CGFloat = 900
    /// Hide the info panel when the file area next to it drops below this width...
    static let hideInspectorBelow: CGFloat = 520
    /// ...and bring it back only once the file area (without the panel) is this wide. The gap between the two
    /// numbers is larger than the panel itself, so showing it can never immediately trigger hiding it again.
    static let showInspectorAbove: CGFloat = 880
}
