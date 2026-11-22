using System.Runtime.InteropServices;

// Every Windows library this assembly calls is a system one: looked up in System32 only, never in the folder the
// program was started from (an elevated setup run from a build folder would otherwise load a planted netapi32 or slc).
[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
