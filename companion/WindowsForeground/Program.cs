// Entry point for the Windows 10/11 companion helper (SPEC §7.2, spec
// commit b751488). Three parts:
//
//   * ForegroundMapping — pure executable → app-identity mapping (unit tested),
//   * ForegroundWatcher — Win32 polling of the foreground window's process,
//   * ForegroundServer  — local TLS WebSocket that authenticates the client
//     and then only ever emits the single bounded message
//     {"type":"foreground-changed","identity":"<token>"}.
//
// Pairing model: the helper binds one private/local IPv4 address, prints a
// one-time local code plus the SHA-256 fingerprint of its persisted TLS
// certificate, and waits for the iPad. Until the connecting device sends the
// exact {"type":"pair","code":"<code>"} message, the helper sends no data at
// all; after that exchange the server hands the device a long-lived 256-bit
// secret (DPAPI-protected on disk) so a later reconnect authenticates with
// {"type":"reconnect","secret":"<secret>"} instead of a new code.
// The helper never sends HID commands and never reports window titles,
// arbitrary process data, or executable names; unknown executables map to
// "generic" (SPEC §7.1/§7.2 E).
using System;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Threading;
using System.Threading.Tasks;

namespace WindowsForeground
{
    public static class Program
    {
        private const int DefaultPort = 8443;
        private const int PollMilliseconds = 350;

        private static async Task<int> Main(string[] args)
        {
            if (!OperatingSystem.IsWindows())
            {
                Console.Error.WriteLine("WindowsForeground only runs on Windows 10/11 (SPEC §7.2); exiting without starting.");
                return 1;
            }

            try
            {
                int port = DefaultPort;
                if (args.Length > 0)
                {
                    if (!int.TryParse(args[0], out port) || port < 1 || port > 65535)
                    {
                        Console.Error.WriteLine($"usage: WindowsForeground [port]   (default {DefaultPort})");
                        return 1;
                    }
                }

                // §7.2: the endpoint must be local-only. Never bind a wildcard
                // address; bind one concrete private/local IPv4 interface.
                if (TrySelectLocalEndPoint(port) is not IPEndPoint endpoint)
                {
                    Console.Error.WriteLine(
                        "[windows-foreground] no private/local IPv4 interface found (RFC 1918 or loopback); " +
                        "refusing to start rather than exposing the helper on a public interface.");
                    return 1;
                }

                // Durable pairing material: the TLS key pair and the device
                // secret are persisted DPAPI-protected under the current user's
                // local app data, so the certificate can be pinned by the iPad
                // and survives restarts. Nothing secret is stored in the repo.
                string dataDirectory = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "iPadForegroundHelper");
                Directory.CreateDirectory(dataDirectory);
                string certPath = Path.Combine(dataDirectory, "tls-cert.pfx");
                string secretPath = Path.Combine(dataDirectory, "device-secret.bin");

                X509Certificate2 cert = LoadPersistedCert(certPath) ?? CreateSelfSignedCert(certPath);

                // The pairing code is the only secret proving the connecting
                // device is the user's iPad. It is local (read off this
                // console), one-time (consumed on the first successful pair),
                // and is never sent to any third party.
                string pairCode = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");

                var server = new ForegroundServer(cert, endpoint, pairCode, secretPath);
                _ = server.AcceptLoopAsync(CancellationToken.None);

                Console.WriteLine($"[windows-foreground] listening on {endpoint}");
                Console.WriteLine("[windows-foreground] TLS certificate SHA-256 fingerprint " +
                                  $"(pin this on the iPad): {cert.GetCertHashString(HashAlgorithmName.SHA256)}");
                byte[]? storedSecret = ForegroundServer.ProtectedStore.TryRead(secretPath);
                if (storedSecret == null || storedSecret.Length == 0)
                {
                    Console.WriteLine($"[windows-foreground] one-time pairing code: {pairCode}");
                }
                else
                {
                    Console.WriteLine("[windows-foreground] device secret already stored; " +
                                      "waiting for the iPad to reconnect with it.");
                }
                Console.WriteLine("[windows-foreground] waiting for iPad authentication " +
                                  "(enter the code above in the iPad app, or let it reconnect with its stored secret)...");

                var watcher = new ForegroundWatcher();
                string lastToken = string.Empty;
                while (true)
                {
                    await Task.Delay(PollMilliseconds);
                    if (!server.IsPaired)
                    {
                        continue;
                    }

                    AppIdentity identity = watcher.Current();
                    string token = ForegroundMapping.Token(identity);
                    if (token == lastToken)
                    {
                        continue;
                    }

                    try
                    {
                        await server.SendForegroundChangedAsync(identity, CancellationToken.None);
                        lastToken = token;
                    }
                    catch (Exception ex)
                    {
                        // iPad disconnected; keep listening. The same device
                        // re-authenticates with its stored long-lived secret
                        // (no new code). lastToken is reset so the new client
                        // always receives an initial identity.
                        Console.WriteLine($"[windows-foreground] lost client: {ex.GetType().Name}: {ex.Message}");
                        server.ForgetClient();
                        lastToken = string.Empty;
                    }
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[windows-foreground] fatal: {ex.GetType().Name}: {ex.Message}");
                return 1;
            }
        }

        // Picks the first operational, non-tunnel interface that owns a
        // private/local IPv4 unicast address. Returns null when there is none
        // (the helper then refuses to start instead of listening on a public
        // or wildcard address).
        private static IPEndPoint? TrySelectLocalEndPoint(int port)
        {
            foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up ||
                    nic.NetworkInterfaceType == NetworkInterfaceType.Tunnel)
                {
                    continue;
                }
                foreach (UnicastIPAddressInformation unicast in nic.GetIPProperties().UnicastAddresses)
                {
                    if (ForegroundServer.IsLocalPrivateAddress(unicast.Address))
                    {
                        return new IPEndPoint(unicast.Address, port);
                    }
                }
            }
            return null;
        }

        // Reuses the previously generated TLS key pair so the iPad can pin one
        // certificate across restarts. The PFX (key + certificate) is stored
        // DPAPI-protected for the current Windows user, never in the repository
        // and never as plaintext.
        private static X509Certificate2? LoadPersistedCert(string certPath)
        {
            try
            {
                byte[]? pfx = ForegroundServer.ProtectedStore.TryRead(certPath);
                if (pfx == null || pfx.Length == 0)
                {
                    return null;
                }
                var cert = new X509Certificate2(pfx, (string?)null,
                    X509KeyStorageFlags.Exportable | X509KeyStorageFlags.EphemeralKeySet);
                return cert.HasPrivateKey ? cert : null;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[windows-foreground] stored certificate unusable ({ex.GetType().Name}); " +
                                  "generating a new one — the iPad must re-pin the new fingerprint.");
                return null;
            }
        }

        // Runtime-generated self-signed TLS certificate (no NuGet, no
        // provisioning). The key is re-imported through an ephemeral PFX so
        // SslStream gets a key blob usable by the OS TLS stack. The PFX is
        // persisted DPAPI-protected, so the same key pair (and therefore the
        // same pinned fingerprint) survives helper restarts.
        //
        // Open (tracked): the iPad must TOFU-pin this certificate (or ship a
        // private CA) for full MITM resistance; until the iOS side is built,
        // TLS+one-time-code is the real Windows-side implementation and no
        // plaintext fallback exists.
        private static X509Certificate2 CreateSelfSignedCert(string certPath)
        {
            using RSA rsa = RSA.Create(2048);
            var request = new CertificateRequest(
                "CN=ipad-foreground-helper",
                rsa,
                HashAlgorithmName.SHA256,
                RSASignaturePadding.Pkcs1);
            request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
            request.CertificateExtensions.Add(new X509KeyUsageExtension(
                X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment,
                critical: false));

            DateTimeOffset now = DateTimeOffset.UtcNow;
            using X509Certificate2 generated = request.CreateSelfSigned(now.AddMinutes(-5), now.AddDays(30));
            byte[] pfx = generated.Export(X509ContentType.Pfx);
            ForegroundServer.ProtectedStore.Write(certPath, pfx);
            return new X509Certificate2(pfx, (string?)null,
                X509KeyStorageFlags.Exportable | X509KeyStorageFlags.EphemeralKeySet);
        }
    }
}
