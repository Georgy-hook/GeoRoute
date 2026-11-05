namespace NextDNSBridge.Tests
{
    public static class Lifecycle
    {
        private static WorkerProcess Worker(string python, string code)
        {
            var start = new System.Diagnostics.ProcessStartInfo(python, "-I -u -c \"" + code + "\"");
            return new WorkerProcess(start, delegate(string message) { });
        }

        private static void Assert(bool condition, string message)
        {
            if (!condition) throw new System.Exception(message);
        }

        public static string Run(string python)
        {
            int passed = 0;
            using (var worker = Worker(python, "import sys; print('READY', flush=True); sys.stdin.readline()"))
            {
                worker.Start(2000);
                Assert(worker.IsRunning, "Healthy worker must be running");
                worker.Stop(1500);
                Assert(!worker.IsRunning, "STOP must stop the healthy worker");
                passed++;
            }
            using (var worker = Worker(python, "import sys; sys.exit(9)"))
            {
                var watch = System.Diagnostics.Stopwatch.StartNew();
                bool rejected = false;
                try { worker.Start(3000); }
                catch (System.InvalidOperationException) { rejected = true; }
                Assert(rejected && watch.ElapsedMilliseconds < 2000, "Startup exit must fail promptly");
                passed++;
            }
            using (var worker = Worker(python, "import time; time.sleep(30)"))
            {
                bool rejected = false;
                try { worker.Start(150); }
                catch (System.TimeoutException) { rejected = true; }
                finally { worker.Stop(100); }
                Assert(rejected && !worker.IsRunning, "Missing READY must time out and release worker");
                passed++;
            }
            using (var worker = Worker(python, "import time; print('READY', flush=True); time.sleep(.5)"))
            {
                worker.Start(2000);
                var watch = System.Diagnostics.Stopwatch.StartNew();
                while (worker.IsRunning && watch.ElapsedMilliseconds < 2000)
                    System.Threading.Thread.Sleep(25);
                Assert(!worker.IsRunning, "Post-READY exit must be observable by the service health check");
                passed++;
            }
            using (var worker = Worker(python, "import time; print('READY', flush=True); time.sleep(30)"))
            {
                worker.Start(2000);
                var watch = System.Diagnostics.Stopwatch.StartNew();
                worker.Stop(100);
                Assert(!worker.IsRunning && watch.ElapsedMilliseconds < 2500, "Hung worker shutdown must be bounded");
                passed++;
            }
            var unstarted = Worker(python, "pass");
            unstarted.Dispose();
            unstarted.Dispose();
            passed++;
            using (var worker = Worker(python, "import sys; print('READY', flush=True); sys.stdin.readline()"))
            {
                worker.Start(2000);
                worker.Stop(1000);
            }
            using (var worker = Worker(python, "import time; time.sleep(30)"))
            {
                bool rejected = false;
                try { worker.Start(150); }
                catch (System.TimeoutException) { rejected = true; }
                finally { worker.Stop(100); }
                Assert(rejected, "A new startup must not reuse a previous READY signal");
                passed++;
            }
            return passed.ToString() + " lifecycle scenarios passed";
        }
    }
}
