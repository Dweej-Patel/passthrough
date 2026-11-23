using System.Text;

namespace Passthrough.Core.Shell.Sessions;

/// <summary>
/// The terminal modes a program has turned on, followed through its output: what a replay that starts partway
/// through a session has to turn on first (a port of TerminalModes.swift). A full-screen program turns its modes on
/// once, when it starts; a long session soon pushes that out of the scrollback, and a terminal replayed only the rest
/// draws every frame on the main screen. Only modes that change what is drawn or what the keys and mouse send are
/// followed; synchronized output (2026) is not, as a replay must never begin holding the screen back.
/// </summary>
internal sealed class TerminalModes
{
    /// <summary>The on/off modes followed, with their defaults.</summary>
    internal static readonly IReadOnlyDictionary<int, bool> Switches =
        new Dictionary<int, bool> { [1] = false, [7] = true, [25] = true, [66] = false, [1004] = false, [2004] = false, [2031] = false };

    private const int CollectLimit = 64;

    internal sealed class Keyboard
    {
        public const int StackLimit = 16;
        public int Flags;
        public List<int> Stack = [];
        public Keyboard Clone() => new() { Flags = Flags, Stack = [.. Stack] };
    }

    private enum State { Ground, Escape, Csi, Ignoring }

    /// <summary>47, 1047 or 1049, whichever turned the alternate screen on.</summary>
    public int? AlternateScreen { get; private set; }
    /// <summary>9, 1000, 1001, 1002 or 1003.</summary>
    public int? MouseTracking { get; private set; }
    /// <summary>1005, 1006, 1015 or 1016.</summary>
    public int? MouseEncoding { get; private set; }
    private SortedDictionary<int, bool> _changed = [];
    public bool ApplicationKeypad { get; private set; }
    public int? ModifyOtherKeys { get; private set; }
    private Keyboard _keyboardMain = new();
    private Keyboard _keyboardAlternate = new();

    private State _state = State.Ground;
    private List<byte> _collected = [];

    public bool IsAlternateScreen => AlternateScreen is not null;

    public TerminalModes Clone() => new()
    {
        AlternateScreen = AlternateScreen, MouseTracking = MouseTracking, MouseEncoding = MouseEncoding,
        _changed = new SortedDictionary<int, bool>(_changed), ApplicationKeypad = ApplicationKeypad, ModifyOtherKeys = ModifyOtherKeys,
        _keyboardMain = _keyboardMain.Clone(), _keyboardAlternate = _keyboardAlternate.Clone(), _state = _state, _collected = [.. _collected],
    };

    public void Scan(ReadOnlySpan<byte> bytes)
    {
        var i = 0;
        while (i < bytes.Length)
        {
            // Nearly all output is text: in it, only an escape can change a mode.
            if (_state == State.Ground)
            {
                var escape = bytes[i..].IndexOf((byte)0x1B);
                if (escape < 0) return;
                i += escape;
            }
            Step(bytes[i]);
            i++;
        }
    }

    public TerminalModes Scanned(ReadOnlySpan<byte> bytes)
    {
        var copy = Clone();
        copy.Scan(bytes);
        return copy;
    }

    /// <summary>
    /// What turns a terminal just reset into one in these modes (empty when nothing is on). The main screen's keyboard
    /// flags come before the switch to the alternate screen, its own after.
    /// </summary>
    public byte[] Restoring()
    {
        var o = new StringBuilder();
        o.Append(Restore(_keyboardMain));
        if (AlternateScreen is { } alt) o.Append($"\u001b[?{alt}h");
        if (IsAlternateScreen) o.Append(Restore(_keyboardAlternate));
        foreach (var (mode, on) in _changed) o.Append($"\u001b[?{mode}{(on ? 'h' : 'l')}");
        if (MouseTracking is { } t) o.Append($"\u001b[?{t}h");
        if (MouseEncoding is { } e) o.Append($"\u001b[?{e}h");
        if (ApplicationKeypad) o.Append("\u001b=");
        if (ModifyOtherKeys is { } m) o.Append($"\u001b[>4;{m}m");
        return Encoding.UTF8.GetBytes(o.ToString());
    }

    /// <summary>Sets the flags at the bottom of the stack, then pushes each one above.</summary>
    private static string Restore(Keyboard keyboard)
    {
        var levels = keyboard.Stack.Append(keyboard.Flags).ToList();
        if (levels.All(l => l == 0)) return "";
        var o = new StringBuilder($"\u001b[={levels[0]};1u");
        foreach (var flags in levels.Skip(1)) o.Append($"\u001b[>{flags}u");
        return o.ToString();
    }

    private void Step(byte b)
    {
        switch (_state)
        {
            case State.Ground:
                if (b == 0x1B) _state = State.Escape;
                break;
            case State.Escape:
                switch (b)
                {
                    case (byte)'[': _state = State.Csi; _collected.Clear(); break;
                    case (byte)'=': ApplicationKeypad = true; _state = State.Ground; break;
                    case (byte)'>': ApplicationKeypad = false; _state = State.Ground; break;
                    case (byte)'c': ResetAll(); break; // full reset
                    // A string (OSC, DCS, APC…) is read as text: an escape ends it and begins a sequence, as in the
                    // phones' terminals, so its sequences count.
                    case 0x1B: break;
                    default: _state = State.Ground; break;
                }
                break;
            case State.Csi:
            case State.Ignoring:
                switch (b)
                {
                    case 0x1B: _state = State.Escape; break;
                    case 0x18 or 0x1A: _state = State.Ground; break; // CAN, SUB: the sequence is abandoned
                    case >= 0x20 and <= 0x3F:
                        if (_state == State.Csi)
                        {
                            if (_collected.Count < CollectLimit) _collected.Add(b);
                            else _state = State.Ignoring;
                        }
                        break;
                    case >= 0x40 and <= 0x7E:
                        if (_state == State.Csi) Dispatch(b);
                        _state = State.Ground;
                        break;
                    default: break; // other controls inside a sequence are carried out, not part of it
                }
                break;
        }
    }

    private void ResetAll()
    {
        AlternateScreen = MouseTracking = MouseEncoding = ModifyOtherKeys = null;
        _changed.Clear();
        ApplicationKeypad = false;
        _keyboardMain = new();
        _keyboardAlternate = new();
        _state = State.Ground;
        _collected.Clear();
    }

    private void Dispatch(byte final)
    {
        if (_collected.Count == 0) return;
        var lead = _collected[0];
        byte? marker = lead is >= 0x3C and <= 0x3F ? lead : null;
        var body = Encoding.ASCII.GetString([.. (marker is null ? _collected : _collected.Skip(1))]);
        var parameters = body.Split(';').Select(p => int.TryParse(p, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var v) ? v : (int?)null).ToList();
        var first = parameters.Count > 0 ? parameters[0] : null;
        switch (marker, (char)final)
        {
            case ((byte)'?', 'h'):
            case ((byte)'?', 'l'):
                foreach (var mode in parameters) if (mode is { } m) Set(m, final == (byte)'h');
                break;
            case ((byte)'>', 'u'):
                UpdateKeyboard(k =>
                {
                    if (k.Stack.Count >= Keyboard.StackLimit) k.Stack.RemoveAt(0);
                    k.Stack.Add(k.Flags);
                    k.Flags = first ?? 0;
                });
                break;
            case ((byte)'<', 'u'):
                var count = Math.Max(first ?? 1, 1);
                UpdateKeyboard(k =>
                {
                    if (count > k.Stack.Count) { k.Flags = 0; k.Stack.Clear(); return; }
                    for (int i = 0; i < count; i++) { k.Flags = k.Stack[^1]; k.Stack.RemoveAt(k.Stack.Count - 1); }
                });
                break;
            case ((byte)'=', 'u'):
                var flags = first ?? 0;
                var how = parameters.Count > 1 ? parameters[1] ?? 1 : 1;
                UpdateKeyboard(k =>
                {
                    switch (how)
                    {
                        case 1: k.Flags = flags; break;
                        case 2: k.Flags |= flags; break;
                        case 3: k.Flags &= ~flags; break;
                    }
                });
                break;
            case ((byte)'>', 'm'):
                if (first != 4) return;
                ModifyOtherKeys = parameters.Count > 1 ? parameters[1] : null;
                if (ModifyOtherKeys == 0) ModifyOtherKeys = null;
                break;
            case (null, 'p') when _collected.Count == 1 && _collected[0] == (byte)'!':
                // DECSTR, CSI ! p: a soft reset.
                _changed.Remove(1);
                _changed.Remove(25);
                _changed.Remove(66);
                ApplicationKeypad = false;
                break;
        }
    }

    private void Set(int mode, bool on)
    {
        switch (mode)
        {
            case 47 or 1047 or 1049: AlternateScreen = on ? mode : null; break;
            case 9 or 1000 or 1001 or 1002 or 1003: MouseTracking = on ? mode : null; break;
            case 1005 or 1006 or 1015 or 1016:
                if (on) MouseEncoding = mode;
                else if (MouseEncoding == mode) MouseEncoding = null;
                break;
            default:
                if (!Switches.TryGetValue(mode, out var initial)) return;
                if (on == initial) _changed.Remove(mode); else _changed[mode] = on;
                break;
        }
    }

    private void UpdateKeyboard(Action<Keyboard> change) => change(IsAlternateScreen ? _keyboardAlternate : _keyboardMain);
}
