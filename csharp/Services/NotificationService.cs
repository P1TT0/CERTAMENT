using System;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using Serilog;

namespace Certament.Services
{
    /// <summary>
    /// Sends notifications via webhooks (e.g., Power Automate, Teams).
    /// </summary>
    public class NotificationService
    {
        private readonly ILogger _logger;
        private readonly HttpClient _httpClient;

        public NotificationService(ILogger logger)
        {
            _logger = logger ?? throw new ArgumentNullException(nameof(logger));
            _httpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        }

        /// <summary>
        /// Sends a notification to a webhook URL.
        /// </summary>
        public async Task<bool> SendWebhookNotification(string webhookUrl, string title, string message, string? target = null)
        {
            if (string.IsNullOrWhiteSpace(webhookUrl))
            {
                _logger.Warning("Webhook URL is empty; skipping notification");
                return false;
            }

            try
            {
                var payload = new
                {
                    type = "message",
                    attachments = new[]
                    {
                        new
                        {
                            contentType = "application/vnd.microsoft.card.adaptive",
                            content = new
                            {
                                @$schema = "http://adaptivecards.io/schemas/adaptive-card.json",
                                type = "AdaptiveCard",
                                version = "1.4",
                                body = new object[]
                                {
                                    new
                                    {
                                        type = "TextBlock",
                                        text = title,
                                        weight = "Bolder",
                                        size = "Medium"
                                    },
                                    new
                                    {
                                        type = "TextBlock",
                                        text = message,
                                        wrap = true
                                    }
                                }
                            }
                        }
                    }
                };

                var json = JsonSerializer.Serialize(payload);
                var content = new StringContent(json, System.Text.Encoding.UTF8, "application/json");

                var response = await _httpClient.PostAsync(webhookUrl, content);

                if (response.IsSuccessStatusCode)
                {
                    _logger.Information("Notification sent successfully to {Target}: {Title}", target ?? "webhook", title);
                    return true;
                }
                else
                {
                    _logger.Warning("Webhook notification failed with status {StatusCode} to {Target}",
                        (int)response.StatusCode, target ?? "webhook");
                    return false;
                }
            }
            catch (Exception ex)
            {
                _logger.Error(ex, "Error sending webhook notification to {Target}", target ?? "webhook");
                return false;
            }
        }

        /// <summary>
        /// Sends a certificate update notification.
        /// </summary>
        public async Task<bool> NotifyCertificateUpdate(string webhookUrl, string subject, string thumbprint, DateTime expiresAt)
        {
            var title = "CERTAMENT – Certificate Updated";
            var message = $@"Subject: {subject}
Thumbprint: {thumbprint}
Expires: {expiresAt:yyyy-MM-dd HH:mm:ss}";

            return await SendWebhookNotification(webhookUrl, title, message, "certificate-update");
        }

        /// <summary>
        /// Sends an expiry warning notification.
        /// </summary>
        public async Task<bool> NotifyExpiryWarning(string webhookUrl, string subject, DateTime expiresAt, int daysRemaining)
        {
            var title = "CERTAMENT – Certificate Expiry Warning";
            var message = $@"Subject: {subject}
Expires: {expiresAt:yyyy-MM-dd}
Days remaining: {daysRemaining}";

            return await SendWebhookNotification(webhookUrl, title, message, "expiry-warning");
        }

        /// <summary>
        /// Sends an error notification.
        /// </summary>
        public async Task<bool> NotifyError(string webhookUrl, string errorTitle, string errorMessage)
        {
            var title = "CERTAMENT – Error";
            var message = $@"{errorTitle}
{errorMessage}";

            return await SendWebhookNotification(webhookUrl, title, message, "error");
        }
    }
}
