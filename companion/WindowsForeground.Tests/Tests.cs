// Focused pure tests for the user-configurable layout document, the executable →
// layout-token resolution, the safe profile-id grammar and the target validation of
// SPEC §7.2 D/F (spec commit b751488 plus the §7.2 F configurability fix). Dependency-free: no NuGet test
// framework; exit code 0 = all passed, 1 = failures listed.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Text.Json;
using WindowsForeground;

var failures = new List<string>();
int checks = 0;

void Check(string name, bool condition)
{
    checks++;
    if (!condition)
    {
        failures.Add(name);
    }
}

// --- the shipped document (SPEC §7.2 F: data, not code) ---
LayoutDocumentData defaults = ForegroundMapping.DefaultDocument();
Check("shipped document has exactly the three canonical profiles",
    defaults.Profiles.Count == 3 &&
    defaults.Profiles[0].Id == "vscode" &&
    defaults.Profiles[1].Id == "chrome" &&
    defaults.Profiles[2].Id == "explorer");
Check("shipped profile titles are the SPEC titles",
    defaults.Profiles[0].Title == "VS Code" &&
    defaults.Profiles[1].Title == "Chrome" &&
    defaults.Profiles[2].Title == "File Explorer");

// --- executable → layout token (matched strictly by executable file name) ---
Check("Code.exe maps to vscode",
    ForegroundMapping.ResolveToken(defaults, @"C:\Program Files\Microsoft VS Code\Code.exe") == "vscode");
Check("executable matching is case-insensitive",
    ForegroundMapping.ResolveToken(defaults, @"D:\apps\code.exe") == "vscode");
Check("chrome.exe maps to chrome",
    ForegroundMapping.ResolveToken(defaults, @"C:\Program Files\Google\Chrome\Application\chrome.exe") == "chrome");
Check("explorer.exe maps to explorer",
    ForegroundMapping.ResolveToken(defaults, @"C:\Windows\explorer.exe") == "explorer");

// --- SPEC §7.2 F: a user-added executable → layout mapping needs no code change ---
string userJson = """
{
  "profiles": [
    {
      "id": "cursor",
      "title": "Cursor",
      "executables": ["Cursor.exe", "code.exe"],
      "actions": [
        { "label": "New Window", "chord": "Ctrl+Shift+N" },
        { "label": "Open Folder", "sequence": ["Ctrl+K", "Ctrl+O"] },
        { "label": "Open my project", "text": "C:\\Projects\\Frost Pi\\start.txt" }
      ]
    }
  ]
}
""";
LayoutDocumentData? userDocument = null;
try
{
    userDocument = JsonSerializer.Deserialize<LayoutDocumentData>(userJson);
}
catch (Exception ex)
{
    Console.WriteLine("FAIL: user profile JSON did not parse: " + ex.Message);
}
Check("user document parses with one custom profile",
    userDocument is { Profiles.Count: 1 } && userDocument.Profiles[0].Id == "cursor" &&
    userDocument.Profiles[0].Title == "Cursor" && userDocument.Profiles[0].Executables.Count == 2);
Check("user document keeps a chord, a chord sequence and a typed-text target",
    userDocument != null &&
    userDocument.Profiles[0].Actions[0].Chord == "Ctrl+Shift+N" &&
    userDocument.Profiles[0].Actions[1].Sequence is { Count: 2 } chords &&
    chords[0] == "Ctrl+K" && chords[1] == "Ctrl+O" &&
    userDocument.Profiles[0].Actions[2].Text == @"C:\Projects\Frost Pi\start.txt");
Check("user executable maps to the user's own layout id",
    userDocument != null &&
    ForegroundMapping.ResolveToken(userDocument, @"C:\apps\Cursor.exe") == "cursor");
Check("a user profile can re-point a canonical executable to another layout",
    userDocument != null &&
    ForegroundMapping.ResolveToken(userDocument, @"D:\apps\code.exe") == "cursor");

// --- SPEC §7.2 B/F: a profile id IS the wire identity token, so it must be one safe
//     token (ASCII letters, digits, '_', '-', '.') and never the reserved `generic` id ---
Check("a plain custom id is a safe token", ForegroundMapping.IsSafeProfileId("cursor"));
Check("an id of letters, digits, '_', '-' and '.' is a safe token",
    ForegroundMapping.IsSafeProfileId("cursor-2.0_v2"));
Check("an empty or blank id is not a safe token",
    !ForegroundMapping.IsSafeProfileId("") && !ForegroundMapping.IsSafeProfileId("   ") &&
    !ForegroundMapping.IsSafeProfileId(null));
Check("the reserved id 'generic' is never a safe profile id (any case)",
    !ForegroundMapping.IsSafeProfileId("generic") && !ForegroundMapping.IsSafeProfileId("GENERIC"));
Check("an id with a space, a quote, a backslash or a newline is not a safe token",
    !ForegroundMapping.IsSafeProfileId("my app") &&
    !ForegroundMapping.IsSafeProfileId("bad\"id") &&
    !ForegroundMapping.IsSafeProfileId(@"bad\id") &&
    !ForegroundMapping.IsSafeProfileId("bad\n\r{}id"));

// A document a user could mis-edit: one profile with a punctuation/quote-bearing id and
// one profile claiming the reserved `generic` id. Neither may reach the iPad.
LayoutDocumentData unsafeDocument = new()
{
    Profiles = new List<LayoutProfileData>
    {
        new()
        {
            Id = "bad\"id", Title = "Bad",
            Executables = new List<string> { "Code.exe" },
            Actions = new List<LayoutActionData>
            {
                new() { Label = "New Window", Chord = "Ctrl+Shift+N" },
            },
        },
        new()
        {
            Id = "GENERIC", Title = "Generic",
            Executables = new List<string> { "cursor.exe" },
            Actions = new List<LayoutActionData>
            {
                new() { Label = "New Window", Chord = "Ctrl+Shift+N" },
            },
        },
    },
};
Check("a profile whose id contains a quote or a newline never resolves",
    ForegroundMapping.ResolveToken(unsafeDocument, @"C:\apps\Code.exe") == ForegroundMapping.GenericToken);
Check("a profile whose id is 'GENERIC' cannot override the generic fallback",
    ForegroundMapping.ResolveToken(unsafeDocument, @"C:\apps\cursor.exe") == ForegroundMapping.GenericToken);
Check("an unsafe id is never put on the wire (exact generic message still sent)",
    ForegroundMapping.ForegroundChangedJson(
        ForegroundMapping.ResolveToken(unsafeDocument, @"C:\apps\Code.exe")) ==
    "{\"type\":\"foreground-changed\",\"identity\":\"generic\"}");
Check("the validator reports an unsafe id and a reserved generic id",
    LayoutValidator.Validate(unsafeDocument).Any(issue => issue.Contains("is not a valid id")) &&
    LayoutValidator.Validate(unsafeDocument).Any(issue => issue.Contains("reserved id")));

// A correctly configured custom profile still works end to end.
LayoutDocumentData customDocument = new()
{
    Profiles = new List<LayoutProfileData>
    {
        new()
        {
            Id = "cursor-2.0", Title = "Cursor",
            Executables = new List<string> { "Cursor.exe" },
            Actions = new List<LayoutActionData>
            {
                new() { Label = "New Window", Chord = "Ctrl+Shift+N" },
            },
        },
    },
};
Check("a valid custom token still resolves", ForegroundMapping.ResolveToken(customDocument, @"C:\apps\Cursor.exe") == "cursor-2.0");
Check("a valid custom token is sent verbatim in the exact wire message",
    ForegroundMapping.ForegroundChangedJson(ForegroundMapping.ResolveToken(customDocument, @"C:\apps\Cursor.exe")) ==
    "{\"type\":\"foreground-changed\",\"identity\":\"cursor-2.0\"}");
Check("a correctly configured custom document raises no validation issue",
    LayoutValidator.Validate(customDocument).Count == 0);
// The helper trims the id it resolved, so an accidentally space-padded id still reaches
// the iPad as the same token the iPad's own document holds.
Check("a space-padded id is emitted as the trimmed token",
    ForegroundMapping.ForegroundChangedJson(" cursor ") ==
    "{\"type\":\"foreground-changed\",\"identity\":\"cursor\"}");

// --- unknown / unavailable → generic (§7.1 default, §7.2 E fallback) ---
Check("unknown executable maps to generic",
    ForegroundMapping.ResolveToken(defaults, @"C:\Windows\System32\notepad.exe") == "generic");
Check("an executable the user document does not configure maps to generic",
    userDocument != null &&
    ForegroundMapping.ResolveToken(userDocument, @"C:\Windows\explorer.exe") == "generic");
Check("missing executable path maps to generic",
    ForegroundMapping.ResolveToken(defaults, null) == "generic");
Check("empty executable path maps to generic",
    ForegroundMapping.ResolveToken(defaults, string.Empty) == "generic");
Check("window-title-like string is never consulted (must stay generic)",
    ForegroundMapping.ResolveToken(defaults, "Google Chrome") == "generic");
Check("path with invalid characters degrades to generic",
    ForegroundMapping.ResolveToken(defaults, "a<b") == "generic");
Check("no document read at all still resolves to generic",
    ForegroundMapping.ResolveToken(null, @"C:\Program Files\Microsoft VS Code\Code.exe") == "generic");

// --- SPEC §7.2 F: the shipped document must parse AND every target must be usable,
//     because the iPad is the device that sends the keystrokes ---
List<string> defaultIssues = LayoutValidator.Validate(defaults);
Check("shipped document parses and every target is usable (" + string.Join("; ", defaultIssues) + ")",
    defaultIssues.Count == 0);
Check("shipped VS Code set keeps all eleven required labels, in order, spelled exactly",
    defaults.Profiles[0].Actions.Select(a => a.Label).SequenceEqual(new[]
    {
        "New Window", "Open Folder", "Frost Pi", "SideChatAI", "Explorer", "Source Control",
        "New Terminal", "Close Saved", "Split Editor Right", "Move to the editor",
        "Quick Open Browser Tab",
    }));
Check("shipped Chrome set keeps its nine labels, in order, spelled exactly",
    defaults.Profiles[1].Actions.Select(a => a.Label).SequenceEqual(new[]
    {
        "New Tab", "Close Tab", "Reload", "Focus Address Bar", "Back", "Forward", "History",
        "Show Bookmarks", "Full Screen",
    }));
Check("shipped File Explorer set keeps its nine labels, in order, spelled exactly",
    defaults.Profiles[2].Actions.Select(a => a.Label).SequenceEqual(new[]
    {
        "New Window", "New Tab", "This PC", "Documents", "Downloads", "Search", "Select All",
        "New Folder", "Rename",
    }));
Check("the six project/folder targets are \"settings\" targets, so their chords stay user data",
    defaults.Profiles.Sum(p => p.Actions.Count(a => !string.IsNullOrEmpty(a.Settings))) == 6 &&
    defaults.Profiles[0].Actions[2].Settings == "BTRemote.shortcutFrostPi" &&
    defaults.Profiles[0].Actions[3].Settings == "BTRemote.shortcutSideChatAI" &&
    defaults.Profiles[0].Actions[10].Settings == "BTRemote.shortcutQuickOpenBrowserTab" &&
    defaults.Profiles[2].Actions[2].Settings == "BTRemote.shortcutThisPC" &&
    defaults.Profiles[2].Actions[3].Settings == "BTRemote.shortcutDocuments" &&
    defaults.Profiles[2].Actions[4].Settings == "BTRemote.shortcutDownloads");
Check("the shipped \\\"chord\\\"/\\\"sequence\\\" targets all validate",
    LayoutValidator.TryValidateChord("Ctrl+Shift+N", out _) &&
    LayoutValidator.TryValidateChord("Ctrl+K", out _) &&
    LayoutValidator.TryValidateChord("Ctrl+`", out _) &&
    LayoutValidator.TryValidateChord("Ctrl+\\", out _) &&
    LayoutValidator.TryValidateChord("Alt+Left", out _) &&
    LayoutValidator.TryValidateChord("Ctrl+1", out _) &&
    LayoutValidator.TryValidateChord("F11", out _) &&
    LayoutValidator.TryValidateText(@"C:\Projects\Frost Pi\start.txt", out _));

// --- SPEC §7.2 F: only targets the existing HID path can actually send ---
Check("an unknown key name is rejected",
    !LayoutValidator.TryValidateChord("Ctrl+Plus", out string unknownKey) &&
    unknownKey.Contains("unknown key"));
Check("an unknown modifier is rejected",
    !LayoutValidator.TryValidateChord("Teal+K", out string unknownModifier) &&
    unknownModifier.Contains("unknown modifier"));
Check("an untypable character is rejected",
    !LayoutValidator.TryValidateChord("Ctrl+\u00e9", out _) &&
    !LayoutValidator.TryValidateText("\u2192", out string untypable) &&
    untypable.Contains("cannot be typed"));
Check("a blank target is rejected (the action then sends nothing)",
    !LayoutValidator.TryValidateChord("", out string blank) && blank == "target is empty" &&
    !LayoutValidator.TryValidateText("", out string blankText) && blankText == "target is empty");
Check("a chord with no key part is rejected",
    !LayoutValidator.TryValidateChord("Ctrl+", out _));
Check("an action with no target is reported, not silently unusable",
    LayoutValidator.Validate(JsonSerializer.Deserialize<LayoutDocumentData>(
        """
        { "profiles": [ { "id": "x", "title": "X", "executables": ["x.exe"],
                          "actions": [ { "label": "Nothing configured" } ] } ]
        }
        """)!).Any(issue => issue.Contains("no target")));

// --- exact wire strings (client must match them exactly) ---
Check("pair request json",
    ForegroundServer.PairRequestJson("123456") == "{\"type\":\"pair\",\"code\":\"123456\"}");
Check("reconnect request json",
    ForegroundServer.ReconnectRequestJson("abc") == "{\"type\":\"reconnect\",\"secret\":\"abc\"}");
Check("pair and reconnect messages differ",
    ForegroundServer.PairRequestJson("123456") != ForegroundServer.ReconnectRequestJson("123456"));

// --- the one notification the helper ever sends (now a profile id, not a fixed enum) ---
Check("json vscode",
    ForegroundMapping.ForegroundChangedJson(ForegroundMapping.GenericToken) ==
    "{\"type\":\"foreground-changed\",\"identity\":\"generic\"}");
Check("json carries a user-defined profile id unchanged",
    ForegroundMapping.ForegroundChangedJson("cursor") ==
    "{\"type\":\"foreground-changed\",\"identity\":\"cursor\"}");

// --- §7.2 local-only bind rule (no wildcard/public bind) ---
Check("private 10/8 address is local", ForegroundServer.IsLocalPrivateAddress(IPAddress.Parse("10.0.0.7")));
Check("private 172.16/12 address is local", ForegroundServer.IsLocalPrivateAddress(IPAddress.Parse("172.16.5.4")));
Check("private 192.168/16 address is local", ForegroundServer.IsLocalPrivateAddress(IPAddress.Parse("192.168.1.9")));
Check("loopback address is local", ForegroundServer.IsLocalPrivateAddress(IPAddress.Loopback));
Check("public address is NOT accepted", !ForegroundServer.IsLocalPrivateAddress(IPAddress.Parse("8.8.8.8")));
Check("wildcard address is NOT accepted", !ForegroundServer.IsLocalPrivateAddress(IPAddress.Any));
Check("IPv6 address is NOT accepted", !ForegroundServer.IsLocalPrivateAddress(IPAddress.Parse("::1")));

// --- auth mode selection (which credential the next client must present) ---
// No stored secret at all (fresh helper) => the device must use the printed
// one-time code.
Check("no stored secret selects pairing",
    ForegroundServer.SelectAuthMode(null) == AuthMode.Pair);
// A persisted but unusable blob (wrong length: partial write, foreign file) is
// not a credential, so pairing must stay available.
Check("empty stored blob selects pairing",
    ForegroundServer.SelectAuthMode(Array.Empty<byte>()) == AuthMode.Pair);
Check("wrong-length stored blob selects pairing",
    ForegroundServer.SelectAuthMode(new byte[16]) == AuthMode.Pair);
// A valid persisted 32-byte secret => the already-paired device reconnects
// with it; the helper must NOT demand a code it never printed.
Check("valid 32-byte stored secret selects reconnect",
    ForegroundServer.SelectAuthMode(new byte[32]) == AuthMode.Reconnect);
Check("longer stored blob is not a valid secret (selects pairing)",
    ForegroundServer.SelectAuthMode(new byte[64]) == AuthMode.Pair);
// Whichever mode is chosen, the corresponding wire string is the exact one the
// client has to send.
Check("pair mode expects the pair message",
    ForegroundServer.SelectAuthMode(null) == AuthMode.Pair &&
    ForegroundServer.PairRequestJson("000000") == "{\"type\":\"pair\",\"code\":\"000000\"}");
Check("reconnect mode expects the reconnect message",
    ForegroundServer.SelectAuthMode(new byte[32]) == AuthMode.Reconnect &&
    ForegroundServer.ReconnectRequestJson("abc") == "{\"type\":\"reconnect\",\"secret\":\"abc\"}");


if (failures.Count == 0)
{
    Console.WriteLine($"ALL TESTS PASSED ({checks} checks)");
    return 0;
}

foreach (string failure in failures)
{
    Console.WriteLine("FAIL: " + failure);
}
return 1;
