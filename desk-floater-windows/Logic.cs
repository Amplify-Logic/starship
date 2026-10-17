// The Windows desk floater's decisions, kept apart from Windows itself so
// SelfTest.cs can check them anywhere a C# compiler runs. Written for the C# 5
// compiler that ships with .NET Framework 4, which install uses.
// See docs/desk-floater-windows.md.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace StarshipFloater
{
    /// <summary>
    /// A modifier key that acts on a lone tap: pressed and released within the
    /// tap limit, with no other key, click or modifier used while it was down.
    /// A key with a typing guard also leaves taps close to typing alone:
    /// pressed within <c>Quiet</c> of the last key, or followed by a key within
    /// <c>Settle</c> of its release, it was a Shift brushed while typing rather
    /// than a tap. Times are seconds. Mirrors the Mac floater's TapKey.
    /// </summary>
    public sealed class TapKey
    {
        public readonly double Limit;
        public readonly double Quiet;
        public readonly double Settle;
        private double? downAt;
        private bool chorded;
        private double? lastKeyAt;
        private double? pending;

        public TapKey(double limit, double quiet, double settle)
        {
            Limit = limit;
            Quiet = quiet;
            Settle = settle;
        }

        /// <summary>Right Ctrl: dictation.</summary>
        public static TapKey Dictate() { return new TapKey(0.5, 0, 0); }

        /// <summary>Right Shift: a screenshot, kept away from typing.</summary>
        public static TapKey Shot() { return new TapKey(0.5, 1.5, 0.5); }

        public bool IsDown { get { return downAt.HasValue; } }

        /// <summary>A click or another modifier while this key is down makes it part of a shortcut.</summary>
        public void Chord()
        {
            if (downAt.HasValue)
            {
                chorded = true;
            }
        }

        /// <summary>
        /// A key press: part of a shortcut while this key is down, and typing
        /// that a tap close to it belongs to.
        /// </summary>
        public void KeyPressed(double now)
        {
            lastKeyAt = lastKeyAt.HasValue ? Math.Max(lastKeyAt.Value, now) : now;
            if (pending.HasValue && now >= pending.Value && now - pending.Value < Settle)
            {
                pending = null;
            }
            Chord();
        }

        /// <summary>
        /// The key went down. Windows repeats a held key's down event, so a
        /// key already down stays as it was.
        /// </summary>
        public void Down(double now, bool otherModifiersHeld)
        {
            if (downAt.HasValue)
            {
                return;
            }
            downAt = now;
            chorded = otherModifiersHeld || Typed(now);
        }

        /// <summary>The key came up; true when that completes a lone tap.</summary>
        public bool Up(double now)
        {
            if (!downAt.HasValue)
            {
                return false;
            }
            double started = downAt.Value;
            downAt = null;
            if (chorded || now - started >= Limit)
            {
                return false;
            }
            if (Settle > 0)
            {
                pending = now;
            }
            return true;
        }

        /// <summary>
        /// Called <c>Settle</c> after a tap released at <paramref name="tap"/>:
        /// true when it still stands, with no key pressed in between and no
        /// later tap replacing it.
        /// </summary>
        public bool TakeSettled(double tap)
        {
            if (!pending.HasValue || pending.Value != tap)
            {
                return false;
            }
            pending = null;
            return true;
        }

        private bool Typed(double now)
        {
            return Quiet > 0 && lastKeyAt.HasValue && now - lastKeyAt.Value < Quiet;
        }
    }

    public enum TalkAction
    {
        None,
        Begin,
        Deliver,
        Drop
    }

    /// <summary>
    /// Right Alt held is push-to-talk. A key or click in the first moment of
    /// the hold makes it a shortcut instead and drops the hold. After that the
    /// captain is talking: a key or a click leaves the recording running, and
    /// releasing the key still sends it. Mirrors the Mac floater's TalkKey.
    /// </summary>
    public sealed class TalkKey
    {
        public readonly double ShortcutWindow;
        private double? downAt;

        public TalkKey() : this(0.3) { }

        public TalkKey(double shortcutWindow)
        {
            ShortcutWindow = shortcutWindow;
        }

        public bool IsDown { get { return downAt.HasValue; } }

        public TalkAction Update(bool down, double now)
        {
            if (down && !downAt.HasValue)
            {
                downAt = now;
                return TalkAction.Begin;
            }
            if (!down && downAt.HasValue)
            {
                downAt = null;
                return TalkAction.Deliver;
            }
            return TalkAction.None;
        }

        /// <summary>A key press or click while the key may be down.</summary>
        public TalkAction Chord(double now)
        {
            if (!downAt.HasValue || now - downAt.Value >= ShortcutWindow)
            {
                return TalkAction.None;
            }
            downAt = null;
            return TalkAction.Drop;
        }
    }

    /// <summary>
    /// Screenshots waiting to go to Firstmate, and the talk-to-Firstmate words
    /// held to go with them. They go as one message once <c>Window</c> seconds
    /// have passed since the last shot or the end of the last talk, so each new
    /// one restarts the wait. Mirrors the Mac floater's ShotStack.
    /// </summary>
    public sealed class ShotStack
    {
        public const double Window = 3;

        private readonly List<string> shots = new List<string>();
        private int inFlight;
        private string transcript;
        private double? lastActivity;

        public int Count { get { return shots.Count + inFlight; } }
        public int InFlight { get { return inFlight; } }
        public string Transcript { get { return transcript; } }
        public bool IsEmpty { get { return transcript == null && Count == 0; } }

        /// <summary>When the stack may go, unless a capture or a talk is still under way.</summary>
        public double DueAt { get { return (lastActivity.HasValue ? lastActivity.Value : double.MinValue / 2) + Window; } }

        public void ShotStarted(double now)
        {
            inFlight++;
            Touch(now);
        }

        /// <summary>A capture finished: its image path, or null when it failed.</summary>
        public void ShotFinished(string path, double now)
        {
            inFlight--;
            if (path != null)
            {
                shots.Add(path);
                Touch(now);
            }
        }

        public void TalkEnded(double now)
        {
            Touch(now);
        }

        /// <summary>
        /// Holds a transcript to go with the stack, after any words already
        /// held. False when nothing is stacked, so the words should go at once.
        /// </summary>
        public bool Hold(string text)
        {
            if (transcript != null)
            {
                transcript = transcript + " " + text;
                return true;
            }
            if (Count <= 0)
            {
                return false;
            }
            transcript = text;
            return true;
        }

        public bool Ready(double now)
        {
            return !IsEmpty && inFlight == 0 && now >= DueAt;
        }

        /// <summary>Empties the stack, returning the words held (or null) and the images.</summary>
        public string Take(out List<string> images)
        {
            string text = transcript;
            images = new List<string>(shots);
            transcript = null;
            shots.Clear();
            return text;
        }

        private void Touch(double now)
        {
            lastActivity = lastActivity.HasValue ? Math.Max(lastActivity.Value, now) : now;
        }
    }

    /// <summary>When saved talk-to-Firstmate recordings are tried again. Mirrors the Mac floater's Recording.</summary>
    public static class RetryPlan
    {
        /// <summary>Seconds before each automatic retry of a saved recording.</summary>
        public static readonly double[] Delays = { 20, 60, 300 };

        /// <summary>A retry that finds another retry running looks again after this long, without counting as an attempt.</summary>
        public const double BusyDelay = 30;

        /// <summary>The wait before the next retry after <paramref name="attempts"/> attempts, or null when they are used up.</summary>
        public static double? DelayAfter(int attempts)
        {
            int index = attempts - 1;
            if (index < 0 || index >= Delays.Length)
            {
                return null;
            }
            return Delays[index];
        }
    }

    /// <summary>The status line words for one send outcome line of bin/fm-desk-voice.sh send.</summary>
    public static class SendOutcome
    {
        public const string SavedForFirstmate = "Saved for Firstmate";

        /// <summary>The status to show, or null when nothing was delivered.</summary>
        public static string Status(string line)
        {
            if (line == null)
            {
                return null;
            }
            if (line.StartsWith("sent:", StringComparison.Ordinal))
            {
                return "Sent";
            }
            if (line.StartsWith("sent-unconfirmed:", StringComparison.Ordinal))
            {
                return "Sent, unconfirmed";
            }
            if (line.StartsWith("mailbox:", StringComparison.Ordinal))
            {
                return SavedForFirstmate;
            }
            return null;
        }
    }

    public enum RetryKind
    {
        Delivered,
        Unsent,
        Busy,
        Gone
    }

    /// <summary>One line of bin/fm-desk-voice.sh retry.</summary>
    public sealed class RetryResult
    {
        public RetryKind Kind;
        public string Status;
        public int Attempts;

        public static RetryResult Parse(string line)
        {
            if (line == null)
            {
                return null;
            }
            string[] cols = line.TrimEnd('\r', '\n').Split('\t');
            if (cols.Length < 2)
            {
                return null;
            }
            RetryResult r = new RetryResult();
            switch (cols[0])
            {
                case "delivered":
                    if (cols.Length < 3) return null;
                    r.Kind = RetryKind.Delivered;
                    r.Status = SendOutcome.Status(cols[2]) ?? SendOutcome.SavedForFirstmate;
                    return r;
                case "unsent":
                    int attempts;
                    if (cols.Length < 3 || !int.TryParse(cols[2], NumberStyles.None, CultureInfo.InvariantCulture, out attempts)) return null;
                    r.Kind = RetryKind.Unsent;
                    r.Attempts = attempts;
                    return r;
                case "busy":
                    r.Kind = RetryKind.Busy;
                    return r;
                case "gone":
                    r.Kind = RetryKind.Gone;
                    return r;
                default:
                    return null;
            }
        }
    }

    /// <summary>
    /// One outcome line of bin/fm-desk-floater-windows.sh bridge: its first
    /// tab-separated column names it and the rest are its fields.
    /// </summary>
    public sealed class BridgeLine
    {
        public string Kind;
        public string[] Fields;

        public string Field(int i)
        {
            return i < Fields.Length ? Fields[i] : null;
        }

        /// <summary>
        /// The lines of <paramref name="output"/> whose kind is one of
        /// <paramref name="kinds"/>; anything else a login script printed is
        /// ignored.
        /// </summary>
        public static List<BridgeLine> Parse(string output, params string[] kinds)
        {
            List<BridgeLine> lines = new List<BridgeLine>();
            if (output == null)
            {
                return lines;
            }
            foreach (string raw in output.Replace("\r", "").Split('\n'))
            {
                if (raw.Length == 0)
                {
                    continue;
                }
                string kind;
                string[] fields;
                int tab = raw.IndexOf('\t');
                if (tab < 0)
                {
                    kind = raw;
                    fields = new string[0];
                }
                else
                {
                    kind = raw.Substring(0, tab);
                    fields = raw.Substring(tab + 1).Split('\t');
                }
                // Send outcomes are "sent: ..." and the like, named by their prefix.
                int colon = kind.IndexOf(':');
                string name = colon > 0 ? kind.Substring(0, colon + 1) : kind;
                if (Array.IndexOf(kinds, name) < 0)
                {
                    continue;
                }
                BridgeLine line = new BridgeLine();
                line.Kind = name;
                line.Fields = colon > 0 ? new[] { raw } : fields;
                lines.Add(line);
            }
            return lines;
        }

        /// <summary>The first line of <paramref name="output"/> of one of <paramref name="kinds"/>, or null.</summary>
        public static BridgeLine First(string output, params string[] kinds)
        {
            List<BridgeLine> lines = Parse(output, kinds);
            return lines.Count > 0 ? lines[0] : null;
        }
    }

    /// <summary>One reply from bin/fm-speak.sh --history.</summary>
    public sealed class RecentReply
    {
        public int Number;
        public DateTime Time;
        public string Text;

        /// <summary>Reads "&lt;number&gt; TAB &lt;epoch&gt; TAB &lt;text&gt;" lines, newest first.</summary>
        public static List<RecentReply> Parse(string output)
        {
            List<RecentReply> replies = new List<RecentReply>();
            if (output == null)
            {
                return replies;
            }
            foreach (string raw in output.Replace("\r", "").Split('\n'))
            {
                string[] cols = raw.Split(new[] { '\t' }, 3);
                int number;
                long epoch;
                if (cols.Length != 3
                    || !int.TryParse(cols[0], NumberStyles.None, CultureInfo.InvariantCulture, out number)
                    || !long.TryParse(cols[1], NumberStyles.None, CultureInfo.InvariantCulture, out epoch))
                {
                    continue;
                }
                RecentReply reply = new RecentReply();
                reply.Number = number;
                reply.Time = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(epoch).ToLocalTime();
                reply.Text = cols[2];
                replies.Add(reply);
            }
            return replies;
        }
    }

    /// <summary>The spoken voice's level, as bin/fm-speak.sh --volume keeps it.</summary>
    public static class VoiceVolume
    {
        public const int Standard = 100;

        /// <summary>
        /// The highest level the Windows floater offers: Windows playback
        /// cannot go louder than the Windows volume itself.
        /// </summary>
        public const int Max = 100;

        public static int Clamp(int level)
        {
            return Math.Max(0, Math.Min(Max, level));
        }

        /// <summary>The level bin/fm-speak.sh --volume printed, or null.</summary>
        public static int? Parse(string output)
        {
            int level;
            if (output == null || !int.TryParse(output.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out level))
            {
                return null;
            }
            return level;
        }
    }

    /// <summary>Names of the recordings the floater makes, and what they carry.</summary>
    public static class RecordingName
    {
        public static string Make(string id, string purpose)
        {
            return id + "-" + purpose + ".wav";
        }

        /// <summary>The id and purpose a recording's file name carries, or false for any other file.</summary>
        public static bool Split(string fileName, out string id, out string purpose)
        {
            id = null;
            purpose = null;
            if (fileName == null || !fileName.EndsWith(".wav", StringComparison.Ordinal))
            {
                return false;
            }
            string stem = fileName.Substring(0, fileName.Length - 4);
            foreach (string p in new[] { "firstmate", "dictate" })
            {
                string tail = "-" + p;
                if (stem.EndsWith(tail, StringComparison.Ordinal) && stem.Length > tail.Length)
                {
                    id = stem.Substring(0, stem.Length - tail.Length);
                    purpose = p;
                    return IsId(id);
                }
            }
            return false;
        }

        /// <summary>The recording ids the bridge accepts.</summary>
        public static bool IsId(string id)
        {
            if (id == null || id.Length < 8 || id.Length > 64 || id[0] == '-')
            {
                return false;
            }
            foreach (char c in id)
            {
                if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-'))
                {
                    return false;
                }
            }
            return true;
        }
    }

    /// <summary>
    /// Builds a Windows command line that the C runtime's argument rules
    /// (which wsl.exe follows) split back into exactly these arguments.
    /// </summary>
    public static class CommandLine
    {
        public static string Join(IEnumerable<string> args)
        {
            StringBuilder sb = new StringBuilder();
            foreach (string arg in args)
            {
                if (sb.Length > 0)
                {
                    sb.Append(' ');
                }
                Quote(sb, arg);
            }
            return sb.ToString();
        }

        public static void Quote(StringBuilder sb, string arg)
        {
            if (arg.Length > 0 && arg.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            {
                sb.Append(arg);
                return;
            }
            sb.Append('"');
            int slashes = 0;
            foreach (char c in arg)
            {
                if (c == '\\')
                {
                    slashes++;
                    continue;
                }
                if (c == '"')
                {
                    sb.Append('\\', slashes * 2 + 1);
                }
                else
                {
                    sb.Append('\\', slashes);
                }
                slashes = 0;
                sb.Append(c);
            }
            sb.Append('\\', slashes * 2);
            sb.Append('"');
        }
    }

    /// <summary>Which Windows apps are terminals that may be showing the Firstmate chat.</summary>
    public static class Terminals
    {
        private static readonly string[] Names =
        {
            "windowsterminal", "openconsole", "conhost", "wsl", "wslhost", "mintty",
            "alacritty", "wezterm-gui", "tabby", "hyper", "ubuntu", "ubuntu2404", "ubuntu2204"
        };

        public static bool IsTerminal(string processName)
        {
            if (string.IsNullOrEmpty(processName))
            {
                return false;
            }
            return Array.IndexOf(Names, processName.ToLowerInvariant()) >= 0;
        }
    }

    /// <summary>The settings install writes beside the floater: key=value lines.</summary>
    public sealed class FloaterConfig
    {
        public string Distro;
        public string Root;
        public string Home;
        public string Version;

        public static FloaterConfig Parse(IEnumerable<string> lines)
        {
            FloaterConfig c = new FloaterConfig();
            foreach (string raw in lines)
            {
                string line = raw.Trim();
                int eq = line.IndexOf('=');
                if (eq <= 0)
                {
                    continue;
                }
                string key = line.Substring(0, eq).Trim();
                string value = line.Substring(eq + 1).Trim();
                switch (key)
                {
                    case "distro": c.Distro = value; break;
                    case "root": c.Root = value; break;
                    case "home": c.Home = value; break;
                    case "version": c.Version = value; break;
                }
            }
            return c;
        }

        public bool Complete
        {
            get { return !string.IsNullOrEmpty(Distro) && !string.IsNullOrEmpty(Root) && !string.IsNullOrEmpty(Home); }
        }
    }
}
