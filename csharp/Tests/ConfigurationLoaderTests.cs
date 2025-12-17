using System;
using Xunit;
using Serilog;
using Certament.Configuration;

namespace Certament.Tests
{
    public class ConfigurationLoaderTests
    {
        private readonly ILogger _logger;

        public ConfigurationLoaderTests()
        {
            _logger = new LoggerConfiguration()
                .MinimumLevel.Debug()
                .WriteTo.Console()
                .CreateLogger();
        }

        [Fact]
        public void LoadFromFile_WithValidConfig_ReturnsConfig()
        {
            // Create a temporary config file
            var tempDir = System.IO.Path.GetTempPath();
            var configFile = System.IO.Path.Combine(tempDir, "test-config.json");
            var testConfig = @"{
  ""Pfx"": {
    ""Path"": ""C:\\test"",
    ""Password"": """",
    ""AutoSelectLatest"": true
  },
  ""BusinessCentral"": {
    ""UseLatestModule"": true,
    ""IisBindingSite"": ""Test Site""
  }
}";
            System.IO.File.WriteAllText(configFile, testConfig);

            try
            {
                var loader = new ConfigurationLoader(_logger);
                var config = loader.LoadFromFile(configFile);

                Assert.NotNull(config);
                Assert.NotNull(config.Pfx);
                Assert.Equal("C:\\test", config.Pfx.Path);
                Assert.True(config.Pfx.AutoSelectLatest);
            }
            finally
            {
                if (System.IO.File.Exists(configFile))
                    System.IO.File.Delete(configFile);
            }
        }

        [Fact]
        public void LoadFromFile_WithMissingFile_ReturnsNull()
        {
            var loader = new ConfigurationLoader(_logger);
            var config = loader.LoadFromFile("/nonexistent/path/config.json");

            Assert.Null(config);
        }

        [Fact]
        public void ResolvePfxPassword_WithEnvVar_ReturnsEnvVar()
        {
            var loader = new ConfigurationLoader(_logger);
            var testPassword = "test-password-12345";
            
            Environment.SetEnvironmentVariable("CERTAMENT_PFX_PASSWORD", testPassword);

            try
            {
                var config = new CertamentConfig
                {
                    Pfx = new PfxConfig { Password = "config-password" }
                };

                var password = loader.ResolvePfxPassword(config);
                Assert.Equal(testPassword, password);
            }
            finally
            {
                Environment.SetEnvironmentVariable("CERTAMENT_PFX_PASSWORD", null);
            }
        }

        [Fact]
        public void ResolvePfxPassword_WithConfigPassword_ReturnsConfigPassword()
        {
            var loader = new ConfigurationLoader(_logger);
            Environment.SetEnvironmentVariable("CERTAMENT_PFX_PASSWORD", null);

            var config = new CertamentConfig
            {
                Pfx = new PfxConfig { Password = "config-password" }
            };

            var password = loader.ResolvePfxPassword(config);
            Assert.Equal("config-password", password);
        }
    }
}
