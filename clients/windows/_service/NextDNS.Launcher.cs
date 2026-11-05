using System;
using System.Collections;
using System.Globalization;
using System.IO;
using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Security.Cryptography;
using System.Security.Principal;

[assembly: AssemblyTitle("GeoRoute")]
[assembly: AssemblyDescription("GeoRoute — GeoHide profiles and monitoring")]
[assembly: AssemblyProduct("GeoRoute")]
[assembly: AssemblyVersion("0.4.0.0")]
[assembly: AssemblyFileVersion("0.4.0.0")]

namespace NextDNS.Desktop
{
    // Poll the event on the WPF dispatcher; never invoke PowerShell on a CLR worker thread.
    public static class DesktopInstance
    {
        private static Mutex mutex;
        private static EventWaitHandle activation;
        public static string ActivationName { get; private set; }
        public static bool Acquire(string root, bool repair, bool background)
        {
            string hash;
            using (SHA256 sha = SHA256.Create())
                hash = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(Path.GetFullPath(root).ToLowerInvariant()))).Replace("-", "").Substring(0, 24);
            string name = @"Local\NextDNS.Manager." + WindowsIdentity.GetCurrent().User.Value + "." + hash + (repair ? ".Repair" : ".Main");
            ActivationName = name + ".Activate";
            activation = new EventWaitHandle(false, EventResetMode.AutoReset, ActivationName);
            bool created;
            mutex = new Mutex(true, name, out created);
            if (!created) { if (!background) activation.Set(); Dispose(); }
            return created;
        }
        public static bool ConsumeActivation() { return activation != null && activation.WaitOne(0); }
        public static void Dispose()
        {
            if (activation != null) { activation.Dispose(); activation = null; }
            if (mutex != null) { mutex.Dispose(); mutex = null; }
        }
    }

    internal static class Program
    {
        private static string serviceRoot;
        private static bool smokeTest;

        [STAThread]
        private static int Main(string[] args)
        {
            serviceRoot = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "_service");
            if (!File.Exists(Path.Combine(serviceRoot, "NextDNS-GUI.ps1")))
                serviceRoot = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
            foreach (string argument in args)
            {
                if (string.Equals(argument, "-SmokeTest", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(argument, "-RenderPreview", StringComparison.OrdinalIgnoreCase)) smokeTest = true;
            }
            try
            {
                string script = Path.Combine(serviceRoot, "NextDNS-GUI.ps1");
                if (!File.Exists(script)) throw new FileNotFoundException("Не найден файл интерфейса _service\\NextDNS-GUI.ps1.", script);
                bool repair = Array.Exists(args, a => string.Equals(a, "-Repair", StringComparison.OrdinalIgnoreCase));
                bool tray = Array.Exists(args, a => string.Equals(a, "-Tray", StringComparison.OrdinalIgnoreCase));
                if (!smokeTest && !DesktopInstance.Acquire(serviceRoot, repair, tray)) return 0;

                string windowsPowerShell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0");
                var start = new ProcessStartInfo(Path.Combine(windowsPowerShell, "powershell.exe"), Arguments(script, args));
                start.WorkingDirectory = serviceRoot;
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.WindowStyle = ProcessWindowStyle.Hidden;
                AppendLog("launcher.log", "Starting Windows PowerShell 5.1 GUI process");
                using (Process process = Process.Start(start))
                {
                    process.WaitForExit();
                    AppendLog("launcher.log", "GUI process stopped; exit=" + process.ExitCode);
                    return process.ExitCode;
                }
            }
            catch (Exception exception)
            {
                string diagnostic = exception.ToString();
                AppendLog("launcher-error.log", diagnostic);
                if (!smokeTest)
                {
                    string message = "Не удалось открыть GeoRoute.\r\n\r\n" + exception.Message;
                    if (message.Length > 2400) message = message.Substring(0, 2400);
                    message += "\r\n\r\nПодробности: _service\\launcher-error.log";
                    MessageBox.Show(message, "GeoRoute", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                return 1;
            }
            finally { DesktopInstance.Dispose(); }
        }

        private static string Quote(string value)
        {
            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes);
                result.Append(c);
                slashes = 0;
            }
            result.Append('\\', slashes * 2).Append('"');
            return result.ToString();
        }

        private static string Arguments(string script, string[] args)
        {
            var result = new StringBuilder("-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File ").Append(Quote(script));
            for (int index = 0; index < args.Length; index++)
            {
                string argument = args[index];
                if (string.Equals(argument, "-SmokeTest", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(argument, "-Tray", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(argument, "-RenderPreview", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(argument, "-Repair", StringComparison.OrdinalIgnoreCase)) result.Append(' ').Append(argument);
                else if (string.Equals(argument, "-PreviewPath", StringComparison.OrdinalIgnoreCase) ||
                         string.Equals(argument, "-PreviewWidth", StringComparison.OrdinalIgnoreCase) ||
                         string.Equals(argument, "-PreviewHeight", StringComparison.OrdinalIgnoreCase) ||
                         string.Equals(argument, "-HealthSnapshotPath", StringComparison.OrdinalIgnoreCase))
                {
                    if (++index >= args.Length) throw new ArgumentException("Не указано значение " + argument + ".");
                    result.Append(' ').Append(argument).Append(' ').Append(Quote(args[index]));
                }
                else throw new ArgumentException("Неизвестный параметр приложения: " + argument);
            }
            if (!smokeTest && DesktopInstance.ActivationName != null)
                result.Append(" -ActivationEvent ").Append(Quote(DesktopInstance.ActivationName));
            return result.ToString();
        }

        private static void AppendLog(string name, string text)
        {
            try
            {
                string path = Path.Combine(serviceRoot, name);
                if (File.Exists(path) && new FileInfo(path).Length > 512 * 1024)
                    File.WriteAllText(path, "", new UTF8Encoding(true));
                File.AppendAllText(path, DateTime.Now.ToString("o", CultureInfo.InvariantCulture) + "  " + text + Environment.NewLine, new UTF8Encoding(true));
            }
            catch { }
        }
    }
}
