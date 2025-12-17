using System;
using Serilog;
using Certament.Services;
using Certament.Configuration;

namespace Certament
{
    /// <summary>
    /// Main orchestrator for CERTAMENT certificate rotation workflow.
    /// </summary>
    class Program
    {
        static int Main(string[] args)
        {
            // Configure logging
            Log.Logger = new LoggerConfiguration()
                .MinimumLevel.Information()
                .WriteTo.Console()
                .WriteTo.File("logs/certament-.txt", rollingInterval: RollingInterval.Day)
                .CreateLogger();

            try
            {
                var logger = Log.ForContext<Program>();
                logger.Information("CERTAMENT starting...");

                // Verify admin privileges
                if (!IsRunningAsAdmin())
                {
                    logger.Fatal("CERTAMENT requires administrator privileges");
                    return 1;
                }

                // Load configuration
                var configPath = System.IO.Path.Combine(AppContext.BaseDirectory, "config.json");
                var configLoader = new ConfigurationLoader(logger);
                var config = configLoader.LoadFromFile(configPath);

                if (config == null)
                {
                    logger.Fatal("Failed to load configuration");
                    return 1;
                }

                // Validate PFX path
                if (string.IsNullOrWhiteSpace(config.Pfx?.Path))
                {
                    logger.Fatal("PFX path not configured");
                    return 1;
                }

                // Get PFX password
                var pfxPassword = configLoader.ResolvePfxPassword(config);
                if (string.IsNullOrEmpty(pfxPassword))
                {
                    logger.Fatal("Could not resolve PFX password");
                    return 1;
                }

                // Services
                var certService = new CertificateService(logger);
                var iisService = new IisService(logger);

                // Get latest PFX
                var pfxPath = certService.GetLatestPfxFile(config.Pfx.Path);
                if (string.IsNullOrEmpty(pfxPath))
                {
                    logger.Warning("No PFX file found");
                    return 0;
                }

                // Import PFX
                var importedCert = certService.ImportPfxCertificate(pfxPath, pfxPassword);
                if (importedCert == null)
                {
                    logger.Error("Failed to import PFX certificate");
                    return 1;
                }

                logger.Information("Certificate imported: {Subject}, Thumbprint: {Thumbprint}",
                    importedCert.Subject, importedCert.Thumbprint);

                // Update IIS binding
                var siteName = config.BusinessCentral?.IisBindingSite;
                if (!iisService.UpdateHttpsBindingCertificate(importedCert.Thumbprint, siteName))
                {
                    logger.Warning("Failed to update IIS binding");
                }

                // Restart IIS (optional)
                if (args.Contains("--no-iis-restart"))
                {
                    logger.Information("Skipping IIS restart (--no-iis-restart)");
                }
                else
                {
                    iisService.RestartIis();
                }

                logger.Information("CERTAMENT completed successfully");
                return 0;
            }
            catch (Exception ex)
            {
                Log.Fatal(ex, "Unhandled exception in CERTAMENT");
                return 1;
            }
            finally
            {
                Log.CloseAndFlush();
            }
        }

        static bool IsRunningAsAdmin()
        {
            try
            {
                var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
                var principal = new System.Security.Principal.WindowsPrincipal(identity);
                return principal.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
            }
            catch
            {
                return false;
            }
        }
    }
}
