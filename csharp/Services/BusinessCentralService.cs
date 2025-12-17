using System;
using System.Diagnostics;
using System.Linq;
using Serilog;

namespace Certament.Services
{
    /// <summary>
    /// Manages Dynamics 365 Business Central service instances and certificates.
    /// </summary>
    public class BusinessCentralService
    {
        private readonly ILogger _logger;

        public BusinessCentralService(ILogger logger)
        {
            _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        }

        /// <summary>
        /// Gets the current service certificate thumbprint from BC instances via registry/WMI.
        /// </summary>
        public string? GetCurrentServiceCertificateThumbprint()
        {
            try
            {
                // Query via WMI for NAV server instances (requires BC management tools)
                var psi = new ProcessStartInfo
                {
                    FileName = "powershell",
                    Arguments = "-NoProfile -Command \"Get-NAVServerInstance | Select-Object -ExpandProperty ServerInstance -First 1\"",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                };

                using var process = Process.Start(psi);
                if (process == null)
                {
                    _logger.Warning("Could not query BC instances");
                    return null;
                }

                var output = process.StandardOutput.ReadToEnd().Trim();
                process.WaitForExit();

                if (string.IsNullOrEmpty(output))
                {
                    _logger.Warning("No BC instances found");
                    return null;
                }

                var instanceName = output.Split('\n').FirstOrDefault()?.Trim();
                if (string.IsNullOrEmpty(instanceName))
                {
                    _logger.Warning("Could not parse BC instance name");
                    return null;
                }

                // Get thumbprint from registry
                var thumbprint = GetBcInstanceThumbprintFromRegistry(instanceName);
                if (!string.IsNullOrEmpty(thumbprint))
                {
                    _logger.Information("Retrieved BC certificate thumbprint for instance {Instance}: {Thumbprint}",
                        instanceName, thumbprint);
                }
                else
                {
                    _logger.Warning("No certificate thumbprint found for BC instance {Instance}", instanceName);
                }

                return thumbprint;
            }
            catch (Exception ex)
            {
                _logger.Error(ex, "Error retrieving BC service certificate thumbprint");
                return null;
            }
        }

        /// <summary>
        /// Updates the service certificate thumbprint for all BC instances.
        /// </summary>
        public bool UpdateServiceCertificateThumbprint(string newThumbprint)
        {
            if (string.IsNullOrWhiteSpace(newThumbprint))
            {
                _logger.Error("New thumbprint is empty");
                return false;
            }

            try
            {
                _logger.Information("Updating BC service certificate to {Thumbprint}", newThumbprint);

                var psScript = $@"
Get-NAVServerInstance | ForEach-Object {{
    $instance = $_.ServerInstance
    Write-Host ""Updating instance: $instance""
    Set-NAVServerConfiguration -ServerInstance $instance -KeyName 'ServicesCertificateThumbprint' -KeyValue '{newThumbprint}' -Force
    Restart-NAVServerInstance -ServerInstance $instance -Force
    Write-Host ""Instance $instance updated and restarted""
}}
";

                var psi = new ProcessStartInfo
                {
                    FileName = "powershell",
                    Arguments = $"-NoProfile -Command \"{psScript.Replace("\"", "\\\"\").Replace(Environment.NewLine, "; ")}\"",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                };

                using var process = Process.Start(psi);
                if (process == null)
                {
                    _logger.Error("Could not start PowerShell process for BC update");
                    return false;
                }

                var output = process.StandardOutput.ReadToEnd();
                var errors = process.StandardError.ReadToEnd();

                process.WaitForExit();

                if (process.ExitCode != 0)
                {
                    _logger.Error("BC certificate update failed with exit code {ExitCode}. Errors: {Errors}",
                        process.ExitCode, errors);
                    return false;
                }

                _logger.Information("BC service certificate updated successfully. Output: {Output}", output);
                return true;
            }
            catch (Exception ex)
            {
                _logger.Error(ex, "Error updating BC service certificate");
                return false;
            }
        }

        /// <summary>
        /// Tests connectivity to BC web services (OData/SOAP).
        /// </summary>
        public bool TestWebServicesConnectivity(string? baseUrl = null)
        {
            try
            {
                _logger.Information("Testing BC web services connectivity");

                var psScript = @"
try {
    $instances = Get-NAVServerInstance
    foreach ($inst in $instances) {
        $odataUrl = (Get-NAVServerConfiguration -ServerInstance $inst.ServerInstance -KeyName 'PublicODataBaseUrl' -ErrorAction SilentlyContinue)
        if ($odataUrl) {
            $resp = Invoke-WebRequest -Uri $odataUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
            if ($resp.StatusCode -eq 200 -or $resp.StatusCode -eq 401) {
                Write-Host 'OK'
                exit 0
            }
        }
    }
    exit 1
} catch {
    exit 1
}
";

                var psi = new ProcessStartInfo
                {
                    FileName = "powershell",
                    Arguments = $"-NoProfile -Command \"{psScript.Replace("\"", "\\\"\").Replace(Environment.NewLine, "; ")}\"",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    CreateNoWindow = true
                };

                using var process = Process.Start(psi);
                if (process == null)
                {
                    _logger.Warning("Could not test web services");
                    return false;
                }

                process.WaitForExit();
                var result = process.ExitCode == 0;

                _logger.Information("BC web services connectivity test: {Result}", result ? "OK" : "FAILED");
                return result;
            }
            catch (Exception ex)
            {
                _logger.Error(ex, "Error testing BC web services");
                return false;
            }
        }

        private string? GetBcInstanceThumbprintFromRegistry(string instanceName)
        {
            try
            {
                var regPath = $"HKLM:\\SOFTWARE\\Microsoft\\Dynamics\\365\\BC\\{instanceName}";
                
                var psi = new ProcessStartInfo
                {
                    FileName = "powershell",
                    Arguments = $"-NoProfile -Command \"Get-ItemProperty -Path '{regPath}' -Name 'ServicesCertificateThumbprint' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ServicesCertificateThumbprint\"",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    CreateNoWindow = true
                };

                using var process = Process.Start(psi);
                if (process == null)
                    return null;

                var output = process.StandardOutput.ReadToEnd().Trim();
                process.WaitForExit();

                return string.IsNullOrEmpty(output) ? null : output;
            }
            catch
            {
                return null;
            }
        }
    }
}
