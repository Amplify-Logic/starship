// The Windows desk floater: a thin native shell over this home's WSL side.
// It owns only what must happen on Windows - the floating control, the
// hotkeys, recording, screenshots, playback and pasting into the focused app -
// and hands everything else to bin/fm-desk-floater-windows.sh bridge inside
// WSL, which runs the same delivery code the Mac floater uses.
// Written for the C# 5 compiler that ships with .NET Framework 4, which
// bin/fm-desk-floater-windows.sh install uses. See docs/desk-floater-windows.md.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace StarshipFloater
{
    internal static class Program
    {
        internal const string InstanceName = "Local\\StarshipFloater.Instance";
        internal const string QuitName = "Local\\StarshipFloater.Quit";
        internal const string StopPlaybackName = "Local\\StarshipFloater.StopPlayback";

        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length > 0)
            {
                switch (args[0])
                {
                    case "--play":
                        return Player.Play(args);
                    case "--stop-playback":
                        Player.SignalStop();
                        return 0;
                    case "--quit":
                        return Quit();
                }
            }
            string testMicrophone = null;
            for (int i = 0; i + 1 < args.Length; i++)
            {
                if (args[i] == "--test-microphone")
                {
                    testMicrophone = args[i + 1];
                }
            }

            Native.MakeDpiAware();
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            string ini = Path.Combine(dir, "floater.ini");
            FloaterConfig config = File.Exists(ini) ? FloaterConfig.Parse(File.ReadAllLines(ini)) : new FloaterConfig();
            if (!config.Complete)
            {
                MessageBox.Show("This floater has no Starship home set up. In your Ubuntu window, run:\n\n" +
                    "bin/fm-desk-floater-windows.sh install", "Starship floater");
                return 1;
            }

            Mutex instance = new Mutex(false, InstanceName);
            bool owned;
            try
            {
                // A floater restarting after an update waits for the old one to go.
                owned = instance.WaitOne(10000);
            }
            catch (AbandonedMutexException)
            {
                owned = true;
            }
            if (!owned)
            {
                return 0;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new FloaterForm(dir, config, testMicrophone, instance));
            return 0;
        }

        /// <summary>Asks a running floater to quit and waits up to five seconds for it to go.</summary>
        private static int Quit()
        {
            EventWaitHandle quit;
            if (!EventWaitHandle.TryOpenExisting(QuitName, out quit))
            {
                return 0;
            }
            using (quit)
            {
                quit.Set();
            }
            using (Mutex instance = new Mutex(false, InstanceName))
            {
                try
                {
                    if (instance.WaitOne(5000))
                    {
                        instance.ReleaseMutex();
                    }
                }
                catch (AbandonedMutexException)
                {
                }
            }
            return 0;
        }
    }

    /// <summary>Runs bin/fm-desk-floater-windows.sh inside this home's WSL distribution.</summary>
    internal sealed class Bridge
    {
        private readonly FloaterConfig config;
        private readonly string wsl;
        private readonly Action<string> log;

        public Bridge(FloaterConfig config, Action<string> log)
        {
            this.config = config;
            this.log = log;
            wsl = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "wsl.exe");
        }

        /// <summary>
        /// Runs the script with <paramref name="args"/> and <paramref name="input"/>
        /// on its standard input. Returns its standard output, or null when it
        /// could not be run, timed out, or exited non-zero.
        /// </summary>
        public string Run(string[] args, byte[] input, int timeoutSeconds)
        {
            List<string> all = new List<string>();
            all.Add("-d");
            all.Add(config.Distro);
            all.Add("--cd");
            all.Add("~");
            all.Add("-e");
            all.Add(config.Root + "/bin/fm-desk-floater-windows.sh");
            all.AddRange(args);
            ProcessStartInfo psi = new ProcessStartInfo(wsl, CommandLine.Join(all));
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = new UTF8Encoding(false);
            psi.StandardErrorEncoding = new UTF8Encoding(false);
            psi.EnvironmentVariables["FM_HOME"] = config.Home;
            string wslenv = Environment.GetEnvironmentVariable("WSLENV");
            psi.EnvironmentVariables["WSLENV"] = string.IsNullOrEmpty(wslenv) ? "FM_HOME" : wslenv + ":FM_HOME";
            string verb = args.Length > 1 ? args[0] + " " + args[1] : (args.Length > 0 ? args[0] : "");
            try
            {
                using (Process p = Process.Start(psi))
                {
                    string stdout = null;
                    string stderr = null;
                    Thread reader = new Thread(delegate() { stdout = p.StandardOutput.ReadToEnd(); });
                    Thread errors = new Thread(delegate() { stderr = p.StandardError.ReadToEnd(); });
                    reader.IsBackground = true;
                    errors.IsBackground = true;
                    reader.Start();
                    errors.Start();
                    try
                    {
                        if (input != null && input.Length > 0)
                        {
                            p.StandardInput.BaseStream.Write(input, 0, input.Length);
                        }
                        p.StandardInput.Close();
                    }
                    catch (IOException)
                    {
                    }
                    if (!p.WaitForExit(timeoutSeconds * 1000))
                    {
                        try { p.Kill(); } catch (InvalidOperationException) { }
                        log(verb + ": timed out after " + timeoutSeconds + " s");
                        return null;
                    }
                    reader.Join(5000);
                    errors.Join(5000);
                    if (p.ExitCode != 0)
                    {
                        log(verb + ": exit " + p.ExitCode + ": " + Trim(stderr));
                        return null;
                    }
                    if (!string.IsNullOrEmpty(stderr))
                    {
                        log(verb + ": " + Trim(stderr));
                    }
                    return stdout ?? "";
                }
            }
            catch (Exception e)
            {
                log(verb + ": could not run wsl.exe: " + e.Message);
                return null;
            }
        }

        private static string Trim(string text)
        {
            if (text == null)
            {
                return "";
            }
            text = text.Replace("\r", "").Trim().Replace("\n", " | ");
            return text.Length > 400 ? text.Substring(0, 400) + "..." : text;
        }
    }

    /// <summary>
    /// The microphone, through Windows' MCI wave audio device: 16 kHz, 16-bit
    /// mono, the format bin/fm-deepgram-stt.sh is given on the Mac too. The
    /// device is opened ahead of a press so recording starts at once. With a
    /// test microphone set, a recorded file stands in for the microphone so the
    /// whole path can be proven on a machine with none.
    /// </summary>
    internal sealed class Recorder
    {
        private const string Alias = "fmrec";
        private bool open;
        private bool recording;
        private readonly string testFile;

        public Recorder(string testFile)
        {
            this.testFile = testFile;
        }

        public bool HasDevice
        {
            get { return testFile != null || Native.waveInGetNumDevs() > 0; }
        }

        public void Prepare()
        {
            if (open || testFile != null)
            {
                return;
            }
            string error;
            if (!Mci.Send("open new type waveaudio alias " + Alias, out error))
            {
                return;
            }
            open = true;
            // Each setting on its own, so a device that refuses one keeps the rest.
            Mci.Send("set " + Alias + " bitspersample 16", out error);
            Mci.Send("set " + Alias + " channels 1", out error);
            Mci.Send("set " + Alias + " samplespersec 16000", out error);
            Mci.Send("set " + Alias + " bytespersec 32000", out error);
            Mci.Send("set " + Alias + " alignment 2", out error);
        }

        public bool Start(out string error)
        {
            error = null;
            if (testFile != null)
            {
                recording = true;
                return true;
            }
            Prepare();
            if (!open)
            {
                error = "no microphone";
                return false;
            }
            if (!Mci.Send("record " + Alias, out error))
            {
                Close();
                return false;
            }
            recording = true;
            return true;
        }

        /// <summary>Stops recording and writes the audio to <paramref name="path"/>.</summary>
        public bool Finish(string path, out string error)
        {
            error = null;
            if (!recording)
            {
                error = "not recording";
                return false;
            }
            recording = false;
            if (testFile != null)
            {
                try
                {
                    File.Copy(testFile, path, true);
                    return true;
                }
                catch (Exception e)
                {
                    error = e.Message;
                    return false;
                }
            }
            bool ok = Mci.Send("stop " + Alias, out error) && Mci.Send("save " + Alias + " \"" + path + "\"", out error);
            Close();
            return ok && File.Exists(path);
        }

        public void Cancel()
        {
            if (recording && testFile == null)
            {
                string error;
                Mci.Send("stop " + Alias, out error);
                Close();
            }
            recording = false;
        }

        private void Close()
        {
            string error;
            if (open)
            {
                Mci.Send("close " + Alias, out error);
            }
            open = false;
        }
    }

    internal static class Mci
    {
        public static bool Send(string command, out string error)
        {
            int code = Native.mciSendString(command, null, 0, IntPtr.Zero);
            if (code == 0)
            {
                error = null;
                return true;
            }
            StringBuilder text = new StringBuilder(256);
            Native.mciGetErrorString(code, text, text.Capacity);
            error = text.ToString();
            return false;
        }

        public static string Query(string command)
        {
            StringBuilder text = new StringBuilder(128);
            return Native.mciSendString(command, text, text.Capacity, IntPtr.Zero) == 0 ? text.ToString() : null;
        }
    }

    /// <summary>
    /// The player bin/fm-desk-play-windows.sh runs for each spoken reply:
    /// StarshipFloater.exe --play &lt;file&gt; [--volume 0-1000] plays it and returns
    /// when it ends, or at once on --stop-playback.
    /// </summary>
    internal static class Player
    {
        public static int Play(string[] args)
        {
            if (args.Length < 2)
            {
                return 2;
            }
            string path = args[1];
            int volume = 1000;
            for (int i = 2; i + 1 < args.Length; i++)
            {
                if (args[i] == "--volume")
                {
                    int.TryParse(args[i + 1], NumberStyles.None, CultureInfo.InvariantCulture, out volume);
                }
            }
            volume = Math.Max(0, Math.Min(1000, volume));
            string alias = "fmplay" + Process.GetCurrentProcess().Id;
            string error;
            using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.ManualReset, Program.StopPlaybackName))
            {
                stop.Reset();
                if (!Mci.Send("open \"" + path + "\" type mpegvideo alias " + alias, out error))
                {
                    Console.Error.WriteLine("cannot open " + path + ": " + error);
                    return 1;
                }
                try
                {
                    Mci.Send("setaudio " + alias + " volume to " + volume, out error);
                    if (!Mci.Send("play " + alias, out error))
                    {
                        Console.Error.WriteLine("cannot play " + path + ": " + error);
                        return 1;
                    }
                    while (!stop.WaitOne(100))
                    {
                        string mode = Mci.Query("status " + alias + " mode");
                        if (mode != "playing" && mode != "seeking")
                        {
                            break;
                        }
                    }
                }
                finally
                {
                    Mci.Send("close " + alias, out error);
                }
            }
            return 0;
        }

        public static void SignalStop()
        {
            EventWaitHandle stop;
            if (EventWaitHandle.TryOpenExisting(Program.StopPlaybackName, out stop))
            {
                using (stop)
                {
                    stop.Set();
                }
            }
        }
    }

    /// <summary>
    /// Global keys, watched on a thread of their own so a busy floater never
    /// slows the keyboard: Right Alt held talks to Firstmate, a lone tap of
    /// Right Ctrl starts or finishes dictation, and a lone tap of Right Shift
    /// away from typing takes a screenshot. Keys are only watched, never
    /// swallowed. Events are handed to the form's thread in order.
    /// </summary>
    internal sealed class Hotkeys
    {
        /// <summary>Marks the key presses the floater itself sends, so it never reacts to them.</summary>
        public static readonly IntPtr OwnInput = new IntPtr(0x464D4653);

        public delegate void KeyHandler(int vk, int scan, bool down, double time);
        public delegate void ClickHandler(double time);

        private readonly Control owner;
        private readonly KeyHandler onKey;
        private readonly ClickHandler onClick;
        private Native.HookProc keyProc;
        private Native.HookProc mouseProc;
        private readonly Stopwatch clock = Stopwatch.StartNew();

        public Hotkeys(Control owner, KeyHandler onKey, ClickHandler onClick)
        {
            this.owner = owner;
            this.onKey = onKey;
            this.onClick = onClick;
        }

        public void Start()
        {
            Thread thread = new Thread(Run);
            thread.IsBackground = true;
            thread.Name = "hotkeys";
            thread.Start();
        }

        private void Run()
        {
            keyProc = KeyHook;
            mouseProc = MouseHook;
            IntPtr module = Native.GetModuleHandle(null);
            Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, keyProc, module, 0);
            Native.SetWindowsHookEx(Native.WH_MOUSE_LL, mouseProc, module, 0);
            Native.MSG msg;
            while (Native.GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
            {
                Native.TranslateMessage(ref msg);
                Native.DispatchMessage(ref msg);
            }
        }

        private IntPtr KeyHook(int code, IntPtr wParam, IntPtr lParam)
        {
            if (code >= 0)
            {
                Native.KBDLLHOOKSTRUCT k = (Native.KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(Native.KBDLLHOOKSTRUCT));
                if (k.dwExtraInfo != OwnInput)
                {
                    int message = wParam.ToInt32();
                    bool down = message == Native.WM_KEYDOWN || message == Native.WM_SYSKEYDOWN;
                    bool up = message == Native.WM_KEYUP || message == Native.WM_SYSKEYUP;
                    if ((down || up) && owner.IsHandleCreated)
                    {
                        owner.BeginInvoke(onKey, (int)k.vkCode, (int)k.scanCode, down, clock.Elapsed.TotalSeconds);
                    }
                }
            }
            return Native.CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
        }

        private IntPtr MouseHook(int code, IntPtr wParam, IntPtr lParam)
        {
            if (code >= 0)
            {
                int message = wParam.ToInt32();
                if ((message == Native.WM_LBUTTONDOWN || message == Native.WM_RBUTTONDOWN || message == Native.WM_MBUTTONDOWN)
                    && owner.IsHandleCreated)
                {
                    Native.MSLLHOOKSTRUCT m = (Native.MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(Native.MSLLHOOKSTRUCT));
                    if (m.dwExtraInfo != OwnInput)
                    {
                        owner.BeginInvoke(onClick, clock.Elapsed.TotalSeconds);
                    }
                }
            }
            return Native.CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
        }

        public static bool IsDown(int vk)
        {
            return (Native.GetAsyncKeyState(vk) & 0x8000) != 0;
        }

        /// <summary>Presses and releases keys as the floater's own input.</summary>
        public static bool Send(params int[] keysDownThenUp)
        {
            // Every key goes down in order, then comes up in reverse.
            List<Native.INPUT> inputs = new List<Native.INPUT>();
            foreach (int vk in keysDownThenUp)
            {
                inputs.Add(Native.Key(vk, false, OwnInput));
            }
            for (int i = keysDownThenUp.Length - 1; i >= 0; i--)
            {
                inputs.Add(Native.Key(keysDownThenUp[i], true, OwnInput));
            }
            Native.INPUT[] all = inputs.ToArray();
            return Native.SendInput((uint)all.Length, all, Marshal.SizeOf(typeof(Native.INPUT))) == all.Length;
        }
    }

    /// <summary>
    /// Types dictated text where the cursor is: the text goes on the clipboard,
    /// Ctrl+V is pressed in the app being typed in, and the clipboard is put
    /// back. The text is marked to stay out of clipboard history, and
    /// clipboard contents a password manager marked private are not put back.
    /// </summary>
    internal static class Paster
    {
        private static readonly string[] Private =
        {
            "ExcludeClipboardContentFromMonitorProcessing", "Clipboard Viewer Ignore", "CanIncludeInClipboardHistory"
        };

        public static bool Paste(string text)
        {
            // A modifier still held would turn Ctrl+V into another shortcut.
            for (int i = 0; i < 75 && AnyModifierDown(); i++)
            {
                Thread.Sleep(20);
            }
            DataObject saved = null;
            bool forget = false;
            try
            {
                IDataObject old = Clipboard.GetDataObject();
                if (old != null)
                {
                    string[] formats = old.GetFormats(false);
                    foreach (string f in Private)
                    {
                        if (Array.IndexOf(formats, f) >= 0)
                        {
                            forget = true;
                        }
                    }
                    if (!forget && formats.Length > 0)
                    {
                        saved = new DataObject();
                        foreach (string f in formats)
                        {
                            try
                            {
                                object value = old.GetData(f, false);
                                if (value != null)
                                {
                                    saved.SetData(f, false, value);
                                }
                            }
                            catch (Exception)
                            {
                            }
                        }
                    }
                }
            }
            catch (ExternalException)
            {
            }

            DataObject data = new DataObject();
            data.SetData(DataFormats.UnicodeText, false, text);
            data.SetData("ExcludeClipboardContentFromMonitorProcessing", false, new MemoryStream(new byte[] { 1, 0, 0, 0 }));
            data.SetData("CanIncludeInClipboardHistory", false, new MemoryStream(new byte[4]));
            data.SetData("CanUploadToCloudClipboard", false, new MemoryStream(new byte[4]));
            try
            {
                Clipboard.SetDataObject(data, true, 5, 50);
            }
            catch (ExternalException)
            {
                return false;
            }
            uint ours = Native.GetClipboardSequenceNumber();
            // Clipboard listeners open the clipboard for a moment after each
            // change; an app pasting in that moment finds it busy and pastes
            // nothing (about one paste in eight without this wait).
            Thread.Sleep(150);
            for (int i = 0; i < 10 && Native.GetOpenClipboardWindow() != IntPtr.Zero; i++)
            {
                Thread.Sleep(25);
            }
            bool typed = Hotkeys.Send(Native.VK_CONTROL, 0x56);
            if (!typed)
            {
                // Left on the clipboard for a manual paste.
                return false;
            }
            System.Windows.Forms.Timer later = new System.Windows.Forms.Timer();
            later.Interval = 700;
            later.Tick += delegate
            {
                later.Stop();
                later.Dispose();
                // Something copied meanwhile is left alone.
                if (Native.GetClipboardSequenceNumber() != ours)
                {
                    return;
                }
                try
                {
                    if (saved != null)
                    {
                        Clipboard.SetDataObject(saved, true, 5, 50);
                    }
                    else
                    {
                        Clipboard.Clear();
                    }
                }
                catch (ExternalException)
                {
                }
            };
            later.Start();
            return true;
        }

        private static bool AnyModifierDown()
        {
            foreach (int vk in new[] { Native.VK_LSHIFT, Native.VK_RSHIFT, Native.VK_LCONTROL, Native.VK_RCONTROL,
                Native.VK_LMENU, Native.VK_RMENU, Native.VK_LWIN, Native.VK_RWIN })
            {
                if (Hotkeys.IsDown(vk))
                {
                    return true;
                }
            }
            return false;
        }
    }

    internal enum Mode
    {
        Idle,
        Starting,
        Recording,
        Busy
    }

    internal enum Purpose
    {
        Firstmate,
        Dictate
    }

    /// <summary>The floating control and everything it does; the Mac floater's FloaterModel and view in one.</summary>
    internal sealed class FloaterForm : Form
    {
        private const string Idle = "Hold to talk";
        private const string SavedRetrying = "Saved - retrying";

        private readonly string dir;
        private readonly FloaterConfig config;
        private readonly Mutex instance;
        private readonly Bridge bridge;
        private readonly Recorder recorder;
        private readonly string recordingDir;
        private readonly string pendingDir;
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private readonly ToolTip tip = new ToolTip();
        private readonly NotifyIcon tray = new NotifyIcon();
        private readonly System.Windows.Forms.Timer every = new System.Windows.Forms.Timer();

        // Capture state, as in the Mac floater.
        private Mode mode = Mode.Idle;
        private Purpose purpose = Purpose.Firstmate;
        private string status = Idle;
        private int statusGeneration;
        private bool latched;
        private bool fromHotkey;
        private double? pressStartedAt;
        private const double TapWindow = 0.3;
        private string recordPath;
        private string recordId;

        // Voice-out state.
        private bool muted;
        private int voiceVolume = VoiceVolume.Standard;
        private bool micBlocked;

        // Screenshots stack until the captain stops taking them, then go as one
        // message; a talk-to-Firstmate message recorded meanwhile takes them along.
        private readonly ShotStack stack = new ShotStack();
        private System.Windows.Forms.Timer shotTimer;
        private readonly List<string> heldRecordings = new List<string>();

        // Saved talk-to-Firstmate recordings waiting for an automatic retry, by
        // WSL path, with the attempts each has had.
        private readonly Dictionary<string, int> retrying = new Dictionary<string, int>();

        // Hotkeys.
        private readonly TalkKey talkKey = new TalkKey();
        private readonly TapKey dictateKey = TapKey.Dictate();
        private readonly TapKey shotKey = TapKey.Shot();

        // Self-update.
        private readonly HashSet<string> updateTried = new HashSet<string>();
        private double nextUpdateCheck;
        private double nextPendingPump;
        private double nextMuteRefresh;

        // Layout, in 96-dpi units scaled by `scale`.
        private float scale = 1;
        private static readonly RectangleF TalkBox = new RectangleF(8, 8, 48, 48);
        private static readonly RectangleF StopBox = new RectangleF(64, 8, 22, 22);
        private static readonly RectangleF RepeatBox = new RectangleF(90, 8, 22, 22);
        private static readonly RectangleF MuteBox = new RectangleF(64, 34, 22, 22);
        private static readonly RectangleF CameraBox = new RectangleF(90, 34, 22, 22);
        private static readonly RectangleF ArrowBox = new RectangleF(116, 20, 16, 24);
        private static readonly RectangleF StatusBox = new RectangleF(6, 60, 128, 18);
        private const float PlateWidth = 140, PlateHeight = 80;
        private string hover;
        private string pressed;
        private Point dragFrom;
        private bool dragging;

        public FloaterForm(string dir, FloaterConfig config, string testMicrophone, Mutex instance)
        {
            this.dir = dir;
            this.config = config;
            this.instance = instance;
            bridge = new Bridge(config, Log);
            recorder = new Recorder(testMicrophone);
            recordingDir = Path.Combine(dir, "recording");
            pendingDir = Path.Combine(dir, "pending");
            Directory.CreateDirectory(recordingDir);
            Directory.CreateDirectory(pendingDir);

            Text = "Starship floater";
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            StartPosition = FormStartPosition.Manual;
            BackColor = Color.FromArgb(28, 28, 32);
            DoubleBuffered = true;
            Opacity = 0.96;
            tip.ShowAlways = true;

            tray.Icon = MakeIcon();
            tray.Text = "Starship floater";
            tray.Visible = true;
            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add("Show or hide the floater", null, delegate { Visible = !Visible; });
            menu.Items.Add("Quit", null, delegate { Close(); });
            tray.ContextMenuStrip = menu;
            tray.MouseClick += delegate(object s, MouseEventArgs e)
            {
                if (e.Button == MouseButtons.Left)
                {
                    Visible = true;
                }
            };

            Log("started, version " + config.Version + (testMicrophone != null ? ", test microphone " + testMicrophone : ""));
            WaitForQuit();
        }

        // --- window ------------------------------------------------------------

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST;
                return cp;
            }
        }

        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        protected override void WndProc(ref Message m)
        {
            // Clicking the floater never takes the keyboard from the app being typed in.
            if (m.Msg == Native.WM_MOUSEACTIVATE)
            {
                m.Result = new IntPtr(Native.MA_NOACTIVATE);
                return;
            }
            if (m.Msg == Native.WM_DPICHANGED)
            {
                Rescale();
            }
            base.WndProc(ref m);
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            Rescale();
            Location = SavedLocation();
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            new Hotkeys(this, OnKey, OnClick).Start();
            recorder.Prepare();
            every.Interval = 1000;
            every.Tick += delegate { Tick(); };
            every.Start();
            CheckMicrophone();
            RecoverRecordings();
            nextUpdateCheck = Now() + 5;
            nextMuteRefresh = Now() + 1;
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            SaveLocation();
            recorder.Cancel();
            tray.Visible = false;
            base.OnFormClosing(e);
        }

        private void Rescale()
        {
            uint dpi = 96;
            try
            {
                dpi = Native.GetDpiForWindow(Handle);
            }
            catch (EntryPointNotFoundException)
            {
                using (Graphics g = CreateGraphics())
                {
                    dpi = (uint)g.DpiX;
                }
            }
            scale = (dpi == 0 ? 96 : dpi) / 96f;
            ClientSize = new Size((int)Math.Ceiling(PlateWidth * scale), (int)Math.Ceiling(PlateHeight * scale));
            using (GraphicsPath path = Rounded(new RectangleF(0, 0, ClientSize.Width, ClientSize.Height), 12 * scale))
            {
                Region = new Region(path);
            }
            Invalidate();
        }

        private void WaitForQuit()
        {
            EventWaitHandle quit = new EventWaitHandle(false, EventResetMode.AutoReset, Program.QuitName);
            Thread waiter = new Thread(delegate()
            {
                quit.WaitOne();
                if (IsHandleCreated)
                {
                    BeginInvoke(new Action(Close));
                }
            });
            waiter.IsBackground = true;
            waiter.Start();
        }

        private Point SavedLocation()
        {
            try
            {
                string[] xy = File.ReadAllText(Path.Combine(dir, "position.txt")).Trim().Split(',');
                Point p = new Point(int.Parse(xy[0], CultureInfo.InvariantCulture), int.Parse(xy[1], CultureInfo.InvariantCulture));
                foreach (Screen s in Screen.AllScreens)
                {
                    if (s.WorkingArea.Contains(p))
                    {
                        return p;
                    }
                }
            }
            catch (Exception)
            {
            }
            Rectangle area = Screen.PrimaryScreen.WorkingArea;
            return new Point(area.Right - Width - (int)(24 * scale), area.Bottom - Height - (int)(24 * scale));
        }

        private void SaveLocation()
        {
            try
            {
                File.WriteAllText(Path.Combine(dir, "position.txt"),
                    Location.X.ToString(CultureInfo.InvariantCulture) + "," + Location.Y.ToString(CultureInfo.InvariantCulture));
            }
            catch (Exception)
            {
            }
        }

        // --- drawing -----------------------------------------------------------

        private RectangleF Scaled(RectangleF r)
        {
            return new RectangleF(r.X * scale, r.Y * scale, r.Width * scale, r.Height * scale);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            using (GraphicsPath plate = Rounded(new RectangleF(0.5f, 0.5f, Width - 1, Height - 1), 12 * scale))
            using (Brush fill = new SolidBrush(Color.FromArgb(28, 28, 32)))
            using (Pen edge = new Pen(Color.FromArgb(70, 70, 78)))
            {
                g.FillPath(fill, plate);
                g.DrawPath(edge, plate);
            }

            Circle(g, TalkBox, TalkColor(), "talk");
            using (Font icons = IconFont(20))
            {
                Glyph(g, TalkBox, icons, "", "M");
            }
            if (micBlocked)
            {
                RectangleF badge = new RectangleF(TalkBox.Right - 14, TalkBox.Y - 2, 16, 16);
                Circle(g, badge, Color.FromArgb(230, 140, 40), null);
                using (Font f = new Font("Segoe UI", 8 * scale, FontStyle.Bold, GraphicsUnit.Pixel))
                {
                    Glyph(g, badge, f, "!", "!");
                }
            }

            using (Font icons = IconFont(11))
            {
                Circle(g, StopBox, Color.FromArgb(60, 60, 68), "stop");
                Glyph(g, StopBox, icons, "", "■");
                Circle(g, RepeatBox, Color.FromArgb(60, 60, 68), "repeat");
                Glyph(g, RepeatBox, icons, "", "↻");
                Circle(g, MuteBox, muted ? Color.FromArgb(225, 120, 40) : Color.FromArgb(60, 60, 68), "mute");
                Glyph(g, MuteBox, icons, muted ? "" : "", muted ? "x" : "♪");
                Circle(g, CameraBox, Color.FromArgb(60, 60, 68), "camera");
                Glyph(g, CameraBox, icons, "", "C");
                RectangleF arrow = Scaled(ArrowBox);
                if (hover == "arrow")
                {
                    using (Brush b = new SolidBrush(Color.FromArgb(55, 55, 62)))
                    {
                        g.FillRectangle(b, arrow);
                    }
                }
                Glyph(g, ArrowBox, icons, "", "v");
            }
            int count = stack.Count;
            if (count > 0)
            {
                RectangleF badge = new RectangleF(CameraBox.Right - 9, CameraBox.Y - 4, 13, 13);
                Circle(g, badge, Color.FromArgb(60, 130, 230), null);
                using (Font f = new Font("Segoe UI", 8 * scale, FontStyle.Bold, GraphicsUnit.Pixel))
                {
                    Glyph(g, badge, f, count.ToString(CultureInfo.InvariantCulture), "");
                }
            }

            using (Font f = new Font("Segoe UI", 10.5f * scale, GraphicsUnit.Pixel))
            using (Brush b = new SolidBrush(StatusColor()))
            using (StringFormat sf = new StringFormat())
            {
                sf.Alignment = StringAlignment.Center;
                sf.LineAlignment = StringAlignment.Center;
                sf.Trimming = StringTrimming.EllipsisCharacter;
                sf.FormatFlags = StringFormatFlags.NoWrap;
                g.DrawString(status, f, b, Scaled(StatusBox), sf);
            }
        }

        private Color TalkColor()
        {
            switch (mode)
            {
                case Mode.Starting: return Color.FromArgb(217, 140, 51);
                case Mode.Recording: return purpose == Purpose.Dictate ? Color.FromArgb(140, 80, 210) : Color.FromArgb(217, 51, 51);
                case Mode.Busy: return Color.FromArgb(110, 110, 120);
                default: return Color.FromArgb(45, 110, 220);
            }
        }

        private Color StatusColor()
        {
            if (status == SendOutcome.SavedForFirstmate || status.StartsWith("Saved", StringComparison.Ordinal)
                || status.StartsWith("Mic", StringComparison.Ordinal))
            {
                return Color.FromArgb(240, 160, 70);
            }
            return Color.FromArgb(215, 215, 222);
        }

        private void Circle(Graphics g, RectangleF box, Color color, string name)
        {
            RectangleF r = Scaled(box);
            if (name != null && hover == name)
            {
                color = ControlPaint.Light(color, 0.25f);
            }
            if (name != null && pressed == name)
            {
                color = ControlPaint.Dark(color, 0.1f);
            }
            using (Brush b = new SolidBrush(color))
            {
                g.FillEllipse(b, r);
            }
        }

        private void Glyph(Graphics g, RectangleF box, Font font, string glyph, string fallback)
        {
            string text = font.Name == "Segoe MDL2 Assets" || font.Name == "Segoe Fluent Icons" || fallback.Length == 0 ? glyph : fallback;
            using (StringFormat sf = new StringFormat())
            using (Brush b = new SolidBrush(Color.White))
            {
                sf.Alignment = StringAlignment.Center;
                sf.LineAlignment = StringAlignment.Center;
                g.DrawString(text, font, b, Scaled(box), sf);
            }
        }

        private Font IconFont(float size)
        {
            foreach (string name in new[] { "Segoe Fluent Icons", "Segoe MDL2 Assets" })
            {
                Font f = new Font(name, size * scale, GraphicsUnit.Pixel);
                if (f.Name == name)
                {
                    return f;
                }
                f.Dispose();
            }
            return new Font("Segoe UI", size * scale, FontStyle.Bold, GraphicsUnit.Pixel);
        }

        private static GraphicsPath Rounded(RectangleF r, float radius)
        {
            GraphicsPath path = new GraphicsPath();
            float d = radius * 2;
            path.AddArc(r.X, r.Y, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        private static Icon MakeIcon()
        {
            using (Bitmap bmp = new Bitmap(32, 32))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                using (Brush b = new SolidBrush(Color.FromArgb(45, 110, 220)))
                using (Brush w = new SolidBrush(Color.White))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.FillEllipse(b, 1, 1, 30, 30);
                    g.FillRectangle(w, 13, 7, 6, 12);
                    g.FillEllipse(w, 13, 4, 6, 6);
                    g.FillEllipse(w, 13, 16, 6, 6);
                    g.FillRectangle(w, 15, 21, 2, 6);
                }
                return Icon.FromHandle(bmp.GetHicon());
            }
        }

        // --- mouse -------------------------------------------------------------

        private string HitTest(Point p)
        {
            PointF q = new PointF(p.X / scale, p.Y / scale);
            if (micBlocked && new RectangleF(TalkBox.Right - 14, TalkBox.Y - 2, 16, 16).Contains(q)) return "badge";
            if (InCircle(TalkBox, q)) return "talk";
            if (InCircle(StopBox, q)) return "stop";
            if (InCircle(RepeatBox, q)) return "repeat";
            if (InCircle(MuteBox, q)) return "mute";
            if (InCircle(CameraBox, q)) return "camera";
            if (ArrowBox.Contains(q)) return "arrow";
            return null;
        }

        private static bool InCircle(RectangleF box, PointF q)
        {
            float cx = box.X + box.Width / 2, cy = box.Y + box.Height / 2, r = box.Width / 2;
            return (q.X - cx) * (q.X - cx) + (q.Y - cy) * (q.Y - cy) <= r * r;
        }

        private static readonly Dictionary<string, string> Tips = new Dictionary<string, string>
        {
            { "talk", "Talk to your first mate: hold, or click to start and click again to send. Right Alt held does the same." },
            { "badge", "Desktop apps may not use the microphone. Click to open the Windows setting." },
            { "stop", "Stop the reply being spoken" },
            { "repeat", "Speak the last reply again" },
            { "mute", "Voice on or off. Right-click for the voice volume." },
            { "camera", "Screenshot of the screen under the pointer, sent to your first mate. Right Shift tapped does the same." },
            { "arrow", "Recent spoken replies" },
        };

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (dragging)
            {
                Location = new Point(Location.X + e.X - dragFrom.X, Location.Y + e.Y - dragFrom.Y);
                return;
            }
            string now = HitTest(e.Location);
            if (now != hover)
            {
                hover = now;
                string text;
                tip.SetToolTip(this, now != null && Tips.TryGetValue(now, out text) ? text : "");
                Invalidate();
            }
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            hover = null;
            Invalidate();
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            string target = HitTest(e.Location);
            if (target == null)
            {
                if (e.Button == MouseButtons.Left)
                {
                    dragging = true;
                    dragFrom = e.Location;
                }
                return;
            }
            pressed = target;
            Invalidate();
            if (target == "talk" && e.Button == MouseButtons.Left)
            {
                PressBegan();
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (dragging)
            {
                dragging = false;
                SaveLocation();
                return;
            }
            string target = HitTest(e.Location);
            string was = pressed;
            pressed = null;
            Invalidate();
            if (was == "talk" && e.Button == MouseButtons.Left)
            {
                PressEnded();
                return;
            }
            if (target == null || target != was)
            {
                return;
            }
            if (e.Button == MouseButtons.Right)
            {
                if (target == "mute")
                {
                    ShowVolume();
                }
                return;
            }
            switch (target)
            {
                case "badge": OpenMicrophoneSettings(); break;
                case "stop": RunSpeak(new[] { "--stop" }, delegate(bool ok) { return ok ? "Stopped" : "Stop failed"; }); break;
                case "repeat": RepeatLast(); break;
                case "mute": ToggleMute(); break;
                case "camera": TakeShot(); break;
                case "arrow": ShowRecent(); break;
            }
        }

        // --- keys --------------------------------------------------------------

        private void OnKey(int vk, int scan, bool down, double at)
        {
            // AltGr sends a left Ctrl press of its own before Right Alt; it is not a key the captain pressed.
            if (vk == Native.VK_LCONTROL && scan == 0x21D)
            {
                return;
            }
            bool modifier = vk == Native.VK_LSHIFT || vk == Native.VK_RSHIFT || vk == Native.VK_LCONTROL
                || vk == Native.VK_RCONTROL || vk == Native.VK_LMENU || vk == Native.VK_RMENU
                || vk == Native.VK_LWIN || vk == Native.VK_RWIN;
            if (!modifier)
            {
                if (down)
                {
                    // A key while a hotkey is held makes it a shortcut, not a hotkey;
                    // Right Alt is one only in the first moment of its hold.
                    if (talkKey.Chord(at) == TalkAction.Drop)
                    {
                        HotkeyTalkChorded();
                    }
                    dictateKey.KeyPressed(at);
                    shotKey.KeyPressed(at);
                }
                return;
            }
            if (vk == Native.VK_RMENU)
            {
                switch (talkKey.Update(down, at))
                {
                    case TalkAction.Begin:
                        // A lone Alt press and release would open the focused
                        // app's menu bar; a key of no meaning in between stops that.
                        Hotkeys.Send(0xE8);
                        HotkeyTalkBegan();
                        break;
                    case TalkAction.Deliver:
                        HotkeyTalkEnded();
                        break;
                }
            }
            if (vk == Native.VK_RCONTROL)
            {
                if (down)
                {
                    dictateKey.Down(at, OthersDown(Native.VK_RCONTROL, false));
                }
                else if (dictateKey.Up(at))
                {
                    ToggleDictation();
                }
            }
            else
            {
                dictateKey.Chord();
            }
            if (vk == Native.VK_RSHIFT)
            {
                if (down)
                {
                    // Screenshots taken while Right Alt is held join that voice message.
                    shotKey.Down(at, OthersDown(Native.VK_RSHIFT, talkKey.IsDown));
                }
                else if (shotKey.Up(at))
                {
                    ShotTapped(at);
                }
            }
            else
            {
                shotKey.Chord();
            }
        }

        private static bool OthersDown(int self, bool talking)
        {
            foreach (int vk in new[] { Native.VK_LSHIFT, Native.VK_RSHIFT, Native.VK_LCONTROL, Native.VK_RCONTROL,
                Native.VK_LMENU, Native.VK_RMENU, Native.VK_LWIN, Native.VK_RWIN })
            {
                if (vk == self || (talking && (vk == Native.VK_RMENU || vk == Native.VK_LCONTROL)))
                {
                    continue;
                }
                if (Hotkeys.IsDown(vk))
                {
                    return true;
                }
            }
            return false;
        }

        private void OnClick(double at)
        {
            if (talkKey.Chord(at) == TalkAction.Drop)
            {
                HotkeyTalkChorded();
            }
            dictateKey.Chord();
            shotKey.Chord();
        }

        /// <summary>A Right Shift tap becomes a screenshot only once typing has not resumed right after it.</summary>
        private void ShotTapped(double tap)
        {
            After(shotKey.Settle, delegate
            {
                if (shotKey.TakeSettled(tap))
                {
                    TakeShot();
                }
            });
        }

        // --- talk to Firstmate (button and Right Alt) ---------------------------

        private void PressBegan()
        {
            if (mode == Mode.Idle)
            {
                Begin(Purpose.Firstmate);
                pressStartedAt = Now();
            }
            else if (mode == Mode.Recording && latched && purpose == Purpose.Firstmate && !fromHotkey)
            {
                StopAndDeliver();
            }
        }

        private void PressEnded()
        {
            if (purpose != Purpose.Firstmate || fromHotkey)
            {
                return;
            }
            bool quick = pressStartedAt.HasValue && Now() - pressStartedAt.Value < TapWindow;
            pressStartedAt = null;
            if (mode == Mode.Starting)
            {
                if (quick) latched = true; else CancelCapture();
            }
            else if (mode == Mode.Recording && !latched)
            {
                if (quick)
                {
                    latched = true;
                    SetStatus("Listening… (click to stop)");
                }
                else
                {
                    StopAndDeliver();
                }
            }
        }

        private void HotkeyTalkBegan()
        {
            if (mode != Mode.Idle)
            {
                return;
            }
            Begin(Purpose.Firstmate);
            fromHotkey = true;
            pressStartedAt = Now();
        }

        private void HotkeyTalkEnded()
        {
            if (!fromHotkey)
            {
                return;
            }
            bool quick = !pressStartedAt.HasValue || Now() - pressStartedAt.Value < TapWindow;
            if (mode == Mode.Starting)
            {
                CancelCapture();
            }
            else if (mode == Mode.Recording)
            {
                // A brush of the key is not a message: nothing is sent for it.
                if (quick) CancelCapture(); else StopAndDeliver();
            }
        }

        private void HotkeyTalkChorded()
        {
            if (fromHotkey && (mode == Mode.Starting || mode == Mode.Recording))
            {
                CancelCapture();
            }
        }

        // --- dictation (a tap of Right Ctrl) -----------------------------------

        private void ToggleDictation()
        {
            if (mode == Mode.Idle)
            {
                Begin(Purpose.Dictate);
                latched = true;
            }
            else if (purpose == Purpose.Dictate && mode == Mode.Starting)
            {
                CancelCapture();
            }
            else if (purpose == Purpose.Dictate && mode == Mode.Recording)
            {
                StopAndDeliver();
            }
        }

        // --- capture -----------------------------------------------------------

        private void Begin(Purpose p)
        {
            purpose = p;
            mode = Mode.Starting;
            latched = false;
            fromHotkey = false;
            pressStartedAt = null;
            SetStatus("Starting…");
            if (!recorder.HasDevice)
            {
                Finish("No microphone");
                return;
            }
            recordId = Guid.NewGuid().ToString("N");
            recordPath = Path.Combine(recordingDir, RecordingName.Make(recordId, PurposeName(p)));
            string error;
            if (!recorder.Start(out error))
            {
                Log("record: " + error);
                recordPath = null;
                Finish(micBlocked ? "Mic off - click !" : "Mic error");
                return;
            }
            mode = Mode.Recording;
            SetStatus(purpose == Purpose.Dictate ? "Dictating… tap to end" : (latched ? "Listening… (click to stop)" : "Listening…"));
        }

        private void CancelCapture()
        {
            latched = false;
            fromHotkey = false;
            pressStartedAt = null;
            recorder.Cancel();
            recorder.Prepare();
            TryDelete(recordPath);
            recordPath = null;
            mode = Mode.Idle;
            purpose = Purpose.Firstmate;
            SetStatus(IdleStatus());
        }

        private void StopAndDeliver()
        {
            Purpose p = purpose;
            if (p == Purpose.Firstmate)
            {
                stack.TalkEnded(Now());
            }
            latched = false;
            fromHotkey = false;
            pressStartedAt = null;
            string path = recordPath;
            string id = recordId;
            recordPath = null;
            mode = Mode.Busy;
            SetStatus("Transcribing…");
            // The last words are still arriving as the key comes up; the capture
            // keeps recording for a moment before the file is closed.
            After(0.4, delegate
            {
                string error;
                bool saved = recorder.Finish(path, out error);
                recorder.Prepare();
                if (!saved)
                {
                    Log("record: " + error);
                    TryDelete(path);
                    Finish("Record error");
                    return;
                }
                TranscribeAndDeliver(path, id, p);
            });
        }

        private void TranscribeAndDeliver(string path, string id, Purpose p)
        {
            Work(delegate
            {
                return bridge.Run(new[] { "bridge", "transcribe", id, PurposeName(p) }, ReadAll(path), 20 * 60);
            }, delegate(string output)
            {
                BridgeLine line = BridgeLine.First(output, "text", "saved", "nothing", "known");
                if (line == null)
                {
                    // Ubuntu could not take it: the recording waits here and is
                    // handed over as soon as Ubuntu answers again.
                    MoveToPending(path);
                    Finish(p == Purpose.Firstmate ? SavedRetrying : "Saved, not sent", 6);
                    return;
                }
                TryDelete(path);
                Log("transcribe: " + line.Kind);
                switch (line.Kind)
                {
                    case "known":
                        Finish(IdleStatus());
                        break;
                    case "nothing":
                        Finish(line.Field(0) == "transcribe-failed" ? "Transcribe failed" : "No speech");
                        break;
                    case "saved":
                        if (p == Purpose.Firstmate)
                        {
                            Finish(SavedRetrying, 6);
                            ScheduleRetry(line.Field(0), 1, null);
                        }
                        else
                        {
                            Finish("Saved, not sent", 6);
                        }
                        break;
                    case "text":
                        if (p == Purpose.Dictate)
                        {
                            Dictated(line.Field(1));
                        }
                        else
                        {
                            VoiceTranscribed(line.Field(1), line.Field(0));
                        }
                        break;
                }
            });
        }

        /// <summary>
        /// Dictated words: sent when the Firstmate chat is what the captain is
        /// typing in (only a terminal can be showing it), pasted anywhere else.
        /// </summary>
        private void Dictated(string text)
        {
            string front = Native.ForegroundProcessName();
            if (!Terminals.IsTerminal(front))
            {
                PasteDictation(text);
                return;
            }
            Work(delegate
            {
                return bridge.Run(new[] { "bridge", "dictate" }, Encoding.UTF8.GetBytes(text), 120);
            }, delegate(string output)
            {
                BridgeLine line = BridgeLine.First(output, "sent:", "sent-unconfirmed:", "mailbox:", "not-in-front", "failed");
                string sent = line != null && line.Field(0) != null ? SendOutcome.Status(line.Field(0)) : null;
                Log("dictate: " + (line == null ? "no answer" : line.Kind));
                if (sent != null)
                {
                    Finish(sent);
                }
                else
                {
                    PasteDictation(text);
                }
            });
        }

        private void PasteDictation(string text)
        {
            bool typed = Paster.Paste(text);
            Finish(typed ? "Typed" : "Copied - press Ctrl+V");
        }

        // --- screenshots -------------------------------------------------------

        private void TakeShot()
        {
            stack.ShotStarted(Now());
            ShotsChanged();
            Work(delegate
            {
                byte[] png = CaptureUnderPointer();
                if (png == null)
                {
                    return null;
                }
                string output = bridge.Run(new[] { "bridge", "shot" }, png, 60);
                if (output == null)
                {
                    return null;
                }
                foreach (string raw in output.Replace("\r", "").Split('\n'))
                {
                    if (raw.StartsWith("/", StringComparison.Ordinal) && raw.EndsWith(".png", StringComparison.Ordinal))
                    {
                        return raw;
                    }
                }
                return null;
            }, delegate(string path)
            {
                stack.ShotFinished(path, Now());
                ShotsChanged();
                if (path == null)
                {
                    Flash("Shot failed");
                }
                ScheduleFlush();
            });
        }

        private static byte[] CaptureUnderPointer()
        {
            try
            {
                Rectangle b = Screen.FromPoint(Cursor.Position).Bounds;
                using (Bitmap bmp = new Bitmap(b.Width, b.Height, PixelFormat.Format32bppArgb))
                {
                    using (Graphics g = Graphics.FromImage(bmp))
                    {
                        g.CopyFromScreen(b.Location, Point.Empty, b.Size);
                    }
                    using (MemoryStream ms = new MemoryStream())
                    {
                        bmp.Save(ms, ImageFormat.Png);
                        return ms.ToArray();
                    }
                }
            }
            catch (Exception)
            {
                return null;
            }
        }

        private bool VoiceInProgress
        {
            get { return purpose == Purpose.Firstmate && mode != Mode.Idle; }
        }

        private void ShotsChanged()
        {
            if (mode == Mode.Idle)
            {
                SetStatus(IdleStatus());
            }
            Invalidate();
        }

        private void ScheduleFlush()
        {
            if (shotTimer != null)
            {
                shotTimer.Stop();
                shotTimer.Dispose();
            }
            double delay = Math.Max(0.1, stack.DueAt - Now());
            shotTimer = After(delay, FlushShots);
        }

        private void FlushShots()
        {
            shotTimer = null;
            if (stack.IsEmpty)
            {
                return;
            }
            if (VoiceInProgress || !stack.Ready(Now()))
            {
                // A capture is still being written, the stack is waiting for a
                // voice message, or the window has not passed: look again shortly.
                shotTimer = After(0.5, FlushShots);
                return;
            }
            List<string> images;
            string text = stack.Take(out images);
            List<string> recordings = new List<string>(heldRecordings);
            heldRecordings.Clear();
            ShotsChanged();
            if (mode == Mode.Idle)
            {
                SetStatus(text != null ? "Delivering…" : (images.Count == 1 ? "Sending 1 shot…" : "Sending " + images.Count + " shots…"));
            }
            Deliver(text, images, recordings, false);
        }

        /// <summary>
        /// A transcribed talk-to-Firstmate message: sent at once when nothing is
        /// stacked, otherwise held until the stack window closes and sent with
        /// the shots. The floater is free meanwhile, so another talk joins it.
        /// </summary>
        private void VoiceTranscribed(string text, string recording)
        {
            if (!stack.Hold(text))
            {
                SetStatus("Delivering…");
                Deliver(text, new List<string>(), new List<string> { recording }, true);
                return;
            }
            heldRecordings.Add(recording);
            mode = Mode.Idle;
            purpose = Purpose.Firstmate;
            SetStatus(IdleStatus());
            ScheduleFlush();
        }

        /// <summary>
        /// Sends one message through bin/fm-desk-voice.sh send; the recordings
        /// it came from are removed once its words are delivered, and kept to
        /// be tried again when they were not.
        /// </summary>
        private void Deliver(string text, List<string> images, List<string> recordings, bool finishing)
        {
            List<string> args = new List<string> { "bridge", "deliver" };
            foreach (string r in recordings)
            {
                args.Add("--recording");
                args.Add(r);
            }
            foreach (string i in images)
            {
                args.Add("--image");
                args.Add(i);
            }
            Work(delegate
            {
                return bridge.Run(args.ToArray(), Encoding.UTF8.GetBytes(text ?? ""), 5 * 60);
            }, delegate(string output)
            {
                List<BridgeLine> lines = BridgeLine.Parse(output, "sent:", "sent-unconfirmed:", "mailbox:", "saved", "failed");
                string message = null;
                bool saved = false;
                foreach (BridgeLine line in lines)
                {
                    if (line.Kind == "saved")
                    {
                        saved = true;
                        ScheduleRetry(line.Field(0), 1, null);
                    }
                    else if (line.Kind != "failed" && message == null)
                    {
                        message = SendOutcome.Status(line.Field(0));
                    }
                }
                Log("deliver: " + (message ?? (saved ? "saved" : "failed")));
                if (message == null)
                {
                    message = saved ? SavedRetrying : "Deliver failed";
                }
                if (finishing) Finish(message, saved ? 6 : (double?)null); else Flash(message, saved ? 6 : (double?)null);
            });
        }

        // --- recordings kept until delivered -----------------------------------

        private void ScheduleRetry(string path, int attempts, double? wait)
        {
            if (string.IsNullOrEmpty(path))
            {
                return;
            }
            double? delay = wait ?? RetryPlan.DelayAfter(attempts);
            if (!delay.HasValue)
            {
                retrying.Remove(path);
                if (mode == Mode.Idle) SetStatus(IdleStatus());
                Flash("Saved, not sent", 6);
                return;
            }
            retrying[path] = attempts;
            if (mode == Mode.Idle) SetStatus(IdleStatus());
            After(delay.Value, delegate { Retry(path); });
        }

        private void Retry(string path)
        {
            int attempts;
            if (!retrying.TryGetValue(path, out attempts))
            {
                attempts = 1;
            }
            Work(delegate
            {
                string output = bridge.Run(new[] { "bridge", "retry", path }, null, 20 * 60);
                if (output == null)
                {
                    return null;
                }
                foreach (string raw in output.Replace("\r", "").Split('\n'))
                {
                    RetryResult r = RetryResult.Parse(raw);
                    if (r != null)
                    {
                        return r;
                    }
                }
                return null;
            }, delegate(RetryResult r)
            {
                Log("retry: " + (r == null ? "no answer" : r.Kind.ToString()));
                if (r == null)
                {
                    ScheduleRetry(path, attempts + 1, null);
                    return;
                }
                switch (r.Kind)
                {
                    case RetryKind.Delivered:
                        Retried(path, r.Status);
                        break;
                    case RetryKind.Unsent:
                        ScheduleRetry(path, r.Attempts, null);
                        break;
                    case RetryKind.Busy:
                        ScheduleRetry(path, attempts, RetryPlan.BusyDelay);
                        break;
                    case RetryKind.Gone:
                        Retried(path, null);
                        break;
                }
            });
        }

        private void Retried(string path, string message)
        {
            retrying.Remove(path);
            if (mode == Mode.Idle) SetStatus(IdleStatus());
            if (message != null) Flash(message, 6);
        }

        /// <summary>
        /// At launch: recordings a stopped floater left behind wait to be handed
        /// over, Ubuntu saves those it holds, and the automatic retries of saved
        /// talk-to-Firstmate recordings resume.
        /// </summary>
        private void RecoverRecordings()
        {
            foreach (string file in Directory.GetFiles(recordingDir, "*.wav"))
            {
                if ((DateTime.Now - File.GetLastWriteTime(file)).TotalSeconds >= 10)
                {
                    MoveToPending(file);
                }
            }
            PumpPending();
            Work(delegate
            {
                return bridge.Run(new[] { "bridge", "recover" }, null, 120);
            }, delegate(string output)
            {
                foreach (BridgeLine line in BridgeLine.Parse(output, "retry"))
                {
                    int attempts;
                    if (int.TryParse(line.Field(1), NumberStyles.None, CultureInfo.InvariantCulture, out attempts)
                        && RetryPlan.DelayAfter(attempts).HasValue && !retrying.ContainsKey(line.Field(0)))
                    {
                        ScheduleRetry(line.Field(0), attempts, null);
                    }
                }
            });
        }

        private void MoveToPending(string path)
        {
            try
            {
                string dest = Path.Combine(pendingDir, Path.GetFileName(path));
                if (File.Exists(dest)) File.Delete(dest);
                File.Move(path, dest);
            }
            catch (Exception e)
            {
                Log("pending: " + e.Message);
            }
        }

        private bool pumping;

        /// <summary>Hands recordings Ubuntu could not take when they were made over to it, to be kept and retried there.</summary>
        private void PumpPending()
        {
            string[] files = Directory.GetFiles(pendingDir, "*.wav");
            if (pumping || files.Length == 0)
            {
                return;
            }
            pumping = true;
            Work(delegate
            {
                List<string> saved = new List<string>();
                foreach (string file in files)
                {
                    string id, p;
                    if (!RecordingName.Split(Path.GetFileName(file), out id, out p))
                    {
                        continue;
                    }
                    string output = bridge.Run(new[] { "bridge", "adopt", id, p }, ReadAll(file), 120);
                    BridgeLine line = BridgeLine.First(output, "saved", "known");
                    if (line == null)
                    {
                        break;
                    }
                    TryDelete(file);
                    if (line.Kind == "saved" && p == "firstmate")
                    {
                        saved.Add(line.Field(0));
                    }
                }
                return saved;
            }, delegate(List<string> saved)
            {
                pumping = false;
                foreach (string path in saved)
                {
                    ScheduleRetry(path, 1, null);
                }
                if (mode == Mode.Idle) SetStatus(IdleStatus());
            });
        }

        // --- voice-out controls ------------------------------------------------

        private void RepeatLast()
        {
            if (muted)
            {
                if (mode == Mode.Idle) Finish("Voice muted");
                return;
            }
            RunSpeak(new[] { "--repeat" }, delegate(bool ok) { return ok ? "Repeating" : "Nothing to repeat"; });
        }

        private void ToggleMute()
        {
            bool was = muted;
            muted = !muted;
            Invalidate();
            RunSpeak(new[] { was ? "--unmute" : "--mute" }, delegate(bool ok)
            {
                return ok ? (was ? "Voice on" : "Voice muted") : "Mute failed";
            });
        }

        private void RunSpeak(string[] args, Func<bool, string> message)
        {
            List<string> all = new List<string> { "bridge", "speak" };
            all.AddRange(args);
            Work(delegate
            {
                return bridge.Run(all.ToArray(), null, 60) != null;
            }, delegate(bool ok)
            {
                if (mode == Mode.Idle)
                {
                    Finish(message(ok));
                }
                RefreshMute();
            });
        }

        private void RefreshMute()
        {
            Work(delegate
            {
                return bridge.Run(new[] { "bridge", "speak", "--muted" }, null, 60);
            }, delegate(string output)
            {
                if (output != null)
                {
                    bool now = output.Trim() == "muted";
                    if (now != muted)
                    {
                        muted = now;
                        Invalidate();
                    }
                }
            });
        }

        private void ShowRecent()
        {
            Work(delegate
            {
                return RecentReply.Parse(bridge.Run(new[] { "bridge", "speak", "--history" }, null, 60));
            }, delegate(List<RecentReply> replies)
            {
                ContextMenuStrip list = new ContextMenuStrip();
                list.ShowItemToolTips = true;
                if (replies.Count == 0)
                {
                    list.Items.Add("No spoken replies yet").Enabled = false;
                }
                foreach (RecentReply reply in replies)
                {
                    RecentReply chosen = reply;
                    string head = reply.Text.Length > 60 ? reply.Text.Substring(0, 60) + "…" : reply.Text;
                    ToolStripItem item = list.Items.Add(reply.Time.ToString("HH:mm", CultureInfo.CurrentCulture) + "   " + head);
                    item.ToolTipText = reply.Text;
                    item.Click += delegate
                    {
                        if (muted)
                        {
                            if (mode == Mode.Idle) Finish("Voice muted");
                            return;
                        }
                        RunSpeak(new[] { "--replay", chosen.Number.ToString(CultureInfo.InvariantCulture) },
                            delegate(bool ok) { return ok ? "Replaying" : "No longer kept"; });
                    };
                }
                list.Closed += delegate { list.Dispose(); };
                list.Show(this, new Point(0, Height));
            });
        }

        private void ShowVolume()
        {
            Work(delegate
            {
                return VoiceVolume.Parse(bridge.Run(new[] { "bridge", "speak", "--volume" }, null, 60));
            }, delegate(int? level)
            {
                if (level.HasValue) voiceVolume = level.Value;
                TrackBar bar = new TrackBar();
                bar.Minimum = 0;
                bar.Maximum = VoiceVolume.Max;
                bar.TickFrequency = 10;
                bar.SmallChange = 5;
                bar.LargeChange = 10;
                bar.Value = VoiceVolume.Clamp(voiceVolume);
                bar.Width = (int)(160 * scale);
                Label label = new Label();
                label.AutoSize = true;
                label.Text = "Voice " + bar.Value + "%";
                Button reset = new Button();
                reset.Text = "Reset";
                reset.AutoSize = true;
                FlowLayoutPanel panel = new FlowLayoutPanel();
                panel.AutoSize = true;
                panel.FlowDirection = FlowDirection.TopDown;
                panel.Controls.Add(label);
                panel.Controls.Add(bar);
                panel.Controls.Add(reset);
                ToolStripDropDown drop = new ToolStripDropDown();
                drop.Items.Add(new ToolStripControlHost(panel));
                bar.ValueChanged += delegate { label.Text = "Voice " + bar.Value + "%"; };
                bar.MouseUp += delegate { SetVoiceVolume(bar.Value); };
                bar.KeyUp += delegate { SetVoiceVolume(bar.Value); };
                reset.Click += delegate
                {
                    bar.Value = VoiceVolume.Standard;
                    SetVoiceVolume(VoiceVolume.Standard);
                };
                drop.Closed += delegate { drop.Dispose(); };
                drop.Show(this, new Point(0, Height));
            });
        }

        private void SetVoiceVolume(int level)
        {
            level = VoiceVolume.Clamp(level);
            if (level == voiceVolume)
            {
                return;
            }
            voiceVolume = level;
            RunSpeak(new[] { "--volume", level.ToString(CultureInfo.InvariantCulture) },
                delegate(bool ok) { return ok ? "Voice at " + level + "%" : "Volume not saved"; });
        }

        // --- microphone permission ---------------------------------------------

        /// <summary>
        /// Windows can keep desktop apps off the microphone (Settings, Privacy,
        /// Microphone); the talk button then shows an orange badge.
        /// </summary>
        private void CheckMicrophone()
        {
            bool blocked = Denied(Registry.CurrentUser, "") || Denied(Registry.LocalMachine, "")
                || Denied(Registry.CurrentUser, "\\NonPackaged");
            if (blocked != micBlocked)
            {
                micBlocked = blocked;
                if (mode == Mode.Idle) SetStatus(IdleStatus());
                Invalidate();
            }
        }

        private static bool Denied(RegistryKey root, string sub)
        {
            try
            {
                using (RegistryKey key = root.OpenSubKey(
                    "Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone" + sub))
                {
                    return key != null && string.Equals(key.GetValue("Value") as string, "Deny", StringComparison.OrdinalIgnoreCase);
                }
            }
            catch (Exception)
            {
                return false;
            }
        }

        private static void OpenMicrophoneSettings()
        {
            try
            {
                Process.Start("ms-settings:privacy-microphone");
            }
            catch (Exception)
            {
            }
        }

        // --- once a second -----------------------------------------------------

        private void Tick()
        {
            double now = Now();
            if (now >= nextMuteRefresh)
            {
                nextMuteRefresh = now + 10;
                RefreshMute();
                CheckMicrophone();
            }
            if (now >= nextPendingPump)
            {
                nextPendingPump = now + 60;
                PumpPending();
            }
            if (now >= nextUpdateCheck)
            {
                nextUpdateCheck = now + 3600;
                CheckForUpdate();
            }
        }

        /// <summary>
        /// Checks in with Ubuntu (bin/fm-desk-floater-windows.sh bridge hello)
        /// and, when Starship's copy of the floater's sources has changed (after
        /// a git pull), rebuilds and restarts once nothing is being recorded or sent.
        /// </summary>
        private void CheckForUpdate()
        {
            Work(delegate
            {
                BridgeLine line = BridgeLine.First(bridge.Run(new[] { "bridge", "hello" }, null, 60), "version");
                return line == null ? null : line.Field(0);
            }, delegate(string version)
            {
                if (string.IsNullOrEmpty(version) || version == config.Version || updateTried.Contains(version))
                {
                    return;
                }
                if (mode != Mode.Idle || !stack.IsEmpty || pumping)
                {
                    nextUpdateCheck = Now() + 30;
                    return;
                }
                updateTried.Add(version);
                Log("updating to " + version);
                Flash("Updating…", 10);
                Work(delegate
                {
                    return bridge.Run(new[] { "install", "--no-start" }, null, 5 * 60) != null;
                }, delegate(bool ok)
                {
                    if (!ok)
                    {
                        Flash("Update failed", 6);
                        return;
                    }
                    Restart();
                });
            });
        }

        private void Restart()
        {
            SaveLocation();
            recorder.Cancel();
            tray.Visible = false;
            instance.ReleaseMutex();
            Process.Start(Path.Combine(dir, "StarshipFloater.exe"));
            Application.Exit();
        }

        // --- helpers -----------------------------------------------------------

        private string IdleStatus()
        {
            if (stack.Transcript != null) return "Adding shots…";
            int count = stack.Count;
            if (count > 0) return count == 1 ? "1 shot stacked" : count + " shots stacked";
            if (retrying.Count > 0 || Directory.GetFiles(pendingDir, "*.wav").Length > 0) return SavedRetrying;
            if (micBlocked) return "Mic off - click !";
            return Idle;
        }

        private void SetStatus(string text)
        {
            status = text;
            statusGeneration++;
            Invalidate();
        }

        private void Finish(string text)
        {
            Finish(text, null);
        }

        private void Finish(string text, double? seconds)
        {
            mode = Mode.Idle;
            purpose = Purpose.Firstmate;
            Flash(text, seconds);
        }

        /// <summary>Shows a short outcome while nothing is being captured; a message saved rather than sent stays up longer.</summary>
        private void Flash(string text, double? seconds = null)
        {
            if (mode != Mode.Idle)
            {
                return;
            }
            SetStatus(text);
            int generation = statusGeneration;
            double shown = seconds ?? (text == SendOutcome.SavedForFirstmate ? 6 : 2);
            After(shown, delegate
            {
                if (mode == Mode.Idle && statusGeneration == generation)
                {
                    SetStatus(IdleStatus());
                }
            });
        }

        private double Now()
        {
            return clock.Elapsed.TotalSeconds;
        }

        private System.Windows.Forms.Timer After(double seconds, Action action)
        {
            System.Windows.Forms.Timer t = new System.Windows.Forms.Timer();
            t.Interval = Math.Max(1, (int)(seconds * 1000));
            t.Tick += delegate
            {
                t.Stop();
                t.Dispose();
                action();
            };
            t.Start();
            return t;
        }

        /// <summary>Runs <paramref name="work"/> off the form's thread and <paramref name="done"/> back on it.</summary>
        private void Work<T>(Func<T> work, Action<T> done)
        {
            ThreadPool.QueueUserWorkItem(delegate
            {
                T result = default(T);
                try
                {
                    result = work();
                }
                catch (Exception e)
                {
                    Log("work: " + e.Message);
                }
                if (IsHandleCreated)
                {
                    BeginInvoke(done, result);
                }
            });
        }

        private static string PurposeName(Purpose p)
        {
            return p == Purpose.Dictate ? "dictate" : "firstmate";
        }

        private static byte[] ReadAll(string path)
        {
            try
            {
                return File.ReadAllBytes(path);
            }
            catch (Exception)
            {
                return null;
            }
        }

        private static void TryDelete(string path)
        {
            if (path == null)
            {
                return;
            }
            try
            {
                File.Delete(path);
            }
            catch (Exception)
            {
            }
        }

        private readonly object logLock = new object();

        /// <summary>A short local log of what the floater did, never the words: floater.log beside it.</summary>
        private void Log(string line)
        {
            lock (logLock)
            {
                try
                {
                    string path = Path.Combine(dir, "floater.log");
                    FileInfo info = new FileInfo(path);
                    if (info.Exists && info.Length > 1000000)
                    {
                        File.Delete(path + ".1");
                        File.Move(path, path + ".1");
                    }
                    File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + " " + line + "\r\n");
                }
                catch (Exception)
                {
                }
            }
        }
    }

    internal static class Native
    {
        public const int WH_KEYBOARD_LL = 13;
        public const int WH_MOUSE_LL = 14;
        public const int WM_KEYDOWN = 0x100, WM_KEYUP = 0x101, WM_SYSKEYDOWN = 0x104, WM_SYSKEYUP = 0x105;
        public const int WM_LBUTTONDOWN = 0x201, WM_RBUTTONDOWN = 0x204, WM_MBUTTONDOWN = 0x207;
        public const int WM_MOUSEACTIVATE = 0x21, MA_NOACTIVATE = 3, WM_DPICHANGED = 0x2E0;
        public const int WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x80, WS_EX_TOPMOST = 0x8;
        public const int VK_CONTROL = 0x11;
        public const int VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1, VK_LCONTROL = 0xA2, VK_RCONTROL = 0xA3;
        public const int VK_LMENU = 0xA4, VK_RMENU = 0xA5, VK_LWIN = 0x5B, VK_RWIN = 0x5C;

        public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct KBDLLHOOKSTRUCT
        {
            public uint vkCode;
            public uint scanCode;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MSLLHOOKSTRUCT
        {
            public int x;
            public int y;
            public uint mouseData;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MSG
        {
            public IntPtr hwnd;
            public uint message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public int x;
            public int y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct KEYBDINPUT
        {
            public ushort wVk;
            public ushort wScan;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        // The union's largest member (MOUSEINPUT) sets INPUT's size.
        [StructLayout(LayoutKind.Sequential)]
        public struct MOUSEINPUT
        {
            public int dx;
            public int dy;
            public uint mouseData;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Explicit)]
        public struct INPUTUNION
        {
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public KEYBDINPUT ki;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct INPUT
        {
            public uint type;
            public INPUTUNION u;
        }

        public static INPUT Key(int vk, bool up, IntPtr extra)
        {
            INPUT input = new INPUT();
            input.type = 1;
            input.u.ki.wVk = (ushort)vk;
            input.u.ki.dwFlags = up ? 2u : 0u;
            input.u.ki.dwExtraInfo = extra;
            return input;
        }

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SetWindowsHookEx(int idHook, HookProc proc, IntPtr hMod, uint threadId);

        [DllImport("user32.dll")]
        public static extern IntPtr CallNextHookEx(IntPtr hhk, int code, IntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr GetModuleHandle(string name);

        [DllImport("user32.dll")]
        public static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);

        [DllImport("user32.dll")]
        public static extern bool TranslateMessage(ref MSG msg);

        [DllImport("user32.dll")]
        public static extern IntPtr DispatchMessage(ref MSG msg);

        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int vk);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint SendInput(uint count, INPUT[] inputs, int size);

        [DllImport("user32.dll")]
        public static extern uint GetClipboardSequenceNumber();

        [DllImport("user32.dll")]
        public static extern IntPtr GetOpenClipboardWindow();

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

        [DllImport("user32.dll")]
        public static extern uint GetDpiForWindow(IntPtr hwnd);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr context);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
        public static extern int mciSendString(string command, StringBuilder ret, int length, IntPtr callback);

        [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
        public static extern bool mciGetErrorString(int error, StringBuilder text, int length);

        [DllImport("winmm.dll")]
        public static extern uint waveInGetNumDevs();

        /// <summary>
        /// Per-monitor DPI awareness, so screenshots are taken at every
        /// display's own resolution and the floater stays sharp.
        /// </summary>
        public static void MakeDpiAware()
        {
            try
            {
                if (SetProcessDpiAwarenessContext(new IntPtr(-4)))
                {
                    return;
                }
            }
            catch (EntryPointNotFoundException)
            {
            }
            try
            {
                SetProcessDPIAware();
            }
            catch (EntryPointNotFoundException)
            {
            }
        }

        public static string ForegroundProcessName()
        {
            try
            {
                uint pid;
                GetWindowThreadProcessId(GetForegroundWindow(), out pid);
                using (Process p = Process.GetProcessById((int)pid))
                {
                    return p.ProcessName;
                }
            }
            catch (Exception)
            {
                return null;
            }
        }
    }
}
