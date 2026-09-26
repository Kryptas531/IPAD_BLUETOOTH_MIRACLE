// ForegroundServer — the local TLS WebSocket endpoint the paired iPad
// connects to (SPEC §7.2 B/C). No NuGet packages: SslStream from the base
// library plus a minimal server-side WebSocket handshake, because .NET
// ships no built-in server WebSocket (System.Net.WebSockets is client-side
// only).
//
// Contract enforced here:
//   * The listener binds exactly one concrete private/local IPv4 address
//     (never IPAddress.Any / IPAddress.IPv6Any), so the endpoint is never
//     reachable from a non-local network (§7.2 "local" requirement).
//   * TLS is mandatory; a client that fails the TLS handshake receives
//     nothing. There is no plaintext fallback anywhere in this helper.
//   * The connection yields no data until the device authenticates. Which
//     credential the helper demands is decided once, at construction, by
//     SelectAuthMode (see also Program.Main, which only prints a code when no
//     valid secret exists):
//       - no valid stored 32-byte secret (fresh helper, or an unwritable
//         blob): first pairing, the exact one-time request
//         {"type":"pair","code":"<code>"} (the code shown on the local
//         Windows console). A successful pair consumes the code (one-time
//         semantics) and provisions a long-lived 256-bit device secret,
//         which the server sends to the client once, over TLS, as
//         {"type":"paired","secret":"<base64>"}.
//       - a valid stored 32-byte secret already exists (helper restart after
//         a successful pair, or a Wi-Fi drop / iPad reboot mid-run): the exact
//         request {"type":"reconnect","secret":"<base64>"}. The server
//         verifies the stored long-lived secret with a fixed-time comparison,
//         so the device does not have to re-enter a code that the helper no
//         longer prints.
//     Client authentication is therefore verified by the server ( possession
//     of the one-time code, then of the durable secret), not assumed.
//   * After the authentication exchange the only message ever sent is the
//     fixed notification produced by ForegroundMapping — never HID commands,
//     window titles, executable paths or arbitrary process data.
using System;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Security;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace WindowsForeground
{
    // Which credential the next connecting client has to prove. Pure decision
    // (see ForegroundServer.SelectAuthMode), unit tested without a network.
    public enum AuthMode
    {
        // No usable stored secret: the device authenticates with the one-time
        // code printed on the local Windows console.
        Pair,
        // A valid 32-byte device secret is already stored: only that secret
        // authenticates; no new pairing code is issued or printed.
        Reconnect,
    }

    public sealed class ForegroundServer
    {
        // RFC 6455 §1.3 magic GUID for the handshake accept hash.
        private const string WsHandshakeGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

        private readonly X509Certificate2 _cert;
        private readonly TcpListener _listener;
        private readonly string _secretPath;
        private AuthMode _authMode;
        private string? _pairCode;
        private string? _deviceSecret;   // long-lived credential handed to the iPad at pair time
        private bool _authenticated;
        private WebSocket? _ws;
        private TcpClient? _client;      // owned socket of the authenticated client

        public ForegroundServer(X509Certificate2 cert, IPEndPoint endpoint, string pairCode, string secretPath)
        {
            _cert = cert;
            _listener = new TcpListener(endpoint);
            _listener.Start(); // bind errors surface immediately (fail fast)
            _secretPath = secretPath;

            // Auth mode is fixed here so it can never disagree with Program's
            // console output: the one-time code is only meaningful when no
            // valid stored secret exists. If a 32-byte secret is already
            // persisted, this helper was paired with this iPad before, the
            // code it just generated is never printed, and the device must be
            // authenticated by its stored secret instead.
            byte[]? storedSecret = ProtectedStore.TryRead(secretPath);
            if (SelectAuthMode(storedSecret) == AuthMode.Reconnect)
            {
                _authMode = AuthMode.Reconnect;
                _deviceSecret = Convert.ToBase64String(storedSecret!);
            }
            else
            {
                _authMode = AuthMode.Pair;
                _pairCode = pairCode;
            }
        }

        // Pure auth-mode selection: a persisted secret counts as valid only
        // when it is exactly the 32 bytes (256 bit) the pair flow wrote.
        // Anything else (missing file, unreadable blob, wrong length) falls
        // back to pairing so the user is shown a fresh code.
        public static AuthMode SelectAuthMode(byte[]? storedSecret) =>
            storedSecret is { Length: 32 } ? AuthMode.Reconnect : AuthMode.Pair;

        // Exact wire strings owned by the server so the client contract stays
        // unambiguous (and testable without a network).
        public static string PairRequestJson(string code) =>
            "{\"type\":\"pair\",\"code\":\"" + code + "\"}";

        public static string ReconnectRequestJson(string secret) =>
            "{\"type\":\"reconnect\",\"secret\":\"" + secret + "\"}";

        // §7.2 requires a *local* endpoint only. True for loopback and for
        // RFC 1918 / link-local IPv4 unicast addresses; false for public and
        // for IPv6 (this helper's iPad↔Windows link is IPv4 LAN/Bluetooth PAN).
        public static bool IsLocalPrivateAddress(IPAddress address)
        {
            if (address.AddressFamily != AddressFamily.InterNetwork)
            {
                return false;
            }
            if (IPAddress.IsLoopback(address))
            {
                return true;
            }
            byte[] b = address.GetAddressBytes();
            if (b[0] == 10)
            {
                return true;
            }
            if (b[0] == 172 && b[1] >= 16 && b[1] <= 31)
            {
                return true;
            }
            if (b[0] == 192 && b[1] == 168)
            {
                return true;
            }
            return b[0] == 169 && b[1] == 254;
        }

        // A client is usable for notifications only after TLS and a correct
        // authentication exchange (one-time code, then the stored secret).
        public bool IsPaired => _ws != null && _authenticated;

        // Accepts connections one at a time (single paired iPad). An incoming
        // connection is always let through to the authentication exchange —
        // including the case where the already-paired iPad opens a fresh
        // socket after a network drop while nothing changed on Windows (the
        // helper then never sends, so it cannot notice the dead socket on its
        // own). This does not weaken client auth: a connection is only
        // accepted as the paired device if it proves possession of the stored
        // credential, and nothing at all is sent before that succeeds.
        public async Task AcceptLoopAsync(CancellationToken cancellationToken)
        {
            try
            {
                while (!cancellationToken.IsCancellationRequested)
                {
                    TcpClient client = await _listener.AcceptTcpClientAsync(cancellationToken);
                    bool handedOff = false;
                    try
                    {
                        handedOff = await HandleAsync(client, cancellationToken);
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine($"[windows-foreground] rejected connection: {ex.GetType().Name}: {ex.Message}");
                    }
                    finally
                    {
                        // When HandleAsync authenticated the client it took
                        // ownership of the socket (it is the live paired
                        // channel); otherwise close it immediately.
                        if (!handedOff)
                        {
                            client.Dispose();
                        }
                    }
                }
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[windows-foreground] accept loop stopped: {ex.GetType().Name}: {ex.Message}");
            }
        }

        // Drop a broken/disconnected client so the same device can re-authenticate
        // with its stored long-lived secret (no new code needed).
        public void ForgetClient()
        {
            try { _ws?.Dispose(); } catch { }
            try { _client?.Dispose(); } catch { }
            _ws = null;
            _client = null;
            _authenticated = false;
        }

        public async Task SendForegroundChangedAsync(string token, CancellationToken cancellationToken)
        {
            WebSocket ws = _ws ?? throw new InvalidOperationException("no paired client");
            string json = ForegroundMapping.ForegroundChangedJson(token);
            byte[] payload = Encoding.UTF8.GetBytes(json);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(3));
            await ws.SendAsync(new ArraySegment<byte>(payload), WebSocketMessageType.Text, endOfMessage: true, timeout.Token);
        }

        // Returns true only when the client authenticated; then the server
        // owns its socket as the single live paired channel. Every failure
        // path closes the connection without sending a single byte of payload
        // and leaves any previously authenticated session untouched.
        private async Task<bool> HandleAsync(TcpClient client, CancellationToken cancellationToken)
        {
            SslStream? ssl = null;
            WebSocket? ws = null;
            bool authenticatedClient = false;
            try
            {
                // --- TLS (mandatory; no plaintext path exists) ---
                ssl = new SslStream(client.GetStream(), leaveInnerStreamOpen: false);
                var sslOptions = new SslServerAuthenticationOptions
                {
                    ServerCertificate = _cert,
                    ClientCertificateRequired = false,
                    // SslProtocols.None ⇒ let the OS select its default (TLS 1.2/1.3).
                    EnabledSslProtocols = SslProtocols.None,
                    CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
                };
                await ssl.AuthenticateAsServerAsync(sslOptions, cancellationToken);

                // --- RFC 6455 server handshake over the established TLS stream ---
                string requestHead = await ReadHttpHeadAsync(ssl, cancellationToken);
                string? secWebSocketKey = null;
                foreach (string line in requestHead.Split("\r\n"))
                {
                    int colon = line.IndexOf(':');
                    if (colon <= 0)
                    {
                        continue;
                    }
                    if (line.Substring(0, colon).Trim().Equals("Sec-WebSocket-Key", StringComparison.OrdinalIgnoreCase))
                    {
                        secWebSocketKey = line.Substring(colon + 1).Trim();
                        break;
                    }
                }
                if (string.IsNullOrEmpty(secWebSocketKey))
                {
                    // Not a WebSocket client at all — close without sending data.
                    return false;
                }

                string accept = Convert.ToBase64String(SHA1Hash(Encoding.ASCII.GetBytes(secWebSocketKey + WsHandshakeGuid)));
                byte[] responseBytes = Encoding.ASCII.GetBytes(
                    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                    "Sec-WebSocket-Accept: " + accept + "\r\n\r\n");
                await ssl.WriteAsync(responseBytes, cancellationToken);

                // Standard WebSocket plumbing (RFC 6455 keep-alive pings only;
                // the only *data* frames ever sent are the §7.2 notifications).
                ws = WebSocket.CreateFromStream(ssl, true, client.Client.RemoteEndPoint?.ToString() ?? "unknown", TimeSpan.FromSeconds(30));

                // --- Client authentication: exact JSON, received before any
                // outbound data. The expected credential follows the auth mode
                // chosen at construction: the one-time local code while no
                // valid secret is stored, afterwards the stored secret. ---
                string? localCode = _authMode == AuthMode.Pair ? _pairCode : null;
                string? storedSecret = _authMode == AuthMode.Reconnect ? _deviceSecret : null;
                string? expectedRequest = null;
                if (!string.IsNullOrEmpty(localCode))
                {
                    expectedRequest = PairRequestJson(localCode);
                }
                else if (!string.IsNullOrEmpty(storedSecret))
                {
                    expectedRequest = ReconnectRequestJson(storedSecret);
                }
                if (expectedRequest == null)
                {
                    return false; // code spent and no secret stored; restart the helper to re-pair
                }

                var receiveBuffer = new byte[256];
                var received = new StringBuilder();
                using var pairTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                pairTimeout.CancelAfter(TimeSpan.FromSeconds(5));

                while (true)
                {
                    WebSocketReceiveResult result = await ws.ReceiveAsync(new ArraySegment<byte>(receiveBuffer), pairTimeout.Token);
                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        return false; // no pairing — send nothing, wait for next device
                    }
                    received.Append(Encoding.UTF8.GetString(receiveBuffer, 0, result.Count));
                    if (received.Length > 64)
                    {
                        return false; // oversized/unexpected frame
                    }
                    if (result.EndOfMessage)
                    {
                        break;
                    }
                }

                string actualRequest = received.ToString();
                bool credentialsMatch = CryptographicOperations.FixedTimeEquals(
                    Encoding.UTF8.GetBytes(expectedRequest),
                    Encoding.UTF8.GetBytes(actualRequest));
                if (!credentialsMatch)
                {
                    return false; // wrong or missing credential — send nothing
                }

                if (!string.IsNullOrEmpty(localCode))
                {
                    // First successful pairing: provision the durable credential
                    // (32 random bytes) and hand it to the client exactly once,
                    // over the already-established TLS channel. The one-time
                    // code is now spent.
                    var secret = new byte[32];
                    RandomNumberGenerator.Fill(secret);
                    ProtectedStore.Write(secretPath: _secretPath, secret);
                    _deviceSecret = Convert.ToBase64String(secret);
                    _pairCode = null;
                    _authMode = AuthMode.Reconnect;   // later sockets authenticate with the secret

                    byte[] ack = Encoding.UTF8.GetBytes(
                        "{\"type\":\"paired\",\"secret\":\"" + _deviceSecret + "\"}");
                    await ws.SendAsync(new ArraySegment<byte>(ack), WebSocketMessageType.Text,
                        endOfMessage: true, cancellationToken);
                    Console.WriteLine("[windows-foreground] client paired with one-time code; " +
                                      "long-lived device secret issued and stored (DPAPI-protected).");
                }
                else
                {
                    byte[] ack = Encoding.UTF8.GetBytes("{\"type\":\"reconnected\"}");
                    await ws.SendAsync(new ArraySegment<byte>(ack), WebSocketMessageType.Text,
                        endOfMessage: true, cancellationToken);
                    Console.WriteLine("[windows-foreground] client reconnected with stored device secret.");
                }

                // Take over the live channel. A device that reconnects on a new
                // socket replaces the stale one (that socket is already dead,
                // which is why the device is reconnecting with its secret).
                if (_ws != null)
                {
                    try { _ws.Dispose(); } catch { }
                    try { _client?.Dispose(); } catch { }
                }
                _ws = ws;
                _client = client;
                _authenticated = true;
                authenticatedClient = true;
                return true;
            }
            catch (Exception ex) when (!cancellationToken.IsCancellationRequested)
            {
                Console.WriteLine($"[windows-foreground] rejected connection: {ex.GetType().Name}: {ex.Message}");
                return false;
            }
            finally
            {
                if (!authenticatedClient)
                {
                    // Unusable connection: close it, keep any prior session.
                    if (ws != null)
                    {
                        try { ws.Dispose(); } catch { }
                    }
                    else if (ssl != null)
                    {
                        try { ssl.Dispose(); } catch { }
                    }
                }
            }
        }

        // DPAPI (crypt32) protects data at rest for the current Windows user;
        // no plaintext secret is ever written to disk and no NuGet dependency
        // is introduced (System.Security.Cryptography.ProtectedData is a NuGet
        // package, so the two entry points are P/Invoke'd directly).
        internal static class ProtectedStore
        {
            [StructLayout(LayoutKind.Sequential)]
            private struct DATA_BLOB
            {
                public int cbData;
                public IntPtr pbData;
            }

            private const int CRYPTPROTECT_UI_FORBIDDEN = 0x01;

            [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
            private static extern bool CryptProtectData(
                ref DATA_BLOB dataIn, string? sDescription, IntPtr pOptionalEntropy,
                IntPtr pvReserved, IntPtr pPromptStruct, int dwFlags, out DATA_BLOB pDataOut);

            [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
            private static extern bool CryptUnprotectData(
                ref DATA_BLOB dataIn, out string? sDescription, IntPtr pOptionalEntropy,
                IntPtr pvReserved, IntPtr pPromptStruct, int dwFlags, out DATA_BLOB pDataOut);

            [DllImport("crypt32.dll")]
            private static extern void CryptMemFree(IntPtr pv);

            public static void Write(string secretPath, byte[] secret)
            {
                GCHandle handle = GCHandle.Alloc(secret, GCHandleType.Pinned);
                try
                {
                    var input = new DATA_BLOB { cbData = secret.Length, pbData = handle.AddrOfPinnedObject() };
                    if (!CryptProtectData(ref input, "ipad-foreground-helper", IntPtr.Zero, IntPtr.Zero,
                            IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out DATA_BLOB output))
                    {
                        throw new CryptographicException(Marshal.GetLastWin32Error());
                    }
                    try
                    {
                        byte[] protectedBytes = new byte[output.cbData];
                        Marshal.Copy(output.pbData, protectedBytes, 0, output.cbData);
                        File.WriteAllBytes(secretPath, protectedBytes);
                    }
                    finally
                    {
                        CryptMemFree(output.pbData);
                    }
                }
                finally
                {
                    handle.Free();
                }
            }

            // null when nothing was stored yet (fresh helper) or when the blob
            // cannot be unwrapped (different Windows user / wiped profile).
            public static byte[]? TryRead(string secretPath)
            {
                try
                {
                    if (!File.Exists(secretPath))
                    {
                        return null;
                    }
                    byte[] protectedBytes = File.ReadAllBytes(secretPath);
                    IntPtr blob = Marshal.AllocHGlobal(protectedBytes.Length);
                    try
                    {
                        Marshal.Copy(protectedBytes, 0, blob, protectedBytes.Length);
                        var input = new DATA_BLOB { cbData = protectedBytes.Length, pbData = blob };
                        if (!CryptUnprotectData(ref input, out _, IntPtr.Zero, IntPtr.Zero,
                                IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out DATA_BLOB output))
                        {
                            return null;
                        }
                        try
                        {
                            byte[] secret = new byte[output.cbData];
                            Marshal.Copy(output.pbData, secret, 0, output.cbData);
                            return secret;
                        }
                        finally
                        {
                            CryptMemFree(output.pbData);
                        }
                    }
                    finally
                    {
                        Marshal.FreeHGlobal(blob);
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"[windows-foreground] stored secret unreadable: {ex.GetType().Name}: {ex.Message}");
                    return null;
                }
            }
        }

        // Reads the client's HTTP upgrade headers byte-by-byte until the
        // terminating CRLF CRLF. Headers are small; simplicity beats a full
        // HTTP parser (there is no HTTP server dependency in scope).
        private static async Task<string> ReadHttpHeadAsync(Stream stream, CancellationToken cancellationToken)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(5));
            var bytes = new MemoryStream();
            var one = new byte[1];
            while (true)
            {
                int read = await stream.ReadAsync(new Memory<byte>(one), timeout.Token);
                if (read == 0)
                {
                    throw new EndOfStreamException("client closed before WebSocket handshake");
                }
                bytes.Write(one, 0, 1);
                if (bytes.Length > 4096)
                {
                    throw new InvalidDataException("HTTP handshake header overflow");
                }
                int n = (int)bytes.Length;
                if (n >= 4)
                {
                    byte[] buffer = bytes.GetBuffer();
                    if (buffer[n - 4] == (byte)'\r' && buffer[n - 3] == (byte)'\n' &&
                        buffer[n - 2] == (byte)'\r' && buffer[n - 1] == (byte)'\n')
                    {
                        return Encoding.UTF8.GetString(bytes.ToArray(), 0, n);
                    }
                }
            }
        }

        private static byte[] SHA1Hash(byte[] input)
        {
            using var sha1 = SHA1.Create();
            return sha1.ComputeHash(input);
        }
    }
}
