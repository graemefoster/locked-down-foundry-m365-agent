import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';

// ============================================================================
// NORTHWIND BANK — CUSTOMER CRM MCP SERVER
// ----------------------------------------------------------------------------
// Powers a customer-facing agent that helps retail-banking customers navigate
// their accounts, cards, payments, and support relationship.
//
// NOTE FOR THE FOUNDRY OPTIMISATION DEMO:
//   Several tools below are DELIBERATELY badly described to give the prompt/
//   tool optimiser something to fix. Each one is flagged with a
//   `// [NASTY #n]` comment explaining what's wrong with it. See the summary
//   at the bottom of this file for the full list.
// ============================================================================

// --------------------------------------------------------------------------
// Data model
// --------------------------------------------------------------------------

type Customer = {
    customerId: string;
    title: string;
    firstName: string;
    lastName: string;
    dateOfBirth: string;
    email: string;
    phone: string;
    addressLine1: string;
    city: string;
    postcode: string;
    segment: 'standard' | 'premier' | 'private' | 'student';
    kycStatus: 'verified' | 'pending-review' | 'expired';
    relationshipManager?: string;
    marketingOptIn: boolean;
    joinedDate: string;
};

type Account = {
    accountId: string;
    customerId: string;
    type: 'current' | 'savings' | 'isa' | 'credit-card' | 'loan' | 'mortgage';
    nickname: string;
    sortCode: string;
    accountNumber: string;
    currency: 'GBP';
    balance: number;
    availableBalance: number;
    interestRate: number;
    overdraftLimit: number;
    status: 'active' | 'frozen' | 'closed' | 'dormant';
    openedDate: string;
};

type Card = {
    cardId: string;
    customerId: string;
    accountId: string;
    type: 'debit' | 'credit';
    network: 'visa' | 'mastercard';
    last4: string;
    expiry: string;
    status: 'active' | 'frozen' | 'blocked' | 'expired';
    contactlessEnabled: boolean;
    onlinePaymentsEnabled: boolean;
    dailyAtmLimit: number;
    dailySpendLimit: number;
};

type Transaction = {
    transactionId: string;
    accountId: string;
    date: string;
    description: string;
    merchant: string;
    category: 'groceries' | 'dining' | 'transport' | 'utilities' | 'salary' | 'transfer' | 'entertainment' | 'shopping' | 'cash' | 'fees';
    amount: number; // negative = debit, positive = credit
    balanceAfter: number;
    status: 'posted' | 'pending';
    channel: 'card' | 'transfer' | 'direct-debit' | 'standing-order' | 'atm' | 'faster-payment';
};

type Payee = {
    payeeId: string;
    customerId: string;
    name: string;
    sortCode: string;
    accountNumber: string;
    reference?: string;
    lastUsed?: string;
};

type StandingInstruction = {
    id: string;
    customerId: string;
    accountId: string;
    kind: 'standing-order' | 'direct-debit';
    payeeName: string;
    amount: number;
    frequency: 'weekly' | 'monthly' | 'quarterly' | 'annually';
    nextPaymentDate: string;
    status: 'active' | 'cancelled' | 'suspended';
};

type LoanOrMortgage = {
    accountId: string;
    customerId: string;
    product: string;
    principal: number;
    outstanding: number;
    interestRate: number;
    monthlyPayment: number;
    termMonths: number;
    remainingMonths: number;
    nextPaymentDate: string;
};

type SupportCase = {
    caseId: string;
    customerId: string;
    subject: string;
    channel: 'chat' | 'phone' | 'branch' | 'email';
    priority: 'low' | 'medium' | 'high' | 'urgent';
    status: 'open' | 'in-progress' | 'awaiting-customer' | 'resolved' | 'closed';
    openedDate: string;
    lastUpdated: string;
    notes: string[];
};

type Appointment = {
    appointmentId: string;
    customerId: string;
    type: 'mortgage-advice' | 'financial-review' | 'fraud-support' | 'account-opening' | 'general';
    advisor: string;
    branch: string;
    dateTime: string;
    status: 'booked' | 'completed' | 'cancelled';
};

type Dispute = {
    disputeId: string;
    customerId: string;
    transactionId: string;
    reason: 'unrecognised' | 'duplicate' | 'goods-not-received' | 'incorrect-amount' | 'subscription-cancelled';
    amount: number;
    status: 'raised' | 'investigating' | 'refunded' | 'rejected';
    raisedDate: string;
};

// --------------------------------------------------------------------------
// Fabricated seed data
// --------------------------------------------------------------------------

const customers: Customer[] = [
    {
        customerId: 'CUST-100001',
        title: 'Ms',
        firstName: 'Amelia',
        lastName: 'Hartley',
        dateOfBirth: '1989-03-14',
        email: 'amelia.hartley@example.com',
        phone: '+44 7700 900123',
        addressLine1: '42 Pendle Street',
        city: 'Manchester',
        postcode: 'M1 4AB',
        segment: 'premier',
        kycStatus: 'verified',
        relationshipManager: 'David Okafor',
        marketingOptIn: true,
        joinedDate: '2012-06-01'
    },
    {
        customerId: 'CUST-100002',
        title: 'Mr',
        firstName: 'Raj',
        lastName: 'Patel',
        dateOfBirth: '1995-11-02',
        email: 'raj.patel@example.com',
        phone: '+44 7700 900456',
        addressLine1: '9 Waterloo Road',
        city: 'Leeds',
        postcode: 'LS1 5DR',
        segment: 'standard',
        kycStatus: 'pending-review',
        marketingOptIn: false,
        joinedDate: '2020-09-15'
    },
    {
        customerId: 'CUST-100003',
        title: 'Dr',
        firstName: 'Sofia',
        lastName: 'Nowak',
        dateOfBirth: '1978-07-23',
        email: 'sofia.nowak@example.com',
        phone: '+44 7700 900789',
        addressLine1: '17 Kingsway',
        city: 'London',
        postcode: 'WC2B 6UN',
        segment: 'private',
        kycStatus: 'verified',
        relationshipManager: 'Priya Sharma',
        marketingOptIn: true,
        joinedDate: '2008-02-20'
    }
];

const accounts: Account[] = [
    {
        accountId: 'ACC-2001',
        customerId: 'CUST-100001',
        type: 'current',
        nickname: 'Everyday Current',
        sortCode: '20-11-45',
        accountNumber: '11223344',
        currency: 'GBP',
        balance: 3241.87,
        availableBalance: 3741.87,
        interestRate: 0,
        overdraftLimit: 500,
        status: 'active',
        openedDate: '2012-06-01'
    },
    {
        accountId: 'ACC-2002',
        customerId: 'CUST-100001',
        type: 'savings',
        nickname: 'Rainy Day Saver',
        sortCode: '20-11-45',
        accountNumber: '55667788',
        currency: 'GBP',
        balance: 18540.5,
        availableBalance: 18540.5,
        interestRate: 4.1,
        overdraftLimit: 0,
        status: 'active',
        openedDate: '2015-01-10'
    },
    {
        accountId: 'ACC-2003',
        customerId: 'CUST-100001',
        type: 'credit-card',
        nickname: 'Premier Rewards Card',
        sortCode: '20-11-45',
        accountNumber: '90011223',
        currency: 'GBP',
        balance: -742.19,
        availableBalance: 4257.81,
        interestRate: 21.9,
        overdraftLimit: 0,
        status: 'active',
        openedDate: '2018-05-04'
    },
    {
        accountId: 'ACC-2004',
        customerId: 'CUST-100002',
        type: 'current',
        nickname: 'Main Account',
        sortCode: '20-11-45',
        accountNumber: '33445566',
        currency: 'GBP',
        balance: 512.03,
        availableBalance: 512.03,
        interestRate: 0,
        overdraftLimit: 0,
        status: 'active',
        openedDate: '2020-09-15'
    },
    {
        accountId: 'ACC-2005',
        customerId: 'CUST-100003',
        type: 'mortgage',
        nickname: 'Kingsway Home',
        sortCode: '20-11-45',
        accountNumber: '77889900',
        currency: 'GBP',
        balance: -284500,
        availableBalance: 0,
        interestRate: 3.79,
        overdraftLimit: 0,
        status: 'active',
        openedDate: '2019-04-01'
    },
    {
        accountId: 'ACC-2006',
        customerId: 'CUST-100003',
        type: 'isa',
        nickname: 'Stocks & Shares ISA',
        sortCode: '20-11-45',
        accountNumber: '66554433',
        currency: 'GBP',
        balance: 41230.72,
        availableBalance: 41230.72,
        interestRate: 0,
        overdraftLimit: 0,
        status: 'active',
        openedDate: '2016-04-06'
    }
];

const cards: Card[] = [
    {
        cardId: 'CARD-3001',
        customerId: 'CUST-100001',
        accountId: 'ACC-2001',
        type: 'debit',
        network: 'visa',
        last4: '4821',
        expiry: '08/28',
        status: 'active',
        contactlessEnabled: true,
        onlinePaymentsEnabled: true,
        dailyAtmLimit: 500,
        dailySpendLimit: 5000
    },
    {
        cardId: 'CARD-3002',
        customerId: 'CUST-100001',
        accountId: 'ACC-2003',
        type: 'credit',
        network: 'mastercard',
        last4: '7733',
        expiry: '02/27',
        status: 'active',
        contactlessEnabled: true,
        onlinePaymentsEnabled: true,
        dailyAtmLimit: 300,
        dailySpendLimit: 5000
    },
    {
        cardId: 'CARD-3003',
        customerId: 'CUST-100002',
        accountId: 'ACC-2004',
        type: 'debit',
        network: 'visa',
        last4: '1290',
        expiry: '11/26',
        status: 'active',
        contactlessEnabled: true,
        onlinePaymentsEnabled: false,
        dailyAtmLimit: 250,
        dailySpendLimit: 1000
    }
];

const transactions: Transaction[] = [
    { transactionId: 'TXN-9001', accountId: 'ACC-2001', date: '2026-06-30', description: 'Salary — Contoso Ltd', merchant: 'Contoso Ltd', category: 'salary', amount: 2850.0, balanceAfter: 3241.87, status: 'posted', channel: 'faster-payment' },
    { transactionId: 'TXN-9002', accountId: 'ACC-2001', date: '2026-06-29', description: 'Tesco Superstore', merchant: 'Tesco', category: 'groceries', amount: -82.44, balanceAfter: 391.87, status: 'posted', channel: 'card' },
    { transactionId: 'TXN-9003', accountId: 'ACC-2001', date: '2026-06-28', description: 'TfGM Travel', merchant: 'Transport for Greater Manchester', category: 'transport', amount: -14.6, balanceAfter: 474.31, status: 'posted', channel: 'card' },
    { transactionId: 'TXN-9004', accountId: 'ACC-2001', date: '2026-06-27', description: 'Netflix', merchant: 'Netflix', category: 'entertainment', amount: -10.99, balanceAfter: 488.91, status: 'posted', channel: 'direct-debit' },
    { transactionId: 'TXN-9005', accountId: 'ACC-2001', date: '2026-06-26', description: 'Amazon Marketplace', merchant: 'Amazon', category: 'shopping', amount: -239.99, balanceAfter: 499.9, status: 'posted', channel: 'card' },
    { transactionId: 'TXN-9006', accountId: 'ACC-2003', date: '2026-06-25', description: 'British Airways', merchant: 'British Airways', category: 'transport', amount: -420.0, balanceAfter: -742.19, status: 'posted', channel: 'card' },
    { transactionId: 'TXN-9007', accountId: 'ACC-2003', date: '2026-06-24', description: 'Unrecognised — QUICKPAY LDN', merchant: 'QUICKPAY LDN', category: 'shopping', amount: -89.0, balanceAfter: -322.19, status: 'posted', channel: 'card' },
    { transactionId: 'TXN-9008', accountId: 'ACC-2004', date: '2026-06-30', description: 'Odeon Cinema', merchant: 'Odeon', category: 'entertainment', amount: -27.5, balanceAfter: 512.03, status: 'posted', channel: 'card' },
    { transactionId: 'TXN-9009', accountId: 'ACC-2004', date: '2026-06-28', description: 'British Gas', merchant: 'British Gas', category: 'utilities', amount: -96.2, balanceAfter: 539.53, status: 'posted', channel: 'direct-debit' },
    { transactionId: 'TXN-9010', accountId: 'ACC-2002', date: '2026-06-01', description: 'Interest payment', merchant: 'Northwind Bank', category: 'salary', amount: 63.15, balanceAfter: 18540.5, status: 'posted', channel: 'transfer' }
];

const payees: Payee[] = [
    { payeeId: 'PAYEE-4001', customerId: 'CUST-100001', name: 'Jack Hartley', sortCode: '30-22-11', accountNumber: '12345678', reference: 'Rent', lastUsed: '2026-06-01' },
    { payeeId: 'PAYEE-4002', customerId: 'CUST-100001', name: 'EDF Energy', sortCode: '40-11-22', accountNumber: '87654321', reference: 'Acct 5567', lastUsed: '2026-05-28' },
    { payeeId: 'PAYEE-4003', customerId: 'CUST-100002', name: 'Leeds City Council', sortCode: '50-33-44', accountNumber: '11119999', reference: 'Council Tax' }
];

const standingInstructions: StandingInstruction[] = [
    { id: 'SI-5001', customerId: 'CUST-100001', accountId: 'ACC-2001', kind: 'standing-order', payeeName: 'Jack Hartley', amount: 950, frequency: 'monthly', nextPaymentDate: '2026-07-01', status: 'active' },
    { id: 'SI-5002', customerId: 'CUST-100001', accountId: 'ACC-2001', kind: 'direct-debit', payeeName: 'EDF Energy', amount: 88.4, frequency: 'monthly', nextPaymentDate: '2026-07-05', status: 'active' },
    { id: 'SI-5003', customerId: 'CUST-100002', accountId: 'ACC-2004', kind: 'direct-debit', payeeName: 'British Gas', amount: 96.2, frequency: 'monthly', nextPaymentDate: '2026-07-28', status: 'active' }
];

const loans: LoanOrMortgage[] = [
    { accountId: 'ACC-2005', customerId: 'CUST-100003', product: '5-Year Fixed Mortgage', principal: 320000, outstanding: 284500, interestRate: 3.79, monthlyPayment: 1642.3, termMonths: 300, remainingMonths: 246, nextPaymentDate: '2026-07-15' }
];

const supportCases: SupportCase[] = [
    {
        caseId: 'CASE-6001',
        customerId: 'CUST-100001',
        subject: 'Suspicious card transaction QUICKPAY LDN',
        channel: 'chat',
        priority: 'high',
        status: 'in-progress',
        openedDate: '2026-06-24',
        lastUpdated: '2026-06-25',
        notes: ['Customer flagged £89 charge as unrecognised.', 'Card monitoring enabled pending investigation.']
    }
];

const appointments: Appointment[] = [
    {
        appointmentId: 'APT-7001',
        customerId: 'CUST-100003',
        type: 'financial-review',
        advisor: 'Priya Sharma',
        branch: 'London Holborn',
        dateTime: '2026-07-10 11:00',
        status: 'booked'
    }
];

const disputes: Dispute[] = [];

const creditScores: Record<string, { score: number; band: string; updated: string }> = {
    'CUST-100001': { score: 812, band: 'Excellent', updated: '2026-06-15' },
    'CUST-100002': { score: 640, band: 'Fair', updated: '2026-06-15' },
    'CUST-100003': { score: 905, band: 'Excellent', updated: '2026-06-15' }
};

// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------

function text(body: string) {
    return { content: [{ type: 'text' as const, text: body }] };
}

function findCustomer(customerId: string): Customer | undefined {
    return customers.find((c) => c.customerId.toLowerCase() === customerId.toLowerCase());
}

function accountsFor(customerId: string): Account[] {
    return accounts.filter((a) => a.customerId.toLowerCase() === customerId.toLowerCase());
}

function gbp(amount: number): string {
    const sign = amount < 0 ? '-' : '';
    return `${sign}£${Math.abs(amount).toFixed(2)}`;
}

// --------------------------------------------------------------------------
// Tool registration
// --------------------------------------------------------------------------

export function registerCrmMcpTools(server: McpServer): void {
    // -----------------------------------------------------------------
    // Customer profile
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-get-customer-profile',
        {
            description:
                'Retrieve a customer\'s CRM profile by customer ID, including name, contact details, banking segment, KYC status and relationship manager. Use this when you need to confirm who the customer is or view their personal details.',
            inputSchema: z.object({
                customerId: z.string().describe('The customer identifier, e.g. "CUST-100001".')
            })
        },
        async ({ customerId }: { customerId: string }) => {
            const c = findCustomer(customerId);
            if (!c) {
                return text(`No customer found for ID ${customerId}.`);
            }
            return text(
                [
                    `${c.title} ${c.firstName} ${c.lastName} (${c.customerId})`,
                    `Segment: ${c.segment} | KYC: ${c.kycStatus}`,
                    `Email: ${c.email} | Phone: ${c.phone}`,
                    `Address: ${c.addressLine1}, ${c.city}, ${c.postcode}`,
                    `Relationship manager: ${c.relationshipManager ?? 'None assigned'}`,
                    `Customer since: ${c.joinedDate} | Marketing opt-in: ${c.marketingOptIn ? 'yes' : 'no'}`
                ].join('\n')
            );
        }
    );

    // -----------------------------------------------------------------
    // Customer search
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-search-customers',
        {
            description:
                'Search for customers by name, email or postcode. Returns matching customer IDs and summary details. Use this when you do not yet know the customer ID.',
            inputSchema: z.object({
                query: z.string().describe('Free-text search across name, email and postcode.')
            })
        },
        async ({ query }: { query: string }) => {
            const q = query.trim().toLowerCase();
            const matches = customers.filter((c) =>
                [c.firstName, c.lastName, c.email, c.postcode, `${c.firstName} ${c.lastName}`]
                    .join(' ')
                    .toLowerCase()
                    .includes(q)
            );
            if (matches.length === 0) {
                return text(`No customers matched "${query}".`);
            }
            return text(
                matches
                    .map((c) => `${c.customerId} | ${c.firstName} ${c.lastName} | ${c.email} | ${c.city} ${c.postcode} | ${c.segment}`)
                    .join('\n')
            );
        }
    );

    // -----------------------------------------------------------------
    // Accounts overview
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-list-accounts',
        {
            description:
                'List all accounts belonging to a customer with balances, account type, status and interest rate. Use this to give a customer an overview of their products.',
            inputSchema: z.object({
                customerId: z.string().describe('The customer identifier, e.g. "CUST-100001".')
            })
        },
        async ({ customerId }: { customerId: string }) => {
            const custAccounts = accountsFor(customerId);
            if (custAccounts.length === 0) {
                return text(`No accounts found for customer ${customerId}.`);
            }
            return text(
                custAccounts
                    .map(
                        (a) =>
                            `${a.accountId} | ${a.nickname} (${a.type}) | ${a.sortCode} ${a.accountNumber} | Balance: ${gbp(a.balance)} | Available: ${gbp(a.availableBalance)} | ${a.status}`
                    )
                    .join('\n')
            );
        }
    );

    // -----------------------------------------------------------------
    // Account balance detail
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-get-account-balance',
        {
            description:
                'Get detailed balance information for a single account, including available balance, overdraft limit and interest rate.',
            inputSchema: z.object({
                accountId: z.string().describe('The account identifier, e.g. "ACC-2001".')
            })
        },
        async ({ accountId }: { accountId: string }) => {
            const a = accounts.find((x) => x.accountId.toLowerCase() === accountId.toLowerCase());
            if (!a) {
                return text(`No account found for ID ${accountId}.`);
            }
            return text(
                [
                    `${a.nickname} (${a.accountId}) — ${a.type}`,
                    `Balance: ${gbp(a.balance)}`,
                    `Available: ${gbp(a.availableBalance)}`,
                    `Overdraft limit: ${gbp(a.overdraftLimit)}`,
                    `Interest rate: ${a.interestRate}%`,
                    `Status: ${a.status}`
                ].join('\n')
            );
        }
    );

    // -----------------------------------------------------------------
    // [NASTY #1] Transaction search with a vague name, no useful
    // description, and undocumented params. The agent won't know what
    // "data" means, that amounts filter on absolute value, or that the
    // category enum even exists.
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-data',
        {
            description: 'Gets data.',
            inputSchema: z.object({
                accountId: z.string(),
                q: z.string().optional(),
                cat: z.string().optional(),
                min: z.number().optional(),
                max: z.number().optional()
            })
        },
        async ({ accountId, q, cat, min, max }: { accountId: string; q?: string; cat?: string; min?: number; max?: number }) => {
            let rows = transactions.filter((t) => t.accountId.toLowerCase() === accountId.toLowerCase());
            if (q) {
                const needle = q.toLowerCase();
                rows = rows.filter((t) => t.description.toLowerCase().includes(needle) || t.merchant.toLowerCase().includes(needle));
            }
            if (cat) {
                rows = rows.filter((t) => t.category.toLowerCase() === cat.toLowerCase());
            }
            if (typeof min === 'number') {
                rows = rows.filter((t) => Math.abs(t.amount) >= min);
            }
            if (typeof max === 'number') {
                rows = rows.filter((t) => Math.abs(t.amount) <= max);
            }
            if (rows.length === 0) {
                return text('No results.');
            }
            return text(
                rows
                    .map((t) => `${t.date} | ${t.transactionId} | ${t.description} | ${t.category} | ${gbp(t.amount)} | ${t.status}`)
                    .join('\n')
            );
        }
    );

    // -----------------------------------------------------------------
    // Recent transactions (well described counterpart)
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-recent-transactions',
        {
            description:
                'List the most recent transactions on an account, newest first. Use this to help a customer review recent spending or find a specific payment.',
            inputSchema: z.object({
                accountId: z.string().describe('The account identifier, e.g. "ACC-2001".'),
                limit: z.number().int().positive().max(50).optional().describe('Maximum number of transactions to return (default 10).')
            })
        },
        async ({ accountId, limit }: { accountId: string; limit?: number }) => {
            const rows = transactions
                .filter((t) => t.accountId.toLowerCase() === accountId.toLowerCase())
                .sort((a, b) => b.date.localeCompare(a.date))
                .slice(0, limit ?? 10);
            if (rows.length === 0) {
                return text(`No transactions found for account ${accountId}.`);
            }
            return text(
                rows.map((t) => `${t.date} | ${t.description} | ${gbp(t.amount)} | ${t.category} | ${t.channel} | ${t.status}`).join('\n')
            );
        }
    );

    // -----------------------------------------------------------------
    // Cards — list
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-list-cards',
        {
            description:
                'List a customer\'s debit and credit cards with masked numbers, expiry, status and security settings (contactless, online payments, limits).',
            inputSchema: z.object({
                customerId: z.string().describe('The customer identifier, e.g. "CUST-100001".')
            })
        },
        async ({ customerId }: { customerId: string }) => {
            const custCards = cards.filter((c) => c.customerId.toLowerCase() === customerId.toLowerCase());
            if (custCards.length === 0) {
                return text(`No cards found for customer ${customerId}.`);
            }
            return text(
                custCards
                    .map(
                        (c) =>
                            `${c.cardId} | ${c.network.toUpperCase()} ${c.type} •••• ${c.last4} | Exp ${c.expiry} | ${c.status} | Contactless: ${c.contactlessEnabled ? 'on' : 'off'} | Online: ${c.onlinePaymentsEnabled ? 'on' : 'off'}`
                    )
                    .join('\n')
            );
        }
    );

    // -----------------------------------------------------------------
    // [NASTY #2] Overloaded "manage" tool that does freeze, unfreeze,
    // report-lost and toggle-contactless all at once. The description
    // doesn't explain the action values or that reporting lost is
    // irreversible. Great candidate to split / clarify during
    // optimisation.
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-card-manage',
        {
            description: 'Manage a card. Pass an action.',
            inputSchema: z.object({
                cardId: z.string(),
                action: z.string()
            })
        },
        async ({ cardId, action }: { cardId: string; action: string }) => {
            const card = cards.find((c) => c.cardId.toLowerCase() === cardId.toLowerCase());
            if (!card) {
                return text(`No card found for ID ${cardId}.`);
            }
            const a = action.trim().toLowerCase();
            switch (a) {
                case 'freeze':
                    card.status = 'frozen';
                    return text(`Card •••• ${card.last4} is now frozen.`);
                case 'unfreeze':
                    card.status = 'active';
                    return text(`Card •••• ${card.last4} is now active.`);
                case 'report-lost':
                case 'lost':
                    card.status = 'blocked';
                    return text(`Card •••• ${card.last4} has been permanently blocked and a replacement ordered.`);
                case 'contactless-on':
                    card.contactlessEnabled = true;
                    return text(`Contactless enabled on card •••• ${card.last4}.`);
                case 'contactless-off':
                    card.contactlessEnabled = false;
                    return text(`Contactless disabled on card •••• ${card.last4}.`);
                default:
                    return text(`Unknown action "${action}".`);
            }
        }
    );

    // -----------------------------------------------------------------
    // Payees
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-list-payees',
        {
            description: 'List a customer\'s saved payees (beneficiaries) for making payments and transfers.',
            inputSchema: z.object({
                customerId: z.string().describe('The customer identifier, e.g. "CUST-100001".')
            })
        },
        async ({ customerId }: { customerId: string }) => {
            const list = payees.filter((p) => p.customerId.toLowerCase() === customerId.toLowerCase());
            if (list.length === 0) {
                return text(`No saved payees for customer ${customerId}.`);
            }
            return text(
                list
                    .map((p) => `${p.payeeId} | ${p.name} | ${p.sortCode} ${p.accountNumber} | Ref: ${p.reference ?? '—'} | Last used: ${p.lastUsed ?? 'never'}`)
                    .join('\n')
            );
        }
    );

    // -----------------------------------------------------------------
    // [NASTY #3] Money-movement tool that is dangerously under-specified.
    // Name ("crm-process") gives no hint it MOVES MONEY, the description
    // is misleadingly casual, amount units aren't stated, and there is no
    // mention that it debits immediately with no confirmation step.
    // Perfect for demonstrating guardrail/description hardening.
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-process',
        {
            description: 'Helpful utility for handling a request between accounts.',
            inputSchema: z.object({
                from: z.string(),
                to: z.string(),
                amount: z.number(),
                ref: z.string().optional()
            })
        },
        async ({ from, to, amount, ref }: { from: string; to: string; amount: number; ref?: string }) => {
            const source = accounts.find((a) => a.accountId.toLowerCase() === from.toLowerCase());
            if (!source) {
                return text(`No source account found for ID ${from}.`);
            }
            if (amount <= 0) {
                return text('Amount must be positive.');
            }
            if (amount > source.availableBalance) {
                return text(`Insufficient funds. Available balance is ${gbp(source.availableBalance)}.`);
            }
            source.balance -= amount;
            source.availableBalance -= amount;
            const confirmation = `PAY-${Date.now().toString(36).toUpperCase()}`;
            return text(
                `Sent ${gbp(amount)} from ${source.accountId} to ${to}${ref ? ` (ref: ${ref})` : ''}. Confirmation: ${confirmation}. New balance: ${gbp(source.balance)}.`
            );
        }
    );

    // -----------------------------------------------------------------
    // Standing orders & direct debits
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-list-regular-payments',
        {
            description:
                'List a customer\'s standing orders and direct debits, including payee, amount, frequency, next payment date and status.',
            inputSchema: z.object({
                customerId: z.string().describe('The customer identifier, e.g. "CUST-100001".')
            })
        },
        async ({ customerId }: { customerId: string }) => {
            const list = standingInstructions.filter((s) => s.customerId.toLowerCase() === customerId.toLowerCase());
            if (list.length === 0) {
                return text(`No standing orders or direct debits for customer ${customerId}.`);
            }
            return text(
                list
                    .map((s) => `${s.id} | ${s.kind} | ${s.payeeName} | ${gbp(s.amount)} ${s.frequency} | Next: ${s.nextPaymentDate} | ${s.status}`)
                    .join('\n')
            );
        }
    );

    server.registerTool(
        'crm-cancel-regular-payment',
        {
            description:
                'Cancel a standing order or direct debit by its ID. This stops future payments but does not reverse payments already made.',
            inputSchema: z.object({
                instructionId: z.string().describe('The standing order / direct debit ID, e.g. "SI-5001".')
            })
        },
        async ({ instructionId }: { instructionId: string }) => {
            const s = standingInstructions.find((x) => x.id.toLowerCase() === instructionId.toLowerCase());
            if (!s) {
                return text(`No standing order or direct debit found for ID ${instructionId}.`);
            }
            s.status = 'cancelled';
            return text(`${s.kind} ${s.id} to ${s.payeeName} has been cancelled.`);
        }
    );

    // -----------------------------------------------------------------
    // Loans & mortgages
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-get-loan-details',
        {
            description:
                'Get details of a customer\'s loans and mortgages, including outstanding balance, interest rate, monthly payment and remaining term.',
            inputSchema: z.object({
                customerId: z.string().describe('The customer identifier, e.g. "CUST-100003".')
            })
        },
        async ({ customerId }: { customerId: string }) => {
            const list = loans.filter((l) => l.customerId.toLowerCase() === customerId.toLowerCase());
            if (list.length === 0) {
                return text(`No loans or mortgages found for customer ${customerId}.`);
            }
            return text(
                list
                    .map(
                        (l) =>
                            `${l.product} (${l.accountId}) | Outstanding: ${gbp(l.outstanding)} | Rate: ${l.interestRate}% | Monthly: ${gbp(l.monthlyPayment)} | ${l.remainingMonths}/${l.termMonths} months left | Next: ${l.nextPaymentDate}`
                    )
                    .join('\n')
            );
        }
    );

    // -----------------------------------------------------------------
    // [NASTY #4] Credit score tool whose description is actively
    // MISLEADING — it claims to return "account balance" when it really
    // returns a credit score. Wrong-tool-selection bait for the optimiser.
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-account-balance-check',
        {
            description: 'Returns the current account balance for a customer so you can tell them how much money they have.',
            inputSchema: z.object({
                customerId: z.string().describe('The customer identifier.')
            })
        },
        async ({ customerId }: { customerId: string }) => {
            const score = creditScores[customerId.toUpperCase()];
            if (!score) {
                return text(`No credit score on file for customer ${customerId}.`);
            }
            return text(`Credit score: ${score.score} (${score.band}). Last updated ${score.updated}.`);
        }
    );

    // -----------------------------------------------------------------
    // Support cases
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-list-support-cases',
        {
            description: 'List open and historical support cases for a customer, including subject, priority, status and notes.',
            inputSchema: z.object({
                customerId: z.string().describe('The customer identifier, e.g. "CUST-100001".')
            })
        },
        async ({ customerId }: { customerId: string }) => {
            const list = supportCases.filter((s) => s.customerId.toLowerCase() === customerId.toLowerCase());
            if (list.length === 0) {
                return text(`No support cases for customer ${customerId}.`);
            }
            return text(
                list
                    .map(
                        (s) =>
                            `${s.caseId} | ${s.subject} | ${s.priority} | ${s.status} | opened ${s.openedDate}\n   notes: ${s.notes.join(' | ')}`
                    )
                    .join('\n')
            );
        }
    );

    server.registerTool(
        'crm-raise-support-case',
        {
            description:
                'Open a new support case for a customer. Use this to log a complaint, query or issue that needs follow-up by the bank.',
            inputSchema: z.object({
                customerId: z.string().describe('The customer identifier, e.g. "CUST-100001".'),
                subject: z.string().describe('A short summary of the issue.'),
                priority: z.enum(['low', 'medium', 'high', 'urgent']).optional().describe('Case priority (default medium).')
            })
        },
        async ({ customerId, subject, priority }: { customerId: string; subject: string; priority?: 'low' | 'medium' | 'high' | 'urgent' }) => {
            if (!findCustomer(customerId)) {
                return text(`No customer found for ID ${customerId}.`);
            }
            const caseId = `CASE-${(6000 + supportCases.length + 1).toString()}`;
            supportCases.push({
                caseId,
                customerId,
                subject,
                channel: 'chat',
                priority: priority ?? 'medium',
                status: 'open',
                openedDate: new Date().toISOString().slice(0, 10),
                lastUpdated: new Date().toISOString().slice(0, 10),
                notes: ['Case opened via customer agent.']
            });
            return text(`Support case ${caseId} raised: "${subject}" (${priority ?? 'medium'} priority).`);
        }
    );

    // -----------------------------------------------------------------
    // Disputes
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-raise-transaction-dispute',
        {
            description:
                'Raise a dispute against a specific transaction (e.g. unrecognised, duplicate, goods not received). Creates a dispute case and starts the chargeback investigation.',
            inputSchema: z.object({
                customerId: z.string().describe('The customer identifier, e.g. "CUST-100001".'),
                transactionId: z.string().describe('The transaction identifier to dispute, e.g. "TXN-9007".'),
                reason: z
                    .enum(['unrecognised', 'duplicate', 'goods-not-received', 'incorrect-amount', 'subscription-cancelled'])
                    .describe('The reason for the dispute.')
            })
        },
        async ({ customerId, transactionId, reason }: { customerId: string; transactionId: string; reason: Dispute['reason'] }) => {
            const txn = transactions.find((t) => t.transactionId.toLowerCase() === transactionId.toLowerCase());
            if (!txn) {
                return text(`No transaction found for ID ${transactionId}.`);
            }
            const disputeId = `DIS-${(8000 + disputes.length + 1).toString()}`;
            disputes.push({
                disputeId,
                customerId,
                transactionId,
                reason,
                amount: Math.abs(txn.amount),
                status: 'raised',
                raisedDate: new Date().toISOString().slice(0, 10)
            });
            return text(`Dispute ${disputeId} raised for ${transactionId} (${gbp(Math.abs(txn.amount))}, reason: ${reason}). Status: raised.`);
        }
    );

    // -----------------------------------------------------------------
    // Appointments
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-list-appointments',
        {
            description: 'List a customer\'s upcoming and past appointments with advisors.',
            inputSchema: z.object({
                customerId: z.string().describe('The customer identifier, e.g. "CUST-100003".')
            })
        },
        async ({ customerId }: { customerId: string }) => {
            const list = appointments.filter((a) => a.customerId.toLowerCase() === customerId.toLowerCase());
            if (list.length === 0) {
                return text(`No appointments for customer ${customerId}.`);
            }
            return text(
                list.map((a) => `${a.appointmentId} | ${a.type} | ${a.advisor} | ${a.branch} | ${a.dateTime} | ${a.status}`).join('\n')
            );
        }
    );

    server.registerTool(
        'crm-book-appointment',
        {
            description:
                'Book an appointment for a customer with a branch advisor. Specify the appointment type and a preferred date/time.',
            inputSchema: z.object({
                customerId: z.string().describe('The customer identifier, e.g. "CUST-100001".'),
                type: z
                    .enum(['mortgage-advice', 'financial-review', 'fraud-support', 'account-opening', 'general'])
                    .describe('The type of appointment.'),
                dateTime: z.string().describe('Preferred date and time, e.g. "2026-07-20 14:30".'),
                branch: z.string().optional().describe('Preferred branch (default nearest branch).')
            })
        },
        async ({ customerId, type, dateTime, branch }: { customerId: string; type: Appointment['type']; dateTime: string; branch?: string }) => {
            if (!findCustomer(customerId)) {
                return text(`No customer found for ID ${customerId}.`);
            }
            const appointmentId = `APT-${(7000 + appointments.length + 1).toString()}`;
            appointments.push({
                appointmentId,
                customerId,
                type,
                advisor: 'Next available advisor',
                branch: branch ?? 'Nearest branch',
                dateTime,
                status: 'booked'
            });
            return text(`Appointment ${appointmentId} booked: ${type} on ${dateTime} at ${branch ?? 'nearest branch'}.`);
        }
    );

    // -----------------------------------------------------------------
    // [NASTY #5] Update-contact-details tool with a description that
    // OVER-CLAIMS scope. It says it can update "any customer detail
    // including segment, KYC status and credit limit", but it only
    // actually updates email/phone/address. This over-promising causes
    // the agent to pick it for things it can't do.
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-update-details',
        {
            description:
                'Update any customer detail — email, phone, address, name, date of birth, banking segment, KYC status, overdraft and credit limits, marketing preferences and more. A one-stop tool for editing everything about a customer.',
            inputSchema: z.object({
                customerId: z.string().describe('The customer identifier, e.g. "CUST-100001".'),
                email: z.string().optional(),
                phone: z.string().optional(),
                addressLine1: z.string().optional(),
                city: z.string().optional(),
                postcode: z.string().optional()
            })
        },
        async ({ customerId, email, phone, addressLine1, city, postcode }: { customerId: string; email?: string; phone?: string; addressLine1?: string; city?: string; postcode?: string }) => {
            const c = findCustomer(customerId);
            if (!c) {
                return text(`No customer found for ID ${customerId}.`);
            }
            const changes: string[] = [];
            if (email) { c.email = email; changes.push(`email → ${email}`); }
            if (phone) { c.phone = phone; changes.push(`phone → ${phone}`); }
            if (addressLine1) { c.addressLine1 = addressLine1; changes.push(`address → ${addressLine1}`); }
            if (city) { c.city = city; changes.push(`city → ${city}`); }
            if (postcode) { c.postcode = postcode; changes.push(`postcode → ${postcode}`); }
            if (changes.length === 0) {
                return text('No changes supplied.');
            }
            return text(`Updated ${c.firstName} ${c.lastName}: ${changes.join(', ')}.`);
        }
    );

    // -----------------------------------------------------------------
    // Credit score (correctly described)
    // -----------------------------------------------------------------
    server.registerTool(
        'crm-get-credit-score',
        {
            description: 'Retrieve a customer\'s current credit score and rating band.',
            inputSchema: z.object({
                customerId: z.string().describe('The customer identifier, e.g. "CUST-100001".')
            })
        },
        async ({ customerId }: { customerId: string }) => {
            const score = creditScores[customerId.toUpperCase()];
            if (!score) {
                return text(`No credit score on file for customer ${customerId}.`);
            }
            return text(`Credit score for ${customerId}: ${score.score} (${score.band}). Last updated ${score.updated}.`);
        }
    );
}

// ============================================================================
// SUMMARY OF DELIBERATELY BAD TOOLS (for the Foundry optimisation demo)
// ----------------------------------------------------------------------------
//  NASTY #1  crm-data                  Transaction search. Useless name +
//                                      "Gets data." description, undocumented
//                                      params (q/cat/min/max), hidden category
//                                      enum, non-obvious abs-value amount filter.
//
//  NASTY #2  crm-card-manage           Overloaded action tool. "Manage a card.
//                                      Pass an action." doesn't list valid
//                                      actions or warn that report-lost is
//                                      irreversible.
//
//  NASTY #3  crm-process               MOVES MONEY but is named/described as a
//                                      generic "helpful utility". No units, no
//                                      confirmation, no warning it debits
//                                      immediately. High-risk ambiguity.
//
//  NASTY #4  crm-account-balance-check  MISLEADING — claims to return account
//                                      balance but actually returns the credit
//                                      score. Wrong-tool-selection bait.
//
//  NASTY #5  crm-update-details         OVER-CLAIMS scope (says it edits segment,
//                                      KYC, limits, DOB…) but only updates
//                                      email/phone/address. Over-promising.
//
//  Good counterparts exist for several of these (crm-recent-transactions,
//  crm-get-credit-score) so you can A/B the optimiser's rewrites.
// ============================================================================
