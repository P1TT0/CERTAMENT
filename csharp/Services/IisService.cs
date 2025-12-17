using System;
using System.Linq;
using Microsoft.Web.Administration;
using Serilog;

namespace Certament.Services
{
    /// <summary>
    /// Manages IIS application pools and HTTPS bindings.
    /// </summary>
    public class IisService
    {
        private readonly ILogger _logger;
        private const string DefaultSiteName = "Microsoft Dynamics 365 Business Central Web Client";

        public IisService(ILogger logger)
        {
            _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        }

        /// <summary>
        /// Updates the HTTPS binding certificate for the BC site.
        /// </summary>
        public bool UpdateHttpsBindingCertificate(string thumbprint, string? siteName = null)
        {
            siteName ??= DefaultSiteName;

            try
            {
                using var mgr = new ServerManager();
                var site = mgr.Sites.FirstOrDefault(s => s.Name == siteName);

                if (site == null)
                {
                    _logger.Error("Site '{SiteName}' not found in IIS", siteName);
                    return false;
                }

                var httpsBindings = site.Bindings.Where(b => b.Protocol == "https").ToList();
                if (!httpsBindings.Any())
                {
                    _logger.Warning("No HTTPS bindings found on site '{SiteName}'", siteName);
                    return false;
                }

                var thumbprintNorm = thumbprint.ToUpper().Replace(" ", "");
                int updated = 0;

                foreach (var binding in httpsBindings)
                {
                    try
                    {
                        binding.CertificateHash = System.Text.Encoding.ASCII.GetBytes(thumbprintNorm);
                        binding.CertificateStoreName = "My";
                        updated++;
                        _logger.Information("Updated binding {BindingInfo} with thumbprint {Thumbprint}",
                            binding.BindingInformation, thumbprint);
                    }
                    catch (Exception ex)
                    {
                        _logger.Error(ex, "Error updating binding {BindingInfo}", binding.BindingInformation);
                    }
                }

                if (updated > 0)
                {
                    mgr.CommitChanges();
                    _logger.Information("IIS changes committed; {UpdateCount} bindings updated", updated);
                }

                return updated > 0;
            }
            catch (Exception ex)
            {
                _logger.Error(ex, "Error updating IIS HTTPS bindings");
                return false;
            }
        }

        /// <summary>
        /// Restarts IIS (via iisreset).
        /// </summary>
        public bool RestartIis()
        {
            try
            {
                _logger.Information("Restarting IIS...");
                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "iisreset",
                    Arguments = "/noforce",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    CreateNoWindow = true
                };

                using var process = System.Diagnostics.Process.Start(psi);
                if (process == null)
                {
                    _logger.Error("Failed to start iisreset process");
                    return false;
                }

                process.WaitForExit();
                _logger.Information("IIS restart completed with exit code {ExitCode}", process.ExitCode);
                return process.ExitCode == 0;
            }
            catch (Exception ex)
            {
                _logger.Error(ex, "Error restarting IIS");
                return false;
            }
        }
    }
}
