using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.IO;
using Serilog;

namespace Certament.Configuration
{
    /// <summary>
    /// Configuration model and loader for CERTAMENT.
    /// </summary>
    public class CertamentConfig
    {
        public PfxConfig? Pfx { get; set; }
        public BusinessCentralConfig? BusinessCentral { get; set; }
        public NotificationsConfig? Notifications { get; set; }
    }

    public class PfxConfig
    {
        public string? Path { get; set; }
        public string? Password { get; set; }
        public bool AutoSelectLatest { get; set; } = true;
    }

    public class BusinessCentralConfig
    {
        public bool UseLatestModule { get; set; }
        public string? IisBindingSite { get; set; }
    }

    public class NotificationsConfig
    {
        public bool EnableWebhook { get; set; }
        public Dictionary<string, string>? Webhooks { get; set; }
    }

    /// <summary>
    /// Loads and validates configuration from JSON.
    /// </summary>
    public class ConfigurationLoader
    {
        private readonly ILogger _logger;

        public ConfigurationLoader(ILogger logger)
        {
            _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        }

        public CertamentConfig? LoadFromFile(string configPath)
        {
            if (!File.Exists(configPath))
            {
                _logger.Error("Configuration file not found: {ConfigPath}", configPath);
                return null;
            }

            try
            {
                var json = File.ReadAllText(configPath);
                var options = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
                var config = JsonSerializer.Deserialize<CertamentConfig>(json, options);

                if (config == null)
                {
                    _logger.Error("Failed to deserialize configuration");
                    return null;
                }

                _logger.Information("Configuration loaded from {ConfigPath}", configPath);
                return config;
            }
            catch (Exception ex)
            {
                _logger.Error(ex, "Error loading configuration from {ConfigPath}", configPath);
                return null;
            }
        }

        public string? ResolvePfxPassword(CertamentConfig config)
        {
            // Priority: env var > config file > prompt
            var envPassword = Environment.GetEnvironmentVariable("CERTAMENT_PFX_PASSWORD");
            if (!string.IsNullOrEmpty(envPassword))
            {
                _logger.Information("PFX password resolved from environment variable");
                return envPassword;
            }

            if (!string.IsNullOrEmpty(config.Pfx?.Password))
            {
                _logger.Warning("PFX password from config file is not recommended; use env var instead");
                return config.Pfx.Password;
            }

            // Could add interactive prompt here if needed
            _logger.Error("No PFX password found in environment or config");
            return null;
        }
    }
}
