using Azure.AI.Projects;
using Azure.Identity;
using support_case_agent.Agent;
using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Foundry.Hosting;
using Microsoft.Extensions.AI;
using Azure.AI.AgentServer.Responses;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

var projectEndpoint = new Uri(Environment.GetEnvironmentVariable("FOUNDRY_PROJECT_ENDPOINT")
    ?? throw new InvalidOperationException("FOUNDRY_PROJECT_ENDPOINT environment variable is not set."));

var deployment = Environment.GetEnvironmentVariable("AZURE_AI_MODEL_DEPLOYMENT_NAME")
    ?? throw new InvalidOperationException("AZURE_AI_MODEL_DEPLOYMENT_NAME environment variable is not set.");

var credential = new DefaultAzureCredential();
var projectClient = new AIProjectClient(projectEndpoint, credential);
var prompt = LoadEmbeddedResource("Prompt.md");

// Default template agent behavior for conversational responses.
var agent = projectClient.AsAIAgent(new ChatClientAgentOptions
{
    Name = "support_case_agent",
    Description = "An agent that drives a support case conversation, step by step, with an end-user.",
    ChatOptions = new ChatOptions
    {
        Instructions = prompt,
        ModelId = deployment
    }
});

var builder = AgentHost.CreateBuilder(args);

if (builder.WebApplicationBuilder.Environment.IsDevelopment())
{
    builder.Services.AddSingleton<HostedSessionIsolationKeyProvider, DevelopmentHostedSessionIsolationKeyProvider>();
}

// NOTE: We deliberately do NOT call AddFoundryResponses(agent) here.
// In SDK 1.17 that helper calls ConfigureFoundryListenPort, which adds a second
// Kestrel ListenAnyIP(8088) binding whenever FOUNDRY_HOSTING_ENVIRONMENT is set
// (i.e. running as a Foundry hosted agent). AgentHost.CreateBuilder(...).Build()
// ALSO binds 8088 unconditionally, so the two collide with
// "Failed to bind to address http://0.0.0.0:8088: address already in use",
// the /readiness endpoint never returns 200, and the session is reported as
// session_not_ready. We therefore replicate AddFoundryResponses(agent) minus the
// port binding. See https://github.com/microsoft/agent-framework (Foundry.Hosting)
// + https://github.com/Azure/azure-sdk-for-net (Azure.AI.AgentServer.Core).
var agentSessionStore = FileSystemAgentSessionStore.CreateDefault();

builder.Services.AddResponsesServer();
builder.Services.AddHealthChecks();

if (!string.IsNullOrWhiteSpace(agent.Name))
{
    builder.Services.TryAddKeyedSingleton<AIAgent>(agent.Name, agent);
    builder.Services.TryAddKeyedSingleton<AgentSessionStore>(agent.Name, agentSessionStore);
}

builder.Services.TryAddSingleton<AIAgent>(agent);
builder.Services.TryAddSingleton<AgentSessionStore>(agentSessionStore);
builder.Services.TryAddSingleton<ResponseHandler, AgentFrameworkResponseHandler>();

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
