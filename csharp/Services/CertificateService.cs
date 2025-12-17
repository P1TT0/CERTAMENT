using System;
using System.Security.Cryptography.X509Certificates;
using System.Diagnostics;
using Serilog;

namespace Certament.Services
{
    /// <summary>
    /// Manages X.509 certificates in the local machine certificate store.
    /// </summary>
    public class CertificateService
    {
        private readonly ILogger _logger;

        public CertificateService(ILogger logger)
        {
            _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        }

        /// <summary>
        /// Retrieves a certificate by thumbprint from LocalMachine\My store.
        /// </summary>
        public X509Certificate2? GetCertificateByThumbprint(string thumbprint)
        {
            if (string.IsNullOrWhiteSpace(thumbprint))
            {
                _logger.Warning("Thumbprint is empty or null");
                return null;
            }

            try
            {
                using var store = new X509Store(StoreName.My, StoreLocation.LocalMachine);
                store.Open(OpenFlags.ReadOnly);

                var certs = store.Certificates.Find(
                    X509FindType.FindByThumbprint,
                    thumbprint.ToUpper().Replace(" ", ""),
                    validOnly: false
                );

                if (certs.Count == 0)
                {
                    _logger.Warning("Certificate with thumbprint {Thumbprint} not found", thumbprint);
                    return null;
                }

                _logger.Information("Found certificate: {Subject}, expires {NotAfter}",
                    certs[0].Subject, certs[0].NotAfter);

                return certs[0];
            }
            catch (Exception ex)
            {
                _logger.Error(ex, "Error retrieving certificate by thumbprint {Thumbprint}", thumbprint);
                return null;
            }
        }

        /// <summary>
        /// Imports a PFX certificate into LocalMachine\My store.
        /// </summary>
        public X509Certificate2? ImportPfxCertificate(string pfxPath, string password)
        {
            if (!System.IO.File.Exists(pfxPath))
            {
                _logger.Error("PFX file not found: {PfxPath}", pfxPath);
                return null;
            }

            try
            {
                var cert = new X509Certificate2(pfxPath, password, X509KeyStorageFlags.Exportable | X509KeyStorageFlags.PersistKeySet);

                using var store = new X509Store(StoreName.My, StoreLocation.LocalMachine);
                store.Open(OpenFlags.ReadWrite);
                store.Add(cert);
                store.Close();

                _logger.Information("Certificate imported successfully: {Subject}, Thumbprint: {Thumbprint}",
                    cert.Subject, cert.Thumbprint);

                return cert;
            }
            catch (Exception ex)
            {
                _logger.Error(ex, "Error importing PFX certificate from {PfxPath}", pfxPath);
                return null;
            }
        }

        /// <summary>
        /// Gets the newest PFX file from a directory.
        /// </summary>
        public string? GetLatestPfxFile(string directoryPath)
        {
            if (!System.IO.Directory.Exists(directoryPath))
            {
                _logger.Warning("Directory not found: {DirectoryPath}", directoryPath);
                return null;
            }

            try
            {
                var di = new System.IO.DirectoryInfo(directoryPath);
                var pfxFiles = di.GetFiles("*.pfx", System.IO.SearchOption.TopDirectoryOnly);

                if (pfxFiles.Length == 0)
                {
                    _logger.Warning("No PFX files found in {DirectoryPath}", directoryPath);
                    return null;
                }

                var latest = pfxFiles[0];
                foreach (var file in pfxFiles)
                {
                    if (file.LastWriteTime > latest.LastWriteTime)
                        latest = file;
                }

                _logger.Information("Found latest PFX: {FileName} (modified {LastWriteTime})",
                    latest.Name, latest.LastWriteTime);

                return latest.FullName;
            }
            catch (Exception ex)
            {
                _logger.Error(ex, "Error retrieving latest PFX from {DirectoryPath}", directoryPath);
                return null;
            }
        }

        /// <summary>
        /// Compares two certificates and returns true if pfx is newer.
        /// </summary>
        public bool ShouldUpdateCertificate(X509Certificate2 current, X509Certificate2 pfx)
        {
            if (current.Thumbprint == pfx.Thumbprint)
            {
                _logger.Information("Certificates have same thumbprint—no update needed");
                return false;
            }

            var pfxExpiry = pfx.NotAfter;
            var currentExpiry = current.NotAfter;

            var shouldUpdate = pfxExpiry > currentExpiry;
            _logger.Information("Certificate comparison: Current expires {CurrentExpiry}, PFX expires {PfxExpiry} → Update: {ShouldUpdate}",
                currentExpiry, pfxExpiry, shouldUpdate);

            return shouldUpdate;
        }
    }
}
