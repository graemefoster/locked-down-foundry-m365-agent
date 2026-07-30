import { randomUUID } from 'node:crypto';
import express, { Request } from 'express';
import { AGENT_CARD_PATH, AgentCard, Message } from '@a2a-js/sdk';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import {
    AgentExecutor,
    DefaultRequestHandler,
    ExecutionEventBus,
    InMemoryTaskStore,
    RequestContext
} from '@a2a-js/sdk/server';
import { agentCardHandler, jsonRpcHandler, restHandler, UserBuilder } from '@a2a-js/sdk/server/express';
import { registerBurnleyMcpTools } from './BurnleyMcpTools';
import { registerWorldcupMcpTools } from './WorldcupMcpTools';
import { registerCrmMcpTools } from './CrmMcpTools';

const app = express();
const port = 8080;
const websiteHostname = process.env.WEBSITE_HOSTNAME?.trim();
const fallback = 'https://5bcd-2404-f801-e818-14-2583-9c48-41c7-ff1f.ngrok-free.app'
const fallbackPublicBaseUrl = websiteHostname ? `https://${websiteHostname}` : fallback;

function sanitizeBaseUrl(value: string): string {
    return value.replace(/\/+$/, '');
}


class HelloExecutor implements AgentExecutor {
    async execute(requestContext: RequestContext, eventBus: ExecutionEventBus): Promise<void> {
        const responseMessage: Message = {
            kind: 'message',
            messageId: randomUUID(),
            role: 'agent',
            parts: [{ kind: 'text', text: 'Hello there!!' }],
            contextId: requestContext.contextId,
            taskId: requestContext.taskId
        };

        eventBus.publish(responseMessage);
        eventBus.finished();
    }

    async cancelTask(): Promise<void> {}
}

function buildAgentCard(baseUrl: string): AgentCard {
    return {
        name: 'Simple A2A Agent',
        description: 'Minimal A2A agent powered by the official JS SDK.',
        protocolVersion: '0.3.0',
        version: '0.1.0',
        url: `${baseUrl}/a2a/rpc`,
        preferredTransport: 'JSONRPC',
        capabilities: {
            streaming: false,
            pushNotifications: false
        },
        defaultInputModes: ['text'],
        defaultOutputModes: ['text'],
        skills: [
            {
                id: 'hello',
                name: 'Hello',
                description: 'Always replies with a hello message.',
                tags: ['hello', 'chat']
            }
        ],
        additionalInterfaces: [
            { url: `${baseUrl}/a2a/rpc`, transport: 'JSONRPC' },
            { url: `${baseUrl}/a2a/rest`, transport: 'HTTP+JSON' }
        ]
    };
}

const agentCard = buildAgentCard(fallbackPublicBaseUrl);

const requestHandler = new DefaultRequestHandler(agentCard, new InMemoryTaskStore(), new HelloExecutor());

function createMcpServer(): McpServer {
    const server = new McpServer({
        name: 'simple-mcp-server',
        version: '1.0.0'
    });
    registerBurnleyMcpTools(server);

    return server;
}

app.use(express.json({ limit: '1mb' }));
app.get(`/a2a/${AGENT_CARD_PATH}`, (req, res) => {
    res.json(buildAgentCard(fallbackPublicBaseUrl));
});
app.get(`/${AGENT_CARD_PATH}`, (req, res) => {
    res.json(buildAgentCard(fallbackPublicBaseUrl));
});
app.use('/a2a/rpc', jsonRpcHandler({ requestHandler, userBuilder: UserBuilder.noAuthentication }));
app.use('/a2a/rest', restHandler({ requestHandler, userBuilder: UserBuilder.noAuthentication }));

app.post('/mcp', async (req, res) => {
    const server = createMcpServer();
    const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: undefined
    });

    try {
        await server.connect(transport);
        await transport.handleRequest(req, res, req.body);
    } catch (error) {
        if (!res.headersSent) {
            res.status(500).json({
                jsonrpc: '2.0',
                error: {
                    code: -32603,
                    message: 'Internal MCP server error'
                },
                id: null
            });
        }
    } finally {
        await transport.close();
        await server.close();
    }
});

app.get('/mcp', (_req, res) => {
    res.status(405).json({
        jsonrpc: '2.0',
        error: {
            code: -32000,
            message: 'Method not allowed.'
        },
        id: null
    });
});

function createWorldcupMcpServer(): McpServer {
    const server = new McpServer({
        name: 'fifa-worldcup-enterprise-mcp-server',
        version: '1.0.0'
    });
    registerWorldcupMcpTools(server);
    return server;
}

app.post('/mcp-worldcup', async (req, res) => {
    const server = createWorldcupMcpServer();
    const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: undefined
    });

    try {
        await server.connect(transport);
        await transport.handleRequest(req, res, req.body);
    } catch (error) {
        if (!res.headersSent) {
            res.status(500).json({
                jsonrpc: '2.0',
                error: {
                    code: -32603,
                    message: 'Internal MCP server error'
                },
                id: null
            });
        }
    } finally {
        await transport.close();
        await server.close();
    }
});

app.get('/mcp-worldcup', (_req, res) => {
    res.status(405).json({
        jsonrpc: '2.0',
        error: {
            code: -32000,
            message: 'Method not allowed.'
        },
        id: null
    });
});

function createCrmMcpServer(): McpServer {
    const server = new McpServer({
        name: 'northwind-bank-crm-mcp-server',
        version: '1.0.0'
    });
    registerCrmMcpTools(server);
    return server;
}

app.post('/mcp-crm', async (req, res) => {
    const server = createCrmMcpServer();
    const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: undefined
    });

    try {
        await server.connect(transport);
        await transport.handleRequest(req, res, req.body);
    } catch (error) {
        if (!res.headersSent) {
            res.status(500).json({
                jsonrpc: '2.0',
                error: {
                    code: -32603,
                    message: 'Internal MCP server error'
                },
                id: null
            });
        }
    } finally {
        await transport.close();
        await server.close();
    }
});

app.get('/mcp-crm', (_req, res) => {
    res.status(405).json({
        jsonrpc: '2.0',
        error: {
            code: -32000,
            message: 'Method not allowed.'
        },
        id: null
    });
});

app.get('/weather', (_req, res) => {
    res.type('text/plain').send("It's HOT HOT HOT!");
});

app.get('/health', (_req, res) => {
    res.json({ ok: true, service: 'a2a-sdk-agent', port });
});

const server = app.listen(port, () => {
    console.log(`A2A SDK agent listening at http://localhost:${port}/a2a`);
    console.log(`Agent card: ${fallbackPublicBaseUrl}/a2a/${AGENT_CARD_PATH}`);
    console.log(`JSON-RPC endpoint: ${fallbackPublicBaseUrl}/a2a/rpc`);
    console.log(`REST endpoint: ${fallbackPublicBaseUrl}/a2a/rest`);
});

server.on('error', (error: NodeJS.ErrnoException) => {
    if (error.code === 'EADDRINUSE') {
        console.error(`Port ${port} is already in use. Stop the existing server first (for example: pkill -f "ts-node src/index.ts").`);
        process.exit(1);
    }
    console.error('Server failed to start:', error);
    process.exit(1);
});
