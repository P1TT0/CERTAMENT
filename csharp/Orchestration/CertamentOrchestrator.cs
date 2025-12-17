using System;
using System.Security.Cryptography.X509Certificates;
using System.Threading.Tasks;
using Serilog;
using Certament.Configuration;

namespace Certament.Orchestration
{
    /// <summary>
    /// Main orchestrator for the certificate rotation workflow.
    /// </summary>
    public class CertamentOrchestrator
    {
        private readonly ILogger _logger;
        private readonly CertamentConfig _config;
        private readonly CertificateService _certService;
        private readonly IisService _iisService;
        private readonly BusinessCentralService _bcService;
        private readonly NotificationService _notificationService;

        public CertamentOrchestrator(
            ILogger logger,
            CertamentConfig config,
            CertificateService certService,
            IisService iisService,
            BusinessCentralService bcService,
            NotificationService notificationService)
        {
            _logger = logger ?? throw new ArgumentNullException(nameof(logger));
            _config = config ?? throw new ArgumentNullException(nameof(config));
            _certService = certService ?? throw new ArgumentNullException(nameof(certService));
            _iisService = iisService ?? throw new ArgumentNullException(nameof(iisService));
            _bcService = bcService ?? throw new ArgumentNullException(nameof(bcService));
            _notificationService = notificationService ?? throw new ArgumentNullException(nameof(notificationService));
        }

        /// <summary>
        /// Runs the complete certificate rotation workflow.
        /// </summary>
        public async Task<bool> ExecuteAsync(bool skipIisRestart = false, bool dryRun = false)
        {
            try
            {
                _logger.Information("CERTAMENT Orchestration starting. DryRun: {DryRun}", dryRun);

                // Step 1: Get current certificate
                _logger.Information("Step 1: Retrieving current service certificate...");
                var currentThumbprint = _bcService.GetCurrentServiceCertificateThumbprint();
                X509Certificate2? currentCert = null;

                if (!string.IsNullOrEmpty(currentThumbprint))
                {
                    currentCert = _certService.GetCertificateByThumbprint(currentThumbprint);
                    if (currentCert != null)
                    {
                        _logger.Information("Current certificate: {Subject}, Thumbprint: {Thumbprint}, Expires: {NotAfter}",
                            currentCert.Subject, currentCert.Thumbprint, currentCert.NotAfter);
                    }
                }
                else
                {
                    _logger.Warning("No current certificate found in BC configuration");
                }

                // Step 2: Find and validate PFX file
                _logger.Information("Step 2: Searching for latest PFX file...");
                var pfxPath = _certService.GetLatestPfxFile(_config.Pfx?.Path ?? "");
                if (string.IsNullOrEmpty(pfxPath))
                {
                    _logger.Warning("No PFX file found; nothing to do");
                    return true;
                }

                _logger.Information("Found PFX: {PfxPath}", pfxPath);

                // Step 3: Import PFX
                _logger.Information("Step 3: Importing PFX certificate...");
                var pfxPassword = Environment.GetEnvironmentVariable("CERTAMENT_PFX_PASSWORD") ?? _config.Pfx?.Password;
                if (string.IsNullOrEmpty(pfxPassword))
                {
                    _logger.Error("PFX password not available");
                    return false;
                }

                var pfxCert = _certService.ImportPfxCertificate(pfxPath, pfxPassword);
                if (pfxCert == null)
                {
                    _logger.Error("Failed to import PFX certificate");
                    await _notificationService.NotifyError(
                        _config.Notifications?.Webhooks?["Internal"] ?? "",
                        "PFX Import Failed",
                        $"Could not import certificate from {pfxPath}");
                    return false;
                }

                _logger.Information("PFX imported: {Subject}, Thumbprint: {Thumbprint}, Expires: {NotAfter}",
                    pfxCert.Subject, pfxCert.Thumbprint, pfxCert.NotAfter);

                // Step 4: Compare certificates
                _logger.Information("Step 4: Comparing certificates...");
                bool shouldUpdate = currentCert == null || _certService.ShouldUpdateCertificate(currentCert, pfxCert);

                if (!shouldUpdate)
                {
                    _logger.Information("Certificate is already up-to-date; no update needed");
                    return true;
                }

                _logger.Information("Certificate update needed; new thumbprint: {Thumbprint}", pfxCert.Thumbprint);

                if (dryRun)
                {
                    _logger.Information("DryRun mode: skipping actual updates");
                    return true;
                }

                // Step 5: Update BC service certificate
                _logger.Information("Step 5: Updating Business Central service certificate...");
                if (!_bcService.UpdateServiceCertificateThumbprint(pfxCert.Thumbprint))
                {
                    _logger.Error("Failed to update BC service certificate");
                    await _notificationService.NotifyError(
                        _config.Notifications?.Webhooks?["Internal"] ?? "",
                        "BC Update Failed",
                        "Could not update Business Central service certificate");
                    return false;
                }

                // Step 6: Update IIS binding
                _logger.Information("Step 6: Updating IIS HTTPS binding...");
                var siteName = _config.BusinessCentral?.IisBindingSite;
                if (!_iisService.UpdateHttpsBindingCertificate(pfxCert.Thumbprint, siteName))
                {
                    _logger.Error("Failed to update IIS binding");
                    await _notificationService.NotifyError(
                        _config.Notifications?.Webhooks?["Internal"] ?? "",
                        "IIS Update Failed",
                        "Could not update IIS HTTPS binding");
                    return false;
                }

                // Step 7: Restart IIS (if not skipped)
                _logger.Information("Step 7: Restarting IIS...");
                if (!skipIisRestart)
                {
                    if (!_iisService.RestartIis())
                    {
                        _logger.Error("Failed to restart IIS");
                    }
                }
                else
                {
                    _logger.Information("IIS restart skipped");
                }

                // Step 8: Test connectivity
                _logger.Information("Step 8: Testing BC web services connectivity...");
                var connectivityOk = _bcService.TestWebServicesConnectivity();
                if (connectivityOk)
                {
                    _logger.Information("Web services test passed");
                }
                else
                {
                    _logger.Warning("Web services test failed; check services manually");
                }

                // Step 9: Send success notification
                _logger.Information("Step 9: Sending notifications...");
                if (_config.Notifications?.EnableWebhook == true)
                {
                    var webhookUrl = _config.Notifications?.Webhooks?["Internal"];
                    if (!string.IsNullOrEmpty(webhookUrl))
                    {
                        await _notificationService.NotifyCertificateUpdate(
                            webhookUrl,
                            pfxCert.Subject,
                            pfxCert.Thumbprint,
                            pfxCert.NotAfter);
                    }
                }

                _logger.Information("CERTAMENT Orchestration completed successfully");
                return true;
            }
            catch (Exception ex)
            {
                _logger.Fatal(ex, "Unhandled exception in orchestration");
                return false;
            }
        }
    }
}
