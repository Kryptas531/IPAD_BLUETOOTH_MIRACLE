// ForegroundWatcher — detects which executable owns the foreground window
// (SPEC §7.2 D). Pure Win32 queries:
//
//   GetForegroundWindow → GetWindowThreadProcessId → OpenProcess →
//   QueryFullProcessImageNameW
//
// Only the executable *file name* is ever handed to ForegroundMapping; no
// window title and no other process data is read or reported. Any failure
// (no foreground window, access denied, protected process) yields null so the
// iPad always falls back to the generic layout (§7.2 E).
// Nothing in this file sends input of any kind.
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace WindowsForeground
{
    public sealed class ForegroundWatcher
    {
        private const uint ProcessQueryLimitedInformation = 0x1000;

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool QueryFullProcessImageNameW(IntPtr hProcess, int dwFlags, StringBuilder lpExeName, ref int lpdwSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        // Full path of the executable that owns the foreground window, or null on any
        // detection failure (no foreground window, access denied, protected process).
        // The caller resolves it through the user's layout document; the path itself is
        // never sent to the iPad (SPEC §7.2 D/G).
        public string? CurrentExecutablePath()
        {
            try
            {
                IntPtr hwnd = GetForegroundWindow();
                if (hwnd == IntPtr.Zero)
                {
                    return null;
                }

                GetWindowThreadProcessId(hwnd, out uint processId);
                if (processId == 0)
                {
                    return null;
                }

                IntPtr hProcess = OpenProcess(ProcessQueryLimitedInformation, false, processId);
                if (hProcess == IntPtr.Zero)
                {
                    // Access denied / protected process: unknown ⇒ generic.
                    return null;
                }

                try
                {
                    var buffer = new StringBuilder(1024);
                    int size = buffer.Capacity;
                    if (!QueryFullProcessImageNameW(hProcess, 0, buffer, ref size))
                    {
                        return null;
                    }

                    // Executable path is used ONLY to extract the file name for the
                    // configured mapping; the path itself is never sent.
                    return buffer.ToString(0, size);
                }
                finally
                {
                    CloseHandle(hProcess);
                }
            }
            catch (Exception)
            {
                // Detection problems must never break the iPad experience.
                return null;
            }
        }
    }
}
