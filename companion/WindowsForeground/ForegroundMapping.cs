// ForegroundMapping — the testable, pure part of the Windows helper contract
// (SPEC §7.2 D/F). It owns:
//   * the canonical executable → app-identity mapping (Code.exe / chrome.exe /
//     explorer.exe), matched strictly by executable *file name*, never by window
//     title or path;
//   * the wire message the helper emits to the paired iPad.
//
// The helper reports a stable *identity* so the iPad can pick the matching
// layout; the concrete keystroke targets a layout references are user-configurable
// and live on the iPad side (SPEC §7.2 F). Nothing here sends HID input.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace WindowsForeground
{
    // The app-specific CONTROL layout the iPad should present. `Generic` is the
    // §7.1 default surface and is also the fallback for unknown executables and
    // for "helper not running / not paired / channel down" (SPEC §7.2 E).
    public enum AppIdentity
    {
        Generic = 0,
        VsCode = 1,
        Chrome = 2,
        Explorer = 3,
    }

    public static class ForegroundMapping
    {
        // Executable file name (case-insensitive) → layout identity. Keys are the
        // bare file names from SPEC §7.2 D. Matching is by executable identity
        // only — never by (user/locale-editable) window title.
        public static readonly Dictionary<string, AppIdentity> Known =
            new(StringComparer.OrdinalIgnoreCase)
            {
                ["Code.exe"] = AppIdentity.VsCode,
                ["chrome.exe"] = AppIdentity.Chrome,
                ["explorer.exe"] = AppIdentity.Explorer,
            };

        // Resolve the foreground executable's full path to a layout identity.
        // Only the file name is trusted; anything not in the configured set is the
        // §7.1 generic layout. A null/empty path (no foreground / access denied)
        // is also generic, so the iPad is never left on a blank layout.
        public static AppIdentity Resolve(string? executablePath)
        {
            if (string.IsNullOrEmpty(executablePath))
            {
                return AppIdentity.Generic;
            }

            string fileName;
            try
            {
                fileName = Path.GetFileName(executablePath);
            }
            catch (ArgumentException)
            {
                return AppIdentity.Generic;
            }

            return Known.TryGetValue(fileName, out var identity) ? identity : AppIdentity.Generic;
        }

        // Stable string token sent on the wire for an identity. The iPad maps this
        // token to a user-configurable layout profile; it is NOT a keystroke.
        public static string Token(AppIdentity identity) => identity switch
        {
            AppIdentity.VsCode => "vscode",
            AppIdentity.Chrome => "chrome",
            AppIdentity.Explorer => "explorer",
            _ => "generic",
        };

        // The one notification the helper ever sends (SPEC §7.2 B):
        //   { "type": "foreground-changed", "identity": "<token>" }
        // Hand-built JSON so the wire contract is exact and needs no reflection /
        // serializer dependency.
        public static string ForegroundChangedJson(AppIdentity identity)
        {
            var sb = new StringBuilder();
            sb.Append("{\"type\":\"foreground-changed\",\"identity\":\"");
            sb.Append(Token(identity));
            sb.Append("\"}");
            return sb.ToString();
        }
    }
}
