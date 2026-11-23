import PassthroughCore
import ScreenClient

extension WindowsShortcut {
    /// The exact key events, in order.
    public var strokes: [WindowsKeymap.Stroke] {
        WindowsKeymap.strokes(for: chord.key, modifiers: chord.modifiers)
    }
}
