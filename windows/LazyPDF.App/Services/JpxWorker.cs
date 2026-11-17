using System.Diagnostics;
using System.Runtime.InteropServices;
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

    private static readonly object Gate = new();
    private static Child? child;

    /// <summary>How long one decode may take before the child is killed.</summary>
    internal static TimeSpan Limit { get; set; } = TimeSpan.FromSeconds(DecodeSeconds);

    /// <summary>The job's memory cap for each child started from now on.</summary>
    internal static long MemoryCap { get; set; } = OpenJpeg.DecodeBudget + 4 * PdfImageSamples.MaxPixels + (256L << 20);

    /// <summary>The program and arguments that start a child; null for this app itself. Tests run inside another host.</summary>
    internal static string[]? CommandLine { get; set; }

    /// <summary>How many children have been killed, for tests.</summary>
    internal static int Kills { get; private set; }

    public static PdfRgbaImage? Decode(byte[] data, int components) => Request(JpxChild.Decode, components, data);

    internal static PdfRgbaImage? Request(byte op, int hint, byte[] data)
    {
        lock (Gate)
        {
            try
            {
                if (child is { Process.HasExited: true }) Stop();
                var current = child ??= Start();
                using (current.Watch(Limit)) return Exchange(current, op, hint, data);
            }
            catch (Exception)
            {
                Stop();
                return null;
            }
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
            else process.Kill();
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

        // Kills the child when the time runs out; the read or write it blocks in then fails.
        public IDisposable Watch(TimeSpan limit) => new Timer(_ => Kill(), null, limit, Timeout.InfiniteTimeSpan);

        public void Kill()
        {
            if (Interlocked.Exchange(ref killed, 1) != 0) return;
            try { Process.Kill(); }
            catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception) { }
            Process.WaitForExit(5000);
            CloseHandle(job);
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
