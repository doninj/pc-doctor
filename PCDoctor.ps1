<#
    PC Doctor - diagnostic du PC (lenteurs, plantages, espace disque)
    Lancer via "PC Doctor.exe" ou "Lancer PC Doctor.bat".
    Nécessite Windows PowerShell 5.1 (inclus dans Windows 10/11).
#>
param([switch]$SelfTest, [string]$LaunchedFrom)

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
using System.Collections.Generic;
using System.Threading;
using System.Runtime.InteropServices;

namespace PCDoctor {
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
if (-not ('PCDoctor.DiskScanner' -as [type])) { Add-Type -TypeDefinition $csharp -Language CSharp }

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
        $txt = (powercfg /getactivescheme) -join ' '
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
    try { $line = (& $smi ($SmiQuery -split ' ') 2>$null) | Select-Object -First 1 } catch { return $null }
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
        $text = "La RAM tourne à $cfg MT/s alors que le kit est prévu pour $kit MT/s : le profil EXPO/XMP est désactivé. C'est la configuration la plus stable (un peu moins rapide)."
    } elseif ($cfg -gt $jedec -or ($kit -and $kit -gt $base -and $cfg -ge ($kit - 100))) {
        $state = 'On'
        $text = "La RAM tourne à $cfg MT/s, au-dessus de la vitesse standard : le profil EXPO/XMP/DOCP est activé. C'est un overclocking de la RAM, prévu par le fabricant, mais pas toujours stable selon le processeur et la carte mère."
    } else {
        $state = 'Base'
        $text = "La RAM tourne à sa vitesse standard ($cfg MT/s) : pas d'overclocking."
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
    $note = if ($name -match 'X3D') { "Processeur X3D : il ne s'overclocke pas de façon classique. Seuls le PBO et le Curve Optimizer existent dans le BIOS : s'ils ont été réglés, remettez-les sur « Auto » pour tester la stabilité." }
    elseif ($name -match 'Ryzen') { "Processeur Ryzen : l'overclocking se fait dans le BIOS (PBO, Curve Optimizer) ou avec Ryzen Master. Un Curve Optimizer trop agressif provoque des plantages aléatoires : remettez « Auto » pour tester." }
    elseif ($name -match 'i[3579]-1[34]\d{3}') { "Intel Core 13e/14e génération : ces processeurs ont un défaut d'instabilité connu. Mettez absolument le BIOS à jour (microcode 0x12B ou plus récent) et gardez les réglages Intel par défaut." }
    elseif ($name -match 'i[3579]-\d{4,5}K') { "Processeur Intel « K » débloqué : un overclocking ou undervolt (BIOS, Intel XTU, ThrottleStop) peut rendre le PC instable. Remettez les réglages par défaut pour tester." }
    else { "Ce processeur fonctionne à ses réglages d'usine : pas d'overclocking à surveiller." }
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
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
        Background="#FFF4F6FA" Foreground="#FF0F172A" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <SolidColorBrush x:Key="Muted" Color="#FF64748B"/>
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
      <Setter Property="Foreground" Value="#FF64748B"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,4,0,0"/>
      <Setter Property="FontSize" Value="13.5"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="MutedText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FF64748B"/>
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
      <Setter Property="Padding" Value="18,16"/>
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

    <!-- Tableaux -->
    <Style TargetType="DataGrid">
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
            <Border x:Name="Bd" Background="Transparent" CornerRadius="9" Padding="14,11">
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
              <Border x:Name="BadgeDrivers" Style="{StaticResource Badge}" Background="#FFF59E0B" DockPanel.Dock="Right"><TextBlock x:Name="BadgeDriversText" Style="{StaticResource BadgeText}"/></Border>
              <TextBlock Style="{StaticResource NavIcon}" Text="&#xE772;"/><TextBlock Style="{StaticResource NavText}" Text="Pilotes"/>
            </DockPanel>
          </ListBoxItem>
          <ListBoxItem>
            <DockPanel><TextBlock Style="{StaticResource NavIcon}" Text="&#xEC4A;"/><TextBlock Style="{StaticResource NavText}" Text="Performances"/></DockPanel>
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
                <StackPanel>
                  <TextBlock Style="{StaticResource PageTitle}" Text="Diagnostic"/>
                  <TextBlock x:Name="TxtSysInfo" Style="{StaticResource PageSub}" Text="Analyse en cours…"/>
                </StackPanel>
              </DockPanel>

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
                          <TextBlock Text="{Binding Title, Mode=OneWay}" FontWeight="SemiBold" FontSize="14.5" TextWrapping="Wrap"/>
                          <TextBlock Text="{Binding Advice, Mode=OneWay}" TextWrapping="Wrap" Margin="0,3,0,0" Foreground="#FF475569"/>
                        </StackPanel>
                      </DockPanel>
                    </Border>
                    <DataTemplate.Triggers>
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
              <TextBlock Style="{StaticResource PageSub}" Text="Des solutions classées selon ce qui a été détecté sur votre PC. Faites-les dans l'ordre, une à la fois."/>
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
                          <TextBlock Text="{Binding Why, Mode=OneWay}" TextWrapping="Wrap" Foreground="#FF475569" Margin="0,6,0,0"/>
                          <Border Background="#FFF7F9FC" CornerRadius="8" Padding="14,10" Margin="0,12,0,0">
                            <TextBlock Text="{Binding Steps, Mode=OneWay}" TextWrapping="Wrap" LineHeight="21"/>
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

        <!-- PILOTES -->
        <TabItem>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="DriversRoot" Margin="32,28,32,24">
              <TextBlock Style="{StaticResource PageTitle}" Text="Pilotes"/>
              <TextBlock Style="{StaticResource PageSub}" Text="Mettez vos pilotes à jour en quelques clics et repérez les périphériques qui ont un problème."/>

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

        <!-- PERFORMANCES / OVERCLOCKING -->
        <TabItem>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="PerfRoot" Margin="32,28,32,24">
              <TextBlock Style="{StaticResource PageTitle}" Text="Performances et overclocking"/>
              <TextBlock Style="{StaticResource PageSub}" Text="Voyez ce qui est overclocké sur votre PC et testez la stabilité directement d'ici. Tous les réglages sont réversibles."/>
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
                        <TextBlock Style="{StaticResource MutedText}" FontSize="12" TextWrapping="Wrap" Margin="0,6,0,0" Text="Test d'alimentation : à 75 %, la carte évite les pics de consommation (environ 5 % de FPS en moins en jeu). Si les coupures disparaissent, l'alimentation est en cause. Revient à 100 % au redémarrage."/>
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
                    <TextBlock Style="{StaticResource MutedText}" TextWrapping="Wrap" Text="« Performances élevées » garde le processeur prêt à tout moment (un peu plus de consommation)."/>
                    <WrapPanel Margin="0,12,0,0">
                      <Button Content="Équilibré" Tag="power:balanced" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                      <Button Content="Performances élevées" Tag="power:high" Style="{StaticResource Secondary}" Margin="0,0,8,6"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
              </Grid>
            </StackPanel>
          </ScrollViewer>
        </TabItem>

        <!-- DEMARRAGE -->
        <TabItem>
          <DockPanel Margin="32,28,32,20">
            <StackPanel DockPanel.Dock="Top">
              <TextBlock Style="{StaticResource PageTitle}" Text="Programmes au démarrage"/>
              <TextBlock x:Name="TxtStartupInfo" Style="{StaticResource PageSub}"/>
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
                          <TextBlock Text="{Binding Sub, Mode=OneWay}" Foreground="#FF94A3B8" FontSize="11.5" TextTrimming="CharacterEllipsis"/>
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
              <TextBlock Style="{StaticResource PageSub}" Text="Programmes regroupés par nom (tous les onglets Chrome ensemble, par exemple). Cliquez sur « Actualiser » au moment où le PC rame pour voir le coupable."/>
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
                          <TextBlock Foreground="#FF94A3B8" FontSize="11.5"><Run Text="{Binding Name, Mode=OneWay}"/><Run Text=".exe  ·  "/><Run Text="{Binding Count, Mode=OneWay}"/><Run Text=" instance(s)"/></TextBlock>
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
                  <TextBlock Style="{StaticResource PageSub}" Text="Écrans bleus, coupures, logiciels qui plantent et erreurs disque des 30 derniers jours (journaux de Windows)."/>
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
              <TextBlock Style="{StaticResource PageSub}" Text="Trouvez quels dossiers et quels fichiers prennent le plus de place. Double-cliquez sur un dossier pour entrer dedans."/>
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
              <TextBlock Style="{StaticResource PageSub}" Text="Fichiers jetables qui prennent de la place. Rien n'est supprimé sans votre confirmation."/>
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

function New-PCDoctorWindow {
    [xml]$x = $xamlText
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
    "--- Interface ---"
    $built = New-PCDoctorWindow
    "Fenêtre OK, $($built.UI.Count) éléments nommés"
    return
}

# ---------------------------------------------------------------------------
#  Application
# ---------------------------------------------------------------------------
try {
    $built = New-PCDoctorWindow
    $window = $built.Window
    $here = Split-Path -Parent $script:ScriptPath
    foreach ($logo in @((Join-Path $here 'PCDoctor.png'), (Join-Path $here 'build\PCDoctor.png'))) {
        if (Test-Path -LiteralPath $logo) {
            try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri $logo)) } catch {}
            break
        }
    }
    $script:ui = $built.UI
    $ui = $script:ui
    $script:Brush = New-Object System.Windows.Media.BrushConverter
    function Get-Brush([string]$hex) { $script:Brush.ConvertFromString($hex) }

    $script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($script:IsAdmin) {
        $ui.TxtAdmin.Text = 'Mode administrateur'
        $ui.AdminDot.Fill = Get-Brush '#FF22C55E'
        $ui.TxtAdminHint.Text = 'Accès complet : tout peut être analysé et modifié.'
        $ui.BtnElevate.Visibility = 'Collapsed'
    }

    function Set-Status([string]$t) { $script:ui.TxtStatus.Text = $t }

    $script:Pages = @{ diag = 0; solutions = 1; drivers = 2; perf = 3; startup = 4; procs = 5; crashes = 6; disk = 7; clean = 8 }
    function Show-Page([string]$name) { if ($script:Pages.ContainsKey($name)) { $ui.NavList.SelectedIndex = $script:Pages[$name] } }
    $script:DriversLoaded = $false
    $ui.NavList.Add_SelectionChanged({
            $i = $ui.NavList.SelectedIndex
            if ($i -lt 0) { return }
            $ui.Tabs.SelectedIndex = $i
            if ($i -eq $script:Pages['drivers'] -and -not $script:DriversLoaded) { Load-Drivers }
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
& ([scriptblock]::Create(`$s)) -LaunchedFrom `$p
"@
        Start-Process -FilePath $script:PowerShellExe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-EncodedCommand', (ConvertTo-EncodedCommand $boot))
    }

    # --- Actions déclenchées par les boutons des constats / solutions -------
    function Invoke-Action([string]$id) {
        if (-not $id) { return }
        if ($id -like 'goto:*') { Show-Page $id.Substring(5); return }
        if ($id -like 'url:*') { Start-Process $id.Substring(4); return }
        if ($id -like 'ms-settings:*') { Start-Process $id; return }
        if ($id -like 'gpu-pl:*') { Set-GpuPowerLimit ([int]$id.Substring(7)); return }
        if ($id -like 'power:*') { Set-PowerPlan $id.Substring(6); return }
        switch ($id) {
            'gpu-update' { Open-GpuUpdater }
            'gpu-site' { Start-Process (Get-GpuDriverUrl) }
            'devmgmt' { Start-Process (Get-SysExe 'devmgmt.msc') }
            'chipset' { Start-Process 'https://www.amd.com/fr/support/download/drivers.html' }
            'fastboot-off' { Set-FastStartup $false }
            'fastboot-on' { Set-FastStartup $true }
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
        try { $t = (powercfg.exe /getactivescheme) -join ' '; if ($t -match '\(([^)]+)\)') { return $Matches[1] } } catch {}
        return 'Inconnu'
    }
    function Set-PowerPlan([string]$which) {
        $guid = if ($which -eq 'high') { '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' } else { '381b4222-f694-41f0-9685-ff5bb260df2e' }
        try { $null = powercfg.exe /setactive $guid } catch {}
        $t = ''
        try { $t = (powercfg.exe /getactivescheme) -join ' ' } catch {}
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
            $ui.TxtGpuTempMax.Text = "max {0:N0} °C depuis l'ouverture de PC Doctor" -f $script:GpuMaxTemp
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
            $ui.TxtGpuLimit.Text = "Limite actuelle : {0:N0} W, soit {1:N0} % de la normale ({2:N0} W)." -f $g.PowerLimit, $pct, $g.PowerDefault
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
                'On' { $ui.RamPillText.Text = 'EXPO / XMP activé (overclocking)'; $ui.RamPill.Background = Get-Brush '#FFFFF1DB'; $ui.RamPillText.Foreground = Get-Brush '#FFB45309' }
                'Off' { $ui.RamPillText.Text = 'EXPO / XMP désactivé'; $ui.RamPill.Background = Get-Brush '#FFE3F7EA'; $ui.RamPillText.Foreground = Get-Brush '#FF15803D' }
                default { $ui.RamPillText.Text = 'Vitesse standard'; $ui.RamPill.Background = Get-Brush '#FFE8EFFE'; $ui.RamPillText.Foreground = Get-Brush '#FF3B6EF5' }
            }
            $adv = $m.XmpText
            if ($m.XmpState -eq 'On' -and @($d.Crashes | Where-Object { $_ -and $_.Category -eq 'Arrêt brutal' }).Count) { $adv += " Avec les coupures détectées, désactivez-le quelques jours pour tester (bouton ci-dessous, puis voir les étapes dans Solutions)." }
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
            $ui.TxtOcToolsAdvice.Text = "Si vous avez réglé un overclocking ou un undervolt avec ces logiciels, cliquez sur « Reset » dedans et désactivez l'application des réglages au démarrage, le temps de tester la stabilité."
        } else {
            $ui.TxtOcTools.Text = 'Aucun détecté'
            $ui.TxtOcToolsAdvice.Text = "Ni MSI Afterburner, ni Ryzen Master, ni Intel XTU n'ont été trouvés : pas d'overclocking logiciel sur ce PC. Un éventuel overclocking ne peut venir que du BIOS (EXPO/XMP, PBO)."
        }
        $ui.TxtPowerPlan.Text = if ($d.Summary.PowerPlanName) { $d.Summary.PowerPlanName } else { Get-PowerPlanName }
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

    $window.Add_Loaded({ Start-FullAnalysis })
    $window.Add_Closing({ [PCDoctor.DiskScanner]::Cancel = $true; $script:Timer.Stop() })

    $script:Timer.Start()
    [void]$window.ShowDialog()
}
catch {
    Write-Log "Erreur fatale : $_ $($_.ScriptStackTrace)"
    [System.Windows.MessageBox]::Show("PC Doctor n'a pas pu démarrer :`n`n$_`n`nDétails dans : $script:LogFile", 'PC Doctor', 'OK', 'Error') | Out-Null
}
