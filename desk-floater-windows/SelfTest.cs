// Checks of the Windows floater's decisions in Logic.cs. Built as a console
// program next to Logic.cs alone (tests/fm-desk-floater-windows.test.sh does
// it with the .NET Framework compiler on Windows), it prints one line per
// failed check and exits 1 when any failed.
using System;
using System.Collections.Generic;

namespace StarshipFloater
{
    public static class SelfTest
    {
        private static int failures;
        private static int checks;

        private static void Check(bool ok, string what)
        {
            checks++;
            if (!ok)
            {
                failures++;
                Console.WriteLine("FAIL: " + what);
            }
        }

        private static void Equal<T>(T want, T got, string what)
        {
            Check(EqualityComparer<T>.Default.Equals(want, got), what + ": want <" + want + "> got <" + got + ">");
        }

        public static int Main()
        {
            TapKeys();
            TalkKeys();
            Stack();
            Retries();
            Outcomes();
            Lines();
            History();
            Volumes();
            Names();
            CommandLines();
            Config();
            Console.WriteLine(failures == 0
                ? "ok: " + checks + " checks"
                : failures + " of " + checks + " checks failed");
            return failures == 0 ? 0 : 1;
        }

        private static void TapKeys()
        {
            TapKey k = TapKey.Dictate();
            k.Down(10, false);
            Check(k.Up(10.2), "a quick lone tap counts");
            k.Down(20, false);
            Check(!k.Up(20.6), "a press held past the limit is an ordinary press");
            k.Down(30, false);
            k.Down(30.1, false);
            k.Down(30.2, false);
            Check(k.Up(30.3), "Windows' repeated down events of a held key do not restart or spoil the tap");
            k.Down(40, false);
            k.KeyPressed(40.1);
            Check(!k.Up(40.2), "a key pressed while it is down makes a shortcut");
            k.Down(50, false);
            k.Chord();
            Check(!k.Up(50.2), "a click or modifier while it is down makes a shortcut");
            k.Down(60, true);
            Check(!k.Up(60.1), "pressed with another modifier held is a shortcut");
            k.Chord();
            k.Down(70, false);
            Check(k.Up(70.1), "a click while it is up spoils nothing");
            Check(!k.Up(70.2), "an up without a down is not a tap");

            TapKey s = TapKey.Shot();
            s.KeyPressed(100);
            s.Down(101, false);
            Check(!s.Up(101.1), "a Shift tap within 1.5 s of typing is typing");
            s.Down(110, false);
            Check(s.Up(110.1), "a Shift tap away from typing is a tap");
            Check(s.TakeSettled(110.1), "a tap with no key after it settles");
            Check(!s.TakeSettled(110.1), "a settled tap is taken once");
            s.Down(120, false);
            Check(s.Up(120.1), "tap before typing resumes");
            s.KeyPressed(120.3);
            Check(!s.TakeSettled(120.1), "a key within the settle time cancels the tap");
            s.Down(130, false);
            Check(s.Up(130.1), "first of two taps");
            s.Down(130.3, false);
            Check(s.Up(130.35), "a second tap within the settle time is a tap too");
            Check(!s.TakeSettled(130.1), "a later tap replaces the first, so two taps take one shot");
            Check(s.TakeSettled(130.35), "the later tap stands");
        }

        private static void TalkKeys()
        {
            TalkKey t = new TalkKey();
            Equal(TalkAction.Begin, t.Update(true, 1), "down begins");
            Equal(TalkAction.None, t.Update(true, 1.1), "a repeated down changes nothing");
            Equal(TalkAction.Deliver, t.Update(false, 2), "up delivers");
            Equal(TalkAction.None, t.Update(false, 2.1), "a second up changes nothing");
            t.Update(true, 3);
            Equal(TalkAction.Drop, t.Chord(3.1), "a key early in the hold is a shortcut and drops it");
            Equal(TalkAction.None, t.Update(false, 3.2), "the dropped hold sends nothing on release");
            t.Update(true, 4);
            Equal(TalkAction.None, t.Chord(4.5), "a key later in the hold leaves the recording running");
            Equal(TalkAction.Deliver, t.Update(false, 5), "and release still sends");
            Equal(TalkAction.None, t.Chord(6), "a key with nothing held does nothing");
        }

        private static void Stack()
        {
            ShotStack st = new ShotStack();
            Check(st.IsEmpty, "a new stack is empty");
            Check(!st.Hold("hello"), "words go at once when nothing is stacked");
            st.ShotStarted(10);
            Equal(1, st.Count, "a shot being captured counts");
            Check(!st.Ready(20), "a capture under way holds the stack");
            st.ShotFinished("/s/1.png", 11);
            Check(!st.Ready(13.9), "not before three seconds after the last shot");
            Check(st.Ready(14), "ready three seconds after the last shot");
            Check(st.Hold("first words"), "words join stacked shots");
            Check(st.Hold("more words"), "a second talk joins the held words");
            st.TalkEnded(15);
            Check(!st.Ready(17), "the end of a talk restarts the wait");
            Check(st.Ready(18), "ready three seconds after the talk");
            List<string> images;
            string text = st.Take(out images);
            Equal("first words more words", text, "held words in order");
            Equal(1, images.Count, "one image");
            Equal("/s/1.png", images[0], "the image path");
            Check(st.IsEmpty, "take empties the stack");
            st.ShotStarted(30);
            st.ShotFinished(null, 30.5);
            Check(st.IsEmpty, "a failed capture leaves nothing stacked");
        }

        private static void Retries()
        {
            Equal<double?>(20, RetryPlan.DelayAfter(1), "first retry after 20 s");
            Equal<double?>(60, RetryPlan.DelayAfter(2), "second after a minute");
            Equal<double?>(300, RetryPlan.DelayAfter(3), "third after five minutes");
            Equal<double?>(null, RetryPlan.DelayAfter(4), "then no more automatic retries");
            Equal<double?>(null, RetryPlan.DelayAfter(0), "no attempts is not a retry");
        }

        private static void Outcomes()
        {
            Equal("Sent", SendOutcome.Status("sent: tmux %3"), "sent");
            Equal("Sent, unconfirmed", SendOutcome.Status("sent-unconfirmed: tmux %3 (pending)"), "unconfirmed");
            Equal(SendOutcome.SavedForFirstmate, SendOutcome.Status("mailbox: /h/state/desk-voice/inbox/x.json"), "mailbox");
            Equal<string>(null, SendOutcome.Status("failed"), "failed delivers nothing");
            Equal<string>(null, SendOutcome.Status(null), "no output delivers nothing");

            RetryResult r = RetryResult.Parse("delivered\t/u/a.wav\tsent: tmux %1\n");
            Check(r != null && r.Kind == RetryKind.Delivered && r.Status == "Sent", "retry delivered");
            r = RetryResult.Parse("unsent\t/u/a.wav\t2\ttranscription failed");
            Check(r != null && r.Kind == RetryKind.Unsent && r.Attempts == 2, "retry unsent with attempts");
            r = RetryResult.Parse("busy\t/u/a.wav");
            Check(r != null && r.Kind == RetryKind.Busy, "retry busy");
            r = RetryResult.Parse("gone\t/u/a.wav");
            Check(r != null && r.Kind == RetryKind.Gone, "retry gone");
            Check(RetryResult.Parse("transcript\t/u/a.wav\twords") == null, "a dictation transcript is not a talk retry result");
            Check(RetryResult.Parse("unsent\t/u/a.wav\tmany") == null, "unreadable attempts");
        }

        private static void Lines()
        {
            string output = "Welcome to Ubuntu: note\r\ntext\t/h/state/desk-voice/recording/abc-firstmate.wav\thello there\r\n";
            BridgeLine line = BridgeLine.First(output, "text", "saved", "nothing", "known");
            Check(line != null && line.Kind == "text", "the text line is found past login noise");
            Equal("/h/state/desk-voice/recording/abc-firstmate.wav", line.Field(0), "recording path");
            Equal("hello there", line.Field(1), "words");
            Equal<string>(null, line.Field(2), "no third field");

            line = BridgeLine.First("sent: tmux %1\n", "sent:", "sent-unconfirmed:", "mailbox:", "failed");
            Check(line != null && line.Kind == "sent:" && line.Field(0) == "sent: tmux %1", "send outcome keeps its whole line");
            List<BridgeLine> lines = BridgeLine.Parse("saved\t/u/1.wav\nsaved\t/u/2.wav\nfailed\n", "saved", "failed");
            Equal(3, lines.Count, "saved lines and the failure");
            Equal("failed", lines[2].Kind, "failure last");
            Check(BridgeLine.First("", "text") == null, "nothing in empty output");
            Check(BridgeLine.First(null, "text") == null, "nothing in no output");
        }

        private static void History()
        {
            List<RecentReply> replies = RecentReply.Parse("12\t1700000000\tThe build is green.\n11\t1699999000\tFirst\twith a tab\nbad line\n");
            Equal(2, replies.Count, "two replies");
            Equal(12, replies[0].Number, "newest number first");
            Equal("The build is green.", replies[0].Text, "reply text");
            Equal("First\twith a tab", replies[1].Text, "text keeps everything after the second tab");
        }

        private static void Volumes()
        {
            Equal(100, VoiceVolume.Clamp(150), "Windows plays at most the Windows volume");
            Equal(0, VoiceVolume.Clamp(-5), "never below silence");
            Equal(40, VoiceVolume.Clamp(40), "levels in range are kept");
            Equal<int?>(80, VoiceVolume.Parse("80\n"), "parse");
            Equal<int?>(null, VoiceVolume.Parse("loud"), "unreadable");
        }

        private static void Names()
        {
            string id, purpose;
            Equal("0123abcd-firstmate.wav", RecordingName.Make("0123abcd", "firstmate"), "name");
            Check(RecordingName.Split("0123abcd-ef01-dictate.wav", out id, out purpose)
                && id == "0123abcd-ef01" && purpose == "dictate", "split a dictation name");
            Check(RecordingName.Split("0123abcd-firstmate.wav", out id, out purpose)
                && id == "0123abcd" && purpose == "firstmate", "split a talk name");
            Check(!RecordingName.Split("notes.txt", out id, out purpose), "other files are not recordings");
            Check(!RecordingName.Split("x-firstmate.wav", out id, out purpose), "an id must be long enough");
            Check(!RecordingName.Split("../../evil-firstmate.wav", out id, out purpose), "an id has no path characters");
            Check(RecordingName.IsId(Guid.NewGuid().ToString("N")), "a fresh id is accepted");
        }

        private static void CommandLines()
        {
            Equal("bridge transcribe abc", CommandLine.Join(new[] { "bridge", "transcribe", "abc" }), "plain words");
            Equal("\"/home/a b/x\"", CommandLine.Join(new[] { "/home/a b/x" }), "spaces are quoted");
            Equal("\"\"", CommandLine.Join(new[] { "" }), "an empty argument survives");
            Equal("\"say \\\"hi\\\"\"", CommandLine.Join(new[] { "say \"hi\"" }), "quotes are escaped");
            Equal("\"C:\\a b\\\\\"", CommandLine.Join(new[] { "C:\\a b\\" }), "a trailing backslash before the closing quote is doubled");
            Equal("C:\\a\\b", CommandLine.Join(new[] { "C:\\a\\b" }), "backslashes alone stay");
            Check(Terminals.IsTerminal("WindowsTerminal"), "Windows Terminal is a terminal");
            Check(!Terminals.IsTerminal("notepad"), "Notepad is not");
            Check(!Terminals.IsTerminal(null), "no process is not");
        }

        private static void Config()
        {
            FloaterConfig c = FloaterConfig.Parse(new[] { "distro=Ubuntu-24.04\r", "root=/home/a/starship", "home=/home/a/starship", "version=abc", "junk" });
            Check(c.Complete, "a full config");
            Equal("Ubuntu-24.04", c.Distro, "distro without the carriage return");
            Equal("abc", c.Version, "version");
            Check(!FloaterConfig.Parse(new[] { "distro=x" }).Complete, "a config without the home is incomplete");
        }
    }
}
