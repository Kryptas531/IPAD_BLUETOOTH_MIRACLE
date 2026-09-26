// Focused pure tests for the user-configurable layout document, the executable →
// layout-token resolution, the safe profile-id grammar, the target validation of
// SPEC §7.2 D/F (spec commit b751488 plus the §7.2 F configurability fix) and the
// §7.2 B command line / bind-address rules (spec commit 3eb6a85). Dependency-free: no
// NuGet test framework; exit code 0 = all passed, 1 = failures listed.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Security.Cryptography;
using System.Text;
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

// --- SPEC §7.2 C: the whole reconnect frame must fit the auth frame the helper
//     reads. A REAL 32-byte secret base64-encodes to 44 characters, so the
//     exact reconnect request is 76 bytes; the previous 64-byte cap made the
//     helper reject its own credential and never reconnect.
byte[] realSecret = new byte[32];
RandomNumberGenerator.Fill(realSecret);
string realSecretBase64 = Convert.ToBase64String(realSecret);
string realReconnectRequest = ForegroundServer.ReconnectRequestJson(realSecretBase64);
Check("a real 32-byte secret base64-encodes to exactly 44 characters",
    realSecret.Length == 32 && realSecretBase64.Length == 44);
Check("the complete 32-byte-secret reconnect request is the exact 76-byte frame",
    Encoding.UTF8.GetByteCount(realReconnectRequest) == 76 &&
    realReconnectRequest == "{\"type\":\"reconnect\",\"secret\":\"" + realSecretBase64 + "\"}");
Check("the full reconnect frame fits the bounded auth frame the helper reads",
    Encoding.UTF8.GetByteCount(realReconnectRequest) <= ForegroundServer.MaxAuthFrameBytes);
Check("the pair frame still fits the original ≤64-byte bound",
    Encoding.UTF8.GetByteCount(ForegroundServer.PairRequestJson("123456")) <= 64);
Check("an oversized (129-byte) auth frame is still outside the bound",
    Encoding.UTF8.GetByteCount(new string('x', ForegroundServer.MaxAuthFrameBytes + 1))
        > ForegroundServer.MaxAuthFrameBytes);
// The exact fixed-time credential comparison is unchanged: the server only
// accepts the byte-for-byte expected request built from its own stored secret.
Check("the exact expected reconnect request still matches by fixed-time comparison",
    CryptographicOperations.FixedTimeEquals(
        Encoding.UTF8.GetBytes(ForegroundServer.ReconnectRequestJson(realSecretBase64)),
        Encoding.UTF8.GetBytes(realReconnectRequest)) &&
    !CryptographicOperations.FixedTimeEquals(
        Encoding.UTF8.GetBytes(ForegroundServer.ReconnectRequestJson(realSecretBase64)),
        Encoding.UTF8.GetBytes(ForegroundServer.PairRequestJson("123456"))));

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

// --- SPEC §7.2 B, spec commit 3eb6a85: `WindowsForeground [--bind-ip <IPv4>] [port]` ---
// Argument parsing is pure, so it is exercised without a network or an adapter.
Check("no arguments keeps the default port and automatic interface selection",
    ForegroundServer.TryParseLaunchArguments(Array.Empty<string>(), out int defaultPort,
        out string? noBind, out string noError) &&
    defaultPort == 8443 && noBind == null && noError == string.Empty);
Check("the existing optional positional port still works",
    ForegroundServer.TryParseLaunchArguments(new[] { "9100" }, out int portOnly, out string? portBind, out _) &&
    portOnly == 9100 && portBind == null);
Check("an invalid positional port is still rejected",
    !ForegroundServer.TryParseLaunchArguments(new[] { "not-a-port" }, out _, out _, out _) &&
    !ForegroundServer.TryParseLaunchArguments(new[] { "0" }, out _, out _, out _) &&
    !ForegroundServer.TryParseLaunchArguments(new[] { "70000" }, out _, out _, out _));
Check("--bind-ip <IPv4> is accepted and keeps the default port",
    ForegroundServer.TryParseLaunchArguments(new[] { "--bind-ip", "192.168.1.25" }, out int bindPort,
        out string? bindIp, out string bindError) &&
    bindIp == "192.168.1.25" && bindPort == 8443 && bindError == string.Empty);
Check("--bind-ip and the positional port can be combined",
    ForegroundServer.TryParseLaunchArguments(new[] { "--bind-ip", "192.168.1.25", "9100" },
        out int bothPort, out string? bothIp, out _) && bothIp == "192.168.1.25" && bothPort == 9100);
Check("--bind-ip without a value is a startup error",
    !ForegroundServer.TryParseLaunchArguments(new[] { "--bind-ip" }, out _, out _, out string missingValue) &&
    missingValue.Contains("--bind-ip") && missingValue.Contains("IPv4"));
Check("an unknown option is a startup error",
    !ForegroundServer.TryParseLaunchArguments(new[] { "--bind-ipx", "192.168.1.25" }, out _, out _, out _));

// The explicit address is validated exactly as specified: valid IPv4, not a
// wildcard, private/local, AND owned by an operational non-tunnel interface.
bool publicOk = ForegroundServer.TryResolveEndPoint("8.8.8.8", 8443, out IPEndPoint? publicEp, out string publicError);
Check("a public address is refused (no bind, clear error, no fallback)",
    !publicOk && publicEp == null && publicError.Contains("not a private/local IPv4"));
bool wildcardOk = ForegroundServer.TryResolveEndPoint("0.0.0.0", 8443, out IPEndPoint? wildcardEp, out string wildcardError);
Check("a wildcard address is refused",
    !wildcardOk && wildcardEp == null && wildcardError.Contains("wildcard address"));
bool ipv6Ok = ForegroundServer.TryResolveEndPoint("::1", 8443, out IPEndPoint? ipv6Ep, out string ipv6Error);
Check("an IPv6 address is refused as not a valid IPv4",
    !ipv6Ok && ipv6Ep == null && ipv6Error.Contains("not a valid IPv4"));
bool garbageOk = ForegroundServer.TryResolveEndPoint("not-an-address", 8443, out IPEndPoint? garbageEp, out string garbageError);
Check("a malformed address is refused",
    !garbageOk && garbageEp == null && garbageError.Contains("not a valid IPv4"));
bool partialOk = ForegroundServer.TryResolveEndPoint("192.168.1", 8443, out IPEndPoint? partialEp, out string partialError);
Check("an incomplete dotted-quad address is refused",
    !partialOk && partialEp == null && partialError.Length > 0);
bool unassignedOk = ForegroundServer.TryResolveEndPoint("10.42.42.42", 8443, out IPEndPoint? unassignedEp, out string unassignedError);
Check("a private address not owned by an operational non-tunnel interface is refused",
    !unassignedOk && unassignedEp == null && unassignedError.Contains("not assigned"));

// The automatic path is unchanged: whatever it picked before is still accepted,
// and asking for that same address explicitly yields the same endpoint/port.
bool autoOk = ForegroundServer.TryResolveEndPoint(null, 8443, out IPEndPoint? autoEp, out string autoError);
if (autoOk && autoEp != null)
{
    bool explicitOk = ForegroundServer.TryResolveEndPoint(autoEp.Address.ToString(), 9100,
                                                          out IPEndPoint? explicitEp, out string explicitError);
    Check("an address owned by an operational non-tunnel interface is accepted as --bind-ip",
        explicitOk && explicitEp != null && explicitEp.Address.Equals(autoEp.Address) && explicitError == string.Empty);
    Check("an explicit --bind-ip address can carry its own port",
        explicitOk && explicitEp != null && explicitEp.Port == 9100);
    Check("automatic selection still uses the requested port",
        autoEp.Port == 8443 && ForegroundServer.IsLocalPrivateAddress(autoEp.Address));
}
else
{
    // No private/local adapter on this machine: the helper must refuse to start
    // with the original message, never fall back to a public or wildcard bind.
    Check("automatic selection refuses to start when no private/local IPv4 exists",
        !autoOk && autoEp == null && autoError.Contains("no private/local IPv4 interface found"));
}

// A valid private/local address the host does own (loopback always qualifies).
bool loopbackOk = ForegroundServer.TryResolveEndPoint("127.0.0.1", 8443, out IPEndPoint? loopbackEp, out string loopbackError);
Check("a valid private/local address owned by this host binds exactly it",
    loopbackOk && loopbackEp != null &&
    loopbackEp.Address.Equals(IPAddress.Loopback) && loopbackEp.Port == 8443 && loopbackError == string.Empty);

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
