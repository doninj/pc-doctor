// Lanceur de PC Doctor.
// Le script PowerShell est intégré à l'exe et exécuté directement à l'intérieur du processus
// (moteur PowerShell de Windows) : aucun powershell.exe caché, aucun contournement de la
// stratégie d'exécution. Le script et le logo sont aussi copiés dans %LOCALAPPDATA%\PCDoctor\app
// (le logo sert à l'interface ; le script n'est jamais relu depuis le disque par l'exe).
using System;
using System.Collections.ObjectModel;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("PC Doctor")]
[assembly: AssemblyProduct("PC Doctor")]
[assembly: AssemblyDescription("Diagnostic du PC : lenteurs, plantages, pilotes, espace disque")]
[assembly: AssemblyCompany("PC Doctor (open source)")]
[assembly: AssemblyCopyright("Licence MIT")]
[assembly: AssemblyVersion("2.3.1.0")]
[assembly: AssemblyFileVersion("2.3.1.0")]

static class Program {
    [STAThread]
    static int Main(string[] args) {
        try {
            string dir = Path.Combine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PCDoctor"), "app");
            Directory.CreateDirectory(dir);
            string scriptPath = Path.Combine(dir, "PCDoctor.ps1");
            byte[] scriptBytes = Resource("PCDoctor.ps1");
            Save(scriptBytes, scriptPath);
            Save(Resource("PCDoctor.png"), Path.Combine(dir, "PCDoctor.png"));

            // Le texte exécuté vient de l'exe lui-même, pas du fichier copié sur le disque
            string text = new UTF8Encoding(false).GetString(scriptBytes).TrimStart('﻿');
            bool monitor = Array.IndexOf(args, "--monitor") >= 0;
            bool widget = Array.IndexOf(args, "--widget") >= 0;

            InitialSessionState iss = InitialSessionState.CreateDefault();
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss)) {
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (PowerShell ps = PowerShell.Create()) {
                    ps.Runspace = rs;
                    ps.AddScript(text)
                      .AddParameter("LaunchedFrom", scriptPath)
                      .AddParameter("ExePath", Assembly.GetExecutingAssembly().Location);
                    if (monitor) ps.AddParameter("Monitor", true);
                    else if (widget) ps.AddParameter("Widget", true);
                    ps.Invoke();
                    if (ps.HadErrors && ps.Streams.Error.Count > 0 && !monitor) {
                        Log(ps.Streams.Error);
                    }
                }
            }
            return 0;
        } catch (Exception ex) {
            MessageBox.Show("PC Doctor n'a pas pu démarrer :\n\n" + ex.Message, "PC Doctor", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    static byte[] Resource(string name) {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)) {
            if (s == null) return new byte[0];
            byte[] data = new byte[s.Length];
            int read = 0;
            while (read < data.Length) {
                int n = s.Read(data, read, data.Length - read);
                if (n <= 0) break;
                read += n;
            }
            return data;
        }
    }

    static void Save(byte[] data, string path) {
        if (data.Length == 0) return;
        try {
            if (File.Exists(path)) {
                byte[] old = File.ReadAllBytes(path);
                if (old.Length == data.Length) {
                    bool same = true;
                    for (int i = 0; i < data.Length; i++) { if (old[i] != data[i]) { same = false; break; } }
                    if (same) return;
                }
            }
            File.WriteAllBytes(path, data);
        } catch { }
    }

    static void Log(System.Collections.Generic.IEnumerable<ErrorRecord> errors) {
        try {
            string log = Path.Combine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PCDoctor"), "PCDoctor.log");
            StringBuilder sb = new StringBuilder();
            foreach (ErrorRecord e in errors) sb.AppendLine("[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] Lanceur : " + e.ToString());
            File.AppendAllText(log, sb.ToString(), Encoding.UTF8);
        } catch { }
    }
}
