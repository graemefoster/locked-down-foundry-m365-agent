namespace CopilotAgent;

public sealed class CopilotHostedAgentOptions
{
    public const string SectionName = "HostedAgent";

    public string? FoundryProjectEndpoint { get; set; }

    public string? ModelDeploymentName { get; set; }

    public string? InstructionsFile { get; set; }

    public string? WorkingDirectory { get; set; }

    public string[] SkillDirectories { get; set; } = [];
}
