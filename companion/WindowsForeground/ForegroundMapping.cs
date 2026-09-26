// ForegroundMapping — the testable, pure part of the Windows helper contract
// (SPEC §7.2 D/F). It owns:
//   * the user-configurable layout document (profiles: executable file names →
//     layout id, plus the labelled actions each layout offers),
//   * the chord / chord-sequence / typed-text target validation for that document,
//   * the wire message the helper emits to the paired iPad.
//
// SPEC §7.2 F: the executable→layout mapping and every labelled action are data,
// not code. The three canonical profiles (VS Code / Chrome / File Explorer) ship
// unchanged in DefaultJson below; a user adds an app mapping or edits, adds,
// renames or reorders actions by editing the profiles.json the helper creates next
// to its data — no source change and no rebuild.
//
// The concrete keystroke target each action sends lives on the iPad side
// (BTRemote/WindowsForeground.swift + HIDInput.swift) and must stay inside the
// existing HID keyboard report set; this file only validates it. Nothing here ever
// sends HID input.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace WindowsForeground
{
    // ── SPEC §7.2 F data model (mirrors BTRemote/WindowsForeground.swift) ──

    // One user-configurable action of a layout: a label plus exactly one HID-compatible
    // target. `chord` is a single chord ("Ctrl+Shift+P", "F5"), `sequence` an ordered
    // list of chords (["Ctrl+K", "Ctrl+O"]), `text` a literal string/path to type, and
    // `settings` the iPad app-settings key holding the chord the user entered for one
    // of the six project/folder targets. Only targets that resolve to existing HID key
    // reports may be used; an unconfigured or unparseable target sends nothing.
    public sealed class LayoutActionData
    {
        [JsonPropertyName("label")] public string Label { get; set; } = string.Empty;
        [JsonPropertyName("chord")] public string? Chord { get; set; }
        [JsonPropertyName("sequence")] public List<string>? Sequence { get; set; }
        [JsonPropertyName("text")] public string? Text { get; set; }
        [JsonPropertyName("settings")] public string? Settings { get; set; }
    }

    // One user-configurable executable→layout mapping: `id` is the token the helper
    // reports (SPEC §7.2 B/D), `title` names the layout on the iPad, `executables` the
    // executable file names that resolve to it and `actions` the ordered labelled
    // actions it offers.
    public sealed class LayoutProfileData
    {
        [JsonPropertyName("id")] public string Id { get; set; } = string.Empty;
        [JsonPropertyName("title")] public string Title { get; set; } = string.Empty;
        [JsonPropertyName("executables")] public List<string> Executables { get; set; } = new();
        [JsonPropertyName("actions")] public List<LayoutActionData> Actions { get; set; } = new();
    }

    // The whole user-configurable configuration: the ordered list of app profiles.
    public sealed class LayoutDocumentData
    {
        [JsonPropertyName("profiles")] public List<LayoutProfileData> Profiles { get; set; } = new();
    }

    public static class ForegroundMapping
    {
        // The identity used when nothing is configured, unknown, unavailable or the
        // channel is down: "keep the generic §7.1 layout". It is reserved for exactly
        // that meaning, so it is never a user-configurable profile id.
        public const string GenericToken = "generic";

        // SPEC §7.2 B/F: the helper sends `"identity":"<token>"` where <token> is a
        // profile id the user typed, so a profile id must be a single safe token that
        // can never break the JSON message or impersonate the reserved fallback:
        // one or more ASCII letters, digits, '_' '-' or '.' — no spaces, quotes,
        // backslashes, braces, newlines or any other punctuation, and never
        // `generic`/`GENERIC`/other case, which stays the "no app layout" identity.
        public static bool IsSafeProfileId(string? id)
        {
            string value = (id ?? string.Empty).Trim();
            if (value.Length == 0 || string.Equals(value, GenericToken, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }
            foreach (char c in value)
            {
                bool asciiWord = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
                if (!asciiWord && c != '_' && c != '-' && c != '.')
                {
                    return false;
                }
            }
            return true;
        }

        // The shipped default document: the canonical three executable→layout mappings
        // (Code.exe → vscode, chrome.exe → chrome, explorer.exe → explorer) with the
        // exact SPEC §7.2 F labels, and the six project/folder targets left
        // unconfigured (`"settings"` points at an iPad app-settings key).
        //
        // This JSON text is the same document the iPad ships as
        // `AppLayouts.defaultJSON` in `BTRemote/WindowsForeground.swift`; the two
        // copies must stay identical so the file the user edits on Windows can be
        // copied into the iPad's "App layouts (JSON)" editor.
        public const string DefaultJson = """
        {
          "profiles": [
            {
              "id": "vscode",
              "title": "VS Code",
              "executables": ["Code.exe"],
              "actions": [
                { "label": "New Window", "chord": "Ctrl+Shift+N" },
                { "label": "Open Folder", "sequence": ["Ctrl+K", "Ctrl+O"] },
                { "label": "Frost Pi", "settings": "BTRemote.shortcutFrostPi" },
                { "label": "SideChatAI", "settings": "BTRemote.shortcutSideChatAI" },
                { "label": "Explorer", "chord": "Ctrl+Shift+E" },
                { "label": "Source Control", "chord": "Ctrl+Shift+G" },
                { "label": "New Terminal", "chord": "Ctrl+`" },
                { "label": "Close Saved", "chord": "Ctrl+W" },
                { "label": "Split Editor Right", "chord": "Ctrl+\\" },
                { "label": "Move to the editor", "chord": "Ctrl+1" },
                { "label": "Quick Open Browser Tab", "settings": "BTRemote.shortcutQuickOpenBrowserTab" }
              ]
            },
            {
              "id": "chrome",
              "title": "Chrome",
              "executables": ["chrome.exe"],
              "actions": [
                { "label": "New Tab", "chord": "Ctrl+T" },
                { "label": "Close Tab", "chord": "Ctrl+W" },
                { "label": "Reload", "chord": "Ctrl+R" },
                { "label": "Focus Address Bar", "chord": "Ctrl+L" },
                { "label": "Back", "chord": "Alt+Left" },
                { "label": "Forward", "chord": "Alt+Right" },
                { "label": "History", "chord": "Ctrl+H" },
                { "label": "Show Bookmarks", "chord": "Ctrl+Shift+B" },
                { "label": "Full Screen", "chord": "F11" }
              ]
            },
            {
              "id": "explorer",
              "title": "File Explorer",
              "executables": ["explorer.exe"],
              "actions": [
                { "label": "New Window", "chord": "Ctrl+N" },
                { "label": "New Tab", "chord": "Ctrl+T" },
                { "label": "This PC", "settings": "BTRemote.shortcutThisPC" },
                { "label": "Documents", "settings": "BTRemote.shortcutDocuments" },
                { "label": "Downloads", "settings": "BTRemote.shortcutDownloads" },
                { "label": "Search", "chord": "Ctrl+E" },
                { "label": "Select All", "chord": "Ctrl+A" },
                { "label": "New Folder", "chord": "Ctrl+Shift+N" },
                { "label": "Rename", "chord": "F2" }
              ]
            }
          ]
        }
        """;

        // Loads the user's document from `path`. When the file does not exist the
        // shipped defaults are written to it (so the user has an editable file) and
        // used. A file that cannot be parsed is reported and the shipped defaults are
        // used instead, so a broken edit never leaves the iPad without a layout.
        public static LayoutDocumentData LoadDocument(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    LayoutDocumentData? userDocument =
                        JsonSerializer.Deserialize<LayoutDocumentData>(File.ReadAllText(path));
                    if (userDocument is { Profiles.Count: > 0 })
                    {
                        return userDocument;
                    }
                    Console.WriteLine("[windows-foreground] " + path +
                                      " is empty or not a valid layout document; using the shipped defaults.");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[windows-foreground] could not read {path} ({ex.GetType().Name}: " +
                                  ex.Message + "); using the shipped defaults.");
            }

            LayoutDocumentData defaults = DefaultDocument();
            try
            {
                if (!File.Exists(path))
                {
                    File.WriteAllText(path, DefaultJson);
                    Console.WriteLine("[windows-foreground] wrote the default layout document to " + path +
                                      " — edit it to add apps or change actions, and copy the same JSON into the" +
                                      " iPad's \"App layouts (JSON)\" setting.");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[windows-foreground] could not write {path} ({ex.GetType().Name}: " +
                                  ex.Message + "); continuing with the built-in defaults.");
            }
            return defaults;
        }

        // The shipped defaults, parsed from DefaultJson. If that ever failed to parse
        // the helper still runs; an empty document just means "always generic".
        public static LayoutDocumentData DefaultDocument() =>
            JsonSerializer.Deserialize<LayoutDocumentData>(DefaultJson) ?? new LayoutDocumentData();

        // Resolve the foreground executable to a layout token. Only executable file
        // names configured in the document are matched — never a window title, never a
        // path outside the configured set. Anything else (unknown app, no foreground
        // window, access denied) is `generic`, so the iPad falls back to §7.1 (§7.2 E)
        // and no arbitrary process information ever reaches the iPad (§7.2 G).
        public static string ResolveToken(LayoutDocumentData? document, string? executablePath)
        {
            if (document == null || string.IsNullOrEmpty(executablePath))
            {
                return GenericToken;
            }

            string fileName;
            try
            {
                fileName = Path.GetFileName(executablePath);
            }
            catch (ArgumentException)
            {
                return GenericToken;
            }

            foreach (LayoutProfileData profile in document.Profiles)
            {
                foreach (string executable in profile.Executables ?? new List<string>())
                {
                    if (!string.IsNullOrWhiteSpace(executable) &&
                        string.Equals(executable.Trim(), fileName, StringComparison.OrdinalIgnoreCase))
                    {
                        string id = (profile.Id ?? string.Empty).Trim();
                        // A profile whose id is not one safe token (or which claims the
                        // reserved `generic` id) is never reported: such an id could break
                        // the JSON message or replace the §7.1 fallback layout on the iPad.
                        return IsSafeProfileId(id) ? id : GenericToken;
                    }
                }
            }
            return GenericToken;
        }

        // The one notification the helper ever sends (SPEC §7.2 B):
        //   { "type": "foreground-changed", "identity": "<token>" }
        // Hand-built JSON so the wire contract is exact and needs no reflection or
        // serializer on the sending side. The token is a profile id, never a path,
        // title or keystroke, and only an id that passed IsSafeProfileId (or the
        // reserved generic token itself) can ever be written: anything else is sent as
        // `generic`, so a malformed user id can neither corrupt the message nor select
        // an app layout.
        public static string ForegroundChangedJson(string token)
        {
            // Never emit a token the grammar above rejected: an id containing a quote,
            // a backslash, a newline or a space would produce malformed JSON or a token
            // the iPad cannot resolve, and an id of `generic` would let a user profile
            // replace the required §7.1 fallback. Both cases send the generic identity.
            string value = (token ?? string.Empty).Trim();
            string safe = IsSafeProfileId(value) ? value : GenericToken;
            StringBuilder sb = new();
            sb.Append("{\"type\":\"foreground-changed\",\"identity\":\"");
            sb.Append(safe);
            sb.Append("\"}");
            return sb.ToString();
        }
    }

    // SPEC §7.2 F: the action targets a user may configure must be things the shipped
    // HID keyboard path can already send. This is the same table the iPad uses
    // (BTRemote/WindowsForeground.swift `UserTargets`, whose key names mirror the
    // HID keycode enum and whose characters mirror the `HIDInput` ASCII map), kept here
    // so the user gets the error on Windows, at the machine where the JSON is edited.
    public static class LayoutValidator
    {
        // Chord names accepted in the layout document, mapped onto keycodes that already
        // exist in the HID key tables (no new keycodes).
        public static readonly HashSet<string> KeyNames = new(StringComparer.OrdinalIgnoreCase)
        {
            "enter", "return", "esc", "escape", "tab", "space", "backspace",
            "delete", "insert", "home", "end", "pageup", "pagedown",
            "up", "down", "left", "right",
            "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
        };

        // Modifier names accepted in the layout document (left-hand HID modifiers only —
        // the only modifier set the shipped HID keyboard reports already use).
        public static readonly HashSet<string> ModifierNames = new(StringComparer.OrdinalIgnoreCase)
        {
            "ctrl", "control", "shift", "alt", "option",
            "win", "windows", "cmd", "command", "meta",
        };

        // Characters the existing `HIDInput`/`mapASCII` table can type: a-z, A-Z, 0-9
        // plus the symbols of the shipped ASCII table. A `text` target may only contain
        // these, because no new keycodes may be introduced (SPEC §7.2 F).
        public static readonly HashSet<char> TypeableCharacters = new()
        {
            'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm',
            'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
            'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
            'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
            '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
            ' ', '\n', '\r', '\t', '-', '_', '=', '+', '[', '{', ']', '}',
            '\\', '|', ';', ':', '\'', '"', '`', '~', ',', '<', '.', '>', '/', '?', '!',
            '@', '#', '$', '%', '^', '&', '*', '(', ')',
        };

        // True when `chord` parses into existing HID reports: every token before the last
        // must be a known modifier name and the last token a known key name or a single
        // typeable ASCII character. `reason` explains the first failure.
        public static bool TryValidateChord(string? chord, out string reason)
        {
            reason = string.Empty;
            string value = (chord ?? string.Empty).Trim();
            if (value.Length == 0)
            {
                reason = "target is empty";
                return false;
            }

            List<string> tokens = new();
            foreach (string token in value.Split('+'))
            {
                string trimmed = token.Trim();
                if (trimmed.Length > 0)
                {
                    tokens.Add(trimmed);
                }
            }
            if (tokens.Count == 0)
            {
                reason = "target \"" + value + "\" has no key";
                return false;
            }

            string key = tokens[tokens.Count - 1];
            for (int i = 0; i < tokens.Count - 1; i++)
            {
                if (!ModifierNames.Contains(tokens[i]))
                {
                    reason = "unknown modifier \"" + tokens[i] + "\" in chord \"" + value + "\"";
                    return false;
                }
            }
            if (KeyNames.Contains(key))
            {
                return true;
            }
            if (key.Length == 1 && TypeableCharacters.Contains(key[0]))
            {
                return true;
            }
            reason = "unknown key \"" + key + "\" in chord \"" + value + "\"";
            return false;
        }

        // True when every character of a `text` target can be typed with the existing
        // ASCII-to-keycode mapping.
        public static bool TryValidateText(string? text, out string reason)
        {
            reason = string.Empty;
            string value = text ?? string.Empty;
            if (value.Length == 0)
            {
                reason = "target is empty";
                return false;
            }
            foreach (char c in value)
            {
                if (!TypeableCharacters.Contains(c))
                {
                    reason = "character \"" + c + "\" cannot be typed with the existing keymap";
                    return false;
                }
            }
            return true;
        }

        // Checks the whole document and returns a human-readable issue per problem found
        // (empty list = the configuration is usable). Called by Program at start so the
        // user sees on Windows what would silently do nothing on the iPad.
        public static List<string> Validate(LayoutDocumentData document)
        {
            List<string> issues = new();
            if (document == null)
            {
                issues.Add("no layout document");
                return issues;
            }

            HashSet<string> seenIds = new(StringComparer.OrdinalIgnoreCase);
            foreach (LayoutProfileData profile in document.Profiles ?? new List<LayoutProfileData>())
            {
                string id = (profile.Id ?? string.Empty).Trim();
                if (id.Length == 0)
                {
                    issues.Add("a profile has no id");
                    continue;
                }
                // SPEC §7.2 B/F: the profile id is the wire token the helper sends, so it
                // must be one safe token and must not be the reserved `generic` id.
                if (!ForegroundMapping.IsSafeProfileId(id))
                {
                    issues.Add("profile \"" + id + "\" is not a valid id: use only ASCII letters, " +
                               "digits, '_', '-' or '.', and do not use the reserved id \"" +
                               ForegroundMapping.GenericToken + "\"");
                }
                if (!seenIds.Add(id))
                {
                    issues.Add("profile \"" + id + "\" is listed more than once");
                }
                if ((profile.Title ?? string.Empty).Trim().Length == 0)
                {
                    issues.Add("profile \"" + id + "\" has no title");
                }
                if (profile.Executables == null || profile.Executables.Count == 0)
                {
                    issues.Add("profile \"" + id + "\" maps no executable, so the helper can never select it");
                }
                if (profile.Actions == null || profile.Actions.Count == 0)
                {
                    issues.Add("profile \"" + id + "\" has no actions");
                    continue;
                }

                foreach (LayoutActionData action in profile.Actions)
                {
                    string label = (action.Label ?? string.Empty).Trim();
                    string where = "profile \"" + id + "\" action \"" + label + "\"";
                    if (label.Length == 0)
                    {
                        issues.Add("profile \"" + id + "\" has an action with no label");
                    }

                    int targets = 0;
                    if (!string.IsNullOrEmpty(action.Chord)) targets++;
                    if (action.Sequence is { Count: > 0 }) targets++;
                    if (!string.IsNullOrEmpty(action.Text)) targets++;
                    if (!string.IsNullOrEmpty(action.Settings)) targets++;
                    if (targets == 0)
                    {
                        // A label with no target is legal (SPEC §7.2 F: the user may leave a
                        // project/folder target unconfigured) but it sends nothing, so say so.
                        issues.Add(where + " has no target, so it stays disabled and sends nothing");
                        continue;
                    }
                    if (targets > 1)
                    {
                        issues.Add(where + " has more than one target; using the first");
                    }

                    if (!string.IsNullOrEmpty(action.Chord))
                    {
                        if (!TryValidateChord(action.Chord, out string reason))
                        {
                            issues.Add(where + ": " + reason);
                        }
                        continue;
                    }
                    if (action.Sequence is { Count: > 0 })
                    {
                        foreach (string chord in action.Sequence)
                        {
                            if (!TryValidateChord(chord, out string reason))
                            {
                                issues.Add(where + ": " + reason);
                            }
                        }
                        continue;
                    }
                    if (!string.IsNullOrEmpty(action.Text))
                    {
                        if (!TryValidateText(action.Text, out string reason))
                        {
                            issues.Add(where + ": " + reason);
                        }
                        continue;
                    }
                    // `settings`: the chord lives in the iPad's matching settings field.
                }
            }
            return issues;
        }
    }
}
