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
//   * The connection yields no data until the device authenticates:
//       - first pairing: the exact one-time request
//         {"type":"pair","code":"<code>"} (the code shown on the local
//         Windows console). A successful pair consumes the code (one-time
//         semantics) and provisions a long-lived 256-bit device secret,
//         which the server sends to the client once, over TLS, as
//         {"type":"paired","secret":"<base64>"}.
//       - every later connection (after a Wi-Fi drop, iPad reboot, helper
//         restart): the exact request
//         {"type":"reconnect","secret":"<base64>"}. The server verifies the
//         stored long-lived secret with a fixed-time comparison, so the
//         device does not have to re-enter a code after a transient loss of
//         connectivity.
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
    public sealed class ForegroundServer
    {
        // RFC 6455 §1.3 magic GUID for the handshake accept hash.
        private const string WsHandshakeGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

        private readonly X509Certificate2 _cert;
        private readonly TcpListener _listener;
        private readonly string _secretPath;
        private string? _pairCode;
        private string? _deviceSecret;   // long-lived credential handed to the iPad at pair time
        private bool _authenticated;
        private WebSocket? _ws;

        public ForegroundServer(X509Certificate2 cert, IPEndPoint endpoint, string pairCode, string secretPath)
        {
            _cert = cert;
            _listener = new TcpListener(endpoint);
            _listener.Start(); // bind errors surface immediately (fail fast)
            _secretPath = secretPath;
            _pairCode = pairCode;
            _deviceSecret = ProtectedStore.TryRead(secretPath) is byte[] stored && stored.Length == 32
                ? Convert.ToBase64String(stored)
                : null;
        }

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

        // Accept connections one at a time (single paired iPad). Rejected or
        // unpaired connections are closed without a single byte of payload.
        public async Task AcceptLoopAsync(CancellationToken cancellationToken)
        {
            try
            {
                while (!cancellationToken.IsCancellationRequested)
                {
                    TcpClient client = await _listener.AcceptTcpClientAsync(cancellationToken);
                    if (_ws != null)
                    {
                        // A device is already paired; accept nothing else on
                        // this run — the iPad keeps the single local channel.
                        client.Dispose();
                        continue;
                    }

                    try
                    {
                        await HandleAsync(client, cancellationToken);
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine($"[windows-foreground] rejected connection: {ex.GetType().Name}: {ex.Message}");
                        try { _ws?.Dispose(); } catch { }
                        _ws = null;
                        _authenticated = false;
                    }
                    finally
                    {
                        client.Dispose();
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
            _ws = null;
            _authenticated = false;
        }

        public async Task SendForegroundChangedAsync(AppIdentity identity, CancellationToken cancellationToken)
        {
            WebSocket ws = _ws ?? throw new InvalidOperationException("no paired client");
            string json = ForegroundMapping.ForegroundChangedJson(identity);
            byte[] payload = Encoding.UTF8.GetBytes(json);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(3));
            await ws.SendAsync(new ArraySegment<byte>(payload), WebSocketMessageType.Text, endOfMessage: true, timeout.Token);
        }

        private async Task HandleAsync(TcpClient client, CancellationToken cancellationToken)
        {
            // --- TLS (mandatory; no plaintext path exists) ---
            var ssl = new SslStream(client.GetStream(), leaveInnerStreamOpen: false);
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
                ssl.Dispose();
                return;
            }

            string accept = Convert.ToBase64String(SHA1Hash(Encoding.ASCII.GetBytes(secWebSocketKey + WsHandshakeGuid)));
            byte[] responseBytes = Encoding.ASCII.GetBytes(
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                "Sec-WebSocket-Accept: " + accept + "\r\n\r\n");
            await ssl.WriteAsync(responseBytes, cancellationToken);

            // Standard WebSocket plumbing (RFC 6455 keep-alive pings only;
            // the only *data* frames ever sent are the §7.2 notifications).
            _ws = WebSocket.CreateFromStream(ssl, true, client.Client.RemoteEndPoint?.ToString() ?? "unknown", TimeSpan.FromSeconds(30));

            // --- Client authentication: exact JSON, received before any
            // outbound data. First connection proves the one-time local code;
            // every later connection proves the stored long-lived secret. ---
            string? localCode = _pairCode;
            string? storedSecret = _deviceSecret;
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
                return; // code spent and no secret stored; restart the helper to re-pair
            }

            var receiveBuffer = new byte[256];
            var received = new StringBuilder();
            using var pairTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            pairTimeout.CancelAfter(TimeSpan.FromSeconds(5));

            while (true)
            {
                WebSocketReceiveResult result = await _ws.ReceiveAsync(new ArraySegment<byte>(receiveBuffer), pairTimeout.Token);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    _ws.Dispose();
                    _ws = null;
                    return; // no pairing — send nothing, wait for next device
                }
                received.Append(Encoding.UTF8.GetString(receiveBuffer, 0, result.Count));
                if (received.Length > 64)
                {
                    _ws.Dispose();
                    _ws = null;
                    return; // oversized/unexpected frame
                }
                if (result.EndOfMessage)
                {
                    break;
                }
            }

            string actualRequest = received.ToString();
            bool authenticated = CryptographicOperations.FixedTimeEquals(
                Encoding.UTF8.GetBytes(expectedRequest),
                Encoding.UTF8.GetBytes(actualRequest));
            if (!authenticated)
            {
                _ws.Dispose();
                _ws = null;
                return; // wrong or missing credential — send nothing
            }

            if (!string.IsNullOrEmpty(localCode))
            {
                // First successful pairing: provision the durable credential
                // (32 random bytes) and hand it to the client exactly once,
                // over the already-established TLS channel. The one-time code
                // is now spent.
                var secret = new byte[32];
                RandomNumberGenerator.Fill(secret);
                ProtectedStore.Write(secretPath: _secretPath, secret);
                _deviceSecret = Convert.ToBase64String(secret);
                _pairCode = null;

                byte[] ack = Encoding.UTF8.GetBytes(
                    "{\"type\":\"paired\",\"secret\":\"" + _deviceSecret + "\"}");
                await _ws.SendAsync(new ArraySegment<byte>(ack), WebSocketMessageType.Text,
                    endOfMessage: true, cancellationToken);
                Console.WriteLine("[windows-foreground] client paired with one-time code; " +
                                  "long-lived device secret issued and stored (DPAPI-protected).");
            }
            else
            {
                byte[] ack = Encoding.UTF8.GetBytes("{\"type\":\"reconnected\"}");
                await _ws.SendAsync(new ArraySegment<byte>(ack), WebSocketMessageType.Text,
                    endOfMessage: true, cancellationToken);
                Console.WriteLine("[windows-foreground] client reconnected with stored device secret.");
            }

            _authenticated = true;
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
