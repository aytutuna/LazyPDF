using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using LazyPDF.Core;

namespace LazyPDF.App.Services;

/// <summary>
/// Runs JPEG 2000 decodes in a child copy of the app (<see cref="JpxChild"/>) inside a job object with a memory cap. A file
/// that hangs the decoder or takes the process down only costs the child: it is killed, that picture counts as unreadable
/// and the next one gets a fresh child.
/// </summary>
internal static class JpxWorker
{
    private const int DecodeSeconds = 20, StartSeconds = 20;

    private const int TimeoutsBeforePause = 3, MaxRemembered = 256, HashedBytes = 64 << 10;

    internal static readonly object Gate = new();
    private static readonly HashSet<string> TimedOut = [];
    private static Child? child;
    private static int timeouts;
    private static long pausedUntil;

    /// <summary>How long one decode may take before the child is killed.</summary>
    internal static TimeSpan Limit { get; set; } = TimeSpan.FromSeconds(DecodeSeconds);

    /// <summary>The job's memory cap for each child started from now on.</summary>
    internal static long MemoryCap { get; set; } = OpenJpeg.DecodeBudget + 4 * PdfImageSamples.MaxPixels + (256L << 20);

    /// <summary>The program and arguments that start a child; null for this app itself. Tests run inside another host.</summary>
    internal static string[]? CommandLine { get; set; }

    /// <summary>How long every decode is refused after three timeouts in a row.</summary>
    internal static TimeSpan Pause { get; set; } = TimeSpan.FromSeconds(60);

    /// <summary>How many children have been killed and started, for tests.</summary>
    internal static int Kills { get; private set; }

    internal static int Starts { get; private set; }

    public static PdfRgbaImage? Decode(byte[] data, int components) => Request(JpxChild.Decode, components, data);

    internal static PdfRgbaImage? Request(byte op, int hint, byte[] data)
    {
        string key = Key(op, hint, data);
        if (Refused(key)) return null;
        // Whoever waits longer than a decode may take gives up, so a file full of bad pictures cannot queue the rest behind kill after kill.
        if (!Monitor.TryEnter(Gate, Limit)) return null;
        Child.Alarm? alarm = null;
        try
        {
            if (Refused(key)) return null;
            if (child is { IsGone: true }) Stop();
            var current = child ??= Start();
            alarm = current.Watch(Limit);
            var image = Exchange(current, op, hint, data);
            timeouts = 0;
            return image;
        }
        catch (Exception)
        {
            bool late = alarm?.Fired == true;
            Stop();
            if (late) NoteTimeout(key);
            return null;
        }
        finally
        {
            alarm?.Dispose();
            Monitor.Exit(Gate);
        }
    }

    private static string Key(byte op, int hint, byte[] data) =>
        $"{op}/{hint}/{data.Length}/{Convert.ToHexString(SHA256.HashData(data.AsSpan(0, Math.Min(data.Length, HashedBytes))))}";

    private static bool Refused(string key)
    {
        lock (TimedOut)
        {
            return Environment.TickCount64 < pausedUntil || TimedOut.Contains(key);
        }
    }

    private static void NoteTimeout(string key)
    {
        lock (TimedOut)
        {
            if (TimedOut.Count >= MaxRemembered) TimedOut.Clear();
            TimedOut.Add(key);
            if (++timeouts >= TimeoutsBeforePause) pausedUntil = Environment.TickCount64 + (long)Pause.TotalMilliseconds;
        }
    }

    private static PdfRgbaImage? Exchange(Child current, byte op, int hint, byte[] data)
    {
        var head = new byte[9];
        head[0] = op;
        BitConverter.TryWriteBytes(head.AsSpan(1), hint);
        BitConverter.TryWriteBytes(head.AsSpan(5), data.Length);
        current.Input.Write(head);
        current.Input.Write(data);
        current.Input.Flush();

        int status = current.Output.ReadByte();
        if (status == 1) return null;
        if (status != 0) throw new InvalidDataException();
        var size = new byte[8];
        current.Output.ReadExactly(size);
        int width = BitConverter.ToInt32(size, 0), height = BitConverter.ToInt32(size, 4);
        if (width < 1 || height < 1 || (long)width * height > PdfImageSamples.MaxPixels) throw new InvalidDataException();
        var rgba = new byte[width * height * 4];
        current.Output.ReadExactly(rgba);
        return new PdfRgbaImage(width, height, rgba);
    }

    /// <summary>Ends the running child, so the next decode starts a new one with the current settings, and forgets every timeout. For tests.</summary>
    internal static void Reset()
    {
        lock (Gate) Stop();
        lock (TimedOut)
        {
            TimedOut.Clear();
            timeouts = 0;
            pausedUntil = 0;
        }
    }

    private static Child Start()
    {
        string[] command = CommandLine ?? Own();
        var info = new ProcessStartInfo(command[0])
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (string argument in command[1..]) info.ArgumentList.Add(argument);
        var process = Process.Start(info) ?? throw new InvalidOperationException();
        Starts++;
        Child? started = null;
        try
        {
            process.ErrorDataReceived += (_, _) => { };
            process.BeginErrorReadLine();
            // The job has the child before anything is sent to it.
            started = new Child(process, MemoryCap);
            using (started.Watch(TimeSpan.FromSeconds(StartSeconds)))
            {
                if (started.Output.ReadByte() != JpxChild.Ready) throw new InvalidDataException();
            }
            AppDomain.CurrentDomain.ProcessExit -= Exit;
            AppDomain.CurrentDomain.ProcessExit += Exit;
            return started;
        }
        catch (Exception)
        {
            if (started is not null) started.Kill();
            else End(process);
            throw;
        }
    }

    // This exe, with the entry dll too when the host is dotnet.exe.
    private static string[] Own()
    {
        string host = Environment.ProcessPath ?? throw new InvalidOperationException();
        if (!string.Equals(Path.GetFileNameWithoutExtension(host), "dotnet", StringComparison.OrdinalIgnoreCase)) return [host, JpxChild.Switch];
        return [host, typeof(JpxWorker).Assembly.Location, JpxChild.Switch];
    }

    private static void Stop()
    {
        var old = child;
        child = null;
        if (old is null) return;
        old.Kill();
        Kills++;
    }

    private static void Exit(object? sender, EventArgs e) => child?.Kill();

    private static void End(Process process)
    {
        try { process.Kill(); }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        process.WaitForExit(5000);
        process.Dispose();
    }

    private sealed class Child
    {
        private readonly IntPtr job;
        private int killed;

        public Child(Process process, long memoryCap)
        {
            Process = process;
            job = CreateJobObjectW(IntPtr.Zero, null);
            var limits = new ExtendedLimits();
            limits.Basic.LimitFlags = KillOnClose | DieOnUnhandled | ProcessMemory;
            limits.ProcessMemoryLimit = (nuint)memoryCap;
            if (job == IntPtr.Zero || !SetInformationJobObject(job, ExtendedLimitInformation, ref limits, Marshal.SizeOf<ExtendedLimits>()) || !AssignProcessToJobObject(job, process.Handle))
            {
                if (job != IntPtr.Zero) CloseHandle(job);
                throw new InvalidOperationException("job object");
            }
            Input = process.StandardInput.BaseStream;
            Output = process.StandardOutput.BaseStream;
        }

        public Process Process { get; }

        public Stream Input { get; }

        public Stream Output { get; }

        public bool IsGone => Volatile.Read(ref killed) != 0 || Process.HasExited;

        // Kills the child when the time runs out; the read or write it blocks in then fails.
        public Alarm Watch(TimeSpan limit) => new(this, limit);

        public void Kill()
        {
            if (Interlocked.Exchange(ref killed, 1) != 0) return;
            End(Process);
            CloseHandle(job);
        }

        // A timer callback can already be running when its exchange ends, so it checks under the lock that it is still the one
        // it was set for; otherwise it would kill a child that has moved on to the next request.
        public sealed class Alarm : IDisposable
        {
            private readonly Child owner;
            private readonly Timer timer;
            private readonly object sync = new();
            private bool over;

            public Alarm(Child owner, TimeSpan limit)
            {
                this.owner = owner;
                timer = new Timer(_ => Expire(), null, limit, Timeout.InfiniteTimeSpan);
            }

            public bool Fired { get; private set; }

            private void Expire()
            {
                lock (sync)
                {
                    if (over) return;
                    Fired = true;
                    owner.Kill();
                }
            }

            public void Dispose()
            {
                lock (sync) over = true;
                timer.Dispose();
            }
        }
    }

    private const uint ProcessMemory = 0x100, DieOnUnhandled = 0x400, KillOnClose = 0x2000;
    private const int ExtendedLimitInformation = 9;

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public nuint MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public nuint Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimits
    {
        public BasicLimits Basic;
        public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
        public nuint ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObjectW(IntPtr attributes, string? name);

    [DllImport("kernel32", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, int size);

    [DllImport("kernel32", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);
}
