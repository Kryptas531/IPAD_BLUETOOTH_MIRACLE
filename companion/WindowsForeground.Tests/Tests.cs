// Focused pure tests for the executable → app-identity wire contract
// (SPEC §7.2 D, spec commit b751488). Dependency-free: no NuGet test
// framework; exit code 0 = all passed, 1 = failures listed.
using System;
using System.Collections.Generic;
using System.Net;
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

// --- executable → identity (matched strictly by executable file name) ---
Check("Code.exe maps to vscode",
    ForegroundMapping.Resolve(@"C:\Program Files\Microsoft VS Code\Code.exe") == AppIdentity.VsCode);
Check("executable matching is case-insensitive",
    ForegroundMapping.Resolve(@"D:\apps\code.exe") == AppIdentity.VsCode);
Check("chrome.exe maps to chrome",
    ForegroundMapping.Resolve(@"C:\Program Files\Google\Chrome\Application\chrome.exe") == AppIdentity.Chrome);
Check("explorer.exe maps to explorer",
    ForegroundMapping.Resolve(@"C:\Windows\explorer.exe") == AppIdentity.Explorer);

// --- unknown / unavailable → generic (§7.1 default, §7.2 E fallback) ---
Check("unknown executable maps to generic",
    ForegroundMapping.Resolve(@"C:\Windows\System32\notepad.exe") == AppIdentity.Generic);
Check("missing executable path maps to generic",
    ForegroundMapping.Resolve(null) == AppIdentity.Generic);
Check("empty executable path maps to generic",
    ForegroundMapping.Resolve(string.Empty) == AppIdentity.Generic);
Check("window-title-like string is never consulted (must stay generic)",
    ForegroundMapping.Resolve("Google Chrome") == AppIdentity.Generic);
Check("path with invalid characters degrades to generic",
    ForegroundMapping.Resolve("a<b") == AppIdentity.Generic);

// --- wire tokens ---
Check("token vscode", ForegroundMapping.Token(AppIdentity.VsCode) == "vscode");
Check("token chrome", ForegroundMapping.Token(AppIdentity.Chrome) == "chrome");
Check("token explorer", ForegroundMapping.Token(AppIdentity.Explorer) == "explorer");
Check("token generic", ForegroundMapping.Token(AppIdentity.Generic) == "generic");

// --- exact notification JSON (the only message the helper ever sends) ---
Check("json vscode",
    ForegroundMapping.ForegroundChangedJson(AppIdentity.VsCode) ==
    "{\"type\":\"foreground-changed\",\"identity\":\"vscode\"}");
Check("json generic",
    ForegroundMapping.ForegroundChangedJson(AppIdentity.Generic) ==
    "{\"type\":\"foreground-changed\",\"identity\":\"generic\"}");

// --- bounded known set: exactly the three specified executables ---
Check("known set has exactly three entries",
    ForegroundMapping.Known.Count == 3 &&
    ForegroundMapping.Known["Code.exe"] == AppIdentity.VsCode &&
    ForegroundMapping.Known["chrome.exe"] == AppIdentity.Chrome &&
    ForegroundMapping.Known["explorer.exe"] == AppIdentity.Explorer);

// --- §7.2 local-only bind rule (no wildcard/public bind) ---
Check("private 10/8 address is local", ForegroundServer.IsLocalPrivateAddress(IPAddress.Parse("10.0.0.7")));
Check("private 172.16/12 address is local", ForegroundServer.IsLocalPrivateAddress(IPAddress.Parse("172.16.5.4")));
Check("private 192.168/16 address is local", ForegroundServer.IsLocalPrivateAddress(IPAddress.Parse("192.168.1.9")));
Check("loopback address is local", ForegroundServer.IsLocalPrivateAddress(IPAddress.Loopback));
Check("public address is NOT accepted", !ForegroundServer.IsLocalPrivateAddress(IPAddress.Parse("8.8.8.8")));
Check("wildcard address is NOT accepted", !ForegroundServer.IsLocalPrivateAddress(IPAddress.Any));
Check("IPv6 address is NOT accepted", !ForegroundServer.IsLocalPrivateAddress(IPAddress.Parse("::1")));

// --- exact authentication wire strings (client must match them exactly) ---
Check("pair request json",
    ForegroundServer.PairRequestJson("123456") == "{\"type\":\"pair\",\"code\":\"123456\"}");
Check("reconnect request json",
    ForegroundServer.ReconnectRequestJson("abc") == "{\"type\":\"reconnect\",\"secret\":\"abc\"}");
Check("pair and reconnect messages differ",
    ForegroundServer.PairRequestJson("123456") != ForegroundServer.ReconnectRequestJson("123456"));

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
