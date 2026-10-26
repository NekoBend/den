# cmd_fake_tool.ps1 - build the stand-in tool tests/shell/cmd_shims.cmd runs in
# place of lsd, bat, rg, fd, uv, pip and python: a console program that prints
# each argument it was given as [arg], one per line, and exits with the code in
# FAKE_RC (0 when unset). With FAKE_SELF set it first prints [@<folder>], the
# name of the folder it runs from, which tells copies of it apart. As uv, it
# answers `uv python find --system --no-config` with the path in
# FAKE_FIND_SYSTEM (--no-managed-python) or FAKE_FIND_MANAGED
# (--managed-python), and fails when that is unset or either flag is missing.
# Windows PowerShell's Add-Type compiles it, so it splits its command line by
# the Microsoft C runtime's rules, as the real tools do.
param([Parameter(Mandatory = $true)][string]$Out)
$ErrorActionPreference = 'Stop'
$source = @'
public static class FakeTool
{
    public static int Main(string[] args)
    {
        if (args.Length >= 2 && args[0] == "python" && args[1] == "find")
        {
            if (System.Array.IndexOf(args, "--system") < 0 || System.Array.IndexOf(args, "--no-config") < 0) { return 3; }
            string key = System.Array.IndexOf(args, "--managed-python") >= 0 ? "FAKE_FIND_MANAGED" : "FAKE_FIND_SYSTEM";
            string found = System.Environment.GetEnvironmentVariable(key);
            if (string.IsNullOrEmpty(found)) { return 2; }
            System.Console.WriteLine(found);
            return 0;
        }
        if (!string.IsNullOrEmpty(System.Environment.GetEnvironmentVariable("FAKE_SELF")))
        {
            string dir = System.AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            System.Console.WriteLine("[@" + System.IO.Path.GetFileName(dir) + "]");
        }
        foreach (string a in args) { System.Console.WriteLine("[" + a + "]"); }
        string rc = System.Environment.GetEnvironmentVariable("FAKE_RC");
        return string.IsNullOrEmpty(rc) ? 0 : int.Parse(rc);
    }
}
'@
Add-Type -TypeDefinition $source -OutputAssembly $Out -OutputType ConsoleApplication
