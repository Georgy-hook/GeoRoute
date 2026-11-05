using System;
using System.Diagnostics;
using System.IO;
using System.ServiceProcess;
using System.Text;
using System.Threading;

[assembly: System.Reflection.AssemblyTitle("NextDNS Bridge")]
[assembly: System.Reflection.AssemblyDescription("NextDNS TLS 1.3 DNS service, bound to loopback only")]
[assembly: System.Reflection.AssemblyVersion("1.1.0.0")]

namespace NextDNSBridge
{
    // Own exactly one worker. A fresh instance supplies a fresh READY signal.
    internal sealed class WorkerProcess : IDisposable
    {
        private readonly Process process;
        private readonly ManualResetEvent ready = new ManualResetEvent(false);
        private readonly object gate = new object();
        private readonly Action<string> log;
        private bool disposed;

        internal WorkerProcess(ProcessStartInfo start, Action<string> logger)
        {
            log = logger;
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardInput = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            process = new Process { StartInfo = start };
            process.OutputDataReceived += Output;
            process.ErrorDataReceived += Error;
        }

        private void Output(object sender, DataReceivedEventArgs e)
        {
            if (e.Data == "READY")
            {
                lock (gate) { if (!disposed) ready.Set(); }
            }
            else if (!String.IsNullOrEmpty(e.Data)) log(e.Data);
        }

        private void Error(object sender, DataReceivedEventArgs e)
        {
            if (!String.IsNullOrEmpty(e.Data)) log(e.Data);
        }

        internal bool IsRunning { get { return !process.HasExited; } }

        internal void Start(int timeoutMilliseconds)
        {
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            Stopwatch elapsed = Stopwatch.StartNew();
            while (!ready.WaitOne(50))
            {
                if (process.HasExited)
                    throw new InvalidOperationException("DNS worker exited before READY; see service.log");
                if (elapsed.ElapsedMilliseconds >= timeoutMilliseconds)
                    throw new System.TimeoutException("DNS worker did not become ready; see service.log");
            }
            if (process.HasExited)
                throw new InvalidOperationException("DNS worker exited during startup; see service.log");
        }

        internal void Stop(int timeoutMilliseconds)
        {
            // STOP is the worker protocol. Terminate only this owned child if hung.
            try
            {
                if (process.HasExited) return;
                try { process.StandardInput.WriteLine("STOP"); process.StandardInput.Flush(); }
                catch (IOException) { }
                if (!process.WaitForExit(timeoutMilliseconds))
                {
                    log("DNS worker did not stop in time; terminating the owned worker");
                    process.Kill();
                    process.WaitForExit(2000);
                }
            }
            catch (InvalidOperationException) { } // Not started, or exited concurrently.
        }

        public void Dispose()
        {
            lock (gate)
            {
                if (disposed) return;
                disposed = true;
            }
            try { Stop(6000); }
            finally
            {
                process.OutputDataReceived -= Output;
                process.ErrorDataReceived -= Error;
                process.Dispose();
                ready.Dispose();
            }
        }
    }

    public sealed class BridgeService : ServiceBase
    {
        private static readonly string Data = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "NextDNSBridge");
        private readonly object gate = new object();
        private readonly object logGate = new object();
        private WorkerProcess worker;
        private Timer health;
        private bool stopping;

        public BridgeService()
        {
            ServiceName = "NextDNSBridge";
            CanStop = true;
            CanShutdown = true;
            AutoLog = true;
        }

        private void Log(string text)
        {
            lock (logGate)
            {
                try
                {
                    Directory.CreateDirectory(Data);
                    string path = Path.Combine(Data, "service.log");
                    if (File.Exists(path) && new FileInfo(path).Length > 256 * 1024)
                        File.WriteAllText(path, "");
                    File.AppendAllText(path, DateTime.UtcNow.ToString("o") + " " + text + Environment.NewLine, Encoding.UTF8);
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }

        protected override void OnStart(string[] args)
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string python = Path.Combine(root, @"python\python.exe");
            string script = Path.Combine(root, "bridge.py");
            if (!File.Exists(python) || !File.Exists(script))
                throw new FileNotFoundException("DNS worker package is incomplete");
            var start = new ProcessStartInfo(python, "-I -u \"" + script +
                "\" --profile-file \"" + Path.Combine(root, "profile.txt") + "\" --data-dir \"" + Data + "\"");
            start.WorkingDirectory = root;
            var next = new WorkerProcess(start, Log);
            try { next.Start(12000); }
            catch { next.Dispose(); throw; }
            lock (gate)
            {
                stopping = false;
                ExitCode = 0;
                worker = next;
                health = new Timer(CheckWorker, null, 1000, 1000);
            }
            Log("Service started; DNS worker ready");
        }

        private void CheckWorker(object state)
        {
            lock (gate)
            {
                if (stopping || worker == null || worker.IsRunning) return;
                stopping = true;
                // The installer sets SCM failureflag=1 for non-success stops.
                ExitCode = 1067; // ERROR_PROCESS_ABORTED
            }
            Log("DNS worker exited unexpectedly; stopping service for Windows recovery");
            Stop();
        }

        protected override void OnStop()
        {
            WorkerProcess previous;
            Timer previousHealth;
            lock (gate)
            {
                stopping = true;
                previous = worker;
                worker = null;
                previousHealth = health;
                health = null;
            }
            if (previousHealth != null) previousHealth.Dispose();
            if (previous != null) previous.Dispose();
            Log("Service stopped");
        }

        protected override void OnShutdown() { OnStop(); }
    }

    public static class Program
    {
        public static int Main(string[] args)
        {
            using (var service = new BridgeService()) ServiceBase.Run(service);
            return 0;
        }
    }
}
