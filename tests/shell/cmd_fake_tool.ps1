# cmd_fake_tool.ps1 - build the stand-in tool tests/shell/cmd_shims.cmd runs in
# place of lsd, bat, rg, fd, uv and a venv's python.exe: a console program that
# prints each argument it was given as [arg], one per line, and exits with the
# code in FAKE_RC (0 when unset). Windows PowerShell's Add-Type compiles it, so
# it splits its command line by the Microsoft C runtime's rules, as the real
# tools do.
param([Parameter(Mandatory = $true)][string]$Out)
$ErrorActionPreference = 'Stop'
$source = @'
public static class FakeTool
{
    public static int Main(string[] args)
    {
        foreach (string a in args) { System.Console.WriteLine("[" + a + "]"); }
        string rc = System.Environment.GetEnvironmentVariable("FAKE_RC");
        return string.IsNullOrEmpty(rc) ? 0 : int.Parse(rc);
    }
}
'@
Add-Type -TypeDefinition $source -OutputAssembly $Out -OutputType ConsoleApplication
