using Azure.AI.Projects;
using Azure.Identity;
using support_case_agent.Agent;
using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Foundry.Hosting;
using Microsoft.Extensions.AI;

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

builder.Services.AddFoundryResponses(agent);
builder.RegisterProtocol("responses", endpoints => endpoints.MapFoundryResponses());

var host = builder.Build();
host.Run();

static string LoadEmbeddedResource(string resourceName)
{
    using var stream = typeof(Program).Assembly.GetManifestResourceStream(resourceName)
        ?? throw new InvalidOperationException($"Embedded resource '{resourceName}' was not found :( ");
    using var reader = new StreamReader(stream);
    return reader.ReadToEnd();
}
