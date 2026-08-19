using Azure.AI.Projects;
using Azure.Identity;
using support_case_agent.Agent;
using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Foundry.Hosting;
using Microsoft.Extensions.AI;
using Azure.AI.AgentServer.Responses;
using Microsoft.Extensions.DependencyInjection.Extensions;

const string TelemetrySource = "Azure.AI.AgentServer.Responses";

var projectEndpoint = new Uri(Environment.GetEnvironmentVariable("FOUNDRY_PROJECT_ENDPOINT")
    ?? throw new InvalidOperationException("FOUNDRY_PROJECT_ENDPOINT environment variable is not set."));

var deployment = Environment.GetEnvironmentVariable("AZURE_AI_MODEL_DEPLOYMENT_NAME")
    ?? throw new InvalidOperationException("AZURE_AI_MODEL_DEPLOYMENT_NAME environment variable is not set.");

var builder = AgentHost.CreateBuilder(args);
Azure.Core.TokenCredential credential = builder.WebApplicationBuilder.Environment.IsDevelopment()
    ? new AzureCliCredential()
    : new DefaultAzureCredential();

var projectClient = new AIProjectClient(projectEndpoint, credential);
var prompt = LoadEmbeddedResource("Prompt.md");

var enableSensitiveTelemetry = string.Equals(
    Environment.GetEnvironmentVariable("OTEL_ENABLE_SENSITIVE_DATA"), "true", StringComparison.OrdinalIgnoreCase);

// Default template agent behavior for conversational responses.
var agent = projectClient.AsAIAgent(
    new ChatClientAgentOptions
    {
        Name = "support_case_agent",
        Description = "An agent that drives a support case conversation, step by step, with an end-user.",
        ChatOptions = new ChatOptions
        {
            Instructions = prompt,
            ModelId = deployment
        }
    })
    .AsBuilder()
    .UseOpenTelemetry(sourceName: TelemetrySource, configure: cfg => cfg.EnableSensitiveData = enableSensitiveTelemetry)
    .Build();

if (builder.WebApplicationBuilder.Environment.IsDevelopment())
{
    builder.Services.AddSingleton<HostedSessionIsolationKeyProvider, DevelopmentHostedSessionIsolationKeyProvider>();
}

builder.Services.TryAddSingleton<ResponseHandler, AgentFrameworkResponseHandler>();

builder.Services.AddFoundryResponses(agent);
builder.RegisterProtocol("responses", endpoints => endpoints.MapFoundryResponses());

var host = builder.Build();
host.Run();

static string LoadEmbeddedResource(string resourceName)
{
    using var stream = typeof(Program).Assembly.GetManifestResourceStream(resourceName)
        ?? throw new InvalidOperationException($"Embedded resource '{resourceName}' was not found :( ...");
    using var reader = new StreamReader(stream);
    return reader.ReadToEnd();
}
