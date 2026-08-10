using Azure.AI.AgentServer.Responses;
using Azure.AI.AgentServer.Responses.Models;
using Microsoft.Agents.AI.Foundry.Hosting;

namespace support_case_agent.Agent;

public class DevelopmentHostedSessionIsolationKeyProvider : HostedSessionIsolationKeyProvider
{
    public override ValueTask<HostedSessionContext?> GetKeysAsync(ResponseContext context, CreateResponse request,
        CancellationToken cancellationToken)
    {
        return new ValueTask<HostedSessionContext?>(
            new HostedSessionContext(
                "development-user",
                "development-chat"));
    }
}
