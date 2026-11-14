// Lanceur de PC Doctor : contient le script et le logo, les extrait dans
// %LOCALAPPDATA%\PCDoctor\app puis démarre l'interface sans fenêtre console.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("PC Doctor")]
[assembly: AssemblyProduct("PC Doctor")]
[assembly: AssemblyDescription("Diagnostic du PC : lenteurs, plantages, pilotes, espace disque")]
[assembly: AssemblyVersion("2.2.0.0")]
[assembly: AssemblyFileVersion("2.2.0.0")]

static class Program {
    [STAThread]
    static int Main(string[] args) {
        try {
            string dir = Path.Combine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PCDoctor"), "app");
            Directory.CreateDirectory(dir);
            string script = Path.Combine(dir, "PCDoctor.ps1");
            Extract("PCDoctor.ps1", script);
            Extract("PCDoctor.png", Path.Combine(dir, "PCDoctor.png"));

            string ps = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            string self = Assembly.GetExecutingAssembly().Location;
            bool monitor = Array.IndexOf(args, "--monitor") >= 0;   // boîte noire (icône de notification, sans fenêtre)
            string psArgs = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\" -ExePath \"" + self + "\"";
            if (monitor) psArgs += " -Monitor";
            ProcessStartInfo psi = new ProcessStartInfo(ps, psArgs);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = dir;
            Process.Start(psi);
            return 0;
        } catch (Exception ex) {
            MessageBox.Show("PC Doctor n'a pas pu démarrer :\n\n" + ex.Message, "PC Doctor", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    static void Extract(string name, string path) {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)) {
            if (s == null) return;
            byte[] data = new byte[s.Length];
            int read = 0;
            while (read < data.Length) {
                int n = s.Read(data, read, data.Length - read);
                if (n <= 0) break;
                read += n;
            }
            if (File.Exists(path)) {
                byte[] old = File.ReadAllBytes(path);
                if (old.Length == data.Length) {
                    bool same = true;
                    for (int i = 0; i < data.Length; i++) { if (old[i] != data[i]) { same = false; break; } }
                    if (same) return;
                }
            }
            File.WriteAllBytes(path, data);
        }
    }
}
