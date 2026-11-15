<#
    PC Doctor - diagnostic du PC (lenteurs, plantages, espace disque)
    Lancer via "PC Doctor.exe" ou "Lancer PC Doctor.bat".
    Nécessite Windows PowerShell 5.1 (inclus dans Windows 10/11).
#>
param([switch]$SelfTest, [string]$LaunchedFrom, [switch]$Monitor, [switch]$Widget, [string]$ExePath)

$ErrorActionPreference = 'Stop'
# $LaunchedFrom est fourni quand le script est relancé en administrateur depuis la mémoire (voir Start-ElevatedSelf)
$script:ScriptPath = if ($LaunchedFrom) { $LaunchedFrom } else { $MyInvocation.MyCommand.Path }
# Chemins système résolus par l'API Windows (et non par des variables d'environnement modifiables)
$script:Sys32 = [Environment]::SystemDirectory
$script:PowerShellExe = Join-Path $script:Sys32 'WindowsPowerShell\v1.0\powershell.exe'
$script:LogDir = Join-Path $env:LOCALAPPDATA 'PCDoctor'
New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
$script:LogFile = Join-Path $script:LogDir 'PCDoctor.log'

function Write-Log([string]$Text) {
    try { Add-Content -LiteralPath $script:LogFile -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Text) -Encoding UTF8 } catch {}
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, Microsoft.VisualBasic

# ---------------------------------------------------------------------------
#  Moteur rapide (C#) : scan disque, taille de dossiers, nettoyage, corbeille
# ---------------------------------------------------------------------------
$csharp = @'
using System;
using System.IO;
using System.Text;
using System.Globalization;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;
using System.Collections.Generic;
using System.Threading;
using System.Runtime.InteropServices;
using System.Management;
using System.IO.MemoryMappedFiles;

namespace PCDoctor {
    // ---------------------------------------------------------------------
    //  Capteurs en direct pour le widget (CPU, GPU, RAM, SSD)
    // ---------------------------------------------------------------------
    public class SensorSnapshot {
        public double Cpu = -1, CpuTemp = -1, Ram = -1, RamUsedGB = -1, RamTotalGB = -1;
        public double GpuUsage = -1, GpuTemp = -1, GpuPower = -1, GpuPowerLimit = -1, GpuMemUsed = -1, GpuMemTotal = -1, GpuFan = -1, GpuClock = -1;
        public double DiskBusy = -1, DiskRead = -1, DiskWrite = -1, DiskTemp = -1, DiskUsedPct = -1, DiskFreeGB = -1;
        public string CpuTempSource = "", DiskTempSource = "", DiskName = "", GpuName = "";
    }

    // Garde les proportions d'une fenêtre pendant qu'on la redimensionne par ses bords (message WM_SIZING)
    public class AspectLock : NativeWindow {
        public double Ratio = 1.0;     // largeur / hauteur
        public int MinWidth = 150, MaxWidth = 900;
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
        public AspectLock(IntPtr hwnd) { AssignHandle(hwnd); }
        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x0214 && Ratio > 0.05) {
                RECT r = (RECT)Marshal.PtrToStructure(m.LParam, typeof(RECT));
                int edge = m.WParam.ToInt32();
                int w = r.R - r.L, h = r.B - r.T;
                if (edge == 3 || edge == 6) w = (int)Math.Round(h * Ratio);   // bord haut ou bas : la hauteur commande
                w = Math.Max(MinWidth, Math.Min(MaxWidth, w));
                h = (int)Math.Round(w / Ratio);
                if (edge == 1 || edge == 4 || edge == 7) r.L = r.R - w; else r.R = r.L + w;
                if (edge == 3 || edge == 4 || edge == 5) r.T = r.B - h; else r.B = r.T + h;
                Marshal.StructureToPtr(r, m.LParam, false);
                m.Result = (IntPtr)1;
                return;
            }
            base.WndProc(ref m);
        }
    }

    public static class LiveSensors {
        [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
        [StructLayout(LayoutKind.Sequential)]
        class MEMSTAT {
            public uint dwLength; public uint dwMemoryLoad; public ulong ullTotalPhys; public ulong ullAvailPhys;
            public ulong ullTotalPageFile; public ulong ullAvailPageFile; public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
            public MEMSTAT() { dwLength = (uint)Marshal.SizeOf(typeof(MEMSTAT)); }
        }
        [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx([In, Out] MEMSTAT m);

        static long _pi, _pk, _pu;
        static Process _smi; static volatile string _smiLine; static string _smiPath;
        static readonly object _lock = new object();
        static double _diskBusy = -1, _diskRead = -1, _diskWrite = -1, _diskTemp = -1, _cpuTemp = -1;
        static string _cpuTempSrc = "", _diskTempSrc = "", _diskModel = "", _drive = "C:";
        static int _diskIndex = -1;
        static volatile bool _running;

        public static bool CoreTempInstalled() {
            return File.Exists(CoreTempPath());
        }
        public static string CoreTempPath() {
            string a = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"Core Temp\Core Temp.exe");
            if (File.Exists(a)) return a;
            string b = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), @"Core Temp\Core Temp.exe");
            return File.Exists(b) ? b : a;
        }

        public static void Start(string smiPath, string drive) {
            if (_running) return;
            _running = true;
            _drive = string.IsNullOrEmpty(drive) ? "C:" : drive.TrimEnd('\\');
            _smiPath = smiPath;
            StartSmi();
            Thread t = new Thread(Loop);
            t.IsBackground = true;
            t.Start();
        }
        public static void Stop() {
            _running = false;
            try { if (_smi != null && !_smi.HasExited) _smi.Kill(); } catch { }
        }

        static void StartSmi() {
            if (string.IsNullOrEmpty(_smiPath) || !File.Exists(_smiPath)) return;
            try {
                ProcessStartInfo psi = new ProcessStartInfo(_smiPath, "--query-gpu=name,temperature.gpu,utilization.gpu,power.draw,power.limit,memory.used,memory.total,fan.speed,clocks.gr --format=csv,noheader,nounits -lms 2000");
                psi.UseShellExecute = false; psi.RedirectStandardOutput = true; psi.CreateNoWindow = true;
                _smi = Process.Start(psi);
                _smi.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null && e.Data.IndexOf(',') > 0) _smiLine = e.Data; };
                _smi.BeginOutputReadLine();
            } catch { _smi = null; }
        }

        static void Loop() {
            FindDisk();
            DateTime nextDiskTemp = DateTime.MinValue;
            while (_running) {
                try { ReadDiskPerf(); } catch { }
                try { ReadCpuTemp(); } catch { }
                if (DateTime.Now >= nextDiskTemp) { nextDiskTemp = DateTime.Now.AddSeconds(30); try { ReadDiskTemp(); } catch { } }
                try { if (_smi != null && _smi.HasExited) { _smi = null; _smiLine = null; StartSmi(); } } catch { }
                Thread.Sleep(2000);
            }
        }

        static void FindDisk() {
            try {
                using (ManagementObjectSearcher s = new ManagementObjectSearcher("ASSOCIATORS OF {Win32_LogicalDisk.DeviceID='" + _drive + "'} WHERE AssocClass=Win32_LogicalDiskToPartition"))
                    foreach (ManagementObject p in s.Get()) { _diskIndex = Convert.ToInt32(p["DiskIndex"]); break; }
                if (_diskIndex >= 0)
                    using (ManagementObjectSearcher s2 = new ManagementObjectSearcher("SELECT Model FROM Win32_DiskDrive WHERE Index=" + _diskIndex))
                        foreach (ManagementObject d in s2.Get()) { _diskModel = Convert.ToString(d["Model"]); break; }
            } catch { }
        }

        static void ReadDiskPerf() {
            using (ManagementObjectSearcher s = new ManagementObjectSearcher("SELECT Name, PercentIdleTime, DiskReadBytesPersec, DiskWriteBytesPersec FROM Win32_PerfFormattedData_PerfDisk_PhysicalDisk")) {
                foreach (ManagementObject o in s.Get()) {
                    string name = Convert.ToString(o["Name"]);
                    if (name == "_Total") continue;
                    bool match = (_diskIndex >= 0 && name.StartsWith(_diskIndex + " ")) || name.IndexOf(_drive, StringComparison.OrdinalIgnoreCase) >= 0;
                    if (!match) continue;
                    double idle = Convert.ToDouble(o["PercentIdleTime"]);
                    lock (_lock) {
                        _diskBusy = Math.Max(0, Math.Min(100, 100 - idle));
                        _diskRead = Convert.ToDouble(o["DiskReadBytesPersec"]);
                        _diskWrite = Convert.ToDouble(o["DiskWriteBytesPersec"]);
                    }
                    break;
                }
            }
        }

        static void ReadDiskTemp() {
            double t = -1; string src = "";
            if (_diskIndex >= 0) {
                try {
                    ManagementScope scope = new ManagementScope(@"root\Microsoft\Windows\Storage");
                    using (ManagementObjectSearcher s = new ManagementObjectSearcher(scope, new ObjectQuery("SELECT DeviceId, Temperature FROM MSFT_StorageReliabilityCounter")))
                        foreach (ManagementObject o in s.Get()) {
                            if (Convert.ToString(o["DeviceId"]) != _diskIndex.ToString()) continue;
                            object v = o["Temperature"];
                            if (v != null && Convert.ToDouble(v) > 0) { t = Convert.ToDouble(v); src = "SMART"; }
                            break;
                        }
                } catch { }
            }
            if (t < 0) {
                foreach (HwReading r in HwinfoAll()) {
                    if (r.Type == 1 && r.Label.StartsWith("Drive Temperature") && (_diskModel.Length == 0 || r.Sensor.IndexOf(_diskModel, StringComparison.OrdinalIgnoreCase) >= 0)) { t = r.Value; src = "HWiNFO"; break; }
                }
            }
            lock (_lock) { _diskTemp = t; _diskTempSrc = src; }
        }

        static void ReadCpuTemp() {
            double t = -1; string src = "";
            string[] wanted = { "CPU (Tctl/Tdie)", "CPU Package", "CPU (Tctl)", "CPU Die (average)", "Core Max", "CPU" };
            List<HwReading> hw = HwinfoAll();
            foreach (string w in wanted) {
                foreach (HwReading r in hw) { if (r.Type == 1 && r.Label == w && r.Value > 0) { t = r.Value; src = "HWiNFO"; break; } }
                if (t > 0) break;
            }
            if (t <= 0) { t = CoreTemp(); if (t > 0) src = "Core Temp"; }
            lock (_lock) { _cpuTemp = t > 0 ? t : -1; _cpuTempSrc = src; }
        }

        static double CoreTemp() {
            foreach (string name in new string[] { "CoreTempMappingObject", "CoreTempMappingObjectEx" }) {
                try {
                    using (MemoryMappedFile mmf = MemoryMappedFile.OpenExisting(name, MemoryMappedFileRights.Read))
                    using (MemoryMappedViewAccessor a = mmf.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read)) {
                        uint cores = a.ReadUInt32(1536), cpus = a.ReadUInt32(1540);
                        uint n = Math.Min(256u, Math.Max(1u, cores * Math.Max(1u, cpus)));
                        uint tj = a.ReadUInt32(1024);
                        byte fahr = a.ReadByte(2684), delta = a.ReadByte(2685);
                        double max = -1;
                        for (int i = 0; i < n; i++) {
                            double v = a.ReadSingle(1544 + i * 4);
                            if (delta != 0) v = tj - v;
                            if (fahr != 0) v = (v - 32) * 5 / 9;
                            if (v > max) max = v;
                        }
                        if (max > 0 && max < 130) return max;
                    }
                } catch { }
            }
            return -1;
        }

        struct HwReading { public uint Type; public string Sensor; public string Label; public double Value; }
        static string Str(MemoryMappedViewAccessor a, long off, int len) {
            byte[] buf = new byte[len];
            a.ReadArray(off, buf, 0, len);
            int z = Array.IndexOf(buf, (byte)0);
            return Encoding.Default.GetString(buf, 0, z < 0 ? len : z);
        }
        // Mémoire partagée de HWiNFO (option « Shared Memory Support »)
        static List<HwReading> HwinfoAll() {
            List<HwReading> res = new List<HwReading>();
            try {
                using (MemoryMappedFile mmf = MemoryMappedFile.OpenExisting(@"Global\HWiNFO_SENS_SM2", MemoryMappedFileRights.Read))
                using (MemoryMappedViewAccessor a = mmf.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read)) {
                    if (a.ReadUInt32(0) != 0x53695748) return res;   // "HWiS"
                    uint offS = a.ReadUInt32(20), sizeS = a.ReadUInt32(24), numS = a.ReadUInt32(28);
                    uint offR = a.ReadUInt32(32), sizeR = a.ReadUInt32(36), numR = a.ReadUInt32(40);
                    string[] sensors = new string[Math.Min(numS, 2048u)];
                    for (uint i = 0; i < sensors.Length; i++) sensors[i] = Str(a, offS + i * sizeS + 8, 128);
                    for (uint i = 0; i < numR && i < 16384; i++) {
                        long b = offR + (long)i * sizeR;
                        HwReading r = new HwReading();
                        r.Type = a.ReadUInt32(b);
                        uint si = a.ReadUInt32(b + 4);
                        r.Label = Str(a, b + 12, 128);
                        r.Value = a.ReadDouble(b + 284);
                        r.Sensor = si < sensors.Length ? sensors[si] : "";
                        res.Add(r);
                    }
                }
            } catch { }
            return res;
        }

        static double N(string s) {
            double d;
            return double.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out d) ? d : -1;
        }

        public static SensorSnapshot Read() {
            SensorSnapshot s = new SensorSnapshot();
            long i, k, u;
            if (GetSystemTimes(out i, out k, out u)) {
                if (_pk != 0) {
                    long di = i - _pi, tot = (k - _pk) + (u - _pu);
                    if (tot > 0) s.Cpu = Math.Max(0, Math.Min(100, 100.0 * (tot - di) / tot));
                }
                _pi = i; _pk = k; _pu = u;
            }
            MEMSTAT m = new MEMSTAT();
            if (GlobalMemoryStatusEx(m)) {
                s.Ram = m.dwMemoryLoad;
                s.RamTotalGB = m.ullTotalPhys / 1073741824.0;
                s.RamUsedGB = (m.ullTotalPhys - m.ullAvailPhys) / 1073741824.0;
            }
            string line = _smiLine;
            if (line != null) {
                string[] v = line.Split(',');
                if (v.Length >= 9) {
                    s.GpuName = v[0].Trim(); s.GpuTemp = N(v[1]); s.GpuUsage = N(v[2]); s.GpuPower = N(v[3]); s.GpuPowerLimit = N(v[4]);
                    s.GpuMemUsed = N(v[5]); s.GpuMemTotal = N(v[6]); s.GpuFan = N(v[7]); s.GpuClock = N(v[8]);
                }
            }
            try {
                DriveInfo d = new DriveInfo(_drive);
                if (d.IsReady && d.TotalSize > 0) { s.DiskUsedPct = 100.0 * (d.TotalSize - d.TotalFreeSpace) / d.TotalSize; s.DiskFreeGB = d.TotalFreeSpace / 1073741824.0; }
            } catch { }
            lock (_lock) {
                s.DiskBusy = _diskBusy; s.DiskRead = _diskRead; s.DiskWrite = _diskWrite;
                s.DiskTemp = _diskTemp; s.DiskTempSource = _diskTempSrc;
                s.CpuTemp = _cpuTemp; s.CpuTempSource = _cpuTempSrc;
            }
            s.DiskName = _diskModel;
            return s;
        }
    }

    // ---------------------------------------------------------------------
    //  Jeu et confort : souris, touches rémanentes, écrans (lecture / réglage)
    // ---------------------------------------------------------------------
    public class DisplayInfo { public string Name = "", Device = ""; public int Width, Height, Hz, MaxHz, MaxWidth, MaxHeight; }
    public static class Tweaks {
        [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, int[] data, uint winIni);
        [StructLayout(LayoutKind.Sequential)] struct STICKYKEYS { public uint cbSize; public uint dwFlags; }
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfo")] static extern bool SpiSticky(uint action, uint param, ref STICKYKEYS data, uint winIni);
        const uint SPIF_SAVE = 3;   // enregistre dans le profil et prévient les programmes

        public static bool MouseAccel() { int[] m = new int[3]; SystemParametersInfo(3, 0, m, 0); return m[2] != 0; }
        public static bool SetMouseAccel(bool on) { return SystemParametersInfo(4, 0, on ? new int[] { 6, 10, 1 } : new int[] { 0, 0, 0 }, SPIF_SAVE); }
        public static bool StickyHotkey() { STICKYKEYS s = new STICKYKEYS(); s.cbSize = 8; SpiSticky(0x3A, 8, ref s, 0); return (s.dwFlags & 4) != 0; }
        public static bool SetStickyHotkey(bool on) {
            STICKYKEYS s = new STICKYKEYS(); s.cbSize = 8;
            if (!SpiSticky(0x3A, 8, ref s, 0)) return false;
            s.dwFlags = on ? (s.dwFlags | 4u) : (s.dwFlags & ~4u);
            return SpiSticky(0x3B, 8, ref s, SPIF_SAVE);
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DISPLAY_DEVICE {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DEVMODE {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
            public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
            public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels;
            public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
            public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE dd, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE dm);

        public static List<DisplayInfo> Displays() {
            List<DisplayInfo> list = new List<DisplayInfo>();
            for (uint i = 0; i < 16; i++) {
                DISPLAY_DEVICE dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
                if ((dd.StateFlags & 1) == 0) continue;            // pas relié au bureau
                DEVMODE cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
                if (!EnumDisplaySettings(dd.DeviceName, -1, ref cur)) continue;
                DisplayInfo d = new DisplayInfo();
                d.Device = dd.DeviceName; d.Width = cur.dmPelsWidth; d.Height = cur.dmPelsHeight; d.Hz = cur.dmDisplayFrequency;
                DISPLAY_DEVICE mon = new DISPLAY_DEVICE(); mon.cb = dd.cb;
                if (EnumDisplayDevices(dd.DeviceName, 0, ref mon, 0)) d.Name = mon.DeviceString ?? "";
                DEVMODE m = new DEVMODE(); m.dmSize = cur.dmSize;
                for (int k = 0; EnumDisplaySettings(dd.DeviceName, k, ref m); k++) {
                    if (m.dmPelsWidth == d.Width && m.dmPelsHeight == d.Height && m.dmDisplayFrequency > d.MaxHz) d.MaxHz = m.dmDisplayFrequency;
                    if ((long)m.dmPelsWidth * m.dmPelsHeight > (long)d.MaxWidth * d.MaxHeight) { d.MaxWidth = m.dmPelsWidth; d.MaxHeight = m.dmPelsHeight; }
                }
                list.Add(d);
            }
            return list;
        }
    }

    // ---------------------------------------------------------------------
    //  Test de stabilité : charge processeur, RAM et carte graphique, avec
    //  arrêt automatique si les températures dépassent les seuils.
    // ---------------------------------------------------------------------
    public static class StressTest {
        public static volatile bool Running;
        public static volatile string StopReason = "";     // "", "time", "user", "cputemp", "gputemp", "gpudriver"
        public static volatile string GpuStatus = "", RamStatus = "";
        public static bool UseCpu, UseRam, UseGpu;
        public static DateTime Started, Ends, StoppedAt;
        public static double CpuLimit = 90, GpuLimit = 87;
        public static double MaxCpuTemp = -1, MaxGpuTemp = -1, MaxGpuPower = -1, GpuPowerLimit = -1, MaxCpu = -1, MaxGpuUsage = -1;
        public static long RamErrors, RamPasses;
        public static double RamGB;
        public static SensorSnapshot Last = new SensorSnapshot();
        static readonly List<double[]> _hist = new List<double[]>();
        static volatile bool _run;
        static List<Thread> _threads = new List<Thread>();
        static string _marker;
        public static double Sink;
        public static uint GpuMaxGroups = 65535;   // plafond de charge (réduit pour les essais)

        public static void Start(bool cpu, bool ram, bool gpu, int minutes, string marker, string smiPath) {
            if (Running) return;
            UseCpu = cpu; UseRam = ram; UseGpu = gpu;
            StopReason = ""; GpuStatus = gpu ? "Démarrage…" : ""; RamStatus = ram ? "Réservation de la mémoire…" : "";
            MaxCpuTemp = MaxGpuTemp = MaxGpuPower = GpuPowerLimit = MaxCpu = MaxGpuUsage = -1;
            RamErrors = 0; RamPasses = 0; RamGB = 0;
            lock (_hist) _hist.Clear();
            _marker = marker;
            Started = DateTime.Now; Ends = Started.AddMinutes(minutes);
            _run = true; Running = true;
            _threads.Clear();
            LiveSensors.Start(smiPath, Path.GetPathRoot(Environment.SystemDirectory));
            WriteMarker();
            if (cpu) for (int i = 0; i < Environment.ProcessorCount; i++) Spawn(CpuWork, ThreadPriority.BelowNormal);
            if (ram) Spawn(RamWork, ThreadPriority.BelowNormal);
            if (gpu) Spawn(GpuWork, ThreadPriority.Normal);
            Spawn(Monitor, ThreadPriority.AboveNormal);
        }

        public static void Stop(string reason) {
            if (!_run) return;
            if (StopReason == "") StopReason = reason;
            _run = false;
        }

        static void Spawn(ThreadStart f, ThreadPriority p) {
            Thread t = new Thread(f); t.IsBackground = true; t.Priority = p; t.Start(); _threads.Add(t);
        }

        // Historique pour les courbes : 0 = temp. CPU, 1 = temp. GPU, 2 = conso GPU, 3 = charge CPU
        public static double[] History(int col) {
            lock (_hist) { double[] r = new double[_hist.Count]; for (int i = 0; i < r.Length; i++) r[i] = _hist[i][col]; return r; }
        }

        static void WriteMarker() {
            try {
                File.WriteAllText(_marker, string.Format(CultureInfo.InvariantCulture,
                    "start={0:yyyy-MM-ddTHH:mm:ss}\nlast={1:yyyy-MM-ddTHH:mm:ss}\ncpu={2}\nram={3}\ngpu={4}\nmaxcputemp={5:0}\nmaxgputemp={6:0}\nmaxgpupower={7:0}\nramerrors={8}\n",
                    Started, DateTime.Now, UseCpu ? 1 : 0, UseRam ? 1 : 0, UseGpu ? 1 : 0, MaxCpuTemp, MaxGpuTemp, MaxGpuPower, RamErrors));
            } catch { }
        }

        static void Monitor() {
            int hotCpu = 0, hotGpu = 0, tick = 0;
            LiveSensors.Read();
            while (_run) {
                Thread.Sleep(1000);
                SensorSnapshot s = LiveSensors.Read();
                Last = s;
                if (s.CpuTemp > MaxCpuTemp) MaxCpuTemp = s.CpuTemp;
                if (s.GpuTemp > MaxGpuTemp) MaxGpuTemp = s.GpuTemp;
                if (s.GpuPower > MaxGpuPower) MaxGpuPower = s.GpuPower;
                if (s.GpuPowerLimit > 0) GpuPowerLimit = s.GpuPowerLimit;
                if (s.Cpu > MaxCpu && tick > 2) MaxCpu = s.Cpu;
                if (s.GpuUsage > MaxGpuUsage) MaxGpuUsage = s.GpuUsage;
                hotCpu = s.CpuTemp >= CpuLimit ? hotCpu + 1 : 0;
                hotGpu = s.GpuTemp >= GpuLimit ? hotGpu + 1 : 0;
                if (hotCpu >= 2) Stop("cputemp");
                else if (hotGpu >= 2) Stop("gputemp");
                else if (DateTime.Now >= Ends) Stop("time");
                tick++;
                if (tick % 2 == 0) lock (_hist) _hist.Add(new double[] { s.CpuTemp, s.GpuTemp, s.GpuPower, s.Cpu });
                if (tick % 5 == 0) WriteMarker();
            }
            foreach (Thread t in _threads) if (t != Thread.CurrentThread) { try { t.Join(5000); } catch { } }
            StoppedAt = DateTime.Now;
            LiveSensors.Stop();
            try { File.Delete(_marker); } catch { }
            Running = false;
        }

        // --- Processeur : calcul flottant en continu sur chaque cœur logique ---
        static void CpuWork() {
            double a = 1.1, b = 1.2, c = 1.3, d = 1.4, e = 1.5, f = 1.6, g = 1.7, h = 1.8;
            while (_run) {
                for (int i = 0; i < 2000000; i++) {
                    a = a * 0.999999 + 0.000001; b = b * 0.999998 + 0.000002;
                    c = c * 0.999997 + 0.000003; d = d * 0.999996 + 0.000004;
                    e = e * 0.999995 + 0.000005; f = f * 0.999994 + 0.000006;
                    g = g * 0.999993 + 0.000007; h = h * 0.999992 + 0.000008;
                    if ((i & 1023) == 0) a += Math.Sqrt(b + c) * 1e-12;
                }
                Sink = a + b + c + d + e + f + g + h;
            }
        }

        // --- Mémoire vive : écrit un motif puis le relit ; toute différence est une erreur ---
        static void RamWork() {
            List<long[]> blocks = new List<long[]>();
            try {
                SensorSnapshot s = LiveSensors.Read();
                double availGB = s.RamTotalGB - s.RamUsedGB;
                double targetGB = Math.Min(availGB - 2.5, s.RamTotalGB * 0.7);
                if (targetGB < 0.5) targetGB = 0.5;
                const int blockLongs = 32 * 1024 * 1024;      // 256 Mo
                int count = (int)(targetGB * 4);
                for (int i = 0; i < count && _run; i++) {
                    try { blocks.Add(new long[blockLongs]); } catch (OutOfMemoryException) { break; }
                    RamGB = blocks.Count / 4.0;
                }
                RamStatus = "";
                ulong seed = 0x9E3779B97F4A7C15UL;
                while (_run) {
                    seed = seed * 6364136223846793005UL + 1442695040888963407UL;
                    for (int bi = 0; bi < blocks.Count && _run; bi++) {
                        long[] blk = blocks[bi];
                        ulong x = seed ^ (ulong)bi;
                        for (int j = 0; j < blk.Length; j++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; blk[j] = (long)x; }
                    }
                    for (int bi = 0; bi < blocks.Count && _run; bi++) {
                        long[] blk = blocks[bi];
                        ulong x = seed ^ (ulong)bi;
                        for (int j = 0; j < blk.Length; j++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; if (blk[j] != (long)x) Interlocked.Increment(ref RamErrors); }
                    }
                    if (_run) Interlocked.Increment(ref RamPasses);
                }
            } catch (Exception ex) { RamStatus = "Erreur : " + ex.Message; }
            finally { blocks.Clear(); blocks = null; GC.Collect(); }
        }

        // --- Carte graphique : calcul Direct3D 11 (compute shader), par lots courts ---
        [DllImport("d3d11.dll")] static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr levels, uint numLevels, uint sdk, out IntPtr device, out int level, out IntPtr context);
        [DllImport("d3dcompiler_47.dll")] static extern int D3DCompile([MarshalAs(UnmanagedType.LPStr)] string src, IntPtr size, IntPtr name, IntPtr defines, IntPtr include, [MarshalAs(UnmanagedType.LPStr)] string entry, [MarshalAs(UnmanagedType.LPStr)] string target, uint f1, uint f2, out IntPtr code, out IntPtr errors);
        [StructLayout(LayoutKind.Sequential)] struct BUFFER_DESC { public uint ByteWidth; public int Usage; public uint BindFlags, CPUAccessFlags, MiscFlags, StructureByteStride; }
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint FRelease(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate IntPtr FBlobPtr(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FCreateBuffer(IntPtr self, ref BUFFER_DESC d, IntPtr init, out IntPtr buf);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FCreateUav(IntPtr self, IntPtr res, int[] desc, out IntPtr uav);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FCreateCs(IntPtr self, IntPtr code, IntPtr len, IntPtr linkage, out IntPtr cs);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FCreateQuery(IntPtr self, int[] desc, out IntPtr q);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void FCsSetShader(IntPtr self, IntPtr cs, IntPtr inst, uint n);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void FCsSetUavs(IntPtr self, uint start, uint n, IntPtr[] uavs, IntPtr counts);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void FDispatch(IntPtr self, uint x, uint y, uint z);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void FEnd(IntPtr self, IntPtr q);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int FGetData(IntPtr self, IntPtr q, IntPtr data, uint size, uint flags);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void FFlush(IntPtr self);
        static T Fn<T>(IntPtr obj, int slot) where T : class {
            IntPtr vt = Marshal.ReadIntPtr(obj);
            return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vt, slot * IntPtr.Size), typeof(T));
        }
        static void Rel(IntPtr p) { if (p != IntPtr.Zero) try { Fn<FRelease>(p, 2)(p); } catch { } }

        const string Shader = @"
RWBuffer<float> o : register(u0);
[numthreads(256,1,1)]
void main(uint3 id : SV_DispatchThreadID) {
    float4 a = float4(id.x * 1e-7, 0.5, 0.25, 0.125);
    float4 b = a + 0.3, c = a + 0.6, d = a + 0.9;
    [loop] for (int i = 0; i < 2048; i++) {
        a = mad(a, 0.9999, 0.0001); b = mad(b, 0.9998, 0.0002);
        c = mad(c, 0.9997, 0.0003); d = mad(d, 0.9996, 0.0004);
        a = mad(b, c, a) * 0.5;
    }
    float s = dot(a + b, c + d);
    if (s == 1.2345) o[id.x & 1023] = s;
}";

        static void GpuWork() {
            IntPtr dev = IntPtr.Zero, ctx = IntPtr.Zero, code = IntPtr.Zero, err = IntPtr.Zero, cs = IntPtr.Zero, buf = IntPtr.Zero, uav = IntPtr.Zero;
            IntPtr[] q = new IntPtr[2];
            try {
                int lvl;
                int hr = D3D11CreateDevice(IntPtr.Zero, 1, IntPtr.Zero, 0, IntPtr.Zero, 0, 7, out dev, out lvl, out ctx);
                if (hr < 0) { GpuStatus = "Erreur : Direct3D 11 indisponible (0x" + hr.ToString("X8") + ")"; return; }
                try { hr = D3DCompile(Shader, (IntPtr)Shader.Length, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, "main", "cs_5_0", 0, 0, out code, out err); }
                catch (DllNotFoundException) { GpuStatus = "Erreur : compilateur Direct3D introuvable"; return; }
                if (hr < 0) { GpuStatus = "Erreur : compilation du test (0x" + hr.ToString("X8") + ")"; return; }
                IntPtr cptr = Fn<FBlobPtr>(code, 3)(code), clen = Fn<FBlobPtr>(code, 4)(code);
                hr = Fn<FCreateCs>(dev, 18)(dev, cptr, clen, IntPtr.Zero, out cs);
                if (hr < 0) { GpuStatus = "Erreur : carte graphique incompatible (0x" + hr.ToString("X8") + ")"; return; }
                BUFFER_DESC bd = new BUFFER_DESC { ByteWidth = 4096, Usage = 0, BindFlags = 0x80 };
                hr = Fn<FCreateBuffer>(dev, 3)(dev, ref bd, IntPtr.Zero, out buf);
                if (hr < 0) { GpuStatus = "Erreur : mémoire graphique (0x" + hr.ToString("X8") + ")"; return; }
                hr = Fn<FCreateUav>(dev, 8)(dev, buf, new int[] { 41, 1, 0, 1024, 0 }, out uav);   // R32_FLOAT, tampon de 1024 éléments
                if (hr < 0) { GpuStatus = "Erreur : vue mémoire (0x" + hr.ToString("X8") + ")"; return; }
                for (int i = 0; i < 2; i++) { hr = Fn<FCreateQuery>(dev, 24)(dev, new int[] { 0, 0 }, out q[i]); if (hr < 0) { GpuStatus = "Erreur : requête (0x" + hr.ToString("X8") + ")"; return; } }
                Fn<FCsSetShader>(ctx, 69)(ctx, cs, IntPtr.Zero, 0);
                Fn<FCsSetUavs>(ctx, 68)(ctx, 0, 1, new IntPtr[] { uav }, IntPtr.Zero);
                FDispatch dispatch = Fn<FDispatch>(ctx, 41); FEnd end = Fn<FEnd>(ctx, 28); FGetData getData = Fn<FGetData>(ctx, 29); FFlush flush = Fn<FFlush>(ctx, 111);
                uint groups = Math.Min(64u, GpuMaxGroups);
                bool[] pending = new bool[2];
                int cur = 0;
                Stopwatch sw = Stopwatch.StartNew();
                GpuStatus = "";
                while (_run) {
                    dispatch(ctx, groups, 1, 1);
                    end(ctx, q[cur]); flush(ctx); pending[cur] = true;
                    int prev = 1 - cur;
                    if (pending[prev]) {
                        int r;
                        while ((r = getData(ctx, q[prev], IntPtr.Zero, 0, 0)) == 1) { if (!_run) break; Thread.Sleep(1); }
                        if (r < 0) { GpuStatus = "Erreur : le pilote de la carte graphique a planté (0x" + r.ToString("X8") + ")"; Stop("gpudriver"); break; }
                        pending[prev] = false;
                        double ms = sw.Elapsed.TotalMilliseconds; sw.Restart();
                        // Lots de 15 à 40 ms : la carte reste chargée sans dépasser le délai de sécurité de Windows (2 s)
                        if (ms < 15 && groups < GpuMaxGroups) groups = Math.Min(GpuMaxGroups, groups * 2);
                        else if (ms > 40 && groups > 1) groups = Math.Max(1u, groups / 2);
                    }
                    cur = prev;
                }
                // attendre la fin des lots en cours avant de libérer
                for (int i = 0; i < 2; i++) if (pending[i]) { int w = 0; while (getData(ctx, q[i], IntPtr.Zero, 0, 0) == 1 && w++ < 3000) Thread.Sleep(1); }
            } catch (Exception ex) { GpuStatus = "Erreur : " + ex.Message; }
            finally {
                Rel(q[0]); Rel(q[1]); Rel(uav); Rel(buf); Rel(cs); Rel(code); Rel(err); Rel(ctx); Rel(dev);
                if (GpuStatus.StartsWith("Erreur") && !UseCpu && !UseRam) Stop("gpuerror");
            }
        }
    }

    // ---------------------------------------------------------------------
    //  Boîte noire : enregistre l'état du PC toutes les 2 s (icône de notification)
    // ---------------------------------------------------------------------
    public static class BlackBox {
        [StructLayout(LayoutKind.Sequential)] struct FILETIME { public uint Low; public uint High; }
        [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);
        [StructLayout(LayoutKind.Sequential)]
        class MEMORYSTATUSEX {
            public uint dwLength; public uint dwMemoryLoad; public ulong ullTotalPhys; public ulong ullAvailPhys;
            public ulong ullTotalPageFile; public ulong ullAvailPageFile; public ulong ullTotalVirtual; public ulong ullAvailVirtual; public ulong ullAvailExtendedVirtual;
            public MEMORYSTATUSEX() { dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)); }
        }
        [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX m);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);

        public const string MutexName = @"Local\PCDoctorBlackBox";
        public const string StopEventName = @"Local\PCDoctorBlackBoxStop";
        public const string Header = "time;gpu_temp;gpu_power;gpu_limit;gpu_clock;gpu_usage;cpu;ram;app;cpu_temp;disk_temp;disk_busy";

        static ulong U(FILETIME f) { return ((ulong)f.High << 32) | f.Low; }
        static ulong _pIdle, _pKernel, _pUser;
        public static double CpuPercent() {
            FILETIME i, k, u;
            if (!GetSystemTimes(out i, out k, out u)) return -1;
            ulong idle = U(i), kern = U(k), usr = U(u);
            double r = -1;
            if (_pKernel != 0) {
                ulong di = idle - _pIdle, total = (kern - _pKernel) + (usr - _pUser);   // le temps noyau inclut le temps inactif
                if (total > 0) r = Math.Max(0, Math.Min(100, 100.0 * (total - di) / total));
            }
            _pIdle = idle; _pKernel = kern; _pUser = usr;
            return r;
        }
        public static int RamPercent() { MEMORYSTATUSEX m = new MEMORYSTATUSEX(); return GlobalMemoryStatusEx(m) ? (int)m.dwMemoryLoad : -1; }
        public static string ForegroundApp() {
            try {
                uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
                if (pid == 0) return "";
                using (Process p = Process.GetProcessById((int)pid)) return p.ProcessName.Replace(";", "");
            } catch { return ""; }
        }

        public static bool IsRunning() {
            Mutex m;
            if (Mutex.TryOpenExisting(MutexName, out m)) { m.Dispose(); return true; }
            return false;
        }
        public static bool RequestStop() {
            EventWaitHandle e;
            if (EventWaitHandle.TryOpenExisting(StopEventName, out e)) { e.Set(); e.Dispose(); return true; }
            return false;
        }

        static Process _smi; static volatile string _smiLine; static string _smiPath;
        static void StartSmi() {
            if (string.IsNullOrEmpty(_smiPath) || !File.Exists(_smiPath)) return;
            try {
                ProcessStartInfo psi = new ProcessStartInfo(_smiPath, "--query-gpu=temperature.gpu,power.draw,power.limit,clocks.gr,utilization.gpu --format=csv,noheader,nounits -lms 2000");
                psi.UseShellExecute = false; psi.RedirectStandardOutput = true; psi.CreateNoWindow = true;
                _smi = Process.Start(psi);
                _smi.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null && e.Data.IndexOf(',') > 0) _smiLine = e.Data; };
                _smi.BeginOutputReadLine();
            } catch { _smi = null; }
        }

        // --- Lecture des enregistrements (utilisée par l'interface) ---
        static IEnumerable<string> Lines(string dir, DateTime day) {
            string file = Path.Combine(dir, day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) + ".csv");
            if (!File.Exists(file)) yield break;
            using (FileStream fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (StreamReader sr = new StreamReader(fs, Encoding.UTF8)) {
                string l;
                while ((l = sr.ReadLine()) != null) { if (l.Length >= 19 && l[0] != 't') yield return l; }
            }
        }
        public static List<string> ReadRange(string dir, DateTime from, DateTime to) {
            List<string> res = new List<string>();
            string a = from.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture), b = to.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture);
            for (DateTime d = from.Date; d <= to.Date; d = d.AddDays(1)) {
                foreach (string l in Lines(dir, d)) {
                    string ts = l.Substring(0, 19);
                    if (string.CompareOrdinal(ts, a) >= 0 && string.CompareOrdinal(ts, b) <= 0) res.Add(l);
                }
            }
            return res;
        }
        public static string LastBefore(string dir, DateTime t, int hoursBack) {
            string limit = t.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture);
            string start = t.AddHours(-hoursBack).ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture);
            string last = null;
            for (DateTime d = t.AddHours(-hoursBack).Date; d <= t.Date; d = d.AddDays(1)) {
                foreach (string l in Lines(dir, d)) {
                    string ts = l.Substring(0, 19);
                    if (string.CompareOrdinal(ts, start) >= 0 && string.CompareOrdinal(ts, limit) < 0) last = l;
                }
            }
            return last;
        }

        static NotifyIcon _tray; static System.Windows.Forms.Timer _timer; static bool _paused;
        static string _dir, _settings, _openExe, _openArgs;
        static int _alertTemp = 85; static bool _alerts = true;
        static DateTime _lastAlertGpu = DateTime.MinValue, _lastAlertRam = DateTime.MinValue, _lastSettings = DateTime.MinValue;
        static int _hotCount, _ramCount;
        static EventWaitHandle _stop;

        public static int Run(string dataDir, string settingsPath, string openExe, string openArgs, string iconPng, string smiPath) {
            bool created;
            using (Mutex mutex = new Mutex(true, MutexName, out created)) {
                if (!created) return 1;   // déjà lancée
                _dir = dataDir; _settings = settingsPath; _smiPath = smiPath; _openExe = openExe; _openArgs = openArgs;
                Directory.CreateDirectory(_dir);
                Cleanup();
                LoadSettings();
                _stop = new EventWaitHandle(false, EventResetMode.AutoReset, StopEventName);
                StartSmi();
                CpuPercent();
                // Températures processeur (Core Temp / HWiNFO) et SSD (SMART / HWiNFO), activité du disque système
                LiveSensors.Start(null, Path.GetPathRoot(Environment.SystemDirectory));

                Application.EnableVisualStyles();
                _tray = new NotifyIcon();
                try {
                    using (Bitmap b = new Bitmap(iconPng))
                    using (Bitmap s = new Bitmap(b, new Size(32, 32))) {
                        IntPtr h = s.GetHicon();
                        _tray.Icon = (Icon)Icon.FromHandle(h).Clone();
                        DestroyIcon(h);
                    }
                } catch { _tray.Icon = SystemIcons.Application; }
                _tray.Text = "PC Doctor : boîte noire active";
                ContextMenuStrip menu = new ContextMenuStrip();
                menu.Items.Add("Ouvrir PC Doctor", null, delegate { OpenApp(); });
                ToolStripMenuItem pause = new ToolStripMenuItem("Suspendre l'enregistrement");
                pause.Click += delegate {
                    _paused = !_paused;
                    pause.Text = _paused ? "Reprendre l'enregistrement" : "Suspendre l'enregistrement";
                    _tray.Text = _paused ? "PC Doctor : boîte noire en pause" : "PC Doctor : boîte noire active";
                };
                menu.Items.Add(pause);
                menu.Items.Add(new ToolStripSeparator());
                menu.Items.Add("Arrêter la surveillance", null, delegate { Application.Exit(); });
                _tray.ContextMenuStrip = menu;
                _tray.DoubleClick += delegate { OpenApp(); };
                _tray.Visible = true;

                _timer = new System.Windows.Forms.Timer();
                _timer.Interval = 2000;
                _timer.Tick += delegate { Tick(); };
                _timer.Start();
                Application.Run();

                _timer.Stop();
                _tray.Visible = false;
                _tray.Dispose();
                try { if (_smi != null && !_smi.HasExited) _smi.Kill(); } catch { }
                LiveSensors.Stop();
                return 0;
            }
        }

        static void OpenApp() {
            try {
                ProcessStartInfo psi = new ProcessStartInfo(_openExe, _openArgs);
                psi.UseShellExecute = false; psi.CreateNoWindow = true;
                Process.Start(psi);
            } catch { }
        }

        static string Num(string s) {
            double d;
            return double.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out d) ? d.ToString("0.#", CultureInfo.InvariantCulture) : "";
        }

        static void Tick() {
            if (_stop.WaitOne(0)) { Application.Exit(); return; }
            if ((DateTime.Now - _lastSettings).TotalSeconds > 60) LoadSettings();
            if (_smi != null && _smi.HasExited) { _smi = null; _smiLine = null; StartSmi(); }

            double cpu = CpuPercent();
            int ram = RamPercent();
            string app = ForegroundApp();
            SensorSnapshot ls = LiveSensors.Read();
            string gt = "", gp = "", gl = "", gc = "", gu = "";
            double gtemp = -1;
            string line = _smiLine;
            if (line != null) {
                string[] v = line.Split(',');
                if (v.Length >= 5) {
                    gt = Num(v[0]); gp = Num(v[1]); gl = Num(v[2]); gc = Num(v[3]); gu = Num(v[4]);
                    if (gt.Length > 0) gtemp = double.Parse(gt, CultureInfo.InvariantCulture);
                }
            }
            if (!_paused) {
                DateTime now = DateTime.Now;
                string row = string.Format(CultureInfo.InvariantCulture, "{0:yyyy-MM-ddTHH:mm:ss};{1};{2};{3};{4};{5};{6};{7};{8};{9};{10};{11}",
                    now, gt, gp, gl, gc, gu, cpu < 0 ? "" : cpu.ToString("0", CultureInfo.InvariantCulture), ram < 0 ? "" : ram.ToString(CultureInfo.InvariantCulture), app,
                    ls.CpuTemp < 0 ? "" : ls.CpuTemp.ToString("0.#", CultureInfo.InvariantCulture),
                    ls.DiskTemp < 0 ? "" : ls.DiskTemp.ToString("0", CultureInfo.InvariantCulture),
                    ls.DiskBusy < 0 ? "" : ls.DiskBusy.ToString("0", CultureInfo.InvariantCulture));
                Write(now, row);
            }
            Alerts(gtemp, ram);
            CpuAlert(ls.CpuTemp);
        }

        static void Write(DateTime now, string row) {
            string file = Path.Combine(_dir, now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) + ".csv");
            try {
                bool isNew = !File.Exists(file);
                using (FileStream fs = new FileStream(file, FileMode.Append, FileAccess.Write, FileShare.ReadWrite)) {
                    byte[] b = Encoding.UTF8.GetBytes((isNew ? Header + "\r\n" : "") + row + "\r\n");
                    fs.Write(b, 0, b.Length);
                    fs.Flush(true);   // écrit physiquement sur le disque : les données survivent à une coupure
                }
            } catch { }
        }

        static void Alerts(double gtemp, int ram) {
            if (!_alerts) return;
            _hotCount = gtemp >= _alertTemp ? _hotCount + 1 : 0;
            if (_hotCount >= 2 && (DateTime.Now - _lastAlertGpu).TotalMinutes >= 10) {
                _lastAlertGpu = DateTime.Now;
                _tray.ShowBalloonTip(10000, "Carte graphique très chaude",
                    string.Format(CultureInfo.InvariantCulture, "{0:0} °C (seuil d'alerte : {1} °C). Vérifiez la ventilation et la poussière.", gtemp, _alertTemp), ToolTipIcon.Warning);
            }
            _ramCount = ram >= 95 ? _ramCount + 1 : 0;
            if (_ramCount >= 5 && (DateTime.Now - _lastAlertRam).TotalMinutes >= 15) {
                _lastAlertRam = DateTime.Now;
                _tray.ShowBalloonTip(10000, "Mémoire vive saturée", "La RAM est utilisée à " + ram + " % : le PC va ralentir. Fermez des programmes.", ToolTipIcon.Warning);
            }
        }

        static int _cpuHot; static DateTime _lastAlertCpu = DateTime.MinValue;
        static void CpuAlert(double t) {
            if (!_alerts) return;
            _cpuHot = t >= 90 ? _cpuHot + 1 : 0;
            if (_cpuHot >= 3 && (DateTime.Now - _lastAlertCpu).TotalMinutes >= 10) {
                _lastAlertCpu = DateTime.Now;
                _tray.ShowBalloonTip(10000, "Processeur très chaud",
                    string.Format(CultureInfo.InvariantCulture, "{0:0} °C. Vérifiez le ventirad, la poussière et la pâte thermique.", t), ToolTipIcon.Warning);
            }
        }

        static void LoadSettings() {
            _lastSettings = DateTime.Now;
            try {
                if (!File.Exists(_settings)) return;
                foreach (string l in File.ReadAllLines(_settings)) {
                    int i = l.IndexOf('=');
                    if (i < 0) continue;
                    string k = l.Substring(0, i).Trim(), v = l.Substring(i + 1).Trim();
                    int n;
                    if (k == "AlertGpuTemp" && int.TryParse(v, out n) && n >= 50 && n <= 110) _alertTemp = n;
                    if (k == "Alerts") _alerts = v != "0";
                }
            } catch { }
        }

        static void Cleanup() {
            try { foreach (string f in Directory.GetFiles(_dir, "*.csv")) if (File.GetLastWriteTime(f) < DateTime.Now.AddDays(-8)) File.Delete(f); } catch { }
        }
    }

    public class DirNode {
        public string Name; public string FullPath;
        public long Size; public long Files; public long Folders; public long OwnFilesSize;
        public bool Denied; public DirNode Parent;
        public List<DirNode> Children = new List<DirNode>();
    }
    public class FileEntry { public string Name; public string FullPath; public string Folder; public long Size; public DateTime Modified; }
    public class ExtStat { public string Ext; public long Size; public long Count; }

    public static class DiskScanner {
        public static volatile bool Running;
        public static volatile bool Cancel;
        public static long FilesScanned;
        public static long BytesScanned;
        public static long DeniedCount;
        public static volatile string CurrentPath = "";
        public static DirNode Root;
        public static List<FileEntry> TopFiles;
        public static List<ExtStat> Extensions;
        public static string Error;

        static List<FileEntry> _files;
        static Dictionary<string, ExtStat> _ext;
        static int _topN;
        static long _minKeep;

        // Attributs "fichier dans le cloud" (OneDrive...) : RecallOnDataAccess, RecallOnOpen, Pinned, Unpinned
        const int CloudAttrs = 0x400000 | 0x40000 | 0x80000 | 0x100000;
        const int NotLocalAttrs = 0x400000 | 0x1000;   // RecallOnDataAccess | Offline

        public static void Start(string root, int topN) {
            if (Running) return;
            Running = true; Cancel = false;
            FilesScanned = 0; BytesScanned = 0; DeniedCount = 0;
            Root = null; TopFiles = null; Extensions = null; Error = null;
            _topN = topN; _minKeep = 0;
            Thread t = new Thread(new ThreadStart(delegate() { Run(root); }), 32 * 1024 * 1024);
            t.IsBackground = true;
            t.Start();
        }

        static void Run(string root) {
            try {
                _files = new List<FileEntry>();
                _ext = new Dictionary<string, ExtStat>(StringComparer.OrdinalIgnoreCase);
                DirectoryInfo di = new DirectoryInfo(root);
                DirNode n = new DirNode();
                n.Name = di.FullName; n.FullPath = di.FullName;
                Scan(di, n, 0);
                TrimFiles();
                TopFiles = _files;
                List<ExtStat> e = new List<ExtStat>(_ext.Values);
                e.Sort(delegate(ExtStat a, ExtStat b) { return b.Size.CompareTo(a.Size); });
                Extensions = e;
                SortTree(n);
                Root = n;
            } catch (Exception ex) { Error = ex.Message; }
            finally { Running = false; }
        }

        static bool ShouldFollow(string fullPath, int attr) {
            if ((attr & (int)FileAttributes.ReparsePoint) == 0) return true;
            // Jonctions de compatibilité Windows ("Application Data", "Documents and Settings"...) : on ne suit pas
            if ((attr & ((int)FileAttributes.Hidden | (int)FileAttributes.System)) != 0) return false;
            // Dossiers OneDrive / cloud : on suit
            if ((attr & CloudAttrs) != 0) return true;
            if (fullPath.IndexOf("\\OneDrive", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            return false; // liens symboliques : évite les doubles comptages et les boucles
        }

        static void Scan(DirectoryInfo di, DirNode node, int depth) {
            if (Cancel || depth > 200) return;
            CurrentPath = node.FullPath;
            FileSystemInfo[] items;
            try { items = di.GetFileSystemInfos(); }
            catch { node.Denied = true; Interlocked.Increment(ref DeniedCount); return; }
            foreach (FileSystemInfo fsi in items) {
                if (Cancel) return;
                try {
                    int attr = (int)fsi.Attributes;
                    if ((attr & (int)FileAttributes.Directory) != 0) {
                        if (!ShouldFollow(fsi.FullName, attr)) continue;
                        DirNode c = new DirNode();
                        c.Name = fsi.Name; c.FullPath = fsi.FullName; c.Parent = node;
                        node.Children.Add(c);
                        Scan((DirectoryInfo)fsi, c, depth + 1);
                        node.Size += c.Size; node.Files += c.Files; node.Folders += 1 + c.Folders;
                    } else {
                        FileInfo fi = (FileInfo)fsi;
                        long len = ((attr & NotLocalAttrs) != 0) ? 0 : fi.Length;
                        node.Size += len; node.Files++;
                        FilesScanned++; BytesScanned += len;
                        AddFile(fi, len);
                    }
                } catch { }
            }
        }

        static void AddFile(FileInfo fi, long len) {
            string name = fi.Name;
            int dot = name.LastIndexOf('.');
            string ext = (dot > 0 && dot < name.Length - 1) ? name.Substring(dot).ToLowerInvariant() : "(sans extension)";
            ExtStat es;
            if (!_ext.TryGetValue(ext, out es)) { es = new ExtStat(); es.Ext = ext; _ext[ext] = es; }
            es.Size += len; es.Count++;
            if (len <= _minKeep) return;
            FileEntry f = new FileEntry();
            f.Name = name; f.FullPath = fi.FullName; f.Size = len;
            try { f.Folder = fi.DirectoryName; } catch { f.Folder = ""; }
            try { f.Modified = fi.LastWriteTime; } catch { }
            _files.Add(f);
            if (_files.Count > _topN * 4) TrimFiles();
        }

        static void TrimFiles() {
            _files.Sort(delegate(FileEntry a, FileEntry b) { return b.Size.CompareTo(a.Size); });
            if (_files.Count > _topN) {
                _files.RemoveRange(_topN, _files.Count - _topN);
                _minKeep = _files[_files.Count - 1].Size;
            }
        }

        static void SortTree(DirNode n) {
            long childSum = 0;
            foreach (DirNode c in n.Children) { SortTree(c); childSum += c.Size; }
            n.OwnFilesSize = n.Size - childSum;
            n.Children.Sort(delegate(DirNode a, DirNode b) { return b.Size.CompareTo(a.Size); });
        }

        public static long QuickSize(string path) {
            try {
                DirectoryInfo di = new DirectoryInfo(path);
                if (!di.Exists) return 0;
                return QS(di, 0);
            } catch { return 0; }
        }

        static long QS(DirectoryInfo di, int depth) {
            long total = 0;
            FileSystemInfo[] items;
            try { items = di.GetFileSystemInfos(); } catch { return 0; }
            foreach (FileSystemInfo fsi in items) {
                try {
                    int attr = (int)fsi.Attributes;
                    if ((attr & (int)FileAttributes.Directory) != 0) {
                        if ((attr & (int)FileAttributes.ReparsePoint) != 0 || depth > 100) continue;
                        total += QS((DirectoryInfo)fsi, depth + 1);
                    } else if ((attr & NotLocalAttrs) == 0) {
                        total += ((FileInfo)fsi).Length;
                    }
                } catch { }
            }
            return total;
        }

        public static long FileSize(string path) {
            try {
                string dir = Path.GetDirectoryName(path);
                string name = Path.GetFileName(path);
                FileInfo[] f = new DirectoryInfo(dir).GetFiles(name);
                return f.Length > 0 ? f[0].Length : 0;
            } catch { return 0; }
        }
    }

    public class DriverUpdateRow {
        public bool Selected { get; set; }
        public string Title { get; set; }
        public string Manufacturer { get; set; }
        public string DriverClass { get; set; }
        public string DateText { get; set; }
        public string SizeText { get; set; }
        public string UpdateId { get; set; }
    }

    public static class Cleaner {
        public static int LastFailed;
        public static long CleanFolder(string path) {
            LastFailed = 0;
            long freed = 0;
            DirectoryInfo di = new DirectoryInfo(path);
            if (!di.Exists) return 0;
            CleanRec(di, ref freed, false);
            return freed;
        }
        // Relit les attributs sur le disque juste avant d'agir : évite qu'un dossier remplacé
        // entre-temps par un lien (jonction) fasse supprimer des fichiers ailleurs.
        static bool IsLinkNow(string path) {
            try { return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0; } catch { return true; }
        }
        static void CleanRec(DirectoryInfo di, ref long freed, bool deleteSelf) {
            if (deleteSelf && IsLinkNow(di.FullName)) {
                try { Directory.Delete(di.FullName, false); } catch { LastFailed++; }
                return;
            }
            FileSystemInfo[] items;
            try { items = di.GetFileSystemInfos(); } catch { LastFailed++; return; }
            foreach (FileSystemInfo fsi in items) {
                int attr = (int)fsi.Attributes;
                if ((attr & (int)FileAttributes.Directory) != 0) {
                    if ((attr & (int)FileAttributes.ReparsePoint) != 0 || IsLinkNow(fsi.FullName)) {
                        // lien : on supprime uniquement le lien, jamais la cible
                        try { Directory.Delete(fsi.FullName, false); } catch { LastFailed++; }
                        continue;
                    }
                    CleanRec((DirectoryInfo)fsi, ref freed, true);
                } else {
                    try {
                        long len = ((FileInfo)fsi).Length;
                        if ((attr & (int)FileAttributes.ReadOnly) != 0 && !IsLinkNow(fsi.FullName)) fsi.Attributes = FileAttributes.Normal;
                        fsi.Delete();   // pour un lien, supprime le lien et pas sa cible
                        freed += len;
                    } catch { LastFailed++; }
                }
            }
            if (deleteSelf) { try { di.Delete(false); } catch { } }
        }
    }

    public static class RecycleBin {
        [StructLayout(LayoutKind.Sequential)]
        struct SHQUERYRBINFO { public int cbSize; public long i64Size; public long i64NumItems; }
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        static extern int SHQueryRecycleBin(string pszRootPath, ref SHQUERYRBINFO pSHQueryRBInfo);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        static extern int SHEmptyRecycleBin(IntPtr hwnd, string pszRootPath, uint dwFlags);

        public static long Size() {
            SHQUERYRBINFO i = new SHQUERYRBINFO();
            i.cbSize = Marshal.SizeOf(typeof(SHQUERYRBINFO));
            return SHQueryRecycleBin(null, ref i) == 0 ? i.i64Size : 0;
        }
        public static long Count() {
            SHQUERYRBINFO i = new SHQUERYRBINFO();
            i.cbSize = Marshal.SizeOf(typeof(SHQUERYRBINFO));
            return SHQueryRecycleBin(null, ref i) == 0 ? i.i64NumItems : 0;
        }
        public static bool Empty() {
            // SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND
            return SHEmptyRecycleBin(IntPtr.Zero, null, 0x1 | 0x2 | 0x4) == 0;
        }
    }
}
'@
if (-not ('PCDoctor.DiskScanner' -as [type])) { Add-Type -TypeDefinition $csharp -Language CSharp -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Management, System.Core }

# ---------------------------------------------------------------------------
#  Réglages partagés (appli + boîte noire) : %LOCALAPPDATA%\PCDoctor\settings.ini
# ---------------------------------------------------------------------------
$script:AppVersion = '2.9.0'
$script:Repo = 'doninj/pc-doctor'
$script:SettingsFile = Join-Path $script:LogDir 'settings.ini'
$script:BlackBoxDir = Join-Path $script:LogDir 'boite-noire'
$script:Defaults = @{ Theme = 'light'; Alerts = '1'; AlertGpuTemp = '85'; CheckUpdates = '1' }

function Get-Settings {
    $s = @{} + $script:Defaults
    try {
        if (Test-Path -LiteralPath $script:SettingsFile) {
            foreach ($l in [IO.File]::ReadAllLines($script:SettingsFile)) {
                $i = $l.IndexOf('='); if ($i -gt 0) { $s[$l.Substring(0, $i).Trim()] = $l.Substring($i + 1).Trim() }
            }
        }
    } catch {}
    $s
}
function Set-Setting([string]$key, [string]$value) {
    $s = Get-Settings
    $s[$key] = $value
    $lines = $s.Keys | Sort-Object | ForEach-Object { "$_=$($s[$_])" }
    [IO.File]::WriteAllLines($script:SettingsFile, [string[]]$lines)
}

# Comment relancer PC Doctor (depuis l'exe ou depuis le script)
function Get-LaunchCommand([switch]$Monitor, [switch]$Widget) {
    if ($ExePath -and (Test-Path -LiteralPath $ExePath)) {
        return @{ Exe = $ExePath; Args = $(if ($Monitor) { '--monitor' } elseif ($Widget) { '--widget' } else { '' }) }
    }
    $a = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$script:ScriptPath`""
    if ($Monitor) { $a += ' -Monitor' } elseif ($Widget) { $a += ' -Widget' }
    return @{ Exe = $script:PowerShellExe; Args = $a }
}

function Get-LogoPng {
    $here = Split-Path -Parent $script:ScriptPath
    foreach ($p in @((Join-Path $here 'PCDoctor.png'), (Join-Path $here 'build\PCDoctor.png'))) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

# ---------------------------------------------------------------------------
#  Mode surveillance (boîte noire) : pas d'interface, juste l'icône de notification
# ---------------------------------------------------------------------------
if ($Monitor) {
    $smi = @((Join-Path $script:Sys32 'nvidia-smi.exe'), (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $open = Get-LaunchCommand
    [void][PCDoctor.BlackBox]::Run($script:BlackBoxDir, $script:SettingsFile, $open.Exe, $open.Args, (Get-LogoPng), [string]$smi)
    return
}

# ---------------------------------------------------------------------------
#  Widget de bureau : températures et utilisation en direct
# ---------------------------------------------------------------------------
$widgetXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PC Doctor - Widget" Width="230" Height="180" WindowStyle="None" AllowsTransparency="True"
        Background="#01000000" ResizeMode="CanResize" ShowInTaskbar="False" Topmost="True"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="0" ResizeBorderThickness="8" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="4"/>
      <Setter Property="Maximum" Value="100"/>
      <Setter Property="Background" Value="#26FFFFFF"/>
      <Setter Property="Foreground" Value="#FF5B8CFF"/>
      <Setter Property="Margin" Value="0,7,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="2"/>
              <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="2" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FFAAB4C5"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FF7D889B"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
      <Setter Property="Margin" Value="0,1,0,0"/>
    </Style>
    <Style x:Key="Value" TargetType="TextBlock">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Display, Segoe UI"/>
    </Style>
    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Width" Value="26"/>
      <Setter Property="Margin" Value="0,2,0,0"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
    </Style>
    <Style x:Key="Pill" TargetType="Border">
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="7,1"/>
      <Setter Property="Margin" Value="7,2,0,0"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
      <Setter Property="Background" Value="#22FFFFFF"/>
    </Style>
    <Style x:Key="PillText" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#FFAAB4C5"/>
    </Style>
  </Window.Resources>

  <Viewbox x:Name="WBox" Stretch="Uniform">
  <Border x:Name="Root" Width="250" CornerRadius="14" BorderBrush="#30FFFFFF" BorderThickness="1" Padding="14,10,14,12" Margin="8">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
        <GradientStop Color="#F2161D2E" Offset="0"/>
        <GradientStop Color="#F20D121D" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Border.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="3" Direction="270" Opacity="0.45"/></Border.Effect>
    <StackPanel>
      <DockPanel Margin="0,0,0,4">
        <TextBlock x:Name="WClose" DockPanel.Dock="Right" Text="&#xE711;" FontFamily="{StaticResource Icons}" FontSize="10" Foreground="#FF7D889B" Cursor="Hand" VerticalAlignment="Center" Padding="6,4,0,4" ToolTip="Fermer le widget"/>
        <TextBlock x:Name="WPin" DockPanel.Dock="Right" Text="&#xE718;" FontFamily="{StaticResource Icons}" FontSize="11" Foreground="#FF5B8CFF" Cursor="Hand" VerticalAlignment="Center" Padding="6,4" ToolTip="Toujours au premier plan"/>
        <Image x:Name="WLogo" Width="16" Height="16" Margin="0,0,8,0" VerticalAlignment="Center"/>
        <TextBlock Text="PC Doctor" Foreground="#FFE6EAF2" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <TextBlock x:Name="WClock" Foreground="#FF7D889B" Margin="8,0,0,0" VerticalAlignment="Center"/>
      </DockPanel>

      <StackPanel Margin="0,9,0,0">
        <DockPanel>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock x:Name="WCpu" Text="—" Style="{StaticResource Value}"/>
            <Border x:Name="WCpuTempPill" Style="{StaticResource Pill}" Cursor="Hand"><TextBlock x:Name="WCpuTemp" Text="— °C" Style="{StaticResource PillText}"/></Border>
          </StackPanel>
          <TextBlock Text="&#xE950;" Style="{StaticResource Icon}" Foreground="#FF5B8CFF" VerticalAlignment="Center" Margin="0"/>
          <TextBlock Text="Processeur" Style="{StaticResource Label}" VerticalAlignment="Center"/>
        </DockPanel>
        <TextBlock x:Name="WCpuSub" Style="{StaticResource Sub}" Margin="26,0,0,0"/>
        <ProgressBar x:Name="WCpuBar" Margin="26,6,0,0"/>
      </StackPanel>
      <StackPanel Margin="0,9,0,0">
        <DockPanel>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock x:Name="WGpu" Text="—" Style="{StaticResource Value}"/>
            <Border x:Name="WGpuTempPill" Style="{StaticResource Pill}"><TextBlock x:Name="WGpuTemp" Text="— °C" Style="{StaticResource PillText}"/></Border>
          </StackPanel>
          <TextBlock Text="&#xE7F4;" Style="{StaticResource Icon}" Foreground="#FFA78BFA" VerticalAlignment="Center" Margin="0"/>
          <TextBlock Text="Carte graphique" Style="{StaticResource Label}" VerticalAlignment="Center"/>
        </DockPanel>
        <TextBlock x:Name="WGpuSub" Style="{StaticResource Sub}" Margin="26,0,0,0"/>
        <ProgressBar x:Name="WGpuBar" Foreground="#FFA78BFA" Margin="26,6,0,0"/>
      </StackPanel>
      <StackPanel Margin="0,9,0,0">
        <DockPanel>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock x:Name="WRam" Text="—" Style="{StaticResource Value}"/>
          </StackPanel>
          <TextBlock Text="&#xEEA0;" Style="{StaticResource Icon}" Foreground="#FF34D399" VerticalAlignment="Center" Margin="0"/>
          <TextBlock Text="Mémoire vive" Style="{StaticResource Label}" VerticalAlignment="Center"/>
        </DockPanel>
        <TextBlock x:Name="WRamSub" Style="{StaticResource Sub}" Margin="26,0,0,0"/>
        <ProgressBar x:Name="WRamBar" Foreground="#FF34D399" Margin="26,6,0,0"/>
      </StackPanel>
      <StackPanel Margin="0,9,0,0">
        <DockPanel>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock x:Name="WDisk" Text="—" Style="{StaticResource Value}"/>
            <Border x:Name="WDiskTempPill" Style="{StaticResource Pill}"><TextBlock x:Name="WDiskTemp" Text="— °C" Style="{StaticResource PillText}"/></Border>
          </StackPanel>
          <TextBlock Text="&#xEDA2;" Style="{StaticResource Icon}" Foreground="#FFFBBF24" VerticalAlignment="Center" Margin="0"/>
          <TextBlock x:Name="WDiskTitle" Text="SSD" Style="{StaticResource Label}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        </DockPanel>
        <TextBlock x:Name="WDiskSub" Style="{StaticResource Sub}" Margin="26,0,0,0"/>
        <ProgressBar x:Name="WDiskBar" Foreground="#FFFBBF24" Margin="26,6,0,0"/>
      </StackPanel>
      <!-- Historique -->
      <Border x:Name="WHistBox" Background="#14FFFFFF" CornerRadius="10" Padding="10,8" Margin="0,12,0,0">
        <StackPanel>
          <DockPanel>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              <Ellipse Width="7" Height="7" Fill="#FF5B8CFF" VerticalAlignment="Center"/><TextBlock Text="CPU" Style="{StaticResource Sub}" Margin="4,0,10,0" VerticalAlignment="Center"/>
              <Ellipse Width="7" Height="7" Fill="#FFA78BFA" VerticalAlignment="Center"/><TextBlock Text="GPU" Style="{StaticResource Sub}" Margin="4,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <TextBlock Text="2 dernières minutes" Style="{StaticResource Sub}" Margin="0"/>
          </DockPanel>
          <Canvas x:Name="WHistory" Height="38" Margin="0,6,0,0" ClipToBounds="True"/>
        </StackPanel>
      </Border>
    </StackPanel>
  </Border>
  </Viewbox>
</Window>
'@

function New-WidgetWindow {
    [xml]$x = $widgetXaml
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $map = @{}
    foreach ($m in [regex]::Matches($widgetXaml, 'x:Name="(\w+)"')) { $el = $w.FindName($m.Groups[1].Value); if ($el) { $map[$m.Groups[1].Value] = $el } }
    $logo = Get-LogoPng
    if ($logo) { try { $src = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri $logo)); $map['WLogo'].Source = $src; $w.Icon = $src } catch {} }
    @{ Window = $w; UI = $map }
}

$script:WBrush = New-Object System.Windows.Media.BrushConverter
function Get-WBrush([string]$hex) { $script:WBrush.ConvertFromString($hex) }
function Set-WTemp($pill, $text, [double]$t, [double]$warn, [double]$hot, [string]$tip) {
    if ($t -le 0) {
        $text.Text = '— °C'; $text.Foreground = Get-WBrush '#FF7D889B'; $pill.Background = Get-WBrush '#22FFFFFF'
        $pill.ToolTip = $tip
        return
    }
    $text.Text = "{0:N0} °C" -f $t
    $c = if ($t -ge $hot) { @('#FFF87171', '#33F87171') } elseif ($t -ge $warn) { @('#FFFBBF24', '#33FBBF24') } else { @('#FF4ADE80', '#2622C55E') }
    $text.Foreground = Get-WBrush $c[0]; $pill.Background = Get-WBrush $c[1]
    $pill.ToolTip = $null
}
function Format-Rate([double]$b) { if ($b -lt 0) { '—' } elseif ($b -ge 1MB) { '{0:N1} Mo/s' -f ($b / 1MB) } else { '{0:N0} Ko/s' -f ($b / 1KB) } }

function Set-WidgetDetailsVisibility($u, [bool]$on) {
    foreach ($n in 'WCpuSub', 'WGpuSub', 'WRamSub', 'WDiskSub', 'WHistBox') { $u[$n].Visibility = $(if ($on) { 'Visible' } else { 'Collapsed' }) }
}

$script:WHistCpu = New-Object System.Collections.Generic.List[double]
$script:WHistGpu = New-Object System.Collections.Generic.List[double]
function Update-Widget($u, $s) {
    $u.WClock.Text = (Get-Date).ToString('HH:mm')
    # Processeur
    $u.WCpu.Text = if ($s.Cpu -ge 0) { "{0:N0} %" -f $s.Cpu } else { '—' }
    $u.WCpuBar.Value = [math]::Max(0, $s.Cpu)
    $ctTip = if ([PCDoctor.LiveSensors]::CoreTempInstalled()) { 'Température indisponible : cliquez pour lancer Core Temp (déjà installé), le widget la lira automatiquement.' } else { 'Windows ne donne pas la température du processeur : lancez HWiNFO (option « Shared Memory Support ») ou Core Temp, le widget la lira automatiquement.' }
    Set-WTemp $u.WCpuTempPill $u.WCpuTemp $s.CpuTemp 70 85 $ctTip
    $u.WCpuSub.Text = if ($s.CpuTemp -gt 0) { "Température via $($s.CpuTempSource)" } else { 'Température : lancez Core Temp' }
    # Carte graphique
    if ($s.GpuUsage -ge 0) {
        $u.WGpu.Text = "{0:N0} %" -f $s.GpuUsage
        $u.WGpuBar.Value = $s.GpuUsage
        $parts = @()
        if ($s.GpuPower -ge 0) { $parts += "{0:N0} W" -f $s.GpuPower }
        if ($s.GpuMemTotal -gt 0) { $parts += "VRAM {0:N1}/{1:N0} Go" -f ($s.GpuMemUsed / 1024), ($s.GpuMemTotal / 1024) }
        if ($s.GpuFan -ge 0) { $parts += "ventilo {0:N0} %" -f $s.GpuFan }
        $u.WGpuSub.Text = $parts -join '  ·  '
    } else { $u.WGpu.Text = '—'; $u.WGpuSub.Text = 'Suivi disponible pour les cartes NVIDIA' }
    Set-WTemp $u.WGpuTempPill $u.WGpuTemp $s.GpuTemp 75 85 'Température indisponible'
    # Mémoire
    $u.WRam.Text = if ($s.Ram -ge 0) { "{0:N0} %" -f $s.Ram } else { '—' }
    $u.WRamBar.Value = [math]::Max(0, $s.Ram)
    $u.WRamBar.Foreground = Get-WBrush $(if ($s.Ram -ge 90) { '#FFF87171' } elseif ($s.Ram -ge 80) { '#FFFBBF24' } else { '#FF34D399' })
    $u.WRamSub.Text = if ($s.RamTotalGB -gt 0) { "{0:N1} Go utilisés sur {1:N0} Go" -f $s.RamUsedGB, $s.RamTotalGB } else { '' }
    # SSD
    $u.WDiskTitle.Text = "$(if ($s.DiskName -match 'SSD|NVMe') { 'SSD' } else { 'Disque' }) $($env:SystemDrive)"
    $u.WDiskTitle.ToolTip = $s.DiskName
    $u.WDisk.Text = if ($s.DiskBusy -ge 0) { "{0:N0} %" -f $s.DiskBusy } else { '—' }
    $u.WDiskBar.Value = [math]::Max(0, $s.DiskBusy)
    $u.WDiskSub.Text = "L {0}  ·  É {1}  ·  {2:N0} % plein" -f (Format-Rate $s.DiskRead), (Format-Rate $s.DiskWrite), [math]::Max(0, $s.DiskUsedPct)
    Set-WTemp $u.WDiskTempPill $u.WDiskTemp $s.DiskTemp 55 65 'Température du SSD : ouvrez le widget depuis PC Doctor en mode administrateur, ou lancez HWiNFO.'
    # En mode compact, les détails restent accessibles en survolant les valeurs
    foreach ($n in 'Cpu', 'Gpu', 'Ram', 'Disk') { $u["W$n"].ToolTip = $u["W${n}Sub"].Text }
    # Historique (60 points = 2 minutes)
    foreach ($pair in @(@($script:WHistCpu, $s.Cpu), @($script:WHistGpu, $s.GpuUsage))) {
        $pair[0].Add([math]::Max(0, [double]$pair[1])); while ($pair[0].Count -gt 60) { $pair[0].RemoveAt(0) }
    }
    $cv = $u.WHistory
    $cv.Children.Clear()
    $wd = if ($cv.ActualWidth -gt 20) { $cv.ActualWidth } else { 236 }
    $h = $cv.Height
    foreach ($serie in @(@($script:WHistGpu, '#FFA78BFA'), @($script:WHistCpu, '#FF5B8CFF'))) {
        $pts = $serie[0]
        if ($pts.Count -lt 2) { continue }
        $poly = New-Object System.Windows.Shapes.Polyline
        $poly.Stroke = Get-WBrush $serie[1]; $poly.StrokeThickness = 1.6; $poly.StrokeLineJoin = 'Round'
        for ($i = 0; $i -lt $pts.Count; $i++) {
            $x = $wd - ($pts.Count - 1 - $i) * ($wd / 59)
            [void]$poly.Points.Add((New-Object System.Windows.Point($x, ($h - 1 - [math]::Min(100, $pts[$i]) / 100 * ($h - 2)))))
        }
        [void]$cv.Children.Add($poly)
    }
}

if ($Widget) {
    $wMutex = New-Object System.Threading.Mutex($false, 'Local\PCDoctorWidget')
    if (-not $wMutex.WaitOne(0)) { return }   # déjà ouvert
    try {
        $smi = @((Join-Path $script:Sys32 'nvidia-smi.exe'), (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        [PCDoctor.LiveSensors]::Start([string]$smi, $env:SystemDrive)
        $wb = New-WidgetWindow
        $ww = $wb.Window; $wu = $wb.UI
        $cfg = Get-Settings

        # Position et réglages mémorisés
        $wa = [System.Windows.SystemParameters]::WorkArea
        $left = 0.0; $top = 0.0
        $okPos = [double]::TryParse([string]$cfg['WidgetLeft'], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$left) -and [double]::TryParse([string]$cfg['WidgetTop'], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$top)
        $vs = @([System.Windows.SystemParameters]::VirtualScreenLeft, [System.Windows.SystemParameters]::VirtualScreenTop, [System.Windows.SystemParameters]::VirtualScreenWidth, [System.Windows.SystemParameters]::VirtualScreenHeight)
        if (-not $okPos -or $left -lt $vs[0] - 50 -or $top -lt $vs[1] - 50 -or $left -gt $vs[0] + $vs[2] - 100 -or $top -gt $vs[1] + $vs[3] - 100) { $left = $wa.Right - 306 - 16; $top = $wa.Top + 16 }
        $ww.Left = $left; $ww.Top = $top
        $ww.Topmost = ($cfg['WidgetTopmost'] -ne '0')
        $op = 1.0; if ([double]::TryParse([string]$cfg['WidgetOpacity'], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$op)) { $ww.Opacity = [math]::Max(0.4, [math]::Min(1, $op)) }

        function Save-WidgetPos { try { $inv = [Globalization.CultureInfo]::InvariantCulture; Set-Setting 'WidgetLeft' $ww.Left.ToString($inv); Set-Setting 'WidgetTop' $ww.Top.ToString($inv) } catch {} }
        function Update-PinIcon { $wu.WPin.Foreground = Get-WBrush $(if ($ww.Topmost) { '#FF5B8CFF' } else { '#FF7D889B' }); $wu.WPin.ToolTip = if ($ww.Topmost) { 'Toujours au premier plan (cliquer pour désactiver)' } else { 'Cliquer pour garder le widget au premier plan' } }
        function Set-WidgetTopmost([bool]$on) { $ww.Topmost = $on; Set-Setting 'WidgetTopmost' $(if ($on) { '1' } else { '0' }); Update-PinIcon; $script:MiTop.IsChecked = $on }
        Update-PinIcon
        # Taille naturelle du contenu (à l'échelle 1) : sert à garder les proportions
        function Get-WidgetNatural {
            $wu.Root.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
            $d = $wu.Root.DesiredSize
            @([math]::Max(1, $d.Width), [math]::Max(1, $d.Height))
        }
        function Update-WidgetRatio {
            $n = Get-WidgetNatural
            if ($script:WLock) { $script:WLock.Ratio = $n[0] / $n[1] }
            $n
        }
        function Set-WidgetScale([double]$s, [switch]$NoSave) {
            $s = [math]::Max(0.5, [math]::Min(2.5, $s))
            $n = Update-WidgetRatio
            $ww.Width = $n[0] * $s
            $ww.Height = $n[1] * $s
            $script:WScale = $s
            if (-not $NoSave) { Set-Setting 'WidgetScale' $s.ToString([Globalization.CultureInfo]::InvariantCulture) }
        }
        function Set-WidgetDetails([bool]$on, [switch]$NoSave) {
            Set-WidgetDetailsVisibility $wu $on
            $script:MiDetails.IsChecked = $on
            if (-not $NoSave) { Set-Setting 'WidgetDetails' $(if ($on) { '1' } else { '0' }) }
            # même largeur, hauteur ajustée au nouveau contenu
            if ($script:WScale) { Set-WidgetScale $script:WScale -NoSave }
        }

        # Déplacement à la souris
        $wu.Root.Add_MouseLeftButtonDown({
                param($s, $e)
                $src = $e.OriginalSource
                if (@($wu.WClose, $wu.WPin, $wu.WCpuTemp, $wu.WCpuTempPill) -contains $src) { return }   # boutons du widget
                if ($e.ClickCount -eq 1) { try { $ww.DragMove() } catch {}; Save-WidgetPos }
            })
        $wu.WClose.Add_MouseLeftButtonUp({ $ww.Close() })
        $wu.WPin.Add_MouseLeftButtonUp({ Set-WidgetTopmost (-not $ww.Topmost) })
        $wu.WCpuTempPill.Add_MouseLeftButtonUp({
                if ([PCDoctor.LiveSensors]::Read().CpuTemp -le 0 -and [PCDoctor.LiveSensors]::CoreTempInstalled()) { try { Start-Process -FilePath ([PCDoctor.LiveSensors]::CoreTempPath()) } catch {} }
            })

        # Menu clic droit
        $menu = New-Object System.Windows.Controls.ContextMenu
        $script:MiTop = New-Object System.Windows.Controls.MenuItem
        $script:MiTop.Header = 'Toujours au premier plan'; $script:MiTop.IsCheckable = $true; $script:MiTop.IsChecked = $ww.Topmost
        $script:MiTop.Add_Click({ Set-WidgetTopmost $script:MiTop.IsChecked })
        [void]$menu.Items.Add($script:MiTop)
        $miOp = New-Object System.Windows.Controls.MenuItem; $miOp.Header = 'Opacité'
        foreach ($v in 100, 90, 80, 70, 60) {
            $it = New-Object System.Windows.Controls.MenuItem; $it.Header = "$v %"; $it.Tag = $v / 100
            $it.Add_Click({ param($s, $e) $ww.Opacity = [double]$s.Tag; Set-Setting 'WidgetOpacity' ([double]$s.Tag).ToString([Globalization.CultureInfo]::InvariantCulture) })
            [void]$miOp.Items.Add($it)
        }
        [void]$menu.Items.Add($miOp)
        $miSize = New-Object System.Windows.Controls.MenuItem; $miSize.Header = 'Taille'
        foreach ($v in @(@('Petite', 0.7), @('Moyenne', 0.85), @('Grande', 1.0))) {
            $it = New-Object System.Windows.Controls.MenuItem; $it.Header = $v[0]; $it.Tag = $v[1]
            $it.Add_Click({ param($s, $e) Set-WidgetScale ([double]$s.Tag) })
            [void]$miSize.Items.Add($it)
        }
        [void]$menu.Items.Add($miSize)
        $script:MiDetails = New-Object System.Windows.Controls.MenuItem
        $script:MiDetails.Header = 'Afficher les détails et l''historique'; $script:MiDetails.IsCheckable = $true
        $script:MiDetails.Add_Click({ Set-WidgetDetails $script:MiDetails.IsChecked })
        [void]$menu.Items.Add($script:MiDetails)
        [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
        $miOpen = New-Object System.Windows.Controls.MenuItem; $miOpen.Header = 'Ouvrir PC Doctor'
        $miOpen.Add_Click({ $c = Get-LaunchCommand; $psi = New-Object Diagnostics.ProcessStartInfo($c.Exe, $c.Args); $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; [void][Diagnostics.Process]::Start($psi) })
        [void]$menu.Items.Add($miOpen)
        $miClose = New-Object System.Windows.Controls.MenuItem; $miClose.Header = 'Fermer le widget'
        $miClose.Add_Click({ $ww.Close() })
        [void]$menu.Items.Add($miClose)
        $wu.Root.ContextMenu = $menu

        # Taille et détails (compact par défaut)
        $sc = 0.85; [void][double]::TryParse([string]$cfg['WidgetScale'], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$sc)
        Set-WidgetDetailsVisibility $wu ($cfg['WidgetDetails'] -eq '1')
        $script:MiDetails.IsChecked = ($cfg['WidgetDetails'] -eq '1')
        Set-WidgetScale $sc -NoSave
        if (-not $okPos) { $ww.Left = $wa.Right - $ww.Width - 16 }

        # Redimensionnement par les bords : proportions verrouillées, contenu mis à l'échelle
        $ww.Add_SourceInitialized({
                try {
                    $h = (New-Object System.Windows.Interop.WindowInteropHelper $ww).Handle
                    $script:WLock = New-Object PCDoctor.AspectLock($h)
                    [void](Update-WidgetRatio)
                } catch { Write-Log "Widget (redimensionnement) : $_" }
            })
        $ww.Add_SizeChanged({
                $n = Get-WidgetNatural
                $script:WScale = $ww.ActualWidth / $n[0]
                $script:WScaleDirty = $true
            })

        [void][PCDoctor.LiveSensors]::Read()
        $wTimer = New-Object System.Windows.Threading.DispatcherTimer
        $wTimer.Interval = [TimeSpan]::FromSeconds(2)
        $wTimer.Add_Tick({
                try { Update-Widget $wu ([PCDoctor.LiveSensors]::Read()) } catch { Write-Log "Widget : $_" }
                if ($script:WScaleDirty -and [System.Windows.Input.Mouse]::LeftButton -eq 'Released') {
                    $script:WScaleDirty = $false
                    Set-Setting 'WidgetScale' $script:WScale.ToString([Globalization.CultureInfo]::InvariantCulture)
                    Save-WidgetPos
                }
            })
        $ww.Add_ContentRendered({ try { Update-Widget $wu ([PCDoctor.LiveSensors]::Read()) } catch {}; $wTimer.Start() })
        $ww.Add_Closing({
                $wTimer.Stop(); Save-WidgetPos
                if ($script:WScale) { Set-Setting 'WidgetScale' $script:WScale.ToString([Globalization.CultureInfo]::InvariantCulture) }
                if ($script:WLock) { try { $script:WLock.ReleaseHandle() } catch {} }
            })
        [void]$ww.ShowDialog()
    } catch {
        Write-Log "Widget : $_ $($_.ScriptStackTrace)"
    } finally {
        [PCDoctor.LiveSensors]::Stop()
        $wMutex.ReleaseMutex()
    }
    return
}

# ---------------------------------------------------------------------------
#  Collecte des informations (exécutée en arrière-plan pour ne pas figer l'appli)
# ---------------------------------------------------------------------------
$script:CollectorsCode = @'
function Format-Size([double]$Bytes) {
    if ($Bytes -lt 0) { return '?' }
    if ($Bytes -ge 1TB) { return '{0:N2} To' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N1} Go' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} Mo' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} Ko' -f ($Bytes / 1KB) }
    return '{0:N0} o' -f $Bytes
}

# Lance un programme en arrière-plan, sans jamais ouvrir de fenêtre, et renvoie ses lignes de sortie.
# (PowerShell tourne dans l'exe sans console : un appel classique ferait apparaître une fenêtre noire.)
function Invoke-Hidden([string]$exe, [string]$arguments, [string]$encoding = 'oem') {
    $psi = New-Object Diagnostics.ProcessStartInfo($exe, $arguments)
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = if ($encoding -eq 'utf8') { New-Object Text.UTF8Encoding $false } else { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
    $p = [Diagnostics.Process]::Start($psi)
    $null = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $p.Dispose()
    @($out -split "`r?`n")
}
function Get-Sys32Exe([string]$name) { Join-Path ([Environment]::SystemDirectory) $name }

function Get-PCSummary {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $cpu = @(Get-CimInstance Win32_Processor)
    $bb  = $null; try { $bb = Get-CimInstance Win32_BaseBoard } catch {}
    $bios = $null; try { $bios = Get-CimInstance Win32_BIOS } catch {}

    $samples = @()
    for ($i = 0; $i -lt 3; $i++) {
        try { $samples += [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime } catch {}
        Start-Sleep -Milliseconds 400
    }
    if ($samples.Count) { $cpuLoad = ($samples | Measure-Object -Average).Average }
    else { $cpuLoad = [double]($cpu | Measure-Object LoadPercentage -Average).Average }

    $diskBusy = $null
    try {
        $pd = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
        $diskBusy = [math]::Max(0, 100 - [double]$pd.PercentIdleTime)
    } catch {}

    $ramTotal = [double]$os.TotalVisibleMemorySize * 1KB
    $ramFree  = [double]$os.FreePhysicalMemory * 1KB
    $uptime   = (Get-Date) - $os.LastBootUpTime

    $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $size = [double]$_.Size; $free = [double]$_.FreeSpace
        [pscustomobject]@{
            Drive = $_.DeviceID; Label = $_.VolumeName; Size = $size; Free = $free
            UsedPct = $(if ($size -gt 0) { [math]::Round(100 * (1 - $free / $size), 1) } else { 0 })
        }
    })

    $phys = @()
    try {
        $phys = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
            $m = [string]$_.MediaType
            $media = switch ($m) { '3' { 'HDD' } '4' { 'SSD' } '5' { 'SCM' } '0' { 'Inconnu' } 'Unspecified' { 'Inconnu' } default { $m } }
            $h = [string]$_.HealthStatus
            $health = switch ($h) { '0' { 'Bon' } 'Healthy' { 'Bon' } '1' { 'Avertissement' } 'Warning' { 'Avertissement' } '2' { 'Mauvais' } 'Unhealthy' { 'Mauvais' } default { 'Inconnu' } }
            [pscustomobject]@{ Number = [string]$_.DeviceId; Name = $_.FriendlyName; Media = $media; Health = $health; Size = [double]$_.Size }
        })
    } catch {}

    $sysMedia = $null
    try {
        $letter = $env:SystemDrive.TrimEnd(':')
        $num = [string](Get-Partition -DriveLetter $letter -ErrorAction Stop | Select-Object -First 1).DiskNumber
        $sysMedia = ($phys | Where-Object { $_.Number -eq $num } | Select-Object -First 1).Media
    } catch {}

    $gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; DriverVersion = $_.DriverVersion; DriverDate = $_.DriverDate; Status = [string]$_.Status }
    })

    $planGuid = ''; $planName = ''
    try {
        $txt = (Invoke-Hidden (Get-Sys32Exe 'powercfg.exe') '/getactivescheme') -join ' '
        if ($txt -match '([0-9a-fA-F]{8}-[0-9a-fA-F-]{27})') { $planGuid = $Matches[1].ToLower() }
        if ($txt -match '\(([^)]+)\)') { $planName = $Matches[1] }
    } catch {}

    [pscustomobject]@{
        OSName       = $os.Caption
        Model        = ("{0} {1}" -f $cs.Manufacturer, $cs.Model).Trim()
        Board        = $(if ($bb) { ("{0} {1}" -f $bb.Manufacturer, $bb.Product).Trim() } else { '' })
        BiosVersion  = $(if ($bios) { [string]$bios.SMBIOSBIOSVersion } else { '' })
        BiosDate     = $(if ($bios) { $bios.ReleaseDate } else { $null })
        CpuName      = ($cpu | Select-Object -First 1).Name.Trim()
        Cores        = ($cpu | Measure-Object NumberOfCores -Sum).Sum
        CpuLoad      = [math]::Round($cpuLoad, 0)
        DiskBusy     = $diskBusy
        RamTotal     = $ramTotal
        RamFree      = $ramFree
        RamUsedPct   = $(if ($ramTotal -gt 0) { [math]::Round(100 * (1 - $ramFree / $ramTotal), 0) } else { 0 })
        Uptime       = $uptime
        BootTime     = $os.LastBootUpTime
        Drives       = $drives
        PhysicalDisks = $phys
        SystemDiskMedia = $sysMedia
        Gpus         = $gpus
        MainGpu      = ($gpus | Where-Object { $_.Status -eq 'OK' -and $_.Name -match 'NVIDIA|AMD|Radeon|Intel' -and $_.Name -notmatch 'Virtual' } | Select-Object -First 1).Name
        PowerPlanGuid = $planGuid
        PowerPlanName = $planName
        ProcessCount = @(Get-Process).Count
    }
}

function Get-ProcessUsage {
    $cores = [Environment]::ProcessorCount
    $totalRam = [double](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $before = @{}
    foreach ($p in Get-Process) { try { $before[$p.Id] = $p.TotalProcessorTime.TotalMilliseconds } catch {} }
    $ms = 1500
    Start-Sleep -Milliseconds $ms
    $rows = foreach ($p in Get-Process) {
        if ($p.Id -eq 0 -or $p.ProcessName -eq 'Idle') { continue }
        $cpu = 0.0
        try { if ($before.ContainsKey($p.Id)) { $cpu = ($p.TotalProcessorTime.TotalMilliseconds - $before[$p.Id]) / $ms / $cores * 100 } } catch {}
        $desc = ''
        try { $desc = $p.Description } catch {}
        [pscustomobject]@{ Name = $p.ProcessName; Cpu = [math]::Max(0, $cpu); Ram = [double]$p.WorkingSet64; Desc = $desc }
    }
    $rows | Group-Object Name | ForEach-Object {
        $g = $_.Group
        $ram = [double]($g | Measure-Object Ram -Sum).Sum
        $cpuSum = [double]($g | Measure-Object Cpu -Sum).Sum
        $d = ($g | Where-Object { $_.Desc } | Select-Object -First 1).Desc
        $ramPct = if ($totalRam -gt 0) { 100 * $ram / $totalRam } else { 0 }
        [pscustomobject]@{
            Name = $_.Name; Count = $_.Count
            CpuPct = [math]::Round($cpuSum, 1); CpuText = ('{0:N1} %' -f $cpuSum)
            RamBytes = $ram; RamText = (Format-Size $ram); RamPct = $ramPct
            Description = $(if ($d) { $d } else { $_.Name })
        }
    } | Sort-Object RamBytes -Descending
}

# --- Base de connaissances : programmes au démarrage -------------------------
# Ordre important : la première règle qui correspond l'emporte.
$StartupKB = @(
    @('SecurityHealth|Windows Security|Sécurité Windows', 'À garder', "Sécurité Windows (antivirus intégré). Ne pas désactiver."),
    @('Bitdefender|Kaspersky|Norton|Avast|\bAVG\b|ESET|Malwarebytes|McAfee', 'À garder', "Antivirus : il doit démarrer avec le PC pour vous protéger."),
    @('Realtek|RtkAud|RTHDVCPL|RtkNGUI', 'À garder', "Pilote audio Realtek : gardez-le pour que le son et les prises casque fonctionnent bien."),
    @('Synaptics|ETDCtrl|\bElan\b|Wacom|Bluetooth|ctfmon', 'À garder', "Pilote matériel (pavé tactile, tablette, Bluetooth ou clavier) : à garder."),
    @('MicrosoftEdgeAutoLaunch|msedge\.exe', 'Désactivable', "Edge se pré-charge en arrière-plan à l'allumage, même si vous utilisez un autre navigateur."),
    @('GoogleChromeAutoLaunch|chrome\.exe.*--no-startup-window', 'Désactivable', "Chrome se pré-charge en arrière-plan : il s'ouvrira très bien quand vous cliquerez dessus."),
    @('\bOpera', 'Désactivable', "Navigateur Opera / assistant Opera : inutile au démarrage."),
    @('Discord', 'Désactivable', "Se lance en 3 secondes quand vous l'ouvrez. Inutile de l'avoir en fond dès l'allumage."),
    @('steam\.exe|\bSteam\b', 'Désactivable', "Steam démarre très vite quand vous lancez un jeu. Sinon il garde ~500 Mo de RAM en permanence (steamwebhelper)."),
    @('EpicGamesLauncher|Epic Games', 'Désactivable', "Launcher Epic : ouvrez-le seulement quand vous jouez."),
    @('EADesktop|EA app|\bOrigin\b|Electronic Arts', 'Désactivable', "Launcher EA : ouvrez-le seulement quand vous jouez."),
    @('Ubisoft|uplay|UbisoftConnect', 'Désactivable', "Launcher Ubisoft : ouvrez-le seulement quand vous jouez."),
    @('Battle\.net|Blizzard', 'Désactivable', "Launcher Battle.net : ouvrez-le seulement quand vous jouez."),
    @('GalaxyClient|\bGOG\b', 'Désactivable', "Launcher GOG Galaxy : inutile au démarrage."),
    @('RiotClient|Riot Client', 'Désactivable', "Launcher Riot : inutile au démarrage (Vanguard, l'anti-triche, est géré à part)."),
    @('Rockstar', 'Désactivable', "Launcher Rockstar : inutile au démarrage."),
    @('Overwolf|CurseForge|Outplayed', 'Désactivable', "Overwolf et ses applis : gourmand en RAM, se lance à la demande."),
    @('\bMedal\b', 'Désactivable', "Medal (clips de jeu) : à lancer seulement quand vous voulez enregistrer."),
    @('Razer Cortex|RazerCortex', 'Désactivable', "Razer Cortex : « booster » de jeux, inutile voire contre-productif."),
    @('Spotify', 'Désactivable', "Spotify s'ouvre quand vous voulez écouter de la musique."),
    @('ms-teams|MSTeams|\bTeams\b', 'Désactivable', "Microsoft Teams : gourmand en mémoire. À ouvrir seulement quand vous en avez besoin."),
    @('Skype', 'Désactivable', "Skype : à ouvrir seulement quand vous en avez besoin."),
    @('\bZoom\b', 'Désactivable', "Zoom : à ouvrir pour vos visios uniquement."),
    @('WhatsApp', 'Désactivable', "WhatsApp : à ouvrir quand vous en avez besoin."),
    @('Telegram', 'Désactivable', "Telegram : à ouvrir quand vous en avez besoin."),
    @('Messenger|Facebook', 'Désactivable', "Messenger : à ouvrir quand vous en avez besoin."),
    @('\bSlack\b|\bNotion\b|\bFigma\b', 'Désactivable', "Appli de travail : à ouvrir quand vous en avez besoin."),
    @('\bClaude\b', 'Désactivable', "L'appli Claude : s'ouvre à la demande."),
    @('ChatGPT|Copilot|Cortana', 'Désactivable', "Assistant IA : s'ouvre à la demande."),
    @('CCleaner', 'Désactivable', "CCleaner en arrière-plan : inutile (et souvent envahissant)."),
    @('AdobeGCInvoker|AcroTray|Adobe|CCXProcess|Creative Cloud', 'Désactivable', "Services Adobe (mises à jour, vérification de licence) : inutiles au démarrage."),
    @('uTorrent|BitTorrent|qBittorrent', 'Désactivable', "Client torrent : à lancer seulement pour télécharger."),
    @('iTunes|jusched|Java Update|Google Update|GoogleUpdate', 'Désactivable', "Programme de mise à jour : les mises à jour se feront quand vous ouvrirez le logiciel."),
    @('Docker', 'Désactivable', "Docker : très gourmand, à lancer seulement quand vous développez."),
    @('Twitch|Streamlabs|obs64|\bOBS\b', 'Désactivable', "Logiciel de streaming : à lancer quand vous streamez."),
    @('Grammarly', 'Désactivable', "Grammarly : inutile au démarrage si vous ne l'utilisez pas en permanence."),
    @('XboxPcApp|Xbox', 'Désactivable', "Appli Xbox : s'ouvre quand vous lancez un jeu Game Pass."),
    @('Amazon|Prime Video|Netflix|Disney', 'Désactivable', "Appli de streaming vidéo : inutile au démarrage."),
    @('GamingApp', 'Désactivable', "Appli Xbox : s'ouvre quand vous lancez un jeu Game Pass."),
    @('BlueStacks', 'Désactivable', "Émulateur Android : ses services tournent en fond pour rien si vous ne l'utilisez pas."),
    @('Laragon|XAMPP|WampServer', 'Désactivable', "Serveur de développement : à lancer seulement quand vous codez."),
    @('Web Companion|Lavasoft|Adaware', 'Désactivable', "Logiciel souvent installé en même temps qu'un autre programme, sans réelle utilité. Vous pouvez même le désinstaller."),
    @('StartExperiencesApp|M365Companions|MicrosoftOfficeHub|Todos|WindowsTerminal', 'Désactivable', "Appli Microsoft qui se pré-charge en fond : elle s'ouvrira normalement quand vous cliquerez dessus."),
    @('DragonCenter', 'Au choix', "Ancien logiciel MSI (RGB, ventilateurs). Désactivez-le si vous n'utilisez pas ses réglages."),
    @('YourPhone|CrossDevice|Phone Link', 'Au choix', "Lien avec votre téléphone (notifications, SMS sur le PC). Désactivez si vous ne vous en servez pas."),
    @('HueSync|Nanoleaf|Govee|OpenRGB|SignalRgb', 'Au choix', "Contrôle des lumières / RGB : gardez-le seulement si vous voulez la synchro dès l'allumage."),
    @('Tailscale|Radmin|Hamachi|ZeroTier|playit', 'Au choix', "Réseau privé / tunnel (jeu en LAN, serveur) : gardez-le seulement si vous l'utilisez souvent."),
    @('Folder Size|WizTree|TreeSize', 'Au choix', "Utilitaire d'espace disque : inutile qu'il tourne en permanence."),
    @('OneDrive', 'Au choix', "Synchronise vos fichiers avec le cloud. Désactivez seulement si vous n'utilisez pas OneDrive."),
    @('Dropbox|GoogleDriveFS|Google Drive|iCloud', 'Au choix', "Synchronisation de fichiers : gardez-le si vous comptez dessus pour vos sauvegardes."),
    @('MSI\.CentralServer|MSI Center|Dragon Center|Mystic Light|\bMSI\b', 'Au choix', "Logiciel MSI (RGB, ventilateurs), réputé instable : désactivez-le si vous n'utilisez pas ses réglages."),
    @('Armoury|ArmouryCrate|AURA|LightingService|ASUS', 'Au choix', "Logiciel ASUS (RGB, ventilateurs, mises à jour). Gardez-le seulement si vous utilisez ses réglages."),
    @('iCUE|Corsair', 'Au choix', "Corsair iCUE (RGB, profils clavier/souris). Gardez-le si vous en avez besoin pour vos périphériques."),
    @('LGHUB|G HUB|Logitech', 'Au choix', "Logitech G HUB (profils souris/clavier). Gardez-le si vos réglages de souris en dépendent."),
    @('Razer|Synapse', 'Au choix', "Razer Synapse (profils souris/clavier, RGB). Gardez-le si vous en avez besoin."),
    @('SteelSeries|Sonar', 'Au choix', "SteelSeries GG (profils, son Sonar). Gardez-le si vous l'utilisez."),
    @('NVIDIA|NvBackend|GeForce', 'Au choix', "Logiciel NVIDIA (overlay, enregistrement, mises à jour du pilote). La carte graphique fonctionne très bien sans."),
    @('AMDRSServ|Radeon|\bAMD\b', 'Au choix', "Logiciel AMD (overlay, réglages). Le pilote fonctionne sans."),
    @('Nahimic|Sonic Studio|\bDTS\b|Dolby', 'Au choix', "Effets audio du constructeur. Nahimic est connu pour causer des bugs : désactivez-le si vous n'entendez pas de différence."),
    @('wallpaper32|wallpaper64|Wallpaper Engine', 'Au choix', "Fonds d'écran animés : consomme un peu de GPU et de RAM."),
    @('Oculus|Meta Quest|OVRServer|\bMeta\b', 'Au choix', "Logiciel Meta Quest : nécessaire seulement pour jouer en VR."),
    @('Virtual Desktop', 'Au choix', "Virtual Desktop (VR sans fil) : nécessaire seulement pour jouer en VR."),
    @('Parsec|AnyDesk|TeamViewer|RustDesk', 'Au choix', "Accès à distance : désactivez-le si vous ne l'utilisez pas (plus sûr)."),
    @('VPN|NordVPN|ProtonVPN|Surfshark|Hotspot', 'Au choix', "VPN : gardez-le seulement si vous voulez être protégé dès l'allumage."),
    @('Elgato|Stream Deck', 'Au choix', "Elgato / Stream Deck : gardez-le si vous utilisez ce matériel."),
    @('PowerToys|f\.lux|TranslucentTB|Rainmeter|StartAllBack|ExplorerPatcher|Voicemeeter|EarTrumpet', 'Au choix', "Utilitaire de personnalisation : gardez-le si vous l'utilisez tous les jours.")
)
$AdviceOrder = @{ 'Désactivable' = 0; 'Inconnu' = 1; 'Au choix' = 2; 'À garder' = 3 }

function Get-StartupAdvice([string]$text) {
    foreach ($k in $StartupKB) { if ($text -match $k[0]) { return , @($k[1], $k[2]) } }
    return , @('Inconnu', "PC Doctor ne connaît pas ce programme. En cas de doute, désactivez-le : vous pourrez le réactiver ici à tout moment.")
}

function Get-ExePath([string]$cmd) {
    if (-not $cmd) { return $null }
    try {
        $c = [Environment]::ExpandEnvironmentVariables($cmd.Trim())
        if ($c -match '^"([^"]+)"') { $p = $Matches[1] }
        elseif ($c -match '^(.+?\.(exe|bat|cmd))(\s|$)') { $p = $Matches[1] }
        else { $p = ($c -split ' ')[0] }
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p }
    } catch {}
    return $null
}

function New-StartupRow($name, $cmd, $where, $kind, $approved, $valueName, $uwpKey, [bool]$enabled, [bool]$allUsers) {
    $exe = Get-ExePath $cmd
    $desc = ''; $company = ''
    if ($exe) { try { $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe); $desc = [string]$vi.FileDescription; $company = [string]$vi.CompanyName } catch {} }
    $display = if ($desc -and $desc.Trim().Length -gt 2 -and $desc -notmatch '^(Application|Launcher|App|Updater)$') { $desc.Trim() } else { $name }
    $adv = Get-StartupAdvice ("$name | $display | $company | $cmd")
    $sub = (@($company.Trim(), $where) | Where-Object { $_ }) -join '  ·  '
    [pscustomobject]@{
        Name = $name; DisplayName = $display; Sub = $sub; Company = $company.Trim()
        Command = $cmd; Where = $where; Kind = $kind; ApprovedKey = $approved; ValueName = $valueName; UwpKey = $uwpKey; AllUsers = $allUsers
        Enabled = $enabled
        State = $(if ($enabled) { 'Activé' } else { 'Désactivé' })
        ActionText = $(if ($enabled) { 'Désactiver' } else { 'Activer' })
        Advice = $adv[0]; AdviceText = $adv[1]; AdviceOrder = $AdviceOrder[$adv[0]]
    }
}

function Test-Disabled($approvedItem, [string]$valueName) {
    if (-not $approvedItem) { return $false }
    $b = $approvedItem.GetValue($valueName)
    return ($b -is [byte[]] -and $b.Length -gt 0 -and ($b[0] % 2) -eq 1)
}

function Get-StartupItems {
    $base = 'Software\Microsoft\Windows\CurrentVersion'
    $rows = New-Object System.Collections.Generic.List[object]

    $regSources = @(
        @{ Run = "HKCU:\$base\Run"; Approved = "HKCU:\$base\Explorer\StartupApproved\Run"; Where = 'Registre (votre compte)'; AllUsers = $false },
        @{ Run = "HKLM:\$base\Run"; Approved = "HKLM:\$base\Explorer\StartupApproved\Run"; Where = 'Registre (tous les comptes)'; AllUsers = $true },
        @{ Run = "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Approved = "HKLM:\$base\Explorer\StartupApproved\Run32"; Where = 'Registre (tous les comptes)'; AllUsers = $true }
    )
    foreach ($src in $regSources) {
        $k = $null; try { $k = Get-Item -LiteralPath $src.Run -ErrorAction Stop } catch { continue }
        $appr = $null; try { $appr = Get-Item -LiteralPath $src.Approved -ErrorAction Stop } catch {}
        foreach ($v in $k.GetValueNames()) {
            if (-not $v) { continue }
            $cmd = [string]$k.GetValue($v)
            $rows.Add((New-StartupRow $v $cmd $src.Where 'reg' $src.Approved $v $null (-not (Test-Disabled $appr $v)) $src.AllUsers))
        }
    }

    $wsh = $null; try { $wsh = New-Object -ComObject WScript.Shell } catch {}
    $folders = @(
        @{ Path = [Environment]::GetFolderPath('Startup'); Approved = "HKCU:\$base\Explorer\StartupApproved\StartupFolder"; Where = 'Dossier Démarrage (votre compte)'; AllUsers = $false },
        @{ Path = [Environment]::GetFolderPath('CommonStartup'); Approved = "HKLM:\$base\Explorer\StartupApproved\StartupFolder"; Where = 'Dossier Démarrage (tous les comptes)'; AllUsers = $true }
    )
    foreach ($f in $folders) {
        if (-not $f.Path -or -not (Test-Path -LiteralPath $f.Path)) { continue }
        $appr = $null; try { $appr = Get-Item -LiteralPath $f.Approved -ErrorAction Stop } catch {}
        foreach ($file in @(Get-ChildItem -LiteralPath $f.Path -File -Force -ErrorAction SilentlyContinue)) {
            if ($file.Name -ieq 'desktop.ini') { continue }
            $cmd = $file.FullName
            if ($file.Extension -ieq '.lnk' -and $wsh) {
                try { $sc = $wsh.CreateShortcut($file.FullName); if ($sc.TargetPath) { $cmd = ('"{0}" {1}' -f $sc.TargetPath, $sc.Arguments).Trim() } } catch {}
            }
            $rows.Add((New-StartupRow $file.BaseName $cmd $f.Where 'folder' $f.Approved $file.Name $null (-not (Test-Disabled $appr $file.Name)) $f.AllUsers))
        }
    }

    $uwpRoot = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
    try {
        foreach ($pkg in @(Get-ChildItem -LiteralPath $uwpRoot -ErrorAction Stop)) {
            foreach ($task in @(Get-ChildItem -LiteralPath $pkg.PSPath -ErrorAction SilentlyContinue)) {
                $state = $task.GetValue('State')
                if ($null -eq $state) { continue }
                $pkgName = $pkg.PSChildName
                $friendly = ($pkgName -split '_')[0]
                if ($friendly -match '\.([^.]+)$') { $friendly = $Matches[1] }
                $enabled = (@(2, 4) -contains [int]$state)
                $rows.Add((New-StartupRow $friendly "$pkgName ($($task.PSChildName))" 'Application du Microsoft Store' 'uwp' $null $null $task.PSPath $enabled $false))
            }
        }
    } catch {}

    $rows | Sort-Object @{ Expression = 'Enabled'; Descending = $true }, AdviceOrder, DisplayName
}

function Get-CrashEvents([int]$Days = 30) {
    $start = (Get-Date).AddDays(-$Days)
    $rows = New-Object System.Collections.Generic.List[object]

    $sys = @()
    try { $sys = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = @(41, 6008, 1001, 4101, 7, 51, 153, 55); StartTime = $start } -MaxEvents 500 -ErrorAction Stop) } catch {}
    foreach ($e in $sys) {
        $cat = $null; $detail = $null
        $prov = [string]$e.ProviderName
        switch ($e.Id) {
            41 {
                if ($prov -eq 'Microsoft-Windows-Kernel-Power') {
                    $cat = 'Arrêt brutal'
                    $bc = 0; $btn = 0
                    try { $bc = [int64]$e.Properties[0].Value; $btn = [int64]$e.Properties[3].Value } catch {}
                    if ($bc -ne 0) { $detail = "Redémarrage après un écran bleu (code 0x{0:X8})." -f $bc }
                    elseif ($btn -ne 0) { $detail = "Bouton d'alimentation maintenu pour forcer l'arrêt (le PC était probablement figé)." }
                    else { $detail = "Coupure nette sans écran bleu : gel total ou perte d'alimentation (alimentation, surchauffe, RAM/overclocking instable, coupure secteur)." }
                }
            }
            6008 { if ($prov -eq 'EventLog') { $cat = 'Arrêt inattendu'; $detail = "L'arrêt précédent du système était inattendu." } }
            1001 {
                if ($prov -like '*WER-SystemErrorReporting*') {
                    $cat = 'Écran bleu (BSOD)'
                    $msg = ''
                    try { $msg = [string]$e.Message } catch {}
                    if ($msg -match '0x[0-9a-fA-F]{8}') { $detail = "Code d'arrêt $($Matches[0]) — " + ($msg -split "`n")[0] }
                    elseif ($msg) { $detail = ($msg -split "`n")[0] }
                    else { $detail = 'Le système a redémarré après une erreur critique.' }
                }
            }
            4101 { if ($prov -eq 'Display') { $cat = 'Pilote graphique'; $detail = "Le pilote d'affichage a cessé de répondre puis a redémarré." } }
            55 { if ($prov -like '*Ntfs*') { $cat = 'Système de fichiers'; $detail = 'Structure du disque endommagée (lancer une vérification du disque).' } }
            default {
                if ($prov -eq 'disk' -and @(7, 51, 153) -contains $e.Id) {
                    $cat = 'Erreur disque'
                    $detail = switch ($e.Id) { 7 { 'Secteur défectueux détecté sur un disque.' } 51 { "Erreur lors d'une opération de pagination (lecture/écriture)." } 153 { "Opération d'E/S relancée sur un disque (lenteur / disque fatigué)." } }
                }
            }
        }
        if ($cat) { $rows.Add([pscustomobject]@{ Date = $e.TimeCreated; DateText = $e.TimeCreated.ToString('dd/MM/yyyy HH:mm'); Category = $cat; Detail = $detail; App = '' }) }
    }

    $app = @()
    try { $app = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = @(1000, 1002); StartTime = $start } -MaxEvents 500 -ErrorAction Stop) } catch {}
    foreach ($e in $app) {
        $name = ''
        try { $name = [string]$e.Properties[0].Value } catch {}
        if ($e.ProviderName -eq 'Application Error') {
            $mod = ''
            try { $mod = [string]$e.Properties[3].Value } catch {}
            $rows.Add([pscustomobject]@{ Date = $e.TimeCreated; DateText = $e.TimeCreated.ToString('dd/MM/yyyy HH:mm'); Category = 'Plantage logiciel'; Detail = "$name a planté (module en cause : $mod)"; App = $name })
        } elseif ($e.ProviderName -eq 'Application Hang') {
            $rows.Add([pscustomobject]@{ Date = $e.TimeCreated; DateText = $e.TimeCreated.ToString('dd/MM/yyyy HH:mm'); Category = 'Logiciel figé'; Detail = "$name ne répondait plus et a été fermé"; App = $name })
        }
    }
    $rows | Sort-Object Date -Descending
}

# --- Carte graphique NVIDIA en direct (nvidia-smi, installé avec le pilote) ---
$SmiQuery = '--query-gpu=name,temperature.gpu,power.draw,power.limit,power.default_limit,power.min_limit,power.max_limit,clocks.gr,clocks.max.gr,fan.speed,utilization.gpu,driver_version --format=csv,noheader,nounits'

function Get-NvidiaSmi {
    # Uniquement les emplacements officiels du pilote NVIDIA (jamais le PATH, qui peut contenir des dossiers modifiables)
    $candidates = @(
        (Join-Path ([Environment]::SystemDirectory) 'nvidia-smi.exe'),
        (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
    )
    foreach ($p in $candidates) { if (Test-Path -LiteralPath $p -PathType Leaf) { return $p } }
    return $null
}

function ConvertFrom-SmiLine([string]$line) {
    if (-not $line -or $line -notmatch ',') { return $null }
    $v = $line -split ',\s*'
    if ($v.Count -lt 12) { return $null }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $num = { param($s) $x = 0.0; if ([double]::TryParse(([string]$s).Trim(), [Globalization.NumberStyles]::Float, $inv, [ref]$x)) { $x } else { $null } }
    [pscustomobject]@{
        Name = $v[0].Trim(); Temp = (& $num $v[1]); Power = (& $num $v[2]); PowerLimit = (& $num $v[3]); PowerDefault = (& $num $v[4])
        PowerMin = (& $num $v[5]); PowerMax = (& $num $v[6]); Clock = (& $num $v[7]); ClockMax = (& $num $v[8])
        Fan = (& $num $v[9]); Usage = (& $num $v[10]); Driver = $v[11].Trim()
    }
}

function Get-GpuLive {
    $smi = Get-NvidiaSmi
    if (-not $smi) { return $null }
    $line = $null
    try { $line = Invoke-Hidden $smi $SmiQuery 'utf8' | Where-Object { $_ -match ',' } | Select-Object -First 1 } catch { return $null }
    ConvertFrom-SmiLine $line
}

# --- RAM : vitesse réelle et profil EXPO/XMP ---
function Get-MemoryInfo {
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    if (-not $mods.Count) { return $null }
    $m = $mods[0]
    $type = switch ([int]$m.SMBIOSMemoryType) { 24 { 'DDR3' } 26 { 'DDR4' } 34 { 'DDR5' } default { 'DDR' } }
    $cfg = [int]$m.ConfiguredClockSpeed
    if (-not $cfg) { $cfg = [int]$m.Speed }
    $part = ([string]$m.PartNumber).Trim()
    $kit = $null
    foreach ($mm in [regex]::Matches($part, '(\d{4})')) { $n = [int]$mm.Groups[1].Value; if ($n -ge 2133 -and $n -le 9000) { $kit = $n } }
    $jedec = switch ($type) { 'DDR4' { 3200 } 'DDR5' { 5600 } 'DDR3' { 1600 } default { 99999 } }
    $base = switch ($type) { 'DDR4' { 2666 } 'DDR5' { 4800 } 'DDR3' { 1333 } default { 0 } }
    if ($kit -and $cfg -lt ($kit - 100)) {
        $state = 'Off'
        $text = "Profil désactivé : $cfg au lieu de $kit MT/s. Le plus stable, un peu moins rapide."
    } elseif ($cfg -gt $jedec -or ($kit -and $kit -gt $base -and $cfg -ge ($kit - 100))) {
        $state = 'On'
        $text = if ($cfg -le $jedec) { "Vitesse prévue par le fabricant du kit, supportée par le processeur." } else { "Au-dessus de la norme du processeur : overclocking, pas toujours stable." }
    } else {
        $state = 'Base'
        $text = "Vitesse standard : pas d'overclocking."
    }
    $total = [double]($mods | Measure-Object Capacity -Sum).Sum
    [pscustomobject]@{
        Type = $type; Count = $mods.Count; Total = $total; PerModule = [double]$m.Capacity
        Configured = $cfg; Kit = $kit; Part = $part; Maker = ([string]$m.Manufacturer).Trim()
        XmpState = $state; XmpText = $text
    }
}

# --- Processeur : overclocking possible ? ---
function Get-CpuOcInfo {
    $c = Get-CimInstance Win32_Processor | Select-Object -First 1
    $name = ([string]$c.Name).Trim()
    $note = if ($name -match 'X3D') { "Pas d'overclocking classique. Si PBO ou Curve Optimizer ont été réglés dans le BIOS, remettez « Auto »." }
    elseif ($name -match 'Ryzen') { "En cas de plantages, remettez PBO et Curve Optimizer sur « Auto » dans le BIOS." }
    elseif ($name -match 'i[3579]-1[34]\d{3}') { "Défaut d'instabilité connu : mettez le BIOS à jour (microcode 0x12B ou plus) et gardez les réglages Intel par défaut." }
    elseif ($name -match 'i[3579]-\d{4,5}K') { "En cas d'instabilité, retirez overclocking et undervolt (BIOS, XTU, ThrottleStop)." }
    else { "Réglages d'usine : rien à surveiller." }
    [pscustomobject]@{ Name = $name; MaxClock = [int]$c.MaxClockSpeed; Cores = [int]$c.NumberOfCores; Threads = [int]$c.NumberOfLogicalProcessors; Note = $note }
}

# --- Logiciels d'overclocking présents ---
function Get-OcTools {
    $out = New-Object System.Collections.Generic.List[object]
    $defs = @(
        @('MSIAfterburner', 'MSI Afterburner', 'carte graphique'),
        @('PrecisionX|EVGAPrecision', 'EVGA Precision', 'carte graphique'),
        @('GPUTweak', 'ASUS GPU Tweak', 'carte graphique'),
        @('TrixxServer|SapphireTrixx', 'Sapphire Trixx', 'carte graphique'),
        @('FireStorm', 'Zotac FireStorm', 'carte graphique'),
        @('AMDRyzenMaster|RyzenMaster', 'AMD Ryzen Master', 'processeur'),
        @('XtuService|PerfTune', 'Intel XTU', 'processeur'),
        @('ThrottleStop', 'ThrottleStop', 'processeur')
    )
    $procs = @(Get-Process | Select-Object -ExpandProperty ProcessName)
    foreach ($d in $defs) {
        if ($procs | Where-Object { $_ -match $d[0] } | Select-Object -First 1) { $out.Add([pscustomobject]@{ Name = $d[1]; Target = $d[2]; Running = $true }) }
    }
    $paths = @(
        @("${env:ProgramFiles(x86)}\MSI Afterburner\MSIAfterburner.exe", 'MSI Afterburner', 'carte graphique'),
        @("$env:ProgramFiles\AMD\RyzenMaster\bin\AMD Ryzen Master.exe", 'AMD Ryzen Master', 'processeur'),
        @("${env:ProgramFiles(x86)}\ASUS\GPU TweakIII\GPUTweakIII.exe", 'ASUS GPU Tweak', 'carte graphique')
    )
    foreach ($p in $paths) {
        if ((Test-Path -LiteralPath $p[0]) -and -not ($out | Where-Object { $_.Name -eq $p[1] })) { $out.Add([pscustomobject]@{ Name = $p[1]; Target = $p[2]; Running = $false }) }
    }
    $out
}

# --- Périphériques en erreur (Gestionnaire de périphériques) ---
function Get-ProblemDevices {
    $msg = @{ 1 = 'Mal configuré'; 3 = 'Pilote endommagé'; 10 = 'Ne peut pas démarrer'; 12 = 'Ressources insuffisantes'; 14 = 'Redémarrage nécessaire'; 18 = 'Pilote à réinstaller'; 19 = 'Configuration endommagée'; 21 = 'En cours de suppression'; 22 = 'Désactivé'; 28 = 'Aucun pilote installé'; 31 = 'Ne fonctionne pas correctement'; 39 = 'Pilote manquant ou endommagé'; 43 = 'Arrêté après un problème'; 48 = 'Pilote bloqué (incompatible)'; 52 = 'Signature du pilote invalide' }
    $realGpu = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' -and $_.Name -match 'NVIDIA|AMD|Radeon|Intel' }).Count -gt 0
    @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue) |
        Where-Object { @(24, 45) -notcontains [int]$_.ConfigManagerErrorCode } | ForEach-Object {
            $code = [int]$_.ConfigManagerErrorCode
            $name = if ($_.Name) { $_.Name } else { $_.DeviceID }
            $problem = if ($msg.ContainsKey($code)) { $msg[$code] } else { "Erreur $code" }
            $serious = ($code -ne 22)
            if ($realGpu -and $name -match 'vidéo de base|Basic Display') { $serious = $false; $problem = 'Inutilisé : la vraie carte graphique fonctionne (sans importance)' }
            if ($name -match 'Virtual|Virtuel') { $serious = $false }
            [pscustomobject]@{ Name = $name; Class = [string]$_.PNPClass; Code = $code; Problem = $problem; Serious = $serious }
        }
}

# --- Durée des démarrages : mesures de la carte mère (Kernel-Boot 30), du noyau et de l'ouverture de session ---
function Get-BootTimes([int]$Max = 10) {
    $q = { param($prov, $id, $n) @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $prov; Id = $id } -MaxEvents $n -ErrorAction SilentlyContinue) }
    $fw = & $q 'Microsoft-Windows-Kernel-Boot' 30 $Max
    $types = & $q 'Microsoft-Windows-Kernel-Boot' 27 ($Max * 2)
    $kern = & $q 'Microsoft-Windows-Kernel-General' 12 ($Max * 2)
    $logons = & $q 'Microsoft-Windows-Winlogon' 7001 ($Max * 3)
    $near = { param($list, $t) $list | Where-Object { [math]::Abs(($_.TimeCreated - $t).TotalSeconds) -lt 120 } | Sort-Object { [math]::Abs(($_.TimeCreated - $t).TotalSeconds) } | Select-Object -First 1 }
    $boots = foreach ($e in $fw) {
        $d = @{}; foreach ($x in ([xml]$e.ToXml()).Event.EventData.Data) { $v = 0.0; [void][double]::TryParse([string]$x.'#text', [ref]$v); $d[$x.Name] = $v }
        if (-not $d['StartOSImageStart'] -or -not $d['ExitBootServicesEntry']) { continue }
        $k = & $near $kern $e.TimeCreated
        $kt = if ($k) { $k.TimeCreated } else { $e.TimeCreated }
        # la session doit s'ouvrir avant le démarrage suivant
        $next = $kern | Where-Object { $_.TimeCreated -gt $kt.AddSeconds(5) } | Sort-Object TimeCreated | Select-Object -First 1
        $limit = if ($next -and $next.TimeCreated -lt $kt.AddMinutes(15)) { $next.TimeCreated } else { $kt.AddMinutes(15) }
        $lg = $logons | Where-Object { $_.TimeCreated -gt $kt -and $_.TimeCreated -lt $limit } | Sort-Object TimeCreated | Select-Object -First 1
        $ty = & $near $types $e.TimeCreated
        $fwS = $d['StartOSImageStart'] / 1000; $ldS = ($d['ExitBootServicesEntry'] - $d['StartOSImageStart']) / 1000
        $ss = if ($lg) { ($lg.TimeCreated - $kt).TotalSeconds } else { $null }
        [pscustomobject]@{
            Date = $kt; Firmware = $fwS; Loader = $ldS; Session = $ss
            Total = $(if ($null -ne $ss) { $fwS + $ldS + $ss } else { $null })
            Type = $(switch ([int]$(if ($ty) { $ty.Properties[0].Value } else { 0 })) { 1 { 'Démarrage rapide' } 2 { 'Sortie de veille prolongée' } default { 'Démarrage complet' } })
            DateText = $kt.ToString('dd/MM HH:mm'); FirmwareText = ('{0:N1} s' -f $fwS); LoaderText = ('{0:N1} s' -f $ldS)
            SessionText = $(if ($null -ne $ss) { '{0:N0} s' -f $ss } else { '—' }); TotalText = $(if ($null -ne $ss) { '{0:N0} s' -f ($fwS + $ldS + $ss) } else { '—' })
        }
    }
    # Ce qui ralentit le démarrage (journal réservé au mode administrateur)
    $culprits = @()
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 101, 102, 103, 106, 109; StartTime = (Get-Date).AddDays(-30) } -ErrorAction Stop)
        $culprits = @($ev | ForEach-Object { $d = @{}; foreach ($x in ([xml]$_.ToXml()).Event.EventData.Data) { $d[$x.Name] = [string]$x.'#text' }; [pscustomobject]@{ Name = $(if ($d['FriendlyName']) { $d['FriendlyName'] } else { $d['Name'] }); Ms = [double]$d['DegradationTime'] } } |
            Where-Object { $_.Name } | Group-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Count = $_.Count; Seconds = ($_.Group | Measure-Object Ms -Average).Average / 1000 } } | Sort-Object Seconds -Descending | Select-Object -First 5)
    } catch {}
    [pscustomobject]@{ Boots = @($boots); Culprits = $culprits; CanReadDetails = $(try { [void](Get-WinEvent -ListLog 'Microsoft-Windows-Diagnostics-Performance/Operational' -ErrorAction Stop); $true } catch { $false }) }
}

function Get-FastStartup {
    try { return ([int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction Stop).HiberbootEnabled -eq 1) } catch { return $null }
}

# --- Pilotes installés (fabricants) ---
function Get-KeyDrivers {
    $cls = @{ 'DISPLAY' = 'Carte graphique'; 'NET' = 'Réseau'; 'MEDIA' = 'Audio'; 'SYSTEM' = 'Chipset / système'; 'BLUETOOTH' = 'Bluetooth'; 'HDC' = 'Stockage'; 'SCSIADAPTER' = 'Stockage'; 'USB' = 'USB' }
    $now = Get-Date
    $seen = @{}
    @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue) | Where-Object {
        $_.DeviceName -and $_.DeviceClass -and $cls.ContainsKey(([string]$_.DeviceClass).ToUpper()) -and $_.DriverProviderName -and $_.DriverProviderName -notmatch '^Microsoft'
    } | ForEach-Object {
        $key = "$($_.DeviceName)|$($_.DriverVersion)"
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        $date = $_.DriverDate
        $age = if ($date) { ($now - $date).TotalDays / 365.25 } else { $null }
        [pscustomobject]@{
            Category = $cls[([string]$_.DeviceClass).ToUpper()]; Device = $_.DeviceName; Provider = $_.DriverProviderName; Version = $_.DriverVersion
            Date = $date; DateText = $(if ($date) { $date.ToString('dd/MM/yyyy') } else { '?' })
            AgeText = $(if ($null -eq $age) { '?' } elseif ($age -lt 1) { "{0:N0} mois" -f [math]::Max(1, $age * 12) } else { "{0:N1} ans" -f $age })
            Old = ($null -ne $age -and $age -ge 3)
        }
    } | Sort-Object Category, Device
}

# --- Mises à jour de pilotes disponibles sur Windows Update ---
function Get-DriverUpdates {
    $session = New-Object -ComObject Microsoft.Update.Session
    $res = $session.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    foreach ($u in $res.Updates) {
        $row = New-Object PCDoctor.DriverUpdateRow
        $row.Selected = $true
        $row.Title = [string]$u.Title
        $row.Manufacturer = [string]$u.DriverManufacturer
        $row.DriverClass = [string]$u.DriverClass
        try { $row.DateText = ([datetime]$u.DriverVerDate).ToString('dd/MM/yyyy') } catch { $row.DateText = '' }
        $row.SizeText = Format-Size ([double]$u.MaxDownloadSize)
        $row.UpdateId = [string]$u.Identity.UpdateID
        $row
    }
}

# --- Santé détaillée des disques (SMART, nécessite le mode administrateur) ---
function Get-DiskHealth {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $rc = $null
        try { $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
        $m = [string]$d.MediaType
        $media = switch ($m) { '3' { 'HDD' } '4' { 'SSD' } 'HDD' { 'HDD' } 'SSD' { 'SSD' } default { 'Disque' } }
        $b = [string]$d.BusType
        $bus = switch ($b) { '17' { 'NVMe' } 'NVMe' { 'NVMe' } '11' { 'SATA' } 'SATA' { 'SATA' } '7' { 'USB' } 'USB' { 'USB' } '8' { 'RAID' } 'RAID' { 'RAID' } default { $b } }
        if ($bus -eq 'NVMe') { $media = 'SSD' }
        $h = [string]$d.HealthStatus
        $health = switch ($h) { '0' { 'Bon' } 'Healthy' { 'Bon' } '1' { 'Avertissement' } 'Warning' { 'Avertissement' } '2' { 'Mauvais' } 'Unhealthy' { 'Mauvais' } default { 'Inconnu' } }
        $temp = if ($rc -and $rc.Temperature -gt 0) { [int]$rc.Temperature } else { $null }
        $tempMax = if ($rc -and $rc.TemperatureMax -gt 0) { [int]$rc.TemperatureMax } else { $null }
        $wear = if ($rc -and $null -ne $rc.Wear -and $media -eq 'SSD') { [int]$rc.Wear } else { $null }
        $hours = if ($rc -and $rc.PowerOnHours -gt 0) { [int64]$rc.PowerOnHours } else { $null }
        $rerr = if ($rc -and $null -ne $rc.ReadErrorsUncorrected) { [int64]$rc.ReadErrorsUncorrected } else { $null }
        $werr = if ($rc -and $null -ne $rc.WriteErrorsUncorrected) { [int64]$rc.WriteErrorsUncorrected } else { $null }
        $hasDetails = ($null -ne $temp -or $null -ne $hours -or $null -ne $wear)
        $hot = if ($bus -eq 'NVMe') { 70 } else { 55 }
        [void]$out.Add([pscustomobject]@{
            Name = ([string]$d.FriendlyName).Trim(); Media = $media; Bus = $bus; Size = [double]$d.Size
            Kind = "$media $bus  ·  $(Format-Size ([double]$d.Size))"
            Health = $health; Temp = $temp; TempMax = $tempMax; Wear = $wear; Hours = $hours; ReadErrors = $rerr; WriteErrors = $werr
            HasDetails = $hasDetails; HotLimit = $hot
            TempText = $(if ($null -ne $temp) { "$temp °C" + $(if ($tempMax) { "  (max $tempMax °C)" } else { '' }) } else { '—' })
            WearText = $(if ($null -ne $wear) { "{0} % utilisée  ·  reste ~{1} %" -f $wear, [math]::Max(0, 100 - $wear) } elseif ($media -eq 'HDD') { 'Sans objet (disque mécanique)' } else { '—' })
            HoursText = $(if ($null -ne $hours) { "{0:N0} h  (~{1:N1} ans allumé)" -f $hours, ($hours / 8766) } else { '—' })
            ErrorsText = $(if ($null -ne $rerr -or $null -ne $werr) { $t = [int64]$rerr + [int64]$werr; if ($t -eq 0) { 'Aucune' } else { "$t erreur(s) non corrigée(s)" } } else { '—' })
        })
    }
    $out
}

# --- Qualité de la connexion réseau ---
function Test-NetworkQuality {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
    $gw = if ($route) { [string]$route.NextHop } else { $null }
    $ad = if ($route) { Get-NetAdapter -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue } else { $null }
    $isWifi = $ad -and (([string]$ad.PhysicalMediaType -match '802\.11') -or ([string]$ad.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11'))
    $signal = $null
    if ($isWifi) { try { foreach ($l in (Invoke-Hidden (Get-Sys32Exe 'netsh.exe') 'wlan show interfaces')) { if ($l -match '^\s*Signal\s*:\s*(\d+)\s*%') { $signal = [int]$Matches[1] } } } catch {} }
    $dnsServers = @()
    if ($route) { try { $dnsServers = @((Get-DnsClientServerAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses) } catch {} }

    $targets = @()
    if ($gw -and $gw -ne '0.0.0.0') { $targets += , @('Votre box / routeur', $gw, 'local') }
    $targets += , @('Cloudflare (1.1.1.1)', '1.1.1.1', 'internet')
    $targets += , @('Google (8.8.8.8)', '8.8.8.8', 'internet')
    $pinger = New-Object System.Net.NetworkInformation.Ping
    $results = foreach ($t in $targets) {
        $rtts = New-Object System.Collections.Generic.List[double]
        $lost = 0; $n = 20
        for ($i = 0; $i -lt $n; $i++) {
            try { $r = $pinger.Send($t[1], 1000); if ($r.Status -eq 'Success') { $rtts.Add([double]$r.RoundtripTime) } else { $lost++ } } catch { $lost++ }
            Start-Sleep -Milliseconds 100
        }
        $avg = if ($rtts.Count) { ($rtts | Measure-Object -Average).Average } else { $null }
        $jit = 0.0
        if ($rtts.Count -gt 1) { $sum = 0.0; for ($k = 1; $k -lt $rtts.Count; $k++) { $sum += [math]::Abs($rtts[$k] - $rtts[$k - 1]) }; $jit = $sum / ($rtts.Count - 1) }
        $loss = 100.0 * $lost / $n
        [pscustomobject]@{
            Name = $t[0]; Target = $t[1]; Scope = $t[2]; Avg = $avg; Jitter = $jit; Loss = $loss
            Min = $(if ($rtts.Count) { ($rtts | Measure-Object -Minimum).Minimum } else { $null }); Max = $(if ($rtts.Count) { ($rtts | Measure-Object -Maximum).Maximum } else { $null })
            AvgText = $(if ($null -ne $avg) { "{0:N0} ms" -f $avg } else { 'injoignable' })
            RangeText = $(if ($rtts.Count) { "{0:N0} – {1:N0} ms" -f ($rtts | Measure-Object -Minimum).Minimum, ($rtts | Measure-Object -Maximum).Maximum } else { '—' })
            JitterText = ("{0:N1} ms" -f $jit); LossText = ("{0:N0} %" -f $loss)
            Verdict = $(if ($null -eq $avg) { 'Mauvais' } elseif ($loss -ge 5 -or ($t[2] -eq 'local' -and $avg -gt 10) -or $avg -gt 80 -or $jit -gt 15) { 'Mauvais' } elseif ($loss -gt 0 -or ($t[2] -eq 'local' -and $avg -gt 4) -or $avg -gt 40 -or $jit -gt 6) { 'Moyen' } else { 'Bon' })
        }
    }
    $dnsMs = @()
    foreach ($dom in 'wikipedia.org', 'steampowered.com', 'cloudflare.com') {
        try { $sw = [Diagnostics.Stopwatch]::StartNew(); $null = Resolve-DnsName $dom -DnsOnly -NoHostsFile -QuickTimeout -Type A -ErrorAction Stop; $dnsMs += $sw.Elapsed.TotalMilliseconds } catch {}
    }
    [pscustomobject]@{
        Adapter = $(if ($ad) { [string]$ad.InterfaceDescription } else { 'Inconnue' })
        Type = $(if ($isWifi) { 'Wi-Fi' } elseif ($ad) { 'Câble Ethernet' } else { 'Inconnue' })
        IsWifi = [bool]$isWifi; Signal = $signal; LinkSpeed = $(if ($ad) { [string]$ad.LinkSpeed } else { '' })
        Gateway = $gw; DnsServers = $dnsServers
        DnsMs = $(if ($dnsMs.Count) { ($dnsMs | Measure-Object -Average).Average } else { $null })
        Results = @($results)
    }
}

# --- Logiciels pouvant être mis à jour (winget) ---
function Get-WingetPath {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}
function Get-WingetUpgrades {
    $wg = Get-WingetPath
    if (-not $wg) { throw "winget n'est pas installé sur ce PC (Microsoft Store > « Programme d'installation d'application »)." }
    $lines = @(Invoke-Hidden $wg 'upgrade --include-unknown --source winget --accept-source-agreements --disable-interactivity' 'utf8')
    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^-{20,}\s*$') { continue }
        $header = ($lines[$i - 1] -split "`r")[-1]
        $cols = @([regex]::Matches($header, '\S+') | ForEach-Object { $_.Index })
        if ($cols.Count -lt 4) { continue }
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $l = $lines[$j]
            if (-not $l.Trim() -or $l -match '^\d+\s' -or $l.Length -lt $cols[3]) { break }
            $cut = { param($a, $b) if ($a -ge $l.Length) { '' } elseif ($null -eq $b -or $b -gt $l.Length) { $l.Substring($a).Trim() } else { $l.Substring($a, $b - $a).Trim() } }
            $name = & $cut $cols[0] $cols[1]
            $id = & $cut $cols[1] $cols[2]
            $ver = & $cut $cols[2] $cols[3]
            $avail = & $cut $cols[3] $(if ($cols.Count -gt 4) { $cols[4] } else { $null })
            if (-not $id -or $id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { continue }
            [void]$rows.Add([pscustomobject]@{ Name = $name; Id = $id; Version = $ver; Available = $avail })
        }
    }
    $rows
}

# Sécurité du PC : uniquement de la lecture (aucun réglage n'est modifié ici)
function Get-SecurityStatus {
    $list = New-Object System.Collections.Generic.List[object]
    $order = @{ 'Critique' = 0; 'Attention' = 1; 'Info' = 2; 'OK' = 3 }
    $add = { param($sev, $title, $advice, $actLabel, $actId) $list.Add([pscustomobject]@{ Severity = $sev; Title = $title; Advice = $advice; Order = $order[$sev]; ActionLabel = $actLabel; ActionId = $actId }) }
    $reg = { param($path, $name) try { (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop).$name } catch { $null } }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $facts = [ordered]@{ Antivirus = '?'; Firewall = '?'; Updates = '?'; Hardware = '?' }

    # --- Antivirus ---
    $mp = $null; try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch {}
    $avs = @(); try { $avs = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop) } catch {}
    $third = @($avs | Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' -and ([int64]$_.productState -band 0x1000) })
    $defOn = $mp -and $mp.RealTimeProtectionEnabled -and $mp.AMRunningMode -ne 'Passive Mode'
    if ($third.Count) {
        $a = $third[0]
        $facts.Antivirus = $a.displayName
        if ([int64]$a.productState -band 0x10) { & $add 'Attention' "Antivirus « $($a.displayName) » pas à jour" "Ses définitions de virus sont anciennes : ouvrez-le et lancez sa mise à jour." $null $null }
        else { & $add 'OK' "Antivirus actif : $($a.displayName)" "Protection en temps réel activée et à jour (Microsoft Defender se met en retrait, c'est normal)." $null $null }
    } elseif ($defOn) {
        $facts.Antivirus = 'Microsoft Defender'
        $age = [int]$mp.AntivirusSignatureAge
        if ($age -ge 4) { & $add 'Attention' "Définitions de virus anciennes ($age jours)" "Microsoft Defender ne connaît pas les menaces les plus récentes. Lancez la mise à jour de la protection (ou Windows Update)." 'Mettre à jour' 'windowsdefender://threat' }
        else { & $add 'OK' 'Antivirus actif : Microsoft Defender' ("Protection en temps réel activée, définitions à jour (" + $(if ($age -lt 1) { "mises à jour aujourd'hui" } else { "il y a $age jour(s)" }) + ").") $null $null }
        if ($mp.PSObject.Properties['IsTamperProtected'] -and -not $mp.IsTamperProtected) { & $add 'Attention' 'Protection contre les falsifications désactivée' "Elle empêche un programme malveillant de couper l'antivirus. Réactivez-la dans Sécurité Windows > Protection contre les virus > Gérer les paramètres." 'Ouvrir' 'windowsdefender://threatsettings' }
        $scan = [int]$mp.QuickScanAge
        if ($scan -gt 14 -and $scan -lt 10000) { & $add 'Info' "Dernière analyse antivirus il y a $scan jours" "La protection en temps réel surveille déjà tout ; une analyse rapide de temps en temps vérifie ce qui est déjà sur le disque." 'Analyse rapide' 'sec-quickscan' }
    } else {
        $facts.Antivirus = 'Aucun'
        & $add 'Critique' 'Aucun antivirus actif' "Ni Microsoft Defender ni un autre antivirus ne protège le PC en temps réel. Réactivez la protection en temps réel dans Sécurité Windows." 'Activer' 'windowsdefender://threatsettings'
    }
    if ($mp) {
        try {
            $since = (Get-Date).AddDays(-30)
            $det = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object { $_.InitialDetectionTime -ge $since })
            if ($det.Count) {
                $names = @()
                try { $th = @(Get-MpThreat -ErrorAction Stop); $names = @($det | ForEach-Object { $id = $_.ThreatID; ($th | Where-Object { $_.ThreatID -eq $id } | Select-Object -First 1).ThreatName } | Where-Object { $_ } | Select-Object -Unique -First 3) } catch {}
                & $add 'Attention' "$($det.Count) menace(s) détectée(s) ces 30 derniers jours" ("Microsoft Defender a bloqué ou mis en quarantaine : " + $(if ($names.Count) { $names -join ', ' } else { 'voir l''historique' }) + ". Vérifiez dans l'historique qu'elles ont bien été traitées.") 'Historique' 'windowsdefender://history'
            }
        } catch {}
        if ($defOn) {
            try {
                $pref = Get-MpPreference -ErrorAction Stop
                $ex = @(@($pref.ExclusionPath) + @($pref.ExclusionProcess) | Where-Object { $_ -and $_ -notlike 'N/A*' })
                if ($ex.Count) { & $add 'Info' "$($ex.Count) exclusion(s) dans l'antivirus" ("Ces éléments ne sont pas analysés : " + (($ex | Select-Object -First 4) -join ' ; ') + ". Un logiciel malveillant peut en ajouter pour se cacher : vérifiez que vous les reconnaissez.") 'Voir' 'windowsdefender://threatsettings' }
                if ($pref.PUAProtection -eq 0) { & $add 'Info' 'Blocage des applications indésirables désactivé' "Il bloque les logiciels publicitaires et les barres d'outils installés en douce avec d'autres programmes. Activez « Blocage d'applications potentiellement indésirables »." 'Activer' 'windowsdefender://appbrowser' }
            } catch {}
        }
    }

    # --- Pare-feu ---
    try {
        $off = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled } | ForEach-Object { @{ Domain = 'domaine'; Private = 'privé'; Public = 'public' }[[string]$_.Name] })
        $fw3 = @(); try { $fw3 = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName FirewallProduct -ErrorAction Stop | Where-Object { [int64]$_.productState -band 0x1000 }) } catch {}
        if (-not $off.Count) { $facts.Firewall = 'Actif'; & $add 'OK' 'Pare-feu Windows actif' 'Les connexions entrantes non autorisées sont bloquées sur tous les réseaux.' $null $null }
        elseif ($fw3.Count) { $facts.Firewall = $fw3[0].displayName; & $add 'OK' "Pare-feu actif : $($fw3[0].displayName)" 'Un pare-feu tiers remplace celui de Windows.' $null $null }
        else { $facts.Firewall = 'Désactivé'; & $add 'Critique' "Pare-feu désactivé (réseau $($off -join ', '))" "Le PC accepte des connexions qu'il devrait bloquer, dangereux surtout sur un Wi-Fi public. Réactivez-le dans Sécurité Windows." 'Activer' 'windowsdefender://network' }
    } catch {}

    # --- Windows et mises à jour ---
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $build = [int]$os.BuildNumber
        if ($os.Caption -match 'Windows 10') { & $add 'Critique' "Windows 10 n'est plus mis à jour" "Microsoft ne publie plus de correctifs de sécurité pour Windows 10 depuis le 14 octobre 2025. Passez à Windows 11 (gratuit si le PC est compatible)." 'Windows Update' 'ms-settings:windowsupdate' }
        elseif ($build -lt 26100) { & $add 'Attention' "Version de Windows 11 qui n'est plus prise en charge (build $build)" "Elle ne reçoit plus de correctifs de sécurité : installez la dernière version via Windows Update." 'Windows Update' 'ms-settings:windowsupdate' }
        elseif ($build -lt 26200) { & $add 'Attention' 'Windows 11 24H2 : fin de prise en charge en octobre 2026' "Installez la version 25H2 via Windows Update (mise à jour rapide) pour continuer à recevoir les correctifs." 'Windows Update' 'ms-settings:windowsupdate' }
    } catch {}
    $lastWu = $null
    try {
        $sess = New-Object -ComObject Microsoft.Update.Session
        $srch = $sess.CreateUpdateSearcher()
        $n = $srch.GetTotalHistoryCount()
        if ($n -gt 0) { $lastWu = @($srch.QueryHistory(0, [math]::Min($n, 60)) | Where-Object { $_.ResultCode -eq 2 -and $_.Operation -eq 1 } | Sort-Object Date -Descending | Select-Object -First 1).Date }
    } catch {}
    if (-not $lastWu) { try { $lastWu = (Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1).InstalledOn } catch {} }
    if ($lastWu) {
        $lastWu = $lastWu.ToLocalTime()
        $days = [int]((Get-Date) - $lastWu).TotalDays
        $facts.Updates = if ($days -le 1) { "aujourd'hui" } else { "il y a $days jours" }
        if ($days -gt 90) { & $add 'Critique' "Aucune mise à jour Windows depuis $days jours" 'Le PC manque des correctifs de sécurité importants. Ouvrez Windows Update et installez tout.' 'Windows Update' 'ms-settings:windowsupdate' }
        elseif ($days -gt 40) { & $add 'Attention' "Dernière mise à jour Windows il y a $days jours" "Microsoft publie des correctifs chaque mois : vérifiez que Windows Update n'est pas en pause ou bloqué." 'Windows Update' 'ms-settings:windowsupdate' }
        else { & $add 'OK' 'Windows à jour' ("Dernière mise à jour installée le {0:dd/MM/yyyy}." -f $lastWu) $null $null }
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { & $add 'Info' 'Redémarrage nécessaire' 'Des mises à jour attendent un redémarrage pour être appliquées : elles ne protègent pas le PC tant que ce n''est pas fait.' 'Windows Update' 'ms-settings:windowsupdate' }

    # --- Contrôle de compte (UAC) et SmartScreen ---
    $lua = & $reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'
    $cpa = & $reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorAdmin'
    if ($lua -eq 0) { & $add 'Critique' 'Contrôle de compte d''utilisateur (UAC) désactivé' "N'importe quel programme peut modifier Windows sans rien demander. Remettez le curseur sur le niveau par défaut (redémarrage nécessaire)." 'Régler' 'uac' }
    elseif ($cpa -eq 0) { & $add 'Attention' 'UAC réglé sur « Ne jamais m''avertir »' "Les programmes obtiennent les droits administrateur sans confirmation. Remettez le curseur sur le niveau par défaut." 'Régler' 'uac' }
    else { & $add 'OK' 'Contrôle de compte d''utilisateur actif' 'Windows demande confirmation avant qu''un programme modifie le système.' $null $null }
    $ss = & $reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled'
    $ssPol = & $reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen'
    if ($ss -eq 'Off' -or $ssPol -eq 0) { & $add 'Attention' 'SmartScreen désactivé' 'Il prévient avant de lancer un programme téléchargé inconnu ou dangereux. Réactivez « Vérifier les applications et les fichiers ».' 'Activer' 'windowsdefender://appbrowser' }

    # --- Matériel : Secure Boot, TPM, intégrité de la mémoire, chiffrement ---
    $hw = @()
    $sb = & $reg 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
    if ($sb -eq 1) { $hw += 'Secure Boot' }
    elseif ($null -ne $sb) { & $add 'Attention' 'Secure Boot désactivé' "Il empêche un virus de se lancer avant Windows, et certains jeux (anti-triche) l'exigent. Activez-le dans le BIOS (section Boot > Secure Boot, mode « Windows UEFI »)." $null $null }
    else { & $add 'Info' 'Démarrage en mode BIOS ancien (pas UEFI)' 'Secure Boot n''est pas disponible dans ce mode.' $null $null }
    $tpm = $null
    try { $tpm = Get-CimInstance Win32_PnPEntity -Filter "PNPClass='SecurityDevices'" -ErrorAction Stop | Where-Object { $_.Service -eq 'TPM' -or $_.Name -match 'Trusted Platform|TPM|plateforme sécurisée' } | Select-Object -First 1 } catch {}
    if ($tpm -and $tpm.Status -eq 'OK') { $hw += $(if ($tpm.Name -match '2\.0') { 'TPM 2.0' } else { 'TPM' }) }
    else { & $add 'Attention' 'Puce de sécurité TPM non détectée' "Windows 11 et le chiffrement en ont besoin. Sur les cartes mères AMD, activez « fTPM » (ou « AMD CPU fTPM ») dans le BIOS." $null $null }
    $hvci = & $reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'
    if ($hvci -eq 1) { $hw += 'intégrité de la mémoire' }
    else { & $add 'Info' 'Intégrité de la mémoire désactivée' "Elle empêche un pilote malveillant de s'installer au cœur de Windows. Coût en jeu : très faible sur un processeur récent. Si Windows refuse de l'activer, un ancien pilote incompatible est en cause." 'Ouvrir' 'windowsdefender://coreisolation' }
    $bl = $null
    if ($isAdmin) { try { $bl = (Get-CimInstance -Namespace root\cimv2\Security\MicrosoftVolumeEncryption -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop).ProtectionStatus } catch {} }
    else { try { $bl = (New-Object -ComObject Shell.Application).NameSpace(17).ParseName("$env:SystemDrive\").ExtendedProperty('System.Volume.BitLockerProtection') } catch {} }
    if ($bl -eq 1) { $hw += 'disque chiffré' }
    elseif ($null -ne $bl) { & $add 'Info' "Disque $env:SystemDrive non chiffré" "Le chiffrement (BitLocker ou « Chiffrement de l'appareil ») protège vos fichiers si le PC est volé. Surtout utile pour un portable ; gardez bien la clé de récupération." $null $null }
    $facts.Hardware = if ($hw.Count) { $hw -join ' · ' } else { '—' }

    # --- Accès à distance et réseau ---
    if ((& $reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections') -eq 0) { & $add 'Attention' 'Bureau à distance activé' "Le PC accepte les connexions à distance. Si vous ne vous en servez pas, désactivez-le : c'est une porte d'entrée souvent attaquée." 'Désactiver' 'ms-settings:remotedesktop' }
    $smb1 = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10' -ErrorAction SilentlyContinue
    if (($smb1 -and $smb1.Start -ne 4) -or (& $reg 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'SMB1') -eq 1) { & $add 'Attention' 'Ancien partage de fichiers SMB 1.0 installé' "Ce protocole obsolète a été utilisé par le rançongiciel WannaCry. Désinstallez « Support de partage de fichiers SMB 1.0/CIFS » dans les fonctionnalités de Windows." 'Fonctionnalités' 'optionalfeatures' }
    $remote = @{ 'AnyDesk' = 'AnyDesk'; 'TeamViewer' = 'TeamViewer'; 'rustdesk' = 'RustDesk'; 'UltraViewer' = 'UltraViewer'; 'ScreenConnect' = 'ScreenConnect'; 'Splashtop' = 'Splashtop'; 'SRService' = 'Splashtop'; 'AteraAgent' = 'Atera'; 'LogMeIn' = 'LogMeIn'; 'Supremo' = 'Supremo'; 'ToDesk' = 'ToDesk'; 'AweSun' = 'AweSun'; 'AA_v3' = 'Ammyy Admin'; 'RemotePC' = 'RemotePC'; 'QuickAssist' = 'Assistance rapide' }
    $found = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $n = $_.ProcessName; foreach ($k in $remote.Keys) { if ($n -like "$k*") { $remote[$k] } } } | Select-Object -Unique)
    if ($found.Count) { & $add 'Attention' ("Logiciel de prise de contrôle à distance ouvert : " + ($found -join ', ')) "Si c'est vous qui l'utilisez, tout va bien. Sinon, fermez-le et désinstallez-le : les arnaqueurs au « faux support technique » s'en servent pour prendre la main sur le PC." 'Applications' 'ms-settings:appsfeatures' }
    $pe = & $reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'ProxyEnable'
    $pac = & $reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'AutoConfigURL'
    if ($pe -eq 1 -or $pac) {
        $srv = if ($pac) { $pac } else { & $reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'ProxyServer' }
        & $add 'Attention' "Proxy configuré : $srv" "Tout le trafic web passe par ce serveur. Si vous ne l'avez pas mis en place (VPN, entreprise), un logiciel malveillant peut s'en servir pour espionner votre navigation." 'Paramètres' 'ms-settings:network-proxy'
    }
    # Fichier hosts : on ignore les sites de développement locaux, le réseau local et Tailscale.
    # Restent : les sites envoyés vers un serveur extérieur, et les sites de sécurité bloqués.
    try {
        $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        $known = 'microsoft|windowsupdate|windows\.com|norton|avast|avg\.com|kaspersky|eset|bitdefender|malwarebytes|mcafee|avira|virustotal|google|paypal|apple\.com|steampowered|epicgames'
        $redir = New-Object System.Collections.Generic.List[object]; $blocked = New-Object System.Collections.Generic.List[string]
        foreach ($line in @(Get-Content -LiteralPath $hosts -ErrorAction Stop)) {
            $p = @(($line -replace '#.*$', '').Trim() -split '\s+' | Where-Object { $_ })
            if ($p.Count -lt 2) { continue }
            $ip = $p[0]
            foreach ($h in $p[1..($p.Count - 1)]) {
                if ($h -match '^(localhost|localhost\.localdomain|ip6-\w+)$' -or $h -match '\.(test|local|localhost|lan|internal|home\.arpa|ts\.net\.?)$' -or $h -notmatch '\.') { continue }
                if ($ip -match '^(127\.|0\.0\.0\.0$|::1?$|::$)') { if ($h -match $known) { $blocked.Add($h) } }
                elseif ($ip -notmatch '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|169\.254\.|f[cd]|fe80)') { $redir.Add([pscustomobject]@{ Host = $h; Ip = $ip }) }
            }
        }
        if ($blocked.Count) { & $add 'Attention' "$($blocked.Count) site(s) de sécurité ou connus bloqués dans le fichier hosts" ("Bloqués : " + (($blocked | Select-Object -First 4) -join ', ') + ". Un virus fait souvent ça pour empêcher l'antivirus ou Windows de se mettre à jour. Si vous ne l'avez pas fait vous-même, supprimez ces lignes.") 'Ouvrir le dossier' 'sec-hosts' }
        if ($redir.Count) {
            $ips = @($redir | Group-Object Ip | Sort-Object Count -Descending | ForEach-Object { $_.Name })
            & $add 'Attention' "$($redir.Count) site(s) redirigé(s) vers un serveur extérieur (fichier hosts)" ("Par exemple " + (($redir | Select-Object -First 3 | ForEach-Object { $_.Host }) -join ', ') + " → " + ($ips -join ', ') + ". Ces adresses n'arrivent pas sur le vrai site mais sur ce serveur. Si vous n'avez pas ajouté ces lignes vous-même (ou avec un outil de confiance), un logiciel a pu le faire pour vous envoyer vers de faux sites. Pour simplement bloquer un site, on utilise 0.0.0.0.") 'Ouvrir le dossier' 'sec-hosts' }
    } catch {}

    # --- Comptes ---
    try {
        foreach ($u in @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Enabled })) {
            $sid = [string]$u.SID
            if ($sid -match '-500$') { & $add 'Attention' "Compte Administrateur intégré activé (« $($u.Name) »)" "Ce compte caché a tous les droits sans confirmation UAC. Désactivez-le si vous ne vous en servez pas." 'Désactiver' "sec-disable-user:$($u.Name)" }
            elseif ($sid -match '-501$') { & $add 'Attention' "Compte Invité activé (« $($u.Name) »)" "N'importe qui peut ouvrir une session sans mot de passe. Désactivez-le." 'Désactiver' "sec-disable-user:$($u.Name)" }
        }
    } catch {}

    # --- Programmes au démarrage sans signature numérique ---
    try {
        $uns = New-Object System.Collections.Generic.List[string]
        foreach ($it in @(Get-StartupItems | Where-Object { $_.Enabled -and $_.Kind -ne 'uwp' })) {
            $exe = Get-ExePath $it.Command
            if (-not $exe -or -not (Test-Path -LiteralPath $exe) -or $exe -match 'PC Doctor') { continue }
            $sig = Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction SilentlyContinue
            if ($sig -and $sig.Status -ne 'Valid') { $uns.Add($it.DisplayName) }
        }
        if ($uns.Count) { & $add 'Info' "$($uns.Count) programme(s) au démarrage sans signature numérique" ((($uns | Select-Object -First 4) -join ', ') + ". Pas forcément dangereux (petits logiciels gratuits), mais vérifiez que vous les connaissez ; sinon, désactivez-les.") 'Démarrage' 'goto:startup' }
    } catch {}

    [pscustomobject]@{ Items = @($list | Sort-Object Order); Facts = [pscustomobject]$facts; IsAdmin = $isAdmin }
}

function Get-CleanableItems {
    $L = $env:LOCALAPPDATA
    $downloads = Join-Path $env:USERPROFILE 'Downloads'
    try { $p = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path; if ($p) { $downloads = $p } } catch {}

    $folders = @(
        @('Fichiers temporaires (utilisateur)', $env:TEMP, 'Bouton « Vider les fichiers temporaires »', $true),
        @('Fichiers temporaires (Windows)', "$env:windir\Temp", 'Bouton « Vider les fichiers temporaires » (mode admin conseillé)', $true),
        @('Cache Windows Update', "$env:windir\SoftwareDistribution\Download", 'Nettoyage de disque Windows > « Nettoyer les fichiers système »', $true),
        @("Rapports d'erreurs Windows", "$env:ProgramData\Microsoft\Windows\WER", 'Nettoyage de disque Windows', $true),
        @('Cache DirectX (shaders)', "$L\D3DSCache", 'Nettoyage de disque Windows (se reconstruit tout seul)', $true),
        @('Cache NVIDIA', "$L\NVIDIA\DXCache", 'Se reconstruit tout seul', $true),
        @('Cache Chrome', "$L\Google\Chrome\User Data\Default\Cache", 'Vider depuis Chrome (Ctrl+Maj+Suppr)', $false),
        @('Cache Edge', "$L\Microsoft\Edge\User Data\Default\Cache", 'Vider depuis Edge (Ctrl+Maj+Suppr)', $false),
        @('Ancien Windows (Windows.old)', "$env:SystemDrive\Windows.old", 'Nettoyage de disque > « Installations précédentes de Windows »', $true),
        @('Mini-dumps (écrans bleus)', "$env:windir\Minidump", 'Nettoyage de disque Windows', $true),
        @('Téléchargements', $downloads, 'À trier à la main : souvent plein de vieux installeurs', $false)
    )
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($f in $folders) {
        if (-not $f[1] -or -not (Test-Path -LiteralPath $f[1])) { continue }
        $size = [double][PCDoctor.DiskScanner]::QuickSize($f[1])
        if ($size -le 0) { continue }
        $rows.Add([pscustomobject]@{ Name = $f[0]; Path = $f[1]; SizeBytes = $size; SizeText = (Format-Size $size); Advice = $f[2]; Reclaimable = $f[3] })
    }

    $rb = [double][PCDoctor.RecycleBin]::Size()
    if ($rb -gt 0) { $rows.Add([pscustomobject]@{ Name = 'Corbeille'; Path = '(corbeille)'; SizeBytes = $rb; SizeText = (Format-Size $rb); Advice = 'Bouton « Vider la corbeille »'; Reclaimable = $true }) }

    $sd = $env:SystemDrive
    $sysFiles = @(
        @('Fichier d''hibernation (hiberfil.sys)', "$sd\hiberfil.sys", 'Désactivable si vous n''utilisez pas la veille prolongée : « powercfg /h off » en admin', $false),
        @('Mémoire virtuelle (pagefile.sys)', "$sd\pagefile.sys", 'Ne pas supprimer : utilisé par Windows quand la RAM est pleine', $false),
        @('Dump mémoire complet (MEMORY.DMP)', "$env:windir\MEMORY.DMP", 'Nettoyage de disque > « Fichiers de vidage mémoire »', $true)
    )
    foreach ($f in $sysFiles) {
        $size = [double][PCDoctor.DiskScanner]::FileSize($f[1])
        if ($size -le 0) { continue }
        $rows.Add([pscustomobject]@{ Name = $f[0]; Path = $f[1]; SizeBytes = $size; SizeText = (Format-Size $size); Advice = $f[2]; Reclaimable = $f[3] })
    }
    $rows | Sort-Object SizeBytes -Descending
}
'@

$script:FullJobCode = @'
function Invoke-Safe([scriptblock]$sb) { try { & $sb } catch { Write-Error ("Collecte : " + $_) } }
[pscustomobject]@{
    Summary   = Invoke-Safe { Get-PCSummary }
    Processes = @(Invoke-Safe { Get-ProcessUsage })
    Startup   = @(Invoke-Safe { Get-StartupItems })
    Crashes   = @(Invoke-Safe { Get-CrashEvents -Days 30 })
    Cleanable = @(Invoke-Safe { Get-CleanableItems })
    Memory    = Invoke-Safe { Get-MemoryInfo }
    Cpu       = Invoke-Safe { Get-CpuOcInfo }
    OcTools   = @(Invoke-Safe { Get-OcTools })
    ProblemDevices = @(Invoke-Safe { Get-ProblemDevices })
    FastStartup = Invoke-Safe { Get-FastStartup }
    Gpu       = Invoke-Safe { Get-GpuLive }
    Disks     = @(Invoke-Safe { Get-DiskHealth })
}
'@

. ([scriptblock]::Create($script:CollectorsCode))

# ---------------------------------------------------------------------------
#  Analyse : constats + score
# ---------------------------------------------------------------------------
function Get-CrashStats($d) {
    $c = @($d.Crashes | Where-Object { $_ })
    $hard = @($c | Where-Object { $_.Category -eq 'Arrêt brutal' })
    [pscustomobject]@{
        All      = $c
        Hard     = $hard
        Silent   = @($hard | Where-Object { $_.Detail -like 'Coupure nette*' })
        Bsod     = @($c | Where-Object { $_.Category -eq 'Écran bleu (BSOD)' })
        Tdr      = @($c | Where-Object { $_.Category -eq 'Pilote graphique' })
        Disk     = @($c | Where-Object { $_.Category -eq 'Erreur disque' -or $_.Category -eq 'Système de fichiers' })
        AppGroups = @($c | Where-Object { $_.App } | Group-Object App | Sort-Object Count -Descending)
        LastHard = ($hard | Sort-Object Date -Descending | Select-Object -First 1)
    }
}

function Get-Findings($d) {
    $list = New-Object System.Collections.Generic.List[object]
    $order = @{ 'Critique' = 0; 'Attention' = 1; 'Info' = 2; 'OK' = 3 }
    $add = {
        param($sev, $title, $advice, $actLabel, $actId)
        $list.Add([pscustomobject]@{ Severity = $sev; Title = $title; Advice = $advice; Order = $order[$sev]; ActionLabel = $actLabel; ActionId = $actId })
    }

    $procs = @($d.Processes | Where-Object { $_ })
    $topRam = ($procs | Sort-Object RamBytes -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Description) ($($_.RamText))" }) -join ', '
    $topCpu = ($procs | Sort-Object CpuPct -Descending | Select-Object -First 3 | Where-Object { $_.CpuPct -ge 1 } | ForEach-Object { "$($_.Description) ($($_.CpuText))" }) -join ', '
    $cs = Get-CrashStats $d

    # Plantages
    if ($cs.Hard.Count) {
        $sev = if ($cs.Hard.Count -ge 5) { 'Critique' } else { 'Attention' }
        $msg = "Dernier le $($cs.LastHard.DateText). "
        if ($cs.Silent.Count -ge [math]::Ceiling($cs.Hard.Count / 2)) { $msg += "$($cs.Silent.Count) fois sans écran bleu : le PC se coupe net ou gèle complètement. C'est presque toujours matériel ou réglage (RAM, température, alimentation, pilote graphique)." }
        else { $msg += "Le PC s'est éteint ou a figé sans s'arrêter proprement." }
        & $add $sev "Le PC a planté $($cs.Hard.Count) fois ces 30 derniers jours" $msg 'Voir les solutions' 'goto:solutions'
    }
    if ($cs.Bsod.Count) {
        $codes = ($cs.Bsod | ForEach-Object { if ($_.Detail -match '0x[0-9a-fA-F]{8}') { $Matches[0] } } | Select-Object -Unique) -join ', '
        & $add 'Critique' "$($cs.Bsod.Count) écran(s) bleu(s) ces 30 derniers jours" "Codes : $codes. Causes fréquentes : pilote, RAM instable ou surchauffe." 'Voir les solutions' 'goto:solutions'
    }
    if ($cs.Disk.Count) { & $add 'Critique' "$($cs.Disk.Count) erreur(s) de disque ces 30 derniers jours" "Signe possible d'un disque qui fatigue ou d'un câble défectueux. Sauvegardez vos données importantes." 'Voir les solutions' 'goto:solutions' }
    if ($cs.Tdr.Count) { & $add 'Attention' "Le pilote graphique a planté $($cs.Tdr.Count) fois" "Écran noir quelques secondes ou jeu qui crashe : réinstallez proprement le pilote graphique." 'Voir les solutions' 'goto:solutions' }
    foreach ($a in @($cs.AppGroups | Where-Object { $_.Count -ge 2 } | Select-Object -First 3)) { & $add 'Attention' "« $($a.Name) » a planté ou figé $($a.Count) fois" "Mettez ce logiciel à jour, réinstallez-le, ou désactivez-le s'il se lance au démarrage." 'Voir les plantages' 'goto:crashes' }
    if ($d.Memory -and $d.Memory.XmpState -eq 'On' -and $cs.Silent.Count) { & $add 'Attention' "RAM overclockée (profil EXPO/XMP à $($d.Memory.Configured) MT/s)" "Première piste pour les coupures nettes : désactivez EXPO/XMP dans le BIOS quelques jours pour tester." 'Voir les solutions' 'goto:solutions' }
    $ocRun = @($d.OcTools | Where-Object { $_ -and $_.Running })
    if ($ocRun.Count) { & $add $(if ($cs.Hard.Count) { 'Attention' } else { 'Info' }) "Logiciel d'overclocking actif : $(($ocRun | ForEach-Object { $_.Name }) -join ', ')" "Un overclocking de la carte graphique ou du processeur peut provoquer gels et coupures. Remettez les réglages d'usine pour tester." 'Voir les performances' 'goto:perf' }
    $probs = @($d.ProblemDevices | Where-Object { $_ -and $_.Serious })
    if ($probs.Count) { & $add 'Attention' "$($probs.Count) périphérique(s) en erreur" ((($probs | Select-Object -First 3 | ForEach-Object { "$($_.Name) : $($_.Problem)" }) -join '  ·  ') + '.') 'Voir les pilotes' 'goto:drivers' }
    if ($d.Gpu -and $d.Gpu.Temp -ge 83) { & $add 'Attention' ("Carte graphique chaude : {0:N0} °C" -f $d.Gpu.Temp) "Vérifiez la ventilation du boîtier et dépoussiérez la carte graphique." 'Températures' 'goto:perf' }
    foreach ($dk in @($d.Disks | Where-Object { $_ })) {
        if ($dk.ReadErrors -gt 0 -or $dk.WriteErrors -gt 0) { & $add 'Critique' "Disque « $($dk.Name) » : erreurs non corrigées" "Le disque n'arrive plus à lire ou écrire certaines données. Sauvegardez vos fichiers et prévoyez de le remplacer." 'Santé des disques' 'goto:perf' }
        if ($null -ne $dk.Wear -and $dk.Wear -ge 80) { & $add 'Attention' "SSD « $($dk.Name) » usé à $($dk.Wear) %" "Il approche de sa fin de vie théorique : sauvegardez régulièrement et prévoyez son remplacement." 'Santé des disques' 'goto:perf' }
        if ($null -ne $dk.Temp -and $dk.Temp -ge $dk.HotLimit) { & $add 'Attention' "Disque « $($dk.Name) » chaud ($($dk.Temp) °C)" "Améliorez la ventilation autour du disque (un dissipateur pour un SSD NVMe)." 'Santé des disques' 'goto:perf' }
    }
    $bbOn = $false
    try { $bbOn = [PCDoctor.BlackBox]::IsRunning() } catch {}
    if ($cs.Hard.Count -and -not $bbOn) { & $add 'Info' 'Activez la boîte noire pour comprendre les coupures' "Elle enregistre l'état du PC toutes les 2 secondes : après la prochaine coupure, vous verrez si c'était la chauffe, un pic de consommation ou autre chose." 'Activer la boîte noire' 'bb-start' }

    $s = $d.Summary
    if ($s) {
        if ($s.RamUsedPct -ge 90) { & $add 'Critique' "Mémoire vive saturée ($($s.RamUsedPct) %)" "Windows utilise le disque à la place de la RAM : tout ralentit. Plus gros consommateurs : $topRam." 'Voir les processus' 'goto:procs' }
        elseif ($s.RamUsedPct -ge 80) { & $add 'Attention' "Mémoire vive bien remplie ($($s.RamUsedPct) %)" "Peu de marge avant les ralentissements. Plus gros consommateurs : $topRam." 'Voir les processus' 'goto:procs' }
        if ($s.RamTotal -lt 7.5GB) { & $add 'Attention' "Peu de mémoire vive ($(Format-Size $s.RamTotal))" "8 Go est un minimum aujourd'hui, 16 Go conseillés pour le jeu. Ajouter de la RAM est souvent l'amélioration la moins chère." $null $null }
        if ($s.CpuLoad -ge 85) { & $add 'Attention' "Processeur très sollicité ($($s.CpuLoad) %)" "En ce moment : $topCpu." 'Voir les processus' 'goto:procs' }
        if ($null -ne $s.DiskBusy -and $s.DiskBusy -ge 90) { & $add 'Attention' ("Disque occupé à {0:N0} %" -f $s.DiskBusy) "Le disque n'arrive pas à suivre, ce qui fige souvent tout le PC (mises à jour, antivirus, indexation ou disque mécanique)." $null $null }
        foreach ($dr in $s.Drives) {
            $label = "$($dr.Drive) $(if ($dr.Label) { "($($dr.Label))" })".Trim()
            if ($dr.UsedPct -ge 95) { & $add 'Critique' "Disque $label presque plein ($(Format-Size $dr.Free) libres)" "Un disque système plein ralentit Windows et bloque les mises à jour." "Trouver ce qui prend la place" 'goto:disk' }
            elseif ($dr.UsedPct -ge 88) { & $add 'Attention' "Disque $label rempli à $($dr.UsedPct) % ($(Format-Size $dr.Free) libres)" "Gardez au moins 10 à 15 % d'espace libre." "Trouver ce qui prend la place" 'goto:disk' }
        }
        foreach ($pd in $s.PhysicalDisks) {
            if ($pd.Health -eq 'Mauvais' -or $pd.Health -eq 'Avertissement') { & $add 'Critique' "Disque « $($pd.Name) » : état $($pd.Health)" "Windows signale un problème matériel sur ce disque. Sauvegardez vos fichiers dès maintenant et prévoyez de le remplacer." $null $null }
        }
        if ($s.SystemDiskMedia -eq 'HDD') { & $add 'Attention' 'Windows est installé sur un disque dur mécanique' "Première cause de lenteur au démarrage et à l'ouverture des programmes. Un SSD change complètement le ressenti." $null $null }
        $days = [math]::Floor($s.Uptime.TotalDays)
        if ($days -ge 7) { & $add 'Attention' "PC pas redémarré depuis $days jours" "Faites Démarrer > Marche/Arrêt > « Redémarrer ». « Arrêter » ne remet pas tout à zéro à cause du démarrage rapide de Windows." $null $null }
        if ($s.PowerPlanGuid -eq 'a1841308-3541-4fab-bc81-f71556f20b4a') { & $add 'Attention' "Mode « Économie d'énergie » activé" "Le processeur est bridé. Passez en mode « Équilibré » ou « Performances élevées »." 'Réglages d''alimentation' 'ms-settings:powersleep' }
        $realGpus = @($s.Gpus | Where-Object { $_.Status -eq 'OK' -and $_.Name -match 'NVIDIA|AMD|Radeon|Intel|Arc' })
        $basic = @($s.Gpus | Where-Object { $_.Status -eq 'OK' -and $_.Name -match 'Basic Display|de base Microsoft|vidéo de base' })
        if ($basic.Count -and -not $realGpus.Count) { & $add 'Critique' 'Aucun pilote graphique installé' "La carte graphique tourne avec le pilote de base de Windows : affichage lent, jeux impossibles." 'Voir les solutions' 'goto:solutions' }
        foreach ($g in $realGpus) {
            if ($g.DriverDate -and $g.DriverDate -lt (Get-Date).AddMonths(-18) -and $g.Name -match 'NVIDIA|AMD|Radeon|GeForce|Arc') { & $add 'Info' "Pilote graphique ancien ($($g.DriverDate.ToString('MM/yyyy')))" "Une mise à jour peut corriger plantages et lenteurs en jeu." 'Voir les solutions' 'goto:solutions' }
        }
    }

    $on = @($d.Startup | Where-Object { $_ -and $_.Enabled })
    $rec = @($on | Where-Object { $_.Advice -eq 'Désactivable' })
    if ($on.Count -ge 8 -or $rec.Count -ge 3) {
        $sev = if ($on.Count -ge 12) { 'Attention' } else { 'Info' }
        $names = ($rec | Select-Object -First 5 | ForEach-Object { $_.DisplayName }) -join ', '
        $txt = "$($rec.Count) d'entre eux peuvent être désactivés sans souci"
        if ($names) { $txt += " ($names…)" }
        & $add $sev "$($on.Count) programmes se lancent au démarrage" "$txt. Ça accélère l'allumage et libère de la mémoire." 'Gérer le démarrage' 'goto:startup'
    }

    $clean = @($d.Cleanable | Where-Object { $_ -and $_.Reclaimable })
    $cleanTotal = [double]($clean | Measure-Object SizeBytes -Sum).Sum
    if ($cleanTotal -ge 2GB) { & $add 'Info' "$(Format-Size $cleanTotal) récupérables facilement" "Fichiers temporaires, caches et corbeille." 'Nettoyer' 'goto:clean' }

    if ($topRam) { & $add 'Info' 'Ce qui consomme le plus de mémoire en ce moment' "$topRam." 'Voir les processus' 'goto:procs' }

    if (-not ($list | Where-Object { $_.Order -le 1 })) { & $add 'OK' 'Aucun problème majeur détecté' "Le PC semble en bonne santé. Si vous avez des lenteurs, regardez l'onglet Processus au moment où ça rame." $null $null }

    $list | Sort-Object Order
}

function Get-HealthScore($findings) {
    $crit = @($findings | Where-Object { $_.Severity -eq 'Critique' }).Count
    $warn = @($findings | Where-Object { $_.Severity -eq 'Attention' }).Count
    [int][math]::Max(5, [math]::Min(100, 100 - 22 * $crit - 8 * $warn))
}

# ---------------------------------------------------------------------------
#  Solutions pour les plantages (adaptées à ce qui a été détecté)
# ---------------------------------------------------------------------------
function Get-CrashDiagnosis($d) {
    $cs = Get-CrashStats $d
    if ($cs.Silent.Count -ge 1) {
        return "Votre PC s'est coupé net $($cs.Silent.Count) fois en 30 jours, sans écran bleu (dernière fois le $($cs.LastHard.DateText)). Ce type de plantage ne vient quasiment jamais d'un logiciel : c'est le matériel ou ses réglages qui lâchent (RAM, température, alimentation ou pilote graphique). Testez les solutions dans l'ordre, une à la fois, et utilisez le PC quelques jours entre chaque pour voir si ça revient."
    }
    if ($cs.Bsod.Count -ge 1) { return "Votre PC a fait $($cs.Bsod.Count) écran(s) bleu(s) en 30 jours. Les causes les plus fréquentes sont un pilote défectueux, une RAM instable ou une surchauffe. Suivez les solutions dans l'ordre." }
    if ($cs.Hard.Count -ge 1) { return "Votre PC s'est arrêté brutalement $($cs.Hard.Count) fois en 30 jours. Suivez les solutions dans l'ordre." }
    if ($cs.AppGroups.Count) { return "Pas de plantage complet du PC ces 30 derniers jours, mais certains logiciels plantent. Les solutions ci-dessous aident à les stabiliser." }
    return "Aucun plantage détecté ces 30 derniers jours. Voici quand même les vérifications utiles si un problème apparaît."
}

function Get-Solutions($d) {
    $s = $d.Summary
    $cs = Get-CrashStats $d
    $list = New-Object System.Collections.Generic.List[object]
    $idx = 0
    $act = { param($label, $id) [pscustomobject]@{ Label = $label; Id = $id } }
    $addS = {
        param([bool]$rec, $title, $why, $steps, $actions)
        $script:solIdx++
        $list.Add([pscustomobject]@{ Recommended = $rec; Title = $title; Why = $why; Steps = $steps; Actions = @($actions | Where-Object { $_ }); Index = $list.Count; Num = '' })
    }

    $gpu = if ($s) { [string]$s.MainGpu } else { '' }
    $board = if ($s) { [string]$s.Board } else { '' }
    $isAsus = ($board + ' ' + $s.Model) -match 'ASUS'
    $isMsi = ($board + ' ' + $s.Model) -match 'MSI|Micro-Star'
    $isGigabyte = ($board + ' ' + $s.Model) -match 'Gigabyte'
    $isAmdCpu = $s -and $s.CpuName -match 'AMD|Ryzen'
    $silent = $cs.Silent.Count
    $bsod = $cs.Bsod.Count

    # 0. Boîte noire
    $bbOn = $false
    try { $bbOn = [PCDoctor.BlackBox]::IsRunning() } catch {}
    if ($cs.Hard.Count -or $bsod) {
        if ($bbOn) {
            & $addS $false 'Boîte noire : active' `
                "PC Doctor enregistre l'état du PC toutes les 2 secondes. À la prochaine coupure, ouvrez la page Boîte noire pour voir ce qui se passait juste avant." `
                "Rien à faire : laissez-la tourner (icône PC Doctor près de l'horloge)." `
                @((& $act 'Ouvrir la boîte noire' 'goto:blackbox'))
        } else {
            & $addS $true 'Activer la boîte noire' `
                "Pour trouver la cause, il faut savoir ce qui se passait au moment de la coupure. La boîte noire enregistre en continu la température et la consommation de la carte graphique, le processeur, la mémoire et le programme utilisé, et l'écrit sur le disque à chaque mesure : les données survivent à la coupure." `
                "1. Cliquez sur « Activer la boîte noire » : elle démarre et se relancera avec Windows.`n2. Utilisez le PC normalement.`n3. Après la prochaine coupure, ouvrez PC Doctor > Boîte noire > « Analyser »." `
                @((& $act 'Activer la boîte noire' 'bb-start'), (& $act 'En savoir plus' 'goto:blackbox'))
        }
    }
    if ($cs.Hard.Count) {
        & $addS $false 'Reproduire la coupure avec le test de stabilité' `
            "Plutôt que d'attendre la prochaine coupure, provoquez-la : le test fait tourner le processeur, la mémoire et la carte graphique à fond pendant 5 à 15 minutes en surveillant les températures. Si le PC se coupe, la boîte noire montre pourquoi ; s'il tient, l'alimentation et le refroidissement supportent la pleine charge." `
            "1. Enregistrez vos documents et fermez vos jeux.`n2. Lancez Core Temp pour que la température du processeur soit surveillée.`n3. Page Test de stabilité > « Lancer le test » (10 minutes)." `
            @((& $act 'Ouvrir le test de stabilité' 'goto:stress'))
    }

    # 1. RAM EXPO / XMP
    $bios = "Cherchez l'option EXPO, XMP ou DOCP et mettez-la sur « Désactivé » ou « Auto »."
    if ($isAsus) { $bios = "Carte mère ASUS : appuyez sur F7 (mode avancé) > onglet « Ai Tweaker » > « Ai Overclock Tuner » : passez de EXPO/DOCP/XMP à « Auto »." }
    elseif ($isMsi) { $bios = "Carte mère MSI : désactivez « A-XMP » / « EXPO » sur l'écran principal du BIOS." }
    elseif ($isGigabyte) { $bios = "Carte mère Gigabyte : onglet « Tweaker » > « Extreme Memory Profile (X.M.P.) » / EXPO : « Disabled »." }
    $mem = $d.Memory
    $ramRec = ($silent -ge 1 -or $bsod -ge 1)
    $ramTitle = "Désactiver l'overclocking de la RAM (EXPO / XMP)"
    $ramState = ''
    if ($mem -and $mem.XmpState -eq 'On') { $ramState = " Sur votre PC, la RAM tourne à $($mem.Configured) MT/s : le profil EXPO/XMP est bien activé." }
    elseif ($mem -and $mem.XmpState -eq 'Off') { $ramState = " Sur votre PC, la RAM tourne déjà en dessous de la vitesse du kit ($($mem.Configured) MT/s) : ce test est déjà fait."; $ramRec = $false; $ramTitle += ' : déjà fait' }
    & $addS $ramRec $ramTitle `
        ("Les coupures nettes et écrans bleus aléatoires viennent très souvent d'une RAM poussée au-delà de ce qu'elle tient vraiment (profil EXPO/XMP activé dans le BIOS)$(if ($isAmdCpu) { ', particulièrement sur les processeurs Ryzen' }). C'est gratuit, rapide et réversible : c'est le premier test à faire." + $ramState) `
        ("1. Cliquez sur « Redémarrer dans le BIOS » (enregistrez votre travail avant).`n2. $bios`n3. Appuyez sur F10 pour enregistrer et redémarrer.`n4. Utilisez le PC normalement quelques jours. Si les plantages disparaissent, c'était la RAM : vous pouvez réactiver EXPO avec une fréquence un cran en dessous, ou mettre à jour le BIOS.`n5. Revenez dans PC Doctor > Performances : la vitesse de la RAM doit avoir baissé.") `
        @((& $act 'Redémarrer dans le BIOS' 'bios'), (& $act "Voir l'état de la RAM" 'goto:perf'))

    # 1 bis. Overclocking logiciel
    $oc = @($d.OcTools | Where-Object { $_ })
    if ($oc.Count) {
        $ocNames = ($oc | ForEach-Object { "$($_.Name) ($($_.Target)$(if ($_.Running) { ', actif' }))" }) -join ', '
        & $addS ($silent -ge 1 -and @($oc | Where-Object { $_.Running }).Count -gt 0) "Retirer l'overclocking logiciel" `
            "Logiciels d'overclocking trouvés : $ocNames. Un overclocking ou un undervolt trop poussé fait planter le PC net, surtout en jeu." `
            "1. MSI Afterburner / GPU Tweak : cliquez sur le bouton « Reset » (flèche ronde), puis « Apply », et décochez « Appliquer l'overclocking au démarrage » dans les réglages.`n2. Ryzen Master / Intel XTU : bouton « Reset » ou « Default ».`n3. Testez quelques jours avec les réglages d'usine." `
            @((& $act 'Voir les performances' 'goto:perf'))
    }

    # 2. Températures
    & $addS ($silent -ge 1) 'Vérifier les températures' `
        "Quand le processeur ou la carte graphique chauffe trop, le PC se coupe d'un coup pour se protéger, surtout en jeu." `
        "1. $(if ($d.Gpu) { "Laissez PC Doctor ouvert pendant que vous jouez : il enregistre la température maximale de la carte graphique (page Performances)." } else { 'Installez HWiNFO (gratuit) et lancez-le en mode « Sensors only ».' })`n2. Pour le processeur, utilisez HWiNFO (mode « Sensors only ») et regardez la colonne « Maximum » après 15 minutes de jeu.`n3. Processeur au-dessus de 90 °C ou carte graphique au-dessus de 85 °C : dépoussiérez le PC (bombe d'air), vérifiez que tous les ventilateurs tournent, et refaites la pâte thermique si le PC a plusieurs années." `
        @($(if ($d.Gpu) { & $act 'Températures en direct' 'goto:perf' }), (& $act 'Télécharger HWiNFO' 'url:https://www.hwinfo.com/download/'))

    # 3. Alimentation
    $watt = $null
    switch -Regex ($gpu) {
        '5090|4090' { $watt = 1000; break }
        '5080|4080|7900 XTX' { $watt = 850; break }
        '5070 Ti|4070 Ti|7900|3090|3080' { $watt = 750; break }
        '5070|4070|3070|7800|7700|6800' { $watt = 650; break }
    }
    $why = "Une alimentation trop juste, de mauvaise qualité ou fatiguée coupe le PC net lors des pics de consommation (typiquement en jeu), sans écran bleu."
    if ($watt) { $why += " Avec une $gpu, il faut une alimentation de bonne qualité d'au moins $watt W." }
    $canLimit = ($d.Gpu -and $d.Gpu.PowerDefault)
    $plStep = if ($canLimit) { "3. Test simple, directement ici : cliquez sur « Limiter la carte graphique à 75 % » et utilisez le PC quelques jours (environ 5 % de FPS en moins). Si les coupures disparaissent, l'alimentation est en cause. Le réglage revient à 100 % au redémarrage, ou avec le bouton « Revenir à 100 % »." } else { "3. Test simple : limitez la puissance de la carte graphique à 75 % (MSI Afterburner, curseur « Power Limit »). Si les coupures disparaissent, l'alimentation est en cause." }
    & $addS ($silent -ge 2) "Vérifier l'alimentation" $why `
        "1. Regardez la marque et la puissance (W) sur l'étiquette de l'alimentation, à l'arrière du PC.`n2. Vérifiez que la carte graphique est branchée avec des câbles séparés, pas un seul câble dédoublé en Y.`n$plStep" `
        $(if ($canLimit) { @((& $act 'Limiter la carte graphique à 75 %' 'gpu-pl:75'), (& $act 'Revenir à 100 %' 'gpu-pl:100')) } else { @((& $act 'Télécharger MSI Afterburner' 'url:https://www.msi.com/Landing/afterburner/graphics-cards')) })

    # 4. Pilote graphique
    & $addS ($cs.Tdr.Count -ge 1 -or $silent -ge 1) 'Réinstaller proprement le pilote graphique' `
        "Un pilote graphique corrompu ou instable peut figer complètement le PC ou faire planter les jeux.$(if ($d.Gpu -and $d.Gpu.Driver) { " Pilote installé : $($d.Gpu.Driver)." })" `
        "1. Cliquez sur « Mettre à jour le pilote » : PC Doctor ouvre l'outil du fabricant$(if ($gpu -match 'NVIDIA') { ' (NVIDIA app)' }).`n2. Choisissez l'installation « personnalisée » / « propre » (nouvelle installation) plutôt que l'installation express.`n3. Si les problèmes continuent : désinstallez complètement avec DDU (Display Driver Uninstaller) en mode sans échec, puis réinstallez." `
        @((& $act 'Mettre à jour le pilote' 'gpu-update'), (& $act 'Tous les pilotes' 'goto:drivers'))

    # 5. BIOS
    $biosOld = $s -and $s.BiosDate -and $s.BiosDate -lt (Get-Date).AddMonths(-12)
    $biosTxt = if ($s -and $s.BiosDate) { "Votre BIOS ($($s.BiosVersion)) date du $($s.BiosDate.ToString('dd/MM/yyyy'))." } else { '' }
    & $addS ($biosOld -and ($silent -ge 1 -or $bsod -ge 1)) 'Mettre à jour le BIOS' `
        "$biosTxt Les mises à jour du BIOS corrigent souvent la stabilité de la RAM et du processeur$(if ($isAmdCpu) { ' (AGESA chez AMD)' })." `
        "1. Trouvez votre carte mère$(if ($board) { " ($board)" }) sur le site du fabricant, rubrique Support > BIOS.`n2. Téléchargez la dernière version stable et suivez la procédure (souvent via clé USB, « EZ Flash » chez ASUS, « M-Flash » chez MSI, « Q-Flash » chez Gigabyte).`n3. Ne coupez surtout pas le courant pendant la mise à jour." `
        @($(if ($board) { & $act 'Chercher le BIOS' ('url:https://www.google.com/search?q=' + [uri]::EscapeDataString("$board BIOS support")) }))

    # 6. Test RAM
    & $addS ($bsod -ge 1 -or $silent -ge 3) 'Tester la mémoire vive' `
        "Une barrette de RAM défectueuse provoque des plantages aléatoires, même sans overclocking." `
        "1. Cliquez sur « Lancer le test mémoire » puis choisissez « Redémarrer maintenant ».`n2. Le test dure 10 à 20 minutes, le PC redémarre tout seul ensuite.`n3. Le résultat s'affiche en notification après le redémarrage. Pour un test plus poussé : MemTest86 sur clé USB." `
        @((& $act 'Lancer le test mémoire' 'mdsched'))

    # 7. SFC / DISM
    & $addS ($bsod -ge 1 -or $cs.AppGroups.Count -ge 3) 'Réparer les fichiers de Windows' `
        "Des fichiers système abîmés (après un plantage ou une coupure) peuvent provoquer d'autres plantages." `
        "1. Cliquez sur « Lancer la réparation » et acceptez la demande d'administrateur.`n2. Une fenêtre lance SFC puis DISM : laissez-la tourner (10 à 30 minutes).`n3. Redémarrez le PC à la fin." `
        @((& $act 'Lancer la réparation' 'sfc'))

    # 8. Disque
    & $addS ($cs.Disk.Count -ge 1) 'Vérifier le disque' `
        "Des erreurs disque peuvent figer le PC et corrompre des fichiers." `
        "1. Cliquez sur « Vérifier le disque » et acceptez la demande d'administrateur.`n2. Si des erreurs sont trouvées, Windows proposera de les corriger au prochain redémarrage.`n3. Sauvegardez vos fichiers importants si le disque montre des secteurs défectueux." `
        @((& $act 'Vérifier le disque' 'chkdsk'))

    # 9. Logiciels qui plantent
    if ($cs.AppGroups.Count) {
        $names = ($cs.AppGroups | Select-Object -First 5 | ForEach-Object { "$($_.Name) ($($_.Count)×)" }) -join ', '
        $extra = if ($names -match 'MSI\.CentralServer|MSI Center') { "`nMSI Center est connu pour être instable : si vous n'utilisez pas ses réglages RGB/ventilateurs, désinstallez-le ou désactivez-le au démarrage." } else { '' }
        & $addS $true 'Mettre à jour ou retirer les logiciels qui plantent' `
            "Logiciels qui ont planté ces 30 derniers jours : $names." `
            ("1. Mettez-les à jour depuis leur site officiel, ou réinstallez-les.`n2. S'ils ne vous servent pas, désinstallez-les (Paramètres > Applications) ou désactivez-les au démarrage.$extra") `
            @((& $act 'Applications installées' 'ms-settings:appsfeatures'), (& $act 'Gérer le démarrage' 'goto:startup'))
    }

    # 9 bis. Démarrage rapide
    if ($d.FastStartup -eq $true) {
        & $addS ($silent -ge 3) 'Désactiver le démarrage rapide de Windows' `
            "Avec le démarrage rapide, « Arrêter » ne ferme pas vraiment Windows : les pilotes restent en mémoire d'un allumage à l'autre. Après des plantages, un pilote peut ainsi rester dans un mauvais état. Sans lui, chaque démarrage repart de zéro (quelques secondes de plus au démarrage)." `
            "1. Cliquez sur « Désactiver le démarrage rapide » et acceptez la demande d'administrateur.`n2. C'est réversible à tout moment avec le bouton « Réactiver »." `
            @((& $act 'Désactiver le démarrage rapide' 'fastboot-off'))
    } elseif ($d.FastStartup -eq $false) {
        & $addS $false 'Démarrage rapide de Windows : déjà désactivé' `
            "Chaque démarrage repart de zéro, c'est la configuration la plus stable." `
            "Rien à faire. Vous pouvez le réactiver si vous préférez un démarrage un peu plus rapide." `
            @((& $act 'Réactiver le démarrage rapide' 'fastboot-on'))
    }

    # 10. Windows Update
    & $addS $false 'Mettre tous les pilotes à jour' `
        "Windows Update propose des pilotes (chipset, audio, réseau, Bluetooth…) qui corrigent souvent des plantages." `
        "1. Cliquez sur « Rechercher les pilotes » : PC Doctor liste les mises à jour disponibles.`n2. Cochez celles que vous voulez et cliquez sur « Installer la sélection ».`n3. Installez aussi les pilotes chipset$(if ($isAmdCpu) { ' AMD' }) depuis le site du fabricant (bouton dans la page Pilotes)." `
        @((& $act 'Rechercher les pilotes' 'goto:drivers'), (& $act 'Ouvrir Windows Update' 'ms-settings:windowsupdate'))

    # 11. Fiabilité
    & $addS $false "Consulter l'historique de fiabilité" `
        "Cet outil de Windows montre jour par jour ce qui a planté et ce qui a été installé juste avant : pratique pour repérer qu'un plantage a commencé après une mise à jour ou un nouveau logiciel." `
        "Ouvrez l'outil, cliquez sur les jours avec une croix rouge et regardez ce qui s'est passé juste avant." `
        @((& $act "Ouvrir l'historique de fiabilité" 'reliability'))

    $sorted = @($list | Sort-Object @{ Expression = 'Recommended'; Descending = $true }, Index)
    $n = 0
    foreach ($x in $sorted) { $n++; $x.Num = [string]$n }
    $sorted
}

# ---------------------------------------------------------------------------
#  Interface
# ---------------------------------------------------------------------------
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PC Doctor" Width="1280" Height="820" MinWidth="1000" MinHeight="640"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
        Background="#FFF4F6FA" Foreground="#FF0F172A" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <SolidColorBrush x:Key="Muted" Color="#FF475569"/>
    <BooleanToVisibilityConverter x:Key="B2V"/>
    <SolidColorBrush x:Key="Line" Color="#FFE2E8F0"/>
    <SolidColorBrush x:Key="Accent" Color="#FF3B6EF5"/>

    <!-- Boutons -->
    <Style TargetType="Button">
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Background" Value="#FF3B6EF5"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.75"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Secondary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#FF0F172A"/>
      <Setter Property="BorderBrush" Value="#FFD5DCE6"/>
    </Style>
    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#FFEF4444"/>
    </Style>
    <Style x:Key="Small" TargetType="Button" BasedOn="{StaticResource Secondary}">
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0"/>
    </Style>

    <!-- Textes -->
    <Style x:Key="PageTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="26"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Display, Segoe UI"/>
    </Style>
    <Style x:Key="PageSub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FF475569"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,6,0,0"/>
      <Setter Property="FontSize" Value="14.5"/>
      <Setter Property="LineHeight" Value="22"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="MutedText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FF475569"/>
    </Style>
    <!-- Lien « Détails / Masquer » qui déplie une explication -->
    <Style x:Key="DetailsToggle" TargetType="ToggleButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#FF3B6EF5"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <TextBlock x:Name="T" Text="Détails" FontSize="13" FontWeight="SemiBold" Foreground="{TemplateBinding Foreground}"/>
              <TextBlock x:Name="C" Text="&#xE70D;" FontFamily="{StaticResource Icons}" FontSize="10" Margin="6,4,0,0" Foreground="{TemplateBinding Foreground}"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="T" Property="Text" Value="Masquer"/>
                <Setter TargetName="C" Property="Text" Value="&#xE70E;"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Wrap" TargetType="TextBlock">
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,8"/>
    </Style>

    <!-- Cartes -->
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="20,18"/>
      <Setter Property="BorderBrush" Value="#FFE6EAF0"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Effect">
        <Setter.Value><DropShadowEffect BlurRadius="18" ShadowDepth="2" Direction="270" Opacity="0.06"/></Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Panel" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="6"/>
      <Setter Property="BorderBrush" Value="#FFE6EAF0"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>

    <!-- Barres de progression -->
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Foreground" Value="#FF3B6EF5"/>
      <Setter Property="Background" Value="#FFEDF1F7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border x:Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="4"/>
              <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="4" HorizontalAlignment="Left"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Barres de défilement fines -->
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True" Focusable="False">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Border Background="#FFC5CDD8" CornerRadius="4" Margin="2"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="10"/>
          <Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track" IsDirectionReversed="False" Focusable="False">
                  <Track.Thumb>
                    <Thumb>
                      <Thumb.Template>
                        <ControlTemplate TargetType="Thumb"><Border Background="#FFC5CDD8" CornerRadius="4" Margin="2"/></ControlTemplate>
                      </Thumb.Template>
                    </Thumb>
                  </Track.Thumb>
                </Track>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#FF0F172A"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,4"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>

    <!-- Tableaux -->
    <Style TargetType="DataGrid">
      <Setter Property="Foreground" Value="#FF0F172A"/>
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#FFF1F4F8"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="RowBackground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="SelectionMode" Value="Single"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserResizeRows" Value="False"/>
      <Setter Property="MinRowHeight" Value="36"/>
      <Setter Property="EnableRowVirtualization" Value="True"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Padding" Value="12,10"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#FF64748B"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="BorderBrush" Value="#FFE6EAF0"/>
    </Style>
    <Style TargetType="DataGridRow">
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FFF7F9FC"/></Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#FFE8EFFE"/>
          <Setter Property="Foreground" Value="#FF0F172A"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- Onglets internes (style segmenté) -->
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#FF64748B"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Padding="14,7" Margin="0,0,4,0" CornerRadius="7" Background="Transparent">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="White"/>
                <Setter Property="Foreground" Value="#FF0F172A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Navigation -->
    <Style x:Key="NavItem" TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="#FF94A3B8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="9" Padding="14,8">
              <Grid>
                <Border x:Name="Bar" Width="3" HorizontalAlignment="Left" Margin="-14,3,0,3" CornerRadius="2" Background="#FF5B8CFF" Visibility="Collapsed"/>
                <ContentPresenter/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF162036"/>
                <Setter Property="Foreground" Value="#FFE2E8F0"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF1E2A47"/>
                <Setter TargetName="Bar" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="NavIcon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="Width" Value="30"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="NavText" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Badge" TargetType="Border">
      <Setter Property="CornerRadius" Value="9"/>
      <Setter Property="Padding" Value="7,1"/>
      <Setter Property="MinWidth" Value="20"/>
      <Setter Property="Background" Value="#FFEF4444"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Visibility" Value="Collapsed"/>
    </Style>
    <Style x:Key="BadgeText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="240"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- ===================== BARRE LATERALE ===================== -->
    <Border Background="#FF0B1220">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="22,26,20,30">
          <Border Width="38" Height="38" CornerRadius="10">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#FF5B8CFF" Offset="0"/>
                <GradientStop Color="#FF8B5CF6" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <TextBlock Text="&#xE95E;" FontFamily="{StaticResource Icons}" FontSize="19" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="PC Doctor" Foreground="White" FontSize="17" FontWeight="SemiBold"/>
            <TextBlock Text="Santé de votre PC" Foreground="#FF64748B" FontSize="12"/>
          </StackPanel>
        </StackPanel>

        <StackPanel DockPanel.Dock="Bottom" Margin="18,10,18,20">
          <Border CornerRadius="10" Background="#FF131C2E" Padding="12,10">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Ellipse x:Name="AdminDot" Width="8" Height="8" Fill="#FFF59E0B" VerticalAlignment="Center"/>
                <TextBlock x:Name="TxtAdmin" Text="Mode standard" Foreground="#FFCBD5E1" FontSize="12" Margin="8,0,0,0"/>
              </StackPanel>
              <TextBlock x:Name="TxtAdminHint" Text="Nécessaire pour gérer certains programmes et tout analyser." Foreground="#FF64748B" FontSize="11" TextWrapping="Wrap" Margin="0,4,0,8"/>
              <Button x:Name="BtnElevate" Content="Passer en administrateur" Style="{StaticResource Small}" Background="#FF1E2A47" Foreground="White" BorderBrush="#FF2A3A5E" HorizontalAlignment="Stretch"/>
            </StackPanel>
          </Border>
        </StackPanel>

        <ListBox x:Name="NavList" Background="Transparent" BorderThickness="0" Margin="12,0" ItemContainerStyle="{StaticResource NavItem}" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
          <ListBoxItem>
            <DockPanel><TextBlock Style="{StaticResource NavIcon}" Text="&#xE9D9;"/><TextBlock Style="{StaticResource NavText}" Text="Diagnostic"/></DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel>
              <Border x:Name="BadgeSol" Style="{StaticResource Badge}" DockPanel.Dock="Right"><TextBlock x:Name="BadgeSolText" Style="{StaticResource BadgeText}"/></Border>
              <TextBlock Style="{StaticResource NavIcon}" Text="&#xE82F;"/><TextBlock Style="{StaticResource NavText}" Text="Solutions"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel>
              <Ellipse x:Name="NavBbDot" Width="8" Height="8" Fill="#FF22C55E" DockPanel.Dock="Right" VerticalAlignment="Center" Visibility="Collapsed"/>
              <TextBlock Style="{StaticResource NavIcon}" Text="&#xE81C;"/><TextBlock Style="{StaticResource NavText}" Text="Boîte noire"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel>
              <Ellipse x:Name="NavStressDot" Width="8" Height="8" Fill="#FFEF4444" DockPanel.Dock="Right" VerticalAlignment="Center" Visibility="Collapsed"/>
              <TextBlock Style="{StaticResource NavIcon}" Text="&#xE945;"/><TextBlock Style="{StaticResource NavText}" Text="Test de stabilité"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel>
              <Border x:Name="BadgeSecurity" Style="{StaticResource Badge}" Background="#FFF59E0B" DockPanel.Dock="Right"><TextBlock x:Name="BadgeSecurityText" Style="{StaticResource BadgeText}"/></Border>
              <TextBlock Style="{StaticResource NavIcon}" Text="&#xE72E;"/><TextBlock Style="{StaticResource NavText}" Text="Sécurité"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel>
              <Border x:Name="BadgeGaming" Style="{StaticResource Badge}" Background="#FF3B6EF5" DockPanel.Dock="Right"><TextBlock x:Name="BadgeGamingText" Style="{StaticResource BadgeText}"/></Border>
              <TextBlock Style="{StaticResource NavIcon}" Text="&#xE7FC;"/><TextBlock Style="{StaticResource NavText}" Text="Jeu et confort"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel>
              <Border x:Name="BadgeDrivers" Style="{StaticResource Badge}" Background="#FFF59E0B" DockPanel.Dock="Right"><TextBlock x:Name="BadgeDriversText" Style="{StaticResource BadgeText}"/></Border>
              <TextBlock Style="{StaticResource NavIcon}" Text="&#xE772;"/><TextBlock Style="{StaticResource NavText}" Text="Pilotes"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel>
              <Border x:Name="BadgeSoftware" Style="{StaticResource Badge}" Background="#FF3B6EF5" DockPanel.Dock="Right"><TextBlock x:Name="BadgeSoftwareText" Style="{StaticResource BadgeText}"/></Border>
              <TextBlock Style="{StaticResource NavIcon}" Text="&#xE7B8;"/><TextBlock Style="{StaticResource NavText}" Text="Logiciels"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel><TextBlock Style="{StaticResource NavIcon}" Text="&#xEC4A;"/><TextBlock Style="{StaticResource NavText}" Text="Performances"/></DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel><TextBlock Style="{StaticResource NavIcon}" Text="&#xE839;"/><TextBlock Style="{StaticResource NavText}" Text="Réseau"/></DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel>
              <Border x:Name="BadgeStartup" Style="{StaticResource Badge}" Background="#FFF59E0B" DockPanel.Dock="Right"><TextBlock x:Name="BadgeStartupText" Style="{StaticResource BadgeText}"/></Border>
              <TextBlock Style="{StaticResource NavIcon}" Text="&#xE7E8;"/><TextBlock Style="{StaticResource NavText}" Text="Démarrage"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel><TextBlock Style="{StaticResource NavIcon}" Text="&#xE9F5;"/><TextBlock Style="{StaticResource NavText}" Text="Processus"/></DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel>
              <Border x:Name="BadgeCrash" Style="{StaticResource Badge}" DockPanel.Dock="Right"><TextBlock x:Name="BadgeCrashText" Style="{StaticResource BadgeText}"/></Border>
              <TextBlock Style="{StaticResource NavIcon}" Text="&#xE7BA;"/><TextBlock Style="{StaticResource NavText}" Text="Plantages"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel><TextBlock Style="{StaticResource NavIcon}" Text="&#xEDA2;"/><TextBlock Style="{StaticResource NavText}" Text="Espace disque"/></DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel><TextBlock Style="{StaticResource NavIcon}" Text="&#xEA99;"/><TextBlock Style="{StaticResource NavText}" Text="Nettoyage"/></DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel>
              <Border x:Name="BadgeSettings" Style="{StaticResource Badge}" Background="#FF22C55E" DockPanel.Dock="Right"><TextBlock x:Name="BadgeSettingsText" Style="{StaticResource BadgeText}" Text="1"/></Border>
              <TextBlock Style="{StaticResource NavIcon}" Text="&#xE713;"/><TextBlock Style="{StaticResource NavText}" Text="Paramètres"/>
            </DockPanel>
          </ListBoxItem>
        </ListBox>
      </DockPanel>
    </Border>

    <!-- ===================== CONTENU ===================== -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <TabControl x:Name="Tabs" BorderThickness="0" Background="Transparent" Padding="0">
        <TabControl.Template>
          <ControlTemplate TargetType="TabControl">
            <ContentPresenter ContentSource="SelectedContent"/>
          </ControlTemplate>
        </TabControl.Template>

        <!-- DIAGNOSTIC -->
        <TabItem>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="32,28,32,24">
              <DockPanel Margin="0,0,0,20">
                <Button x:Name="BtnAnalyze" DockPanel.Dock="Right" VerticalAlignment="Top" Margin="0">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72C;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Relancer l'analyse"/></StackPanel>
                </Button>
                <Button x:Name="BtnWidgetDiag" DockPanel.Dock="Right" VerticalAlignment="Top" Style="{StaticResource Secondary}" Margin="0,0,8,0" ToolTip="Petit widget de bureau : températures et utilisation en direct">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7C4;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Widget"/></StackPanel>
                </Button>
                <StackPanel>
                  <TextBlock Style="{StaticResource PageTitle}" Text="Diagnostic"/>
                  <TextBlock x:Name="TxtSysInfo" Style="{StaticResource PageSub}" Text="Analyse en cours…"/>
                </StackPanel>
              </DockPanel>

              <Border x:Name="UpdateBanner" Visibility="Collapsed" Background="#FF0F1A33" CornerRadius="12" Padding="18,14" Margin="0,0,0,18">
                <DockPanel>
                  <Button x:Name="BtnUpdateNow" DockPanel.Dock="Right" Content="Mettre à jour" Margin="12,0,0,0" VerticalAlignment="Center"/>
                  <TextBlock Text="&#xE896;" FontFamily="{StaticResource Icons}" FontSize="20" Foreground="#FF7EA2FF" DockPanel.Dock="Left" Margin="0,0,14,0" VerticalAlignment="Center"/>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock x:Name="TxtUpdateTitle" Foreground="White" FontWeight="SemiBold" FontSize="15"/>
                    <TextBlock x:Name="TxtUpdateSub" Foreground="#FFC7D2E8" TextWrapping="Wrap" Margin="0,2,0,0"/>
                  </StackPanel>
                </DockPanel>
              </Border>

              <Grid Margin="0,0,0,24">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="300"/>
                  <ColumnDefinition Width="16"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border Style="{StaticResource Card}">
                  <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                    <Grid Width="130" Height="130" HorizontalAlignment="Center">
                      <Ellipse Width="114" Height="114" Stroke="#FFEDF1F7" StrokeThickness="11"/>
                      <Canvas Width="130" Height="130">
                        <Path x:Name="ScoreArc" Stroke="#FF3B6EF5" StrokeThickness="11" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                      </Canvas>
                      <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                        <TextBlock x:Name="ScoreText" Text="…" FontSize="36" FontWeight="Bold" HorizontalAlignment="Center" FontFamily="Segoe UI Variable Display, Segoe UI"/>
                        <TextBlock Text="sur 100" Style="{StaticResource MutedText}" FontSize="11" HorizontalAlignment="Center" Margin="0,-4,0,0"/>
                      </StackPanel>
                    </Grid>
                    <TextBlock x:Name="ScoreLabel" Text="Analyse…" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,12,0,2"/>
                    <TextBlock x:Name="ScoreSub" Style="{StaticResource MutedText}" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap"/>
                  </StackPanel>
                </Border>
                <UniformGrid Grid.Column="2" Columns="2" Rows="2" Margin="0,0,-12,-12">
                  <Border Style="{StaticResource Card}" Margin="0,0,12,12">
                    <StackPanel>
                      <DockPanel><TextBlock Text="&#xE950;" FontFamily="{StaticResource Icons}" Foreground="{StaticResource Muted}" Margin="0,2,8,0"/><TextBlock Text="Processeur" Style="{StaticResource MutedText}"/></DockPanel>
                      <TextBlock x:Name="CardCpu" Text="…" FontSize="28" FontWeight="SemiBold" Margin="0,6,0,8"/>
                      <ProgressBar x:Name="BarCpu" Maximum="100"/>
                      <TextBlock x:Name="CardCpuSub" Style="{StaticResource MutedText}" FontSize="12" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource Card}" Margin="0,0,12,12">
                    <StackPanel>
                      <DockPanel><TextBlock Text="&#xEEA0;" FontFamily="{StaticResource Icons}" Foreground="{StaticResource Muted}" Margin="0,2,8,0"/><TextBlock Text="Mémoire vive" Style="{StaticResource MutedText}"/></DockPanel>
                      <TextBlock x:Name="CardRam" Text="…" FontSize="28" FontWeight="SemiBold" Margin="0,6,0,8"/>
                      <ProgressBar x:Name="BarRam" Maximum="100"/>
                      <TextBlock x:Name="CardRamSub" Style="{StaticResource MutedText}" FontSize="12" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource Card}" Margin="0,0,12,12">
                    <StackPanel>
                      <DockPanel><TextBlock Text="&#xEDA2;" FontFamily="{StaticResource Icons}" Foreground="{StaticResource Muted}" Margin="0,2,8,0"/><TextBlock x:Name="CardDiskTitle" Text="Disque système" Style="{StaticResource MutedText}"/></DockPanel>
                      <TextBlock x:Name="CardDisk" Text="…" FontSize="28" FontWeight="SemiBold" Margin="0,6,0,8"/>
                      <ProgressBar x:Name="BarDisk" Maximum="100"/>
                      <TextBlock x:Name="CardDiskSub" Style="{StaticResource MutedText}" FontSize="12" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource Card}" Margin="0,0,12,12">
                    <StackPanel>
                      <DockPanel><TextBlock Text="&#xE823;" FontFamily="{StaticResource Icons}" Foreground="{StaticResource Muted}" Margin="0,2,8,0"/><TextBlock Text="Allumé depuis" Style="{StaticResource MutedText}"/></DockPanel>
                      <TextBlock x:Name="CardUptime" Text="…" FontSize="28" FontWeight="SemiBold" Margin="0,6,0,8"/>
                      <ProgressBar x:Name="BarUptime" Maximum="14"/>
                      <TextBlock x:Name="CardUptimeSub" Style="{StaticResource MutedText}" FontSize="12" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
                    </StackPanel>
                  </Border>
                </UniformGrid>
              </Grid>

              <TextBlock Style="{StaticResource Section}" Text="Ce qui a été trouvé"/>
              <ItemsControl x:Name="ListFindings">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border x:Name="Bd" Style="{StaticResource Card}" Margin="0,0,0,10" Padding="16,14">
                      <DockPanel>
                        <Border x:Name="IconBg" Width="38" Height="38" CornerRadius="19" Background="#FFEFF4FF" DockPanel.Dock="Left" VerticalAlignment="Top" Margin="0,0,14,0">
                          <TextBlock x:Name="Icon" Text="&#xE946;" FontFamily="{StaticResource Icons}" FontSize="17" Foreground="#FF3B6EF5" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <Button x:Name="Act" DockPanel.Dock="Right" Style="{StaticResource Small}" Content="{Binding ActionLabel, Mode=OneWay}" Tag="{Binding ActionId, Mode=OneWay}" VerticalAlignment="Center" Margin="14,0,0,0"/>
                        <StackPanel VerticalAlignment="Center">
                          <TextBlock Text="{Binding Title, Mode=OneWay}" FontWeight="SemiBold" FontSize="15" TextWrapping="Wrap"/>
                          <ToggleButton x:Name="Tg" Style="{StaticResource DetailsToggle}" HorizontalAlignment="Left" Margin="0,5,0,0"/>
                          <TextBlock x:Name="Adv" Text="{Binding Advice, Mode=OneWay}" TextWrapping="Wrap" Margin="0,8,0,0" Foreground="#FF475569" LineHeight="22" Visibility="Collapsed"/>
                        </StackPanel>
                      </DockPanel>
                    </Border>
                    <DataTemplate.Triggers>
                      <Trigger SourceName="Tg" Property="IsChecked" Value="True"><Setter TargetName="Adv" Property="Visibility" Value="Visible"/></Trigger>
                      <DataTrigger Binding="{Binding Advice}" Value="{x:Null}"><Setter TargetName="Tg" Property="Visibility" Value="Collapsed"/></DataTrigger>
                      <DataTrigger Binding="{Binding Advice}" Value=""><Setter TargetName="Tg" Property="Visibility" Value="Collapsed"/></DataTrigger>
                      <DataTrigger Binding="{Binding ActionLabel}" Value="{x:Null}"><Setter TargetName="Act" Property="Visibility" Value="Collapsed"/></DataTrigger>
                      <DataTrigger Binding="{Binding Severity}" Value="Critique">
                        <Setter TargetName="IconBg" Property="Background" Value="#FFFEECEC"/>
                        <Setter TargetName="Icon" Property="Foreground" Value="#FFEF4444"/>
                        <Setter TargetName="Icon" Property="Text" Value="&#xEA39;"/>
                        <Setter TargetName="Bd" Property="BorderBrush" Value="#FFFBCACA"/>
                      </DataTrigger>
                      <DataTrigger Binding="{Binding Severity}" Value="Attention">
                        <Setter TargetName="IconBg" Property="Background" Value="#FFFFF4E0"/>
                        <Setter TargetName="Icon" Property="Foreground" Value="#FFF59E0B"/>
                        <Setter TargetName="Icon" Property="Text" Value="&#xE7BA;"/>
                      </DataTrigger>
                      <DataTrigger Binding="{Binding Severity}" Value="OK">
                        <Setter TargetName="IconBg" Property="Background" Value="#FFE7F8EE"/>
                        <Setter TargetName="Icon" Property="Foreground" Value="#FF22C55E"/>
                        <Setter TargetName="Icon" Property="Text" Value="&#xE73E;"/>
                      </DataTrigger>
                    </DataTemplate.Triggers>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
          </ScrollViewer>
        </TabItem>

        <!-- SOLUTIONS -->
        <TabItem>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="32,28,32,24">
              <TextBlock Style="{StaticResource PageTitle}" Text="Résoudre les plantages"/>
              <TextBlock Style="{StaticResource PageSub}" Text="À faire dans l'ordre, une à la fois."/>
              <Border Style="{StaticResource Card}" Margin="0,18,0,20" Background="#FF0F1A33" BorderBrush="#FF0F1A33">
                <DockPanel>
                  <TextBlock Text="&#xE9D9;" FontFamily="{StaticResource Icons}" FontSize="22" Foreground="#FF7EA2FF" DockPanel.Dock="Left" VerticalAlignment="Top" Margin="0,2,14,0"/>
                  <StackPanel>
                    <TextBlock Text="Ce qui se passe sur votre PC" Foreground="White" FontWeight="SemiBold" FontSize="15"/>
                    <TextBlock x:Name="TxtDiagnosis" Foreground="#FFC7D2E8" TextWrapping="Wrap" Margin="0,6,0,0" LineHeight="20" Text="Analyse en cours…"/>
                  </StackPanel>
                </DockPanel>
              </Border>
              <ItemsControl x:Name="ListSolutions">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border Style="{StaticResource Card}" Margin="0,0,0,12" Padding="20,18">
                      <DockPanel>
                        <Border x:Name="NumBg" Width="34" Height="34" CornerRadius="17" Background="#FFEDF1F7" DockPanel.Dock="Left" VerticalAlignment="Top" Margin="0,0,16,0">
                          <TextBlock x:Name="NumTxt" Text="{Binding Num, Mode=OneWay}" FontWeight="Bold" FontSize="15" Foreground="#FF475569" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <StackPanel>
                          <WrapPanel>
                            <TextBlock Text="{Binding Title, Mode=OneWay}" FontWeight="SemiBold" FontSize="16" Margin="0,0,10,0" VerticalAlignment="Center"/>
                            <Border x:Name="RecBadge" CornerRadius="10" Background="#FFE8EFFE" Padding="9,2" VerticalAlignment="Center" Visibility="Collapsed">
                              <TextBlock Text="Recommandé pour votre PC" FontSize="11.5" FontWeight="SemiBold" Foreground="#FF3B6EF5"/>
                            </Border>
                          </WrapPanel>
                          <TextBlock Text="{Binding Why, Mode=OneWay}" TextWrapping="Wrap" Foreground="#FF475569" Margin="0,6,0,0" LineHeight="22"/>
                          <ToggleButton x:Name="TgSteps" Style="{StaticResource DetailsToggle}" HorizontalAlignment="Left" Margin="0,8,0,0" IsChecked="{Binding Recommended, Mode=OneTime}"/>
                          <Border x:Name="StepsBox" Background="#FFF7F9FC" CornerRadius="8" Padding="14,10" Margin="0,10,0,0" Visibility="Collapsed">
                            <TextBlock Text="{Binding Steps, Mode=OneWay}" TextWrapping="Wrap" LineHeight="22"/>
                          </Border>
                          <ItemsControl ItemsSource="{Binding Actions, Mode=OneWay}" Margin="0,12,0,0">
                            <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                            <ItemsControl.ItemTemplate>
                              <DataTemplate>
                                <Button Content="{Binding Label, Mode=OneWay}" Tag="{Binding Id, Mode=OneWay}" Padding="14,6" Margin="0,0,8,0"/>
                              </DataTemplate>
                            </ItemsControl.ItemTemplate>
                          </ItemsControl>
                        </StackPanel>
                      </DockPanel>
                    </Border>
                    <DataTemplate.Triggers>
                      <Trigger SourceName="TgSteps" Property="IsChecked" Value="True"><Setter TargetName="StepsBox" Property="Visibility" Value="Visible"/></Trigger>
                      <DataTrigger Binding="{Binding Recommended}" Value="True">
                        <Setter TargetName="RecBadge" Property="Visibility" Value="Visible"/>
                        <Setter TargetName="NumBg" Property="Background" Value="#FF3B6EF5"/>
                        <Setter TargetName="NumTxt" Property="Foreground" Value="White"/>
                      </DataTrigger>
                    </DataTemplate.Triggers>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
          </ScrollViewer>
        </TabItem>

        <!-- BOITE NOIRE -->
        <TabItem>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="BlackBoxRoot" Margin="32,28,32,24">
              <TextBlock Style="{StaticResource PageTitle}" Text="Boîte noire"/>
              <TextBlock Style="{StaticResource PageSub}" Text="Enregistre l'état du PC toutes les 2 secondes. Après une coupure, vous voyez ce qui se passait juste avant."/>
              <Grid Margin="0,18,0,20">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="16"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <StackPanel Orientation="Horizontal">
                      <Ellipse x:Name="BbDot" Width="12" Height="12" Fill="#FF94A3B8" VerticalAlignment="Center"/>
                      <TextBlock x:Name="TxtBbStatus" Text="…" FontSize="18" FontWeight="SemiBold" Margin="10,0,0,0"/>
                    </StackPanel>
                    <TextBlock x:Name="TxtBbSub" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,6,0,12"/>
                    <WrapPanel>
                      <Button x:Name="BtnBbStart" Margin="0,0,8,6">
                        <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE768;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Démarrer la surveillance"/></StackPanel>
                      </Button>
                      <Button x:Name="BtnBbStop" Content="Arrêter" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                    </WrapPanel>
                    <CheckBox x:Name="ChkBbAutostart" Content="Lancer automatiquement avec Windows (recommandé)" Margin="0,8,0,0"/>
                    <Border x:Name="BbCpuTempBox" Background="#FFF7F9FC" CornerRadius="8" Padding="10,8" Margin="0,10,0,0">
                      <DockPanel>
                        <Button x:Name="BtnBbCoreTemp" DockPanel.Dock="Right" Content="Lancer Core Temp" Style="{StaticResource Small}" VerticalAlignment="Center" Margin="10,0,0,0"/>
                        <TextBlock x:Name="TxtBbCpuTemp" TextWrapping="Wrap" FontSize="12" VerticalAlignment="Center"/>
                      </DockPanel>
                    </Border>
                    <TextBlock Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap" Margin="0,8,0,0" Text="Une icône PC Doctor apparaît près de l'horloge : clic droit pour la mettre en pause ou l'arrêter. Consommation : quasi nulle."/>
                  </StackPanel>
                </Border>
                <Border Grid.Column="2" Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="Alertes" FontSize="18" FontWeight="SemiBold"/>
                    <TextBlock Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,6,0,10" Text="Une notification Windows s'affiche quand quelque chose ne va pas (fonctionne quand la surveillance est active)."/>
                    <CheckBox x:Name="ChkAlerts" Content="Me prévenir quand la carte graphique chauffe trop"/>
                    <StackPanel Orientation="Horizontal" Margin="24,6,0,0">
                      <TextBlock Text="Seuil d'alerte :" VerticalAlignment="Center" Margin="0,0,10,0"/>
                      <ComboBox x:Name="CmbAlertTemp" Width="90" Padding="8,4">
                        <ComboBoxItem Content="75 °C"/>
                        <ComboBoxItem Content="80 °C"/>
                        <ComboBoxItem Content="85 °C"/>
                        <ComboBoxItem Content="90 °C"/>
                      </ComboBox>
                    </StackPanel>
                    <TextBlock Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap" Margin="0,12,0,0" Text="Une alerte est aussi affichée si le processeur dépasse 90 °C (avec Core Temp ou HWiNFO) ou si la mémoire vive reste saturée (95 % ou plus)."/>
                  </StackPanel>
                </Border>
              </Grid>

              <DockPanel Margin="0,0,0,10">
                <Button x:Name="BtnBbLast" DockPanel.Dock="Right" Content="Voir les 10 dernières minutes" Style="{StaticResource Secondary}" Margin="0"/>
                <TextBlock Style="{StaticResource Section}" Text="Plantages des 7 derniers jours" Margin="0" VerticalAlignment="Center"/>
              </DockPanel>
              <Border Style="{StaticResource Panel}">
                <DataGrid x:Name="GridBbCrashes" MaxHeight="240">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="REDÉMARRAGE" Binding="{Binding DateText}" SortMemberPath="Date" Width="150"/>
                    <DataGridTextColumn Header="TYPE" Binding="{Binding Category}" Width="150"/>
                    <DataGridTextColumn Header="DONNÉES DE LA BOÎTE NOIRE" Binding="{Binding LastText}" Width="*"/>
                    <DataGridTemplateColumn Header="" Width="120">
                      <DataGridTemplateColumn.CellTemplate>
                        <DataTemplate>
                          <Button x:Name="B" Content="Analyser" Tag="bb-analyze" Style="{StaticResource Small}" Width="96"/>
                          <DataTemplate.Triggers>
                            <DataTrigger Binding="{Binding HasData}" Value="False"><Setter TargetName="B" Property="IsEnabled" Value="False"/></DataTrigger>
                          </DataTemplate.Triggers>
                        </DataTemplate>
                      </DataGridTemplateColumn.CellTemplate>
                    </DataGridTemplateColumn>
                  </DataGrid.Columns>
                </DataGrid>
              </Border>
              <TextBlock x:Name="TxtBbCrashInfo" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,8,0,0"/>

              <Border x:Name="BbAnalysis" Style="{StaticResource Card}" Margin="0,18,0,0" Visibility="Collapsed">
                <StackPanel>
                  <TextBlock x:Name="TxtBbTitle" FontSize="17" FontWeight="SemiBold"/>
                  <Border Background="#FFF7F9FC" CornerRadius="10" Padding="14,12" Margin="0,10,0,0">
                    <TextBlock x:Name="TxtBbVerdict" TextWrapping="Wrap" LineHeight="21"/>
                  </Border>
                  <UniformGrid Columns="2" Margin="0,14,-12,0">
                    <Border Background="#FFF7F9FC" CornerRadius="10" Padding="12,10" Margin="0,0,12,12">
                      <StackPanel>
                        <DockPanel><TextBlock x:Name="ChartGpuTempInfo" DockPanel.Dock="Right" Style="{StaticResource MutedText}" FontSize="12"/><TextBlock Text="Température carte graphique" FontWeight="SemiBold" FontSize="12.5"/></DockPanel>
                        <Canvas x:Name="ChartGpuTemp" Height="90" Margin="0,8,0,0" ClipToBounds="True"/>
                      </StackPanel>
                    </Border>
                    <Border Background="#FFF7F9FC" CornerRadius="10" Padding="12,10" Margin="0,0,12,12">
                      <StackPanel>
                        <DockPanel><TextBlock x:Name="ChartCpuTempInfo" DockPanel.Dock="Right" Style="{StaticResource MutedText}" FontSize="12"/><TextBlock Text="Température processeur" FontWeight="SemiBold" FontSize="12.5"/></DockPanel>
                        <Canvas x:Name="ChartCpuTemp" Height="90" Margin="0,8,0,0" ClipToBounds="True"/>
                      </StackPanel>
                    </Border>
                    <Border Background="#FFF7F9FC" CornerRadius="10" Padding="12,10" Margin="0,0,12,12">
                      <StackPanel>
                        <DockPanel><TextBlock x:Name="ChartGpuPowerInfo" DockPanel.Dock="Right" Style="{StaticResource MutedText}" FontSize="12"/><TextBlock Text="Consommation carte graphique" FontWeight="SemiBold" FontSize="12.5"/></DockPanel>
                        <Canvas x:Name="ChartGpuPower" Height="90" Margin="0,8,0,0" ClipToBounds="True"/>
                      </StackPanel>
                    </Border>
                    <Border Background="#FFF7F9FC" CornerRadius="10" Padding="12,10" Margin="0,0,12,12">
                      <StackPanel>
                        <DockPanel><TextBlock x:Name="ChartCpuInfo" DockPanel.Dock="Right" Style="{StaticResource MutedText}" FontSize="12"/><TextBlock Text="Processeur" FontWeight="SemiBold" FontSize="12.5"/></DockPanel>
                        <Canvas x:Name="ChartCpu" Height="90" Margin="0,8,0,0" ClipToBounds="True"/>
                      </StackPanel>
                    </Border>
                    <Border Background="#FFF7F9FC" CornerRadius="10" Padding="12,10" Margin="0,0,12,12">
                      <StackPanel>
                        <DockPanel><TextBlock x:Name="ChartRamInfo" DockPanel.Dock="Right" Style="{StaticResource MutedText}" FontSize="12"/><TextBlock Text="Mémoire vive" FontWeight="SemiBold" FontSize="12.5"/></DockPanel>
                        <Canvas x:Name="ChartRam" Height="90" Margin="0,8,0,0" ClipToBounds="True"/>
                      </StackPanel>
                    </Border>
                    <Border Background="#FFF7F9FC" CornerRadius="10" Padding="12,10" Margin="0,0,12,12">
                      <StackPanel>
                        <DockPanel><TextBlock x:Name="ChartDiskInfo" DockPanel.Dock="Right" Style="{StaticResource MutedText}" FontSize="12"/><TextBlock Text="SSD système (activité)" FontWeight="SemiBold" FontSize="12.5"/></DockPanel>
                        <Canvas x:Name="ChartDisk" Height="90" Margin="0,8,0,0" ClipToBounds="True"/>
                      </StackPanel>
                    </Border>
                  </UniformGrid>
                  <TextBlock x:Name="TxtBbTableTitle" Text="Dernières mesures" FontWeight="SemiBold" Margin="0,4,0,8"/>
                  <Border Style="{StaticResource Panel}">
                    <DataGrid x:Name="GridBbSamples" MaxHeight="300">
                      <DataGrid.Columns>
                        <DataGridTextColumn Header="HEURE" Binding="{Binding TimeText}" Width="90"/>
                        <DataGridTextColumn Header="GPU °C" Binding="{Binding GpuTempText}" Width="80"/>
                        <DataGridTextColumn Header="CPU °C" Binding="{Binding CpuTempText}" Width="80"/>
                        <DataGridTextColumn Header="GPU W" Binding="{Binding GpuPowerText}" Width="90"/>
                        <DataGridTextColumn Header="GPU %" Binding="{Binding GpuUsageText}" Width="75"/>
                        <DataGridTextColumn Header="PROCESSEUR" Binding="{Binding CpuText}" Width="100"/>
                        <DataGridTextColumn Header="RAM" Binding="{Binding RamText}" Width="75"/>
                        <DataGridTextColumn Header="DISQUE" Binding="{Binding DiskBusyText}" Width="80"/>
                        <DataGridTextColumn Header="PROGRAMME AU PREMIER PLAN" Binding="{Binding App}" Width="*"/>
                      </DataGrid.Columns>
                    </DataGrid>
                  </Border>
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </TabItem>

        <!-- TEST DE STABILITÉ -->
        <TabItem>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="StressRoot" Margin="32,28,32,24">
              <TextBlock Style="{StaticResource PageTitle}" Text="Test de stabilité"/>
              <TextBlock Style="{StaticResource PageSub}" Text="Fait tourner le PC à fond quelques minutes. S'il se coupe, la boîte noire montre pourquoi."/>
              <Border x:Name="StressCrashBox" Background="#FFFEF2F2" BorderBrush="#FFFBCACA" BorderThickness="1" CornerRadius="12" Padding="18,14" Margin="0,18,0,0" Visibility="Collapsed">
                <DockPanel>
                  <Button x:Name="BtnStressCrashBb" DockPanel.Dock="Right" Content="Voir la boîte noire" VerticalAlignment="Center" Margin="12,0,0,0"/>
                  <StackPanel>
                    <TextBlock x:Name="TxtStressCrashTitle" FontSize="16" FontWeight="SemiBold" Foreground="#FFEF4444" TextWrapping="Wrap"/>
                    <TextBlock x:Name="TxtStressCrash" TextWrapping="Wrap" Margin="0,6,0,0" LineHeight="20"/>
                  </StackPanel>
                </DockPanel>
              </Border>
              <Grid Margin="0,18,0,20">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="5*"/>
                  <ColumnDefinition Width="16"/>
                  <ColumnDefinition Width="7*"/>
                </Grid.ColumnDefinitions>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="Réglages" FontSize="18" FontWeight="SemiBold"/>
                    <TextBlock Style="{StaticResource MutedText}" FontSize="12" Margin="0,12,0,6" Text="CE QUI EST TESTÉ"/>
                    <CheckBox x:Name="ChkStressCpu" Content="Processeur (tous les cœurs)" IsChecked="True" Margin="0,0,0,6"/>
                    <CheckBox x:Name="ChkStressRam" Content="Mémoire vive (écriture et vérification)" IsChecked="True" Margin="0,0,0,6"/>
                    <CheckBox x:Name="ChkStressGpu" Content="Carte graphique (calcul Direct3D)" IsChecked="True"/>
                    <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                      <TextBlock Text="Durée :" VerticalAlignment="Center" Margin="0,0,10,0"/>
                      <ComboBox x:Name="CmbStressMinutes" Width="110" Padding="8,4" SelectedIndex="1">
                        <ComboBoxItem Content="5 minutes"/>
                        <ComboBoxItem Content="10 minutes"/>
                        <ComboBoxItem Content="15 minutes"/>
                      </ComboBox>
                    </StackPanel>
                    <WrapPanel Margin="0,16,0,0">
                      <Button x:Name="BtnStressStart" Margin="0,0,8,6">
                        <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE768;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Lancer le test"/></StackPanel>
                      </Button>
                      <Button x:Name="BtnStressStop" Content="Arrêter" Style="{StaticResource Danger}" Margin="0,0,8,6" IsEnabled="False"/>
                    </WrapPanel>
                    <Border x:Name="StressCpuTempBox" Background="#FFF7F9FC" CornerRadius="8" Padding="10,8" Margin="0,10,0,0">
                      <DockPanel>
                        <Button x:Name="BtnStressCoreTemp" DockPanel.Dock="Right" Content="Lancer Core Temp" Style="{StaticResource Small}" VerticalAlignment="Center" Margin="10,0,0,0"/>
                        <TextBlock x:Name="TxtStressCpuTemp" TextWrapping="Wrap" FontSize="12" VerticalAlignment="Center"/>
                      </DockPanel>
                    </Border>
                    <TextBlock Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap" Margin="0,10,0,0" LineHeight="18" Text="Arrêt automatique si le processeur atteint 90 °C ou la carte graphique 87 °C. Enregistrez vos documents et fermez vos jeux avant : si le PC se coupe, ce qui n'est pas enregistré est perdu. La boîte noire est lancée automatiquement."/>
                  </StackPanel>
                </Border>
                <Border Grid.Column="2" Style="{StaticResource Card}">
                  <StackPanel>
                    <DockPanel>
                      <TextBlock x:Name="TxtStressTime" DockPanel.Dock="Right" Style="{StaticResource MutedText}" FontSize="13" VerticalAlignment="Center"/>
                      <TextBlock x:Name="TxtStressState" Text="Prêt" FontSize="18" FontWeight="SemiBold"/>
                    </DockPanel>
                    <ProgressBar x:Name="BarStress" Maximum="100" Margin="0,10,0,0"/>
                    <UniformGrid Columns="4" Margin="0,18,-14,0">
                      <StackPanel Margin="0,0,14,0">
                        <TextBlock Text="Processeur" Style="{StaticResource MutedText}" FontSize="12"/>
                        <TextBlock x:Name="TxtStressCpuT" Text="—" FontSize="24" FontWeight="SemiBold" Margin="0,2,0,2"/>
                        <TextBlock x:Name="TxtStressCpuSub" Style="{StaticResource MutedText}" FontSize="11.5" TextWrapping="Wrap"/>
                      </StackPanel>
                      <StackPanel Margin="0,0,14,0">
                        <TextBlock Text="Carte graphique" Style="{StaticResource MutedText}" FontSize="12"/>
                        <TextBlock x:Name="TxtStressGpuT" Text="—" FontSize="24" FontWeight="SemiBold" Margin="0,2,0,2"/>
                        <TextBlock x:Name="TxtStressGpuSub" Style="{StaticResource MutedText}" FontSize="11.5" TextWrapping="Wrap"/>
                      </StackPanel>
                      <StackPanel Margin="0,0,14,0">
                        <TextBlock Text="Consommation GPU" Style="{StaticResource MutedText}" FontSize="12"/>
                        <TextBlock x:Name="TxtStressGpuW" Text="—" FontSize="24" FontWeight="SemiBold" Margin="0,2,0,2"/>
                        <TextBlock x:Name="TxtStressGpuWSub" Style="{StaticResource MutedText}" FontSize="11.5" TextWrapping="Wrap"/>
                      </StackPanel>
                      <StackPanel Margin="0,0,14,0">
                        <TextBlock Text="Mémoire vive" Style="{StaticResource MutedText}" FontSize="12"/>
                        <TextBlock x:Name="TxtStressRam" Text="—" FontSize="24" FontWeight="SemiBold" Margin="0,2,0,2"/>
                        <TextBlock x:Name="TxtStressRamSub" Style="{StaticResource MutedText}" FontSize="11.5" TextWrapping="Wrap"/>
                      </StackPanel>
                    </UniformGrid>
                    <UniformGrid Columns="3" Margin="0,16,-10,0">
                      <Border Background="#FFF7F9FC" CornerRadius="10" Padding="10,8" Margin="0,0,10,0">
                        <StackPanel>
                          <TextBlock Text="Temp. processeur" FontWeight="SemiBold" FontSize="12"/>
                          <Canvas x:Name="ChartStressCpuT" Height="70" Margin="0,6,0,0" ClipToBounds="True"/>
                        </StackPanel>
                      </Border>
                      <Border Background="#FFF7F9FC" CornerRadius="10" Padding="10,8" Margin="0,0,10,0">
                        <StackPanel>
                          <TextBlock Text="Temp. carte graphique" FontWeight="SemiBold" FontSize="12"/>
                          <Canvas x:Name="ChartStressGpuT" Height="70" Margin="0,6,0,0" ClipToBounds="True"/>
                        </StackPanel>
                      </Border>
                      <Border Background="#FFF7F9FC" CornerRadius="10" Padding="10,8" Margin="0,0,10,0">
                        <StackPanel>
                          <TextBlock Text="Conso. carte graphique" FontWeight="SemiBold" FontSize="12"/>
                          <Canvas x:Name="ChartStressGpuW" Height="70" Margin="0,6,0,0" ClipToBounds="True"/>
                        </StackPanel>
                      </Border>
                    </UniformGrid>
                  </StackPanel>
                </Border>
              </Grid>
              <Border x:Name="StressResult" Style="{StaticResource Card}" Visibility="Collapsed">
                <StackPanel>
                  <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="StressResultDot" Width="12" Height="12" Fill="#FF22C55E" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtStressResultTitle" FontSize="17" FontWeight="SemiBold" Margin="10,0,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                  <Border Background="#FFF7F9FC" CornerRadius="10" Padding="14,12" Margin="0,10,0,0">
                    <TextBlock x:Name="TxtStressResult" TextWrapping="Wrap" LineHeight="21"/>
                  </Border>
                  <WrapPanel Margin="0,12,0,0">
                    <Button x:Name="BtnStressResultBb" Content="Voir la boîte noire pendant le test" Style="{StaticResource Secondary}" Margin="0,0,8,0"/>
                    <Button x:Name="BtnStressSolutions" Content="Voir les solutions" Style="{StaticResource Secondary}" Margin="0"/>
                  </WrapPanel>
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </TabItem>

        <!-- SÉCURITÉ -->
        <TabItem>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="SecurityRoot" Margin="32,28,32,24">
              <TextBlock Style="{StaticResource PageTitle}" Text="Sécurité"/>
              <TextBlock Style="{StaticResource PageSub}" Text="Ce qui protège le PC. Rien n'est modifié sans votre accord."/>
              <Grid Margin="0,18,0,24">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="300"/>
                  <ColumnDefinition Width="16"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border Style="{StaticResource Card}">
                  <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                    <Grid Width="130" Height="130" HorizontalAlignment="Center">
                      <Ellipse Width="114" Height="114" Stroke="#FFEDF1F7" StrokeThickness="11"/>
                      <Canvas Width="130" Height="130">
                        <Path x:Name="SecScoreArc" Stroke="#FF3B6EF5" StrokeThickness="11" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                      </Canvas>
                      <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                        <TextBlock x:Name="SecScoreText" Text="…" FontSize="36" FontWeight="Bold" HorizontalAlignment="Center" FontFamily="Segoe UI Variable Display, Segoe UI"/>
                        <TextBlock Text="sur 100" Style="{StaticResource MutedText}" FontSize="11" HorizontalAlignment="Center" Margin="0,-4,0,0"/>
                      </StackPanel>
                    </Grid>
                    <TextBlock x:Name="SecScoreLabel" Text="Vérification…" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,12,0,2"/>
                    <TextBlock x:Name="SecScoreSub" Style="{StaticResource MutedText}" HorizontalAlignment="Center" TextAlignment="Center" TextWrapping="Wrap"/>
                  </StackPanel>
                </Border>
                <Border Grid.Column="2" Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="Protection" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,10"/>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                      <TextBlock Text="Antivirus" Style="{StaticResource MutedText}" Margin="0,0,0,8"/>
                      <TextBlock x:Name="TxtSecAv" Grid.Column="1" Text="…" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,8"/>
                      <TextBlock Grid.Row="1" Text="Pare-feu" Style="{StaticResource MutedText}" Margin="0,0,0,8"/>
                      <TextBlock x:Name="TxtSecFw" Grid.Row="1" Grid.Column="1" Text="…" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,8"/>
                      <TextBlock Grid.Row="2" Text="Mises à jour" Style="{StaticResource MutedText}" Margin="0,0,0,8"/>
                      <TextBlock x:Name="TxtSecWu" Grid.Row="2" Grid.Column="1" Text="…" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,0,0,8"/>
                      <TextBlock Grid.Row="3" Text="Protections matérielles" Style="{StaticResource MutedText}"/>
                      <TextBlock x:Name="TxtSecHw" Grid.Row="3" Grid.Column="1" Text="…" FontWeight="SemiBold" TextWrapping="Wrap"/>
                    </Grid>
                    <WrapPanel Margin="0,16,0,0">
                      <Button x:Name="BtnSecRefresh" Margin="0,0,8,6">
                        <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72C;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Vérifier à nouveau"/></StackPanel>
                      </Button>
                      <Button x:Name="BtnSecScan" Content="Analyse antivirus rapide" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                      <Button x:Name="BtnSecOpen" Content="Ouvrir Sécurité Windows" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                    </WrapPanel>
                    <TextBlock x:Name="TxtSecNote" Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap" Margin="0,6,0,0"/>
                  </StackPanel>
                </Border>
              </Grid>
              <TextBlock Style="{StaticResource Section}" Text="Points vérifiés"/>
              <ItemsControl x:Name="ListSecurity">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border x:Name="Bd" Style="{StaticResource Card}" Margin="0,0,0,10" Padding="16,14">
                      <DockPanel>
                        <Border x:Name="IconBg" Width="38" Height="38" CornerRadius="19" Background="#FFEFF4FF" DockPanel.Dock="Left" VerticalAlignment="Top" Margin="0,0,14,0">
                          <TextBlock x:Name="Icon" Text="&#xE946;" FontFamily="{StaticResource Icons}" FontSize="17" Foreground="#FF3B6EF5" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <Button x:Name="Act" DockPanel.Dock="Right" Style="{StaticResource Small}" Content="{Binding ActionLabel, Mode=OneWay}" Tag="{Binding ActionId, Mode=OneWay}" VerticalAlignment="Center" Margin="14,0,0,0"/>
                        <StackPanel VerticalAlignment="Center">
                          <TextBlock Text="{Binding Title, Mode=OneWay}" FontWeight="SemiBold" FontSize="15" TextWrapping="Wrap"/>
                          <ToggleButton x:Name="Tg" Style="{StaticResource DetailsToggle}" HorizontalAlignment="Left" Margin="0,5,0,0"/>
                          <TextBlock x:Name="Adv" Text="{Binding Advice, Mode=OneWay}" TextWrapping="Wrap" Margin="0,8,0,0" Foreground="#FF475569" LineHeight="22" Visibility="Collapsed"/>
                        </StackPanel>
                      </DockPanel>
                    </Border>
                    <DataTemplate.Triggers>
                      <Trigger SourceName="Tg" Property="IsChecked" Value="True"><Setter TargetName="Adv" Property="Visibility" Value="Visible"/></Trigger>
                      <DataTrigger Binding="{Binding Advice}" Value="{x:Null}"><Setter TargetName="Tg" Property="Visibility" Value="Collapsed"/></DataTrigger>
                      <DataTrigger Binding="{Binding Advice}" Value=""><Setter TargetName="Tg" Property="Visibility" Value="Collapsed"/></DataTrigger>
                      <DataTrigger Binding="{Binding ActionLabel}" Value="{x:Null}"><Setter TargetName="Act" Property="Visibility" Value="Collapsed"/></DataTrigger>
                      <DataTrigger Binding="{Binding Severity}" Value="Critique">
                        <Setter TargetName="IconBg" Property="Background" Value="#FFFEECEC"/>
                        <Setter TargetName="Icon" Property="Foreground" Value="#FFEF4444"/>
                        <Setter TargetName="Icon" Property="Text" Value="&#xEA39;"/>
                        <Setter TargetName="Bd" Property="BorderBrush" Value="#FFFBCACA"/>
                      </DataTrigger>
                      <DataTrigger Binding="{Binding Severity}" Value="Attention">
                        <Setter TargetName="IconBg" Property="Background" Value="#FFFFF4E0"/>
                        <Setter TargetName="Icon" Property="Foreground" Value="#FFF59E0B"/>
                        <Setter TargetName="Icon" Property="Text" Value="&#xE7BA;"/>
                      </DataTrigger>
                      <DataTrigger Binding="{Binding Severity}" Value="OK">
                        <Setter TargetName="IconBg" Property="Background" Value="#FFE7F8EE"/>
                        <Setter TargetName="Icon" Property="Foreground" Value="#FF22C55E"/>
                        <Setter TargetName="Icon" Property="Text" Value="&#xE73E;"/>
                      </DataTrigger>
                    </DataTemplate.Triggers>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
          </ScrollViewer>
        </TabItem>

        <!-- JEU ET CONFORT -->
        <TabItem>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="GamingRoot" Margin="32,28,32,24">
              <TextBlock Style="{StaticResource PageTitle}" Text="Jeu et confort"/>
              <TextBlock Style="{StaticResource PageSub}" Text="Réglages utiles en jeu et au quotidien. Chacun se change et se remet en un clic."/>
              <Border Style="{StaticResource Card}" Margin="0,18,0,20">
                <DockPanel>
                  <Button x:Name="BtnGamingApply" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="16,0,0,0">
                    <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE73E;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock x:Name="TxtGamingApply" Text="Appliquer les réglages conseillés"/></StackPanel>
                  </Button>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock x:Name="TxtGamingSummary" Text="…" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap"/>
                    <TextBlock x:Name="TxtGamingSub" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,4,0,0"/>
                  </StackPanel>
                </DockPanel>
              </Border>
              <TextBlock Style="{StaticResource Section}" Text="Jeu"/>
              <ItemsControl x:Name="ListGaming">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border x:Name="Bd" Style="{StaticResource Card}" Margin="0,0,0,10" Padding="16,14">
                      <DockPanel>
                        <Border x:Name="IconBg" Width="38" Height="38" CornerRadius="19" Background="#FFEFF4FF" DockPanel.Dock="Left" VerticalAlignment="Top" Margin="0,0,14,0">
                          <TextBlock x:Name="Icon" Text="&#xE946;" FontFamily="{StaticResource Icons}" FontSize="17" Foreground="#FF3B6EF5" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <Button x:Name="Act" DockPanel.Dock="Right" Style="{StaticResource Small}" Content="{Binding ActionLabel, Mode=OneWay}" Tag="{Binding ActionId, Mode=OneWay}" VerticalAlignment="Center" Margin="14,0,0,0"/>
                        <StackPanel VerticalAlignment="Center">
                          <TextBlock Text="{Binding Title, Mode=OneWay}" FontWeight="SemiBold" FontSize="15" TextWrapping="Wrap"/>
                          <ToggleButton x:Name="Tg" Style="{StaticResource DetailsToggle}" HorizontalAlignment="Left" Margin="0,5,0,0"/>
                          <TextBlock x:Name="Adv" Text="{Binding Advice, Mode=OneWay}" TextWrapping="Wrap" Margin="0,8,0,0" Foreground="#FF475569" LineHeight="22" Visibility="Collapsed"/>
                        </StackPanel>
                      </DockPanel>
                    </Border>
                    <DataTemplate.Triggers>
                      <Trigger SourceName="Tg" Property="IsChecked" Value="True"><Setter TargetName="Adv" Property="Visibility" Value="Visible"/></Trigger>
                      <DataTrigger Binding="{Binding Advice}" Value="{x:Null}"><Setter TargetName="Tg" Property="Visibility" Value="Collapsed"/></DataTrigger>
                      <DataTrigger Binding="{Binding Advice}" Value=""><Setter TargetName="Tg" Property="Visibility" Value="Collapsed"/></DataTrigger>
                      <DataTrigger Binding="{Binding ActionLabel}" Value="{x:Null}"><Setter TargetName="Act" Property="Visibility" Value="Collapsed"/></DataTrigger>
                      <DataTrigger Binding="{Binding Severity}" Value="Critique">
                        <Setter TargetName="IconBg" Property="Background" Value="#FFFEECEC"/>
                        <Setter TargetName="Icon" Property="Foreground" Value="#FFEF4444"/>
                        <Setter TargetName="Icon" Property="Text" Value="&#xEA39;"/>
                        <Setter TargetName="Bd" Property="BorderBrush" Value="#FFFBCACA"/>
                      </DataTrigger>
                      <DataTrigger Binding="{Binding Severity}" Value="Attention">
                        <Setter TargetName="IconBg" Property="Background" Value="#FFFFF4E0"/>
                        <Setter TargetName="Icon" Property="Foreground" Value="#FFF59E0B"/>
                        <Setter TargetName="Icon" Property="Text" Value="&#xE7BA;"/>
                      </DataTrigger>
                      <DataTrigger Binding="{Binding Severity}" Value="OK">
                        <Setter TargetName="IconBg" Property="Background" Value="#FFE7F8EE"/>
                        <Setter TargetName="Icon" Property="Foreground" Value="#FF22C55E"/>
                        <Setter TargetName="Icon" Property="Text" Value="&#xE73E;"/>
                      </DataTrigger>
                    </DataTemplate.Triggers>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
              <TextBlock Style="{StaticResource Section}" Text="Confort" Margin="0,14,0,10"/>
              <ItemsControl x:Name="ListComfort">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border x:Name="Bd" Style="{StaticResource Card}" Margin="0,0,0,10" Padding="16,14">
                      <DockPanel>
                        <Border x:Name="IconBg" Width="38" Height="38" CornerRadius="19" Background="#FFEFF4FF" DockPanel.Dock="Left" VerticalAlignment="Top" Margin="0,0,14,0">
                          <TextBlock x:Name="Icon" Text="&#xE946;" FontFamily="{StaticResource Icons}" FontSize="17" Foreground="#FF3B6EF5" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <Button x:Name="Act" DockPanel.Dock="Right" Style="{StaticResource Small}" Content="{Binding ActionLabel, Mode=OneWay}" Tag="{Binding ActionId, Mode=OneWay}" VerticalAlignment="Center" Margin="14,0,0,0"/>
                        <StackPanel VerticalAlignment="Center">
                          <TextBlock Text="{Binding Title, Mode=OneWay}" FontWeight="SemiBold" FontSize="15" TextWrapping="Wrap"/>
                          <ToggleButton x:Name="Tg" Style="{StaticResource DetailsToggle}" HorizontalAlignment="Left" Margin="0,5,0,0"/>
                          <TextBlock x:Name="Adv" Text="{Binding Advice, Mode=OneWay}" TextWrapping="Wrap" Margin="0,8,0,0" Foreground="#FF475569" LineHeight="22" Visibility="Collapsed"/>
                        </StackPanel>
                      </DockPanel>
                    </Border>
                    <DataTemplate.Triggers>
                      <Trigger SourceName="Tg" Property="IsChecked" Value="True"><Setter TargetName="Adv" Property="Visibility" Value="Visible"/></Trigger>
                      <DataTrigger Binding="{Binding Advice}" Value="{x:Null}"><Setter TargetName="Tg" Property="Visibility" Value="Collapsed"/></DataTrigger>
                      <DataTrigger Binding="{Binding Advice}" Value=""><Setter TargetName="Tg" Property="Visibility" Value="Collapsed"/></DataTrigger>
                      <DataTrigger Binding="{Binding ActionLabel}" Value="{x:Null}"><Setter TargetName="Act" Property="Visibility" Value="Collapsed"/></DataTrigger>
                      <DataTrigger Binding="{Binding Severity}" Value="Critique">
                        <Setter TargetName="IconBg" Property="Background" Value="#FFFEECEC"/>
                        <Setter TargetName="Icon" Property="Foreground" Value="#FFEF4444"/>
                        <Setter TargetName="Icon" Property="Text" Value="&#xEA39;"/>
                        <Setter TargetName="Bd" Property="BorderBrush" Value="#FFFBCACA"/>
                      </DataTrigger>
                      <DataTrigger Binding="{Binding Severity}" Value="Attention">
                        <Setter TargetName="IconBg" Property="Background" Value="#FFFFF4E0"/>
                        <Setter TargetName="Icon" Property="Foreground" Value="#FFF59E0B"/>
                        <Setter TargetName="Icon" Property="Text" Value="&#xE7BA;"/>
                      </DataTrigger>
                      <DataTrigger Binding="{Binding Severity}" Value="OK">
                        <Setter TargetName="IconBg" Property="Background" Value="#FFE7F8EE"/>
                        <Setter TargetName="Icon" Property="Foreground" Value="#FF22C55E"/>
                        <Setter TargetName="Icon" Property="Text" Value="&#xE73E;"/>
                      </DataTrigger>
                    </DataTemplate.Triggers>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
          </ScrollViewer>
        </TabItem>

        <!-- PILOTES -->
        <TabItem>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="DriversRoot" Margin="32,28,32,24">
              <TextBlock Style="{StaticResource PageTitle}" Text="Pilotes"/>
              <TextBlock Style="{StaticResource PageSub}" Text="Mises à jour et périphériques en erreur."/>

              <Border Style="{StaticResource Card}" Margin="0,18,0,14">
                <DockPanel>
                  <Border Width="50" Height="50" CornerRadius="12" Background="#FFE7F8EE" DockPanel.Dock="Left" Margin="0,0,16,0" VerticalAlignment="Center">
                    <TextBlock Text="&#xE7F4;" FontFamily="{StaticResource Icons}" FontSize="22" Foreground="#FF16A34A" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button Content="Site du fabricant" Tag="gpu-site" Style="{StaticResource Secondary}"/>
                    <Button Tag="gpu-update" Margin="0">
                      <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE896;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0" IsHitTestVisible="False"/><TextBlock Text="Mettre à jour le pilote" IsHitTestVisible="False"/></StackPanel>
                    </Button>
                  </StackPanel>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="CARTE GRAPHIQUE" Style="{StaticResource MutedText}" FontSize="11.5" FontWeight="SemiBold"/>
                    <TextBlock x:Name="TxtGpuDrvName" Text="…" FontSize="18" FontWeight="SemiBold" Margin="0,2,0,2"/>
                    <TextBlock x:Name="TxtGpuDrvVersion" Style="{StaticResource MutedText}" TextWrapping="Wrap"/>
                  </StackPanel>
                </DockPanel>
              </Border>

              <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                <StackPanel>
                  <DockPanel>
                    <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top">
                      <Button x:Name="BtnSearchDrivers" Style="{StaticResource Secondary}" Content="Rechercher"/>
                      <Button x:Name="BtnInstallDrivers" IsEnabled="False" Margin="0">
                        <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE896;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Installer la sélection"/></StackPanel>
                      </Button>
                    </StackPanel>
                    <StackPanel>
                      <TextBlock Text="Mises à jour de pilotes (Windows Update)" FontSize="16" FontWeight="SemiBold"/>
                      <TextBlock x:Name="TxtWuStatus" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,4,12,0" Text="La recherche démarre à l'ouverture de cette page."/>
                    </StackPanel>
                  </DockPanel>
                  <ProgressBar x:Name="WuBar" Style="{x:Null}" Height="3" Margin="0,12,0,0" Foreground="#FF3B6EF5" Background="Transparent" BorderThickness="0" Visibility="Collapsed"/>
                  <DataGrid x:Name="GridWu" Margin="0,10,0,0" MaxHeight="300" Visibility="Collapsed">
                    <DataGrid.Columns>
                      <DataGridTemplateColumn Header="" Width="44">
                        <DataGridTemplateColumn.CellTemplate>
                          <DataTemplate><CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" VerticalAlignment="Center"/></DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                      <DataGridTextColumn Header="PILOTE" Binding="{Binding Title}" Width="*" ElementStyle="{StaticResource Wrap}"/>
                      <DataGridTextColumn Header="FABRICANT" Binding="{Binding Manufacturer}" Width="150"/>
                      <DataGridTextColumn Header="TYPE" Binding="{Binding DriverClass}" Width="130"/>
                      <DataGridTextColumn Header="DATE" Binding="{Binding DateText}" Width="95"/>
                      <DataGridTextColumn Header="TAILLE" Binding="{Binding SizeText}" Width="80"/>
                    </DataGrid.Columns>
                  </DataGrid>
                </StackPanel>
              </Border>

              <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                <StackPanel>
                  <DockPanel>
                    <Button DockPanel.Dock="Right" Content="Gestionnaire de périphériques" Tag="devmgmt" Style="{StaticResource Secondary}" Margin="0" VerticalAlignment="Top"/>
                    <StackPanel>
                      <TextBlock Text="Périphériques avec un problème" FontSize="16" FontWeight="SemiBold"/>
                      <TextBlock x:Name="TxtProblems" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,4,12,0" Text="…"/>
                    </StackPanel>
                  </DockPanel>
                  <DataGrid x:Name="GridProblems" Margin="0,10,0,0" MaxHeight="220" Visibility="Collapsed">
                    <DataGrid.Columns>
                      <DataGridTextColumn Header="PÉRIPHÉRIQUE" Binding="{Binding Name}" Width="*"/>
                      <DataGridTextColumn Header="TYPE" Binding="{Binding Class}" Width="130"/>
                      <DataGridTextColumn Header="PROBLÈME" Binding="{Binding Problem}" Width="240"/>
                    </DataGrid.Columns>
                  </DataGrid>
                </StackPanel>
              </Border>

              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <DockPanel>
                    <Button x:Name="BtnChipset" DockPanel.Dock="Right" Content="Pilotes chipset AMD" Tag="chipset" Style="{StaticResource Secondary}" Margin="0" VerticalAlignment="Top" Visibility="Collapsed"/>
                    <StackPanel>
                      <TextBlock Text="Pilotes des fabricants installés" FontSize="16" FontWeight="SemiBold"/>
                      <TextBlock x:Name="TxtDrivers" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,4,12,0" Text="Chargement…"/>
                    </StackPanel>
                  </DockPanel>
                  <DataGrid x:Name="GridDrivers" Margin="0,10,0,0" MaxHeight="380">
                    <DataGrid.Columns>
                      <DataGridTextColumn Header="CATÉGORIE" Binding="{Binding Category}" Width="140"/>
                      <DataGridTextColumn Header="PÉRIPHÉRIQUE" Binding="{Binding Device}" Width="*"/>
                      <DataGridTextColumn Header="FABRICANT" Binding="{Binding Provider}" Width="150"/>
                      <DataGridTextColumn Header="VERSION" Binding="{Binding Version}" Width="130"/>
                      <DataGridTextColumn Header="DATE" Binding="{Binding DateText}" SortMemberPath="Date" Width="95"/>
                      <DataGridTemplateColumn Header="ÂGE" Width="85" SortMemberPath="Date">
                        <DataGridTemplateColumn.CellTemplate>
                          <DataTemplate>
                            <TextBlock x:Name="A" Text="{Binding AgeText, Mode=OneWay}"/>
                            <DataTemplate.Triggers>
                              <DataTrigger Binding="{Binding Old}" Value="True"><Setter TargetName="A" Property="Foreground" Value="#FFDC2626"/><Setter TargetName="A" Property="FontWeight" Value="SemiBold"/></DataTrigger>
                            </DataTemplate.Triggers>
                          </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                    </DataGrid.Columns>
                  </DataGrid>
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </TabItem>

        <!-- LOGICIELS -->
        <TabItem>
          <DockPanel Margin="32,28,32,20">
            <StackPanel DockPanel.Dock="Top">
              <TextBlock Style="{StaticResource PageTitle}" Text="Mises à jour des logiciels"/>
              <TextBlock Style="{StaticResource PageSub}" Text="Mettez vos programmes à jour en un clic (winget, l'outil de Microsoft)."/>
              <DockPanel Margin="0,16,0,8">
                <Button x:Name="BtnSwSearch" Content="Rechercher" Style="{StaticResource Secondary}" DockPanel.Dock="Left"/>
                <Button x:Name="BtnSwAll" DockPanel.Dock="Left" IsEnabled="False">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE896;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Tout mettre à jour"/></StackPanel>
                </Button>
                <TextBlock x:Name="TxtSwStatus" Style="{StaticResource MutedText}" VerticalAlignment="Center" TextWrapping="Wrap" Text="La recherche démarre à l'ouverture de cette page."/>
              </DockPanel>
              <ProgressBar x:Name="SwBar" Style="{x:Null}" Height="3" Margin="0,0,0,10" Foreground="#FF3B6EF5" Background="Transparent" BorderThickness="0" Visibility="Collapsed"/>
            </StackPanel>
            <Border Style="{StaticResource Panel}">
              <DataGrid x:Name="GridSoftware">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="LOGICIEL" Binding="{Binding Name}" Width="*">
                    <DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="FontWeight" Value="SemiBold"/></Style></DataGridTextColumn.ElementStyle>
                  </DataGridTextColumn>
                  <DataGridTextColumn Header="VERSION INSTALLÉE" Binding="{Binding Version}" Width="160"/>
                  <DataGridTextColumn Header="NOUVELLE VERSION" Binding="{Binding Available}" Width="160"/>
                  <DataGridTemplateColumn Header="" Width="140">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate><Button Content="Mettre à jour" Tag="sw-update" Style="{StaticResource Small}" Width="112"/></DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                </DataGrid.Columns>
              </DataGrid>
            </Border>
          </DockPanel>
        </TabItem>

        <!-- PERFORMANCES / OVERCLOCKING -->
        <TabItem>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="PerfRoot" Margin="32,28,32,24">
              <DockPanel>
                <Button DockPanel.Dock="Right" Tag="widget-open" VerticalAlignment="Top" Margin="0">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7C4;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Ouvrir le widget"/></StackPanel>
                </Button>
                <TextBlock Style="{StaticResource PageTitle}" Text="Performances et overclocking"/>
              </DockPanel>
              <TextBlock Style="{StaticResource PageSub}" Text="Températures, overclocking et santé des disques. Tout est réversible."/>
              <Grid Margin="0,18,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="3*"/>
                  <ColumnDefinition Width="16"/>
                  <ColumnDefinition Width="2*"/>
                </Grid.ColumnDefinitions>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <DockPanel>
                      <Border x:Name="LivePill" DockPanel.Dock="Right" CornerRadius="10" Background="#FFE7F8EE" Padding="9,3" VerticalAlignment="Top" Visibility="Collapsed">
                        <StackPanel Orientation="Horizontal">
                          <Ellipse Width="7" Height="7" Fill="#FF22C55E" VerticalAlignment="Center"/>
                          <TextBlock Text="EN DIRECT" FontSize="11" FontWeight="Bold" Foreground="#FF15803D" Margin="6,0,0,0"/>
                        </StackPanel>
                      </Border>
                      <StackPanel>
                        <TextBlock Text="CARTE GRAPHIQUE" Style="{StaticResource MutedText}" FontSize="11.5" FontWeight="SemiBold"/>
                        <TextBlock x:Name="TxtGpuName" Text="…" FontSize="18" FontWeight="SemiBold" Margin="0,2,0,0"/>
                      </StackPanel>
                    </DockPanel>
                    <TextBlock x:Name="TxtGpuNA" Visibility="Collapsed" TextWrapping="Wrap" Style="{StaticResource MutedText}" Margin="0,12,0,0" Text="Le suivi en direct fonctionne avec les cartes NVIDIA. Pour les autres cartes, utilisez HWiNFO (lien dans Solutions)."/>
                    <UniformGrid x:Name="GpuStats" Columns="4" Margin="0,18,-14,0">
                      <StackPanel Margin="0,0,14,0">
                        <TextBlock Text="Température" Style="{StaticResource MutedText}" FontSize="12"/>
                        <TextBlock x:Name="TxtGpuTemp" Text="—" FontSize="26" FontWeight="SemiBold" Margin="0,2,0,6"/>
                        <ProgressBar x:Name="BarGpuTemp" Maximum="100"/>
                        <TextBlock x:Name="TxtGpuTempMax" Style="{StaticResource MutedText}" FontSize="11.5" Margin="0,6,0,0" TextWrapping="Wrap"/>
                      </StackPanel>
                      <StackPanel Margin="0,0,14,0">
                        <TextBlock Text="Consommation" Style="{StaticResource MutedText}" FontSize="12"/>
                        <TextBlock x:Name="TxtGpuPower" Text="—" FontSize="26" FontWeight="SemiBold" Margin="0,2,0,6"/>
                        <ProgressBar x:Name="BarGpuPower" Maximum="100"/>
                        <TextBlock x:Name="TxtGpuPowerSub" Style="{StaticResource MutedText}" FontSize="11.5" Margin="0,6,0,0" TextWrapping="Wrap"/>
                      </StackPanel>
                      <StackPanel Margin="0,0,14,0">
                        <TextBlock Text="Fréquence" Style="{StaticResource MutedText}" FontSize="12"/>
                        <TextBlock x:Name="TxtGpuClock" Text="—" FontSize="26" FontWeight="SemiBold" Margin="0,2,0,6"/>
                        <ProgressBar x:Name="BarGpuClock" Maximum="3000"/>
                        <TextBlock x:Name="TxtGpuClockSub" Style="{StaticResource MutedText}" FontSize="11.5" Margin="0,6,0,0" TextWrapping="Wrap"/>
                      </StackPanel>
                      <StackPanel Margin="0,0,14,0">
                        <TextBlock Text="Utilisation" Style="{StaticResource MutedText}" FontSize="12"/>
                        <TextBlock x:Name="TxtGpuUsage" Text="—" FontSize="26" FontWeight="SemiBold" Margin="0,2,0,6"/>
                        <ProgressBar x:Name="BarGpuUsage" Maximum="100"/>
                        <TextBlock x:Name="TxtGpuFan" Style="{StaticResource MutedText}" FontSize="11.5" Margin="0,6,0,0" TextWrapping="Wrap"/>
                      </StackPanel>
                    </UniformGrid>
                    <Border x:Name="GpuLimitBox" Background="#FFF7F9FC" CornerRadius="10" Padding="14,12" Margin="0,18,0,0">
                      <StackPanel>
                        <TextBlock Text="Limite de puissance" FontWeight="SemiBold"/>
                        <TextBlock x:Name="TxtGpuLimit" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,3,0,10"/>
                        <WrapPanel>
                          <Button Content="100 % (normal)" Tag="gpu-pl:100" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                          <Button Content="90 %" Tag="gpu-pl:90" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                          <Button Content="80 %" Tag="gpu-pl:80" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                          <Button Content="75 %" Tag="gpu-pl:75" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                          <Button Content="70 %" Tag="gpu-pl:70" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                        </WrapPanel>
                        <ToggleButton x:Name="TgGpuPl" Style="{StaticResource DetailsToggle}" HorizontalAlignment="Left" Margin="0,4,0,0"/>
                        <TextBlock Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,6,0,0" LineHeight="20" Visibility="{Binding IsChecked, ElementName=TgGpuPl, Converter={StaticResource B2V}}" Text="Test d'alimentation : à 75 %, la carte évite ses pics de consommation (environ 5 % de FPS en moins). Si les coupures disparaissent, l'alimentation est en cause. Retour à 100 % au redémarrage."/>
                      </StackPanel>
                    </Border>
                  </StackPanel>
                </Border>
                <Border Grid.Column="2" Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="MÉMOIRE VIVE" Style="{StaticResource MutedText}" FontSize="11.5" FontWeight="SemiBold"/>
                    <TextBlock x:Name="TxtRamTitle" Text="…" FontSize="18" FontWeight="SemiBold" Margin="0,2,0,2" TextWrapping="Wrap"/>
                    <TextBlock x:Name="TxtRamDetail" Style="{StaticResource MutedText}" TextWrapping="Wrap"/>
                    <Border x:Name="RamPill" CornerRadius="10" Padding="10,3" HorizontalAlignment="Left" Margin="0,12,0,0" Background="#FFF1F5F9">
                      <TextBlock x:Name="RamPillText" FontWeight="SemiBold" FontSize="12"/>
                    </Border>
                    <TextBlock x:Name="TxtRamAdvice" TextWrapping="Wrap" Margin="0,12,0,0" Foreground="#FF475569"/>
                    <Button Content="Redémarrer dans le BIOS" Tag="bios" HorizontalAlignment="Left" Margin="0,14,0,0"/>
                  </StackPanel>
                </Border>
              </Grid>
              <Grid Margin="0,16,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="16"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="16"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="PROCESSEUR" Style="{StaticResource MutedText}" FontSize="11.5" FontWeight="SemiBold"/>
                    <TextBlock x:Name="TxtCpuOcName" Text="…" FontSize="15" FontWeight="SemiBold" Margin="0,2,0,2" TextWrapping="Wrap"/>
                    <TextBlock x:Name="TxtCpuOcDetail" Style="{StaticResource MutedText}" TextWrapping="Wrap"/>
                    <TextBlock x:Name="TxtCpuOcNote" TextWrapping="Wrap" Margin="0,10,0,0" Foreground="#FF475569"/>
                  </StackPanel>
                </Border>
                <Border Grid.Column="2" Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="LOGICIELS D'OVERCLOCKING" Style="{StaticResource MutedText}" FontSize="11.5" FontWeight="SemiBold"/>
                    <TextBlock x:Name="TxtOcTools" Text="…" FontSize="15" FontWeight="SemiBold" Margin="0,2,0,2" TextWrapping="Wrap"/>
                    <TextBlock x:Name="TxtOcToolsAdvice" TextWrapping="Wrap" Margin="0,8,0,0" Foreground="#FF475569"/>
                  </StackPanel>
                </Border>
                <Border Grid.Column="4" Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="MODE D'ALIMENTATION WINDOWS" Style="{StaticResource MutedText}" FontSize="11.5" FontWeight="SemiBold"/>
                    <TextBlock x:Name="TxtPowerPlan" Text="…" FontSize="15" FontWeight="SemiBold" Margin="0,2,0,2" TextWrapping="Wrap"/>
                    <TextBlock Style="{StaticResource MutedText}" TextWrapping="Wrap" Text="Les deux conviennent pour jouer."/>
                    <WrapPanel Margin="0,12,0,0">
                      <Button Content="Équilibré" Tag="power:balanced" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                      <Button Content="Performances élevées" Tag="power:high" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
              </Grid>

              <TextBlock Style="{StaticResource Section}" Text="Santé des disques" Margin="0,24,0,6"/>
              <TextBlock x:Name="TxtDiskHealthNote" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,0,0,10" Visibility="Collapsed" Text="Passez en administrateur (en bas à gauche) pour voir la température, l'usure et les erreurs de chaque disque."/>
              <ItemsControl x:Name="ListDisks">
                <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border Style="{StaticResource Card}" Width="340" Margin="0,0,14,14">
                      <StackPanel>
                        <DockPanel>
                          <Border x:Name="P" DockPanel.Dock="Right" CornerRadius="10" Padding="9,2" Background="#FFE3F7EA" VerticalAlignment="Top">
                            <TextBlock x:Name="T" Text="{Binding Health, Mode=OneWay}" FontSize="11.5" FontWeight="SemiBold" Foreground="#FF15803D"/>
                          </Border>
                          <StackPanel>
                            <TextBlock Text="{Binding Name, Mode=OneWay}" FontWeight="SemiBold" FontSize="14.5" TextTrimming="CharacterEllipsis"/>
                            <TextBlock Text="{Binding Kind, Mode=OneWay}" Style="{StaticResource MutedText}" FontSize="12"/>
                          </StackPanel>
                        </DockPanel>
                        <DockPanel Margin="0,12,0,3"><TextBlock Text="Température" Width="100" Style="{StaticResource MutedText}"/><TextBlock Text="{Binding TempText, Mode=OneWay}"/></DockPanel>
                        <DockPanel Margin="0,3"><TextBlock Text="Usure" Width="100" Style="{StaticResource MutedText}"/><TextBlock Text="{Binding WearText, Mode=OneWay}"/></DockPanel>
                        <DockPanel Margin="0,3"><TextBlock Text="Allumé" Width="100" Style="{StaticResource MutedText}"/><TextBlock Text="{Binding HoursText, Mode=OneWay}"/></DockPanel>
                        <DockPanel Margin="0,3"><TextBlock Text="Erreurs" Width="100" Style="{StaticResource MutedText}"/><TextBlock Text="{Binding ErrorsText, Mode=OneWay}"/></DockPanel>
                      </StackPanel>
                    </Border>
                    <DataTemplate.Triggers>
                      <DataTrigger Binding="{Binding Health}" Value="Avertissement"><Setter TargetName="P" Property="Background" Value="#FFFFF1DB"/><Setter TargetName="T" Property="Foreground" Value="#FFB45309"/></DataTrigger>
                      <DataTrigger Binding="{Binding Health}" Value="Mauvais"><Setter TargetName="P" Property="Background" Value="#FFFEECEC"/><Setter TargetName="T" Property="Foreground" Value="#FFDC2626"/></DataTrigger>
                      <DataTrigger Binding="{Binding Health}" Value="Inconnu"><Setter TargetName="P" Property="Background" Value="#FFF1F5F9"/><Setter TargetName="T" Property="Foreground" Value="#FF64748B"/></DataTrigger>
                    </DataTemplate.Triggers>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
          </ScrollViewer>
        </TabItem>

        <!-- RESEAU -->
        <TabItem>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="NetRoot" Margin="32,28,32,24">
              <TextBlock Style="{StaticResource PageTitle}" Text="Réseau"/>
              <TextBlock Style="{StaticResource PageSub}" Text="Ping, stabilité et pertes de paquets : utile quand les jeux lagguent."/>
              <DockPanel Margin="0,16,0,8">
                <Button x:Name="BtnNetTest" DockPanel.Dock="Left">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE768;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Lancer le test"/></StackPanel>
                </Button>
                <TextBlock x:Name="TxtNetStatus" Style="{StaticResource MutedText}" VerticalAlignment="Center" TextWrapping="Wrap" Text="Le test dure une dizaine de secondes."/>
              </DockPanel>
              <ProgressBar x:Name="NetBar" Style="{x:Null}" Height="3" Margin="0,0,0,10" Foreground="#FF3B6EF5" Background="Transparent" BorderThickness="0" Visibility="Collapsed"/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="2*"/>
                  <ColumnDefinition Width="16"/>
                  <ColumnDefinition Width="3*"/>
                </Grid.ColumnDefinitions>
                <Border Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="CONNEXION" Style="{StaticResource MutedText}" FontSize="11.5" FontWeight="SemiBold"/>
                    <TextBlock x:Name="TxtNetType" Text="—" FontSize="18" FontWeight="SemiBold" Margin="0,2,0,4"/>
                    <TextBlock x:Name="TxtNetDetail" Style="{StaticResource MutedText}" TextWrapping="Wrap"/>
                  </StackPanel>
                </Border>
                <Border Grid.Column="2" Style="{StaticResource Card}">
                  <StackPanel>
                    <TextBlock Text="VERDICT" Style="{StaticResource MutedText}" FontSize="11.5" FontWeight="SemiBold"/>
                    <TextBlock x:Name="TxtNetVerdictTitle" Text="Lancez le test" FontSize="18" FontWeight="SemiBold" Margin="0,2,0,4"/>
                    <TextBlock x:Name="TxtNetVerdict" TextWrapping="Wrap" Foreground="#FF475569"/>
                  </StackPanel>
                </Border>
              </Grid>
              <Border Style="{StaticResource Panel}" Margin="0,16,0,0">
                <DataGrid x:Name="GridNet">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="CIBLE" Binding="{Binding Name}" Width="*">
                      <DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="FontWeight" Value="SemiBold"/></Style></DataGridTextColumn.ElementStyle>
                    </DataGridTextColumn>
                    <DataGridTextColumn Header="PING MOYEN" Binding="{Binding AvgText}" Width="110"/>
                    <DataGridTextColumn Header="MIN – MAX" Binding="{Binding RangeText}" Width="120"/>
                    <DataGridTextColumn Header="GIGUE" Binding="{Binding JitterText}" Width="90"/>
                    <DataGridTextColumn Header="PERTES" Binding="{Binding LossText}" Width="80"/>
                    <DataGridTemplateColumn Header="RÉSULTAT" Width="110">
                      <DataGridTemplateColumn.CellTemplate>
                        <DataTemplate>
                          <Border x:Name="P" CornerRadius="10" Padding="10,3" HorizontalAlignment="Left" Background="#FFE3F7EA">
                            <TextBlock x:Name="T" Text="{Binding Verdict, Mode=OneWay}" FontSize="12" FontWeight="SemiBold" Foreground="#FF15803D"/>
                          </Border>
                          <DataTemplate.Triggers>
                            <DataTrigger Binding="{Binding Verdict}" Value="Moyen"><Setter TargetName="P" Property="Background" Value="#FFFFF1DB"/><Setter TargetName="T" Property="Foreground" Value="#FFB45309"/></DataTrigger>
                            <DataTrigger Binding="{Binding Verdict}" Value="Mauvais"><Setter TargetName="P" Property="Background" Value="#FFFEECEC"/><Setter TargetName="T" Property="Foreground" Value="#FFDC2626"/></DataTrigger>
                          </DataTemplate.Triggers>
                        </DataTemplate>
                      </DataGridTemplateColumn.CellTemplate>
                    </DataGridTemplateColumn>
                  </DataGrid.Columns>
                </DataGrid>
              </Border>
              <Border Style="{StaticResource Card}" Margin="0,16,0,0">
                <DockPanel>
                  <Button DockPanel.Dock="Right" Content="Paramètres réseau" Tag="ms-settings:network-status" Style="{StaticResource Secondary}" Margin="12,0,0,0" VerticalAlignment="Center"/>
                  <StackPanel>
                    <TextBlock Text="DNS (traduction des adresses web)" FontWeight="SemiBold"/>
                    <TextBlock x:Name="TxtNetDns" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,4,0,0" Text="—"/>
                  </StackPanel>
                </DockPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </TabItem>

        <!-- DEMARRAGE -->
        <TabItem>
          <DockPanel Margin="32,28,32,20">
            <StackPanel DockPanel.Dock="Top">
              <TextBlock Style="{StaticResource PageTitle}" Text="Programmes au démarrage"/>
              <TextBlock x:Name="TxtStartupInfo" Style="{StaticResource PageSub}"/>
              <Border x:Name="BootCard" Style="{StaticResource Card}" Margin="0,16,0,0" Padding="18,14" Visibility="Collapsed">
                <StackPanel>
                  <DockPanel>
                    <Button x:Name="BtnBootHistory" DockPanel.Dock="Right" Content="Historique" Style="{StaticResource Small}" VerticalAlignment="Center"/>
                    <TextBlock x:Name="TxtBootAvg" DockPanel.Dock="Right" Style="{StaticResource MutedText}" FontSize="12.5" VerticalAlignment="Center" Margin="0,0,12,0"/>
                    <TextBlock x:Name="TxtBootTitle" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center"/>
                  </DockPanel>
                  <Grid x:Name="BootBar" Height="10" Margin="0,12,0,6">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition x:Name="BootColFw" Width="1*"/>
                      <ColumnDefinition x:Name="BootColLd" Width="1*"/>
                      <ColumnDefinition x:Name="BootColSs" Width="1*"/>
                    </Grid.ColumnDefinitions>
                    <Border Background="#FFF59E0B" CornerRadius="5,0,0,5" Margin="0,0,2,0"/>
                    <Border Grid.Column="1" Background="#FF3B6EF5" Margin="0,0,2,0"/>
                    <Border Grid.Column="2" Background="#FF22C55E" CornerRadius="0,5,5,0"/>
                  </Grid>
                  <WrapPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,0,18,0"><Ellipse Width="8" Height="8" Fill="#FFF59E0B" VerticalAlignment="Center"/><TextBlock x:Name="TxtBootFw" FontSize="12.5" Margin="6,0,0,0"/></StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,0,18,0"><Ellipse Width="8" Height="8" Fill="#FF3B6EF5" VerticalAlignment="Center"/><TextBlock x:Name="TxtBootLd" FontSize="12.5" Margin="6,0,0,0"/></StackPanel>
                    <StackPanel Orientation="Horizontal"><Ellipse Width="8" Height="8" Fill="#FF22C55E" VerticalAlignment="Center"/><TextBlock x:Name="TxtBootSs" FontSize="12.5" Margin="6,0,0,0"/></StackPanel>
                  </WrapPanel>
                  <TextBlock x:Name="TxtBootAdvice" TextWrapping="Wrap" Margin="0,10,0,0" LineHeight="19" Foreground="#FF475569"/>
                  <Border x:Name="BootHistoryBox" Style="{StaticResource Panel}" Margin="0,10,0,0" Visibility="Collapsed">
                    <DataGrid x:Name="GridBoots" MaxHeight="220">
                      <DataGrid.Columns>
                        <DataGridTextColumn Header="DÉMARRAGE" Binding="{Binding DateText}" SortMemberPath="Date" Width="110"/>
                        <DataGridTextColumn Header="CARTE MÈRE" Binding="{Binding FirmwareText}" SortMemberPath="Firmware" Width="110"/>
                        <DataGridTextColumn Header="WINDOWS" Binding="{Binding LoaderText}" SortMemberPath="Loader" Width="95"/>
                        <DataGridTextColumn Header="SESSION" Binding="{Binding SessionText}" SortMemberPath="Session" Width="90"/>
                        <DataGridTextColumn Header="TOTAL" Binding="{Binding TotalText}" SortMemberPath="Total" Width="80"/>
                        <DataGridTextColumn Header="TYPE" Binding="{Binding Type}" Width="*"/>
                      </DataGrid.Columns>
                    </DataGrid>
                  </Border>
                </StackPanel>
              </Border>
              <WrapPanel Margin="0,16,0,14">
                <Button x:Name="BtnDisableRecommended" Margin="0,0,8,6">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE945;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock x:Name="TxtDisableRecommended" Text="Désactiver les programmes conseillés"/></StackPanel>
                </Button>
                <Button x:Name="BtnRefreshStartup" Content="Actualiser" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                <Button x:Name="BtnStartupTaskmgr" Content="Gestionnaire des tâches" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
              </WrapPanel>
            </StackPanel>
            <Border Style="{StaticResource Panel}">
              <DataGrid x:Name="GridStartup">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Header="PROGRAMME" Width="260" SortMemberPath="DisplayName">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <StackPanel Margin="0,8">
                          <TextBlock x:Name="N" Text="{Binding DisplayName, Mode=OneWay}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                          <TextBlock Text="{Binding Sub, Mode=OneWay}" Foreground="#FF64748B" FontSize="11.5" TextTrimming="CharacterEllipsis"/>
                        </StackPanel>
                        <DataTemplate.Triggers>
                          <DataTrigger Binding="{Binding Enabled}" Value="False"><Setter TargetName="N" Property="Foreground" Value="#FF94A3B8"/></DataTrigger>
                        </DataTemplate.Triggers>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTemplateColumn Header="CONSEIL" Width="125" SortMemberPath="AdviceOrder">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <Border x:Name="P" CornerRadius="10" Padding="10,3" HorizontalAlignment="Left" Background="#FFF1F5F9">
                          <TextBlock x:Name="T" Text="{Binding Advice, Mode=OneWay}" FontSize="12" FontWeight="SemiBold" Foreground="#FF475569"/>
                        </Border>
                        <DataTemplate.Triggers>
                          <DataTrigger Binding="{Binding Advice}" Value="Désactivable">
                            <Setter TargetName="P" Property="Background" Value="#FFFFF1DB"/><Setter TargetName="T" Property="Foreground" Value="#FFB45309"/>
                          </DataTrigger>
                          <DataTrigger Binding="{Binding Advice}" Value="À garder">
                            <Setter TargetName="P" Property="Background" Value="#FFE3F7EA"/><Setter TargetName="T" Property="Foreground" Value="#FF15803D"/>
                          </DataTrigger>
                          <DataTrigger Binding="{Binding Advice}" Value="Au choix">
                            <Setter TargetName="P" Property="Background" Value="#FFE8EFFE"/><Setter TargetName="T" Property="Foreground" Value="#FF3B6EF5"/>
                          </DataTrigger>
                        </DataTemplate.Triggers>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTextColumn Header="POURQUOI" Binding="{Binding AdviceText}" Width="*" ElementStyle="{StaticResource Wrap}">
                  </DataGridTextColumn>
                  <DataGridTemplateColumn Header="ÉTAT" Width="105" SortMemberPath="State">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <StackPanel Orientation="Horizontal">
                          <Ellipse x:Name="Dot" Width="8" Height="8" Fill="#FF22C55E" VerticalAlignment="Center"/>
                          <TextBlock Text="{Binding State, Mode=OneWay}" Margin="7,0,0,0" VerticalAlignment="Center"/>
                        </StackPanel>
                        <DataTemplate.Triggers>
                          <DataTrigger Binding="{Binding Enabled}" Value="False"><Setter TargetName="Dot" Property="Fill" Value="#FFCBD5E1"/></DataTrigger>
                        </DataTemplate.Triggers>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTemplateColumn Header="" Width="115">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <Button x:Name="B" Content="{Binding ActionText, Mode=OneWay}" Tag="toggle-startup" Style="{StaticResource Small}" Width="92"/>
                        <DataTemplate.Triggers>
                          <DataTrigger Binding="{Binding Enabled}" Value="False">
                            <Setter TargetName="B" Property="Background" Value="#FF3B6EF5"/>
                            <Setter TargetName="B" Property="Foreground" Value="White"/>
                            <Setter TargetName="B" Property="BorderBrush" Value="#FF3B6EF5"/>
                          </DataTrigger>
                        </DataTemplate.Triggers>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                </DataGrid.Columns>
              </DataGrid>
            </Border>
          </DockPanel>
        </TabItem>

        <!-- PROCESSUS -->
        <TabItem>
          <DockPanel Margin="32,28,32,20">
            <StackPanel DockPanel.Dock="Top">
              <TextBlock Style="{StaticResource PageTitle}" Text="Processus"/>
              <TextBlock Style="{StaticResource PageSub}" Text="Cliquez sur « Actualiser » quand le PC rame pour voir le coupable."/>
              <WrapPanel Margin="0,16,0,14">
                <Button x:Name="BtnRefreshProc" Margin="0,0,8,6">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72C;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Actualiser"/></StackPanel>
                </Button>
                <Button x:Name="BtnTaskmgr" Content="Gestionnaire des tâches" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
              </WrapPanel>
            </StackPanel>
            <Border Style="{StaticResource Panel}">
              <DataGrid x:Name="GridProcs">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Header="PROGRAMME" Width="*" SortMemberPath="Description">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <StackPanel Margin="0,6">
                          <TextBlock Text="{Binding Description, Mode=OneWay}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                          <TextBlock Foreground="#FF64748B" FontSize="11.5"><Run Text="{Binding Name, Mode=OneWay}"/><Run Text=".exe  ·  "/><Run Text="{Binding Count, Mode=OneWay}"/><Run Text=" instance(s)"/></TextBlock>
                        </StackPanel>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                  <DataGridTextColumn Header="PROCESSEUR" Binding="{Binding CpuText}" SortMemberPath="CpuPct" Width="110"/>
                  <DataGridTextColumn Header="MÉMOIRE" Binding="{Binding RamText}" SortMemberPath="RamBytes" Width="100"/>
                  <DataGridTemplateColumn Header="PART DE LA RAM" Width="200" SortMemberPath="RamBytes">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate><ProgressBar Value="{Binding RamPct, Mode=OneWay}" Maximum="30" Height="7"/></DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                </DataGrid.Columns>
              </DataGrid>
            </Border>
          </DockPanel>
        </TabItem>

        <!-- PLANTAGES -->
        <TabItem>
          <DockPanel Margin="32,28,32,20">
            <StackPanel DockPanel.Dock="Top">
              <DockPanel>
                <Button x:Name="BtnGoSolutions" DockPanel.Dock="Right" VerticalAlignment="Top" Margin="0">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE82F;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Voir les solutions"/></StackPanel>
                </Button>
                <StackPanel>
                  <TextBlock Style="{StaticResource PageTitle}" Text="Plantages"/>
                  <TextBlock Style="{StaticResource PageSub}" Text="Écrans bleus, coupures et logiciels qui plantent (30 derniers jours)."/>
                </StackPanel>
              </DockPanel>
              <ItemsControl x:Name="ListCrashStats" Margin="0,16,0,14">
                <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border Style="{StaticResource Card}" Padding="16,10" Margin="0,0,10,10" MinWidth="150">
                      <StackPanel>
                        <TextBlock Text="{Binding Count, Mode=OneWay}" FontSize="24" FontWeight="SemiBold"/>
                        <TextBlock Text="{Binding Name, Mode=OneWay}" Style="{StaticResource MutedText}"/>
                      </StackPanel>
                    </Border>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>
            </StackPanel>
            <Border Style="{StaticResource Panel}">
              <DataGrid x:Name="GridCrashes">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="DATE" Binding="{Binding DateText}" SortMemberPath="Date" Width="140"/>
                  <DataGridTextColumn Header="TYPE" Binding="{Binding Category}" Width="160">
                    <DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="FontWeight" Value="SemiBold"/></Style></DataGridTextColumn.ElementStyle>
                  </DataGridTextColumn>
                  <DataGridTextColumn Header="DÉTAIL" Binding="{Binding Detail}" Width="*" ElementStyle="{StaticResource Wrap}"/>
                </DataGrid.Columns>
              </DataGrid>
            </Border>
          </DockPanel>
        </TabItem>

        <!-- ESPACE DISQUE -->
        <TabItem>
          <DockPanel Margin="32,28,32,20">
            <StackPanel DockPanel.Dock="Top">
              <TextBlock Style="{StaticResource PageTitle}" Text="Espace disque"/>
              <TextBlock Style="{StaticResource PageSub}" Text="Ce qui prend le plus de place. Double-cliquez sur un dossier pour l'ouvrir."/>
              <DockPanel Margin="0,16,0,10">
                <ComboBox x:Name="CmbDrives" Width="340" Margin="0,0,8,0" VerticalContentAlignment="Center" Padding="10,7" DockPanel.Dock="Left"/>
                <Button x:Name="BtnChooseFolder" Content="Choisir un dossier…" Style="{StaticResource Secondary}" DockPanel.Dock="Left"/>
                <Button x:Name="BtnScan" DockPanel.Dock="Left">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE721;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Analyser"/></StackPanel>
                </Button>
                <Button x:Name="BtnCancelScan" Content="Arrêter" Style="{StaticResource Secondary}" IsEnabled="False" DockPanel.Dock="Left"/>
                <TextBlock x:Name="TxtScanProgress" Style="{StaticResource MutedText}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Text="Choisissez un disque puis « Analyser »."/>
              </DockPanel>
              <ProgressBar x:Name="ScanBar" Style="{x:Null}" Height="3" Margin="0,0,0,10" Foreground="#FF3B6EF5" Background="Transparent" BorderThickness="0"/>
              <Border Style="{StaticResource Panel}" Padding="8" Margin="0,0,0,12">
                <DockPanel>
                  <Button x:Name="BtnUp" Style="{StaticResource Small}" IsEnabled="False" DockPanel.Dock="Left" Margin="0,0,10,0">
                    <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74A;" FontFamily="{StaticResource Icons}" Margin="0,1,6,0"/><TextBlock Text="Parent"/></StackPanel>
                  </Button>
                  <Button x:Name="BtnOpenFolder" Content="Ouvrir dans l'Explorateur" Style="{StaticResource Small}" IsEnabled="False" DockPanel.Dock="Right" Margin="10,0,0,0"/>
                  <TextBlock Text="&#xE8B7;" FontFamily="{StaticResource Icons}" Foreground="#FFF59E0B" VerticalAlignment="Center" Margin="0,0,8,0" DockPanel.Dock="Left"/>
                  <TextBlock x:Name="TxtCurrentPath" VerticalAlignment="Center" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" Text="—"/>
                </DockPanel>
              </Border>
            </StackPanel>
            <TabControl x:Name="DiskTabs" BorderThickness="0" Background="Transparent" Padding="0">
              <TabControl.Template>
                <ControlTemplate TargetType="TabControl">
                  <DockPanel>
                    <Border DockPanel.Dock="Top" Background="#FFE6EBF2" CornerRadius="10" Padding="4" HorizontalAlignment="Left" Margin="0,0,0,10">
                      <TabPanel IsItemsHost="True"/>
                    </Border>
                    <ContentPresenter ContentSource="SelectedContent"/>
                  </DockPanel>
                </ControlTemplate>
              </TabControl.Template>
              <TabItem Header="Dossiers">
                <Border Style="{StaticResource Panel}">
                  <DataGrid x:Name="GridFolders">
                    <DataGrid.Columns>
                      <DataGridTemplateColumn Header="DOSSIER" Width="*" SortMemberPath="Name">
                        <DataGridTemplateColumn.CellTemplate>
                          <DataTemplate>
                            <StackPanel Orientation="Horizontal">
                              <TextBlock x:Name="I" Text="&#xE8B7;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Foreground="#FFF59E0B" VerticalAlignment="Center" Margin="0,0,10,0"/>
                              <TextBlock Text="{Binding Name, Mode=OneWay}" VerticalAlignment="Center"/>
                            </StackPanel>
                            <DataTemplate.Triggers>
                              <DataTrigger Binding="{Binding Node}" Value="{x:Null}"><Setter TargetName="I" Property="Text" Value="&#xE8A5;"/><Setter TargetName="I" Property="Foreground" Value="#FF94A3B8"/></DataTrigger>
                            </DataTemplate.Triggers>
                          </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                      <DataGridTextColumn Header="TAILLE" Binding="{Binding SizeText}" SortMemberPath="SizeBytes" Width="100">
                        <DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="FontWeight" Value="SemiBold"/></Style></DataGridTextColumn.ElementStyle>
                      </DataGridTextColumn>
                      <DataGridTemplateColumn Header="PART" Width="220" SortMemberPath="SizeBytes">
                        <DataGridTemplateColumn.CellTemplate>
                          <DataTemplate>
                            <DockPanel>
                              <TextBlock Text="{Binding PctText, Mode=OneWay}" DockPanel.Dock="Right" Width="52" TextAlignment="Right" Foreground="#FF64748B" FontSize="12"/>
                              <ProgressBar Value="{Binding Pct, Mode=OneWay}" Maximum="100" Height="7" VerticalAlignment="Center"/>
                            </DockPanel>
                          </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                      <DataGridTextColumn Header="FICHIERS" Binding="{Binding FilesText}" SortMemberPath="FilesNum" Width="100"/>
                    </DataGrid.Columns>
                  </DataGrid>
                </Border>
              </TabItem>
              <TabItem Header="Plus gros fichiers">
                <DockPanel>
                  <StackPanel Orientation="Horizontal" DockPanel.Dock="Top" Margin="0,0,0,10">
                    <Button x:Name="BtnShowFile" Content="Afficher dans l'Explorateur" Style="{StaticResource Secondary}"/>
                    <Button x:Name="BtnRecycleFile" Content="Mettre à la corbeille" Style="{StaticResource Danger}"/>
                  </StackPanel>
                  <Border Style="{StaticResource Panel}">
                    <DataGrid x:Name="GridFiles">
                      <DataGrid.Columns>
                        <DataGridTextColumn Header="FICHIER" Binding="{Binding Name}" Width="260"/>
                        <DataGridTextColumn Header="TAILLE" Binding="{Binding SizeText}" SortMemberPath="SizeBytes" Width="95">
                          <DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="FontWeight" Value="SemiBold"/></Style></DataGridTextColumn.ElementStyle>
                        </DataGridTextColumn>
                        <DataGridTextColumn Header="TYPE" Binding="{Binding Category}" Width="150"/>
                        <DataGridTextColumn Header="MODIFIÉ" Binding="{Binding ModifiedText}" SortMemberPath="Modified" Width="100"/>
                        <DataGridTextColumn Header="DOSSIER" Binding="{Binding Folder}" Width="*"/>
                      </DataGrid.Columns>
                    </DataGrid>
                  </Border>
                </DockPanel>
              </TabItem>
              <TabItem Header="Par type de fichier">
                <Border Style="{StaticResource Panel}">
                  <DataGrid x:Name="GridExt">
                    <DataGrid.Columns>
                      <DataGridTextColumn Header="EXTENSION" Binding="{Binding Ext}" Width="140"/>
                      <DataGridTextColumn Header="CATÉGORIE" Binding="{Binding Category}" Width="180"/>
                      <DataGridTextColumn Header="TAILLE TOTALE" Binding="{Binding SizeText}" SortMemberPath="SizeBytes" Width="120"/>
                      <DataGridTextColumn Header="PART" Binding="{Binding PctText}" SortMemberPath="SizeBytes" Width="80"/>
                      <DataGridTextColumn Header="NOMBRE DE FICHIERS" Binding="{Binding CountText}" SortMemberPath="Count" Width="*"/>
                    </DataGrid.Columns>
                  </DataGrid>
                </Border>
              </TabItem>
            </TabControl>
          </DockPanel>
        </TabItem>

        <!-- NETTOYAGE -->
        <TabItem>
          <DockPanel Margin="32,28,32,20">
            <StackPanel DockPanel.Dock="Top">
              <TextBlock Style="{StaticResource PageTitle}" Text="Nettoyage"/>
              <TextBlock Style="{StaticResource PageSub}" Text="Fichiers inutiles. Rien n'est supprimé sans confirmation."/>
              <Border Style="{StaticResource Card}" Margin="0,18,0,16">
                <DockPanel>
                  <Border Width="52" Height="52" CornerRadius="26" Background="#FFE7F8EE" DockPanel.Dock="Left" Margin="0,0,16,0">
                    <TextBlock Text="&#xEA99;" FontFamily="{StaticResource Icons}" FontSize="22" Foreground="#FF22C55E" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock x:Name="TxtCleanTotal" Text="…" FontSize="24" FontWeight="SemiBold"/>
                    <TextBlock Text="récupérables sans risque (hors Téléchargements et caches de navigateur)" Style="{StaticResource MutedText}"/>
                  </StackPanel>
                </DockPanel>
              </Border>
              <WrapPanel Margin="0,0,0,14">
                <Button x:Name="BtnCleanTemp" Content="Vider les fichiers temporaires" Margin="0,0,8,6"/>
                <Button x:Name="BtnEmptyBin" Content="Vider la corbeille" Margin="0,0,8,6"/>
                <Button x:Name="BtnCleanmgr" Content="Nettoyage de disque Windows" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                <Button x:Name="BtnStorageSettings" Content="Paramètres de stockage" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                <Button x:Name="BtnRefreshClean" Content="Recalculer" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
              </WrapPanel>
            </StackPanel>
            <Border Style="{StaticResource Panel}">
              <DataGrid x:Name="GridClean">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="EMPLACEMENT" Binding="{Binding Name}" Width="260">
                    <DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="FontWeight" Value="SemiBold"/></Style></DataGridTextColumn.ElementStyle>
                  </DataGridTextColumn>
                  <DataGridTextColumn Header="TAILLE" Binding="{Binding SizeText}" SortMemberPath="SizeBytes" Width="100"/>
                  <DataGridTextColumn Header="COMMENT LIBÉRER" Binding="{Binding Advice}" Width="*" ElementStyle="{StaticResource Wrap}"/>
                  <DataGridTextColumn Header="CHEMIN" Binding="{Binding Path}" Width="240"/>
                </DataGrid.Columns>
              </DataGrid>
            </Border>
          </DockPanel>
        </TabItem>
        <!-- PARAMETRES -->
        <TabItem>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="SettingsRoot" Margin="32,28,32,24" MaxWidth="900" HorizontalAlignment="Left">
              <TextBlock Style="{StaticResource PageTitle}" Text="Paramètres"/>
              <Border Style="{StaticResource Card}" Margin="0,18,0,14">
                <StackPanel>
                  <TextBlock Text="Apparence" FontSize="16" FontWeight="SemiBold"/>
                  <TextBlock x:Name="TxtThemeInfo" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,4,0,12"/>
                  <WrapPanel>
                    <Button x:Name="BtnThemeLight" Style="{StaticResource Secondary}" Margin="0,0,8,6">
                      <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE706;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Thème clair"/></StackPanel>
                    </Button>
                    <Button x:Name="BtnThemeDark" Style="{StaticResource Secondary}" Margin="0,0,8,6">
                      <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE708;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Thème sombre"/></StackPanel>
                    </Button>
                  </WrapPanel>
                  <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                    <TextBlock Text="Taille du texte :" VerticalAlignment="Center" Margin="0,0,10,0"/>
                    <ComboBox x:Name="CmbTextScale" Width="170" Padding="8,4">
                      <ComboBoxItem Content="Normale (100 %)"/>
                      <ComboBoxItem Content="Grande (115 %)"/>
                      <ComboBoxItem Content="Très grande (130 %)"/>
                    </ComboBox>
                  </StackPanel>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                <StackPanel>
                  <TextBlock Text="Widget de bureau" FontSize="16" FontWeight="SemiBold"/>
                  <TextBlock Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,4,0,10" Text="Une petite fenêtre qui affiche en direct l'utilisation et la température du processeur, de la carte graphique, de la RAM et du SSD. Déplacez-la à la souris, clic droit pour l'opacité et le premier plan."/>
                  <CheckBox x:Name="ChkWidgetAutostart" Content="Afficher le widget au démarrage de Windows"/>
                  <WrapPanel Margin="0,10,0,0">
                    <Button Tag="widget-open" Margin="0,0,8,6">
                      <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7C4;" FontFamily="{StaticResource Icons}" Margin="0,1,8,0"/><TextBlock Text="Ouvrir le widget"/></StackPanel>
                    </Button>
                  </WrapPanel>
                  <TextBlock Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap" Margin="0,6,0,0" Text="Température du processeur : Windows ne la fournit pas pour tous les processeurs. Le widget la lit automatiquement si Core Temp ou HWiNFO (option « Shared Memory Support ») est lancé. Température du SSD : ouvrez le widget depuis PC Doctor en mode administrateur."/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                <StackPanel>
                  <TextBlock Text="Mises à jour de PC Doctor" FontSize="16" FontWeight="SemiBold"/>
                  <TextBlock x:Name="TxtAppVersion" Style="{StaticResource MutedText}" Margin="0,4,0,4"/>
                  <TextBlock x:Name="TxtUpdateStatus" TextWrapping="Wrap" Margin="0,0,0,10"/>
                  <CheckBox x:Name="ChkCheckUpdates" Content="Vérifier les mises à jour à chaque démarrage"/>
                  <WrapPanel Margin="0,10,0,0">
                    <Button x:Name="BtnCheckUpdate" Content="Vérifier maintenant" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                    <Button x:Name="BtnInstallUpdate" Content="Installer la mise à jour" Margin="0,0,8,6" Visibility="Collapsed"/>
                    <Button Content="Page GitHub du projet" Tag="url:https://github.com/doninj/pc-doctor" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                  </WrapPanel>
                  <TextBlock Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap" Margin="0,6,0,0" Text="La vérification interroge uniquement github.com. Chaque mise à jour est contrôlée par son empreinte SHA-256 avant d'être installée."/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <DockPanel>
                  <Button x:Name="BtnOpenData" DockPanel.Dock="Right" Content="Ouvrir le dossier" Style="{StaticResource Secondary}" Margin="12,0,0,0" VerticalAlignment="Center"/>
                  <StackPanel>
                    <TextBlock Text="Données de PC Doctor" FontSize="16" FontWeight="SemiBold"/>
                    <TextBlock x:Name="TxtDataInfo" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,4,0,0"/>
                  </StackPanel>
                </DockPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </TabItem>
      </TabControl>

      <Border Grid.Row="1" Background="White" BorderBrush="#FFE6EAF0" BorderThickness="0,1,0,0" Padding="32,8">
        <DockPanel>
          <TextBlock x:Name="TxtVersion" DockPanel.Dock="Right" Style="{StaticResource MutedText}" FontSize="12" Text="PC Doctor 2.0"/>
          <TextBlock x:Name="TxtStatus" Style="{StaticResource MutedText}" FontSize="12" Text="Prêt." TextTrimming="CharacterEllipsis"/>
        </DockPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

# --- Thème sombre : palette claire -> palette sombre (appliquée au chargement de l'interface)
$script:DarkMap = [ordered]@{
    '#FFF4F6FA' = '#FF0E131D'; '#FF0F172A' = '#FFE6EAF2'; '#FF64748B' = '#FF97A3B6'; '#FF94A3B8' = '#FF7F8BA0'
    '#FF475569' = '#FFB3BDCC'; '#FF374151' = '#FFB3BDCC'
    '#FFE6EAF0' = '#FF262F41'; '#FFE2E8F0' = '#FF262F41'; '#FFD5DCE6' = '#FF323C50'
    '#FFF7F9FC' = '#FF1B2232'; '#FFF1F4F8' = '#FF1E2534'; '#FFEDF1F7' = '#FF2A3346'; '#FFE6EBF2' = '#FF1B2232'; '#FFF1F5F9' = '#FF2A3346'
    '#FFE8EFFE' = '#FF1D2A4A'; '#FFEFF4FF' = '#FF1D2A4A'; '#FFDBEAFE' = '#FF1D2A4A'
    '#FFFEECEC' = '#FF3A1E24'; '#FFFEF2F2' = '#FF2E1A1F'; '#FFFBCACA' = '#FF5B2A31'
    '#FFFFF4E0' = '#FF3A2E17'; '#FFFFF1DB' = '#FF3A2E17'; '#FFFFFBEB' = '#FF2E2614'
    '#FFE7F8EE' = '#FF16301F'; '#FFE3F7EA' = '#FF16301F'; '#FFF0FDF4' = '#FF14271B'
    '#FFC5CDD8' = '#FF3A4458'; '#FF15803D' = '#FF4ADE80'; '#FFB45309' = '#FFFBBF24'
}
$script:DarkCard = '#FF161C29'
$script:IsDark = ((Get-Settings)['Theme'] -eq 'dark')

function Convert-XamlTheme([string]$text) {
    if (-not $script:IsDark) { return $text }
    $text = [regex]::Replace($text, '(?<=Background=")White(?=")', $script:DarkCard)
    $text = [regex]::Replace($text, '(?<=Property="(Background|RowBackground)" Value=")White(?=")', $script:DarkCard)
    foreach ($k in $script:DarkMap.Keys) { $text = $text.Replace($k, $script:DarkMap[$k]) }
    $text
}

function New-PCDoctorWindow {
    [xml]$x = Convert-XamlTheme $xamlText
    $reader = New-Object System.Xml.XmlNodeReader $x
    $w = [Windows.Markup.XamlReader]::Load($reader)
    $map = @{}
    foreach ($m in [regex]::Matches($xamlText, 'x:Name="(\w+)"')) {
        $n = $m.Groups[1].Value
        $el = $w.FindName($n)
        if ($el) { $map[$n] = $el }
    }
    return @{ Window = $w; UI = $map }
}

$script:ExtCategories = @{}
foreach ($pair in @(
        @('Vidéo', '.mp4 .mkv .avi .mov .wmv .flv .webm .m4v .mpg .mpeg .ts .m2ts'),
        @('Image', '.jpg .jpeg .png .gif .bmp .tif .tiff .webp .heic .raw .cr2 .nef .arw .psd'),
        @('Audio', '.mp3 .wav .flac .aac .ogg .m4a .wma'),
        @('Archive', '.zip .rar .7z .tar .gz .cab'),
        @('Image disque / VM', '.iso .img .vhd .vhdx .vmdk .vdi .wim .esd .avhdx'),
        @('Programme / installeur', '.exe .msi .dll .msp .appx .msix'),
        @('Document', '.pdf .doc .docx .xls .xlsx .ppt .pptx .txt .odt .csv'),
        @('Données de jeu', '.pak .vpk .bundle .forge .bin .dat .ucas .utoc .sdc .arc .bsa .ba2 .rpf'),
        @('Système / journaux', '.sys .etl .log .dmp .evtx .db .edb')
    )) {
    foreach ($e in $pair[1].Split(' ')) { if (-not $script:ExtCategories.ContainsKey($e)) { $script:ExtCategories[$e] = $pair[0] } }
}
function Get-ExtCategory([string]$ext) { if ($script:ExtCategories.ContainsKey($ext)) { $script:ExtCategories[$ext] } else { 'Autre' } }

# --- Activer / désactiver un programme au démarrage (même méthode que le Gestionnaire des tâches)
function Set-StartupState($item, [bool]$enable) {
    if ($item.Kind -eq 'uwp') {
        Set-ItemProperty -LiteralPath $item.UwpKey -Name 'State' -Value $(if ($enable) { 2 } else { 1 }) -Type DWord -ErrorAction Stop
        return
    }
    if (-not (Test-Path -LiteralPath $item.ApprovedKey)) { New-Item -Path $item.ApprovedKey -Force -ErrorAction Stop | Out-Null }
    if ($enable) { $bytes = [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
    else { $bytes = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())) }
    New-ItemProperty -LiteralPath $item.ApprovedKey -Name $item.ValueName -Value $bytes -PropertyType Binary -Force -ErrorAction Stop | Out-Null
}

# ---------------------------------------------------------------------------
#  Mode test (sans interface)
# ---------------------------------------------------------------------------
if ($SelfTest) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $d = & ([scriptblock]::Create($script:FullJobCode))
    "Collecte : {0:N1} s" -f $sw.Elapsed.TotalSeconds
    "Carte mère : $($d.Summary.Board) · BIOS $($d.Summary.BiosVersion) $($d.Summary.BiosDate) · GPU $($d.Summary.MainGpu)"
    "--- Démarrage ($($d.Startup.Count)) ---"
    $d.Startup | ForEach-Object { "{0,-11} {1,-12} {2,-38} {3}" -f $_.State, $_.Advice, $_.DisplayName, $_.Where }
    "--- Constats ---"
    $f = @(Get-Findings $d)
    $f | ForEach-Object { "[{0}] {1}  -> {2}" -f $_.Severity, $_.Title, $_.ActionId }
    "Score : $(Get-HealthScore $f)"
    "--- Diagnostic plantages ---"
    Get-CrashDiagnosis $d
    "--- Solutions ---"
    Get-Solutions $d | ForEach-Object { "{0}. {1}{2}  [{3}]" -f $_.Num, $_.Title, $(if ($_.Recommended) { ' (recommandé)' } else { '' }), (($_.Actions | ForEach-Object { $_.Id }) -join ', ') }
    "--- Performances ---"
    "RAM : $($d.Memory.Count) x $(Format-Size $d.Memory.PerModule) $($d.Memory.Type) @ $($d.Memory.Configured) MT/s, kit $($d.Memory.Kit), part '$($d.Memory.Part)' -> $($d.Memory.XmpState)"
    "CPU : $($d.Cpu.Name) -> $($d.Cpu.Note)"
    "Outils OC : " + (($d.OcTools | ForEach-Object { "$($_.Name) running=$($_.Running)" }) -join '; ')
    "Démarrage rapide activé : $($d.FastStartup)"
    if ($d.Gpu) { "GPU live : {0} {1}°C {2}W / limite {3}W (défaut {4}W, min {5}, max {6}) {7}MHz fan {8} usage {9}% pilote {10}" -f $d.Gpu.Name, $d.Gpu.Temp, $d.Gpu.Power, $d.Gpu.PowerLimit, $d.Gpu.PowerDefault, $d.Gpu.PowerMin, $d.Gpu.PowerMax, $d.Gpu.Clock, $d.Gpu.Fan, $d.Gpu.Usage, $d.Gpu.Driver } else { 'GPU live : indisponible' }
    "--- Pilotes ---"
    "Périphériques en erreur : " + (($d.ProblemDevices | ForEach-Object { "$($_.Name) [$($_.Code) $($_.Problem)]" }) -join '; ')
    $kd = @(Get-KeyDrivers); "Pilotes fabricants : $($kd.Count), anciens : $(@($kd | Where-Object Old).Count)"
    $kd | Select-Object -First 6 | ForEach-Object { "  {0,-18} {1,-45} {2} {3}" -f $_.Category, $_.Device, $_.Version, $_.AgeText }
    $sw.Restart()
    try { $wu = @(Get-DriverUpdates); "Windows Update : $($wu.Count) pilote(s) dispo en {0:N0} s" -f $sw.Elapsed.TotalSeconds; $wu | ForEach-Object { "  - $($_.Title) [$($_.DriverClass)]" } } catch { "Windows Update : erreur $_" }
    "--- Bascule démarrage (clé de test) ---"
    $testKey = 'HKCU:\Software\PCDoctorSelfTest\StartupApproved\Run'
    $fake = [pscustomobject]@{ Kind = 'reg'; ApprovedKey = $testKey; ValueName = 'FakeApp' }
    Set-StartupState $fake $false
    $b1 = (Get-ItemProperty -LiteralPath $testKey).FakeApp
    Set-StartupState $fake $true
    $b2 = (Get-ItemProperty -LiteralPath $testKey).FakeApp
    "Désactivé -> octet {0} ({1} octets) ; Réactivé -> octet {2}" -f $b1[0], $b1.Length, $b2[0]
    $appr = Get-Item -LiteralPath $testKey
    "Lecture : désactivé=$(Test-Disabled $appr 'FakeApp')"
    Remove-Item -LiteralPath 'HKCU:\Software\PCDoctorSelfTest' -Recurse -Force
    "--- Disques ---"
    $d.Disks | ForEach-Object { "  $($_.Name) | $($_.Kind) | $($_.Health) | détails=$($_.HasDetails)" }
    "--- Boîte noire ---"
    $bbLines = [PCDoctor.BlackBox]::ReadRange($script:BlackBoxDir, (Get-Date).AddDays(-1), (Get-Date))
    "Lignes enregistrées (24 h) : $($bbLines.Count) ; active : $([PCDoctor.BlackBox]::IsRunning())"
    "--- Interface ---"
    $built = New-PCDoctorWindow
    "Fenêtre OK, $($built.UI.Count) éléments nommés"
    $script:IsDark = $true
    $builtDark = New-PCDoctorWindow
    "Fenêtre thème sombre OK, $($builtDark.UI.Count) éléments nommés"
    return
}

# ---------------------------------------------------------------------------
#  Application
# ---------------------------------------------------------------------------
try {
    $built = New-PCDoctorWindow
    $window = $built.Window
    $logo = Get-LogoPng
    if ($logo) { try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri $logo)) } catch {} }
    $script:ui = $built.UI
    $ui = $script:ui
    $script:Brush = New-Object System.Windows.Media.BrushConverter
    function Get-Brush([string]$hex) {
        if ($script:IsDark -and $script:DarkMap.Contains($hex)) { $hex = $script:DarkMap[$hex] }
        $script:Brush.ConvertFromString($hex)
    }

    $script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($script:IsAdmin) {
        $ui.TxtAdmin.Text = 'Mode administrateur'
        $ui.AdminDot.Fill = Get-Brush '#FF22C55E'
        $ui.TxtAdminHint.Text = 'Accès complet : tout peut être analysé et modifié.'
        $ui.BtnElevate.Visibility = 'Collapsed'
    }

    function Set-Status([string]$t) { $script:ui.TxtStatus.Text = $t }

    $script:Pages = @{ diag = 0; solutions = 1; blackbox = 2; stress = 3; security = 4; gaming = 5; drivers = 6; software = 7; perf = 8; network = 9; startup = 10; procs = 11; crashes = 12; disk = 13; clean = 14; settings = 15 }
    function Show-Page([string]$name) { if ($script:Pages.ContainsKey($name)) { $ui.NavList.SelectedIndex = $script:Pages[$name] } }
    $script:DriversLoaded = $false
    $script:SoftwareLoaded = $false
    $ui.NavList.Add_SelectionChanged({
            $i = $ui.NavList.SelectedIndex
            if ($i -lt 0) { return }
            $ui.Tabs.SelectedIndex = $i
            try {
                if ($i -eq $script:Pages['drivers'] -and -not $script:DriversLoaded) { Load-Drivers }
                if ($i -eq $script:Pages['software'] -and -not $script:SoftwareLoaded) { Start-SoftwareSearch }
                if ($i -eq $script:Pages['blackbox']) { Update-BlackBoxStatus; Show-BlackBoxCrashes }
                if ($i -eq $script:Pages['security'] -and -not $script:SecurityLoaded) { Load-Security }
                if ($i -eq $script:Pages['gaming']) { Show-Gaming }
            } catch { Write-Log "Navigation : $_ $($_.ScriptStackTrace)" }
        })
    $ui.NavList.SelectedIndex = 0

    # --- Tâches en arrière-plan -------------------------------------------
    $script:Jobs = New-Object System.Collections.ArrayList
    function Start-BgJob([string]$Code, [scriptblock]$OnDone) {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:CollectorsCode + "`n" + $Code)
        $h = $ps.BeginInvoke()
        [void]$script:Jobs.Add(@{ PS = $ps; RS = $rs; Handle = $h; OnDone = $OnDone })
    }

    # --- Lancements en administrateur ------------------------------------------
    # Règles : exécutables désignés par leur chemin complet dans System32, et code passé
    # directement en mémoire (-EncodedCommand) plutôt que via un fichier modifiable.
    function ConvertTo-EncodedCommand([string]$code) { [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)) }
    function Get-SysExe([string]$name) { Join-Path $script:Sys32 $name }

    function Start-AdminConsole([string]$cmd, [string]$title) {
        $full = "`$host.UI.RawUI.WindowTitle = '$title'; Write-Host 'PC Doctor - $title' -ForegroundColor Cyan; Write-Host 'Ne fermez pas cette fenetre avant la fin.' -ForegroundColor Yellow; $cmd; Write-Host ''; Write-Host 'Termine. Vous pouvez fermer cette fenetre.' -ForegroundColor Green"
        try { Start-Process -FilePath $script:PowerShellExe -Verb RunAs -ArgumentList @('-NoProfile', '-NoExit', '-EncodedCommand', (ConvertTo-EncodedCommand $full)) }
        catch { Set-Status 'Action annulée (droits administrateur refusés).' }
    }

    # Relance PC Doctor en administrateur. Le script est lu une seule fois, son empreinte SHA-256
    # est vérifiée par le processus administrateur, puis il est exécuté depuis la mémoire :
    # un programme qui modifierait le fichier entre-temps ne peut pas obtenir les droits admin.
    function Start-ElevatedSelf {
        # Depuis l'exe : on relance simplement l'exe en administrateur (il contient lui-même le script)
        if ($ExePath -and (Test-Path -LiteralPath $ExePath)) {
            Start-Process -FilePath $ExePath -Verb RunAs
            return
        }
        $path = $script:ScriptPath
        $bytes = [IO.File]::ReadAllBytes($path)
        $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', ''
        $p = $path -replace "'", "''"
        $boot = @"
`$p = '$p'
`$b = [IO.File]::ReadAllBytes(`$p)
`$h = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash(`$b)) -replace '-', ''
if (`$h -ne '$hash') { Add-Type -AssemblyName PresentationFramework; [void][System.Windows.MessageBox]::Show('Le fichier de PC Doctor a été modifié entre-temps : lancement en administrateur annulé par sécurité.', 'PC Doctor'); exit 1 }
`$s = [Text.Encoding]::UTF8.GetString(`$b).TrimStart([char]0xFEFF)
& ([scriptblock]::Create(`$s)) -LaunchedFrom `$p -ExePath '$([string]$ExePath -replace "'", "''")'
"@
        Start-Process -FilePath $script:PowerShellExe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-EncodedCommand', (ConvertTo-EncodedCommand $boot))
    }

    # --- Actions déclenchées par les boutons des constats / solutions -------
    function Invoke-Action([string]$id) {
        if (-not $id) { return }
        if ($id -like 'goto:*') { Show-Page $id.Substring(5); return }
        if ($id -like 'url:*') { Start-Process $id.Substring(4); return }
        if ($id -like 'ms-settings:*') { Start-Process $id; return }
        if ($id -like 'windowsdefender:*') { Start-Process $id; return }
        if ($id -like 'sec-disable-user:*') { Disable-LocalAccount $id.Substring(17); return }
        if ($id -like 'tweak:*') { $p = $id.Split(':'); Invoke-Tweak $p[1] ($p[2] -eq '1'); return }
        if ($id -like 'gpu-pl:*') { Set-GpuPowerLimit ([int]$id.Substring(7)); return }
        if ($id -like 'power:*') { Set-PowerPlan $id.Substring(6); return }
        switch ($id) {
            'gpu-update' { Open-GpuUpdater }
            'gpu-site' { Start-Process (Get-GpuDriverUrl) }
            'devmgmt' { Start-Process (Get-SysExe 'devmgmt.msc') }
            'chipset' { Start-Process 'https://www.amd.com/fr/support/download/drivers.html' }
            'fastboot-off' { Set-FastStartup $false }
            'fastboot-on' { Set-FastStartup $true }
            'widget-open' { Open-Widget }
            'uac' { Start-Process (Get-SysExe 'UserAccountControlSettings.exe') }
            'optionalfeatures' { Start-Process (Get-SysExe 'OptionalFeatures.exe') }
            'sec-hosts' { Start-Process (Join-Path $env:windir 'explorer.exe') -ArgumentList ('/select,"{0}"' -f (Join-Path $script:Sys32 'drivers\etc\hosts')) }
            'sec-quickscan' { Start-QuickScan }
            'powerplan-balanced' {
                [void](Invoke-Hidden (Get-SysExe 'powercfg.exe') '/setactive 381b4222-f694-41f0-9685-ff5bb260df2e')
                Set-Status 'Mode d''alimentation « Utilisation normale » activé.'; Show-Gaming
            }
            'bb-start' {
                Start-BlackBox
                Set-BlackBoxAutostart $true
                Set-Status 'Boîte noire activée : elle enregistre maintenant en continu et se relancera avec Windows.'
                $script:BbRefreshAt = [DateTime]::Now.AddSeconds(3)
            }
            'mdsched' { Start-Process (Get-SysExe 'mdsched.exe') }
            'reliability' { Start-Process (Get-SysExe 'perfmon.exe') -ArgumentList '/rel' }
            'sfc' { Start-AdminConsole ("& '{0}' /scannow; & '{1}' /Online /Cleanup-Image /RestoreHealth" -f (Get-SysExe 'sfc.exe'), (Get-SysExe 'Dism.exe')) 'Reparation de Windows' }
            'chkdsk' {
                $drive = [IO.Path]::GetPathRoot($script:Sys32).TrimEnd('\')
                Start-AdminConsole ("& '{0}' {1} /scan" -f (Get-SysExe 'chkdsk.exe'), $drive) 'Verification du disque'
            }
            'bios' {
                $r = [System.Windows.MessageBox]::Show("Le PC va redémarrer directement dans le BIOS dans 10 secondes.`n`nEnregistrez votre travail et fermez vos programmes avant de continuer.", 'Redémarrer dans le BIOS', 'OKCancel', 'Warning')
                if ($r -eq 'OK') {
                    try { Start-Process (Get-SysExe 'shutdown.exe') -Verb RunAs -ArgumentList '/r /fw /t 10' -WindowStyle Hidden }
                    catch { Set-Status 'Redémarrage annulé.' }
                }
            }
        }
    }
    $clickHandler = [System.Windows.RoutedEventHandler] {
        param($sender, $e)
        $b = $e.OriginalSource
        if ($b -is [System.Windows.Controls.Button] -and $b.Tag -is [string] -and $b.Tag -ne 'toggle-startup') {
            try { Invoke-Action $b.Tag } catch { Set-Status "Erreur : $_"; Write-Log "Action $($b.Tag) : $_" }
        }
    }
    $ui.ListFindings.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $clickHandler)
    $ui.ListSolutions.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $clickHandler)
    $ui.DriversRoot.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $clickHandler)
    $ui.ListSecurity.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $clickHandler)
    $ui.ListGaming.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $clickHandler)
    $ui.ListComfort.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $clickHandler)
    $ui.PerfRoot.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $clickHandler)

    function Refresh-Solutions {
        if (-not $script:LastData) { return }
        $sol = @(Get-Solutions $script:LastData)
        $ui.ListSolutions.ItemsSource = $sol
        Set-Badge $ui.BadgeSol $ui.BadgeSolText @($sol | Where-Object { $_.Recommended }).Count
    }

    # --- Carte graphique : pilote et limite de puissance ----------------------
    function Get-MainGpuName { if ($script:LastData -and $script:LastData.Summary) { [string]$script:LastData.Summary.MainGpu } else { '' } }
    function Get-GpuDriverUrl {
        $g = Get-MainGpuName
        if ($g -match 'NVIDIA') { 'https://www.nvidia.com/fr-fr/drivers/' }
        elseif ($g -match 'AMD|Radeon') { 'https://www.amd.com/fr/support/download/drivers.html' }
        else { 'https://www.intel.fr/content/www/fr/fr/support/intel-driver-support-assistant.html' }
    }
    function Open-GpuUpdater {
        $g = Get-MainGpuName
        $candidates = if ($g -match 'NVIDIA') {
            @("$env:ProgramFiles\NVIDIA Corporation\NVIDIA app\CEF\NVIDIA app.exe", "$env:ProgramFiles\NVIDIA Corporation\NVIDIA GeForce Experience\NVIDIA GeForce Experience.exe")
        } elseif ($g -match 'AMD|Radeon') {
            @("$env:ProgramFiles\AMD\CNext\CNext\RadeonSoftware.exe")
        } else { @() }
        $exe = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($exe) {
            Start-Process -FilePath $exe
            $where = if ($g -match 'NVIDIA') { "onglet « Pilotes » > « Télécharger » puis « Installer »" } else { "rubrique Pilotes / Mises à jour" }
            Set-Status "Outil du fabricant ouvert : $where. Choisissez l'installation propre / personnalisée si on vous la propose."
        } else {
            if ($g -match 'NVIDIA') { Start-Process 'https://www.nvidia.com/fr-fr/software/nvidia-app/'; Set-Status "Installez la NVIDIA app : elle met le pilote à jour en un clic à chaque nouvelle version." }
            else { Start-Process (Get-GpuDriverUrl); Set-Status 'Page de téléchargement du pilote ouverte dans votre navigateur.' }
        }
    }

    function Set-GpuPowerLimit([int]$pct) {
        $smi = Get-NvidiaSmi
        $g = Get-GpuLive
        if (-not $smi -or -not $g -or -not $g.PowerDefault) { [System.Windows.MessageBox]::Show("Ce réglage n'est possible que sur les cartes NVIDIA. Pour les autres, utilisez MSI Afterburner (curseur « Power Limit »).", 'Limite de puissance') | Out-Null; return }
        $w = [math]::Round($g.PowerDefault * $pct / 100)
        if ($g.PowerMin -and $w -lt $g.PowerMin) { $w = [math]::Ceiling($g.PowerMin) }
        if ($g.PowerMax -and $w -gt $g.PowerMax) { $w = [math]::Floor($g.PowerMax) }
        if ($pct -lt 100) {
            $r = [System.Windows.MessageBox]::Show(("Limiter « {0} » à {1:N0} W ({2} % de {3:N0} W) ?`n`nLa carte consommera moins lors des pics, avec environ 5 à 10 % de FPS en moins en jeu. Le réglage revient à 100 % au prochain redémarrage, ou avec le bouton « 100 % ».`n`nWindows va demander les droits administrateur." -f $g.Name, $w, $pct, $g.PowerDefault), 'Limite de puissance', 'YesNo', 'Question')
            if ($r -ne 'Yes') { return }
        }
        try { Start-Process -FilePath $smi -ArgumentList "-pl $w" -Verb RunAs -WindowStyle Hidden -Wait }
        catch { Set-Status 'Réglage annulé (droits administrateur refusés).'; return }
        $after = Get-GpuLive
        if ($after -and [math]::Abs($after.PowerLimit - $w) -le 2) {
            Set-Status ("Limite de puissance de la carte graphique : {0:N0} W ({1} %)." -f $after.PowerLimit, $pct)
            Update-GpuLive $after
        } else {
            [System.Windows.MessageBox]::Show("La carte n'a pas accepté ce réglage via le pilote NVIDIA.`n`nUtilisez MSI Afterburner : curseur « Power Limit » sur $pct %, puis « Apply ».", 'Limite de puissance', 'OK', 'Information') | Out-Null
        }
    }

    function Set-FastStartup([bool]$on) {
        $v = if ($on) { 1 } else { 0 }
        try { Start-Process (Get-SysExe 'reg.exe') -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList "add `"HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power`" /v HiberbootEnabled /t REG_DWORD /d $v /f" }
        catch { Set-Status 'Action annulée (droits administrateur refusés).'; return }
        $now = Get-FastStartup
        if ($script:LastData) { $script:LastData.FastStartup = $now }
        if ($now -eq $on) { Set-Status ("Démarrage rapide de Windows {0}." -f $(if ($on) { 'réactivé' } else { 'désactivé : chaque démarrage repart maintenant de zéro' })) }
        else { Set-Status "Le réglage du démarrage rapide n'a pas pu être modifié." }
        Refresh-Solutions
    }

    function Get-PowerPlanName {
        try { $t = (Invoke-Hidden (Get-Sys32Exe 'powercfg.exe') '/getactivescheme') -join ' '; if ($t -match '\(([^)]+)\)') { return $Matches[1] } } catch {}
        return 'Inconnu'
    }
    function Set-PowerPlan([string]$which) {
        $guid = if ($which -eq 'high') { '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' } else { '381b4222-f694-41f0-9685-ff5bb260df2e' }
        try { $null = Invoke-Hidden (Get-Sys32Exe 'powercfg.exe') "/setactive $guid" } catch {}
        $t = ''
        try { $t = (Invoke-Hidden (Get-Sys32Exe 'powercfg.exe') '/getactivescheme') -join ' ' } catch {}
        if ($t -match $guid) { Set-Status "Mode d'alimentation : $(Get-PowerPlanName)." }
        elseif ($which -eq 'high') { Set-Status "Le mode « Performances élevées » n'est pas disponible sur ce PC (Windows le masque parfois). Le mode Équilibré convient très bien." }
        else { Set-Status "Le mode d'alimentation n'a pas pu être changé." }
        $ui.TxtPowerPlan.Text = Get-PowerPlanName
    }

    # --- Page Pilotes ---------------------------------------------------------
    $script:WuItems = @()
    $script:WuCount = 0
    $script:DriverClassFr = @{ 'Display' = 'Carte graphique'; 'Net' = 'Réseau'; 'Media' = 'Audio'; 'System' = 'Système'; 'Bluetooth' = 'Bluetooth'; 'USB' = 'USB'; 'HIDClass' = 'Clavier / souris'; 'Firmware' = 'Firmware / BIOS'; 'Monitor' = 'Écran'; 'Printer' = 'Imprimante'; 'SCSIAdapter' = 'Stockage'; 'HDC' = 'Stockage'; 'Camera' = 'Caméra'; 'Image' = 'Caméra'; 'Extension' = 'Extension'; 'SoftwareComponent' = 'Composant logiciel' }

    function Update-DriversBadge {
        $probs = 0
        if ($script:LastData) { $probs = @($script:LastData.ProblemDevices | Where-Object { $_ -and $_.Serious }).Count }
        Set-Badge $ui.BadgeDrivers $ui.BadgeDriversText ($probs + $script:WuCount)
    }

    function Start-DriverSearch {
        $ui.BtnSearchDrivers.IsEnabled = $false
        $ui.BtnInstallDrivers.IsEnabled = $false
        $ui.WuBar.Visibility = 'Visible'; $ui.WuBar.IsIndeterminate = $true
        $ui.TxtWuStatus.Text = 'Recherche sur Windows Update… (de 30 secondes à 2 minutes)'
        Start-BgJob 'try { [pscustomobject]@{ Ok = $true; Items = @(Get-DriverUpdates); Error = $null } } catch { [pscustomobject]@{ Ok = $false; Items = @(); Error = "$_" } }' {
            param($res)
            $o = @($res)[0]
            $ui.WuBar.IsIndeterminate = $false; $ui.WuBar.Visibility = 'Collapsed'
            $ui.BtnSearchDrivers.IsEnabled = $true
            if (-not $o -or -not $o.Ok) { $ui.TxtWuStatus.Text = "Recherche impossible : $(if ($o) { $o.Error } else { 'erreur inconnue' }). Vérifiez la connexion Internet, ou utilisez Windows Update."; return }
            $items = @($o.Items | Where-Object { $_ } | ForEach-Object { $_.psobject.BaseObject })
            foreach ($i in $items) { if ($script:DriverClassFr.ContainsKey($i.DriverClass)) { $i.DriverClass = $script:DriverClassFr[$i.DriverClass] } }
            $script:WuItems = $items
            $script:WuCount = $items.Count
            $ui.GridWu.ItemsSource = $items
            if ($items.Count) {
                $ui.GridWu.Visibility = 'Visible'
                $ui.BtnInstallDrivers.IsEnabled = $true
                $ui.TxtWuStatus.Text = "$($items.Count) mise(s) à jour de pilote disponible(s). Décochez celles que vous ne voulez pas, puis cliquez sur « Installer la sélection »."
            } else {
                $ui.GridWu.Visibility = 'Collapsed'
                $ui.TxtWuStatus.Text = "Aucune mise à jour de pilote en attente sur Windows Update (vérifié à $(Get-Date -Format 'HH:mm')). Pour la carte graphique, utilisez le bouton « Mettre à jour le pilote » ci-dessus : les pilotes du fabricant sont plus récents."
            }
            Update-DriversBadge
        }
    }

    function Start-DriverInstall([string[]]$ids) {
        $tpl = @'
$host.UI.RawUI.WindowTitle = 'PC Doctor - Installation des pilotes'
$ids = @(__IDS__)
Write-Host 'PC Doctor - installation des pilotes (Windows Update)' -ForegroundColor Cyan
Write-Host 'Ne fermez pas cette fenetre. Cela peut prendre plusieurs minutes.' -ForegroundColor Yellow
try {
    $s = New-Object -ComObject Microsoft.Update.Session
    Write-Host ''; Write-Host 'Recherche des pilotes...'
    $r = $s.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $r.Updates) {
        if ($ids -contains $u.Identity.UpdateID) {
            if ($u.EulaAccepted) { [void]$coll.Add($u); Write-Host ('  - ' + $u.Title) }
            else { Write-Host ('  (ignore, a installer via Windows Update) ' + $u.Title) -ForegroundColor DarkGray }
        }
    }
    if ($coll.Count -eq 0) { Write-Host 'Rien a installer.' -ForegroundColor Green }
    else {
        Write-Host ''; Write-Host 'Telechargement...'
        $d = $s.CreateUpdateDownloader(); $d.Updates = $coll; [void]$d.Download()
        Write-Host 'Installation...'
        $i = $s.CreateUpdateInstaller(); $i.Updates = $coll; $res = $i.Install()
        Write-Host ''
        for ($k = 0; $k -lt $coll.Count; $k++) {
            $rc = $res.GetUpdateResult($k).ResultCode
            $txt = switch ($rc) { 2 { 'OK' } 3 { 'OK (avertissements)' } 4 { 'ECHEC' } 5 { 'Annule' } default { "Code $rc" } }
            $col = if ($rc -eq 2 -or $rc -eq 3) { 'Green' } else { 'Red' }
            Write-Host ('[{0}] {1}' -f $txt, $coll.Item($k).Title) -ForegroundColor $col
        }
        if ($res.RebootRequired) { Write-Host ''; Write-Host 'Redemarrez le PC pour terminer l''installation.' -ForegroundColor Yellow }
    }
} catch { Write-Host ('Erreur : ' + $_) -ForegroundColor Red }
Write-Host ''
Read-Host 'Appuyez sur Entree pour fermer'
'@
        $idList = ($ids | ForEach-Object { "'" + ($_ -replace "[^0-9a-fA-F-]", '') + "'" }) -join ','
        # Passé en mémoire (pas de fichier sur le disque qu'un autre programme pourrait modifier)
        $encoded = ConvertTo-EncodedCommand ($tpl.Replace('__IDS__', $idList))
        try {
            Start-Process -FilePath $script:PowerShellExe -Verb RunAs -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded)
            $ui.TxtWuStatus.Text = 'Installation lancée dans la fenêtre administrateur (progression affichée dedans). Quand elle est terminée, cliquez sur « Rechercher » pour vérifier.'
        } catch { Set-Status 'Installation annulée (droits administrateur refusés).' }
    }

    function Load-Drivers {
        $script:DriversLoaded = $true
        $ui.TxtDrivers.Text = 'Lecture des pilotes installés…'
        Start-BgJob '@(Get-KeyDrivers)' {
            param($res)
            $items = @($res | Where-Object { $_ })
            $ui.GridDrivers.ItemsSource = $items
            $old = @($items | Where-Object { $_.Old }).Count
            $ui.TxtDrivers.Text = "$($items.Count) pilotes de fabricants (carte graphique, réseau, audio, chipset…)." + $(if ($old) { " $old ont plus de 3 ans (en rouge) : regardez s'il existe une version plus récente sur le site du fabricant." } else { ' Aucun n''est vraiment ancien.' })
        }
        Start-DriverSearch
    }

    function Show-DriversInfo($d) {
        $g = Get-MainGpuName
        $ui.TxtGpuDrvName.Text = if ($g) { $g } else { 'Carte graphique' }
        $gi = $d.Summary.Gpus | Where-Object { $_.Name -eq $g } | Select-Object -First 1
        $ver = if ($d.Gpu -and $d.Gpu.Driver) { $d.Gpu.Driver } elseif ($gi) { $gi.DriverVersion } else { '?' }
        $txt = "Pilote installé : $ver"
        if ($gi -and $gi.DriverDate) {
            $months = [int](((Get-Date) - $gi.DriverDate).TotalDays / 30.4)
            $txt += "  ·  publié le $($gi.DriverDate.ToString('dd/MM/yyyy'))"
            $txt += if ($months -le 2) { '  ·  récent' } elseif ($months -le 6) { "  ·  il y a $months mois" } else { "  ·  il y a $months mois : une mise à jour est conseillée" }
        }
        $ui.TxtGpuDrvVersion.Text = $txt
        if ($d.Summary.CpuName -match 'AMD|Ryzen') { $ui.BtnChipset.Visibility = 'Visible' }

        $probs = @($d.ProblemDevices | Where-Object { $_ })
        $ui.GridProblems.ItemsSource = $probs
        if ($probs.Count) {
            $ui.GridProblems.Visibility = 'Visible'
            $serious = @($probs | Where-Object { $_.Serious }).Count
            $ui.TxtProblems.Text = if ($serious) { "$serious périphérique(s) ne fonctionnent pas correctement. Ouvrez le Gestionnaire de périphériques, clic droit sur l'appareil > « Mettre à jour le pilote », ou installez le pilote du fabricant." } else { "Seulement des périphériques désactivés volontairement : rien d'inquiétant." }
        } else { $ui.GridProblems.Visibility = 'Collapsed'; $ui.TxtProblems.Text = 'Aucun : tous les périphériques fonctionnent correctement.' }
        Update-DriversBadge
    }

    # --- Page Performances ----------------------------------------------------
    $script:SmiPath = Get-NvidiaSmi
    $script:GpuProc = $null; $script:GpuTask = $null; $script:GpuNextPoll = [DateTime]::MinValue
    $script:GpuMaxTemp = 0.0; $script:GpuMaxPower = 0.0

    function Update-GpuLive($g) {
        if (-not $g) { return }
        $ui.LivePill.Visibility = 'Visible'
        $ui.TxtGpuName.Text = $g.Name
        if ($null -ne $g.Temp) {
            if ($g.Temp -gt $script:GpuMaxTemp) { $script:GpuMaxTemp = $g.Temp }
            $ui.TxtGpuTemp.Text = "{0:N0} °C" -f $g.Temp
            Set-Bar $ui.BarGpuTemp $g.Temp 75 85
            $ui.TxtGpuTempMax.Text = "max {0:N0} °C" -f $script:GpuMaxTemp
        }
        if ($null -ne $g.Power) {
            if ($g.Power -gt $script:GpuMaxPower) { $script:GpuMaxPower = $g.Power }
            $ui.TxtGpuPower.Text = "{0:N0} W" -f $g.Power
            $p = if ($g.PowerLimit) { 100 * $g.Power / $g.PowerLimit } else { 0 }
            Set-Bar $ui.BarGpuPower $p 90 98
            $ui.TxtGpuPowerSub.Text = "max {0:N0} W  ·  limite {1:N0} W" -f $script:GpuMaxPower, $g.PowerLimit
        }
        if ($null -ne $g.Clock) {
            if ($g.ClockMax) { $ui.BarGpuClock.Maximum = $g.ClockMax }
            $ui.TxtGpuClock.Text = "{0:N0} MHz" -f $g.Clock
            Set-Bar $ui.BarGpuClock $g.Clock 1e9 1e9
            $ui.TxtGpuClockSub.Text = if ($g.ClockMax) { "maximum {0:N0} MHz" -f $g.ClockMax } else { '' }
        }
        if ($null -ne $g.Usage) {
            $ui.TxtGpuUsage.Text = "{0:N0} %" -f $g.Usage
            Set-Bar $ui.BarGpuUsage $g.Usage 1e9 1e9
        }
        $ui.TxtGpuFan.Text = if ($null -ne $g.Fan) { "ventilateurs à {0:N0} %" -f $g.Fan } else { 'ventilateurs : —' }
        if ($g.PowerDefault) {
            $pct = 100 * $g.PowerLimit / $g.PowerDefault
            $ui.TxtGpuLimit.Text = "Actuelle : {0:N0} W ({1:N0} %)." -f $g.PowerLimit, $pct
        }
    }

    function Step-GpuPoll {
        if (-not $script:SmiPath) { return }
        if ($script:GpuTask) {
            if (-not $script:GpuTask.IsCompleted) { return }
            $txt = $null
            try { $txt = $script:GpuTask.Result } catch {}
            try { $script:GpuProc.Dispose() } catch {}
            $script:GpuTask = $null; $script:GpuProc = $null
            if ($txt) { $g = ConvertFrom-SmiLine (($txt -split "`r?`n")[0]); if ($g) { Update-GpuLive $g } }
            return
        }
        if ([DateTime]::Now -lt $script:GpuNextPoll) { return }
        $script:GpuNextPoll = [DateTime]::Now.AddSeconds(3)
        try {
            $psi = New-Object Diagnostics.ProcessStartInfo($script:SmiPath, $SmiQuery)
            $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
            $script:GpuProc = [Diagnostics.Process]::Start($psi)
            $script:GpuTask = $script:GpuProc.StandardOutput.ReadToEndAsync()
        } catch { $script:SmiPath = $null }
    }

    function Show-Perf($d) {
        if ($d.Gpu) { Update-GpuLive $d.Gpu }
        else {
            $ui.TxtGpuName.Text = if ($d.Summary.MainGpu) { $d.Summary.MainGpu } else { 'Carte graphique' }
            $ui.TxtGpuNA.Visibility = 'Visible'; $ui.GpuStats.Visibility = 'Collapsed'; $ui.GpuLimitBox.Visibility = 'Collapsed'
        }
        $m = $d.Memory
        if ($m) {
            $ui.TxtRamTitle.Text = "{0} × {1} {2}  ·  {3:N0} MT/s" -f $m.Count, (Format-Size $m.PerModule), $m.Type, $m.Configured
            $ui.TxtRamDetail.Text = "$(Format-Size $m.Total) au total" + $(if ($m.Kit) { "  ·  kit prévu pour $($m.Kit) MT/s" } else { '' }) + $(if ($m.Part) { "  ·  $($m.Maker) $($m.Part)".TrimEnd() } else { '' })
            switch ($m.XmpState) {
                'On' { $ui.RamPillText.Text = 'EXPO / XMP activé'; $ui.RamPill.Background = Get-Brush '#FFFFF1DB'; $ui.RamPillText.Foreground = Get-Brush '#FFB45309' }
                'Off' { $ui.RamPillText.Text = 'EXPO / XMP désactivé'; $ui.RamPill.Background = Get-Brush '#FFE3F7EA'; $ui.RamPillText.Foreground = Get-Brush '#FF15803D' }
                default { $ui.RamPillText.Text = 'Vitesse standard'; $ui.RamPill.Background = Get-Brush '#FFE8EFFE'; $ui.RamPillText.Foreground = Get-Brush '#FF3B6EF5' }
            }
            $adv = $m.XmpText
            if ($m.XmpState -eq 'On' -and @($d.Crashes | Where-Object { $_ -and $_.Category -eq 'Arrêt brutal' }).Count) { $adv += " Si le test de stabilité trouve des erreurs mémoire, désactivez-le." }
            $ui.TxtRamAdvice.Text = $adv
        }
        $c = $d.Cpu
        if ($c) {
            $ui.TxtCpuOcName.Text = $c.Name
            $ui.TxtCpuOcDetail.Text = "{0} cœurs / {1} threads  ·  {2:N0} MHz de base" -f $c.Cores, $c.Threads, $c.MaxClock
            $ui.TxtCpuOcNote.Text = $c.Note
        }
        $oc = @($d.OcTools | Where-Object { $_ })
        if ($oc.Count) {
            $ui.TxtOcTools.Text = ($oc | ForEach-Object { "$($_.Name)$(if ($_.Running) { ' (actif)' } else { ' (installé)' })" }) -join ', '
            $ui.TxtOcToolsAdvice.Text = "En cas d'instabilité : « Reset » dans le logiciel, et ne plus appliquer ses réglages au démarrage."
        } else {
            $ui.TxtOcTools.Text = 'Aucun détecté'
            $ui.TxtOcToolsAdvice.Text = "Pas d'overclocking logiciel sur ce PC."
        }
        $ui.TxtPowerPlan.Text = if ($d.Summary.PowerPlanName) { $d.Summary.PowerPlanName } else { Get-PowerPlanName }
        $disks = @($d.Disks | Where-Object { $_ })
        $ui.ListDisks.ItemsSource = $disks
        $ui.TxtDiskHealthNote.Visibility = if ($disks.Count -and -not @($disks | Where-Object { $_.HasDetails }).Count -and -not $script:IsAdmin) { 'Visible' } else { 'Collapsed' }
    }
    $ui.BtnGoSolutions.Add_Click({ Show-Page 'solutions' })

    # --- Affichage ----------------------------------------------------------
    function Set-Badge($border, $text, [int]$n) {
        if ($n -gt 0) { $text.Text = [string]$n; $border.Visibility = 'Visible' } else { $border.Visibility = 'Collapsed' }
    }

    function Set-Score([int]$score) {
        $angle = [math]::Min(359.9, [math]::Max(0.5, 3.6 * $score))
        $r = 57.0; $cx = 65.0; $cy = 65.0
        $rad = $angle * [math]::PI / 180
        $x = $cx + $r * [math]::Sin($rad); $y = $cy - $r * [math]::Cos($rad)
        $large = if ($angle -gt 180) { 1 } else { 0 }
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $ui.ScoreArc.Data = [System.Windows.Media.Geometry]::Parse([string]::Format($inv, 'M {0},{1} A {2},{2} 0 {3} 1 {4},{5}', $cx, ($cy - $r), $r, $large, $x, $y))
        $color = if ($score -ge 80) { '#FF22C55E' } elseif ($score -ge 55) { '#FFF59E0B' } else { '#FFEF4444' }
        $ui.ScoreArc.Stroke = Get-Brush $color
        $ui.ScoreText.Text = [string]$score
        $ui.ScoreLabel.Text = if ($score -ge 80) { 'Bon état' } elseif ($score -ge 55) { 'À surveiller' } else { 'Problèmes à régler' }
        $ui.ScoreLabel.Foreground = Get-Brush $color
    }

    function Set-Bar($bar, [double]$value, [double]$warn, [double]$crit) {
        $bar.Value = $value
        $bar.Foreground = Get-Brush $(if ($value -ge $crit) { '#FFEF4444' } elseif ($value -ge $warn) { '#FFF59E0B' } else { '#FF3B6EF5' })
    }

    function Show-All($d) {
        $s = $d.Summary
        if ($s) {
            $ui.TxtSysInfo.Text = "{0}  ·  {1}  ·  {2} de RAM  ·  {3}" -f $s.CpuName, $(if ($s.MainGpu) { $s.MainGpu } else { 'GPU inconnu' }), (Format-Size $s.RamTotal), $s.OSName
            $ui.CardCpu.Text = "$($s.CpuLoad) %"
            Set-Bar $ui.BarCpu $s.CpuLoad 70 90
            $ui.CardCpuSub.Text = "$($s.Cores) cœurs  ·  $($s.ProcessCount) processus"
            $ui.CardRam.Text = "$($s.RamUsedPct) %"
            Set-Bar $ui.BarRam $s.RamUsedPct 80 90
            $ui.CardRamSub.Text = "{0} utilisés sur {1}" -f (Format-Size ($s.RamTotal - $s.RamFree)), (Format-Size $s.RamTotal)
            $sys = $s.Drives | Where-Object { $_.Drive -eq $env:SystemDrive } | Select-Object -First 1
            if ($sys) {
                $ui.CardDiskTitle.Text = "Disque $($sys.Drive)$(if ($s.SystemDiskMedia) { " · $($s.SystemDiskMedia)" })"
                $ui.CardDisk.Text = "$([math]::Round($sys.UsedPct)) %"
                Set-Bar $ui.BarDisk $sys.UsedPct 88 95
                $ui.CardDiskSub.Text = "{0} libres sur {1}" -f (Format-Size $sys.Free), (Format-Size $sys.Size)
            }
            $days = [math]::Floor($s.Uptime.TotalDays)
            $ui.CardUptime.Text = if ($days -ge 1) { "{0} j {1} h" -f $days, $s.Uptime.Hours } else { "{0} h {1:00}" -f $s.Uptime.Hours, $s.Uptime.Minutes }
            Set-Bar $ui.BarUptime ([math]::Min(14, $s.Uptime.TotalDays)) 7 13
            $ui.CardUptimeSub.Text = "Démarré le " + $s.BootTime.ToString('dd/MM à HH:mm')
        }
        Show-Processes $d.Processes
        Show-Startup $d.Startup
        Show-Crashes $d.Crashes
        Show-Clean $d.Cleanable

        $findings = @(Get-Findings $d)
        $ui.ListFindings.ItemsSource = $findings
        $score = Get-HealthScore $findings
        Set-Score $score
        $crit = @($findings | Where-Object { $_.Severity -eq 'Critique' }).Count
        $warn = @($findings | Where-Object { $_.Severity -eq 'Attention' }).Count
        $ui.ScoreSub.Text = if ($crit + $warn -eq 0) { 'Rien d''important à signaler' } else { "$crit problème(s) important(s), $warn point(s) à surveiller" }

        $ui.TxtDiagnosis.Text = Get-CrashDiagnosis $d
        $script:LastData = $d
        Refresh-Solutions
        try { Show-Perf $d } catch { Write-Log "Perf : $_ $($_.ScriptStackTrace)" }
        try { Show-DriversInfo $d } catch { Write-Log "Pilotes : $_ $($_.ScriptStackTrace)" }
    }

    function Show-Processes($p) { $ui.GridProcs.ItemsSource = @($p | Where-Object { $_ }) }

    function Show-Startup($items) {
        $items = @($items | Where-Object { $_ })
        $script:StartupItems = $items
        $ui.GridStartup.ItemsSource = $items
        $on = @($items | Where-Object { $_.Enabled })
        $rec = @($on | Where-Object { $_.Advice -eq 'Désactivable' })
        $ui.TxtStartupInfo.Text = "$($on.Count) programme(s) se lancent avec Windows, dont $($rec.Count) qu'on peut désactiver sans souci. Désactiver ne désinstalle rien : le programme reste utilisable quand vous l'ouvrez, il ne se lance juste plus tout seul. Effet au prochain démarrage."
        $ui.TxtDisableRecommended.Text = if ($rec.Count) { "Désactiver les $($rec.Count) programmes conseillés" } else { 'Rien de plus à désactiver' }
        $ui.BtnDisableRecommended.IsEnabled = ($rec.Count -gt 0)
        Set-Badge $ui.BadgeStartup $ui.BadgeStartupText $rec.Count
    }

    function Reload-Startup {
        try { Show-Startup @(Get-StartupItems) } catch { Set-Status "Erreur de lecture du démarrage : $_" }
    }

    function Show-Crashes($c) {
        $c = @($c | Where-Object { $_ })
        $ui.GridCrashes.ItemsSource = $c
        if ($c.Count -eq 0) { $ui.ListCrashStats.ItemsSource = @([pscustomobject]@{ Count = '0'; Name = 'plantage en 30 jours' }) }
        else { $ui.ListCrashStats.ItemsSource = @($c | Group-Object Category | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Count = [string]$_.Count; Name = $_.Name } }) }
        Set-Badge $ui.BadgeCrash $ui.BadgeCrashText @($c | Where-Object { $_.Category -in @('Arrêt brutal', 'Écran bleu (BSOD)') }).Count
    }

    function Show-Clean($items) {
        $items = @($items | Where-Object { $_ })
        $ui.GridClean.ItemsSource = $items
        $total = [double]($items | Where-Object { $_.Reclaimable } | Measure-Object SizeBytes -Sum).Sum
        $ui.TxtCleanTotal.Text = Format-Size $total
    }

    function Start-FullAnalysis {
        $ui.BtnAnalyze.IsEnabled = $false
        Set-Status 'Analyse du PC en cours… (10 à 30 secondes)'
        $ui.ListFindings.ItemsSource = @([pscustomobject]@{ Severity = 'Info'; Title = 'Analyse en cours…'; Advice = 'Lecture des infos système, des programmes ouverts, des journaux de plantage et de l''espace récupérable.'; ActionLabel = $null; ActionId = $null })
        Start-BgJob $script:FullJobCode {
            param($res)
            $d = @($res)[0]
            $script:LastData = $d
            Show-All $d
            $ui.BtnAnalyze.IsEnabled = $true
            Set-Status ("Analyse terminée à {0:HH:mm}." -f (Get-Date))
        }
    }

    function Refresh-Clean {
        Set-Status 'Calcul de l''espace récupérable…'
        Start-BgJob 'Get-CleanableItems' { param($res) Show-Clean @($res); Set-Status 'Espace récupérable recalculé.' }
    }

    # --- Démarrage : activer / désactiver -----------------------------------
    function Invoke-StartupToggle($item, [bool]$enable) {
        try {
            Set-StartupState $item $enable
            return $true
        } catch {
            Write-Log "Démarrage $($item.Name) : $_"
            if ($item.AllUsers -and -not $script:IsAdmin) {
                [System.Windows.MessageBox]::Show("« $($item.DisplayName) » est réglé pour tous les comptes du PC : il faut les droits administrateur pour le modifier.`n`nCliquez sur « Passer en administrateur » en bas à gauche, puis réessayez.", 'Droits administrateur nécessaires', 'OK', 'Information') | Out-Null
            } else { Set-Status "Impossible de modifier « $($item.DisplayName) » : $($_.Exception.Message)" }
            return $false
        }
    }

    $ui.GridStartup.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
            param($sender, $e)
            $b = $e.OriginalSource
            if (-not ($b -is [System.Windows.Controls.Button]) -or $b.Tag -ne 'toggle-startup') { return }
            $item = $b.DataContext
            if (-not $item) { return }
            $enable = -not $item.Enabled
            if (-not $enable -and $item.Advice -eq 'À garder') {
                $r = [System.Windows.MessageBox]::Show("PC Doctor conseille de garder « $($item.DisplayName) » au démarrage :`n$($item.AdviceText)`n`nLe désactiver quand même ?", 'Programme important', 'YesNo', 'Warning')
                if ($r -ne 'Yes') { return }
            }
            if (Invoke-StartupToggle $item $enable) {
                Set-Status ("« {0} » {1} au démarrage. Effet au prochain redémarrage." -f $item.DisplayName, $(if ($enable) { 'réactivé' } else { 'désactivé' }))
                Reload-Startup
            }
        })

    $ui.BtnDisableRecommended.Add_Click({
            $rec = @($script:StartupItems | Where-Object { $_.Enabled -and $_.Advice -eq 'Désactivable' })
            if (-not $rec.Count) { return }
            $names = ($rec | ForEach-Object { "• $($_.DisplayName)" }) -join "`n"
            $r = [System.Windows.MessageBox]::Show("Ces programmes ne se lanceront plus automatiquement avec Windows :`n`n$names`n`nIls restent installés et utilisables. Vous pourrez les réactiver ici à tout moment.", 'Désactiver au démarrage', 'YesNo', 'Question')
            if ($r -ne 'Yes') { return }
            $ok = 0; $ko = 0
            foreach ($it in $rec) { try { Set-StartupState $it $false; $ok++ } catch { $ko++; Write-Log "Démarrage $($it.Name) : $_" } }
            $msg = "$ok programme(s) désactivé(s) au démarrage."
            if ($ko) { $msg += " $ko n'ont pas pu l'être (réglés pour tous les comptes) : passez en administrateur pour les désactiver." }
            Set-Status $msg
            Reload-Startup
        })
    $ui.BtnRefreshStartup.Add_Click({ Reload-Startup; Set-Status 'Liste du démarrage actualisée.' })
    $ui.BtnStartupTaskmgr.Add_Click({ Start-Process (Get-SysExe 'taskmgr.exe') -ArgumentList '/0 /startup' })

    # --- Espace disque ----------------------------------------------------
    $script:ScanTargets = New-Object System.Collections.ArrayList
    foreach ($dr in [IO.DriveInfo]::GetDrives()) {
        if ($dr.DriveType -ne 'Fixed' -or -not $dr.IsReady) { continue }
        $label = "{0}  {1} — {2} libres sur {3}" -f $dr.Name, $(if ($dr.VolumeLabel) { "($($dr.VolumeLabel))" } else { '' }), (Format-Size $dr.AvailableFreeSpace), (Format-Size $dr.TotalSize)
        [void]$ui.CmbDrives.Items.Add($label)
        [void]$script:ScanTargets.Add($dr.Name)
    }
    if ($ui.CmbDrives.Items.Count) { $ui.CmbDrives.SelectedIndex = 0 }

    $script:ScanActive = $false
    $script:CurrentNode = $null

    function Show-Node($node) {
        if (-not $node) { return }
        $script:CurrentNode = $node
        $ui.TxtCurrentPath.Text = "{0}     ·  {1}  ·  {2:N0} fichiers" -f $node.FullPath, (Format-Size $node.Size), $node.Files
        $total = [math]::Max([double]$node.Size, 1)
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($c in $node.Children) {
            $pct = 100 * $c.Size / $total
            $rows.Add([pscustomobject]@{
                    Name = $c.Name + $(if ($c.Denied) { '   (accès refusé)' } else { '' })
                    SizeBytes = [double]$c.Size; SizeText = (Format-Size $c.Size)
                    Pct = $pct; PctText = ('{0:N1} %' -f $pct)
                    FilesNum = $c.Files; FilesText = ('{0:N0}' -f $c.Files); Node = $c
                })
        }
        if ($node.OwnFilesSize -gt 0) {
            $pct = 100 * $node.OwnFilesSize / $total
            $rows.Add([pscustomobject]@{ Name = 'Fichiers posés directement ici'; SizeBytes = [double]$node.OwnFilesSize; SizeText = (Format-Size $node.OwnFilesSize); Pct = $pct; PctText = ('{0:N1} %' -f $pct); FilesNum = 0; FilesText = ''; Node = $null })
        }
        $ui.GridFolders.ItemsSource = @($rows | Sort-Object SizeBytes -Descending)
        $ui.BtnUp.IsEnabled = ($null -ne $node.Parent)
        $ui.BtnOpenFolder.IsEnabled = $true
    }

    function Complete-Scan {
        $ui.BtnScan.IsEnabled = $true
        $ui.BtnCancelScan.IsEnabled = $false
        $ui.ScanBar.IsIndeterminate = $false
        $err = [PCDoctor.DiskScanner]::Error
        $root = [PCDoctor.DiskScanner]::Root
        if ($err -or -not $root) { $ui.TxtScanProgress.Text = "Échec de l'analyse : $err"; return }
        $secs = ((Get-Date) - $script:ScanStart).TotalSeconds
        $denied = [PCDoctor.DiskScanner]::DeniedCount
        $msg = "Terminé : {0:N0} fichiers, {1}, en {2:N0} s." -f $root.Files, (Format-Size $root.Size), $secs
        if ([PCDoctor.DiskScanner]::Cancel) { $msg = "Arrêté (résultats partiels) : {0:N0} fichiers, {1}." -f $root.Files, (Format-Size $root.Size) }
        if ($denied -gt 0 -and -not $script:IsAdmin) { $msg += " $denied dossier(s) protégé(s) non lus : passez en administrateur pour tout voir." }
        $ui.TxtScanProgress.Text = $msg
        Set-Status $msg
        Show-Node $root

        $files = foreach ($f in [PCDoctor.DiskScanner]::TopFiles) {
            $dot = $f.Name.LastIndexOf('.')
            $ext = if ($dot -gt 0) { $f.Name.Substring($dot).ToLower() } else { '' }
            [pscustomobject]@{ Name = $f.Name; FullPath = $f.FullPath; Folder = $f.Folder; SizeBytes = [double]$f.Size; SizeText = (Format-Size $f.Size); Category = (Get-ExtCategory $ext); Modified = $f.Modified; ModifiedText = $f.Modified.ToString('dd/MM/yyyy') }
        }
        $ui.GridFiles.ItemsSource = @($files)

        $tot = [math]::Max([double]$root.Size, 1)
        $exts = foreach ($e in ([PCDoctor.DiskScanner]::Extensions | Select-Object -First 300)) {
            [pscustomobject]@{ Ext = $e.Ext; Category = (Get-ExtCategory $e.Ext); SizeBytes = [double]$e.Size; SizeText = (Format-Size $e.Size); PctText = ('{0:N1} %' -f (100 * $e.Size / $tot)); Count = $e.Count; CountText = ('{0:N0}' -f $e.Count) }
        }
        $ui.GridExt.ItemsSource = @($exts)
    }

    function Update-ScanProgress {
        if (-not $script:ScanActive) { return }
        if ([PCDoctor.DiskScanner]::Running) {
            $p = [PCDoctor.DiskScanner]::CurrentPath
            if ($p -and $p.Length -gt 70) { $p = '…' + $p.Substring($p.Length - 70) }
            $ui.TxtScanProgress.Text = "Analyse… {0:N0} fichiers · {1} · {2}" -f [PCDoctor.DiskScanner]::FilesScanned, (Format-Size ([PCDoctor.DiskScanner]::BytesScanned)), $p
        } else {
            $script:ScanActive = $false
            Complete-Scan
        }
    }

    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:Timer.Add_Tick({
            foreach ($j in @($script:Jobs)) {
                if (-not $j.Handle.IsCompleted) { continue }
                $script:Jobs.Remove($j)
                $res = $null
                try { $res = $j.PS.EndInvoke($j.Handle) } catch { Write-Log "Tâche : $_" }
                foreach ($e in $j.PS.Streams.Error) { Write-Log $e.ToString() }
                $j.PS.Dispose(); $j.RS.Close(); $j.RS.Dispose()
                try { & $j.OnDone $res } catch { Write-Log "Affichage : $_ $($_.ScriptStackTrace)"; Set-Status "Erreur : $_" }
            }
            try { Update-ScanProgress } catch { Write-Log "Scan : $_" }
            try { Step-GpuPoll } catch { Write-Log "GPU : $_" }
            if (($script:StressWasRunning -or [PCDoctor.StressTest]::Running) -and [DateTime]::Now -ge $script:StressNextUi) {
                $script:StressNextUi = [DateTime]::Now.AddSeconds(1)
                try {
                    Update-StressUi
                    if ($script:StressWasRunning -and -not [PCDoctor.StressTest]::Running) { $script:StressWasRunning = $false; Complete-StressTest }
                } catch { Write-Log "Test : $_ $($_.ScriptStackTrace)" }
            }
            if ($script:BbRefreshAt -and [DateTime]::Now -ge $script:BbRefreshAt) {
                $script:BbRefreshAt = $null
                try { Update-BlackBoxStatus; Refresh-Solutions } catch { Write-Log "Boîte noire : $_" }
            }
        })

    # --- Boutons ----------------------------------------------------------
    $ui.BtnAnalyze.Add_Click({ Start-FullAnalysis })

    $ui.BtnElevate.Add_Click({
            try {
                Start-ElevatedSelf
                $window.Close()
            } catch { Set-Status 'Passage en administrateur annulé.' }
        })

    $ui.BtnRefreshProc.Add_Click({
            $ui.BtnRefreshProc.IsEnabled = $false
            Set-Status 'Mesure de l''activité des programmes…'
            Start-BgJob 'Get-ProcessUsage' { param($res) Show-Processes @($res); $ui.BtnRefreshProc.IsEnabled = $true; Set-Status ("Processus actualisés à {0:HH:mm:ss}." -f (Get-Date)) }
        })
    $ui.BtnTaskmgr.Add_Click({ Start-Process (Get-SysExe 'taskmgr.exe') })

    $ui.BtnChooseFolder.Add_Click({
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Choisissez le dossier à analyser'
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                [void]$ui.CmbDrives.Items.Add("Dossier : " + $dlg.SelectedPath)
                [void]$script:ScanTargets.Add($dlg.SelectedPath)
                $ui.CmbDrives.SelectedIndex = $ui.CmbDrives.Items.Count - 1
            }
        })

    $ui.BtnScan.Add_Click({
            $i = $ui.CmbDrives.SelectedIndex
            if ($i -lt 0) { return }
            $target = $script:ScanTargets[$i]
            $ui.BtnScan.IsEnabled = $false
            $ui.BtnCancelScan.IsEnabled = $true
            $ui.ScanBar.IsIndeterminate = $true
            $ui.GridFolders.ItemsSource = $null; $ui.GridFiles.ItemsSource = $null; $ui.GridExt.ItemsSource = $null
            $ui.TxtCurrentPath.Text = '—'
            $script:ScanStart = Get-Date
            [PCDoctor.DiskScanner]::Start($target, 200)
            $script:ScanActive = $true
            Set-Status "Analyse de $target… (de quelques secondes à quelques minutes selon le disque)"
        })
    $ui.BtnCancelScan.Add_Click({ [PCDoctor.DiskScanner]::Cancel = $true })

    $ui.GridFolders.Add_MouseDoubleClick({
            $it = $ui.GridFolders.SelectedItem
            if ($it -and $it.Node) { Show-Node $it.Node }
        })
    $ui.BtnUp.Add_Click({ if ($script:CurrentNode -and $script:CurrentNode.Parent) { Show-Node $script:CurrentNode.Parent } })
    $ui.BtnOpenFolder.Add_Click({
            $it = $ui.GridFolders.SelectedItem
            $path = if ($it -and $it.Node) { $it.Node.FullPath } elseif ($script:CurrentNode) { $script:CurrentNode.FullPath } else { $null }
            if ($path) { Start-Process explorer.exe -ArgumentList "`"$path`"" }
        })

    $ui.BtnShowFile.Add_Click({
            $it = $ui.GridFiles.SelectedItem
            if ($it) { Start-Process explorer.exe -ArgumentList "/select,`"$($it.FullPath)`"" } else { Set-Status 'Sélectionnez un fichier dans la liste.' }
        })
    $ui.BtnRecycleFile.Add_Click({
            $it = $ui.GridFiles.SelectedItem
            if (-not $it) { Set-Status 'Sélectionnez un fichier dans la liste.'; return }
            $r = [System.Windows.MessageBox]::Show("Mettre ce fichier à la corbeille ?`n`n$($it.FullPath)`n($($it.SizeText))`n`nVous pourrez le récupérer depuis la corbeille tant qu'elle n'est pas vidée. Ne supprimez pas un fichier si vous ne savez pas à quoi il sert.", 'Mettre à la corbeille', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
            try {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($it.FullPath, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
                $ui.GridFiles.ItemsSource = @($ui.GridFiles.ItemsSource | Where-Object { $_.FullPath -ne $it.FullPath })
                Set-Status "« $($it.Name) » mis à la corbeille ($($it.SizeText)). Videz la corbeille pour libérer la place."
            } catch { Set-Status "Impossible : $($_.Exception.Message)" }
        })

    # --- Nettoyage --------------------------------------------------------
    $ui.BtnCleanTemp.Add_Click({
            # Uniquement les deux dossiers temporaires officiels, jamais un dossier racine ou le profil
            $userTemp = [IO.Path]::GetTempPath().TrimEnd('\')
            $winTemp = Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp'
            $userHome = [Environment]::GetFolderPath('UserProfile').TrimEnd('\')
            $targets = @($userTemp, $winTemp) | Where-Object {
                $_ -and $_ -match '\\Temp$' -and $_.Length -gt 8 -and $_ -ne $userHome -and ([IO.Path]::GetPathRoot($_).TrimEnd('\') -ne $_) -and (Test-Path -LiteralPath $_ -PathType Container)
            } | Select-Object -Unique
            if (-not $targets) { Set-Status 'Dossier temporaire introuvable.'; return }
            $r = [System.Windows.MessageBox]::Show("Supprimer le contenu des dossiers temporaires ?`n`n" + (($targets | ForEach-Object { "• $_" }) -join "`n") + "`n`nCe sont des fichiers jetables. Ceux en cours d'utilisation sont simplement ignorés.", 'Fichiers temporaires', 'YesNo', 'Question')
            if ($r -ne 'Yes') { return }
            $ui.BtnCleanTemp.IsEnabled = $false
            Set-Status 'Nettoyage des fichiers temporaires…'
            $code = '$freed = 0; $failed = 0' + "`n"
            foreach ($t in $targets) { $code += "`$freed += [PCDoctor.Cleaner]::CleanFolder('$($t -replace "'", "''")'); `$failed += [PCDoctor.Cleaner]::LastFailed`n" }
            $code += '[pscustomobject]@{ Freed = $freed; Failed = $failed }'
            Start-BgJob $code {
                param($res)
                $o = @($res)[0]
                $ui.BtnCleanTemp.IsEnabled = $true
                [System.Windows.MessageBox]::Show(("{0} libérés.`n{1} élément(s) en cours d'utilisation ont été laissés (normal)." -f (Format-Size $o.Freed), $o.Failed), 'Nettoyage terminé') | Out-Null
                Refresh-Clean
            }
        })
    $ui.BtnEmptyBin.Add_Click({
            $size = [PCDoctor.RecycleBin]::Size(); $count = [PCDoctor.RecycleBin]::Count()
            if ($count -le 0) { Set-Status 'La corbeille est déjà vide.'; return }
            $r = [System.Windows.MessageBox]::Show(("Vider définitivement la corbeille ?`n`n{0:N0} élément(s), {1}.`nCette action est irréversible." -f $count, (Format-Size $size)), 'Vider la corbeille', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
            [void][PCDoctor.RecycleBin]::Empty()
            Set-Status "Corbeille vidée : $(Format-Size $size) libérés."
            Refresh-Clean
        })
    $ui.BtnCleanmgr.Add_Click({ Start-Process (Get-SysExe 'cleanmgr.exe') })
    $ui.BtnStorageSettings.Add_Click({ Start-Process 'ms-settings:storagesense' })
    $ui.BtnRefreshClean.Add_Click({ Refresh-Clean })

    # =====================================================================
    #  BOÎTE NOIRE
    # =====================================================================
    $script:RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $script:RunName = 'PCDoctorBoiteNoire'
    $script:Loading = $true

    function Test-BlackBoxAutostart {
        try { return [bool](Get-ItemProperty -LiteralPath $script:RunKey -Name $script:RunName -ErrorAction Stop).$($script:RunName) } catch { return $false }
    }
    function Set-BlackBoxAutostart([bool]$on) {
        if ($on) {
            $c = Get-LaunchCommand -Monitor
            New-ItemProperty -LiteralPath $script:RunKey -Name $script:RunName -Value ("`"{0}`" {1}" -f $c.Exe, $c.Args).Trim() -PropertyType String -Force | Out-Null
        } else { Remove-ItemProperty -LiteralPath $script:RunKey -Name $script:RunName -ErrorAction SilentlyContinue }
    }
    function Start-BlackBox {
        if ([PCDoctor.BlackBox]::IsRunning()) { return }
        $c = Get-LaunchCommand -Monitor
        $psi = New-Object Diagnostics.ProcessStartInfo($c.Exe, $c.Args)
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        [void][Diagnostics.Process]::Start($psi)
    }

    function Update-BlackBoxStatus {
        $on = [PCDoctor.BlackBox]::IsRunning()
        $ui.BbDot.Fill = Get-Brush $(if ($on) { '#FF22C55E' } else { '#FF94A3B8' })
        $ui.NavBbDot.Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
        $ui.TxtBbStatus.Text = if ($on) { 'Surveillance active' } else { 'Surveillance arrêtée' }
        $ui.BtnBbStart.IsEnabled = -not $on
        $ui.BtnBbStop.IsEnabled = $on
        $files = @(Get-ChildItem -LiteralPath $script:BlackBoxDir -Filter *.csv -ErrorAction SilentlyContinue)
        $size = [double]($files | Measure-Object Length -Sum).Sum
        $ui.TxtBbSub.Text = if ($files.Count) { "{0} jour(s) enregistré(s), {1} sur le disque (conservés 7 jours)." -f $files.Count, (Format-Size $size) } else { "Aucune donnée enregistrée pour l'instant." }
        $script:Loading = $true
        $ui.ChkBbAutostart.IsChecked = Test-BlackBoxAutostart
        $script:Loading = $false
        Update-CpuTempSourceStatus
    }

    # D'où vient la température du processeur (Windows ne la fournit pas pour tous les processeurs)
    function Get-CpuTempSource {
        foreach ($m in @(@('Global\HWiNFO_SENS_SM2', 'HWiNFO'), @('CoreTempMappingObject', 'Core Temp'), @('CoreTempMappingObjectEx', 'Core Temp'))) {
            try { $mm = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($m[0], 'Read'); $mm.Dispose(); return $m[1] } catch {}
        }
        return $null
    }
    function Update-CpuTempSourceStatus {
        $src = Get-CpuTempSource
        if ($src) {
            $ui.TxtBbCpuTemp.Text = "Température du processeur : enregistrée via $src."
            $ui.TxtBbCpuTemp.Foreground = Get-Brush '#FF15803D'
            $ui.BtnBbCoreTemp.Visibility = 'Collapsed'
        } else {
            $installed = [PCDoctor.LiveSensors]::CoreTempInstalled()
            $ui.TxtBbCpuTemp.Text = if ($installed) { "Température du processeur : non enregistrée. Lancez Core Temp (déjà installé) et, dans ses options, cochez « Démarrer avec Windows »." } else { "Température du processeur : non enregistrée. Installez Core Temp (gratuit) ou lancez HWiNFO avec « Shared Memory Support »." }
            $ui.TxtBbCpuTemp.Foreground = Get-Brush '#FFB45309'
            $ui.BtnBbCoreTemp.Content = if ($installed) { 'Lancer Core Temp' } else { 'Télécharger Core Temp' }
            $ui.BtnBbCoreTemp.Visibility = 'Visible'
        }
        $ui.TxtStressCpuTemp.Text = $ui.TxtBbCpuTemp.Text -replace 'enregistrée', 'surveillée'
        $ui.TxtStressCpuTemp.Foreground = $ui.TxtBbCpuTemp.Foreground
        $ui.BtnStressCoreTemp.Content = $ui.BtnBbCoreTemp.Content
        $ui.BtnStressCoreTemp.Visibility = $ui.BtnBbCoreTemp.Visibility
    }
    $ui.BtnBbCoreTemp.Add_Click({
            if ([PCDoctor.LiveSensors]::CoreTempInstalled()) {
                try { Start-Process -FilePath ([PCDoctor.LiveSensors]::CoreTempPath()); Set-Status 'Core Temp lancé : la boîte noire enregistre maintenant la température du processeur.' } catch { Set-Status "Impossible de lancer Core Temp : $_" }
            } else { Start-Process 'https://www.alcpu.com/CoreTemp/' }
            $script:BbRefreshAt = [DateTime]::Now.AddSeconds(4)
        })

    function ConvertFrom-BbLine([string]$l) {
        $v = $l.Split(';')
        if ($v.Count -lt 9) { return $null }
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $n = { param($s) $x = 0.0; if ($s -and [double]::TryParse($s, [Globalization.NumberStyles]::Float, $inv, [ref]$x)) { $x } else { $null } }
        $t = [datetime]::ParseExact($v[0], 'yyyy-MM-ddTHH:mm:ss', $inv)
        $gt = & $n $v[1]; $gp = & $n $v[2]; $gl = & $n $v[3]; $gu = & $n $v[5]; $cpu = & $n $v[6]; $ram = & $n $v[7]
        # Colonnes ajoutées en 2.4 (absentes des anciens enregistrements)
        $ct = if ($v.Count -gt 9) { & $n $v[9] } else { $null }
        $dt = if ($v.Count -gt 10) { & $n $v[10] } else { $null }
        $db = if ($v.Count -gt 11) { & $n $v[11] } else { $null }
        [pscustomobject]@{
            Time = $t; GpuTemp = $gt; GpuPower = $gp; GpuLimit = $gl; GpuClock = (& $n $v[4]); GpuUsage = $gu; Cpu = $cpu; Ram = $ram; App = $v[8]
            CpuTemp = $ct; DiskTemp = $dt; DiskBusy = $db
            CpuTempText = $(if ($null -ne $ct) { "{0:N0} °C" -f $ct } else { '—' })
            DiskTempText = $(if ($null -ne $dt) { "{0:N0} °C" -f $dt } else { '—' })
            DiskBusyText = $(if ($null -ne $db) { "{0:N0} %" -f $db } else { '—' })
            TimeText = $t.ToString('HH:mm:ss')
            GpuTempText = $(if ($null -ne $gt) { "{0:N0} °C" -f $gt } else { '—' })
            GpuPowerText = $(if ($null -ne $gp) { "{0:N0} W" -f $gp } else { '—' })
            GpuUsageText = $(if ($null -ne $gu) { "{0:N0} %" -f $gu } else { '—' })
            CpuText = $(if ($null -ne $cpu) { "{0:N0} %" -f $cpu } else { '—' })
            RamText = $(if ($null -ne $ram) { "{0:N0} %" -f $ram } else { '—' })
        }
    }

    function Show-BlackBoxCrashes {
        $since = (Get-Date).AddDays(-7)
        $events = @()
        if ($script:LastData) { $events = @($script:LastData.Crashes | Where-Object { $_ -and $_.Date -ge $since -and @('Arrêt brutal', 'Écran bleu (BSOD)') -contains $_.Category }) }
        $rows = foreach ($e in $events) {
            $last = [PCDoctor.BlackBox]::LastBefore($script:BlackBoxDir, $e.Date, 12)
            $s = if ($last) { ConvertFrom-BbLine $last } else { $null }
            $gapMin = if ($s) { ($e.Date - $s.Time).TotalMinutes } else { $null }
            [pscustomobject]@{
                Date = $e.Date; DateText = $e.DateText; Category = $e.Category
                HasData = [bool]$s; CutTime = $(if ($s) { $s.Time } else { $null })
                LastText = $(if ($s) { "Dernier enregistrement à {0} ({1})" -f $s.Time.ToString('HH:mm:ss'), $(if ($gapMin -lt 60) { "{0:N0} min avant le redémarrage" -f $gapMin } else { "{0:N1} h avant le redémarrage" -f ($gapMin / 60) }) } else { 'Pas de données : la boîte noire ne tournait pas à ce moment-là' })
            }
        }
        $rows = @($rows | Sort-Object Date -Descending)
        $ui.GridBbCrashes.ItemsSource = $rows
        $withData = @($rows | Where-Object { $_.HasData }).Count
        $ui.TxtBbCrashInfo.Text = if (-not $rows.Count) { 'Aucun plantage ces 7 derniers jours.' }
        elseif (-not $withData) { "Aucun de ces plantages n'a été enregistré : activez la surveillance pour que le prochain le soit." }
        else { "$withData plantage(s) enregistré(s) par la boîte noire : cliquez sur « Analyser »." }
    }

    function Draw-Chart($canvas, $values, [double]$max, [string]$color, $warn) {
        $canvas.Children.Clear()
        $w = $canvas.ActualWidth
        if ($w -lt 50) { $w = 420 }
        $h = $canvas.Height
        if ($null -ne $warn -and $warn -lt $max) {
            $y = $h - ($warn / $max) * $h
            $line = New-Object System.Windows.Shapes.Line
            $line.X1 = 0; $line.X2 = $w; $line.Y1 = $y; $line.Y2 = $y
            $line.Stroke = Get-Brush '#FFEF4444'; $line.StrokeThickness = 1; $line.Opacity = 0.5
            $line.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection (, [double[]](4, 3))
            [void]$canvas.Children.Add($line)
        }
        $n = $values.Count
        if ($n -lt 2) { return }
        $poly = New-Object System.Windows.Shapes.Polyline
        $poly.Stroke = Get-Brush $color; $poly.StrokeThickness = 2; $poly.StrokeLineJoin = 'Round'
        for ($i = 0; $i -lt $n; $i++) {
            $v = $values[$i]
            if ($null -eq $v) { continue }
            $poly.Points.Add((New-Object System.Windows.Point(($i / ($n - 1) * $w), ($h - [math]::Min($v, $max) / $max * ($h - 2) - 1))))
        }
        [void]$canvas.Children.Add($poly)
    }

    function Get-BbVerdict($samples, [bool]$isCrash) {
        $end = $samples[-1].Time
        $last = @($samples | Where-Object { $_.Time -ge $end.AddSeconds(-60) })
        $mx = { param($p) $vals = @($last | ForEach-Object { $_.$p } | Where-Object { $null -ne $_ }); if ($vals.Count) { ($vals | Measure-Object -Maximum).Maximum } else { $null } }
        $maxT = & $mx 'GpuTemp'; $maxP = & $mx 'GpuPower'; $maxU = & $mx 'GpuUsage'; $maxCpu = & $mx 'Cpu'; $maxRam = & $mx 'Ram'
        $maxCt = & $mx 'CpuTemp'; $maxDt = & $mx 'DiskTemp'; $maxDb = & $mx 'DiskBusy'
        $lim = ($last | Where-Object { $_.GpuLimit } | Select-Object -Last 1).GpuLimit
        $app = ($last | Where-Object { $_.App } | Group-Object App | Sort-Object Count -Descending | Select-Object -First 1).Name
        $lines = New-Object System.Collections.Generic.List[string]
        $heavy = $false
        if ($null -ne $maxT) {
            if ($maxT -ge 85) { $lines.Add(("• Carte graphique très chaude ({0:N0} °C) : la surchauffe est une cause probable." -f $maxT)); $heavy = $true }
            elseif ($maxT -ge 78) { $lines.Add(("• Carte graphique chaude ({0:N0} °C), mais pas à un niveau critique." -f $maxT)) }
            else { $lines.Add(("• Température de la carte graphique normale ({0:N0} °C max) : pas de surchauffe côté carte graphique." -f $maxT)) }
        }
        if ($null -ne $maxP -and $lim) {
            if ($maxP -ge 0.9 * $lim) { $lines.Add(("• La carte graphique tirait presque toute sa puissance ({0:N0} W sur {1:N0} W) : un pic de consommation est possible. Testez l'alimentation (limite à 75 %, page Solutions)." -f $maxP, $lim)); $heavy = $true }
            else { $lines.Add(("• Consommation de la carte graphique : {0:N0} W au maximum (limite {1:N0} W)." -f $maxP, $lim)) }
        }
        if ($null -ne $maxCt) {
            if ($maxCt -ge 90) { $lines.Add(("• Processeur très chaud ({0:N0} °C) : la surchauffe du processeur est une cause probable (ventirad, pâte thermique, poussière)." -f $maxCt)); $heavy = $true }
            elseif ($maxCt -ge 80) { $lines.Add(("• Processeur chaud ({0:N0} °C), mais sous sa limite de sécurité." -f $maxCt)) }
            else { $lines.Add(("• Température du processeur normale ({0:N0} °C max) : pas de surchauffe côté processeur." -f $maxCt)) }
        } else {
            $lines.Add("• Température du processeur non enregistrée (lancez Core Temp ou HWiNFO pendant que la boîte noire tourne).")
        }
        if ($null -ne $maxDt -and $maxDt -ge 65) { $lines.Add(("• SSD très chaud ({0:N0} °C) : il peut ralentir fortement ou provoquer des gels." -f $maxDt)); $heavy = $true }
        if ($null -ne $maxDb -and $maxDb -ge 95) { $lines.Add(("• Disque système occupé à {0:N0} % juste avant : il pouvait figer le PC." -f $maxDb)) }
        if ($null -ne $maxCpu -and $maxCpu -ge 90) { $lines.Add(("• Processeur à fond ({0:N0} %)." -f $maxCpu)); $heavy = $true }
        if ($null -ne $maxRam -and $maxRam -ge 95) { $lines.Add(("• Mémoire vive saturée ({0:N0} %)." -f $maxRam)); $heavy = $true }
        if ($app) { $lines.Add("• Programme au premier plan : $app.") }
        if ($isCrash -and -not $heavy) {
            $lines.Add(("`nLe PC était peu sollicité au moment de la coupure (carte graphique {0:N0} %, processeur {1:N0} %). La surchauffe et un pic de consommation sont donc peu probables : regardez plutôt la RAM (test mémoire), le pilote graphique ou une alimentation défectueuse même au repos." -f [double]$maxU, [double]$maxCpu))
        }
        ($lines -join "`n")
    }

    function Show-BlackBoxWindow([datetime]$end, [int]$minutes, [bool]$isCrash) {
        $raw = [PCDoctor.BlackBox]::ReadRange($script:BlackBoxDir, $end.AddMinutes(-$minutes), $end)
        $samples = @($raw | ForEach-Object { ConvertFrom-BbLine $_ } | Where-Object { $_ })
        if (-not $samples.Count) { Set-Status "Aucune donnée enregistrée sur cette période."; return }
        $ui.BbAnalysis.Visibility = 'Visible'
        $ui.TxtBbTitle.Text = if ($isCrash) { "Les $minutes minutes avant la coupure (dernier enregistrement à $($samples[-1].Time.ToString('HH:mm:ss')), le $($samples[-1].Time.ToString('dd/MM')))" } else { "Les $minutes dernières minutes" }
        $ui.TxtBbVerdict.Text = Get-BbVerdict $samples $isCrash
        $window.UpdateLayout()
        $lim = ($samples | Where-Object { $_.GpuLimit } | Select-Object -Last 1).GpuLimit
        $pmax = if ($lim) { [double]$lim * 1.05 } else { 400 }
        Draw-Chart $ui.ChartGpuTemp @($samples | ForEach-Object { $_.GpuTemp }) 100 '#FFF59E0B' 85
        Draw-Chart $ui.ChartGpuPower @($samples | ForEach-Object { $_.GpuPower }) $pmax '#FF8B5CF6' $lim
        Draw-Chart $ui.ChartCpu @($samples | ForEach-Object { $_.Cpu }) 100 '#FF3B6EF5' $null
        Draw-Chart $ui.ChartRam @($samples | ForEach-Object { $_.Ram }) 100 '#FF22C55E' 95
        Draw-Chart $ui.ChartCpuTemp @($samples | ForEach-Object { $_.CpuTemp }) 100 '#FFEF4444' 90
        Draw-Chart $ui.ChartDisk @($samples | ForEach-Object { $_.DiskBusy }) 100 '#FFFBBF24' $null
        $mx = { param($p, $fmt) $vals = @($samples | ForEach-Object { $_.$p } | Where-Object { $null -ne $_ }); if ($vals.Count) { $fmt -f ($vals | Measure-Object -Maximum).Maximum } else { 'pas de données' } }
        $ui.ChartGpuTempInfo.Text = & $mx 'GpuTemp' 'max {0:N0} °C'
        $ui.ChartGpuPowerInfo.Text = (& $mx 'GpuPower' 'max {0:N0} W') + $(if ($lim) { " / limite {0:N0} W" -f $lim } else { '' })
        $ui.ChartCpuInfo.Text = & $mx 'Cpu' 'max {0:N0} %'
        $ui.ChartRamInfo.Text = & $mx 'Ram' 'max {0:N0} %'
        $ui.ChartCpuTempInfo.Text = & $mx 'CpuTemp' 'max {0:N0} °C'
        $ui.ChartDiskInfo.Text = (& $mx 'DiskBusy' 'max {0:N0} %') + $(& $mx 'DiskTemp' '  ·  SSD {0:N0} °C' | Where-Object { $_ -ne 'pas de données' })
        $ui.TxtBbTableTitle.Text = if ($isCrash) { 'Dernières mesures avant la coupure (la plus récente en haut)' } else { 'Dernières mesures (la plus récente en haut)' }
        $tail = @($samples | Select-Object -Last 45)
        [array]::Reverse($tail)
        $ui.GridBbSamples.ItemsSource = $tail
        $ui.BbAnalysis.BringIntoView()
    }

    $ui.BtnBbStart.Add_Click({
            try { Start-BlackBox; Set-Status 'Boîte noire démarrée : icône PC Doctor près de l''horloge.' } catch { Set-Status "Impossible de démarrer la boîte noire : $_" }
            $script:BbRefreshAt = [DateTime]::Now.AddSeconds(3)
        })
    $ui.BtnBbStop.Add_Click({
            if ([PCDoctor.BlackBox]::RequestStop()) { Set-Status 'Boîte noire arrêtée.' }
            $script:BbRefreshAt = [DateTime]::Now.AddSeconds(3)
        })
    $ui.ChkBbAutostart.Add_Checked({ if (-not $script:Loading) { Set-BlackBoxAutostart $true; Set-Status 'La boîte noire se lancera avec Windows.' } })
    $ui.ChkBbAutostart.Add_Unchecked({ if (-not $script:Loading) { Set-BlackBoxAutostart $false; Set-Status 'La boîte noire ne se lancera plus avec Windows.' } })
    $ui.BtnBbLast.Add_Click({ Show-BlackBoxWindow (Get-Date) 10 $false })
    $ui.GridBbCrashes.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
            param($sender, $e)
            $b = $e.OriginalSource
            if ($b -is [System.Windows.Controls.Button] -and $b.Tag -eq 'bb-analyze' -and $b.DataContext.HasData) {
                try { Show-BlackBoxWindow $b.DataContext.CutTime 5 $true } catch { Write-Log "Analyse : $_ $($_.ScriptStackTrace)"; Set-Status "Erreur d'analyse : $_" }
            }
        })

    # =====================================================================
    #  Test de stabilité
    # =====================================================================
    $script:StressMarker = Join-Path $script:LogDir 'test-stabilite.txt'
    $script:StressWasRunning = $false
    $script:StressNextUi = [DateTime]::MinValue
    $script:StressCrashTime = $null

    function Format-Temp($v) { if ($v -gt 0) { "{0:N0} °C" -f $v } else { '—' } }
    function Format-Duration([TimeSpan]$d) { if ($d.TotalSeconds -lt 90) { "{0:N0} s" -f $d.TotalSeconds } else { "{0:N0} min" -f $d.TotalMinutes } }
    function ConvertTo-ChartValues($arr) { @($arr | ForEach-Object { if ($_ -gt 0) { $_ } else { $null } }) }

    # Au lancement : un test était-il en cours quand le PC s'est coupé ?
    function Test-StressCrash {
        if (-not (Test-Path -LiteralPath $script:StressMarker)) { return $false }
        $m = @{}
        foreach ($l in @(Get-Content -LiteralPath $script:StressMarker -ErrorAction SilentlyContinue)) { $i = $l.IndexOf('='); if ($i -gt 0) { $m[$l.Substring(0, $i)] = $l.Substring($i + 1) } }
        Remove-Item -LiteralPath $script:StressMarker -Force -ErrorAction SilentlyContinue
        $inv = [Globalization.CultureInfo]::InvariantCulture
        try { $start = [datetime]::ParseExact($m['start'], 'yyyy-MM-ddTHH:mm:ss', $inv); $last = [datetime]::ParseExact($m['last'], 'yyyy-MM-ddTHH:mm:ss', $inv) } catch { return $false }
        $boot = $null
        try { $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch {}
        if (-not $boot -or $boot -lt $start) { return $false }   # pas de redémarrage : PC Doctor a seulement été fermé brutalement
        $script:StressCrashTime = $last
        $parts = @(); if ($m['cpu'] -eq '1') { $parts += 'processeur' }; if ($m['ram'] -eq '1') { $parts += 'mémoire' }; if ($m['gpu'] -eq '1') { $parts += 'carte graphique' }
        $ct = 0.0; $gt = 0.0; $gw = 0.0; $re = 0
        [void][double]::TryParse($m['maxcputemp'], [Globalization.NumberStyles]::Float, $inv, [ref]$ct)
        [void][double]::TryParse($m['maxgputemp'], [Globalization.NumberStyles]::Float, $inv, [ref]$gt)
        [void][double]::TryParse($m['maxgpupower'], [Globalization.NumberStyles]::Float, $inv, [ref]$gw)
        [void][int]::TryParse($m['ramerrors'], [ref]$re)
        $hot = ($ct -ge 88) -or ($gt -ge 85)
        $txt = "Coupure après environ {0} de test ({1}). Valeurs maximales relevées : processeur {2}, carte graphique {3}{4}." -f (Format-Duration ($last - $start)), ($parts -join ', '), (Format-Temp $ct), (Format-Temp $gt), $(if ($gw -gt 0) { ", {0:N0} W" -f $gw } else { '' })
        $txt += if ($hot) { "`nLes températures étaient très élevées juste avant : la surchauffe est la piste principale (ventilateurs, poussière, pâte thermique)." }
        elseif ($re -gt 0) { "`nDes erreurs de mémoire avaient été détectées avant la coupure : la RAM est la piste principale." }
        elseif ($ct -le 0) { "`nLa carte graphique n'était pas en surchauffe (la température du processeur n'était pas surveillée). Une coupure nette sous forte charge désigne souvent l'alimentation (ou ses câbles) : refaites le test avec Core Temp lancé pour écarter la surchauffe du processeur." }
        else { "`nLes températures étaient normales : une coupure nette sous forte charge, sans surchauffe, désigne d'abord l'alimentation (ou ses câbles), puis la carte mère. La boîte noire montre les dernières secondes." }
        $ui.TxtStressCrashTitle.Text = "Le PC s'est coupé pendant le test de stabilité du {0:dd/MM à HH:mm}" -f $start
        $ui.TxtStressCrash.Text = $txt
        $ui.StressCrashBox.Visibility = 'Visible'
        $ui.NavStressDot.Visibility = 'Visible'
        return $true
    }

    function Set-StressRunningUi([bool]$on) {
        $ui.BtnStressStart.IsEnabled = -not $on
        $ui.BtnStressStop.IsEnabled = $on
        foreach ($c in @($ui.ChkStressCpu, $ui.ChkStressRam, $ui.ChkStressGpu, $ui.CmbStressMinutes)) { $c.IsEnabled = -not $on }
    }

    function Start-StressTest {
        $cpu = [bool]$ui.ChkStressCpu.IsChecked; $ram = [bool]$ui.ChkStressRam.IsChecked; $gpu = [bool]$ui.ChkStressGpu.IsChecked
        if (-not ($cpu -or $ram -or $gpu)) { Set-Status 'Cochez au moins un élément à tester.'; return }
        $min = @(5, 10, 15)[[math]::Max(0, $ui.CmbStressMinutes.SelectedIndex)]
        if ($cpu -and -not (Get-CpuTempSource)) {
            $r = [System.Windows.MessageBox]::Show($window, "La température du processeur n'est pas surveillée (Core Temp ou HWiNFO n'est pas lancé) : l'arrêt automatique à 90 °C ne fonctionnera pas pour le processeur. Il se protège quand même tout seul en ralentissant s'il chauffe trop.`n`nLancer le test quand même ?", 'PC Doctor', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
        }
        try { Start-BlackBox } catch { Write-Log "Test : boîte noire : $_" }
        [PCDoctor.StressTest]::Start($cpu, $ram, $gpu, $min, $script:StressMarker, [string]$script:SmiPath)
        $script:StressWasRunning = $true
        $script:StressNextUi = [DateTime]::MinValue
        Set-StressRunningUi $true
        $ui.StressResult.Visibility = 'Collapsed'
        $ui.StressCrashBox.Visibility = 'Collapsed'
        $ui.NavStressDot.Visibility = 'Collapsed'
        $ui.TxtStressState.Text = 'Test en cours…'
        Set-Status "Test de stabilité lancé pour $min minutes. Le PC peut être lent pendant le test."
        $script:BbRefreshAt = [DateTime]::Now.AddSeconds(3)
    }

    function Update-StressUi {
        $T = [PCDoctor.StressTest]
        $s = $T::Last
        if ($T::Running) {
            $now = Get-Date
            $el = $now - $T::Started
            $tot = ($T::Ends - $T::Started).TotalSeconds
            $rem = $T::Ends - $now; if ($rem.TotalSeconds -lt 0) { $rem = [TimeSpan]::Zero }
            $ui.BarStress.Value = [math]::Min(100, 100 * $el.TotalSeconds / $tot)
            $ui.TxtStressTime.Text = "{0:mm\:ss} écoulées · reste {1:mm\:ss}" -f $el, $rem
            $ui.TxtStressState.Text = if ($T::StopReason) { 'Arrêt en cours…' } else { 'Test en cours…' }
        }
        $ui.TxtStressCpuT.Text = Format-Temp $s.CpuTemp
        $ui.TxtStressCpuT.Foreground = Get-Brush $(if ($s.CpuTemp -ge 85) { '#FFEF4444' } elseif ($s.CpuTemp -ge 78) { '#FFF59E0B' } else { '#FF0F172A' })
        $ui.TxtStressCpuSub.Text = $(if ($s.Cpu -ge 0) { "charge {0:N0} %" -f $s.Cpu } else { '' }) + $(if ($T::MaxCpuTemp -gt 0) { " · max {0:N0} °C" -f $T::MaxCpuTemp } elseif ($T::UseCpu) { ' · température non surveillée' } else { '' })
        $ui.TxtStressGpuT.Text = Format-Temp $s.GpuTemp
        $ui.TxtStressGpuT.Foreground = Get-Brush $(if ($s.GpuTemp -ge 83) { '#FFEF4444' } elseif ($s.GpuTemp -ge 76) { '#FFF59E0B' } else { '#FF0F172A' })
        $ui.TxtStressGpuSub.Text = if ($T::GpuStatus -like 'Erreur*') { $T::GpuStatus.Substring(9) } elseif ($s.GpuUsage -ge 0) { "utilisation {0:N0} %" -f $s.GpuUsage + $(if ($T::MaxGpuTemp -gt 0) { " · max {0:N0} °C" -f $T::MaxGpuTemp } else { '' }) } else { 'non suivie (NVIDIA uniquement)' }
        $ui.TxtStressGpuW.Text = if ($s.GpuPower -ge 0) { "{0:N0} W" -f $s.GpuPower } else { '—' }
        $ui.TxtStressGpuWSub.Text = if ($s.GpuPowerLimit -gt 0) { "limite {0:N0} W" -f $s.GpuPowerLimit + $(if ($T::MaxGpuPower -gt 0) { " · max {0:N0} W" -f $T::MaxGpuPower } else { '' }) } else { '' }
        if ($T::UseRam) {
            $ui.TxtStressRam.Text = if ($T::RamGB -gt 0) { "{0:N1} Go" -f $T::RamGB } else { '…' }
            $ui.TxtStressRam.Foreground = Get-Brush $(if ($T::RamErrors -gt 0) { '#FFEF4444' } else { '#FF0F172A' })
            $ui.TxtStressRamSub.Text = if ($T::RamStatus) { $T::RamStatus } else { "{0} vérification(s) · {1} erreur(s)" -f $T::RamPasses, $T::RamErrors }
        } else { $ui.TxtStressRam.Text = '—'; $ui.TxtStressRamSub.Text = 'non testée' }
        $window.UpdateLayout()
        Draw-Chart $ui.ChartStressCpuT (ConvertTo-ChartValues ($T::History(0))) 100 '#FFEF4444' $T::CpuLimit
        Draw-Chart $ui.ChartStressGpuT (ConvertTo-ChartValues ($T::History(1))) 100 '#FFF59E0B' $T::GpuLimit
        $pl = if ($T::GpuPowerLimit -gt 0) { $T::GpuPowerLimit * 1.05 } else { 400 }
        Draw-Chart $ui.ChartStressGpuW (ConvertTo-ChartValues ($T::History(2))) $pl '#FF8B5CF6' $(if ($T::GpuPowerLimit -gt 0) { $T::GpuPowerLimit } else { $null })
    }

    function Complete-StressTest {
        $T = [PCDoctor.StressTest]
        Set-StressRunningUi $false
        $dur = Format-Duration ($T::StoppedAt - $T::Started)
        $ui.BarStress.Value = 0
        $ui.TxtStressTime.Text = ''
        $lines = New-Object System.Collections.Generic.List[string]
        $sev = 'ok'
        switch ($T::StopReason) {
            'cputemp' { $sev = 'bad'; $title = 'Arrêt automatique : processeur trop chaud'; $lines.Add(("Le processeur a atteint {0:N0} °C après {1}. Son refroidissement est insuffisant : vérifiez que le ventilateur du processeur tourne et que le ventirad est bien fixé, dépoussiérez, et refaites la pâte thermique si le PC a plusieurs années. Une surchauffe peut expliquer des coupures en jeu." -f $T::MaxCpuTemp, $dur)) }
            'gputemp' { $sev = 'bad'; $title = 'Arrêt automatique : carte graphique trop chaude'; $lines.Add(("La carte graphique a atteint {0:N0} °C après {1}. Dépoussiérez-la, vérifiez que ses ventilateurs tournent et que le boîtier est bien ventilé." -f $T::MaxGpuTemp, $dur)) }
            'gpudriver' { $sev = 'bad'; $title = 'Le pilote de la carte graphique a planté'; $lines.Add(("Windows a dû réinitialiser la carte graphique après {0}. Causes fréquentes : pilote abîmé (réinstallez-le proprement, page Pilotes), overclocking de la carte graphique, ou alimentation qui faiblit sous la charge." -f $dur)) }
            'gpuerror' { $sev = 'warn'; $title = 'Test de la carte graphique impossible'; $lines.Add("La carte graphique n'a pas pu être testée : $($T::GpuStatus). Mettez à jour son pilote puis réessayez.") }
            'user' { $sev = 'warn'; $title = "Test arrêté après $dur"; $lines.Add("Vous avez arrêté le test. Aucun problème n'a été détecté jusque-là.") }
            default { $title = "Test réussi : $dur à pleine charge, sans problème"; $lines.Add("Ni coupure, ni surchauffe, ni erreur de mémoire pendant le test.") }
        }
        if ($T::UseRam) {
            if ($T::RamErrors -gt 0) {
                $sev = 'bad'
                if ($T::StopReason -in @('time', 'user')) { $title = 'Erreurs de mémoire vive détectées' }
                $lines.Add(("• Mémoire vive : {0} erreur(s) sur {1:N1} Go testés. La RAM ne garde pas correctement les données : c'est une cause classique de plantages et d'écrans bleus. Vérifiez que l'EXPO/XMP est désactivé dans le BIOS, réinstallez les barrettes, puis testez-les une par une (Diagnostic de mémoire Windows ou MemTest86)." -f $T::RamErrors, $T::RamGB))
            } elseif ($T::RamPasses -gt 0) { $lines.Add(("• Mémoire vive : {0:N1} Go écrits et vérifiés {1} fois, aucune erreur." -f $T::RamGB, $T::RamPasses)) }
            else { $lines.Add("• Mémoire vive : test trop court pour une vérification complète.") }
        }
        if ($T::UseCpu) {
            $lines.Add($(if ($T::MaxCpuTemp -gt 0) { "• Processeur : {0:N0} °C au maximum{1}." -f $T::MaxCpuTemp, $(if ($T::MaxCpuTemp -ge 85) { ', c''est chaud : améliorer son refroidissement est conseillé' } else { ', température correcte' }) } else { "• Processeur : température non surveillée (lancez Core Temp avant le prochain test)." }))
        }
        if ($T::UseGpu -and $T::MaxGpuTemp -gt 0) {
            $g = "• Carte graphique : {0:N0} °C au maximum" -f $T::MaxGpuTemp
            if ($T::MaxGpuPower -gt 0 -and $T::GpuPowerLimit -gt 0) {
                $g += ", {0:N0} W sur {1:N0} W ({2:N0} % de sa limite)" -f $T::MaxGpuPower, $T::GpuPowerLimit, (100 * $T::MaxGpuPower / $T::GpuPowerLimit)
            }
            $lines.Add($g + '.')
            if ($T::StopReason -eq 'time' -and $T::GpuPowerLimit -gt 0 -and $T::MaxGpuPower -lt 0.75 * $T::GpuPowerLimit) { $lines.Add("  La carte graphique n'a pas atteint toute sa puissance pendant ce test : un jeu très exigeant peut la solliciter davantage.") }
        }
        $hard = 0
        if ($script:LastData -and $script:LastData.Crashes) { $hard = @($script:LastData.Crashes | Where-Object { $_ -and $_.Category -eq 'Arrêt brutal' }).Count }
        if ($sev -eq 'ok' -and $hard) {
            $lines.Add("`nLe PC a tenu la pleine charge : une alimentation incapable de fournir la puissance demandée, ou un refroidissement insuffisant, aurait très probablement provoqué la coupure. Si les coupures continuent, elles viennent plutôt d'un pic bref en jeu, de la RAM ou d'un pilote : laissez la boîte noire tourner et analysez la prochaine coupure.")
        }
        $ui.TxtStressState.Text = if ($sev -eq 'ok') { 'Test terminé' } else { 'Test arrêté' }
        $ui.TxtStressResultTitle.Text = $title
        $ui.StressResultDot.Fill = Get-Brush $(switch ($sev) { 'ok' { '#FF22C55E' } 'warn' { '#FFF59E0B' } default { '#FFEF4444' } })
        $ui.TxtStressResult.Text = ($lines -join "`n")
        $ui.StressResult.Visibility = 'Visible'
        $ui.StressResult.BringIntoView()
        Set-Status $title
    }

    $ui.BtnStressStart.Add_Click({ try { Start-StressTest } catch { Write-Log "Test : $_ $($_.ScriptStackTrace)"; Set-Status "Impossible de lancer le test : $_"; Set-StressRunningUi $false } })
    $ui.BtnStressStop.Add_Click({ [PCDoctor.StressTest]::Stop('user'); $ui.TxtStressState.Text = 'Arrêt en cours…'; $ui.BtnStressStop.IsEnabled = $false })
    $ui.BtnStressCoreTemp.Add_Click({
            if ([PCDoctor.LiveSensors]::CoreTempInstalled()) {
                try { Start-Process -FilePath ([PCDoctor.LiveSensors]::CoreTempPath()); Set-Status 'Core Temp lancé : la température du processeur sera surveillée pendant le test.' } catch { Set-Status "Impossible de lancer Core Temp : $_" }
            } else { Start-Process 'https://www.alcpu.com/CoreTemp/' }
            $script:BbRefreshAt = [DateTime]::Now.AddSeconds(4)
        })
    $ui.BtnStressSolutions.Add_Click({ Show-Page 'solutions' })
    $ui.BtnStressResultBb.Add_Click({
            $T = [PCDoctor.StressTest]
            $m = [int][math]::Min(15, [math]::Ceiling(($T::StoppedAt - $T::Started).TotalMinutes) + 1)
            Show-Page 'blackbox'
            try { Show-BlackBoxWindow $T::StoppedAt $m $false } catch { Set-Status "Boîte noire : $_" }
        })
    $ui.BtnStressCrashBb.Add_Click({
            Show-Page 'blackbox'
            if ($script:StressCrashTime) { try { Show-BlackBoxWindow $script:StressCrashTime.AddSeconds(8) 5 $true } catch { Set-Status "Boîte noire : $_" } }
        })

    # =====================================================================
    #  Sécurité
    # =====================================================================
    $script:SecurityLoaded = $false
    function Set-SecScore([int]$score) {
        $angle = [math]::Min(359.9, [math]::Max(0.5, 3.6 * $score))
        $r = 57.0; $cx = 65.0; $cy = 65.0; $rad = $angle * [math]::PI / 180
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $ui.SecScoreArc.Data = [System.Windows.Media.Geometry]::Parse([string]::Format($inv, 'M {0},{1} A {2},{2} 0 {3} 1 {4},{5}', $cx, ($cy - $r), $r, $(if ($angle -gt 180) { 1 } else { 0 }), ($cx + $r * [math]::Sin($rad)), ($cy - $r * [math]::Cos($rad))))
        $color = if ($score -ge 85) { '#FF22C55E' } elseif ($score -ge 60) { '#FFF59E0B' } else { '#FFEF4444' }
        $ui.SecScoreArc.Stroke = Get-Brush $color
        $ui.SecScoreText.Text = [string]$score
        $ui.SecScoreLabel.Text = if ($score -ge 85) { 'Bien protégé' } elseif ($score -ge 60) { 'À améliorer' } else { 'Mal protégé' }
        $ui.SecScoreLabel.Foreground = Get-Brush $color
    }
    function Load-Security {
        $script:SecurityLoaded = $true
        $ui.BtnSecRefresh.IsEnabled = $false
        $ui.ListSecurity.ItemsSource = @([pscustomobject]@{ Severity = 'Info'; Title = 'Vérification en cours…'; Advice = 'Antivirus, pare-feu, mises à jour, réglages de Windows et programmes au démarrage.'; ActionLabel = $null; ActionId = $null })
        Start-BgJob 'Get-SecurityStatus' { param($res) Show-Security (@($res)[0]); $ui.BtnSecRefresh.IsEnabled = $true }
    }
    function Show-Security($r) {
        if (-not $r) { $ui.SecScoreLabel.Text = 'Vérification impossible'; return }
        $items = @($r.Items)
        $ui.ListSecurity.ItemsSource = $items
        $crit = @($items | Where-Object { $_.Severity -eq 'Critique' }).Count
        $warn = @($items | Where-Object { $_.Severity -eq 'Attention' }).Count
        Set-SecScore ([math]::Max(5, 100 - 25 * $crit - 8 * $warn))
        $ui.SecScoreSub.Text = if ($crit + $warn -eq 0) { 'Aucun problème de sécurité' } else { "$crit problème(s) important(s), $warn point(s) à améliorer" }
        $ui.TxtSecAv.Text = $r.Facts.Antivirus; $ui.TxtSecFw.Text = $r.Facts.Firewall
        $ui.TxtSecWu.Text = if ($r.Facts.Updates -ne '?') { "dernière installée $($r.Facts.Updates)" } else { 'inconnu' }
        $ui.TxtSecHw.Text = $r.Facts.Hardware
        $ui.TxtSecAv.Foreground = Get-Brush $(if ($r.Facts.Antivirus -eq 'Aucun') { '#FFEF4444' } else { '#FF0F172A' })
        $ui.TxtSecFw.Foreground = Get-Brush $(if ($r.Facts.Firewall -eq 'Désactivé') { '#FFEF4444' } else { '#FF0F172A' })
        $ui.TxtSecNote.Text = if ($r.IsAdmin) { "Vérifié à $((Get-Date).ToString('HH:mm'))." } else { "Vérifié à $((Get-Date).ToString('HH:mm')). En mode administrateur, PC Doctor vérifie aussi les exclusions de l'antivirus et le chiffrement du disque plus précisément." }
        $ui.BadgeSecurity.Background = Get-Brush $(if ($crit) { '#FFEF4444' } else { '#FFF59E0B' })
        Set-Badge $ui.BadgeSecurity $ui.BadgeSecurityText ($crit + $warn)
    }
    function Start-QuickScan {
        $ui.BtnSecScan.IsEnabled = $false
        Set-Status 'Analyse antivirus rapide en cours avec Microsoft Defender (quelques minutes, vous pouvez continuer à utiliser le PC)…'
        Start-BgJob 'try { Start-MpScan -ScanType QuickScan -ErrorAction Stop; "ok" } catch { "erreur : $_" }' {
            param($res)
            $ui.BtnSecScan.IsEnabled = $true
            if ([string](@($res)[0]) -eq 'ok') {
                $t = @(); try { $t = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object { $_.InitialDetectionTime -ge (Get-Date).AddHours(-1) }) } catch {}
                Set-Status $(if ($t.Count) { "Analyse terminée : $($t.Count) menace(s) trouvée(s) et traitée(s) par Microsoft Defender." } else { 'Analyse antivirus terminée : aucune menace trouvée.' })
                Load-Security
            Load-BootTimes
            try { Show-Gaming } catch { Write-Log "Jeu : $_ $($_.ScriptStackTrace)" }
            } else {
                Set-Status 'L''analyse n''a pas pu être lancée d''ici (autre antivirus, ou droits insuffisants) : ouverture de Sécurité Windows.'
                Start-Process 'windowsdefender://threat'
            }
        }
    }
    function Disable-LocalAccount([string]$name) {
        if ($name -notmatch '^[\w .-]{1,40}$') { return }
        $r = [System.Windows.MessageBox]::Show($window, "Désactiver le compte « $name » ?`n`nIl ne pourra plus être utilisé pour ouvrir une session (vos fichiers et votre compte ne sont pas touchés). Windows va demander l'autorisation administrateur.", 'PC Doctor', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        Start-AdminConsole ("& '{0}' user '{1}' /active:no" -f (Get-SysExe 'net.exe'), $name) 'Desactivation de compte'
        Set-Status "Quand la fenêtre administrateur a terminé, cliquez sur « Vérifier à nouveau »."
    }
    $ui.BtnSecRefresh.Add_Click({ Load-Security })
    $ui.BtnSecScan.Add_Click({ Start-QuickScan })
    $ui.BtnSecOpen.Add_Click({ Start-Process 'windowsdefender://' })

    # =====================================================================
    #  Jeu et confort
    # =====================================================================
    function Get-TwReg([string]$path, [string]$name) { try { (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop).$name } catch { $null } }
    function Set-TwReg([string]$path, [string]$name, $value, [string]$type = 'DWord') {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $path -Name $name -Value $value -PropertyType $type -Force -ErrorAction Stop | Out-Null
    }
    $script:AdValues = @(
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-338388Enabled'),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-338389Enabled'),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-353694Enabled'),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-353696Enabled'),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SubscribedContent-310093Enabled'),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SystemPaneSuggestionsEnabled'),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager', 'SoftLandingEnabled'),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'ShowSyncProviderNotifications'),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced', 'Start_IrisRecommendations'),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement', 'ScoobeSystemSettingEnabled'),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo', 'Enabled')
    )
    # Chaque réglage : état actuel (Get), modification (Set), valeur conseillée (Rec, $null = question de goût)
    $script:TweakDefs = @(
        @{ Id = 'gamemode'; Section = 'game'; Name = 'Mode Jeu'; Rec = $true
            Why = 'Windows donne la priorité au jeu et ne lance pas les mises à jour ni leurs redémarrages pendant que vous jouez.'
            Get = { (Get-TwReg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled') -ne 0 }
            Set = { param($on) Set-TwReg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' ([int]$on) } },
        @{ Id = 'windowed'; Section = 'game'; Name = 'Optimisations pour les jeux en fenêtre'; Rec = $true
            Why = 'Moins de latence pour les jeux en fenêtre ou en plein écran sans bordure, et G-Sync / FreeSync possibles. Effet au prochain lancement du jeu.'
            Get = { [string](Get-TwReg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings') -match 'SwapEffectUpgradeEnable=1' }
            Set = { param($on)
                $v = ([string](Get-TwReg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings')) -replace 'SwapEffectUpgradeEnable=\d;?', ''
                Set-TwReg 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings' ($v + "SwapEffectUpgradeEnable=$([int]$on);") 'String' } },
        @{ Id = 'dvr'; Section = 'game'; Name = 'Enregistrement des jeux en arrière-plan'; Rec = $false
            Why = 'La Xbox Game Bar filme en continu les dernières minutes de jeu (« Enregistrer ce qui s''est passé ») : ça coûte quelques images par seconde. À garder seulement si vous vous en servez.'
            Get = { (Get-TwReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled') -eq 1 }
            Set = { param($on) Set-TwReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled' ([int]$on) } },
        @{ Id = 'mouse'; Section = 'game'; Name = 'Accélération de la souris'; Rec = $false
            Why = '(« Améliorer la précision du pointeur ») Désactivée, un même geste tourne toujours la caméra de la même distance : la visée est plus régulière en jeu. Effet immédiat.'
            Get = { [PCDoctor.Tweaks]::MouseAccel() }
            Set = { param($on) if (-not [PCDoctor.Tweaks]::SetMouseAccel($on)) { throw 'réglage refusé par Windows' } } },
        @{ Id = 'sticky'; Section = 'game'; Name = 'Raccourci des touches rémanentes (Maj 5 fois)'; Rec = $false
            Why = 'Appuyer plusieurs fois sur Maj en jeu (pour courir) ouvre une fenêtre qui fait sortir du jeu. Désactiver le raccourci ne touche pas à la fonction elle-même. Effet immédiat.'
            Get = { [PCDoctor.Tweaks]::StickyHotkey() }
            Set = { param($on) if (-not [PCDoctor.Tweaks]::SetStickyHotkey($on)) { throw 'réglage refusé par Windows' } } },
        @{ Id = 'ads'; Section = 'comfort'; Name = 'Publicités et suggestions de Windows'; Rec = $false
            Why = 'Applications suggérées dans le menu Démarrer, « conseils » et pubs dans l''Explorateur, écran « Terminez la configuration de votre appareil », identifiant publicitaire. Effet complet à la prochaine ouverture de session.'
            Get = { @($script:AdValues | Where-Object { (Get-TwReg $_[0] $_[1]) -ne 0 }).Count -gt 0 }
            Set = { param($on) foreach ($a in $script:AdValues) { Set-TwReg $a[0] $a[1] ([int]$on) } } },
        @{ Id = 'bing'; Section = 'comfort'; Name = 'Résultats web (Bing) dans la recherche du menu Démarrer'; Rec = $false; Admin = $true
            Why = 'Sans eux, la recherche ne montre que vos applications, fichiers et paramètres : plus rapide, et vos frappes ne partent pas sur Internet. Effet à la prochaine ouverture de session.'
            Get = { (Get-TwReg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions') -ne 1 }
            Set = { param($on)
                if ($on) { Remove-ItemProperty -LiteralPath 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Name 'DisableSearchBoxSuggestions' -ErrorAction SilentlyContinue }
                else { Set-TwReg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1 } } },
        @{ Id = 'ext'; Section = 'comfort'; Name = 'Extensions des fichiers visibles (.pdf, .exe…)'; Rec = $true
            Why = 'Permet de repérer un faux document piégé comme « facture.pdf.exe ». Effet à la prochaine fenêtre de l''Explorateur.'
            Get = { (Get-TwReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt') -eq 0 }
            Set = { param($on) Set-TwReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' ([int](-not $on)) } },
        @{ Id = 'dark'; Section = 'comfort'; Name = 'Mode sombre'; Rec = $null
            Why = 'Thème sombre pour Windows et les applications compatibles, plus reposant le soir. Question de goût.'
            Get = { (Get-TwReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme') -eq 0 }
            Set = { param($on) foreach ($n in 'AppsUseLightTheme', 'SystemUsesLightTheme') { Set-TwReg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' $n ([int](-not $on)) } } }
    )

    function Get-TweakRows([string]$section) {
        foreach ($t in @($script:TweakDefs | Where-Object { $_.Section -eq $section })) {
            $on = $false; try { $on = [bool](& $t.Get) } catch {}
            $good = ($null -eq $t.Rec) -or ($on -eq $t.Rec)
            $needAdmin = $t.Admin -and -not $script:IsAdmin
            [pscustomobject]@{
                Severity = $(if ($null -eq $t.Rec) { 'Neutre' } elseif ($good) { 'OK' } else { 'Info' })
                Title = "$($t.Name) : $(if ($on) { 'activé' } else { 'désactivé' })"
                Advice = $t.Why + $(if (-not $good) { " Conseillé : $(if ($t.Rec) { 'activé' } else { 'désactivé' })." } else { '' }) + $(if ($needAdmin) { ' Ce réglage demande le mode administrateur (bouton en bas à gauche).' } else { '' })
                ActionLabel = $(if ($needAdmin) { $null } elseif ($on) { 'Désactiver' } else { 'Activer' })
                ActionId = "tweak:$($t.Id):$(if ($on) { '0' } else { '1' })"
                Fix = ((-not $good) -and -not $needAdmin); Id = $t.Id; Name = $t.Name; Rec = $t.Rec
            }
        }
    }

    function Get-GamingExtraRows {
        $mk = { param($sev, $title, $advice, $label, $act) [pscustomobject]@{ Severity = $sev; Title = $title; Advice = $advice; ActionLabel = $label; ActionId = $act; Fix = $false; Name = $title } }
        # Écrans : fréquence et résolution
        $names = @()
        try { $names = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop | ForEach-Object { -join @($_.UserFriendlyName | Where-Object { $_ } | ForEach-Object { [char]$_ }) }) } catch {}
        $disp = @([PCDoctor.Tweaks]::Displays())
        for ($i = 0; $i -lt $disp.Count; $i++) {
            $d = $disp[$i]
            $n = if ($disp.Count -eq $names.Count -and $names[$i]) { "Écran $($names[$i])" } elseif ($disp.Count -gt 1) { "Écran $($i + 1)" } else { 'Écran' }
            if ($d.MaxHz -gt $d.Hz + 1) { & $mk 'Attention' "$n réglé sur $($d.Hz) Hz alors qu'il peut afficher $($d.MaxHz) Hz" "Images bien plus fluides en jeu comme sur le bureau. Choisissez $($d.MaxHz) Hz dans Affichage avancé > Fréquence d'actualisation. Si la valeur n'apparaît pas, utilisez un câble DisplayPort (ou HDMI 2.1)." 'Régler' 'ms-settings:display-advanced' }
            else { & $mk 'OK' "$n : $($d.Width)×$($d.Height) à $($d.Hz) Hz" 'Réglé sur sa fréquence maximale : rien à faire.' $null $null }
            if ([long]$d.MaxWidth * $d.MaxHeight -gt [long]$d.Width * $d.Height) { & $mk 'Info' "$n en $($d.Width)×$($d.Height) au lieu de $($d.MaxWidth)×$($d.MaxHeight)" 'L''image est moins nette qu''elle pourrait l''être. Choisissez la résolution « recommandée » dans Paramètres > Affichage.' 'Régler' 'ms-settings:display' }
        }
        # Mode d'alimentation
        try {
            $line = [string](@(Invoke-Hidden (Get-SysExe 'powercfg.exe') '/getactivescheme') | Where-Object { $_ -match '[0-9a-f]{8}-' } | Select-Object -First 1)
            $pname = if ($line -match '\(([^)]+)\)') { $Matches[1] } else { '?' }
            if ($line -match 'a1841308-3541-4fab-bc81-f71556f20b4a') { & $mk 'Attention' "Mode d'alimentation « $pname »" 'Le processeur et la carte graphique sont bridés pour économiser l''énergie : les jeux tournent moins vite.' 'Utilisation normale' 'powerplan-balanced' }
            elseif ($line) { & $mk 'OK' "Mode d'alimentation : $pname" 'Le processeur monte en puissance dès qu''un jeu le demande.' $null $null }
        } catch {}
        # Planification GPU à accélération matérielle (réglage système : ouvert dans Windows)
        $hags = Get-TwReg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
        if ($hags -eq 2) { & $mk 'OK' 'Planification GPU à accélération matérielle : activée' 'Un peu moins de latence, et nécessaire pour la génération d''images DLSS des cartes RTX 40.' $null $null }
        elseif ($hags -eq 1) { & $mk 'Info' 'Planification GPU à accélération matérielle : désactivée' 'L''activer réduit un peu la latence et permet la génération d''images DLSS (cartes RTX 40). Redémarrage nécessaire.' 'Ouvrir' 'ms-settings:display-advancedgraphics' }
    }

    function Show-Gaming {
        $game = @(Get-GamingExtraRows) + @(Get-TweakRows 'game')
        $comfort = @(Get-TweakRows 'comfort')
        $ui.ListGaming.ItemsSource = $game
        $ui.ListComfort.ItemsSource = $comfort
        $fix = @(@($game) + @($comfort) | Where-Object { $_.Fix })
        $att = @($game | Where-Object { $_.Severity -eq 'Attention' }).Count
        $script:GamingFix = $fix
        $ui.TxtGamingSummary.Text = if (-not $fix.Count -and -not $att) { 'Tout est bien réglé' } else { (@($(if ($fix.Count) { "$($fix.Count) réglage(s) conseillé(s)" }), $(if ($att) { "$att point(s) à corriger" }) | Where-Object { $_ }) -join ' et ') }
        $ui.TxtGamingSub.Text = if ($fix.Count) { 'Le bouton s''occupe de : ' + (($fix | ForEach-Object { $_.Name }) -join ', ') + '. Chaque réglage peut être remis ensuite d''un clic.' } elseif ($att) { 'Les points en orange se règlent dans Windows : utilisez leur bouton.' } else { 'Les réglages conseillés pour jouer et pour le confort sont déjà en place.' }
        $ui.BtnGamingApply.IsEnabled = ($fix.Count -gt 0)
        Set-Badge $ui.BadgeGaming $ui.BadgeGamingText ($fix.Count + $att)
    }

    function Invoke-Tweak([string]$id, [bool]$on) {
        $t = $script:TweakDefs | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $t) { return }
        try {
            & $t.Set $on
            Set-Status "« $($t.Name) » $(if ($on) { 'activé' } else { 'désactivé' })."
        } catch {
            Write-Log "Réglage $id : $_"
            if ($_.Exception -is [System.UnauthorizedAccessException] -or "$_" -match 'refus|denied|non autoris') { Set-Status "Ce réglage demande les droits administrateur : cliquez sur « Passer en administrateur » en bas à gauche, puis réessayez." }
            else { Set-Status "Impossible de modifier « $($t.Name) » : $_" }
        }
        Show-Gaming
    }

    $ui.BtnGamingApply.Add_Click({
            $fix = @($script:GamingFix)
            if (-not $fix.Count) { return }
            $txt = ($fix | ForEach-Object { "• $($_.Name) : $(if ($_.Rec) { 'activé' } else { 'désactivé' })" }) -join "`n"
            $r = [System.Windows.MessageBox]::Show($window, "PC Doctor va appliquer ces réglages :`n`n$txt`n`nChacun pourra être remis d'un clic sur cette page.", 'Jeu et confort', 'OKCancel', 'Question')
            if ($r -ne 'OK') { return }
            $done = 0
            foreach ($f in $fix) { $t = $script:TweakDefs | Where-Object { $_.Id -eq $f.Id } | Select-Object -First 1; try { & $t.Set ([bool]$t.Rec); $done++ } catch { Write-Log "Réglage $($f.Id) : $_" } }
            Show-Gaming
            Set-Status $(if ($done -eq $fix.Count) { "$done réglage(s) appliqué(s)." } else { "$done réglage(s) sur $($fix.Count) appliqué(s) : les autres demandent les droits administrateur." })
        })

    # =====================================================================
    #  Durée de démarrage (page Démarrage)
    # =====================================================================
    function Show-BootTimes($r) {
        $boots = @($r.Boots | Where-Object { $_ } | Sort-Object Date -Descending)
        if (-not $boots.Count) { $ui.BootCard.Visibility = 'Collapsed'; return }
        $ui.BootCard.Visibility = 'Visible'
        $ui.GridBoots.ItemsSource = $boots
        $b = $boots[0]
        $ss = if ($null -ne $b.Session) { [math]::Min($b.Session, 120) } else { 0 }
        $ui.TxtBootTitle.Text = if ($null -ne $b.Total) { "Dernier démarrage : {0:N0} s jusqu'à l'ouverture de session" -f $b.Total } else { "Dernier démarrage : {0:N0} s jusqu'à l'écran de connexion" -f ($b.Firmware + $b.Loader) }
        $ok = @($boots | Where-Object { $null -ne $_.Total -and $_.Session -lt 180 })
        $ui.TxtBootAvg.Text = if ($ok.Count -ge 2) { "moyenne sur {0} démarrages : {1:N0} s" -f $ok.Count, ($ok | Measure-Object Total -Average).Average } else { '' }
        $ui.BootColFw.Width = New-Object System.Windows.GridLength([math]::Max(0.5, $b.Firmware), 'Star')
        $ui.BootColLd.Width = New-Object System.Windows.GridLength([math]::Max(0.5, $b.Loader), 'Star')
        $ui.BootColSs.Width = New-Object System.Windows.GridLength([math]::Max(0.5, $ss), 'Star')
        $ui.TxtBootFw.Text = "Carte mère (BIOS) : {0:N1} s" -f $b.Firmware
        $ui.TxtBootLd.Text = "Chargement de Windows : {0:N1} s" -f $b.Loader
        $ui.TxtBootSs.Text = if ($null -ne $b.Session) { "Jusqu'à la session : {0:N0} s" -f $b.Session } else { 'Session : non mesurée' }
        $tips = New-Object System.Collections.Generic.List[string]
        $fwAvg = ($boots | Measure-Object Firmware -Average).Average
        if ($fwAvg -ge 12) { $tips.Add(("• Carte mère lente : {0:N0} s (normal 5 à 10 s). BIOS : activer Fast Boot, désactiver CSM et logo." -f $fwAvg)) }
        if ($b.Loader -ge 8) { $tips.Add(("• Windows lent à charger : {0:N1} s (normal 3 à 6 s). Disque lent ou plein, ou Hyper-V / WSL." -f $b.Loader)) }
        if ($null -ne $b.Session -and $b.Session -ge 40) { $tips.Add(("• Session longue : {0:N0} s (saisie du code comprise). Désactiver des programmes ci-dessous." -f $b.Session)) }
        foreach ($c in @($r.Culprits)) { $tips.Add(("• « {0} » : +{1:N1} s ({2} fois en 30 jours)." -f $c.Name, $c.Seconds, $c.Count)) }
        if (-not $tips.Count) { $tips.Add('• Démarrage rapide : rien à améliorer.') }
        if (-not $r.CanReadDetails) { $tips.Add('• Mode administrateur : détail des programmes qui ralentissent.') }
        $ui.TxtBootAdvice.Text = ($tips -join "`n")
    }
    function Load-BootTimes { Start-BgJob 'Get-BootTimes 10' { param($res) try { Show-BootTimes (@($res)[0]) } catch { Write-Log "Démarrage : $_ $($_.ScriptStackTrace)" } } }
    $ui.BtnBootHistory.Add_Click({ $ui.BootHistoryBox.Visibility = if ($ui.BootHistoryBox.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' } })

    # Alertes
    $ui.ChkAlerts.Add_Checked({ if (-not $script:Loading) { Set-Setting 'Alerts' '1' } })
    $ui.ChkAlerts.Add_Unchecked({ if (-not $script:Loading) { Set-Setting 'Alerts' '0' } })
    $ui.CmbAlertTemp.Add_SelectionChanged({
            if ($script:Loading -or $ui.CmbAlertTemp.SelectedIndex -lt 0) { return }
            Set-Setting 'AlertGpuTemp' ([string](75 + 5 * $ui.CmbAlertTemp.SelectedIndex))
            Set-Status "Seuil d'alerte réglé à $(75 + 5 * $ui.CmbAlertTemp.SelectedIndex) °C."
        })

    # =====================================================================
    #  LOGICIELS (winget)
    # =====================================================================
    function Start-WingetConsole([string]$wingetArgs, [string]$title) {
        $wg = Get-WingetPath
        if (-not $wg) { Set-Status "winget n'est pas disponible sur ce PC."; return }
        $code = "`$host.UI.RawUI.WindowTitle = '$title'; [Console]::OutputEncoding = [Text.Encoding]::UTF8; Write-Host 'PC Doctor - $title' -ForegroundColor Cyan; Write-Host 'Certains logiciels peuvent demander une confirmation administrateur ou leur fermeture.' -ForegroundColor Yellow; & '$($wg -replace "'", "''")' $wingetArgs; Write-Host ''; Write-Host 'Termine. Vous pouvez fermer cette fenetre.' -ForegroundColor Green"
        Start-Process -FilePath $script:PowerShellExe -ArgumentList @('-NoProfile', '-NoExit', '-EncodedCommand', (ConvertTo-EncodedCommand $code))
    }

    function Start-SoftwareSearch {
        $script:SoftwareLoaded = $true
        $ui.BtnSwSearch.IsEnabled = $false; $ui.BtnSwAll.IsEnabled = $false
        $ui.SwBar.Visibility = 'Visible'; $ui.SwBar.IsIndeterminate = $true
        $ui.TxtSwStatus.Text = 'Recherche des mises à jour…'
        Start-BgJob 'try { [pscustomobject]@{ Ok = $true; Items = @(Get-WingetUpgrades); Error = $null } } catch { [pscustomobject]@{ Ok = $false; Items = @(); Error = "$_" } }' {
            param($res)
            $o = @($res)[0]
            $ui.SwBar.IsIndeterminate = $false; $ui.SwBar.Visibility = 'Collapsed'
            $ui.BtnSwSearch.IsEnabled = $true
            if (-not $o -or -not $o.Ok) { $ui.TxtSwStatus.Text = "Recherche impossible : $(if ($o) { $o.Error })"; return }
            $items = @($o.Items | Where-Object { $_ })
            $ui.GridSoftware.ItemsSource = $items
            $ui.BtnSwAll.IsEnabled = ($items.Count -gt 0)
            $ui.TxtSwStatus.Text = if ($items.Count) { "$($items.Count) logiciel(s) peuvent être mis à jour." } else { 'Tous vos logiciels sont à jour.' }
            Set-Badge $ui.BadgeSoftware $ui.BadgeSoftwareText $items.Count
        }
    }
    $ui.BtnSwSearch.Add_Click({ Start-SoftwareSearch })
    $ui.BtnSwAll.Add_Click({
            $n = @($ui.GridSoftware.ItemsSource).Count
            $r = [System.Windows.MessageBox]::Show("Mettre à jour les $n logiciels ?`n`nUne fenêtre va afficher la progression. Fermez si possible les programmes concernés (navigateur, launchers…). Certains installeurs demanderont les droits administrateur.", 'Tout mettre à jour', 'YesNo', 'Question')
            if ($r -ne 'Yes') { return }
            Start-WingetConsole 'upgrade --all --include-unknown --source winget --accept-source-agreements --accept-package-agreements' 'Mise a jour des logiciels'
            $ui.TxtSwStatus.Text = 'Mise à jour lancée dans une fenêtre séparée. Cliquez sur « Rechercher » quand elle est terminée.'
        })
    $ui.GridSoftware.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
            param($sender, $e)
            $b = $e.OriginalSource
            if ($b -is [System.Windows.Controls.Button] -and $b.Tag -eq 'sw-update') {
                $id = [string]$b.DataContext.Id
                if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') { return }
                Start-WingetConsole "upgrade --id $id --exact --source winget --accept-source-agreements --accept-package-agreements" "Mise a jour de $id"
                Set-Status "Mise à jour de « $($b.DataContext.Name) » lancée dans une fenêtre séparée."
            }
        })

    # =====================================================================
    #  RÉSEAU
    # =====================================================================
    function Show-Network($n) {
        $ui.TxtNetType.Text = "$($n.Type)$(if ($n.LinkSpeed) { "  ·  $($n.LinkSpeed)" })"
        $det = @("Carte : $($n.Adapter)")
        if ($n.IsWifi -and $null -ne $n.Signal) { $det += "Signal Wi-Fi : $($n.Signal) %" }
        if ($n.Gateway) { $det += "Box / routeur : $($n.Gateway)" }
        $ui.TxtNetDetail.Text = $det -join "`n"
        $ui.GridNet.ItemsSource = @($n.Results)
        $local = @($n.Results | Where-Object { $_.Scope -eq 'local' }) | Select-Object -First 1
        $inet = @($n.Results | Where-Object { $_.Scope -eq 'internet' })
        $best = $inet | Where-Object { $null -ne $_.Avg } | Sort-Object Avg | Select-Object -First 1
        if ($local -and $local.Verdict -ne 'Bon') {
            $ui.TxtNetVerdictTitle.Text = 'Problème entre le PC et la box'
            $ui.TxtNetVerdict.Text = if ($n.IsWifi) { "La liaison Wi-Fi avec la box est instable ($($local.AvgText), pertes $($local.LossText)). Rapprochez le PC de la box, passez sur le Wi-Fi 5 GHz ou, idéalement, branchez un câble Ethernet." } else { "La liaison avec la box n'est pas normale pour un câble ($($local.AvgText), pertes $($local.LossText)). Essayez un autre câble ou un autre port, et redémarrez la box." }
        } elseif (@($inet | Where-Object { $_.Verdict -eq 'Mauvais' }).Count -eq $inet.Count) {
            $ui.TxtNetVerdictTitle.Text = 'Connexion Internet mauvaise'
            $ui.TxtNetVerdict.Text = "Votre réseau local est bon, mais la connexion Internet elle-même est lente ou instable. Redémarrez la box ; si ça continue, contactez votre fournisseur d'accès."
        } elseif (@($inet | Where-Object { $_.Verdict -ne 'Bon' }).Count) {
            $ui.TxtNetVerdictTitle.Text = 'Connexion correcte'
            $ui.TxtNetVerdict.Text = "Ça fonctionne, avec quelques variations (gigue ou pertes ponctuelles). Si ça laggue en jeu aux heures de pointe, c'est souvent le réseau de votre fournisseur."
        } else {
            $ui.TxtNetVerdictTitle.Text = 'Excellente connexion'
            $ui.TxtNetVerdict.Text = "Ping de $($best.AvgText), stable et sans perte. Si un jeu laggue quand même, le problème vient du serveur du jeu ou du PC lui-même (regardez la page Processus)."
        }
        if ($n.IsWifi -and $null -ne $n.Signal -and $n.Signal -lt 60) { $ui.TxtNetVerdict.Text += "`nLe signal Wi-Fi est faible ($($n.Signal) %)." }
        $dns = if ($n.DnsServers.Count) { $n.DnsServers -join ', ' } else { 'automatique' }
        $ui.TxtNetDns.Text = if ($null -eq $n.DnsMs) { "Serveurs DNS : $dns. Mesure impossible." }
        elseif ($n.DnsMs -gt 80) { "Serveurs DNS : $dns. Réponse lente ({0:N0} ms) : passer à Cloudflare (1.1.1.1) ou Google (8.8.8.8) accélère l'ouverture des sites." -f $n.DnsMs }
        else { "Serveurs DNS : $dns. Réponse rapide ({0:N0} ms), rien à changer." -f $n.DnsMs }
    }
    $ui.BtnNetTest.Add_Click({
            $ui.BtnNetTest.IsEnabled = $false
            $ui.NetBar.Visibility = 'Visible'; $ui.NetBar.IsIndeterminate = $true
            $ui.TxtNetStatus.Text = 'Test en cours (environ 10 secondes)…'
            Start-BgJob 'Test-NetworkQuality' {
                param($res)
                $ui.NetBar.IsIndeterminate = $false; $ui.NetBar.Visibility = 'Collapsed'
                $ui.BtnNetTest.IsEnabled = $true
                $n = @($res)[0]
                if (-not $n) { $ui.TxtNetStatus.Text = 'Le test a échoué.'; return }
                Show-Network $n
                $ui.TxtNetStatus.Text = "Test terminé à $(Get-Date -Format 'HH:mm')."
            }
        })

    # =====================================================================
    #  PARAMÈTRES, THÈME ET MISES À JOUR
    # =====================================================================
    function Restart-App {
        if ($script:IsAdmin) { Start-ElevatedSelf }
        else {
            $c = Get-LaunchCommand
            $psi = New-Object Diagnostics.ProcessStartInfo($c.Exe, $c.Args)
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            [void][Diagnostics.Process]::Start($psi)
        }
        $window.Close()
    }
    function Set-Theme([string]$t) {
        if (((Get-Settings)['Theme']) -eq $t) { return }
        Set-Setting 'Theme' $t
        Restart-App
    }
    $ui.BtnThemeLight.Add_Click({ Set-Theme 'light' })
    $ui.BtnThemeDark.Add_Click({ Set-Theme 'dark' })
    $ui.BtnOpenData.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$script:LogDir`"" })
    $ui.SettingsRoot.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $clickHandler)
    $ui.NetRoot.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $clickHandler)
    $ui.ChkCheckUpdates.Add_Checked({ if (-not $script:Loading) { Set-Setting 'CheckUpdates' '1' } })
    $ui.ChkCheckUpdates.Add_Unchecked({ if (-not $script:Loading) { Set-Setting 'CheckUpdates' '0' } })

    $script:UpdateInfo = $null
    function Start-UpdateCheck([bool]$manual) {
        $ui.TxtUpdateStatus.Text = 'Vérification en cours…'
        $code = 'try { $r = Invoke-RestMethod -Uri "https://api.github.com/repos/' + $script:Repo + '/releases/latest" -Headers @{ "User-Agent" = "PCDoctor"; "Accept" = "application/vnd.github+json" } -TimeoutSec 15 -UseBasicParsing; [pscustomobject]@{ Ok = $true; Tag = [string]$r.tag_name; Body = [string]$r.body; Url = [string]$r.html_url; Assets = @($r.assets | ForEach-Object { [pscustomobject]@{ Name = [string]$_.name; Url = [string]$_.browser_download_url } }) } } catch { [pscustomobject]@{ Ok = $false; Error = "$_" } }'
        Start-BgJob $code {
            param($res)
            $o = @($res)[0]
            if (-not $o -or -not $o.Ok) { $ui.TxtUpdateStatus.Text = "Vérification impossible (pas de connexion ?)."; return }
            $remote = $null
            try { $remote = [version]($o.Tag.TrimStart('v', 'V')) } catch {}
            if ($remote -and $remote -gt [version]$script:AppVersion) {
                $script:UpdateInfo = $o
                $ui.UpdateBanner.Visibility = 'Visible'
                $ui.TxtUpdateTitle.Text = "PC Doctor $remote est disponible"
                $ui.TxtUpdateSub.Text = "Vous avez la version $($script:AppVersion). La mise à jour prend quelques secondes et relance l'appli."
                $ui.TxtUpdateStatus.Text = "Nouvelle version disponible : $remote."
                $ui.BtnInstallUpdate.Visibility = 'Visible'
                Set-Badge $ui.BadgeSettings $ui.BadgeSettingsText 1
            } else {
                $ui.TxtUpdateStatus.Text = "Vous avez la dernière version (vérifié à $(Get-Date -Format 'HH:mm'))."
                Set-Badge $ui.BadgeSettings $ui.BadgeSettingsText 0
            }
        }
    }

    function Install-Update {
        $u = $script:UpdateInfo
        if (-not $u) { return }
        $asset = @($u.Assets | Where-Object { $_.Name -like '*.exe' -and $_.Url -like "https://github.com/$($script:Repo)/releases/download/*" }) | Select-Object -First 1
        $expected = if ($u.Body -match '\b([A-Fa-f0-9]{64})\b') { $Matches[1].ToUpper() } else { $null }
        if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath) -or -not $asset -or -not $expected) {
            Start-Process $u.Url
            Set-Status 'Page de la nouvelle version ouverte : téléchargez PC-Doctor.exe et remplacez l''ancien.'
            return
        }
        $r = [System.Windows.MessageBox]::Show("Installer PC Doctor $($u.Tag) ?`n`nLe nouvel exécutable va être téléchargé depuis GitHub, vérifié (SHA-256), puis il remplacera :`n$ExePath`n`nL'appli va se relancer.", 'Mise à jour', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        $ui.BtnUpdateNow.IsEnabled = $false; $ui.BtnInstallUpdate.IsEnabled = $false
        Set-Status 'Téléchargement de la mise à jour…'
        $script:UpdateTmp = "$ExePath.download"
        $script:UpdateExpected = $expected
        $code = "Invoke-WebRequest -UseBasicParsing -Uri '$($asset.Url -replace "'", "''")' -OutFile '$($script:UpdateTmp -replace "'", "''")' -Headers @{ 'User-Agent' = 'PCDoctor' } -TimeoutSec 120; (Get-FileHash -LiteralPath '$($script:UpdateTmp -replace "'", "''")' -Algorithm SHA256).Hash"
        Start-BgJob $code {
            param($res)
            $hash = [string](@($res) | Select-Object -Last 1)
            $ui.BtnUpdateNow.IsEnabled = $true; $ui.BtnInstallUpdate.IsEnabled = $true
            if (-not (Test-Path -LiteralPath $script:UpdateTmp) -or $hash -ne $script:UpdateExpected) {
                Remove-Item -LiteralPath $script:UpdateTmp -Force -ErrorAction SilentlyContinue
                [System.Windows.MessageBox]::Show("Le téléchargement a échoué ou le fichier ne correspond pas à l'empreinte publiée. Rien n'a été modifié.", 'Mise à jour', 'OK', 'Warning') | Out-Null
                return
            }
            try {
                # L'exe est en cours d'utilisation (l'appli tourne dedans) : Windows interdit de l'écraser
                # mais autorise à le renommer. On le met de côté, puis on place le nouveau à sa place.
                # Nom unique : une ancienne copie peut elle-même encore tourner (boîte noire, widget…)
                $old = "$ExePath.$(Get-Date -Format 'yyyyMMddHHmmss').old"
                Move-Item -LiteralPath $ExePath -Destination $old -Force
                try { Move-Item -LiteralPath $script:UpdateTmp -Destination $ExePath -Force }
                catch { Move-Item -LiteralPath $old -Destination $ExePath -Force; throw }
                if ([PCDoctor.BlackBox]::IsRunning()) { [void][PCDoctor.BlackBox]::RequestStop(); Start-Sleep -Milliseconds 2500; Start-BlackBox }
                Start-Process -FilePath $ExePath
                $window.Close()
            } catch {
                Remove-Item -LiteralPath $script:UpdateTmp -Force -ErrorAction SilentlyContinue
                [System.Windows.MessageBox]::Show("Impossible de remplacer le fichier ($($_.Exception.Message)). Téléchargez la nouvelle version depuis la page GitHub.", 'Mise à jour', 'OK', 'Warning') | Out-Null
                Start-Process $script:UpdateInfo.Url
            }
        }
    }
    $ui.BtnUpdateNow.Add_Click({ Install-Update })
    $ui.BtnInstallUpdate.Add_Click({ Install-Update })
    $ui.BtnCheckUpdate.Add_Click({ Start-UpdateCheck $true })

    # --- Widget de bureau ---
    $script:WidgetRunName = 'PCDoctorWidget'
    function Open-Widget {
        $c = Get-LaunchCommand -Widget
        $psi = New-Object Diagnostics.ProcessStartInfo($c.Exe, $c.Args)
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        [void][Diagnostics.Process]::Start($psi)
        Set-Status 'Widget ouvert : déplacez-le à la souris, clic droit pour ses réglages.'
    }
    function Test-WidgetAutostart { try { return [bool](Get-ItemProperty -LiteralPath $script:RunKey -Name $script:WidgetRunName -ErrorAction Stop).$($script:WidgetRunName) } catch { return $false } }
    function Set-WidgetAutostart([bool]$on) {
        if ($on) {
            $c = Get-LaunchCommand -Widget
            New-ItemProperty -LiteralPath $script:RunKey -Name $script:WidgetRunName -Value ("`"{0}`" {1}" -f $c.Exe, $c.Args).Trim() -PropertyType String -Force | Out-Null
        } else { Remove-ItemProperty -LiteralPath $script:RunKey -Name $script:WidgetRunName -ErrorAction SilentlyContinue }
    }
    $ui.BtnWidgetDiag.Add_Click({ Open-Widget })
    $ui.ChkWidgetAutostart.Add_Checked({ if (-not $script:Loading) { Set-WidgetAutostart $true; Set-Status 'Le widget s''affichera au démarrage de Windows.' } })
    $ui.ChkWidgetAutostart.Add_Unchecked({ if (-not $script:Loading) { Set-WidgetAutostart $false; Set-Status 'Le widget ne s''affichera plus au démarrage.' } })

    # Ancienne version mise de côté lors d'une mise à jour : on la supprime (si plus rien ne l'utilise)
    if ($ExePath) {
        $leaf = Split-Path -Leaf $ExePath
        Get-ChildItem -LiteralPath (Split-Path -Parent $ExePath) -Filter "$leaf*.old" -File -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }   # celles encore utilisées restent jusqu'à la prochaine fois
    }

    # --- État initial des réglages ---
    $cfg = Get-Settings
    $ui.ChkWidgetAutostart.IsChecked = Test-WidgetAutostart
    if (Test-WidgetAutostart) { try { Set-WidgetAutostart $true } catch {} }
    $ui.TxtAppVersion.Text = "Version installée : $($script:AppVersion)"
    $ui.TxtVersion.Text = "PC Doctor $($script:AppVersion)"
    $ui.TxtThemeInfo.Text = if ($script:IsDark) { 'Thème sombre activé. Changer de thème relance l''appli.' } else { 'Thème clair activé. Changer de thème relance l''appli.' }
    $ui.TxtDataInfo.Text = "Réglages, journal et enregistrements de la boîte noire : $($script:LogDir)"
    $ui.ChkCheckUpdates.IsChecked = ($cfg['CheckUpdates'] -ne '0')
    # Taille du texte : toute la fenêtre est agrandie (menus et boutons compris)
    $script:TextScales = @(1.0, 1.15, 1.3)
    function Set-TextScale([double]$k) {
        $window.Content.LayoutTransform = New-Object System.Windows.Media.ScaleTransform($k, $k)
        $wa = [System.Windows.SystemParameters]::WorkArea
        $window.MinWidth = [math]::Min(1000 * $k, $wa.Width); $window.MinHeight = [math]::Min(640 * $k, $wa.Height)
        if ($window.Width -lt 1280 * $k) { $window.Width = [math]::Min(1280 * $k, $wa.Width) }
        if ($window.Height -lt 820 * $k) { $window.Height = [math]::Min(820 * $k, $wa.Height) }
    }
    $ts = [Array]::IndexOf(@('100', '115', '130'), [string]$cfg['TextScale']); if ($ts -lt 0) { $ts = 0 }
    $ui.CmbTextScale.SelectedIndex = $ts
    if ($ts -gt 0) { Set-TextScale $script:TextScales[$ts] }
    $ui.CmbTextScale.Add_SelectionChanged({
            if ($script:Loading -or $ui.CmbTextScale.SelectedIndex -lt 0) { return }
            $i = $ui.CmbTextScale.SelectedIndex
            Set-TextScale $script:TextScales[$i]
            Set-Setting 'TextScale' @('100', '115', '130')[$i]
        })
    $ui.ChkAlerts.IsChecked = ($cfg['Alerts'] -ne '0')
    $t = 85; [void][int]::TryParse($cfg['AlertGpuTemp'], [ref]$t)
    $ui.CmbAlertTemp.SelectedIndex = [math]::Max(0, [math]::Min(3, [int](($t - 75) / 5)))
    Set-Badge $ui.BadgeSettings $ui.BadgeSettingsText 0
    if (Test-BlackBoxAutostart) { try { Set-BlackBoxAutostart $true } catch {} }   # met à jour le chemin si l'exe a été déplacé
    $script:Loading = $false
    try { Update-BlackBoxStatus } catch {}

    $window.Add_Loaded({
            Start-FullAnalysis
            Load-Security
            Load-BootTimes
            try { Show-Gaming } catch { Write-Log "Jeu : $_ $($_.ScriptStackTrace)" }
            if ((Get-Settings)['CheckUpdates'] -ne '0') { Start-UpdateCheck $false }
        })
    $window.Add_Closing({
            [PCDoctor.DiskScanner]::Cancel = $true; $script:Timer.Stop()
            if ([PCDoctor.StressTest]::Running) {
                [PCDoctor.StressTest]::Stop('user')
                $w = 0; while ([PCDoctor.StressTest]::Running -and $w -lt 20) { Start-Sleep -Milliseconds 200; $w++ }
                Remove-Item -LiteralPath $script:StressMarker -Force -ErrorAction SilentlyContinue
            }
        })
    try { if (Test-StressCrash) { Show-Page 'stress'; Set-Status 'Le PC s''est coupé pendant le dernier test de stabilité : le problème est reproduit.' } } catch { Write-Log "Test : $_" }

    $script:Timer.Start()
    [void]$window.ShowDialog()
}
catch {
    Write-Log "Erreur fatale : $_ $($_.ScriptStackTrace)"
    [System.Windows.MessageBox]::Show("PC Doctor n'a pas pu démarrer :`n`n$_`n`nDétails dans : $script:LogFile", 'PC Doctor', 'OK', 'Error') | Out-Null
}
