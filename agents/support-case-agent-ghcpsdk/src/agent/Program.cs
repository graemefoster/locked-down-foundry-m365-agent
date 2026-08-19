using Azure.AI.AgentServer.Core;
using Azure.AI.AgentServer.Invocations;
using Azure.Identity;
using CopilotAgent;

// `escalate` subcommand: run the fake escalation tool and exit instead of starting the web host.
// Invoked by the EscalationSkill (skills/EscalationSkill) via `dotnet <agent>.dll escalate ...`.
if (args.Length > 0 && string.Equals(args[0], "escalate", StringComparison.OrdinalIgnoreCase))
{
    return EscalationTool.Run(args[1..]);
}

var builder = AgentHost.CreateBuilder(args);

builder.Services.AddCors(options =>
    options.AddDefaultPolicy(policy =>
        policy.WithOrigins(
                builder.Configuration["Cors:AllowedOrigin"] ?? "http://localhost:5173")
              .AllowAnyHeader()
              .AllowAnyMethod()));

builder.Services.AddSingleton<DefaultAzureCredential>();
builder.Services.Configure<CopilotHostedAgentOptions>(
    builder.Configuration.GetSection(CopilotHostedAgentOptions.SectionName));
builder.Services.AddSingleton<CopilotSessionManager>();

builder.Services.AddInvocationsServer();
builder.Services.AddScoped<InvocationHandler, GitHubCopilotInvocationHandler>();

builder.RegisterProtocol("invocations", endpoints => endpoints.MapInvocationsServer());

var app = builder.Build();
app.App.UseCors();
await app.RunAsync();
return 0;
