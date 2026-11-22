using System.Runtime.InteropServices;

// Media Foundation and Direct3D are system libraries: looked up in System32 only, never beside the program.
[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
