using System.Text.Json;

namespace CopilotAgent;

/// <summary>
/// Fake escalation tool for the support-case PoC, exposed as the <c>escalate</c> subcommand of the
/// agent binary (see Program.cs). Simulates raising an escalation ticket with a human support team
/// and prints a randomly generated ticket reference as JSON. Nothing is actually sent anywhere.
/// </summary>
internal static class EscalationTool
{
    public static int Run(string[] args)
    {
        var ticket = new
        {
            ticket_number = GenerateTicketNumber(),
            status = "Escalated",
            queue = "Tier 2 Support",
            created_utc = DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:sszzz"),
            summary = GetArg(args, "--summary"),
            account = GetArg(args, "--account"),
            application = GetArg(args, "--application"),
            note = "Simulated escalation. This is a proof-of-concept stub; no ticket was actually created.",
        };

        Console.WriteLine(JsonSerializer.Serialize(ticket, new JsonSerializerOptions { WriteIndented = true }));
        return 0;
    }

    private static string GenerateTicketNumber()
    {
        const string chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        Span<char> buffer = stackalloc char[7];
        for (int i = 0; i < buffer.Length; i++)
        {
            buffer[i] = chars[Random.Shared.Next(chars.Length)];
        }

        return $"ESC-{new string(buffer)}";
    }

    private static string GetArg(string[] args, string name)
    {
        for (int i = 0; i < args.Length - 1; i++)
        {
            if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase))
            {
                return args[i + 1];
            }
        }

        return string.Empty;
    }
}
