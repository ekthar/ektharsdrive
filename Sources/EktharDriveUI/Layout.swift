import CoreGraphics

/// Window sizing so the three columns (sidebar, files, info panel) never fight for space.
public enum Layout {
    public static let sidebarWidth: CGFloat = 230
    /// Smallest window that still shows sidebar + a usable file area without macOS overlaying the sidebar.
    public static let windowMinWidth: CGFloat = 900
    /// The info panel shows only when the WINDOW is at least this wide: sidebar 230 + files 540 + panel 280.
    /// Measured on the window (not the file area) so showing the panel cannot change the measurement.
    static let inspectorNeedsWindowWidth: CGFloat = 1050
}
