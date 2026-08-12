using Azure.AI.Projects;
using Azure.Identity;
using workflow_support_agent.Agent;
using Microsoft.Agents.AI;
using Microsoft.Agents.AI.Workflows;
using Microsoft.Agents.AI.Workflows.Declarative;
using Microsoft.Agents.AI.Foundry.Hosting;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Configuration;
using Azure.AI.AgentServer.Responses;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

// ActivitySource that the Foundry AgentHost telemetry pipeline (AddAgentHostTelemetry) listens to
// and exports to Application Insights. Instrumentation must emit onto this exact source to be
// exported; it matches Microsoft.Agents.AI.Foundry.Hosting's internal ResponsesSourceName.
const string TelemetrySource = "Azure.AI.AgentServer.Responses";

var projectEndpoint = new Uri(Environment.GetEnvironmentVariable("FOUNDRY_PROJECT_ENDPOINT")
    ?? throw new InvalidOperationException("FOUNDRY_PROJECT_ENDPOINT environment variable is not set."));

var deployment = Environment.GetEnvironmentVariable("AZURE_AI_MODEL_DEPLOYMENT_NAME")
    ?? throw new InvalidOperationException("AZURE_AI_MODEL_DEPLOYMENT_NAME environment variable is not set.");

var credential = new DefaultAzureCredential();
var projectClient = new AIProjectClient(projectEndpoint, credential);

// Instrument the reasoner's model calls with OpenTelemetry so they reach Application Insights.
// The AgentHost telemetry pipeline (AddAgentHostTelemetry, wired by AgentHost.Build() below)
// exports only the fixed TelemetrySource, and AgentFrameworkResponseHandler auto-instruments the
// HOSTED agent it resolves - but the reasoner is invoked in-process via InProcessReasonerAgentProvider
// and is never seen by that handler, so without this its gen_ai spans (prompt, response, tokens,
// tool calls) never leave the process. Emitting onto TelemetrySource routes them through the same
// exporter. EnableSensitiveData (prompts + responses) is opt-in via OTEL_ENABLE_SENSITIVE_DATA so a
// locked-down deployment does not log conversation content by default.
var enableSensitiveTelemetry = string.Equals(
    Environment.GetEnvironmentVariable("OTEL_ENABLE_SENSITIVE_DATA"), "true", StringComparison.OrdinalIgnoreCase);

// --- The reasoning helper the declarative workflow delegates to ------------------------------
// Built in-process from the embedded runbook (the same projectClient.AsAIAgent(...) pattern
// support-case-agent uses for its single prompt agent). It is NOT persisted as a separate Foundry
// agent - the custom provider below routes the workflow's InvokeAzureAgent steps straight to it, so
// this stays one self-contained deployable.
var reasonerInstructions = LoadEmbeddedResource("Instructions.md");
var reasoner = projectClient.AsAIAgent(
    new ChatClientAgentOptions
    {
        Name = "workflow_support_reasoner",
        Description = "Reasoning helper invoked by the workflow-support-agent declarative workflow.",
        ChatOptions = new ChatOptions
        {
            Instructions = reasonerInstructions,
            ModelId = deployment
        }
    },
    clientFactory: chatClient => chatClient
        .AsBuilder()
        .UseOpenTelemetry(sourceName: TelemetrySource, configure: cfg => cfg.EnableSensitiveData = enableSensitiveTelemetry)
        .Build());

// --- Build the declarative workflow and expose it as an AIAgent ------------------------------
IConfiguration configuration = new ConfigurationBuilder()
    .AddEnvironmentVariables()
    .Build();

// Custom provider resolves the workflow's InvokeAzureAgent steps against the in-process reasoner.
// The reasoner's per-conversation session + message store are persisted on disk alongside the
// host's own session store, so the reasoning helper keeps its memory across a process restart
// (VM suspend/resume, container recycle) - consistent with the outer workflow session, which the
// same store already persists. Created here (rather than later) so the provider can co-locate.
var agentSessionStore = FileSystemAgentSessionStore.CreateDefault();
var reasonerStateDirectory = Path.Combine(agentSessionStore.RootDirectory, "reasoner-sessions");
var agentProvider = new InProcessReasonerAgentProvider(reasoner, reasonerStateDirectory);

DeclarativeWorkflowOptions workflowOptions = new(agentProvider)
{
    Configuration = configuration
};

var workflowPath = Path.Combine(AppContext.BaseDirectory, "workflow.yaml");
Workflow workflow = DeclarativeWorkflowBuilder.Build<string>(workflowPath, workflowOptions);

// Wrap the workflow so it hosts exactly like the prompt-based support-case-agent: as a single
// AIAgent served over the Responses protocol.
AIAgent agent = workflow.AsAIAgent(
    name: "workflow_support_agent",
    description: "Guides a user through GraemeCRM access triage using a declarative workflow.");

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
// (agentSessionStore was created earlier so the reasoner provider could co-locate its state.)

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
