using System;
using System.Threading.Tasks;
using Serilog;
using Certament.Services;
using Certament.Configuration;
using Certament.Orchestration;

namespace Certament
{
    /// <summary>
    /// Main entry point for CERTAMENT.
    /// </summary>
    class Program
    {
        static async Task<int> Main(string[] args)
        {
            // Configure logging
            Log.Logger = new LoggerConfiguration()
                .MinimumLevel.Information()
                .WriteTo.Console(outputTemplate: "[{Timestamp:yyyy-MM-dd HH:mm:ss}] [{Level:u3}] {Message:lj}{NewLine}{Exception}")
                .WriteTo.File(
                    "logs/certament-.txt",
                    rollingInterval: RollingInterval.Day,
                    outputTemplate: "[{Timestamp:yyyy-MM-dd HH:mm:ss}] [{Level:u3}] {Message:lj}{NewLine}{Exception}",
                    retainedFileCountLimit: 30)
                .CreateLogger();

            try
            {
                var logger = Log.ForContext<Program>();
                logger.Information("╔════════════════════════════════════════════════════════════╗");
                logger.Information("║         CERTAMENT – Certificate Rotation Manager           ║");
                logger.Information("║                    v0.2.0 (C# Edition)                    ║");
                logger.Information("╚════════════════════════════════════════════════════════════╝");

                // Verify admin privileges
                if (!IsRunningAsAdmin())
                {
                    logger.Fatal("CERTAMENT requires administrator privileges");
                    return 1;
                }

                // Parse arguments
                bool skipIisRestart = args.Contains("--skip-iis-restart");
                bool dryRun = args.Contains("--dry-run");
                bool skipNotifications = args.Contains("--skip-notifications");

                if (dryRun)
                    logger.Information("DRY RUN MODE: No changes will be applied");

                // Load configuration
                var configPath = System.IO.Path.Combine(AppContext.BaseDirectory, "config.json");
                var configLoader = new ConfigurationLoader(logger);
                var config = configLoader.LoadFromFile(configPath);

                if (config == null)
                {
                    logger.Fatal("Failed to load configuration from {ConfigPath}", configPath);
                    return 1;
                }

                // Validate configuration
                if (string.IsNullOrWhiteSpace(config.Pfx?.Path))
                {
                    logger.Fatal("PFX path not configured");
                    return 1;
                }

                // Initialize services
                var certService = new CertificateService(logger);
                var iisService = new IisService(logger);
                var bcService = new BusinessCentralService(logger);
                var notificationService = new NotificationService(logger);

                // Create and execute orchestrator
                var orchestrator = new CertamentOrchestrator(
                    logger,
                    config,
                    certService,
                    iisService,
                    bcService,
                    notificationService);

                var result = await orchestrator.ExecuteAsync(skipIisRestart, dryRun);

                if (result)
                {
                    logger.Information("CERTAMENT completed successfully");
                    return 0;
                }
                else
                {
                    logger.Error("CERTAMENT completed with errors");
                    return 1;
                }
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
